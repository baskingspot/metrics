# The wire format, as built

Design notes for `prometheus` v0.1.0. Human docs live in `README.md` and the
guide; this file records what was tested and why the code looks the way it
does. The scope is `research/prometheus-scope.md` in `baskingspot/internal`.

## What v0.1.0 is

The text exposition format 0.0.4 writer, and nothing else. `*std.Io.Writer` is
the only sink: no HTTP, no allocator, no clock, no thread, no `var`. A family
that manages state over time belongs to the application.

## Compiler facts, tested on 0.16.0 and 0.17.0 on 2026-11-05

Both compilers agree on every value and every API below, except field
enumeration.

- `std.Io.Writer` with `.print`, `.writeAll`, `.writeByte`, and `.buffered()`
  is the same type on both.
- `@hasField(std.builtin.Type.Struct, "field_names")` is false on 0.16 and
  true on 0.17. That is the probe for the struct-of-arrays rename. Use the
  index helpers `fieldCount(T)` and `fieldName(T, i)`; a function that builds
  and returns a `[]const []const u8` of names fails on 0.16.
- `std.meta.fields` is still declared on 0.17, so `@hasDecl` is not a usable
  probe. Do not call it.
- `{d}` on an `f64` is positional, always: 301 bytes for `1e300`, 326 for
  `5e-324`, 309 for `floatMax`. `{}` is the same as `{d}`.
- `{e}` on an `f64` gives the shortest mantissa with no padding: `1e300`,
  `1e6`, `1.5e0`, `1e-3`, `-0e0`. On `inf`, `-inf`, and `nan` it emits no
  exponent at all, so canonicalizing non-finite values has to happen before
  any comparison between the two forms.
- `{d}` on an integer type is exact. `u64` max prints `18446744073709551615`;
  the same value through `f64` prints `18446744073709552000`.

## Decisions

Value formatting: `+Inf`, `-Inf`, `NaN` are written as themselves. Every other
float is formatted both positionally and scientifically, and the scientific
form is used only when it is strictly shorter. That gives `1841`, `1.5`,
`1e6`, `1e-3`, and `1e300`. Go's `%g` chooses `1e+06` and `0.001`; ours is
shorter and legal, and a golden test pins it. Integers never go through `f64`.

The buffer for the two candidates is 512 bytes on the stack, which covers the
326-byte worst case with room to spare.

Interleaving: `family` writes the header and returns a handle that owns the
write. There is no way to hold two handles over one writer, so a family's
samples are contiguous by construction.

## Still open

The scope's discussion pile, in order: `Histogram(comptime limits)`,
`aggregate`, `render`, counter and gauge types. None of it is in v0.1.0.
