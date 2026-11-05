//! A metric family: its header and every one of its samples, written in one
//! call.
//!
//! The one-call shape is what makes contiguity a fact. A handle that a caller
//! writes through one sample at a time cannot hold that line, because a
//! `*std.Io.Writer` is copyable and two live handles interleave no matter what
//! the type system is asked to do. Here there is no object to leak.
//!
//! Two doors, one core. The comptime door (`family`, `histogramFamily`) is the
//! default: it turns a bad metric name, a bad label name, a wrong kind, an `le`
//! collision, and bad limits into compile errors, and it writes the header as
//! one precomputed literal. The `runtime` door validates the same things at run
//! time, for a name composed at runtime or an embedder's prefix. Both doors run
//! the same emitters, so the bytes cannot drift.

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
// ast-grep-ignore: public-struct-field-default -- a family descriptor: the options bag at the call site
limits: []const f64 = &.{},

pub const Kind = enum { counter, gauge, histogram, untyped };

/// Which door the call came through. It decides what a failed check does, and
/// nothing else: the emitter below is the same for both.
pub const Door = enum { compile_time, runtime };

/// What the caller is asking to write, so one validator can tell the two
/// entry points apart.
const Work = enum { samples, histograms };

/// Longest `le` the value writer can produce for an f64 is 24 bytes.
const le_size = 32;

// -- Comptime door ---------------------------------------------------------

pub fn writeSamples(
    comptime self: Family,
    w: *Io.Writer,
    samples: anytype,
) errors.Error!void {
    comptime checkComptime(self, .samples);
    try w.writeAll(comptime headerBlock(self));
    try emitSamples(w, .compile_time, self.name, samples);
}

pub fn writeHistograms(
    comptime self: Family,
    w: *Io.Writer,
    histograms: anytype,
) errors.Error!void {
    comptime checkComptime(self, .histograms);
    try w.writeAll(comptime headerBlock(self));
    try emitHistograms(w, .compile_time, self.name, self.limits, comptime leTexts(self.limits), histograms);
}

// -- Runtime door ----------------------------------------------------------

pub fn writeSamplesRuntime(self: Family, w: *Io.Writer, samples: anytype) errors.Error!void {
    try checkRuntime(self, .samples);
    try writeHeaderLines(w, self);
    try emitSamples(w, .runtime, self.name, samples);
}

pub fn writeHistogramsRuntime(self: Family, w: *Io.Writer, histograms: anytype) errors.Error!void {
    try checkRuntime(self, .histograms);
    try writeHeaderLines(w, self);
    try emitHistograms(w, .runtime, self.name, self.limits, null, histograms);
}

// -- The emitter, shared by both doors -------------------------------------

fn emitSamples(
    w: *Io.Writer,
    comptime door: Door,
    name: []const u8,
    samples: anytype,
) errors.Error!void {
    // A slice, an array, and a tuple are all legal here. A tuple's elements can
    // have different label structs, so it needs an unrolled loop; the element
    // work below is written once either way.
    if (comptime isTuple(@TypeOf(samples))) {
        inline for (samples) |sample| try emitSample(w, door, name, sample);
    } else {
        for (samples) |sample| try emitSample(w, door, name, sample);
    }
}

fn emitSample(
    w: *Io.Writer,
    comptime door: Door,
    name: []const u8,
    sample: anytype,
) errors.Error!void {
    if (comptime door == .compile_time) {
        comptime checkLabelNamesComptime(@TypeOf(sample.labels));
    } else {
        try checkLabelNamesRuntime(@TypeOf(sample.labels));
    }
    try writeSampleLine(w, name, sample.labels, sample.value);
}

fn writeSampleLine(
    w: *Io.Writer,
    name: []const u8,
    label_values: anytype,
    value: anytype,
) errors.Error!void {
    try w.writeAll(name);
    try labels.writeGroup(w, label_values);
    try w.writeByte(' ');
    try values.write(w, value);
    try w.writeByte('\n');
}

fn emitHistograms(
    w: *Io.Writer,
    comptime door: Door,
    name: []const u8,
    limits: []const f64,
    comptime le_table: anytype,
    histograms: anytype,
) errors.Error!void {
    if (comptime isTuple(@TypeOf(histograms))) {
        inline for (histograms) |histogram| {
            try emitHistogram(w, door, name, limits, le_table, histogram);
        }
    } else {
        for (histograms) |histogram| try emitHistogram(w, door, name, limits, le_table, histogram);
    }
}

