//! Must not compile: `__name__` is the series name, which the parser reserves
//! as a label, and every `__` name belongs to a reserved namespace.

const std = @import("std");
const prometheus = @import("prometheus");

test "a label name in the reserved namespace does not compile" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.family(&w, .{ .name = "jobs_total", .kind = .counter }, &.{
        .{ .labels = .{ .__name__ = "other" }, .value = 1 },
    });
}
