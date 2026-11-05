# Frontier review: prometheus exposition library

Reviewed: the tree at `8ea7c6a` (clean; `60b48d4` plus `b42f032`, `24f1dae`,
`8ea7c6a`), per the mid-run steering. `src/Family.zig`, `src/value.zig`,
`src/escape.zig`, `src/labels.zig`, and `src/name.zig` are byte-identical
between my first read and `8ea7c6a`. All four library findings below also
reproduce at `60b48d4`.

Every experiment ran from a scratch copy under `/tmp`, compiled against
`src/root.zig` with `zig test|run --dep prometheus -Mprometheus=...`, on 0.17.0
(default shell) and 0.16.0 (`.#zig-old`, `/nix/store/y6ngc...-zig-0.16.0`).

Verdict: NEEDS CHANGES. Two of the defects produce wrong output on realistic
input, and a third stops ordinary histograms from compiling. The value
formatter, the escaping, and two-door byte identity all held under every
differential I ran.

## Ranked findings

### 1. defect: a histogram with any observation above its top limit is refused

- Where: `src/Family.zig:341` (`counts[counts.len - 1] != total`).
- Claim: the library returns `error.InvalidBuckets` for valid classic
  histograms. Prometheus's `+Inf` bucket is the total. The last finite bucket
  counts only the observations at or below the top limit, so
  `counts[last] <= count`, not `==`. Observations above the top limit are a
  latency histogram's tail, so this rejects ordinary data.
- Input (both doors):
  `histogramFamily(&w, .{ .name = "latency", .kind = .histogram, .limits = &.{ 10, 20 } }, &.{ .{ .labels = .{}, .counts = &[_]u64{ 1, 2 }, .sum = 45, .count = 3 } })`
  returns `error.InvalidBuckets` (observations 5, 15, 25).
  `runtime.histogramFamily` returns the same error.
- Corroboration: exosphere's own test `writeHistogramFamily: emits classic
  histogram samples` (`Histogram(&.{10, 20})`, observes 10 and 25) expects
  `le="10"} 1`, `le="20"} 1`, `le="+Inf"} 2`, `_count 2`. The library refuses
  exactly that input: `.counts = &[_]u64{ 1, 1 }, .sum = 35, .count = 2` gives
  `error.InvalidBuckets`, and `prom2json` accepts the bytes exosphere expects.
  The Go reference writes `+Inf` from `SampleCount`, independent of the last
  finite bucket (`prometheus/common@v0.72.0/expfmt/text_create.go:235-262`).
- Side effect: the header is already in the writer when the error fires.
  Running the first input leaves `# TYPE latency histogram\n` in the buffer,
  so the commonest form of this bug also leaves a partial family behind.
- The bug is carried everywhere, so nothing catches it: spec property 5
  ("`counts[last] == count`"), the guide (`docs/content/_index.md:183`, `:207`),
  `test/golden.zig:282-288`, which asserts the bug as correct behavior, the
  property test generator, `tools/corpus.zig:207-219`, and every bench sample.
- Fix: reject only `counts[last] > count`. Change the guide's "the last count
  is the total". Flip `golden.zig` w11 to a success case with a golden.

### 2. defect: histogram label names are never validated, in either door

- Where: `src/Family.zig:127-134`. `emitHistogram` calls only
  `checkNoLe`. `checkLabelNames` runs in `emitSample` (`:94`), and nothing
  calls it on the histogram path.
- Claim: a label name outside `[a-zA-Z_][a-zA-Z0-9_]*` compiles through
  `histogramFamily` and `runtime.histogramFamily` and produces bytes the
  oracle rejects. The spec and the guide both say a bad label name does not
  compile.
- Input:
  `const Bad = struct { @"not-a-label": []const u8 };`
  `histogramFamily(&w, .{ .name = "latency", .kind = .histogram, .limits = &.{1} }, &.{ .{ .labels = Bad{ .@"not-a-label" = "x" }, .counts = &[_]u64{1}, .sum = 1, .count = 1 } })`
  writes `latency_bucket{not-a-label="x",le="1"} 1`. `prom2json` exits 1 with
  "expected '=' after label name, found '-'". `.labels = .{ .@"é" = "x" }`
  through `runtime.histogramFamily` also compiles and emits `{é="x",...}`.
- Fix: call `checkLabelNames` in `emitHistogram`, and add a compile-fail
  snippet for `histogramFamily`. The current snippets cover `family` only,
  which is why this went unnoticed.

### 3. defect: the comptime door does not compile a histogram with about 17 or more limits

- Where: `src/Family.zig:250-258` (`leTexts`). It formats every limit through
  `std.fmt.bufPrint("{e}")` in one comptime evaluation. `Io.Writer.print` sets
  the quota to `fmt.len * 1000` = 3000, and the per-limit cost adds up across
  the loop until it passes that.
- Claim: the default door fails to compile on ordinary bucket layouts. The
  runtime door accepts the same descriptor, so the doors diverge. The
  thresholds are the same on 0.16.0 and 0.17.0.
