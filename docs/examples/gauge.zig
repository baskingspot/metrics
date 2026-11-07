const std = @import("std");
const metrics = @import("metrics");

test "a gauge records a number that moves both ways" {
    var in_flight: metrics.gauge.Local(i64) = .zero;
    in_flight.inc();
    in_flight.add(4);
    in_flight.sub(6);

    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w: metrics.prometheus.Writer = .init(&out);
    try w.writeMetric("builds_in_flight", .{ .stage = "link" }, in_flight.get());

    try std.testing.expectEqualStrings("builds_in_flight{stage=\"link\"} -1\n", out.buffered());
}
