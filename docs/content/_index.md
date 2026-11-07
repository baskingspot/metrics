+++
title = "metrics"
+++

Prometheus text exposition format for Zig: write metrics to any writer, no HTTP.

The exposition bytes are the part every service writes by hand, and they are
where the bugs are. One unescaped newline in a label value takes down every
series in the scrape, not one line, and Zig's own `{d}` writes `nan` for `NaN`
and 301 characters for `1e300`. This package owns those two rules and the
escaping around them. It writes to any `std.Io.Writer`, so a buffer, a file,
and a socket are the caller's problem.

It is a cursor, not a registry. `Writer.writeMetric` writes one line, `writeFamily`
writes `# HELP` and `# TYPE` and hands back a writer for that family's samples,
and `Writer.writeHistogram` writes a classic histogram. Which families appear, in what
order, and whether a family has help text are the caller's business.

- [Samples](#samples): `Writer.writeMetric` writes one line, and labels come from a struct's field names, so an illegal label name does not compile.
- [Families](#families): `Writer.writeFamily` writes the header and returns the handle its samples go through.
- [Histograms](#histograms): `Writer.writeHistogram` takes the caller's limits and cumulative counts and writes `_bucket`, `_sum`, and `_count`.
- [Values and escaping](#values-and-escaping): a float that reads back as an integer is written as one, and the three bytes that need escaping are escaped.
- [The primitives](#the-primitives): `Writer` writes one record at a time, and every composition above it is built from those methods.
- [Limits](#limits): what is deliberately not here, from HTTP to a registry.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/metrics/v0.1.0.tar.gz
```

Add the module in `build.zig`:

```zig
const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("metrics", metrics.module("metrics"));
```

`metrics` builds with Zig 0.16 and 0.17. Its one dependency is `testingx`,
which is lazy and comes after an early return in `build.zig`, so a consumer
fetches nothing but the module.

## Import it

```zig
const metrics = @import("metrics");
```

No std namespace is named `metrics`, so nothing needs an alias. A program that
already binds `metrics` to something of its own imports the format it needs
instead of the package:

```zig
const prometheus = @import("metrics").prometheus;
```

Call sites then read `prometheus.Writer`, exactly as they did before the
package was renamed. A program that also wants the recording types imports the
package under another name — `metricsx`, by the org's rule for a shadowed
name — and reaches the format through it:

```zig
exe.root_module.addImport("metricsx", metrics.module("metrics"));
```

The import name is local, so the only requirement is that it is not one you
already use.

## Pick a sink

Every writer takes `*std.Io.Writer` and returns `error{WriteFailed}`. A fixed
buffer holds the document with no allocation:

```zig
var buffer: [4096]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
var w: metrics.prometheus.Writer = .init(&out);
```

`Writer` is the whole interface above the sink: it holds the `*std.Io.Writer`
and nothing else.

`std.Io.Writer.Allocating` grows a body you will own, and `std.Io.File.Writer`
writes to a file or a socket. The library never sees either.

```zig
{{ load_data(path = "examples/sinks.zig", format = "plain") | trim_end }}
```

## Read the examples

The examples this page embeds are in `docs/examples/`. `just test` compiles and
runs them with the module's own tests, so no page can show code that does not
build.

# Samples

## One line

`Writer.writeMetric` writes a name, its labels, a value, and a newline.

```zig
{{ load_data(path = "examples/sinks.zig", format = "plain") | trim_end }}
```

The trailing newline is not optional: the parser rejects a document whose last
line has none, and every writer here adds one.

## Labels come from a struct

The labels argument is any struct: each field name is a label name, in
declaration order, and each field value is the label value. A string field is
escaped and an integer field is printed in decimal, inside the quotes the parser
expects. A struct with no fields writes no braces at all, so `up 1` and not
`up{} 1`.

A label name is a struct field. The grammar is `[a-zA-Z_][a-zA-Z0-9_]*`, the
`__` prefix is reserved (`__name__` is the series name the parser builds from
the line, so it rejects a label that claims it), and the compiler enforces both:
a field written as `@"not-a-label"` or `.__name__` does not compile.

# Families

## The header, then the samples

`Writer.writeFamily` writes `# HELP` and `# TYPE` and returns a handle. Its `write`
method is `writeMetric` with the family's name, so a sample line cannot be
written under another name by accident.

```zig
{{ load_data(path = "examples/write_samples.zig", format = "plain") | trim_end }}
```

An empty `help` writes the `# HELP` line without text. The kind is one of
`counter`, `gauge`, `histogram`, and `untyped`, and it goes on the `# TYPE`
line as written.

## Ordering is yours

Nothing here knows which families you have written or in what order. Two calls
to `writeFamily` with the same name write two headers, and the parser accepts
it; a sample written through the second handle lands after the second header.
The handle exists to save typing the name and to keep the field order, not to
enforce a document shape.

# Histograms

## Cumulative counts, written as buckets

`Writer.writeHistogram` writes the header, then one `_bucket` line per limit, the
implicit `+Inf` bucket, `_sum`, and `_count`. The counts are cumulative:
`counts[i]` is the number of observations at or below `limits[i]`. The last
finite count is at most the total, because an observation above the top limit
belongs only to the `+Inf` bucket, which is written from `count`.

```zig
{{ load_data(path = "examples/histogram.zig", format = "plain") | trim_end }}
```

An empty `limits` slice writes one `+Inf` bucket, `_sum`, and `_count`.

## More than one series

`Writer.writeHistogram` writes the header and one series, so a family with two label
sets cannot call it twice: the second call writes `# HELP` and `# TYPE` again
and the parser rejects the document. Write the header once with `w.writeFamily`
and loop the series form.

```zig
const family = try w.writeFamily(.{ .name = "message_size", .kind = .histogram });
try family.writeHistogramSeries(.{ .direction = "inbound" }, &.{1024}, &[_]u64{1}, 1024, 1);
try family.writeHistogramSeries(.{ .direction = "outbound" }, &.{1024}, &[_]u64{0}, 3072, 2);
```

`sum` is `anytype`: pass a `u64` and every digit is written, because a `f64`
loses everything above 2^53. A float is formatted the way `writeMetric`
formats one.

## What is checked, and what is not

A length mismatch between `limits` and `counts` is a caller bug caught by a
debug assertion. Monotonicity, the size of the tail, and whether `sum`
corresponds to the observations are not checked: they are your counters, and a
library that second-guessed them would have to choose what to do about it.

Two things do not compile, because the bytes would be wrong and no caller could
repair them after the fact. A labels struct carrying `le` is refused: the writer
adds `le` to every bucket line, and a second one on the same line is a duplicate
label name the parser rejects. A `Metric` whose kind is not `.histogram` is
refused by the histogram writers: `# TYPE` would say `counter` or `gauge` while
the `_bucket` lines below it said otherwise.

# Values and escaping

## Values

A float that reads back as the same integer is written as that integer. `1e6`
is `1000000`, `3.0` is `3`, and `-0.0` is `0`. Everything else is Go's `'g'`
with the shortest round-trip digits, in exponent form when the decimal exponent
is below -4 or at least 6, so `1e21` is `1e+21`, `1e300` is `1e+300`, and
`0.0001` stays as it is.

`NaN`, `+Inf`, and `-Inf` are written exactly so.

An integer type never goes through `f64`, so a `u64` above 2^53 prints every
digit. A Go client passing that count as a float writes `9007199254740992`,
because it has no integer path.

## Escaping

Three bytes are escaped inside a label value: backslash, double quote, and
newline. Two are escaped in help text: backslash and newline. Everything else is
written raw, including tab, carriage return, NUL, and any valid UTF-8.

```zig
{{ load_data(path = "examples/escaping.zig", format = "plain") | trim_end }}
```

A label value must be valid UTF-8. The writer does not check it: a check inside
the writer would turn one crafted value into a debug abort, which is worse than
the poisoned document it replaces because it is not survivable, and a rule about
a caller's data does not belong there. Validate where the data arrives, and
answer with whatever your boundary answers for a bad request.

# The primitives

`Writer` writes one expfmt record per call and knows nothing else:

- `help(name, text)` writes `# HELP`, with the text escaped.
- `kind(name, k)` writes `# TYPE`.
- `name(name, labels)` writes `name{label="value",...}` and no trailing space. The labels are a struct, or a tuple of structs written in order.
- `value(v)` writes a space, the value, and the newline.
- `line(bytes)` writes bytes you formatted yourself.

Every composition on this page is built from those five, and a test holds it to
that: the first `_bucket` line `Writer.writeHistogram` writes must equal the same line
written by hand with `name` and `value`. A caller that needs a shape this
library does not have, such as a summary or an exemplar, writes it from the
primitives and gets the same values and escaping.

```zig
var out: std.Io.Writer = .fixed(&buffer);
var w: metrics.prometheus.Writer = .init(&out);
try w.name("custom_total", .{ .kind = "custom" });
try w.value(@as(u64, 7));
```

# Counters

## A number and an add

`counter.Int(T)` is the recording side: an unsigned integer and an add, with the type
and the concurrency model chosen where the counter is declared. `counter.Int(T)` is one
field and a `+%`, for state that belongs to one thread or to a struct the caller
already owns. `Atomic(T)` is a `std.atomic.Value(T)` with monotonic operations,
for a counter a scrape reads while another thread increments it.

```zig
{{ load_data(path = "examples/counter.zig", format = "plain") | trim_end }}
```

## Wrapping, and no way to reset

Both modes wrap at `maxInt(T)` and keep counting. A counter that saturated
would turn a visible reset into a silent flat line.

There is no `set` and no write method: a counter only goes up, and the bytes are
the writer's job. Read it with `get` and pass the number to `writeMetric`,
`writeFamily`, or a histogram.

`T` is whatever unsigned integer the counter should be: `u8` for a flag-like
count, `u32` where a word is enough, `u64` by default. `Atomic(T)` needs 8, 16,
32, or 64 bits, which is what the platform can increment atomically. `get` is a
monotonic load in the atomic case, which orders nothing else. A caller that needs a stronger ordering around its own data
does that ordering itself.

# Limits

What is not here, named so nobody has to look.

- HTTP. There is no listener, no handler, no `Content-Type` constant, and no
  status code. Wrap a `std.Io.Writer`.
- Ordering, family uniqueness, and a document model. The writer lays down lines.
- Counters and gauges. A counter is a `u64` and an add, and the concurrency
  model around it is the application's decision. `writeMetric` takes the number.
- A registry, global state, or a `var` of any kind.
- Validation of a histogram's counters beyond the length. Monotone counts, a
  consistent tail, and a matching `sum` are the caller's.
- OpenMetrics 1.0, exemplars, `_created` series, and native histograms.
- `process_*` collectors. `getrusage` and `/proc/self` are the operating
  system's numbers.
