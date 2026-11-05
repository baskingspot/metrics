//! The two name grammars in the text format, as predicates.
//!
//! A name the parser rejects costs the whole scrape, not one series, so both
//! doors check. `isValidLabelName` runs on a label name, which is a struct
//! field and therefore comptime-known; `isValidMetricName` runs on whatever
//! the caller passed.
//!
//! The predicates return bool on purpose. The comptime door turns `false` into
//! `@compileError` with the offending name in the message, and the runtime door
//! turns a bad metric name into `error.InvalidName`. A label name is comptime
//! in both doors, so it is always a compile error. Every caller reads the same
//! rule.

const std = @import("std");

/// The legacy metric name grammar: a letter, `_`, or `:`, then letters, digits,
/// `_`, or `:`. A colon is reserved for recording rules, so application metrics
/// should not use one.
pub fn isValidMetricName(name: []const u8) bool {
    if (name.len == 0 or !isMetricStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isMetricContinue(c)) return false;
    }
    return true;
}

/// `[a-zA-Z_][a-zA-Z0-9_]*`, which is what a struct field name already is,
/// minus the `__` prefix. The data model reserves it: `__name__` is the series
/// name, so the parser rejects a label that claims it, and every other `__x`
/// name belongs to a reserved namespace.
pub fn isValidLabelName(name: []const u8) bool {
    if (name.len == 0 or !isLabelStart(name[0])) return false;
    if (hasReservedPrefix(name)) return false;
    for (name[1..]) |c| {
        if (!isLabelContinue(c)) return false;
    }
    return true;
}

/// The data model reserves `__`: `__name__` is the series name, so the parser
/// rejects it as a label, and every other `__x` belongs to a reserved
/// namespace. A caller gets a distinct message for this, because the grammar
/// itself would accept the name.
pub fn hasReservedPrefix(name: []const u8) bool {
    return name.len >= 2 and name[0] == '_' and name[1] == '_';
}

fn isLabelStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isLabelContinue(c: u8) bool {
    return isLabelStart(c) or std.ascii.isDigit(c);
}

fn isMetricStart(c: u8) bool {
    return isLabelStart(c) or c == ':';
}

fn isMetricContinue(c: u8) bool {
    return isLabelContinue(c) or c == ':';
}

const testing = std.testing;

test "the metric name grammar" {
    const good = [_][]const u8{ "a", "_", ":a", "a:b", "a_1", "A9", "a_z_Z_0" };
    for (good) |name| try testing.expect(isValidMetricName(name));

    const bad = [_][]const u8{ "", "1a", "a-b", "a b", "a.b", "é", "a\n", "-a", "a{" };
    for (bad) |name| try testing.expect(!isValidMetricName(name));
}

test "the label name grammar has no colon" {
    const good = [_][]const u8{ "a", "_", "a_1", "A9", "_x" };
    for (good) |name| try testing.expect(isValidLabelName(name));

    const bad = [_][]const u8{ "", "1a", "a:b", "a-b", "é", "a b", "__name__", "__x" };
    for (bad) |name| try testing.expect(!isValidLabelName(name));

    // One underscore is an ordinary name; two are the reserved namespace.
    try testing.expect(isValidLabelName("_x"));
    try testing.expect(isValidLabelName("x__y"));
    try testing.expect(hasReservedPrefix("__name__"));
    try testing.expect(!hasReservedPrefix("x__y"));
}
