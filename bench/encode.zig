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
const prometheus = @import("prometheus");
const testingx = @import("testingx");

const Io = std.Io;

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

/// One family of one sample, so the number is the per-family cost.
const two_label_samples = [_]struct { labels: TwoLabels, value: u64 }{
    .{ .labels = .{ .method = "GET", .status = "200" }, .value = 1841 },
};

const eight_label_samples = [_]struct { labels: EightLabels, value: u64 }{
    .{
        .labels = .{
            .a = "alpha",
            .b = "bravo",
            .c = "charlie",
            .d = "delta",
            .e = "echo",
            .f = "foxtrot",
            .g = "golf",
            .h = "hotel",
        },
        .value = 7,
    },
};

/// Every byte that the escaper has to look at, and the worst case: two output
/// bytes for each input byte.
const escape_text = "\\\\\\\"\"\"\\\"\\\\\\\"\"\"\\\"\\\\\\\"\"\"\\\"\\\\\\\"\"\"\\\"";

const escape_samples = [_]struct { labels: struct { k: []const u8 }, value: u64 }{
    .{ .labels = .{ .k = escape_text }, .value = 1 },
};

const HistogramLabels = struct { method: []const u8, code: u16 };
const HistogramSample = struct {
    labels: HistogramLabels,
    counts: [12]u64,
    sum: f64,
    count: u64,
};

const histogram_family: prometheus.Family = .{
    .name = "bench_request_duration_seconds",
    .kind = .histogram,
    .help = "Benchmark histogram.",
    .limits = &.{ 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5 },
};

const histogram_samples = [_]HistogramSample{
    .{ .labels = .{ .method = "GET", .code = 200 }, .counts = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 40 }, .sum = 4.5, .count = 40 },
    .{ .labels = .{ .method = "GET", .code = 404 }, .counts = .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2 }, .sum = 0.2, .count = 2 },
    .{ .labels = .{ .method = "POST", .code = 200 }, .counts = .{ 0, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 9 }, .sum = 0.9, .count = 9 },
    .{ .labels = .{ .method = "PUT", .code = 500 }, .counts = .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1 }, .sum = 0.4, .count = 1 },
};

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.add("Encoder/labels=2", benchmarkTwoLabels);
    try b.add("Encoder/labels=8", benchmarkEightLabels);
    try b.add("Encoder/escape", benchmarkEscape);
    try b.add("Histogram/buckets=12", benchmarkHistogram);
}

fn benchmarkTwoLabels(b: *testingx.B) !void {
    try run(b, &two_label_samples);
}

fn benchmarkEightLabels(b: *testingx.B) !void {
    try run(b, &eight_label_samples);
}

fn benchmarkEscape(b: *testingx.B) !void {
    try run(b, &escape_samples);
}

/// The bytes of exposition per iteration, so every case reports throughput.
fn run(b: *testingx.B, samples: anytype) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);

    while (try b.loop()) {
        w.end = 0;
        try prometheus.family(&w, .{
            .name = "bench_requests_total",
            .kind = .counter,
            .help = "Benchmark counter.",
        }, samples);
        b.keepAlive(w.buffered());
    }
    b.setBytes(@intCast(w.buffered().len));
}

fn benchmarkHistogram(b: *testingx.B) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);

    while (try b.loop()) {
        w.end = 0;
        try prometheus.histogramFamily(&w, histogram_family, &histogram_samples);
        b.keepAlive(w.buffered());
    }
    b.setBytes(@intCast(w.buffered().len));
}
