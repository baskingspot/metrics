+++
title = "prometheus"
+++

Prometheus text exposition format for Zig: write metrics to any writer, no HTTP.

The exposition bytes are the part every service writes by hand, and they are
where the bugs are. One unescaped newline in a label value takes down every
series in the scrape, not one line. A writer that takes a name and a value will
also let one family's header land between another family's samples. This
package owns those bytes. It writes text format 0.0.4 to any `std.Io.Writer`,
so the sink is the caller's problem, and the documents it produces are
accepted by the parser Prometheus ships.

One call writes one family: the header, then every sample. That is what makes
a family's samples contiguous instead of contiguous by convention.

- [Samples](#samples): labels come from a struct's field names, values are written the way a Go client writes them, and an illegal name does not compile.
- [Families](#families): `family` writes `# HELP`, `# TYPE`, and every sample in one call, so there is no handle to leak and no second way to emit a sample.
- [The runtime door](#the-runtime-door): `prometheus.runtime` takes the same descriptor as a value, for a name composed at runtime or an embedder's prefix.
- [Histograms](#histograms): `histogramFamily` takes the caller's limits and cumulative counts and writes `_bucket`, `_sum`, and `_count`.
- [Collecting from several threads](#collecting-from-several-threads): per-thread counters, a snapshot, and one render, because no library can pick your locking model.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/prometheus
```

Add the module in `build.zig`:

```zig
const prometheus = b.dependency("prometheus", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("prometheus", prometheus.module("prometheus"));
```

`prometheus` builds with Zig 0.16 and 0.17. Its one dependency is `testingx`,
which is lazy and comes after an early return in `build.zig`, so a consumer
fetches nothing but the module.

## Import it

```zig
const prometheus = @import("prometheus");
```

No std namespace is named `prometheus`, so nothing needs an alias.

## Pick a sink

Every writer in this package takes `*std.Io.Writer`. A fixed buffer holds the
document with no allocation:

```zig
var buffer: [4096]u8 = undefined;
var w: std.Io.Writer = .fixed(&buffer);
```

`std.Io.Writer.Allocating` grows a body you will own, and `std.Io.Writer.File`
writes to a file or a socket. The library never sees either.

```zig
{{ load_data(path="examples/sinks.zig", format="plain") | trim_end }}
```

## Read the examples

The examples this page embeds are in `docs/examples/`. `just test` compiles and
runs them with the module's own tests, so no page can show code that does not
build.

# Samples

## Labels come from a struct

A sample is `{ .labels = ..., .value = ... }`, and the labels argument is any
struct: each field name is a label name, in declaration order, and each field
value is the label value. A string field is escaped and an integer field is
printed in decimal, inside the quotes the parser expects.

A struct with no fields writes no braces at all, so `up 1` and not `up{} 1`.

A label name is a struct field. The grammar is `[a-zA-Z_][a-zA-Z0-9_]*`, and
the compiler enforces it: a field written as `@"not-a-label"` does not compile.

## Values

A float is written the way `prometheus/common` writes it, which is
`strconv.FormatFloat(f, 'g', -1, 64)`: the shortest digits that round-trip, in
exponent form when the decimal exponent is below -4 or at least 6. A float
`1e6` is `1e+06`, a float `1234567.0` is `1.234567e+06`, `0.0001` stays as it
is, and `1e300` is five bytes instead of 301.

`NaN`, `+Inf`, and `-Inf` are written exactly so, and zero is `0`. Negative
zero is `0` too: Go's writer tests `f == 0`, which is true for it, and matching
that is the point.

An integer never goes through `f64`, so it is exact and positional: the integer
`1234567` stays `1234567`, and a `u64` above 2^53 prints every digit. A Go
client passing that count as a float writes `1.234567e+06`, because it has no
integer path. Floats are the bytes that match Go; a count here is exact by
design.

## Escaping and UTF-8

Three bytes are escaped inside a label value: backslash, double quote, and
newline. Two are escaped in help text: backslash and newline. Everything else
is written raw, including tab, carriage return, NUL, and any valid UTF-8.

```zig
{{ load_data(path="examples/escaping.zig", format = "plain") | trim_end }}
```

Invalid UTF-8 is the other failure that costs the whole scrape. The writer
checks each label value and returns `error.InvalidUtf8` rather than emit
a document that is structurally fine and semantically poisoned. A label value
is caught as it is written, so that one failure can leave a partial line in the
buffer; every other check runs before the first byte, so a bad name, kind, or
bucket set writes nothing. A caller that streams to a socket should render into
a buffer first.

# Families

## One call, header first

`family` writes `# HELP`, `# TYPE`, and every sample, and returns when the
family is done.

```zig
{{ load_data(path="examples/write_samples.zig", format="plain") | trim_end }}
```

`samples` is anything iterable whose elements have `.labels` and `.value`: a
slice, an array, or a tuple literal. The descriptor is comptime, so a bad
metric name, a bad label name, and a kind that belongs to `histogramFamily` do
not compile.

`# HELP` is written when the family has help text and omitted when it does not.
`# TYPE` is always written, including for `.untyped`.

## Why one call

The format asks that a family's samples are contiguous, and a writer that hands
back a handle cannot guarantee it: `*std.Io.Writer` is copyable, so two live
handles interleave however the type system is asked to behave, and the rule
would have been a comment. With one call there is no object to leak, and the
document reads top to bottom because the only way to write a sample is inside
the call that wrote its header.

# The runtime door

## A name composed at runtime

The comptime door cannot see a name you build, so `prometheus.runtime` takes
the same descriptor as a value and validates it at run time.

```zig
{{ load_data(path="examples/runtime.zig", format = "plain") | trim_end }}
```

The error set is the same for both doors: the sink's failure, plus
`InvalidName`, `InvalidUtf8`, `InvalidBuckets`, and `MismatchedKind`, and every
one of them has a path that returns it. What differs is where a mistake is
caught. The metric name, the kind, and the limits
are values, so the runtime door returns an error and the comptime door does
not compile. A label name and a duplicated `le` come from a type, so both doors
reject those at compile time.

## The same bytes

Both doors run the same emitter. The comptime door precomputes the header as
one literal and the histogram `le` values as a table, and the runtime door
formats each as it goes, but the sample loop is written once. Every golden
document in the repository's fixture archive is rendered through both doors and
compared byte for byte.

# Histograms

## Cumulative counts, written as buckets

The descriptor carries the bucket upper bounds in `limits`. Each sample carries
its cumulative counts, its sum, and its total: `counts[i]` is the number of
observations at or below `limits[i]`. The last count is at most the total,
because an observation above the top limit belongs only to the implicit `+Inf`
bucket, which is written from `count`. The caller keeps all of it; this library
writes the bytes.

```zig
{{ load_data(path="examples/histogram.zig", format = "plain") | trim_end }}
```

The writer emits one `_bucket` line per limit, then `_bucket{le="+Inf"}` from
`count`, then `_sum` and `_count`. The `le` value goes through the same float
formatter as a sample value, so a limit of `1e6` is `le="1e+06"`.

An empty `limits` slice is legal: the family is one `+Inf` bucket, `_sum`, and
`_count`.

## What the writer checks

Every check runs before the first byte is written, so a rejected family leaves
the writer exactly as it found it. `error.InvalidBuckets` comes back when any of
these fails, in every build mode; the comptime door also turns the limit check
into a compile error.

- `counts.len` equals `limits.len`.
- The limits are finite and strictly ascending, so no `NaN`, no repeat, and no
  `+Inf`, which the implicit bucket already owns.
- The counts are monotone non-decreasing.
- The last count is at most `count`. It is equal when every observation is at
  or below the top limit, and lower when the family has a tail.

A histogram that emits wrong bytes is the failure this package exists to
prevent, so a mismatched pair of slices is an error rather than an assertion
that disappears in a release build.

# Collecting from several threads

This library writes bytes. Where the numbers come from between two scrapes is
the application's design, and the shape that works is the same one that works
for any read-mostly counter.

## Per-thread state

Give each thread its own counters as plain fields on the struct that owns the
thing being counted. An add is an add, and there is no lock on the request path
and no atomic on the hot path. A connection counter lives on the listener, a
queue depth lives on the queue, and a histogram's buckets live beside the code
that observes them.

That costs one decision per counter and buys the property that a scrape never
sees a torn value.

## Snapshot, then render

A scrape is sequential. Ask each thread for a copy of its counters into memory
the scrape owns, an arena that is reused from one scrape to the next. When
every thread has answered, sort the copies by their labels, sum the ones that
are equal, and write the document one family at a time.

The sorting and summing step is where a document of `n` copies becomes `k`
series, and an `O(n log n)` sort beats a pairwise scan by a wide margin once
`k` is large. That step is not in this package: it needs an allocator and an
ordering decision, and both are the caller's.

# Limits

What is not here, named so nobody has to look.

- HTTP. There is no listener, no handler, no `Content-Type` constant, and no
  status code. Wrap a `std.Io.Writer`.
- Counters and gauges. A counter is a `u64` and an add, and the concurrency
  model around it is the application's most interesting metrics decision. The
  writers take the number.
- A registry, global state, or a `var` of any kind.
- `aggregate` and `render`: a whole document from a slice of samples, with the
  family grouping done for you.
- Streaming one family a sample at a time. The one-call shape is what makes
  contiguity a fact, and a caller that cannot produce a slice has to.
- OpenMetrics 1.0, exemplars, `_created` series, and native histograms. Text
  format 0.0.4 is what a scraper accepts.
- `process_*` collectors. `getrusage` and `/proc/self` are the operating
  system's numbers, and the choice to publish them is the application's.
