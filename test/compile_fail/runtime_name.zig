//! Must not compile: the comptime door needs the descriptor at comptime, which
//! is what makes its checks compile-time. A composed name goes through
//! `prometheus.runtime`.

const std = @import("std");
const prometheus = @import("prometheus");

test "a name that is not comptime-known does not compile" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    var prefix: []const u8 = "acme_";
    _ = &prefix;
    try prometheus.family(&w, .{ .name = prefix, .kind = .counter }, &.{});
}
