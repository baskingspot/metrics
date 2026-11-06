//! Must not compile: a family descriptor is comptime, which is what makes the
//! name checks compile errors. A composed name is not expressible.

const std = @import("std");
const prometheus = @import("prometheus");

test "a name that is not comptime-known does not compile" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);

    var name: []const u8 = "acme_requests_total";
    _ = &name;
    _ = try w.writeFamily(.{ .name = name, .kind = .counter });
}
