//! A recording counter: an unsigned integer and an add, with the storage and
//! the concurrency model chosen where the counter is declared.
//!
//! `Local(T)` is one field and a `+%`. It belongs to whoever holds it, which is
//! a worker thread or a struct the caller already owns. `Atomic(T)` is
//! `std.atomic.Value(T)` with monotonic operations, for the case where a scrape
//! reads a counter another thread is incrementing. The constructor names the
//! storage and `T` names the value type.
//!
//! Both wrap at `maxInt(T)` and keep counting. A counter does not saturate:
//! saturating turns a visible reset into a silent flat line.
//!
//! There is no `set` and no write method. A counter only goes up, and the bytes
//! on the wire are the writer's job: read it with `get` and pass the number.

const std = @import("std");
const testing = std.testing;
const math = std.math;
const Value = std.atomic.Value;

const Mode = enum { atomic, plain };

/// A counter whose field the caller owns. Only the owner writes it.
///
/// The name says the storage; the argument says the value type. `Local(u64)` is
/// a `u64` field; `Atomic(u32)` is a `std.atomic.Value(u32)`.
pub fn Local(comptime T: type) type {
    comptime if (@typeInfo(T) != .int or @typeInfo(T).int.signedness != .unsigned) {
        @compileError("metrics: counter.Local(T) takes an unsigned integer, not " ++ @typeName(T));
    };
    return Counter(.plain, T);
}

/// A counter any thread may write and any thread may read.
pub fn Atomic(comptime T: type) type {
    comptime if (@typeInfo(T) != .int) {
        @compileError("metrics: counter.Atomic(T) takes an unsigned integer, not " ++ @typeName(T));
    };
    return Counter(.atomic, T);
}

fn Counter(comptime mode: Mode, comptime T: type) type {
    comptime checkType(mode, T);
    return struct {
        const Self = @This();

        pub const concurrency = mode;
        pub const ValueType = T;

        const Storage = switch (mode) {
            .plain => T,
            .atomic => Value(T),
        };

        value: Storage,

        /// One more. Wraps at `maxInt(T)`.
        pub inline fn inc(self: *Self) void {
            self.add(1);
        }

        /// Add `n`. Wraps at `maxInt(T)`.
        pub inline fn add(self: *Self, n: T) void {
            switch (mode) {
                .plain => self.value +%= n,
                .atomic => _ = self.value.fetchAdd(n, .monotonic),
            }
        }

        /// The value now. With `.atomic` this is a monotonic load, which is all
        /// a scrape needs: it orders nothing else.
        pub inline fn get(self: *const Self) T {
            return switch (mode) {
                .plain => self.value,
                .atomic => self.value.load(.monotonic),
            };
        }

        /// A counter at zero. The way to make one: `counter.Local(u64).zero`.
        pub const zero: Self = .{ .value = switch (mode) {
            .plain => 0,
            .atomic => .init(0),
        } };
    };
}

fn checkType(comptime mode: Mode, comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.signedness != .unsigned) {
                @compileError("metrics: a counter counts up, so its type is unsigned, not " ++ @typeName(T));
            }
            if (mode == .atomic and !isAtomicWidth(info.bits)) {
                @compileError("metrics: Atomic(" ++ @typeName(T) ++
                    ") has no atomic storage; use 8, 16, 32, or 64 bits");
            }
        },
        else => @compileError("metrics: a counter's type is an unsigned integer, not " ++ @typeName(T)),
    }
}

fn isAtomicWidth(comptime bits: u16) bool {
    return bits == 8 or bits == 16 or bits == 32 or bits == 64;
}

test "both modes add, read, and wrap the same way" {
    var plain: Local(u64) = .zero;
    var atomic: Atomic(u64) = .zero;
    try testing.expectEqual(@as(u64, 0), plain.get());
    try testing.expectEqual(@as(u64, 0), atomic.get());

    const steps = [_]u64{ 1, 0, 7, math.maxInt(u64), 3, math.maxInt(u64) / 2 };
    for (steps) |step| {
        plain.add(step);
        atomic.add(step);
        try testing.expectEqual(plain.get(), atomic.get());
    }

    plain = .zero;
    atomic = .zero;
    plain.inc();
    atomic.inc();
    try testing.expectEqual(@as(u64, 1), plain.get());
    try testing.expectEqual(@as(u64, 1), atomic.get());
}

test "the integer type is the counter's, not the platform's" {
    var byte: Local(u8) = .zero;
    byte.add(255);
    byte.inc();
    try testing.expectEqual(@as(u8, 0), byte.get());

    var narrow: Atomic(u16) = .zero;
    narrow.add(65535);
    narrow.inc();
    try testing.expectEqual(@as(u16, 0), narrow.get());
}

test "a counter is one word, in either mode" {
    // Every consumer of this type is a counter next to other counters, so the
    // claim that matters is that a counter costs a word and adds no padding of
    // its own. That is not visible by reading the type.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Local(u64)));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Atomic(u64)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Local(u64)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Atomic(u64)));

    // One counter beside a u64: two words. Field offsets in an auto-layout
    // struct are the compiler's business, so the size is the claim here.
    const Pair = struct { bytes: u64, errors: Local(u64) };
    try testing.expectEqual(@as(usize, 16), @sizeOf(Pair));

    // A block of counters beside two u64s, which is the shape a worker struct
    // has: four words, no gap added by a counter.
    const Worker = struct {
        started: u64,
        requests: Local(u64),
        errors: Local(u64),
        bytes: u64,
    };
    try testing.expectEqual(@as(usize, 32), @sizeOf(Worker));

    // Two narrow fields and a counter pack into two words, because the counter
    // lands in space the struct already had.
    const Mixed = struct {
        a: u32,
        b: u32,
        errors: Local(u64),
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(Mixed));
}
