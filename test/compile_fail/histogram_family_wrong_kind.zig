//! Must not compile: `histogramFamily` writes `_bucket`, `_sum`, and `_count`
//! lines, which only belong to a family whose TYPE line says histogram.

const std = @import("std");
const prometheus = @import("prometheus");

test "histogramFamily on a counter family" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    _ = try prometheus.histogramFamily(&w, .{ .name = "requests_total", .kind = .counter });
}
