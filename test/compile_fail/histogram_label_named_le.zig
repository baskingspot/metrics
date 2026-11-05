//! Must not compile: the bucket writer adds `le` itself, and a second one is a
//! duplicate label name that the parser rejects.

const std = @import("std");
const prometheus = @import("prometheus");

const Labels = struct { le: u8 };

test "a histogram label set cannot carry le" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.histogramFamily(&w, .{ .name = "x", .kind = .histogram }, &.{.{
        .labels = Labels{ .le = 1 },
        .counts = &[_]u64{},
        .sum = 0,
        .count = 0,
    }});
}
