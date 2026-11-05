//! Must not compile: the legacy metric name grammar is checked at comptime
//! when the name is comptime, so a name a parser would reject never ships.

const std = @import("std");
const prometheus = @import("prometheus");

test "a metric name that starts with a digit does not compile" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    _ = try prometheus.family(&w, .{ .name = "1_requests", .kind = .counter });
}
