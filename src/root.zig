//! Prometheus text exposition format for Zig: write metrics to any writer, no
//! HTTP.
//!
//! One sample line, or one family at a time with its header written once. The
//! sink is any `std.Io.Writer`, so a buffer, a file, and a socket are the
//! caller's problem and this module never sees a socket.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const errors = @import("errors.zig");
/// What every writer in this module can fail with: the sink's own failure, plus
/// the two input checks that keep one caller's typo out of a document.
pub const Error = errors.Error;
pub const Family = @import("Family.zig");
const labels = @import("labels.zig");
const names = @import("name.zig");
const values = @import("value.zig");

/// Write one sample line: `name{label="value"} 1` and a newline.
///
/// This writes no header. A document whose samples need `# HELP` and `# TYPE`
/// uses `family`.
pub fn sample(w: *Io.Writer, name: []const u8, labels_: anytype, value: anytype) Error!void {
    try names.checkMetricName(name);
    try w.writeAll(name);
    try labels.writeGroup(w, labels_);
    try w.writeByte(' ');
    try values.write(w, value);
    try w.writeByte('\n');
}

/// Write the family's header and return the handle its samples are written
/// through. The name and kind are comptime, so a histogram here or an illegal
/// metric name does not compile.
pub fn family(w: *Io.Writer, comptime f: Family) Error!Family.Samples {
    return f.writeHeader(w);
}

fn expectRender(expected: []const u8, metric: []const u8, labels_: anytype, value: anytype) !void {
    var buffer: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try sample(&w, metric, labels_, value);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "a labeled sample" {
    try expectRender(
        "requests_total{method=\"GET\",status=\"200\"} 1841\n",
        "requests_total",
        .{ .method = "GET", .status = "200" },
        1841,
    );
}

test "an unlabeled sample" {
    try expectRender("up 1\n", "up", .{}, 1);
    const NoLabels = struct {};
    try expectRender("up 0\n", "up", NoLabels{}, 0);
}

test "integer label values are decimal inside the quotes" {
    try expectRender("a{port=\"5432\"} 1\n", "a", .{ .port = 5432 }, 1);
    try expectRender("a{port=\"0\"} 1\n", "a", .{ .port = 0 }, 1);
}

test "a label value escapes backslash quote and newline" {
    try expectRender(
        "a{k=\"x\\\\y\\\"z\\nw\"} 1\n",
        "a",
        .{ .k = "x\\y\"z\nw" },
        1,
    );
}

test "a label value leaves tab carriage return NUL and emoji raw" {
    try expectRender("a{k=\"\t\r\x00z🦎\"} 1\n", "a", .{ .k = "\t\r\x00z🦎" }, 1);
}

test "invalid UTF-8 in a label value is an error, not bytes" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const bad: []const u8 = &.{ 0xff, 0xfe };
    try testing.expectError(error.InvalidUtf8, sample(&w, "a", .{ .k = bad }, 1));
    try testing.expectEqualStrings("a{k=\"", w.buffered());
}

test "a metric name outside the legacy charset is an error" {
    var buffer: [64]u8 = undefined;
    const bad = [_][]const u8{ "", "1a", "a-b", "a b", "é", "a.b" };
    for (bad) |metric| {
        var w: Io.Writer = .fixed(&buffer);
        try testing.expectError(error.InvalidName, sample(&w, metric, .{}, 1));
    }
    const good = [_][]const u8{ "a", "_a", ":a", "a:b", "a_1", "A9" };
    for (good) |metric| {
        var w: Io.Writer = .fixed(&buffer);
        try sample(&w, metric, .{}, 1);
    }
}

test "every sample line ends with a newline" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try sample(&w, "a", .{ .k = "v" }, 1.5);
    try sample(&w, "b", .{}, std.math.nan(f64));
    try testing.expectEqual(@as(u8, '\n'), w.buffered()[w.buffered().len - 1]);
}

test "a document written family by family has contiguous samples" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);

    const first = try family(&w, .{
        .name = "first_total",
        .kind = .counter,
        .help = "First family.",
    });
    try first.write(.{ .k = "a" }, 1);
    try first.write(.{ .k = "b" }, 2);

    const second = try family(&w, .{ .name = "second", .kind = .gauge });
    try second.write(.{}, 3);

    const third = try family(&w, .{ .name = "third_bytes", .kind = .untyped, .help = "" });
    try third.write(.{}, 4);

    try testing.expectEqualStrings(
        \\# HELP first_total First family.
        \\# TYPE first_total counter
        \\first_total{k="a"} 1
        \\first_total{k="b"} 2
        \\# TYPE second gauge
        \\second 3
        \\# TYPE third_bytes untyped
        \\third_bytes 4
        \\
    , w.buffered());
}

test "HELP escapes a backslash and a newline, not a quote" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const f = try family(&w, .{
        .name = "escaped",
        .kind = .gauge,
        .help = "a\\b\"c\nd",
    });
    try f.write(.{}, 1);
    try testing.expectEqualStrings(
        "# HELP escaped a\\\\b\"c\\nd\n# TYPE escaped gauge\nescaped 1\n",
        w.buffered(),
    );
}

test "an empty HELP writes no line" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const f = try family(&w, .{ .name = "bare", .kind = .counter, .help = "" });
    try f.write(.{}, 0);
    try testing.expectEqualStrings("# TYPE bare counter\nbare 0\n", w.buffered());
}

test "a family with no samples is its header alone" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    _ = try family(&w, .{ .name = "empty_total", .kind = .counter, .help = "Nothing yet." });
    try testing.expectEqualStrings(
        "# HELP empty_total Nothing yet.\n# TYPE empty_total counter\n",
        w.buffered(),
    );
}
