const std = @import("std");
const prometheus = @import("prometheus");

test "a fixed buffer, one line at a time" {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try prometheus.writeMetric(&w, "up", .{}, 1);

    try std.testing.expectEqualStrings("up 1\n", w.buffered());
}

test "an allocating writer grows a body you own" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try prometheus.writeMetric(&w.writer, "up", .{}, 1);

    try std.testing.expectEqualStrings("up 1\n", w.written());
}
