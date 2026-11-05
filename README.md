<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="prometheus" height="48">
  </picture>
</h1>

Prometheus text exposition format for Zig: write metrics to any writer, no HTTP.

The exposition bytes are the part every service writes by hand, and they are
where the bugs are. One unescaped newline in a label value takes down every
series in the scrape, not one line. A writer that takes a name and a value will
also let one family's header land between another family's samples. This
package owns those bytes. It writes text format 0.0.4 to any `std.Io.Writer`,
so the sink is the caller's problem.

There are no dependencies, no allocator, no clock, and no threads. The numbers
are the caller's; the bytes are here.

```zig
var buffer: [4096]u8 = undefined;
var w: std.Io.Writer = .fixed(&buffer);

const requests = try prometheus.family(&w, .{
    .name = "http_requests_total",
    .kind = .counter,
    .help = "Requests served, by method and status.",
});
try requests.write(.{ .method = "GET", .status = "200" }, 1841);
try requests.write(.{ .method = "POST", .status = "500" }, 3);
```

The API is pre-1.0: pin the commit, and expect it to move.

## What is in it

- [Samples](https://baskingspot.dev/prometheus/#samples): `sample` writes one line, and labels come from a struct's field names, so an illegal label name does not compile.
- [Families](https://baskingspot.dev/prometheus/#families): `family` writes `# HELP` and `# TYPE` once and returns the handle the samples go through.
- [Histograms](https://baskingspot.dev/prometheus/#histograms): `histogramFamily` takes the caller's limits and cumulative counts and writes `_bucket`, `_sum`, and `_count`, with `le` formatted by the same float writer as a value.
- [Collecting from several threads](https://baskingspot.dev/prometheus/#collecting-from-several-threads): per-thread counters, a snapshot, and one render, because no library can pick your locking model.

Not implemented:

- HTTP. There is no listener, no handler, no `Content-Type` constant, and no status code. Wrap a `std.Io.Writer`.
- Counters and gauges. A counter is a `u64` and an add, and the concurrency model around it is the application's decision. `sample` and the family handle take the number.
- A registry, global state, or a `var` of any kind.
- `aggregate` and `render`: a whole document from a slice of samples, with the family grouping done for you.
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

No std namespace is named `prometheus`, so nothing needs an alias. `prometheus` builds with Zig 0.16 and 0.17.

## Documentation

- The [guide](https://baskingspot.dev/prometheus/) covers samples, families, histograms, and the collection pattern this library deliberately does not ship.
- The [API reference](https://baskingspot.dev/prometheus/api/) documents every public symbol in `src/root.zig`.
- [`docs/examples/`](docs/examples/) is the test-verified code shown in the guide: `just test` compiles and runs it alongside the module's own tests.
- [`AGENTS.md`](AGENTS.md) has the working notes for the repository.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain and the site tools. `just` lists the
recipes, and `just ci` runs what CI runs: the unit tests, the guide's examples,
lint, the `prom2json` gates, and the site build.

Two recipes check the output against Prometheus's own parser:
`just check-fixture` renders one document covering every construct, and
`just check-corpus N SEED` renders `N` random documents from a seed and fails on
the first rejection. `just check` is the same gate on the previous Zig.

## License

MIT. See [`LICENSE`](LICENSE). The logo files in `docs/static/` are baskingspot
marks and are not covered by it. See [`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
