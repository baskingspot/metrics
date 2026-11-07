const std = @import("std");

const metrics = @import("metrics");

test "a label value with a quote, a newline, and a backslash" {
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w: metrics.prometheus.Writer = .init(&out);

    try w.writeMetric("worker_log", .{
        .message = "say \"hi\"\nthen\\leave",
    }, 1);

    try std.testing.expectEqualStrings(
        "worker_log{message=\"say \\\"hi\\\"\\nthen\\\\leave\"} 1\n",
        out.buffered(),
    );
}
