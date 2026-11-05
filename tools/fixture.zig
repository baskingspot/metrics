//! The fixture document the oracle gate feeds to Prometheus's parser.
//!
//! Every construct the writer can produce, in one document: labels, escapes,
//! control characters, families, and the values that formatting gets wrong. A
//! development tool, so it may use a fixed buffer and write to stdout.

const std = @import("std");
const prometheus = @import("prometheus");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try document(&w);
    try Io.File.stdout().writeStreamingAll(init.io, w.buffered());
}

fn document(w: *Io.Writer) !void {
    try prometheus.family(w, .{
        .name = "fixture_requests_total",
        .kind = .counter,
        .help = "Requests served, by method and status.",
    }, &.{
        .{ .labels = .{ .method = "GET", .status = "200" }, .value = 1841 },
        .{ .labels = .{ .method = "POST", .status = "500" }, .value = 3 },
    });

    try prometheus.family(w, .{ .name = "fixture_up", .kind = .gauge }, &.{
        .{ .labels = .{}, .value = 1 },
        .{ .labels = .{ .k = "" }, .value = 0 },
        .{ .labels = .{ .k = "back\\slash\"quote\nnewline" }, .value = 2 },
        .{ .labels = .{ .k = "tab\ttcr\rc\x00nul" }, .value = 3 },
        .{ .labels = .{ .k = "é 日本 🦎" }, .value = 4 },
        .{ .labels = .{ .port = 8080 }, .value = 5 },
    });

    try prometheus.family(w, .{
        .name = "fixture_escaped_help",
        .kind = .untyped,
        .help = "Back\\slash.\nNew line. \"Quote\". Tab\there.",
    }, &.{.{ .labels = .{}, .value = 0 }});

    try prometheus.family(w, .{ .name = "fixture_bare", .kind = .counter }, &.{
        .{ .labels = .{}, .value = 0 },
    });

    try prometheus.family(w, .{ .name = "fixture_values", .kind = .untyped }, &.{
        .{ .labels = .{ .case = "zero" }, .value = 0 },
        .{ .labels = .{ .case = "negative_zero" }, .value = -0.0 },
        .{ .labels = .{ .case = "nan" }, .value = std.math.nan(f64) },
        .{ .labels = .{ .case = "inf" }, .value = std.math.inf(f64) },
        .{ .labels = .{ .case = "negative_inf" }, .value = -std.math.inf(f64) },
        .{ .labels = .{ .case = "small" }, .value = 0.0001 },
        .{ .labels = .{ .case = "tiny" }, .value = 1e-7 },
        .{ .labels = .{ .case = "big" }, .value = 1e300 },
        .{ .labels = .{ .case = "subnormal" }, .value = 5e-324 },
        .{ .labels = .{ .case = "u64_max" }, .value = std.math.maxInt(u64) },
    });

    try prometheus.histogramFamily(w, .{
        .name = "fixture_latency_seconds",
        .kind = .histogram,
        .help = "Request latency.",
        .limits = &.{ 0.001, 0.1, 1e6 },
    }, &.{.{
        .labels = .{ .method = "GET" },
        .counts = &[_]u64{ 1, 3, 4 },
        .sum = 1.5,
        .count = 4,
    }});

    try prometheus.histogramFamily(w, .{
        .name = "fixture_unbucketed",
        .kind = .histogram,
    }, &.{.{
        .labels = .{},
        .counts = &[_]u64{},
        .sum = 0,
        .count = 0,
    }});
}