- Input: `.limits` = `0.001 * 2^i` for i in 0..16 compiles; 17 limits fails.
  `1, 2, ..., 17` compiles; 18 fails. The message is
  `std/Io/Writer.zig:1724:35: error: evaluation exceeded 3000 backwards branches`,
  pointing into std, with the trace ending at `Family.zig:63`. 20 limits, as
  in `ExponentialBuckets(…, 2, 20)`, does not compile. A caller can work
  around it with `@setEvalBranchQuota(…)` in its own function. That works,
  but nothing in the error or the docs tells them to.
- Fix: `@setEvalBranchQuota(1000 + limits.len * 1000)` at the top of
  `leTexts`'s comptime block, plus a golden case with 30 or more limits through
  both doors.

### 4. defect (narrow): a label named `__name__` is accepted and kills the scrape

- Where: `src/name.zig:28` (`isValidLabelName`).
- Claim: `__name__` matches the grammar, so it compiles, but the parser
  rejects it as reserved.
- Input:
  `family(&w, .{ .name = "jobs_total", .kind = .counter }, &.{ .{ .labels = .{ .__name__ = "other" }, .value = 1 } })`
  writes `jobs_total{__name__="other"} 1`. `prom2json` exits 1 with
  `label name "__name__" is reserved`
  (`common@v0.72.0/expfmt/text_parse.go:413`). Other `__x` names pass the
  oracle.
- Fix: reject `__name__` in `isValidLabelName`'s comptime caller. Arguably
  reject the whole `__` prefix, which the data model reserves.

### 5. risk: other comptime quotas that real inputs can reach

- `src/Family.zig:301-309`: `checkLabelNames` runs one comptime loop over
  every field, and since `b42f032` it runs in both doors. A labels struct
  with 40 fields of 13-character names fails with "exceeded 2000 backwards
  branches" (`name.zig:37`); 30 such fields compiles. Rare today, but the
  failure is an opaque std/name.zig error.
- `src/escape.zig:33-47`: `escapeHelp` fails at about 2,000 bytes of HELP
  (2,900 fails, 1,500 compiles), comptime door only.
- Fix: the same scaled `@setEvalBranchQuota` in both functions.

### 6. risk: errors arrive after bytes are written

- Where: `src/Family.zig:136`, and the label-value path.
- Claim: `InvalidBuckets` fires per histogram, after the header and any
  earlier label sets have been written. `InvalidUtf8` leaves half a line
  (`name{k="`). The guide (`:118`) documents the UTF-8 case and not the
  histogram case.
- Why it matters: with finding 1, the commonest histogram input triggers this
  path.
- Fix: validate counts, and optionally string label values, in a pass before
  the header, so a failed call writes nothing.

### 7. risk / spec conflict: `-0` does not match the Go reference

- Where: `src/value.zig:39`.
- Claim: `expfmt.writeFloat` has `case f == 0: '0'`, which is true for `-0.0`,
  so a Go client writes `0` and `le="0"`
  (`common@v0.72.0/expfmt/text_create.go:476-481`). This library writes `-0`.
  The spec's table lists `strconv.FormatFloat`, not `writeFloat`, and makes
  `-0` an acceptance golden. The guide now says floats "are the bytes that
  match Go".
- Impact: harmless to the parser, which accepts both, but it is the one float
  that does not match Go. Matt should decide; I would not block on it.

## Categories with no finding

- **Two-door byte identity (2):** none beyond finding 3. I compiled 322
  comptime limit sets through both doors and compared the bytes. The sets were
  22 edge singletons (`-0.0`, `5e-324`, `±max`, `1e21`, `1e22`, `1e-5`,
  `123456.7`, `999999.5`, `0.30000000000000004`, `2^53+1`, and others) and 300
  random sorted bit-pattern sets. All were identical on 0.17.0 and on 0.16.0.
  A `-0.0` literal keeps its sign at comptime (`le="-0"` from both doors). The
  descriptor checks match: the same predicates in the same order, and label
  names and `le` are comptime in both doors.
- **Panics and UB in ReleaseFast (3):** none reachable.
  - `value.zig:47`: `bufPrint` of `{e}` peaks at 24 bytes into 40.
  - `value.zig:51`: the `.?` is safe because a finite nonzero `{e}` always has
    an `e`.
  - `value.zig:52`: the exponent fits `i32`.
  - `Family.zig:255`/`:263`: at most 24 bytes into `le_size` 32.
  - `Family.zig:190-192`: the index is bounded by the `counts.len == limits.len`
    check that runs first.
  - `escape.zig:76`: the `unreachable` is safe because `findAny` returns only
    the specials.
  - `@intCast` at `value.zig:79`/`:92`: both are non-negative by construction.
