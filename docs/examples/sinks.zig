const std = @import("std");
const prometheus = @import("prometheus");

test "a fixed buffer, one line at a time" {
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);

    try prometheus.writeMetric(&w, "up", .{}, 1);

    try std.testing.expectEqualStrings("up 1\n", out.buffered());
}

test "an allocating writer grows a body you own" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var w = prometheus.Writer.init(&buffer.writer);

    try prometheus.writeMetric(&w, "up", .{}, 1);

    try std.testing.expectEqualStrings("up 1\n", buffer.written());
}
