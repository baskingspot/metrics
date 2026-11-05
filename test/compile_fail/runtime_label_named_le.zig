//! Must not compile: the `le` collision comes from a comptime type, so the
//! runtime door rejects it at compile time too. There is no runtime
//! `DuplicateLabel` a caller can hit.

const std = @import("std");
const prometheus = @import("prometheus");

const Labels = struct { le: u8 };

test "the runtime door rejects le at comptime as well" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.runtime.histogramFamily(&w, .{ .name = "x", .kind = .histogram }, &.{.{
        .labels = Labels{ .le = 1 },
        .counts = &[_]u64{},
        .sum = 0,
        .count = 0,
    }});
}