- **0.16 versus 0.17 at run time (4):** none.
  - Floats: `writeFloat` over 1.5M values gave byte-identical output on both
    compilers (`cmp`). The values were a third random bit patterns, a third
    scaled decimals `k·10^e`, and a third random integers. The output matched
    an independent Go `'g'` emulation (Python `repr` shortest digits plus Go's
    layout rule) with 0 mismatches.
  - UTF-8: `utf8ValidateSlice` over 400k biased byte strings agreed on both
    compilers and with Python's strict UTF-8 decoder, which has Go's
    surrogate and overlong rules.
  - Quota thresholds in finding 3 are the same on both.
  - `parseFloat` is used only in tests.
- **Escaping, empty labels, and integer versus float paths (1):** no wrong
  bytes. One document went through `prom2json` with:
  - HELP containing `" \t \r \x00 🦎 \\ \n` and a trailing `\`;
  - labels with `\r\x00\t🦎\\"\n`, `i64` min, and `u128` max;
  - values `-0`, `5e-324`, `i128` min, and an `f32` 0.1;
  - histogram limits `-1e300`, `-0`, `5e-324`, `1e-5`, `123456.7`, `max` in
    both doors, with `-Inf`/`NaN` sums.

  It parsed, and every label, help string, and value round-tripped.
  Zero-field labels write no braces, and a bucket line always writes `{le=…}`.
  `+Inf` and `_count` always print the same number.

## Tests (5)

- `test/golden.zig:282-288` (w11) asserts finding 1's wrong behavior as
  correct: counts `{1,2}`, count 3, expect `InvalidBuckets`.
- `test/golden.zig:322-393`, the histogram property: the generator sets
  `.count = cumulative`, so it never produces a tail observation. Its `+Inf`
  and `_count` assertions compare a printed number with the input it was
  printed from. It cannot find finding 1.
- Compile-fail coverage: no snippet sends a bad label name through
  `histogramFamily`, which is where finding 2 is. `runtime_name.expect` is
  the generic substring `must be comptime-known`, which other comptime
  failures also match.
- The oracle gate has shrunk. Since `b42f032`, `check` is
  `test check-compile-fail`: `check-fixture` is gone, so the 0.16 lane never
  runs `prom2json`, and no golden document is piped through it anywhere.
  `README.md:90`, `AGENTS.md:27`, and `flake.nix:34` still name
  `just check-fixture`. The corpus covers less than the fixture did:
  - runtime door only;
  - `f64` values only, so no integer value reaches the oracle;
  - fixed label names (`k`, `a`/`b`, `method`/`code`/`host`);
  - histograms whose last count always equals the total.

  The spec's acceptance asks for both a fixture recipe and a corpus recipe
  in `ci`.
- Spec property 1, escaping round trip, is carried for label values only.
  HELP escaping has no round-trip property. Minor, since it is a two-byte
  subset.

## Before tagging

Fix 1, 2, and 3 before the tag; each is small. Finding 1 is a one-character
change to the check (`!=` to `>`), plus the guide sentence, the w11 test, and
a property generator that sometimes sets `count` above the last bucket.
Finding 2 is one `comptime checkLabelNames(...)` line in `emitHistogram` and
a compile-fail snippet. Finding 3 is a scaled `@setEvalBranchQuota` in
`leTexts` and a 30-limit golden through both doors. Fold 4 in while touching
the label check. Restore a `prom2json` pass over the golden documents, or a
fixture document, in `check`, so the 0.16 lane and integer values reach the
oracle again. Leave as they are, with a sentence in the guide:
- the other quota limits (5), until someone has 40 labels;
- the partial write on error (6), though moving the counts check before the
  header is cheap once 1 is fixed;
- the `-0` spelling (7), which is Matt's call against the spec table.

The float formatter, UTF-8 validation, escaping, and two-door identity held
under every differential I ran, and I would not touch them.

## Validation

- `nix develop --command just ci` at `8ea7c6a`: passed. testingx 12/10/15
  passed; compile-fail 7 rejected; lint clean; corpus 50 accepted; bench 1
  iteration; docs built.
- `nix develop .#zig-old --command just check` at `8ea7c6a`: passed.
- `nix develop --command just check-corpus 100 3`: passed, 100 documents
  accepted.
- `nix develop --command just bench` (count=5): ran. About 30 ns/op for 2
  labels, about 92 ns/op for 8 labels, about 140 ns/op for escape, about
  3.2 µs/op for the 12-bucket histogram ×4.
- Scratch experiments in `/tmp/promexp`: `hist_tail.zig`, `exo_case.zig`,
  `hist_badlabel.zig` + `prom2json`, `reserved.zig` + `prom2json`,
  `q*/i*/e*.zig` (quota thresholds, both compilers), `mf*.zig`,
  `help*.zig`, `doors.zig` (both compilers), `floatdump.zig` + `gocheck.py`
  (both compilers), `utf8dump.zig` (both compilers), `edge_doc.zig` +
  `prom2json`.
- Not run: Go itself (not on PATH). Go-equivalence comes from the emulation
  and from reading `prometheus/common@v0.72.0` in `~/go/pkg/mod`.
