<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="prometheus" height="48">
  </picture>
</h1>

Prometheus text exposition format for Zig: write metrics to any writer, no HTTP.

The exposition bytes are the part every service writes by hand, and they are
where the bugs are. One unescaped newline in a label value takes down every
series in the scrape, not one line, and Zig's own `{d}` writes `nan` for `NaN`
and 301 characters for `1e300`. This package owns those two rules and the
escaping around them, to any `std.Io.Writer`.

```zig
var buffer: [4096]u8 = undefined;
var out: std.Io.Writer = .fixed(&buffer);
var w = prometheus.Writer.init(&out);

const requests = try prometheus.writeFamily(&w, .{
    .name = "http_requests_total",
    .kind = .counter,
    .help = "Requests served, by method and status.",
});
try requests.write(.{ .method = "GET", .status = "200" }, 1841);
try requests.write(.{ .method = "POST", .status = "500" }, 3);
```

It is a cursor, not a registry. Which families appear, in what order, and
whether a family has help text are the caller's business, and the primitives
underneath (`Writer.help`, `kind`, `name`, `value`, `line`) are public so a
caller can compose a shape this library does not have.

The API is pre-1.0: pin the commit, and expect it to move.

## What is in it

- [Samples](https://baskingspot.dev/prometheus/#samples): `writeMetric` writes one line, and labels come from a struct's field names, so an illegal label name does not compile.
- [Families](https://baskingspot.dev/prometheus/#families): `writeFamily` writes `# HELP` and `# TYPE` and returns the handle its samples go through.
- [Histograms](https://baskingspot.dev/prometheus/#histograms): `writeHistogram` takes the caller's limits and cumulative counts and writes `_bucket`, `_sum`, and `_count`, `le` included.
- [Values and escaping](https://baskingspot.dev/prometheus/#values-and-escaping): a float that reads back as an integer is written as one, and the three bytes that need escaping are escaped.
- [The primitives](https://baskingspot.dev/prometheus/#the-primitives): `Writer` writes one record at a time, and every composition above it is built from those methods.

Not implemented:

- HTTP. There is no listener, no handler, no `Content-Type` constant, and no status code. Wrap a `std.Io.Writer`.
- Ordering, family uniqueness, and a document model.
- Counters and gauges. A counter is a `u64` and an add, and the concurrency model around it is the application's decision.
- A registry, global state, or a `var` of any kind.
- Validation of a histogram's counters beyond the length.
- OpenMetrics 1.0, exemplars, `_created` series, and native histograms.
- `process_*` collectors. `getrusage` and `/proc/self` are the operating system's numbers.

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/prometheus
```

Add the module in `build.zig`:

```zig
const prometheus = b.dependency("prometheus", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("prometheus", prometheus.module("prometheus"));
```

No std namespace is named `prometheus`, so nothing needs an alias. `prometheus`
builds with Zig 0.16 and 0.17. It has one dependency, `testingx`, marked lazy
and used only after `build.zig` returns for a consumer, so a consumer's fetch
graph is the module and nothing else.

## Documentation

- The [guide](https://baskingspot.dev/prometheus/) covers samples, families, histograms, and the value and escaping rules.
- The [API reference](https://baskingspot.dev/prometheus/api/) documents every public symbol in `src/root.zig`.
- [`docs/examples/`](docs/examples/) is the test-verified code shown in the guide: `just test` compiles and runs it alongside the module's own tests.
- [`AGENTS.md`](AGENTS.md) has the working notes for the repository.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain and the site tools. `just` lists the
recipes, and `just ci` runs what CI runs: the unit tests, the guide's examples,
lint, the `prom2json` gates, one benchmark iteration, and the site build.

Two recipes check the output against Prometheus's own parser:
`just check-golden` pipes every golden document through it, and
`just check-corpus N SEED` renders `N` random documents from a seed and fails
on the first rejection. `just check` is the same gate on the previous Zig.

`just bench` runs the encode benchmarks in ReleaseFast and reports bytes per
second.

## License

MIT. See [`LICENSE`](LICENSE). The logo files in `docs/static/` are baskingspot
marks and are not covered by it. See [`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
