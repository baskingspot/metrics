//! The expfmt writer: the lowest layer, one field, no policy.
//!
//! Each method writes one expfmt record. `help` and `kind` write the comment
//! lines, `name` writes a name and its labels, `value` writes a value and ends
//! the line, and `line` writes bytes the caller formatted. Nothing here knows
//! about families, ordering, or which metric came before.
//!
//! This file imports nothing from `compose.zig`. Everything above it is built
//! out of these methods.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const compat = @import("compat.zig");
const escaping = @import("escape.zig");
const names = @import("name.zig");
const values = @import("value.zig");

/// The `# TYPE` line's vocabulary.
pub const Kind = enum { counter, gauge, histogram, untyped };

pub const Writer = struct {
    out: *Io.Writer,

    pub fn init(out: *Io.Writer) Writer {
        return .{ .out = out };
    }

    /// `# HELP name text`, with the text escaped. An empty text writes the line
    /// without a trailing space.
    pub fn help(self: Writer, comptime metric_name: []const u8, text: []const u8) Io.Writer.Error!void {
        comptime checkName(metric_name);
        try self.out.writeAll("# HELP ");
        try self.out.writeAll(metric_name);
        if (text.len > 0) {
            try self.out.writeByte(' ');
            try escaping.writeHelpText(self.out, text);
        }
        try self.out.writeByte('\n');
    }

    /// `# TYPE name kind`.
    pub fn kind(self: Writer, comptime metric_name: []const u8, type_kind: Kind) Io.Writer.Error!void {
        comptime checkName(metric_name);
        try self.out.writeAll("# TYPE ");
        try self.out.writeAll(metric_name);
        try self.out.writeByte(' ');
        try self.out.writeAll(@tagName(type_kind));
        try self.out.writeByte('\n');
    }

    /// `name{label="value",...}` with no trailing space. A struct gives its
    /// fields in order; a tuple of structs gives their fields in sequence, which
    /// is how a caller adds a label of its own to one it already has.
    pub fn name(self: Writer, comptime name_text: []const u8, labels: anytype) Io.Writer.Error!void {
        comptime checkName(name_text);
        try self.out.writeAll(name_text);
        if (comptime labelCount(@TypeOf(labels)) == 0) return;
        try self.out.writeByte('{');
        try writeLabelGroups(self.out, labels);
        try self.out.writeByte('}');
    }

    /// ` value` and the newline that ends the record. An integer type is
    /// written as decimal; a float follows the expfmt rule in `value.zig`.
    pub fn value(self: Writer, value_text: anytype) Io.Writer.Error!void {
        try self.out.writeByte(' ');
        try values.write(self.out, value_text);
        try self.out.writeByte('\n');
    }

    /// Bytes the caller already formatted. Written as given: no newline, no
    /// escaping.
    pub fn line(self: Writer, bytes: []const u8) Io.Writer.Error!void {
        try self.out.writeAll(bytes);
    }
};

/// Labels a struct, or a tuple of structs, holds.
fn labelCount(comptime T: type) usize {
    if (comptime !isTupleGroup(T)) return compat.fieldCount(T);
    var total: usize = 0;
    inline for (0..comptime compat.fieldCount(T)) |i| {
        total += compat.fieldCount(compat.FieldType(T, i));
    }
    return total;
}

fn writeLabelGroups(w: *Io.Writer, labels: anytype) Io.Writer.Error!void {
    if (comptime !isTupleGroup(@TypeOf(labels))) return writeLabelFields(w, labels, 0);
    var written: usize = 0;
    inline for (0..comptime compat.fieldCount(@TypeOf(labels))) |i| {
        const group = @field(labels, compat.fieldName(@TypeOf(labels), i));
        try writeLabelFields(w, group, written);
        written += comptime compat.fieldCount(@TypeOf(group));
    }
}

fn writeLabelFields(w: *Io.Writer, labels: anytype, offset: usize) Io.Writer.Error!void {
    const LabelStruct = @TypeOf(labels);
    inline for (0..comptime compat.fieldCount(LabelStruct)) |i| {
        const label_name = comptime compat.fieldName(LabelStruct, i);
        comptime checkLabelName(label_name);
        if (offset + i > 0) try w.writeByte(',');
        try w.writeAll(label_name);
        try w.writeAll("=\"");
        try writeLabelValue(w, @field(labels, label_name));
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

/// A value a caller may pass where one group of labels is expected: a struct,
/// or a tuple of structs.
fn isTupleGroup(comptime T: type) bool {
    const info = @typeInfo(T);
    return std.meta.activeTag(info) == .@"struct" and info.@"struct".is_tuple;
}

test {
    _ = @import("escape.zig");
    _ = @import("name.zig");
    _ = @import("value.zig");
}
