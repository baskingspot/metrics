# The wire format, as built

Agent notes for `prometheus` v0.1.0. Human docs live in `README.md` and the
guide; this file records what was tried, what was tested, and why the code looks
the way it does. The scope is `research/prometheus-scope.md` in
`baskingspot/internal`.

## The shape

A cursor, not a model. `writeMetric` writes one line; `writeFamily` writes
`# HELP` and `# TYPE` and returns a handle whose `write` is `writeMetric` under
that name; `writeHistogram` writes a classic histogram. Ordering, family
uniqueness, and whether a family has help are the caller's.

That is Matt's call of 2026-11-06, after three earlier shapes were built and
removed:

- **A family that owned its samples through a handle, with contiguity as a
  property.** It cannot hold: `*std.Io.Writer` is copyable, so two live handles
  interleave whatever the type says, and the invariant was a comment with a
  golden test beside it.
- **One call per family with a slice, a tuple, or an iterator.** Contiguity
  became a fact, but the API forced a gather, and `scratch` existed to supply
  the buffer. Storage type, alignment, and sizing arithmetic in every caller is
  the bookkeeping Matt objected to.
- **Two doors over one emitter**, comptime and runtime, with exact error sets.
  Two ways to say one thing, for a runtime family name nobody needed.

What survived all of it is the part that is genuinely format-specific and easy
to get wrong: the value writer, the escaping, and the comptime name checks.

## Values

`prometheus/common`'s rule, which is `expfmt.writeFloat64`'s:

```
intvalue := int64(value)
if float64(intvalue) == value -> decimal integer
else if value <  -MaxFloat64   -> "-Inf"
else if value >   MaxFloat64   -> "+Inf"
else if IsNaN(value)           -> "NaN"
else                           -> strconv.FormatFloat(value, 'g', -1, 64)
```

The integer arm is why `1e6` is `1000000`, `3.0` is `3`, and `-0` is `0`. The
`'g'` arm is the shortest round-trip digits, in exponent form when the decimal
exponent is below -4 or at least 6, so `1e21` is `1e+21` and `0.0001` stays.

Zig's `{d}` alone is not enough, and that is the reason this file exists: it
prints 301 characters for `1e300`, and `nan` for `NaN`.

`writeGoFloat` borrows Zig's `{e}`, which already has the shortest digits with
no sign and no zero padding on the exponent, then re-spaces them into Go's form.
All 14 rows of the reference table agree on Zig 0.16.0 and 0.17.0, and 200,000
random bit patterns round-trip through `parseFloat`.

The integer path is separate: a `u64` above 2^53 keeps every digit and never
touches `f64`.

## Escaping

Three bytes in a label value (`\`, `"`, newline) and two in HELP (backslash,
newline). Tab, carriage return, NUL, and any valid UTF-8 stay raw.

Invalid UTF-8 is `std.debug.assert`, not an error: a label value from outside
the program is a bug to catch in development, not a condition to thread through
every call site.

## Why there is no `scratch`

A helper that reinterpreted caller-owned `[]u64` as a typed slice was written
and removed. `[]u64` was the right word type: alignment 8 is a property of the
slice, so the cast needs no `@alignCast` on a buffer the caller may have sized
wrong. `std.mem.bytesAsSlice` was still the wrong primitive underneath, because
it does `@divExact(bytes.len, @sizeOf(T))` over the whole buffer, so a scratch
holding one spare word past a whole number of samples panics there rather than
being ignored.

## Tests

- `test/testdata/golden.txtar`: one expected document per case, embedded with
  `testingx.fixtures`. `just check-golden` splits the archive and pipes every
  document through `prom2json`, so the oracle sees the goldens on both lanes.
- `test/compile_fail/`: six snippets the comptime checks must reject, each with
  an `.expect` naming the message.
- `just check-corpus N SEED`: random documents from a seeded PRNG, one per file
  and the set as one txtar, each piped to `prom2json`.
- `just bench`: bytes per second for two labels, eight labels, the escaping
  path, and a twelve-bucket histogram.
- `just check-cold`: deletes `zig-pkg` and `.zig-cache` first, because a warm
  `zig-pkg` hides a lazy dependency that developer-only code unwraps.

## The oracle

`prom2json` catches syntax, escaping, name charsets, duplicate label names, bad
UTF-8, and a missing trailing newline. It does not catch duplicate series,
family ordering, or any histogram invariant, so those are unit tests.

## Still open

The discussion pile, in order: a `Histogram` value type with `observe` and
`merge`, `aggregate`, `render`, counter and gauge types. None of it is in
v0.1.0.
