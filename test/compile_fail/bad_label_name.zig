//! Must not compile: a label name is a struct field, and a field written as a
//! quoted identifier can hold a name the format does not allow.

const std = @import("std");
const prometheus = @import("prometheus");

const BadLabels = struct { @"not-a-label": u8 };

test "a label name outside the grammar does not compile" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.sample(&w, "x", BadLabels{ .@"not-a-label" = 1 }, 1);
}
