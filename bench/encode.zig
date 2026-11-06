//! What the encoder costs: headers, label reflection, escaping, and buckets,
//! measured as bytes of exposition per second.
//!
//! `just bench` runs this ReleaseFast through testingx and prints the Go
//! benchmark format, so `benchstat` compares two runs with no glue. Names use
//! benchfmt parts so a matrix groups: `Encoder/labels=2`, `Encoder/escape`,
//! `Histogram/buckets=12`.
//!
//! Bytes per second is the metric because it is the only number that matters on
//! a metrics path: how much exposition one core can push.

const std = @import("std");
const Io = std.Io;

const prometheus = @import("prometheus");
const testingx = @import("testingx");

const TwoLabels = struct { method: []const u8, status: []const u8 };
const EightLabels = struct {
    a: []const u8,
    b: []const u8,
    c: []const u8,
    d: []const u8,
    e: []const u8,
    f: []const u8,
    g: []const u8,
    h: []const u8,
};

/// Every byte the escaper has to look at, and the worst case: two output bytes
/// for each input byte.
const escape_text = "\\\\\\\"\"\"\\\"\\\\\\\"\"\"\\\"\\\\\\\"\"\"\\\"\\\\\\\"\"\"\\\"";

const two_labels = TwoLabels{ .method = "GET", .status = "200" };
const eight_labels = EightLabels{
    .a = "alpha",
    .b = "bravo",
    .c = "charlie",
    .d = "delta",
    .e = "echo",
    .f = "foxtrot",
    .g = "golf",
    .h = "hotel",
};
const escape_labels = struct { k: []const u8 }{ .k = escape_text };

const histogram_limits = [_]f64{ 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5 };
const histogram_counts = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 40 };
const histogram_metric: prometheus.Metric = .{
    .name = "bench_request_duration_seconds",
    .kind = .histogram,
    .help = "Benchmark histogram.",
};

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.add("Encoder/labels=2", benchmarkTwoLabels);
    try b.add("Encoder/labels=8", benchmarkEightLabels);
    try b.add("Encoder/escape", benchmarkEscape);
    try b.add("Histogram/buckets=12", benchmarkHistogram);
}

fn benchmarkTwoLabels(b: *testingx.B) !void {
    try run(b, two_labels);
}

fn benchmarkEightLabels(b: *testingx.B) !void {
    try run(b, eight_labels);
}

fn benchmarkEscape(b: *testingx.B) !void {
    try run(b, escape_labels);
}

/// One family of one sample, so the number is the per-family cost, reported as
/// the bytes of exposition it produces.
fn run(b: *testingx.B, labels: anytype) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w: prometheus.Writer = .init(&out);

    while (try b.loop()) {
        out.end = 0;
        const family = try w.writeFamily(.{
            .name = "bench_requests_total",
            .kind = .counter,
            .help = "Benchmark counter.",
        });
        try family.write(labels, 1841);
        b.keepAlive(out.buffered());
    }
    b.setBytes(@intCast(out.buffered().len));
}

fn benchmarkHistogram(b: *testingx.B) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w: prometheus.Writer = .init(&out);

    while (try b.loop()) {
        out.end = 0;
        try w.writeHistogram(
            histogram_metric,
            .{ .method = "GET", .code = 200 },
            &histogram_limits,
            &histogram_counts,
            4.5,
            40,
        );
        b.keepAlive(out.buffered());
    }
    b.setBytes(@intCast(out.buffered().len));
}
