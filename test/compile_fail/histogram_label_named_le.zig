//! Must not compile: the bucket writer adds `le` itself, and a second one is a
//! duplicate label name the parser rejects.

const std = @import("std");
const prometheus = @import("prometheus");

const Labels = struct { le: u8 };

test "a histogram label set cannot carry le" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.writeHistogram(&w, .{ .name = "x", .kind = .histogram }, Labels{ .le = 1 }, &.{}, &[_]u64{}, 0, 0);
}
