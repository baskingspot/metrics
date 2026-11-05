//! One metric family: the header once, then its samples.
//!
//! A family is a value the caller describes. Writing the header hands back a
//! handle, and every sample line for that family goes through it, so a document
//! written one family at a time has each family's samples in one run. The
//! handle holds the writer it writes to, and the name it was opened with, so a
//! sample cannot be written under another family's name.
//!
//! A histogram family is the same deal with three names: `name_bucket` lines
//! carrying `le`, then `name_sum` and `name_count`. The caller keeps its
//! counters; this file decides the bytes.

const std = @import("std");
const Io = std.Io;

const compat = @import("compat.zig");
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

/// Where a histogram family's samples are written. Same contract as `Samples`,
/// with the bucket, sum, and count bytes this library owns.
pub const Histograms = struct {
    writer: *Io.Writer,
    name: []const u8,

    /// Write one line per limit, the implicit `+Inf` bucket, then `_sum` and
    /// `_count`. The counts are cumulative, as the format requires.
    pub fn write(self: Histograms, label_values: anytype, buckets: Buckets) errors.Error!void {
        comptime if (@hasField(@TypeOf(label_values), "le")) {
            @compileError("prometheus: a histogram label set cannot contain `le`, which this writes");
        };
        try buckets.validate();

        var le_buffer: [32]u8 = undefined;
        for (buckets.limits, buckets.counts) |limit, count| {
            var le_writer: Io.Writer = .fixed(&le_buffer);
            try values.writeFloat(&le_writer, limit);
            try self.writeBucket(label_values, le_writer.buffered(), count);
        }
        // The implicit bucket. Its count is the total, which `validate` has
        // already proven equals the last cumulative count.
        try self.writeBucket(label_values, "+Inf", buckets.count);
        try self.writeSuffixed(label_values, "_sum", buckets.sum);
        try self.writeSuffixed(label_values, "_count", buckets.count);
    }

    fn writeBucket(
        self: Histograms,
        label_values: anytype,
        le: []const u8,
        count: u64,
    ) errors.Error!void {
        const w = self.writer;
        try w.writeAll(self.name);
        try w.writeAll("_bucket{");
        try labels.writeFields(w, label_values);
        if (comptime compat.fieldCount(@TypeOf(label_values)) > 0) try w.writeByte(',');
        try w.writeAll("le=\"");
        try w.writeAll(le);
        try w.writeAll("\"} ");
        try w.print("{d}", .{count});
        try w.writeByte('\n');
    }

    fn writeSuffixed(
        self: Histograms,
        label_values: anytype,
        comptime suffix: []const u8,
        value: anytype,
    ) errors.Error!void {
        const w = self.writer;
        try w.writeAll(self.name);
        try w.writeAll(suffix);
        try labels.writeGroup(w, label_values);
        try w.writeByte(' ');
        try values.write(w, value);
        try w.writeByte('\n');
    }
};

/// What the caller hands the histogram writer: its own counters, and the bucket
/// boundaries it chose. `counts[i]` is the number of observations at or below
/// `limits[i]`, so the slice is cumulative and its last element is `count`.
pub const Buckets = struct {
    limits: []const f64,
    counts: []const u64,
    sum: f64,
    count: u64,

    pub const Error = error{InvalidBuckets};

    /// Every invariant the format needs, checked in every build mode. A
    /// histogram that emits wrong bytes is the failure this library exists to
    /// prevent, so a bad slice is an error rather than a vanishing assert.
    pub fn validate(self: Buckets) Error!void {
        if (self.counts.len != self.limits.len) return error.InvalidBuckets;
        if (self.counts.len == 0) return;

        var previous_limit: f64 = -std.math.inf(f64);
        var previous_count: u64 = 0;
        for (self.limits, self.counts) |limit, count| {
            // Written so a NaN limit fails, and a repeated limit fails, and a
            // limit of +Inf fails: the implicit bucket already owns that label.
            if (!std.math.isFinite(limit) or !(limit > previous_limit)) return error.InvalidBuckets;
            if (count < previous_count) return error.InvalidBuckets;
            previous_limit = limit;
            previous_count = count;
        }
        if (self.counts[self.counts.len - 1] != self.count) return error.InvalidBuckets;
    }
};

/// Write `# HELP` when the family has help text, then `# TYPE`, and return the
/// handle its samples use. Both the kind and the name are checked at comptime:
/// a histogram needs `histogramFamily`, which writes bucket lines this handle
/// cannot.
pub fn writeHeader(comptime self: Family, w: *Io.Writer) errors.Error!Samples {
    comptime if (self.kind == .histogram) {
        @compileError("prometheus: a histogram family is written by histogramFamily");
    };
    try self.writeLines(w);
    return .{ .writer = w, .name = self.name };
}

/// The same header for a histogram family, whose samples are bucket lines.
pub fn writeHistogramHeader(comptime self: Family, w: *Io.Writer) errors.Error!Histograms {
    comptime if (self.kind != .histogram) {
        @compileError("prometheus: histogramFamily needs a family whose kind is .histogram");
    };
    try self.writeLines(w);
    return .{ .writer = w, .name = self.name };
}

fn writeLines(comptime self: Family, w: *Io.Writer) errors.Error!void {
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
}
