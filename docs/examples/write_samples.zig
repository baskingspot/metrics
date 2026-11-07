const std = @import("std");

const metrics = @import("metrics");

test "one family: the header, then its samples" {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w: metrics.prometheus.Writer = .init(&out);

    const requests = try w.writeFamily(.{
        .name = "http_requests_total",
        .kind = .counter,
        .help = "Requests served, by method and status.",
    });
    try requests.write(.{ .method = "GET", .status = "200" }, 1841);
    try requests.write(.{ .method = "POST", .status = "500" }, 3);

    try std.testing.expectEqualStrings(
        \\# HELP http_requests_total Requests served, by method and status.
        \\# TYPE http_requests_total counter
        \\http_requests_total{method="GET",status="200"} 1841
        \\http_requests_total{method="POST",status="500"} 3
        \\
    , out.buffered());
}
