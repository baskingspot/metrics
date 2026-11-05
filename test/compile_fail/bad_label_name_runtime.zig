//! Must not compile: a label name is a struct field, so it is comptime in both
//! doors. There is no runtime `InvalidLabelName`.

const std = @import("std");
const prometheus = @import("prometheus");

const Labels = struct { @"not-a-label": u8 };

test "the runtime door rejects a bad label name at comptime as well" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.runtime.family(&w, .{ .name = "x", .kind = .counter }, &.{
        .{ .labels = Labels{ .@"not-a-label" = 1 }, .value = 1 },
    });
}
