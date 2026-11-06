const std = @import("std");
const prometheus = @import("prometheus");

test "a label value with a quote, a newline, and a backslash" {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try prometheus.writeMetric(&w, "worker_log", .{
        .message = "say \"hi\"\nthen\\leave",
    }, 1);

    try std.testing.expectEqualStrings(
        "worker_log{message=\"say \\\"hi\\\"\\nthen\\\\leave\"} 1\n",
        w.buffered(),
    );
}
