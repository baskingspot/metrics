//! The layer above the writer: one metric, one family, one histogram, each
//! built only out of `Writer` methods.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const writer = @import("writer.zig");
const values = @import("value.zig");

const Writer = writer.Writer;
pub const Kind = writer.Kind;

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

        writer: *Writer,

        pub fn write(self: Self, label_values: anytype, value: anytype) Io.Writer.Error!void {
            return writeMetric(self.writer, m.name, label_values, value);
        }

        /// One histogram series: the bucket lines, `_sum`, and `_count`, with no
        /// header. A family with more than one series writes `help` and `kind`
        /// once through `writeFamily` and then calls this per series; calling
        /// `writeHistogram` twice would write the header twice.
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
            // The implicit bucket, from the total.
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

/// One sample line: the name, the labels, the value, and the newline.
pub fn writeMetric(
    w: *ComposeWriter,
    comptime name: []const u8,
    label_values: anytype,
    value: anytype,
) Io.Writer.Error!void {
    try w.name(name, label_values);
    try w.value(value);
}

/// `# HELP`, `# TYPE`, and the writer its samples go through.
pub fn writeFamily(w: *ComposeWriter, comptime m: Metric) Io.Writer.Error!FamilyWriter(m) {
    try w.help(m.name, m.help);
    try w.kind(m.name, m.kind);
    return .{ .writer = w };
}

/// A whole classic histogram for one label set: the header and one series.
///
/// A family with more than one series cannot use this twice, because each call
/// writes `# HELP` and `# TYPE` again and the parser rejects the second. Write
/// `writeFamily` once and loop `FamilyWriter.writeHistogramSeries` instead.
pub fn writeHistogram(
    w: *ComposeWriter,
    comptime m: Metric,
    label_values: anytype,
    limits: []const f64,
    counts: []const u64,
    sum: anytype,
    count: u64,
) Io.Writer.Error!void {
    const family = try writeFamily(w, m);
    return family.writeHistogramSeries(label_values, limits, counts, sum, count);
}

const ComposeWriter = Writer;

/// The `le` label a histogram adds to the caller's labels.
const Le = struct { le: []const u8 };

const testing = std.testing;

test "the composition is the primitives, byte for byte" {
    // A bucket line from `writeHistogram`, and the same line by hand through
    // `name` and `value`. If the composition ever stops using the primitives,
    // these two stop matching.
    const metric: Metric = .{ .name = "h", .kind = .histogram };
    const limits = [_]f64{1048576.0};
    const counts = [_]u64{3};

    var composed_buffer: [512]u8 = undefined;
    var composed_out: Io.Writer = .fixed(&composed_buffer);
    var composed = Writer.init(&composed_out);
    try writeHistogram(&composed, metric, .{ .method = "GET" }, &limits, &counts, 5.5, 3);

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
