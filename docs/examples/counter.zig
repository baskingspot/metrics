const std = @import("std");
const metrics = @import("metrics");

test "record with a counter, write with the writer" {
    var requests: metrics.counter.Local(u64) = .zero;
    requests.inc();
    requests.add(41);

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w: metrics.prometheus.Writer = .init(&out);
    try w.writeMetric("http_requests_total", .{ .method = "GET" }, requests.get());

    try std.testing.expectEqualStrings("http_requests_total{method=\"GET\"} 42\n", out.buffered());
}
