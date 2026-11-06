//! Sample values and bucket labels.
//!
//! The rule is go-metrics' `expfmt.writeFloat64`: a float that reads back as an
//! `i64` is written as that integer, `NaN` and the infinities are written
//! canonically, and everything else goes through Go's `'g'` with the shortest
//! round-trip digits. An integer type is written as decimal and never touches
//! `f64`.
//!
//! Zig's `{d}` alone is not enough, which is why this exists: it prints 301
//! characters for `1e300`, and `nan` for `NaN`.

const std = @import("std");
const Io = std.Io;
const math = std.math;

/// Longest formatted value: 24 bytes for a `'g'` form, and the integer form is
/// shorter. `le` uses the same buffer.
pub const buffer_size = 32;

/// Longest `{e}` output for an f64: sign, digit, point, 16 digits, `e`, sign,
/// three digits.
const scientific_size = 40;
const digits_size = 32;

/// 2^63 exactly. `i64` cannot hold it, and Go's conversion of it falls through
/// to the float path, so the bound here is half-open.
const two_to_63: f64 = 9223372036854775808.0;

pub fn write(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => w.print("{d}", .{value}),
        .float => switch (@bitSizeOf(@TypeOf(value))) {
            16, 32, 64 => writeFloat(w, @floatCast(value)),
            else => @compileError("prometheus: a metric value is at most f64"),
        },
        .comptime_float => writeFloat(w, @floatCast(value)),
        else => @compileError("prometheus: a metric value is an integer or a float, not " ++ @typeName(@TypeOf(value))),
    };
}

/// The same bytes `write` would emit, as a slice, for a caller that needs the
/// text rather than the write. A bucket label is the reason.
pub fn format(buffer: *[buffer_size]u8, value: f64) []const u8 {
    var w: Io.Writer = .fixed(buffer);
    writeFloat(&w, value) catch unreachable;
    return w.buffered();
}

pub fn writeFloat(w: *Io.Writer, value: f64) Io.Writer.Error!void {
    if (math.isNan(value)) return w.writeAll("NaN");
    if (math.isInf(value)) return w.writeAll(if (value > 0) "+Inf" else "-Inf");

    // A float that reads back as the same integer is written as one. That is
    // why a counter of 1e6 prints `1000000` and not `1e+06`, and why negative
    // zero prints `0`.
    if (value >= -two_to_63 and value < two_to_63 and @trunc(value) == value) {
        const whole: i64 = @intFromFloat(value);
        if (@as(f64, @floatFromInt(whole)) == value) {
            return w.print("{d}", .{whole});
        }
    }
    return writeGoFloat(w, value);
}

/// `strconv.FormatFloat(f, 'g', -1, 64)`: the shortest round-trip digits, in
/// exponent form when the decimal exponent is below -4 or at least 6.
fn writeGoFloat(w: *Io.Writer, value: f64) Io.Writer.Error!void {
    var buffer: [scientific_size]u8 = undefined;
    // `{e}` is the shortest digits in scientific form with no sign and no
    // padding on the exponent; re-spacing them is all Go's `'g'` needs.
    const text = std.fmt.bufPrint(&buffer, "{e}", .{value}) catch unreachable;

    const negative = text[0] == '-';
    const body = if (negative) text[1..] else text;
    const exp_at = std.mem.findScalar(u8, body, 'e').?;
    const exponent = std.fmt.parseInt(i32, body[exp_at + 1 ..], 10) catch unreachable;

    var digits_buffer: [digits_size]u8 = undefined;
    var len: usize = 0;
    for (body[0..exp_at]) |c| {
        if (c == '.') continue;
        digits_buffer[len] = c;
        len += 1;
    }
    const digits = digits_buffer[0..len];

    if (negative) try w.writeByte('-');

    if (exponent < -4 or exponent >= 6) return writeScientific(w, digits, exponent);
    try writePositional(w, digits, exponent);
}

fn writeScientific(w: *Io.Writer, digits: []const u8, exponent: i32) Io.Writer.Error!void {
    try w.writeByte(digits[0]);
    if (digits.len > 1) {
        try w.writeByte('.');
        try w.writeAll(digits[1..]);
    }
    try w.writeByte('e');
    try w.writeByte(if (exponent < 0) '-' else '+');
    const magnitude: u32 = @intCast(if (exponent < 0) -exponent else exponent);
    if (magnitude < 10) try w.writeByte('0');
    try w.print("{d}", .{magnitude});
}

fn writePositional(w: *Io.Writer, digits: []const u8, exponent: i32) Io.Writer.Error!void {
    const point: i32 = exponent + 1;
    if (point <= 0) {
        try w.writeAll("0.");
        var zeros: i32 = 0;
        while (zeros < -point) : (zeros += 1) try w.writeByte('0');
        return w.writeAll(digits);
    }
    const point_at: usize = @intCast(point);
    if (point_at >= digits.len) {
        try w.writeAll(digits);
        var zeros: usize = digits.len;
        while (zeros < point_at) : (zeros += 1) try w.writeByte('0');
        return;
    }
    try w.writeAll(digits[0..point_at]);
    try w.writeByte('.');
    try w.writeAll(digits[point_at..]);
}

const testing = std.testing;

fn expectValue(expected: []const u8, value: f64) !void {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeFloat(&w, value);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "a float that is a whole integer is written as one" {
    try expectValue("1000000", 1e6);
    try expectValue("1234567", 1234567.0);
    try expectValue("3", 3.0);
    try expectValue("0", 0.0);
    try expectValue("0", -0.0);
    try expectValue("-42", -42.0);
    try expectValue("9007199254740992", 9007199254740993.0);
}

test "everything else is Go's 'g' with the shortest digits" {
    try expectValue("0.1", 0.1);
    try expectValue("0.0001", 0.0001);
    try expectValue("1e-07", 1e-7);
    try expectValue("1e+21", 1e21);
    try expectValue("1e+300", 1e300);
    try expectValue("0.3333333333333333", 1.0 / 3.0);
    try expectValue("2.2250738585072014e-308", 2.2250738585072014e-308);
    try expectValue("5e-324", 5e-324);
    try expectValue("999999.5", 999999.5);
    try expectValue("9.223372036854776e+18", 9223372036854775808.0);
}

test "the non-finite spellings are canonical" {
    try expectValue("NaN", math.nan(f64));
    try expectValue("+Inf", math.inf(f64));
    try expectValue("-Inf", -math.inf(f64));
}

test "an integer type keeps every digit" {
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try write(&w, math.maxInt(u64));
    try write(&w, 9007199254740993);
    try write(&w, -5);
    try testing.expectEqualStrings("184467440737095516159007199254740993-5", w.buffered());
}

test "every f64 value survives a round trip" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    var seen: usize = 0;
    while (seen < 200_000) : (seen += 1) {
        const value: f64 = @bitCast(random.int(u64));
        var buffer: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        try writeFloat(&w, value);
        const text = w.buffered();

        if (math.isNan(value)) {
            try testing.expectEqualStrings("NaN", text);
            continue;
        }
        if (math.isInf(value)) {
            try testing.expectEqualStrings(if (value > 0) "+Inf" else "-Inf", text);
            continue;
        }
        const back = try std.fmt.parseFloat(f64, text);
        try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(back)));
    }
}
