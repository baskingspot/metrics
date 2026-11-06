//! Must not compile: only a `Metric` whose kind is `.histogram` may be written
//! by `writeHistogram`, because `# TYPE` would otherwise disagree with the
//! `_bucket` lines below it.

const std = @import("std");
const prometheus = @import("prometheus");

test "writeHistogram rejects a counter metric" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prometheus.writeHistogram(&w, .{ .name = "requests_total", .kind = .counter }, .{}, &.{}, &[_]u64{}, 0, 0);
}
