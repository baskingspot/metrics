const std = @import("std");

const metrics = @import("metrics");

test "per-worker histograms folded into one series" {
    const Histogram = metrics.histogram.Fixed(metrics.counter.Local(u64), &.{ 1024, 1 << 20 });

    // What each worker recorded on its own, with no lock and no shared state.
    var workers: [3]Histogram = undefined;
    for (&workers) |*worker| {
        worker.* = .zero;
        worker.observe(512);
    }
    workers[2].observe(1 << 21);

    // One call adds the buckets, the count, and the sum of every worker.
    const total = Histogram.mergeAll(&workers);

    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w: metrics.prometheus.Writer = .init(&out);
    try w.writeHistogram(
        .{ .name = "message_size_bytes", .kind = .histogram },
        .{ .direction = "inbound" },
        Histogram.Bounds,
        &total.buckets,
        total.total,
        total.observed,
    );

    try std.testing.expectEqualStrings(
        \\# HELP message_size_bytes
        \\# TYPE message_size_bytes histogram
        \\message_size_bytes_bucket{direction="inbound",le="1024"} 3
        \\message_size_bytes_bucket{direction="inbound",le="1048576"} 3
        \\message_size_bytes_bucket{direction="inbound",le="+Inf"} 4
        \\message_size_bytes_sum{direction="inbound"} 2098688
        \\message_size_bytes_count{direction="inbound"} 4
        \\
    , out.buffered());
}
