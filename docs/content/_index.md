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
- [Counters](#counters): `counter.Local(T)` and `counter.Atomic(T)` are an unsigned integer and an add, wrapping, with no way to reset.
- [Gauges](#gauges): `gauge.Local(T)` and `gauge.Atomic(T)` are a number with `set`, `add`, `sub`, `inc`, `dec`, and `get`; the integer may be signed and the float is `f32` or `f64`.
- [Limits](#limits): what is deliberately not here, from HTTP to a registry.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

```sh
zig fetch --save https://baskingspot.dev/metrics/v0.3.0.tar.gz
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

## Record into one

`histogram.Fixed(S, bounds)` is the recording side: a bucket array, a count, and
a sum, each slot the same recording counter type, so one argument decides
atomicity for all of them.

```zig
{{ load_data(path = "examples/histogram.zig", format = "plain") | trim_end }}
```

`observe(v)` walks the bounds at comptime and increments every bucket whose
bound is at or above `v`, so the counts are cumulative at observe and go to
`writeHistogramSeries` unchanged. Atomic slots fill a `Snapshot` you own:
`[bounds.len]u64` plus the count and the sum on the stack. A local histogram
needs none of that — it is plain integers already, so `counts()` lends you its
own buckets and copies nothing. Nothing here allocates, and nothing keeps a
pointer past the call.

`S` is `counter.Atomic(u64)` for a scrape that reads while workers observe, and
`counter.Local(u64)` for a histogram one thread owns. The sum is exact because
the slot's value type is `u64`, not a float, so nothing loses digits above 2^53.

Observations are `u64`, and microseconds stand in for seconds the way the
counter accumulates nanoseconds: one unit that is exact, converted at the write
site.

Bounds can be spelled out or generated at comptime: `&histogram.linear(1, 10, 5)`
gives five bounds ten apart, and `&histogram.exponential(1, 2, 10)` gives ten
doubling from one. Neither counts the `+Inf` bucket, which is implicit.

Bounds are `f64` and observations are `u64`, so the comparison converts the
observation with `@floatFromInt`. That is exact below 2^53, which is nine
petabytes of bytes or 104 days of microseconds, and approximate above it. Empty
bounds are legal and produce a single `+Inf` bucket.

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

`counter.Local(T)` and `counter.Atomic(T)` are the recording side: an unsigned
integer and an add, with the type and the concurrency model chosen where the
counter is declared.

`counter.Local(T)` is one field and a `+%`, for state that belongs to one thread
or to a struct the caller already owns. `counter.Atomic(T)` stores the same
integer with monotonic atomic operations, for a counter a scrape reads while
another thread increments it.

```zig
{{ load_data(path = "examples/counter.zig", format = "plain") | trim_end }}
```

## Wrapping, and no way to reset

Both modes wrap at `maxInt(T)` and keep counting. A counter that saturated
would turn a visible reset into a silent flat line.

There is no `set` and no write method: a counter only goes up, and the bytes are
the writer's job. Read it with `get` and pass the number to `writeMetric`,
`writeFamily`, or a histogram.

`T` is the unsigned integer the counter should be: `u8` for a flag-like count,
`u32` where a word is enough, `u64` by default. `counter.Atomic(T)` needs 8, 16,
32, or 64 bits, which is what the platform can increment atomically. `get` is a
monotonic load in the atomic case, which orders nothing else; a caller that
needs a stronger ordering around its own data does that ordering itself.

## Where the name and the help text go

A counter is storage. It carries no name and no help, because those belong to
the family: the family is what a scraper documents and what a linter can check
for a missing description.

```zig
const families = struct {
    pub const requests = metrics.prometheus.Metric{
        .name = "http_requests_total",
        .kind = .counter,
        .help = "Requests served, by method and status.",
    };
};

var requests: metrics.counter.Local(u64) = .zero;

// where the document is written
const family = try w.writeFamily(families.requests);
try family.write(.{ .method = "GET" }, requests.get());
```

Both of those lines are optional. `# HELP` and `# TYPE` exist for scrapers that
read them; a caller writing samples alone through `writeMetric` pays nothing for
them, and some backends ignore them entirely.

## Accumulate in the smallest exact unit

A counter is an integer, so a duration or a ratio is recorded in the unit that is
exact rather than the unit that is convenient. Accumulate nanoseconds and divide
at the write site:

```zig
try w.writeMetric("process_cpu_seconds_total", .{}, cpu_nanos.get() / 1e9);
```

`counter.Local(u64)` of nanoseconds is exact and branch-free, and the division
happens once per scrape. An `f64` accumulator of seconds stops being exact the
moment the total passes 2^53 nanoseconds, which is about 104 days of process
time: inside the lifetime of a busy service, and the digits are gone silently.

The same reasoning covers any "total time spent" accumulator, and cents rather
than dollars for money. A histogram's `_sum` is not a counter series at all: it
sums in the observed type, which `writeHistogram` takes as `anytype`.

If a genuine case appears where a delta arrives fractional and cannot be scaled,
the design to reach for is a contended float accumulator with a compare-exchange
loop, not an `f64` field. None has appeared yet.

# Gauges

## A number that moves both ways

`gauge.Local(T)` is a plain field; `gauge.Atomic(T)` is an atomic of the same value.
The constructor names the storage and `T` names the value type: `Local(i64)`,
`Local(f64)`, `Atomic(u32)`. The difference from a counter is the method
set and the type: a gauge has `set` and `sub`, its integer may be signed, and its
float is `f32` or `f64`, because a gauge holds a temperature, a ratio, or a queue
depth that dips below its last reading.

```zig
{{ load_data(path = "examples/gauge.zig", format = "plain") | trim_end }}
```

`set`, `add`, `sub`, `inc`, `dec`, and `get`, with `zero` to make one.

## Atomic floats

An atomic float is an integer atomic holding the bit pattern. `set` and `get`
are a store and a load on that integer; `add` and `sub` are a compare-exchange
loop, because there is no atomic float add to call. The loop returns early for a
zero add, so a no-op does not contend for the line.

The loop is what keeps a contended gauge correct: four threads adding to one
`Atomic(f64)` produce the exact total, which is what the contention test in the
source asserts.

## Subtraction, and the floor nothing checks

`sub` wraps at the type's bounds and reports nothing. A gauge that dips below
zero on an unsigned type is a `+` and a `-` that do not match, and no arithmetic
inside the type can find the second one, so there is no assertion to make.
Saturating would be worse than wrapping: it turns a mismatch into a flat line,
which is the same bug with less evidence. A signed gauge has no floor at all --
going negative is the point -- and a float reaches `-Inf` rather than wrapping.

The pattern that prevents the mismatch is to pair the operations on one object:
`var lease = in_flight.acquire(); defer lease.release();`. Zig has no
destructor, so the `defer` is still the caller's to write, but the two halves
cannot be inverted or counted twice.

## HELP and TYPE are optional

A gauge written through `writeMetric` carries neither line. Nothing requires
them: `# HELP` and `# TYPE` are for scrapers that read the descriptor, and a
caller that writes samples only pays nothing for them. `writeFamily` is there
when you want the header.

# Limits

What is not here, named so nobody has to look.

- HTTP. There is no listener, no handler, no `Content-Type` constant, and no
  status code. Wrap a `std.Io.Writer`.
- Ordering, family uniqueness, and a document model. The writer lays down lines.
- A recording type that writes. Read the number with `get` and pass it to the
  writer.
- A registry, global state, or a `var` of any kind.
- Validation of a histogram's counters beyond the length. Monotone counts, a
  consistent tail, and a matching `sum` are the caller's.
- OpenMetrics 1.0, exemplars, `_created` series, and native histograms.
- `process_*` collectors. `getrusage` and `/proc/self` are the operating
  system's numbers.
