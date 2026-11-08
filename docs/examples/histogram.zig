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

test "record observations, then write the series" {
    const S = metrics.counter.Atomic(u64);
    var histogram: metrics.histogram.Fixed(S, &.{ 1024, 1 << 20 }) = .zero;
    histogram.observe(512);
    histogram.observe(2048);
    histogram.observe(1 << 21);

    var snap: @TypeOf(histogram).Snapshot = undefined;
    histogram.snapshot(&snap);

    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w: metrics.prometheus.Writer = .init(&out);
    try w.writeHistogram(
        .{ .name = "message_size_bytes", .kind = .histogram },
        .{ .direction = "inbound" },
        &.{ 1024, 1 << 20 },
        &snap.buckets,
        snap.total,
        snap.observed,
    );

    try std.testing.expectEqualStrings(
        \\# HELP message_size_bytes
        \\# TYPE message_size_bytes histogram
        \\message_size_bytes_bucket{direction="inbound",le="1024"} 1
        \\message_size_bytes_bucket{direction="inbound",le="1048576"} 2
        \\message_size_bytes_bucket{direction="inbound",le="+Inf"} 3
        \\message_size_bytes_sum{direction="inbound"} 2099712
        \\message_size_bytes_count{direction="inbound"} 3
        \\
    , out.buffered());
}
