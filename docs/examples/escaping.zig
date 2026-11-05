const std = @import("std");
const prometheus = @import("prometheus");

test "a label value with a quote, a newline, and a backslash" {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try prometheus.sample(&w, "worker_log", .{
        .message = "say \"hi\"\nthen\\leave",
    }, 1);

    try std.testing.expectEqualStrings(
        "worker_log{message=\"say \\\"hi\\\"\\nthen\\\\leave\"} 1\n",
        w.buffered(),
    );
}

test "invalid UTF-8 is an error, not a document" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    const bad: []const u8 = &.{ 0xff, 0xfe };
    try std.testing.expectError(
        error.InvalidUtf8,
        prometheus.sample(&w, "worker_log", .{ .message = bad }, 1),
    );
}
