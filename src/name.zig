//! The two name grammars in the text format, checked before a byte is written.
//!
//! A name the parser rejects costs the whole scrape, not one series, so the
//! check is part of the writer. A label name comes from a struct field and is
//! therefore comptime-known: a bad one is a compile error. A metric name
//! arrives as a slice and is checked at run time.

const std = @import("std");

pub const Error = error{InvalidName};

/// The legacy metric name grammar: a letter, `_`, or `:`, then letters, digits,
/// `_`, or `:`. A colon is reserved for recording rules, so application metrics
/// should not use one.
pub fn checkMetricName(name: []const u8) Error!void {
    if (!validMetricName(name)) return error.InvalidName;
}

/// `[a-zA-Z_][a-zA-Z0-9_]*`, which is what a struct field name already is.
pub fn checkLabelName(name: []const u8) Error!void {
    if (!validLabelName(name)) return error.InvalidName;
}

/// The same grammar as `checkMetricName`, for a caller that only needs the
/// answer. `sample` uses it at comptime for a label name and at run time for a
/// metric name.
pub fn validMetricName(name: []const u8) bool {
    if (name.len == 0 or !isMetricStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isMetricContinue(c)) return false;
    }
    return true;
}

pub fn validLabelName(name: []const u8) bool {
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
    for (good) |name| try checkMetricName(name);

    const bad = [_][]const u8{
        "",    "1a", "a-b", "a b", "a.b",
        "é",
        "a\n", "-a", "a{",  " a",
    };
    for (bad) |name| try testing.expectError(error.InvalidName, checkMetricName(name));
}

test "the label name grammar has no colon" {
    const good = [_][]const u8{ "a", "_", "a_1", "A9", "_x" };
    for (good) |name| try checkLabelName(name);

    const bad = [_][]const u8{ "", "1a", "a:b", "a-b", "é", "a b" };
    for (bad) |name| try testing.expectError(error.InvalidName, checkLabelName(name));

    try testing.expect(validLabelName("ok"));
    try testing.expect(!validLabelName("not ok"));
}
