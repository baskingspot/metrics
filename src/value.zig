//! Sample values: the number at the end of a sample line.
//!
//! A float is written the way `prometheus/common`'s `writeFloat` writes it, so
//! this library and a Go client spell the same number the same way:
//! `strconv.FormatFloat(f, 'g', -1, 64)`, with `NaN` and the infinities spelled
//! canonically. The `'g'` choice bounds a sample at 24 characters; positional
//! only would print 309 for `1e300` and turn a 5 MB scrape into a 50 MB one.
//!
//! An integer never goes through `f64`, so a `u64` counter above 2^53 keeps
//! every digit.

const std = @import("std");
const Io = std.Io;
const math = std.math;
const testing = std.testing;

/// Longest `{e}` output for an f64 is 24 bytes: sign, digit, point, 16 digits,
/// `e`, sign, three digits.
const scientific_size = 40;
/// Room for the digits of one exponent form or one positional form.
const digits_size = 32;

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

pub fn writeFloat(w: *Io.Writer, value: f64) Io.Writer.Error!void {
    if (math.isNan(value)) return w.writeAll("NaN");
    if (math.isInf(value)) return w.writeAll(if (value > 0) "+Inf" else "-Inf");
    if (value == 0) return w.writeAll(if (math.signbit(value)) "-0" else "0");

    // `{e}` is the shortest round-trip digits in scientific form with no sign
    // and no padding on the exponent: `1.5e0`, `1e300`, `3.333333333333333e-1`.
    // Go's `'g'` wants those same digits, spaced differently.
    var buffer: [scientific_size]u8 = undefined;
    // 24 bytes is the longest an f64 can produce here, so the buffer cannot
    // overflow and there is no error to report.
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

    // Go picks exponent form below -4 and at 6 and above, where `prec` is 6
    // whenever the digits are the shortest ones.
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

fn expectValue(expected: []const u8, value: f64) !void {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeFloat(&w, value);
    try testing.expectEqualStrings(expected, w.buffered());
}

// The reference encoder's table, verified against Go's
// `strconv.FormatFloat(f, 'g', -1, 64)` on 2026-11-05.
test "the Go 'g' table" {
    try expectValue("0.1", 0.1);
    try expectValue("0.0001", 0.0001);
    try expectValue("1e-07", 1e-7);
    try expectValue("999999", 999999);
    try expectValue("1e+06", 1e6);
    try expectValue("1.234567e+06", 1234567);
    try expectValue("1e+21", 1e21);
    try expectValue("1e+300", 1e300);
    try expectValue("3", 3.0);
    try expectValue("0.3333333333333333", 1.0 / 3.0);
    try expectValue("9.007199254740992e+15", 9007199254740993.0);
    try expectValue("2.2250738585072014e-308", 2.2250738585072014e-308);
    try expectValue("-0", -0.0);
    try expectValue("0", 0.0);
    try expectValue("NaN", math.nan(f64));
    try expectValue("+Inf", math.inf(f64));
    try expectValue("-Inf", -math.inf(f64));
    try expectValue("5e-324", 5e-324);
}

test "an integer keeps every digit" {
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try write(&w, math.maxInt(u64));
    try testing.expectEqualStrings("18446744073709551615", w.buffered());

    var narrow: [64]u8 = undefined;
    var w2: Io.Writer = .fixed(&narrow);
    try write(&w2, 9007199254740993);
    try testing.expectEqualStrings("9007199254740993", w2.buffered());
}

test "a float literal and an f32 go through the float path" {
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try write(&w, 1.5);
    try write(&w, @as(f32, 0.25));
    try testing.expectEqualStrings("1.50.25", w.buffered());
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