fn emitHistogram(
    w: *Io.Writer,
    comptime door: Door,
    name: []const u8,
    limits: []const f64,
    comptime le_table: anytype,
    histogram: anytype,
) errors.Error!void {
    if (comptime door == .compile_time) {
        comptime checkNoLeComptime(@TypeOf(histogram.labels));
    } else {
        try checkNoLeRuntime(@TypeOf(histogram.labels));
    }
    const counts = histogram.counts;
    try checkCounts(limits, counts, histogram.count);

    var le_buffer: [le_size]u8 = undefined;
    if (comptime isTuple(@TypeOf(counts))) {
        inline for (counts, 0..) |count, i| {
            try writeBucket(w, name, histogram.labels, limits, le_table, &le_buffer, count, i);
        }
    } else {
        for (counts, 0..) |count, i| {
            try writeBucket(w, name, histogram.labels, limits, le_table, &le_buffer, count, i);
        }
    }
    // The implicit bucket. `checkCounts` has proven its count equals the last
    // cumulative count.
    try writeBucketLine(w, name, histogram.labels, "+Inf", histogram.count);
    try writeSuffixed(w, name, "_sum", histogram.labels, histogram.sum);
    try writeSuffixed(w, name, "_count", histogram.labels, histogram.count);
}

fn writeBucketLine(
    w: *Io.Writer,
    name: []const u8,
    label_values: anytype,
    le: []const u8,
    count: u64,
) errors.Error!void {
    try w.writeAll(name);
    try w.writeAll("_bucket{");
    try labels.writeFields(w, label_values);
    if (comptime compat.fieldCount(@TypeOf(label_values)) > 0) try w.writeByte(',');
    try w.writeAll("le=\"");
    try w.writeAll(le);
    try w.writeAll("\"} ");
    try w.print("{d}", .{count});
    try w.writeByte('\n');
}

fn writeBucket(
    w: *Io.Writer,
    name: []const u8,
    label_values: anytype,
    limits: []const f64,
    comptime le_table: anytype,
    le_buffer: *[le_size]u8,
    count: u64,
    index: usize,
) errors.Error!void {
    // A comptime family with no limits has an empty table, and indexing an
    // empty array is a compile error even where the loop never runs.
    const use_table = comptime blk: {
        if (@TypeOf(le_table) == @TypeOf(null)) break :blk false;
        break :blk le_table.len > 0;
    };
    const le = if (comptime use_table)
        std.mem.sliceTo(&le_table[index], 0)
    else
        formatLe(le_buffer, limits[index]);
    try writeBucketLine(w, name, label_values, le, count);
}

fn writeSuffixed(
    w: *Io.Writer,
    name: []const u8,
    comptime suffix: []const u8,
    label_values: anytype,
    value: anytype,
) errors.Error!void {
    try w.writeAll(name);
    try w.writeAll(suffix);
    try labels.writeGroup(w, label_values);
    try w.writeByte(' ');
    try values.write(w, value);
    try w.writeByte('\n');
}

/// True for a tuple, and for a pointer to one: `&.{ ... }` is a pointer to a
/// tuple, and a tuple's elements may have different types, so it needs the
/// unrolled loop the caller chooses.
fn isTuple(comptime T: type) bool {
    const child = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
    const info = @typeInfo(child);
    return std.meta.activeTag(info) == .@"struct" and info.@"struct".is_tuple;
}

// -- Headers ---------------------------------------------------------------

fn headerBlock(comptime f: Family) []const u8 {
    comptime {
        const type_line = "# TYPE " ++ f.name ++ " " ++ @tagName(f.kind) ++ "\n";
        if (f.help.len == 0) return type_line;
        const help_line = "# HELP " ++ f.name ++ " " ++ escaping.escapeHelp(f.help) ++ "\n";
        return help_line ++ type_line;
    }
}

fn writeHeaderLines(w: *Io.Writer, f: Family) errors.Error!void {
    if (f.help.len > 0) {
        try w.writeAll("# HELP ");
        try w.writeAll(f.name);
        try w.writeByte(' ');
        try escaping.writeHelpText(w, f.help);
        try w.writeByte('\n');
    }
    try w.writeAll("# TYPE ");
    try w.writeAll(f.name);
    try w.writeByte(' ');
    try w.writeAll(@tagName(f.kind));
    try w.writeByte('\n');
}

