//! Must not compile: the comptime door checks the legacy metric name grammar
//! and names the offending metric in the error.

const std = @import("std");
const prometheus = @import("prometheus");

test "a metric name that starts with a digit does not compile" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.family(&w, .{ .name = "1_requests", .kind = .counter }, &.{});
}
