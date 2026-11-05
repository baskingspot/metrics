const std = @import("std");
const prometheus = @import("prometheus");

test "a fixed buffer allocates nothing" {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try prometheus.family(&w, .{ .name = "up", .kind = .gauge }, &.{
        .{ .labels = .{}, .value = 1 },
    });

    try std.testing.expectEqualStrings("# TYPE up gauge\nup 1\n", w.buffered());
}

test "an allocating writer grows a body you own" {
    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    try prometheus.family(&w.writer, .{ .name = "up", .kind = .gauge }, &.{
        .{ .labels = .{}, .value = 1 },
    });

    try std.testing.expectEqualStrings("# TYPE up gauge\nup 1\n", w.written());
}
