//! Must not compile: `__name__` is the series name, which the parser reserves
//! as a label, and every `__` name belongs to a reserved namespace.

const std = @import("std");
const prometheus = @import("prometheus");

test "a label name in the reserved namespace does not compile" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try w.writeMetric("jobs_total", .{ .__name__ = "other" }, 1);
}
