const std = @import("std");

const metrics = @import("metrics");

test "a histogram family from the caller's cumulative counts" {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w: metrics.prometheus.Writer = .init(&out);

    try w.writeHistogram(.{
        .name = "request_latency_seconds",
        .kind = .histogram,
        .help = "Request latency.",
    }, .{ .method = "GET" }, &.{ 0.005, 0.05 }, &[_]u64{ 12, 40 }, 3.5, 40);

    try std.testing.expectEqualStrings(
        \\# HELP request_latency_seconds Request latency.
        \\# TYPE request_latency_seconds histogram
        \\request_latency_seconds_bucket{method="GET",le="0.005"} 12
        \\request_latency_seconds_bucket{method="GET",le="0.05"} 40
        \\request_latency_seconds_bucket{method="GET",le="+Inf"} 40
        \\request_latency_seconds_sum{method="GET"} 3.5
        \\request_latency_seconds_count{method="GET"} 40
        \\
    , out.buffered());
}
