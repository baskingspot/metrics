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

Value formatting: a float is written the way `prometheus/common` writes it,
`strconv.FormatFloat(f, 'g', -1, 64)`, because that is what every Go client
emits. `NaN`, `+Inf`, and `-Inf` are written as themselves; zero is `0` or
`-0`; everything else is the shortest round-trip digits, positional when the
decimal exponent is in -4 to 5, and exponent form otherwise with a signed,
two-digit-padded exponent. So `1e6` is `1e+06`, `1234567` is
`1.234567e+06`, `0.0001` stays positional, and `1e300` is 5 bytes rather
than 301. Zig's `{e}` already has the shortest digits, so the formatter parses
its mantissa and exponent and re-emits them; both compilers agree byte for
byte on the whole table. Integers never go through `f64`.

Escaping and UTF-8: three bytes are escaped in a label value (`\`, `"`,
newline) and two in HELP (`\`, newline). Tab, carriage return, NUL, and any
valid UTF-8 stay raw. Invalid UTF-8 returns `error.InvalidUtf8` instead of
producing a document the parser rejects, because one bad label value costs
every series in the scrape.

Interleaving: `family` writes the header and returns a handle, and every sample
line for that family goes through it. Two calls to `family` on one writer still
compile, because Zig has no move semantics and a `*std.Io.Writer` is copyable,
so contiguity is a property of the API's shape plus a golden test, not a
compile error. The compile-fail cases cover what comptime can prove: the kind
paired with the handle, and the name grammars.

## The oracle

`prom2json` is in the devshell, from the flake, so both gates run offline.
`just check-fixture` pipes one document; `just check-corpus N SEED` emits N
random documents and fails on the first rejection with the seed printed. 300
documents at seed 11 pass.

Corpus coverage is bounded by the API: a label name is a comptime struct
field, so label *shapes* are fixed and only values, escapes, counts, and
numbers vary. Metric names come from a fixed pool. A random name is a unit
test on the grammar, not a corpus entry.

## Still open

The scope's discussion pile, in order: `Histogram(comptime limits)`,
`aggregate`, `render`, counter and gauge types. None of it is in v0.1.0.
