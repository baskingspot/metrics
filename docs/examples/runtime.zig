const std = @import("std");
const prometheus = @import("prometheus");

/// A family whose name is composed at run time, which the comptime door
/// cannot see.
fn render(w: *std.Io.Writer, prefix: []const u8, service: []const u8) !void {
    var name_buffer: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}_{s}_requests_total", .{ prefix, service });

    try prometheus.runtime.family(w, .{
        .name = name,
        .kind = .counter,
        .help = "Requests served.",
    }, &.{.{ .labels = .{}, .value = 12 }});
}

test "the runtime door takes a composed name" {
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try render(&w, "acme", "gateway");

    try std.testing.expectEqualStrings(
        "# HELP acme_gateway_requests_total Requests served.\n" ++
            "# TYPE acme_gateway_requests_total counter\n" ++
            "acme_gateway_requests_total 12\n",
        w.buffered(),
    );
}

test "the runtime door reports a bad name instead of writing it" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidMetricName, prometheus.runtime.family(
        &w,
        .{ .name = "1_requests", .kind = .counter },
        &.{.{ .labels = .{}, .value = 12 }},
    ));
}
