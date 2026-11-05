//! The fixture document the oracle gate feeds to Prometheus's parser.
//!
//! Every construct the writer can produce, in one document: labels, escapes,
//! control characters, and the values that formatting gets wrong. A development
//! tool, so it may use a fixed buffer and write to stdout.

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
    try prometheus.sample(w, "fixture_requests_total", .{ .method = "GET", .status = "200" }, 1841);
    try prometheus.sample(w, "fixture_requests_total", .{ .method = "POST", .status = "500" }, 3);
    try prometheus.sample(w, "fixture_up", .{}, 1);
    try prometheus.sample(w, "fixture_port", .{ .port = 8080 }, 1);
    try prometheus.sample(w, "fixture_empty_label", .{ .k = "" }, 1);
    try prometheus.sample(w, "fixture_escapes", .{ .k = "back\\slash\"quote\nnewline" }, 1);
    try prometheus.sample(w, "fixture_controls", .{ .k = "tab\ttcr\rc\x00nul" }, 1);
    try prometheus.sample(w, "fixture_unicode", .{ .k = "é 日本 🦎" }, 1);
    try prometheus.sample(w, "fixture_zero", .{}, 0);
    try prometheus.sample(w, "fixture_negative_zero", .{}, -0.0);
    try prometheus.sample(w, "fixture_nan", .{}, std.math.nan(f64));
    try prometheus.sample(w, "fixture_positive_infinity", .{}, std.math.inf(f64));
    try prometheus.sample(w, "fixture_negative_infinity", .{}, -std.math.inf(f64));
    try prometheus.sample(w, "fixture_small", .{}, 0.0001);
    try prometheus.sample(w, "fixture_tiny", .{}, 1e-7);
    try prometheus.sample(w, "fixture_big", .{}, 1e300);
    try prometheus.sample(w, "fixture_subnormal", .{}, 5e-324);
    try prometheus.sample(w, "fixture_u64", .{}, std.math.maxInt(u64));
    try prometheus.sample(w, "fixture_i64", .{}, -std.math.maxInt(i64));
}
