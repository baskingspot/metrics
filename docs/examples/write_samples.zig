const std = @import("std");
const prometheus = @import("prometheus");

test "one family: the header once, then its samples" {
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    const requests = try prometheus.family(&w, .{
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
    , w.buffered());
}
