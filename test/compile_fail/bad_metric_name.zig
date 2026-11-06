//! Must not compile: the legacy metric name grammar is checked at comptime and
//! the error names the metric.

const std = @import("std");
const prometheus = @import("prometheus");

test "a metric name that starts with a digit does not compile" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try prometheus.writeMetric(&w, "1_requests", .{}, 1);
}
