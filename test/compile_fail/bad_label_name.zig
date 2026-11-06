//! Must not compile: a label name is a struct field, and a field written as a
//! quoted identifier can hold a name the format does not allow.

const std = @import("std");
const prometheus = @import("prometheus");

const Labels = struct { @"not-a-label": u8 };

test "a label name outside the grammar does not compile" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try prometheus.writeMetric(&w, "ok", Labels{ .@"not-a-label" = 1 }, 1);
}
