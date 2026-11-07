//! A recording gauge: a number that moves both ways, with the storage and the
//! concurrency model chosen where it is declared.
//!
//! `Int(T)` is one field. It belongs to whoever holds it, which is a worker
//! thread or a struct the caller already owns. `Atomic(T)` is
//! `std.atomic.Value(T)` with monotonic operations, for a gauge a scrape reads
//! while another thread writes it.
//!
//! The integer type may be signed. A gauge holds a temperature, a delta, a queue
//! depth that dips below its last reading; a counter cannot.
//!
//! There is no write method. The bytes on the wire are the writer's job: read
//! the gauge with `get` and pass the number.

const std = @import("std");
const testing = std.testing;
const math = std.math;
const assert = std.debug.assert;
const Value = std.atomic.Value;

const Mode = enum { atomic, plain };

/// A gauge whose field the caller owns. Only the owner writes it.
pub fn Int(comptime T: type) type {
    return Gauge(.plain, T);
}

/// A gauge any thread may write and any thread may read.
pub fn Atomic(comptime T: type) type {
    return Gauge(.atomic, T);
}

fn Gauge(comptime mode: Mode, comptime T: type) type {
    comptime checkType(mode, T);
    return struct {
        const Self = @This();

        pub const concurrency = mode;
        pub const IntType = T;

        value: Storage,

        /// Replace the value.
        pub inline fn set(self: *Self, v: T) void {
            switch (mode) {
                .plain => self.value = v,
                .atomic => self.value.store(v, .monotonic),
            }
        }

        /// Add `n`, which may be negative. Wraps at the type's bounds.
        pub inline fn add(self: *Self, n: T) void {
            switch (mode) {
                .plain => self.value +%= n,
                .atomic => _ = self.value.fetchAdd(n, .monotonic),
            }
        }

        /// Subtract `n`, which may be negative. Wraps at the type's bounds.
        ///
        /// An unsigned gauge asserts that the value the subtraction observed
        /// covers it, so a debug build catches the dip below zero; a release
        /// build wraps, which shows up in the next scrape. Saturating would hide
        /// the bug at a flat line, the same way it would in a counter.
        ///
        /// A signed gauge has no such floor. Going negative is the point, and
        /// only `minInt(T)` wraps, so there is nothing to assert.
        pub inline fn sub(self: *Self, n: T) void {
            switch (mode) {
                .plain => {
                    const previous = self.value;
                    if (comptime hasFloor(T)) assert(previous >= n);
                    self.value = previous -% n;
                },
                .atomic => {
                    const previous = self.value.fetchSub(n, .monotonic);
                    if (comptime hasFloor(T)) assert(previous >= n);
                },
            }
        }

        /// One more.
        pub inline fn inc(self: *Self) void {
            self.add(1);
        }

        /// One less.
        pub inline fn dec(self: *Self) void {
            self.sub(1);
        }

        /// The value now. With `.atomic` this is a monotonic load, which is all
        /// a scrape needs: it orders nothing else.
        pub inline fn get(self: *const Self) T {
            return switch (mode) {
                .plain => self.value,
                .atomic => self.value.load(.monotonic),
            };
        }

        const Storage = switch (mode) {
            .plain => T,
            .atomic => Value(T),
        };

        /// A gauge at zero. The way to make one: `Int(u64).zero`.
        pub const zero: Self = .{ .value = switch (mode) {
            .plain => 0,
            .atomic => .init(0),
        } };
    };
}

fn checkType(comptime mode: Mode, comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (mode == .atomic and !isAtomicWidth(info.bits)) {
                @compileError("metrics: Atomic(" ++ @typeName(T) ++
                    ") has no atomic storage; use 8, 16, 32, or 64 bits");
            }
        },
        else => @compileError("metrics: a gauge's type is an integer, not " ++ @typeName(T)),
    }
}

/// True when `sub` has a floor to enforce: an unsigned type has one at zero, a
/// signed type does not.
fn hasFloor(comptime T: type) bool {
    return @typeInfo(T).int.signedness == .unsigned;
}

fn isAtomicWidth(comptime bits: u16) bool {
    return bits == 8 or bits == 16 or bits == 32 or bits == 64;
}

test "both modes set, add, subtract, and read the same way" {
    var plain: Int(i64) = .zero;
    var atomic: Atomic(i64) = .zero;

    const steps = [_]i64{ 1, 0, -7, 1000, -500, 42 };
    for (steps) |step| {
        plain.add(step);
        atomic.add(step);
        try testing.expectEqual(plain.get(), atomic.get());
    }

    plain.set(-5);
    atomic.set(-5);
    try testing.expectEqual(@as(i64, -5), plain.get());
    try testing.expectEqual(@as(i64, -5), atomic.get());
}

test "subtracting to exactly zero is allowed" {
    var plain: Int(u64) = .zero;
    var atomic: Atomic(u64) = .zero;
    plain.set(9);
    atomic.set(9);

    plain.sub(9);
    atomic.sub(9);
    try testing.expectEqual(@as(u64, 0), plain.get());
    try testing.expectEqual(@as(u64, 0), atomic.get());

    // One more subtraction would be the underflow the assertion exists to
    // catch, so the test stops at the boundary rather than past it.
    plain.set(1);
    atomic.set(1);
    plain.dec();
    atomic.dec();
    try testing.expectEqual(@as(u64, 0), plain.get());
    try testing.expectEqual(@as(u64, 0), atomic.get());
}

test "a signed gauge goes negative" {
    var plain: Int(i64) = .zero;
    var atomic: Atomic(i64) = .zero;

    plain.sub(1);
    atomic.sub(1);
    try testing.expectEqual(@as(i64, -1), plain.get());
    try testing.expectEqual(@as(i64, -1), atomic.get());

    plain.set(math.minInt(i64) + 1);
    atomic.set(math.minInt(i64) + 1);
    plain.dec();
    atomic.dec();
    try testing.expectEqual(@as(i64, math.minInt(i64)), plain.get());
    try testing.expectEqual(@as(i64, math.minInt(i64)), atomic.get());
}

test "the integer type is the gauge's, not the platform's" {
    var byte: Int(u8) = .zero;
    byte.set(255);
    byte.add(1);
    try testing.expectEqual(@as(u8, 0), byte.get());

    var narrow: Atomic(u8) = .zero;
    narrow.set(255);
    narrow.add(1);
    try testing.expectEqual(@as(u8, 0), narrow.get());
}

test "a gauge is one word, in either mode" {
    // The same claim a counter makes: it costs a word and adds no padding of
    // its own, which a reader cannot see from the type.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Int(u64)));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Atomic(u64)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Int(u64)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Atomic(u64)));

    // A gauge lands in space the struct already had.
    const Mixed = struct {
        a: u32,
        b: u32,
        depth: Int(u64),
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(Mixed));

    // A signed gauge is the same width as an unsigned one.
    try testing.expectEqual(@sizeOf(Int(u64)), @sizeOf(Int(i64)));
}
