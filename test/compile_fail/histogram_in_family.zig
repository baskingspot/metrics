//! Must not compile: `family` writes plain sample lines, and a histogram
//! family's samples are bucket lines. The kind is comptime, so the mistake is a
//! compile error instead of a document with the wrong bytes.

const std = @import("std");
const prometheus = @import("prometheus");

test "a histogram family cannot go through family" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    _ = try prometheus.family(&w, .{ .name = "requests", .kind = .histogram });
}
