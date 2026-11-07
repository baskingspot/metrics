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
const storage = @import("storage.zig");
const math = std.math;

/// A counter whose field the caller owns, over a plain field. Only the owner
/// writes it. `T` is the unsigned value type.
pub fn Local(comptime T: type) type {
    comptime checkUnsigned(T, "counter.Local");
    return Counter(storage.Local(T));
}

/// A counter any thread may write and any thread may read, over an atomic.
pub fn Atomic(comptime T: type) type {
    comptime checkUnsigned(T, "counter.Atomic");
    return Counter(storage.Atomic(T));
}

fn checkUnsigned(comptime T: type, comptime constructor: []const u8) void {
    comptime if (!storage.isInteger(T) or @typeInfo(T).int.signedness != .unsigned) {
        @compileError("metrics: " ++ constructor ++ "(T) takes an unsigned integer, not " ++ @typeName(T));
    };
}

fn Counter(comptime S: type) type {
    return struct {
        const Self = @This();

        pub const ValueType = S.Value;

        value: S,

        /// One more. Wraps at `maxInt(T)`.
        pub inline fn inc(self: *Self) void {
            self.add(1);
        }

        /// Add `n`. Wraps at `maxInt(T)`.
        pub inline fn add(self: *Self, n: S.Value) void {
            self.value.add(n);
        }

        /// The value now. An atomic storage loads monotonically, which is all a
        /// scrape needs: it orders nothing else.
        pub inline fn get(self: *const Self) S.Value {
            return self.value.load();
        }

        /// A counter at zero. The way to make one: `counter.Local(u64).zero`.
        pub const zero: Self = .{ .value = S.zero };
    };
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
