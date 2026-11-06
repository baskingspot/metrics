//! Prometheus text exposition format for Zig: write metrics to any writer, no
//! HTTP.
//!
//! A cursor for laying down lines, not a family model. `writeMetric` writes one
//! line, `writeFamily` writes the `# HELP` and `# TYPE` lines and hands back a
//! writer for that family's samples, and `writeHistogram` writes a whole classic
//! histogram. Ordering, which families appear, and whether a family gets help
//! text at all are the caller's business.
//!
//! Names and label names are comptime, so a name a parser would reject does not
//! compile. Everything else is the sink's: `std.Io.Writer` is the only error.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const compat = @import("compat.zig");
const escaping = @import("escape.zig");
const names = @import("name.zig");
const values = @import("value.zig");

/// The `# TYPE` line's vocabulary.
pub const Kind = enum { counter, gauge, histogram, untyped };

/// One family: the name, its kind, and the help text. The name and kind are
/// read at comptime, which is where a bad one is caught.
// ast-grep-ignore: public-struct-field-default -- a descriptor: the options bag at the call site
pub const Metric = struct {
    name: []const u8,
    kind: Kind,
    help: []const u8 = "",
};

/// A family's samples, from the value `writeFamily` handed back.
pub fn FamilyWriter(comptime m: Metric) type {
    return struct {
        const Self = @This();

        writer: *Io.Writer,

        /// One sample line, under the name and labels of the family.
        pub fn write(self: Self, label_values: anytype, value: anytype) Io.Writer.Error!void {
            return writeMetric(self.writer, m.name, label_values, value);
        }
    };
}

/// Write `# HELP` and `# TYPE` for a family and return the writer its samples
/// go through. HELP is the caller's choice: an empty one writes the line
/// without text.
pub fn writeFamily(w: *Io.Writer, comptime m: Metric) Io.Writer.Error!FamilyWriter(m) {
    comptime checkName(m.name);
    try w.writeAll("# HELP ");
    try w.writeAll(m.name);
    if (m.help.len > 0) {
        try w.writeByte(' ');
        try escaping.writeHelpText(w, m.help);
    }
    try w.writeByte('\n');
    try w.writeAll("# TYPE ");
    try w.writeAll(m.name);
    try w.writeByte(' ');
    try w.writeAll(@tagName(m.kind));
    try w.writeByte('\n');
    return .{ .writer = w };
}

/// Write one sample line: the name, the labels, the value, and a newline. No
/// header, and no statement about what came before it.
pub fn writeMetric(
    w: *Io.Writer,
    comptime name: []const u8,
    label_values: anytype,
    value: anytype,
) Io.Writer.Error!void {
    comptime checkName(name);
    try w.writeAll(name);
    try writeLabels(w, label_values);
    try w.writeByte(' ');
    try values.write(w, value);
    try w.writeByte('\n');
}

/// Write a whole classic histogram: the header, one `_bucket` line per limit,
/// the implicit `+Inf` bucket from `count`, then `_sum` and `_count`.
///
/// The counts are cumulative and one per limit. Nothing here checks that the
/// caller's counters are monotone or that they agree with `count`; that is the
/// caller's business, and a debug assertion catches a length mismatch.
pub fn writeHistogram(
    w: *Io.Writer,
    comptime m: Metric,
    label_values: anytype,
    limits: []const f64,
    counts: []const u64,
    sum: f64,
    count: u64,
) Io.Writer.Error!void {
    comptime if (m.kind != .histogram) {
        @compileError("prometheus: writeHistogram needs a Metric whose kind is .histogram");
    };
    comptime if (@hasField(@TypeOf(label_values), "le")) {
        @compileError("prometheus: a histogram label set cannot contain \"le\", which this writes");
    };
    assert(counts.len == limits.len);

    _ = try writeFamily(w, m);
    var le_buffer: [value_buffer_size]u8 = undefined;
    for (limits, counts) |limit, bucket_count| {
        try w.writeAll(m.name);
        try w.writeAll("_bucket{");
        try writeLabelFields(w, label_values);
        if (comptime compat.fieldCount(@TypeOf(label_values)) > 0) try w.writeByte(',');
        try w.writeAll("le=\"");
        try w.writeAll(values.format(&le_buffer, limit));
        try w.writeAll("\"} ");
        try w.print("{d}", .{bucket_count});
        try w.writeByte('\n');
    }
    try w.writeAll(m.name);
    try w.writeAll("_bucket{");
    try writeLabelFields(w, label_values);
    if (comptime compat.fieldCount(@TypeOf(label_values)) > 0) try w.writeByte(',');
    try w.writeAll("le=\"+Inf\"} ");
    try w.print("{d}", .{count});
    try w.writeByte('\n');
    try writeSuffixed(w, m.name, "_sum", label_values, sum);
    try writeSuffixed(w, m.name, "_count", label_values, count);
}

fn writeSuffixed(
    w: *Io.Writer,
    comptime name: []const u8,
    comptime suffix: []const u8,
    label_values: anytype,
    value: anytype,
) Io.Writer.Error!void {
    try w.writeAll(name);
    try w.writeAll(suffix);
    try writeLabels(w, label_values);
    try w.writeByte(' ');
    try values.write(w, value);
    try w.writeByte('\n');
}

fn writeLabels(w: *Io.Writer, label_values: anytype) Io.Writer.Error!void {
    const LabelStruct = @TypeOf(label_values);
    if (comptime compat.fieldCount(LabelStruct) == 0) return;
    try w.writeByte('{');
    try writeLabelFields(w, label_values);
    try w.writeByte('}');
}

/// The pairs without braces, for a line that adds a label of its own: a
/// histogram's `le`.
fn writeLabelFields(w: *Io.Writer, label_values: anytype) Io.Writer.Error!void {
    const LabelStruct = @TypeOf(label_values);
    inline for (0..comptime compat.fieldCount(LabelStruct)) |i| {
        const label_name = comptime compat.fieldName(LabelStruct, i);
        if (i > 0) try w.writeByte(',');
        comptime checkLabelName(label_name);
        try w.writeAll(label_name);
        try w.writeAll("=\"");
        try writeLabelValue(w, @field(label_values, label_name));
        try w.writeByte('"');
    }
}

fn writeLabelValue(w: *Io.Writer, label: anytype) Io.Writer.Error!void {
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

fn checkName(comptime name: []const u8) void {
    comptime if (!names.isValidMetricName(name)) {
        @compileError("prometheus: metric name \"" ++ name ++
            "\" is not [a-zA-Z_:][a-zA-Z0-9_:]*");
    };
}

fn checkLabelName(comptime label_name: []const u8) void {
    comptime if (names.hasReservedPrefix(label_name)) {
        @compileError("prometheus: label name \"" ++ label_name ++
            "\" starts with \"__\", which is reserved");
    };
    comptime if (!names.isValidLabelName(label_name)) {
        @compileError("prometheus: label name \"" ++ label_name ++
            "\" is not [a-zA-Z_][a-zA-Z0-9_]*");
    };
}

/// Longest formatted value or `le` this writes.
pub const value_buffer_size = values.buffer_size;

test {
    // The unit tests live beside the code they cover, and this pulls them into
    // the module's one test binary.
    _ = @import("escape.zig");
    _ = @import("name.zig");
    _ = @import("value.zig");
}