/// The `le` values for a comptime family, formatted once at compile time.
fn leTexts(comptime limits: []const f64) [limits.len][le_size]u8 {
    comptime {
        var table: [limits.len][le_size]u8 = @splat(@splat(0));
        for (limits, 0..) |limit, i| {
            var w: Io.Writer = .fixed(&table[i]);
            values.writeFloat(&w, limit) catch unreachable;
        }
        return table;
    }
}

fn formatLe(buffer: *[le_size]u8, limit: f64) []const u8 {
    var w: Io.Writer = .fixed(buffer);
    values.writeFloat(&w, limit) catch unreachable;
    return w.buffered();
}

// -- Validation, one predicate per rule ------------------------------------

fn checkComptime(comptime f: Family, comptime work: Work) void {
    comptime if (!names.isValidMetricName(f.name)) {
        @compileError("prometheus: metric name \"" ++ f.name ++
            "\" is not [a-zA-Z_:][a-zA-Z0-9_:]*");
    };
    comptime if (!std.unicode.utf8ValidateSlice(f.help)) {
        @compileError("prometheus: the HELP text of \"" ++ f.name ++ "\" is not valid UTF-8");
    };
    comptime if (work == .samples and f.kind == .histogram) {
        @compileError("prometheus: \"" ++ f.name ++
            "\" is a histogram, so it is written by histogramFamily");
    };
    comptime if (work == .histograms and f.kind != .histogram) {
        @compileError("prometheus: histogramFamily needs a family whose kind is .histogram");
    };
    comptime if (work == .histograms) {
        if (checkLimits(f.limits)) |_| {} else |_| {
            @compileError("prometheus: histogram limits must be finite and strictly ascending");
        }
    };
}

fn checkRuntime(f: Family, work: Work) errors.Error!void {
    if (!names.isValidMetricName(f.name)) return error.InvalidMetricName;
    if (!std.unicode.utf8ValidateSlice(f.help)) return error.InvalidLabelValue;
    switch (work) {
        .samples => if (f.kind == .histogram) return error.MismatchedKind,
        .histograms => if (f.kind != .histogram) return error.MismatchedKind,
    }
    if (work == .histograms) try checkLimits(f.limits);
}

fn checkLabelNamesComptime(comptime LabelStruct: type) void {
    inline for (0..comptime compat.fieldCount(LabelStruct)) |i| {
        const label_name = comptime compat.fieldName(LabelStruct, i);
        comptime if (!names.isValidLabelName(label_name)) {
            @compileError("prometheus: label name \"" ++ label_name ++
                "\" is not [a-zA-Z_][a-zA-Z0-9_]*");
        };
    }
}

fn checkLabelNamesRuntime(comptime LabelStruct: type) errors.Error!void {
    inline for (0..comptime compat.fieldCount(LabelStruct)) |i| {
        const label_name = comptime compat.fieldName(LabelStruct, i);
        if (comptime !names.isValidLabelName(label_name)) return error.InvalidLabelName;
    }
}

fn checkNoLeComptime(comptime LabelStruct: type) void {
    comptime if (@hasField(LabelStruct, "le")) {
        @compileError("prometheus: a histogram label set cannot contain \"le\", which this writes");
    };
}

fn checkNoLeRuntime(comptime LabelStruct: type) errors.Error!void {
    if (comptime @hasField(LabelStruct, "le")) return error.DuplicateLabel;
}

/// Strictly ascending and finite, so no `NaN`, no repeat, and no `+Inf`, which
/// the implicit bucket already owns.
fn checkLimits(limits: []const f64) error{InvalidHistogram}!void {
    var previous: f64 = -std.math.inf(f64);
    for (limits) |limit| {
        if (!std.math.isFinite(limit) or !(limit > previous)) return error.InvalidHistogram;
        previous = limit;
    }
}

/// Cumulative counts, one per limit, ending at the total. The counts are
/// whatever the caller has: a slice, a fixed array, or a tuple literal.
fn checkCounts(
    limits: []const f64,
    counts: anytype,
    total: u64,
) error{InvalidHistogram}!void {
    if (counts.len != limits.len) return error.InvalidHistogram;
    var previous: u64 = 0;
    if (comptime isTuple(@TypeOf(counts))) {
        inline for (counts, 0..) |count, i| try checkCount(&previous, count, i);
    } else {
        for (counts, 0..) |count, i| try checkCount(&previous, count, i);
    }
    if (counts.len > 0 and counts[counts.len - 1] != total) return error.InvalidHistogram;
}

fn checkCount(previous: *u64, count: u64, index: usize) error{InvalidHistogram}!void {
    if (index > 0 and count < previous.*) return error.InvalidHistogram;
    previous.* = count;
}
