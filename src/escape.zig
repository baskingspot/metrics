//! Escaping for label values and HELP text, and the UTF-8 check in front of it.
//!
//! Three bytes are special inside a label value: `\`, `"`, and newline. Two are
//! special in HELP: `\` and newline. Everything else is written raw, including
//! tab, carriage return, NUL, and any valid UTF-8. A raw newline or a stray
//! backslash ends the scrape for every series, so the escaping is not optional.
//!
//! Invalid UTF-8 is the same class of failure: the parser rejects the document,
//! so one bad label value takes down the whole scrape. The writer refuses to
//! emit one and returns `error.InvalidLabelValue` instead.

const std = @import("std");
const Io = std.Io;
const findAny = std.mem.findAny;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;

pub const Error = error{InvalidLabelValue};

pub fn writeLabelValue(w: *Io.Writer, value: []const u8) (Io.Writer.Error || Error)!void {
    try checkUtf8(value);
    try writeEscaped(w, value, label_specials);
}

pub fn writeHelpText(w: *Io.Writer, value: []const u8) (Io.Writer.Error || Error)!void {
    try checkUtf8(value);
    try writeEscaped(w, value, help_specials);
}

/// The escaped form of HELP text, built at comptime for a comptime family.
///
/// The comptime door writes its whole `# HELP`/`# TYPE` block as one literal,
/// so it needs the escaped bytes as a value rather than as a write.
pub fn escapeHelp(comptime text: []const u8) []const u8 {
    comptime {
        if (!utf8ValidateSlice(text)) {
            @compileError("prometheus: HELP text is not valid UTF-8");
        }
        var out: []const u8 = "";
        for (text) |c| {
            out = out ++ switch (c) {
                '\\' => "\\\\",
                '\n' => "\\n",
                else => &[_]u8{c},
            };
        }
        return out;
    }
}

/// The bytes that need escaping in a label value, in HELP text, and nothing
/// else. Exposed so a test can unescape a document without duplicating the list.
pub const label_specials = "\\\"\n";
pub const help_specials = "\\\n";

fn checkUtf8(value: []const u8) Error!void {
    if (!utf8ValidateSlice(value)) return error.InvalidLabelValue;
}

fn writeEscaped(
    w: *Io.Writer,
    value: []const u8,
    comptime specials: []const u8,
) Io.Writer.Error!void {
    var rest = value;
    while (rest.len > 0) {
        const at = findAny(u8, rest, specials) orelse {
            try w.writeAll(rest);
            return;
        };
        try w.writeAll(rest[0..at]);
        try w.writeByte('\\');
        try w.writeByte(switch (rest[at]) {
            '\\' => '\\',
            '"' => '"',
            '\n' => 'n',
            else => unreachable,
        });
        rest = rest[at + 1 ..];
    }
}

const testing = std.testing;
const Allocator = std.mem.Allocator;

fn expectEscaped(expected: []const u8, value: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeLabelValue(&w, value);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "a label value escapes three bytes and nothing else" {
    try expectEscaped("plain", "plain");
    try expectEscaped("a\\\\b", "a\\b");
    try expectEscaped("a\\\"b", "a\"b");
    try expectEscaped("a\\nb", "a\nb");
    try expectEscaped("\t\r\x00🦎é日本", "\t\r\x00🦎é日本");
}

test "HELP escapes a backslash and a newline, not a quote" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeHelpText(&w, "a\\b\"c\nd");
    try testing.expectEqualStrings("a\\\\b\"c\\nd", w.buffered());
}

test "empty HELP writes nothing" {
    var buffer: [8]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeHelpText(&w, "");
    try testing.expectEqualStrings("", w.buffered());
}

test "invalid UTF-8 is refused rather than emitted" {
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidLabelValue, writeLabelValue(&w, &.{0xff}));
    try testing.expectError(error.InvalidLabelValue, writeHelpText(&w, &.{0xc3}));
    try testing.expectError(error.InvalidLabelValue, writeHelpText(&w, &.{ 0xed, 0xa0, 0x80 }));
}

/// Undo the label escaping, so the round trip can be checked without trusting
/// the writer's own idea of what it wrote.
fn unescape(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            try out.append(gpa, text[i]);
            continue;
        }
        i += 1;
        try out.append(gpa, switch (text[i]) {
            'n' => '\n',
            '\\' => '\\',
            '"' => '"',
            else => return error.BadEscape,
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Pieces of valid UTF-8, including every byte that has to be escaped, the
/// control characters the format leaves raw, and multi-byte text.
const pieces = [_][]const u8{
    "a", "Z", "0", "_", "\\", "\"", "\n", "\t", "\r", "\x00",
    "é",
    "ß",
    "日",
    "本",
    "🦎",
    "🎛",
    " ", "-", "=", "{",
};

test "escaping round trips over random valid UTF-8" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();
    const gpa = testing.allocator;

    var round: usize = 0;
    while (round < 5000) : (round += 1) {
        var original: std.ArrayList(u8) = .empty;
        defer original.deinit(gpa);
        for (0..random.intRangeAtMost(u32, 0, 12)) |_| {
            try original.appendSlice(gpa, pieces[random.uintLessThan(usize, pieces.len)]);
        }

        var buffer: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        try writeLabelValue(&w, original.items);

        const back = try unescape(gpa, w.buffered());
        defer gpa.free(back);
        try testing.expectEqualStrings(original.items, back);
    }
}
