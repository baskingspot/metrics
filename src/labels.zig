//! The `{name="value",...}` group on a sample line.
//!
//! A label name comes from a struct field, so it is comptime-known and an
//! illegal one is a compile error, not a runtime one. Fields are written in
//! declaration order: the format does not care, but a stable order keeps two
//! renders of the same series diffable.

const std = @import("std");
const Io = std.Io;

const compat = @import("compat.zig");
const escaping = @import("escape.zig");

pub const Error = error{InvalidUtf8};

/// Write `{k="v"}` for a struct with fields, and nothing at all for one
/// without. A zero-label sample is `name 1`, not `name{} 1`: both parse, and
/// the bare form is what every other client emits.
pub fn writeGroup(w: *Io.Writer, labels: anytype) (Io.Writer.Error || Error)!void {
    const LabelStruct = @TypeOf(labels);
    if (comptime compat.fieldCount(LabelStruct) == 0) return;
    try w.writeByte('{');
    try writeFields(w, labels);
    try w.writeByte('}');
}

/// Write `k="v",k="v"` with no braces and no trailing comma, for a caller that
/// adds a label of its own. A histogram's `le` is the reason.
pub fn writeFields(w: *Io.Writer, labels: anytype) (Io.Writer.Error || Error)!void {
    const LabelStruct = @TypeOf(labels);
    if (comptime compat.fieldCount(LabelStruct) == 0) return;
    inline for (0..comptime compat.fieldCount(LabelStruct)) |i| {
        const label_name = comptime compat.fieldName(LabelStruct, i);
        if (i > 0) try w.writeByte(',');
        try w.writeAll(label_name);
        try w.writeAll("=\"");
        try writeLabelValue(w, @field(labels, label_name));
        try w.writeByte('"');
    }
}

fn writeLabelValue(w: *Io.Writer, label: anytype) (Io.Writer.Error || Error)!void {
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
