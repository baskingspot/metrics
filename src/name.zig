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

/// `[a-zA-Z_][a-zA-Z0-9_]*`, which is what a struct field name already is.
pub fn isValidLabelName(name: []const u8) bool {
    if (name.len == 0 or !isLabelStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isLabelContinue(c)) return false;
    }
    return true;
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

    const bad = [_][]const u8{ "", "1a", "a:b", "a-b", "é", "a b" };
    for (bad) |name| try testing.expect(!isValidLabelName(name));
}
