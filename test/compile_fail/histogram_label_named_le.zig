//! Must not compile: the bucket writer adds `le` itself, and a second `le` is a
//! duplicate label name, which the parser rejects.

const std = @import("std");
const prometheus = @import("prometheus");

const Labels = struct { le: u8 };

test "a histogram label set cannot carry le" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const handle = try prometheus.histogramFamily(&w, .{ .name = "x", .kind = .histogram });
    try handle.write(Labels{ .le = 1 }, .{ .limits = &.{}, .counts = &.{}, .sum = 0, .count = 0 });
}
