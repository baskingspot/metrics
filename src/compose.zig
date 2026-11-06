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

/// A whole classic histogram: the header, one `_bucket` line per limit, the
/// implicit `+Inf` bucket from the total, `_sum`, and `_count`.
///
/// The counts are cumulative and one per limit. The last finite count is at
/// most the total: an observation above the top limit belongs only to `+Inf`.
/// Nothing here checks monotonicity or the tail, and a length mismatch is a
/// debug assertion.
pub fn writeHistogram(
    w: *ComposeWriter,
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

    try w.help(m.name, m.help);
    try w.kind(m.name, m.kind);

    var le_buffer: [values.buffer_size]u8 = undefined;
    for (limits, counts) |limit, bucket| {
        try w.name(m.name ++ "_bucket", .{ label_values, Le{ .le = values.format(&le_buffer, limit) } });
        try w.value(bucket);
    }
    // The implicit bucket, from the total.
    var inf_buffer: [values.buffer_size]u8 = undefined;
    try w.name(m.name ++ "_bucket", .{
        label_values,
        Le{ .le = values.format(&inf_buffer, std.math.inf(f64)) },
    });
    try w.value(count);

    try w.name(m.name ++ "_sum", label_values);
    try w.value(sum);
    try w.name(m.name ++ "_count", label_values);
    try w.value(count);
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
