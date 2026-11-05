const std = @import("std");
const prometheus = @import("prometheus");

test "a fixed buffer allocates nothing" {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try prometheus.sample(&w, "up", .{}, 1);

    try std.testing.expectEqualStrings("up 1\n", w.buffered());
}
