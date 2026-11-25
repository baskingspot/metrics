const std = @import("std");

const metrics = @import("metrics");

test "per-worker histograms folded into one series" {
    const Histogram = metrics.histogram.Fixed(metrics.counter.Local(u64), &.{ 1024, 1 << 20 });

    // Each worker records into the histogram it owns, with no lock and no
    // shared state.
    const Worker = struct { size: Histogram = .zero };
    var workers: [3]Worker = .{ .{}, .{}, .{} };
    for (&workers) |*worker| worker.size.observe(512);
    workers[2].size.observe(1 << 21);

    // A pointer per worker in worker order; no histogram is copied.
    var sizes: [workers.len]*const Histogram = undefined;
    for (&workers, 0..) |*worker, i| sizes[i] = &worker.size;

    // One call adds the buckets, the count, and the sum of every worker.
    const total = Histogram.mergeAll(&sizes);

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
