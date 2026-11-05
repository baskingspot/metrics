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

There are no dependencies, no allocator, no clock, and no threads. The numbers
are the caller's; the bytes are here.

- [Samples](#samples): `sample` writes one line, and labels come from a struct's field names, so an illegal label name does not compile.
- [Families](#families): `family` writes `# HELP` and `# TYPE` once and returns the handle the samples go through.
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

`prometheus` builds with Zig 0.16 and 0.17.

## Import it

```zig
const prometheus = @import("prometheus");
```

No std namespace is named `prometheus`, so nothing needs an alias.

## Pick a sink

Every writer in this package takes `*std.Io.Writer` and returns
`error{WriteFailed}` plus the two input errors. Wrapping the sink is three
lines, and it is the only thing this library asks of you.

A fixed buffer holds the document with no allocation:

```zig
var buffer: [4096]u8 = undefined;
var w: std.Io.Writer = .fixed(&buffer);
```

`std.Io.Writer.Allocating` grows a body you will own, and `std.Io.File.Writer`
writes to a file or a socket. The library never sees either.

## Read the examples

The examples this page embeds are in `docs/examples/`. `just test` compiles and
runs them with the module's own tests, so no page can show code that does not
build.

# Samples

## One line

`sample` writes a complete line: the name, the labels, the value, and a
newline.

```zig
{{ load_data(path="examples/sinks.zig", format="plain") | trim_end }}
```

The trailing newline is not optional. The parser rejects a document whose last
line has none, and every writer here adds one.

## Labels come from a struct

The labels argument is any struct: each field name is a label name, in
declaration order, and each field value is the label value.

A string field is escaped and an integer field is printed in decimal, inside
the quotes either parser expects. A struct with no fields writes no braces at
all, so `up 1` and not `up{} 1`.

A label name is a struct field. The grammar is `[a-zA-Z_][a-zA-Z0-9_]*`, and
the compiler enforces it: a field written as `@"not-a-label"` does not
compile.

## Values

A float is written the way `prometheus/common` writes it, which is
`strconv.FormatFloat(f, 'g', -1, 64)`: the shortest digits that round-trip, in
exponent form when the decimal exponent is below -4 or at least 6. So `1e6` is
`1e+06`, `1234567` is `1.234567e+06`, `0.0001` stays as it is, and `1e300` is
five bytes instead of 301.

`NaN`, `+Inf`, and `-Inf` are written exactly so, and zero is `0` or `-0`.

An integer never goes through `f64`. A `u64` counter above 2^53 prints every
digit.

## Escaping and UTF-8

Three bytes are escaped inside a label value: backslash, double quote, and
newline. Two are escaped in help text: backslash and newline. Everything else
is written raw, including tab, carriage return, NUL, and any valid UTF-8.

```zig
{{ load_data(path="examples/escaping.zig", format="plain") | trim_end }}
```

Invalid UTF-8 is the other failure that costs the whole scrape. The writer
checks each label value and returns `error.InvalidUtf8` rather than emit a
document that is structurally fine and semantically poisoned. The buffer is
left holding the bytes written before the bad one, so a caller that streams to
a socket should render into a buffer first.

# Families

## The header once, then the samples

A family is `# HELP` and `# TYPE` followed by its samples. `family` writes the
header and returns a handle; the samples go through the handle.

```zig
{{ load_data(path="examples/write_samples.zig", format="plain") | trim_end }}
```

`# HELP` is written when the family has help text and omitted when it does not.
`# TYPE` is always written, including for `.untyped`. The kind is one of
`counter`, `gauge`, `untyped`, and `histogram`, and a histogram goes through
`histogramFamily` instead, which does not compile if the kind is something
else.

## Why a handle

The format asks that a family's samples are contiguous, and a writer that takes
a name and a value produces documents that are not: it is one call to write the
next family's header before this family's last sample. The handle makes that
awkward on purpose. It carries the family's name and the writer, so every line
it writes lands where the header said it would, and a document built one
family at a time reads top to bottom.

The handle is the only value `family` returns, so a sample line cannot be
written for a family that has no header.

# Histograms

## Cumulative counts, written as buckets

A histogram's counters are cumulative: `counts[i]` is the number of
observations at or below `limits[i]`, and the last count is the total. The
caller keeps them; this library writes the bytes, including the implicit `+Inf`
bucket every classic histogram has.

```zig
{{ load_data(path="examples/histogram.zig", format="plain") | trim_end }}
```

The writer emits one `_bucket` line per limit, then `_bucket{le="+Inf"}` from
`count`, then `_sum` and `_count`. The `le` value goes through the same float
formatter as a sample value, so a limit of `1e6` is `le="1e+06"`.

An empty `limits` slice is legal: the family is one `+Inf` bucket, `_sum`, and
`_count`.

## What the writer checks

`Buckets` documents four invariants and `write` returns `error.InvalidBuckets`
when any of them fails, in every build mode:

- `counts.len` equals `limits.len`.
- The limits are finite and strictly ascending, so no `NaN`, no repeat, and no
  `+Inf`, which the implicit bucket already owns.
- The counts are monotone non-decreasing.
- The last count equals `count`.

A histogram that emits wrong bytes is the failure this package exists to
prevent, so a mismatched pair of slices is an error rather than an assertion
that disappears in a release build.

# Collecting from several threads

This library writes bytes. Where the numbers come from between two scrapes is
the application's design, and the shape that works is the same one that works
for any read-mostly counter.

## Per-thread state

Give each thread its own counters as plain fields on the struct that owns the
thing being counted. An add is an add, and there is no lock on the request
path and no atomic on the hot path. A connection counter lives on the listener,
a queue depth lives on the queue, and a histogram's buckets live beside the
code that observes them.

That costs one decision per counter and buys the property that a scrape never
sees a torn value.

## Snapshot, then render

A scrape is sequential. Ask each thread for a copy of its counters into memory
the scrape owns, an arena that is reused from one scrape to the next. When
every thread has answered, sort the copies by their labels, sum the ones that
are equal, and write the document with `family` and `histogramFamily`.

The sorting and summing step is where a document of `n` copies becomes `k`
series, and an `O(n log n)` sort beats a pairwise scan by a wide margin once
`k` is large. That step is not in this package: it needs an allocator and an
ordering decision, and both are the caller's.

# Limits

What is not here, named so nobody has to look.

- HTTP. There is no listener, no handler, no `Content-Type` constant, and no
  status code. Wrap a `std.Io.Writer`.
- Counters and gauges. A counter is a `u64` and an add, and the concurrency
  model around it is the application's most interesting metrics decision.
  `sample` and the family handle take the number.
- A registry, global state, or a `var` of any kind.
- `aggregate` and `render`: a whole document from a slice of samples, with the
  family grouping done for you.
- OpenMetrics 1.0, exemplars, `_created` series, and native histograms. Text
  format 0.0.4 is what a scraper accepts.
- `process_*` collectors. `getrusage` and `/proc/self` are the operating
  system's numbers, and the choice to publish them is the application's.
