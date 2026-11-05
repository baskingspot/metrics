const std = @import("std");
const prometheus = @import("prometheus");

test "a histogram family from the caller's cumulative counts" {
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try prometheus.histogramFamily(&w, .{
        .name = "request_latency_seconds",
        .kind = .histogram,
        .help = "Request latency.",
        .limits = &.{ 0.005, 0.05 },
    }, &.{.{
        .labels = .{ .method = "GET" },
        .counts = &[_]u64{ 12, 40 },
        .sum = 3.5,
        .count = 40,
    }});

    try std.testing.expectEqualStrings(
        \\# HELP request_latency_seconds Request latency.
        \\# TYPE request_latency_seconds histogram
        \\request_latency_seconds_bucket{method="GET",le="0.005"} 12
        \\request_latency_seconds_bucket{method="GET",le="0.05"} 40
        \\request_latency_seconds_bucket{method="GET",le="+Inf"} 40
        \\request_latency_seconds_sum{method="GET"} 3.5
        \\request_latency_seconds_count{method="GET"} 40
        \\
    , w.buffered());
}

test "no limits is one +Inf bucket" {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try prometheus.histogramFamily(&w, .{
        .name = "request_latency_seconds",
        .kind = .histogram,
    }, &.{.{
        .labels = .{},
        .counts = &[_]u64{},
        .sum = 1.25,
        .count = 7,
    }});

    try std.testing.expectEqualStrings(
        \\# TYPE request_latency_seconds histogram
        \\request_latency_seconds_bucket{le="+Inf"} 7
        \\request_latency_seconds_sum 1.25
        \\request_latency_seconds_count 7
        \\
    , w.buffered());
}
