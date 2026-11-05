//! Prometheus text exposition format for Zig: write metrics to any writer, no
//! HTTP.
//!
//! One sample line, and later one family at a time. The sink is any
//! `std.Io.Writer`, so a buffer, a file, and a socket are the caller's problem
//! and this module never sees a socket.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const compat = @import("compat.zig");
const escaping = @import("escape.zig");
const names = @import("name.zig");
const values = @import("value.zig");

/// What every writer in this module can fail with: the sink's own failure, plus
/// the two input checks that keep one caller's typo out of a document.
pub const Error = Io.Writer.Error || error{ InvalidName, InvalidUtf8 };

/// Write one sample line: `name{label="value"} 1` and a newline.
///
/// Labels come from a struct, in field order, so a field name is a label name
/// and an illegal one does not compile. This writes no header; a document whose
/// samples need `# HELP` and `# TYPE` uses `family`.
pub fn sample(w: *Io.Writer, name: []const u8, labels: anytype, value: anytype) Error!void {
    try names.checkMetricName(name);
    try w.writeAll(name);
    if (comptime compat.fieldCount(@TypeOf(labels)) > 0) {
        try w.writeByte('{');
        try writeLabels(w, labels);
        try w.writeByte('}');
    }
    try w.writeByte(' ');
    try values.write(w, value);
    try w.writeByte('\n');
}

fn writeLabels(w: *Io.Writer, labels: anytype) Error!void {
    const LabelStruct = @TypeOf(labels);
    inline for (0..comptime compat.fieldCount(LabelStruct)) |i| {
        const label_name = comptime compat.fieldName(LabelStruct, i);
        comptime if (!names.validLabelName(label_name)) {
            @compileError("prometheus: label name \"" ++ label_name ++
                "\" is not [a-zA-Z_][a-zA-Z0-9_]*");
        };
        if (i > 0) try w.writeByte(',');
        try w.writeAll(label_name);
        try w.writeAll("=\"");
        try writeLabelValue(w, @field(labels, label_name));
        try w.writeByte('"');
    }
}

fn writeLabelValue(w: *Io.Writer, label: anytype) Error!void {
    return switch (@typeInfo(@TypeOf(label))) {
        .int, .comptime_int => w.print("{d}", .{label}),
        // A string literal arrives as `*const [N:0]u8` and a struct field as
        // `[]const u8`; both coerce to the same slice.
        .pointer => escaping.writeLabelValue(w, label),
        else => @compileError(
            "prometheus: a label value is an integer or a string, not " ++
                @typeName(@TypeOf(label)),
        ),
    };
}

fn expectRender(expected: []const u8, metric: []const u8, labels: anytype, value: anytype) !void {
    var buffer: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try sample(&w, metric, labels, value);
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
