//! Must not compile: a histogram sample's labels go through the same check as a
//! plain sample's. Before the check ran on the histogram path, this compiled
//! and produced a line the parser rejects.

const std = @import("std");
const prometheus = @import("prometheus");

const Labels = struct { @"not-a-label": []const u8 };

test "a bad label name on a histogram does not compile" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.histogramFamily(&w, .{
        .name = "latency",
        .kind = .histogram,
        .limits = &.{1},
    }, &.{.{
        .labels = Labels{ .@"not-a-label" = "x" },
        .counts = &[_]u64{1},
        .sum = 1,
        .count = 1,
    }});
}
