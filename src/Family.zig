//! One metric family: the header once, then its samples.
//!
//! A family is a value the caller describes. Writing the header hands back a
//! handle, and every sample line for that family goes through it, so a document
//! written one family at a time has each family's samples in one run. The
//! handle holds the writer it writes to, and the name it was opened with, so a
//! sample cannot be written under another family's name.

const std = @import("std");
const Io = std.Io;

const errors = @import("errors.zig");
const escaping = @import("escape.zig");
const labels = @import("labels.zig");
const names = @import("name.zig");
const values = @import("value.zig");

const Family = @This();

name: []const u8,
kind: Kind,
// ast-grep-ignore: public-struct-field-default -- a family descriptor: the options bag at the call site
help: []const u8 = "",

pub const Kind = enum { counter, gauge, histogram, untyped };

/// Where a family's samples are written. It exists only as the return value of
/// `family`, so a sample line always follows the header that describes it.
pub const Samples = struct {
    writer: *Io.Writer,
    name: []const u8,

    pub fn write(self: Samples, label_values: anytype, value: anytype) errors.Error!void {
        try self.writer.writeAll(self.name);
        try labels.writeGroup(self.writer, label_values);
        try self.writer.writeByte(' ');
        try values.write(self.writer, value);
        try self.writer.writeByte('\n');
    }
};

/// Write `# HELP` when the family has help text, then `# TYPE`, and return the
/// handle. Both the kind and the name are checked at comptime: a histogram
/// needs `histogramFamily`, which writes bucket lines this handle cannot.
pub fn writeHeader(comptime self: Family, w: *Io.Writer) errors.Error!Samples {
    comptime if (self.kind == .histogram) {
        @compileError("prometheus: a histogram family is written by histogramFamily");
    };
    comptime if (!names.validMetricName(self.name)) {
        @compileError("prometheus: metric name \"" ++ self.name ++
            "\" is not [a-zA-Z_:][a-zA-Z0-9_:]*");
    };

    if (self.help.len > 0) {
        try w.writeAll("# HELP ");
        try w.writeAll(self.name);
        try w.writeByte(' ');
        try escaping.writeHelpText(w, self.help);
        try w.writeByte('\n');
    }
    try w.writeAll("# TYPE ");
    try w.writeAll(self.name);
    try w.writeByte(' ');
    try w.writeAll(@tagName(self.kind));
    try w.writeByte('\n');
    return .{ .writer = w, .name = self.name };
}
