//! The expfmt writer, and the compositions built on it.
//!
//! Two layers in one file, because Zig cannot add a method from another file
//! and methods on `Writer` are what the call sites want:
//!
//! - **Primitives.** `help`, `kind`, `name`, `value`, and `line` each write one
//!   expfmt record and nothing else. Nothing in this half knows about families,
//!   ordering, or which metric came before.
//! - **Compositions.** `writeMetric`, `writeFamily`, `writeHistogram`, and
//!   `writeHistogramSeries` write whole records out of the primitives only. The
//!   test `the composition is the primitives, byte for byte` is what holds them
//!   to it: a bucket line has to equal the same line written by hand through
//!   `name` and `value`.
//!
//! A caller that needs a shape this library does not have drops to the
//! primitives and gets the same values and escaping.

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

pub const Writer = struct {
    out: *Io.Writer,

    pub fn init(out: *Io.Writer) Writer {
        return .{ .out = out };
    }

    // -- Primitives ---------------------------------------------------------

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

    /// ` value` and the newline that ends the record. An integer type is written
    /// as decimal; a float follows the expfmt rule in `value.zig`.
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

    // -- Compositions, built only out of the primitives ---------------------

    /// One sample line: the name, the labels, the value, and the newline.
    pub fn writeMetric(
        self: Writer,
        comptime name_text: []const u8,
        label_values: anytype,
        value_text: anytype,
    ) Io.Writer.Error!void {
        try self.name(name_text, label_values);
        try self.value(value_text);
    }

    /// `# HELP`, `# TYPE`, and the handle its samples go through.
    pub fn writeFamily(self: Writer, comptime m: Metric) Io.Writer.Error!FamilyWriter(m) {
        try self.help(m.name, m.help);
        try self.kind(m.name, m.kind);
        return .{ .writer = self };
    }

    /// A whole classic histogram for one label set: the header and one series.
    ///
    /// A family with more than one series cannot use this twice, because each
    /// call writes `# HELP` and `# TYPE` again and the parser rejects the
    /// second. Write `writeFamily` once and loop
    /// `FamilyWriter.writeHistogramSeries` instead.
    pub fn writeHistogram(
        self: Writer,
        comptime m: Metric,
        label_values: anytype,
        limits: []const f64,
        counts: []const u64,
        sum: anytype,
        count: u64,
    ) Io.Writer.Error!void {
        const family = try self.writeFamily(m);
        return family.writeHistogramSeries(label_values, limits, counts, sum, count);
    }
};

/// A family's samples, from the value `writeFamily` handed back. It carries the
/// family's name, which is why the series form hangs off it: a bare `Writer`
/// has nowhere to get one.
pub fn FamilyWriter(comptime m: Metric) type {
    return struct {
        const Self = @This();

        writer: Writer,

        pub fn write(self: Self, label_values: anytype, value_text: anytype) Io.Writer.Error!void {
            return self.writer.writeMetric(m.name, label_values, value_text);
        }

        /// One histogram series: the bucket lines, `_sum`, and `_count`, with no
        /// header. A family with more than one series writes `help` and `kind`
        /// once through `writeFamily` and then calls this per series.
        ///
        /// `sum` is `anytype` so a caller whose sum is a `u64` keeps every
        /// digit; a `f64` cannot hold one above 2^53.
        pub fn writeHistogramSeries(
            self: Self,
            label_values: anytype,
            limits: []const f64,
            counts: []const u64,
            sum: anytype,
            count: u64,
        ) Io.Writer.Error!void {
            comptime if (m.kind != .histogram) {
                @compileError("prometheus: writeHistogramSeries needs a Metric whose kind is .histogram");
            };
            comptime if (@hasField(@TypeOf(label_values), "le")) {
                @compileError("prometheus: a histogram label set cannot contain \"le\", which this writes");
            };
            assert(counts.len == limits.len);

            var le_buffer: [values.buffer_size]u8 = undefined;
            for (limits, counts) |limit, bucket| {
                try self.writer.name(m.name ++ "_bucket", .{
                    label_values,
                    Le{ .le = values.format(&le_buffer, limit) },
                });
                try self.writer.value(bucket);
            }
            // The implicit bucket, from the total. An empty `limits` reaches
            // here with no finite bucket written, which is exactly one `+Inf`.
            var inf_buffer: [values.buffer_size]u8 = undefined;
            try self.writer.name(m.name ++ "_bucket", .{
                label_values,
                Le{ .le = values.format(&inf_buffer, std.math.inf(f64)) },
            });
            try self.writer.value(count);

            try self.writer.name(m.name ++ "_sum", label_values);
            try self.writer.value(sum);
            try self.writer.name(m.name ++ "_count", label_values);
            try self.writer.value(count);
        }
    };
}

/// The `le` label a histogram adds to the caller's labels.
const Le = struct { le: []const u8 };

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

test "the composition is the primitives, byte for byte" {
    // A bucket line from `writeHistogramSeries`, and the same line by hand
    // through `name` and `value`. If a composition ever stops using the
    // primitives, these two stop matching.
    const metric: Metric = .{ .name = "h", .kind = .histogram };
    const limits = [_]f64{1048576.0};
    const counts = [_]u64{3};

    var composed_buffer: [512]u8 = undefined;
    var composed_out: Io.Writer = .fixed(&composed_buffer);
    var composed = Writer.init(&composed_out);
    try composed.writeHistogram(metric, .{ .method = "GET" }, &limits, &counts, 5.5, 3);

    var by_hand_buffer: [512]u8 = undefined;
    var by_hand_out: Io.Writer = .fixed(&by_hand_buffer);
    var by_hand = Writer.init(&by_hand_out);
    try by_hand.help("h", "");
    try by_hand.kind("h", .histogram);
    try by_hand.name("h_bucket", .{ .method = "GET", .le = "1048576" });
    try by_hand.value(@as(u64, 3));
    try by_hand.name("h_bucket", .{ .method = "GET", .le = "+Inf" });
    try by_hand.value(@as(u64, 3));
    try by_hand.name("h_sum", .{ .method = "GET" });
    try by_hand.value(@as(f64, 5.5));
    try by_hand.name("h_count", .{ .method = "GET" });
    try by_hand.value(@as(u64, 3));

    try testing.expectEqualStrings(by_hand_out.buffered(), composed_out.buffered());
}

test "a tuple of label groups writes in order" {
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = Writer.init(&out);
    try w.name("x", .{ .{ .a = "1" }, .{ .b = "2" } });
    try testing.expectEqualStrings("x{a=\"1\",b=\"2\"}", out.buffered());
}
