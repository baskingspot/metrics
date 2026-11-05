# The wire format, as built

Design notes for `prometheus` v0.1.0. Human docs live in `README.md` and the
guide; this file records what was tested and why the code looks the way it
does. The scope is `research/prometheus-scope.md` in `baskingspot/internal`.

## The shape

One call writes one family: the header, then every sample. The comptime door
(`family`, `histogramFamily`) takes the descriptor at comptime and turns a bad
metric name, a bad label name, a wrong kind, an `le` collision, and bad limits
into compile errors. `prometheus.runtime` takes the same descriptor as a value
and returns those as errors. Both run one emitter.

A handle that the caller writes through one sample at a time cannot hold the
contiguity line: `*std.Io.Writer` is copyable, so two live handles interleave
however the type system is asked to behave, and the invariant would have been
a comment. The one-call shape makes it a fact.

## Compiler facts, tested on 0.16.0 and 0.17.0

- `std.Io.Writer` with `.print`, `.writeAll`, `.writeByte`, and `.buffered()`
  is the same type on both.
- `@hasField(std.builtin.Type.Struct, "field_names")` is false on 0.16 and
  true on 0.17. That is the probe for the struct-of-arrays rename. Use the
  index helpers `fieldCount(T)` and `fieldName(T, i)`; a function that builds
  and returns a `[]const []const u8` of names fails on 0.16.
- `std.meta.fields` is still declared on 0.17, so `@hasDecl` is not a usable
  probe. Do not call it.
- `{d}` on an `f64` is positional, always. `{}` is the same as `{d}`.
- `{e}` on an `f64` gives the shortest mantissa with no padding: `1e300`,
  `1e6`, `1.5e0`, `-0e0`, and no exponent at all on `inf`/`nan`.
- `std.meta.activeTag(@typeInfo(T))` plus `info.@"struct".is_tuple` works on
  both, and `&.{ ... }` in an `anytype` position is a pointer to a tuple, not
  an array, so the tuple check has to look through one pointer.

## Comptime precomputation

The comptime door writes its header as one literal and its `le` values as a
table, both built with `comptime` blocks that are proven on both compilers:

- The header is `"# HELP " ++ name ++ " " ++ escaped_help ++ "\n# TYPE ..."`
  with `escaped_help` built by `++` in a comptime loop over the input bytes.
- The `le` table is `[limits.len][32]u8`, filled by running the real float
  writer into a fixed buffer per row at comptime. A zero-length table would be
  indexed by the shared bucket loop, and indexing an empty array is a compile
  error, so the loop falls back to formatting when the table is empty.

Neither is a correctness requirement. The sample loop is shared, so if the
comptime machinery ever fights a compiler, dropping it costs one format per
bucket and nothing else.

## Value formatting

`prometheus/common`'s `writeFloat`: `NaN`, `+Inf`, `-Inf` bare, zero as `0` or
`-0`, everything else `strconv.FormatFloat(f, 'g', -1, 64)`. Zig's `{e}` has
the shortest digits, so the formatter parses its mantissa and exponent and
re-emits them per Go's rule: exponent form below -4 and at 6 and above, with a
signed, zero-padded exponent. All 14 rows of the reference table agree on both
compilers, and 200,000 random f64 bit patterns round-trip through
`parseFloat`.

Integers take a separate path and never go through `f64`.

## Escaping and UTF-8

Three bytes are escaped in a label value and two in HELP. Tab, carriage
return, NUL, and any valid UTF-8 stay raw. Invalid UTF-8 returns
`error.InvalidUtf8` instead of producing a document the parser rejects.

## Tests

- `test/testdata/golden.txtar` holds one expected document per case, read at
  compile time by `testingx.fixtures`. Every case renders through both doors
  and both must match the file, which is the differential check.
- `test/compile_fail/` holds five snippets the comptime door must reject, each
  with an `.expect` naming the message. The recipe fails if a snippet compiles
  or fails for the wrong reason.
- `just check-corpus N SEED` renders N random documents through `runtime`, one
  per file and the set as one txtar, and pipes each to `prom2json`.
- `just check-golden` splits the golden archive and pipes every document
  through `prom2json`, so the oracle sees the comptime door's bytes and the
  integer values, which the corpus never produces.
- `just bench` reports bytes per second for four cases: 2 labels, 8 labels, an
  escape-heavy label, and a 12-bucket histogram with four samples.

## The oracle

`prom2json` is in the devShell, from the flake, so both gates run offline. It
catches syntax, escaping, name charsets, duplicate label names, bad UTF-8, and
a missing trailing newline. It does not catch duplicate series, family
ordering, or any histogram invariant, so those are unit tests: a golden
contiguity document and a 2,000-round property test over random buckets.

## Still open

The discussion pile, in order: `Histogram(comptime limits)` as a value type,
`aggregate`, `render`, counter and gauge types. None of it is in v0.1.0.
