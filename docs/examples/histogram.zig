const std = @import("std");
const prometheus = @import("prometheus");

test "a histogram family from the caller's cumulative counts" {
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    const latency = try prometheus.histogramFamily(&w, .{
        .name = "request_latency_seconds",
        .kind = .histogram,
        .help = "Request latency.",
    });
    try latency.write(.{ .method = "GET" }, .{
        .limits = &.{ 0.005, 0.05 },
        .counts = &.{ 12, 40 },
        .sum = 3.5,
        .count = 40,
    });

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
