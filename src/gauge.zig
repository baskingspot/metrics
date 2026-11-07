//! A recording gauge: a number that moves both ways, with the storage chosen by
//! the constructor and the value type by the argument.
//!
//! `Local(T)` is one field and belongs to whoever holds it, which is a worker
//! thread or a struct the caller already owns. `Atomic(T)` is a
//! `std.atomic.Value` with monotonic operations, for a gauge a scrape reads
//! while another thread writes it.
//!
//! A gauge holds a temperature, a delta, a queue depth that dips below its last
//! reading, so its integer may be signed and its float is `f32` or `f64`. The
//! counter has neither.
//!
//! There is no write method. The bytes on the wire are the writer's job: read
//! the gauge with `get` and pass the number.

const std = @import("std");
const testing = std.testing;
const math = std.math;
const assert = std.debug.assert;
const Value = std.atomic.Value;
const Io = std.Io;

const Mode = enum { atomic, plain };

/// A gauge whose field the caller owns. Only the owner writes it.
///
/// The name says the storage; the argument says the value type. `Local(i64)` is
/// an `i64` field, `Local(f64)` an `f64`, and `Atomic(u32)` a
/// `std.atomic.Value(u32)`.
pub fn Local(comptime T: type) type {
    comptime if (!isInteger(T) and !isFloat(T)) {
        @compileError("metrics: gauge.Local(T) takes an integer, f32, or f64, not " ++ @typeName(T));
    };
    return Gauge(.plain, T);
}

/// A gauge any thread may write and any thread may read: an integer or a float.
pub fn Atomic(comptime T: type) type {
    comptime if (!isInteger(T) and !isFloat(T)) {
        @compileError("metrics: gauge.Atomic(T) takes an integer, f32, or f64, not " ++ @typeName(T));
    };
    return Gauge(.atomic, T);
}

fn Gauge(comptime mode: Mode, comptime T: type) type {
    comptime checkType(mode, T);
    return struct {
        const Self = @This();

        pub const concurrency = mode;
        pub const ValueType = T;

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
                .plain => {
                    if (comptime isFloat(T)) {
                        self.value += n;
                    } else {
                        self.value +%= n;
                    }
                },
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
        /// A signed integer has no such floor, and a float has neither a floor
        /// nor a wrap: going negative is the point, and a float subtraction is
        /// just arithmetic.
        pub inline fn sub(self: *Self, n: T) void {
            switch (mode) {
                .plain => {
                    if (comptime isFloat(T)) {
                        self.value -= n;
                    } else if (comptime hasFloor(T)) {
                        const previous = self.value;
                        assert(previous >= n);
                        self.value = previous -% n;
                    } else {
                        self.value = self.value -% n;
                    }
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
            .atomic => AtomicStorage(T),
        };

        /// A gauge at zero. The way to make one: `gauge.Local(i64).zero`.
        pub const zero: Self = .{ .value = switch (mode) {
            .plain => 0,
            .atomic => .init(0),
        } };
    };
}

/// The integer atomic an atomic gauge stores: the type itself for an integer,
/// and `AtomicFloat` for a float.
fn AtomicStorage(comptime T: type) type {
    return if (isFloat(T)) AtomicFloat(T) else Value(T);
}

/// An atomic `f32` or `f64`. There is no atomic float add to call, so this is an
/// integer atomic holding the bit pattern: `load` and `store` are a load and a
/// store on it, and `fetchAdd` is a compare-exchange loop.
fn AtomicFloat(comptime T: type) type {
    comptime assert(isFloat(T));
    return struct {
        const Self = @This();
        const Bits = AtomicBits(T);

        bits: Value(Bits),

        pub fn init(v: T) Self {
            return .{ .bits = .init(@bitCast(v)) };
        }

        pub fn load(self: *const Self, comptime order: std.builtin.AtomicOrder) T {
            return @bitCast(self.bits.load(order));
        }

        pub fn store(self: *Self, v: T, comptime order: std.builtin.AtomicOrder) void {
            self.bits.store(@bitCast(v), order);
        }

        /// The value the caller observed, like the integer `fetchAdd`.
        pub fn fetchAdd(self: *Self, n: T, comptime order: std.builtin.AtomicOrder) T {
            // A no-op add does not need to contend for the line.
            if (n == 0) return self.load(order);
            var current: Bits = self.bits.load(order);
            while (true) {
                const next: Bits = @bitCast(@as(T, @bitCast(current)) + n);
                if (self.bits.cmpxchgWeak(current, next, order, order)) |observed| {
                    current = observed;
                } else return @bitCast(current);
            }
        }

        pub fn fetchSub(self: *Self, n: T, comptime order: std.builtin.AtomicOrder) T {
            return self.fetchAdd(-n, order);
        }
    };
}

/// The integer an atomic float is stored in: 32 bits for an `f32`, 64 for an
/// `f64`.
fn AtomicBits(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .float => |info| switch (info.bits) {
            32 => u32,
            64 => u64,
            else => @compileError("metrics: an atomic gauge is 32 or 64 bits, not " ++ @typeName(T)),
        },
        else => @compileError("metrics: AtomicBits takes a float, not " ++ @typeName(T)),
    };
}

fn checkType(comptime mode: Mode, comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (mode == .atomic and !isAtomicWidth(info.bits)) {
                @compileError("metrics: gauge.Atomic(" ++ @typeName(T) ++
                    ") has no atomic storage; use 8, 16, 32, or 64 bits");
            }
        },
        .float => {},
        else => @compileError("metrics: a gauge's type is an integer or a float, not " ++ @typeName(T)),
    }
}

fn isInteger(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// True when `sub` has a floor to enforce: an unsigned type has one at zero, a
/// signed integer and a float do not.
fn hasFloor(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |info| info.signedness == .unsigned,
        else => false,
    };
}

fn isAtomicWidth(comptime bits: u16) bool {
    return bits == 8 or bits == 16 or bits == 32 or bits == 64;
}

test "a local and an atomic gauge agree step for step" {
    var local: Local(i64) = .zero;
    var atomic: Atomic(i64) = .zero;

    const steps = [_]i64{ 1, 0, -7, 1000, -500, 42 };
    for (steps) |step| {
        local.add(step);
        atomic.add(step);
        try testing.expectEqual(local.get(), atomic.get());
    }

    local.set(-5);
    atomic.set(-5);
    try testing.expectEqual(@as(i64, -5), local.get());
    try testing.expectEqual(@as(i64, -5), atomic.get());
}

test "subtracting to exactly zero is allowed" {
    var local: Local(u64) = .zero;
    var atomic: Atomic(u64) = .zero;
    local.set(9);
    atomic.set(9);

    local.sub(9);
    atomic.sub(9);
    try testing.expectEqual(@as(u64, 0), local.get());
    try testing.expectEqual(@as(u64, 0), atomic.get());

    // One more subtraction would be the underflow the assertion exists to
    // catch, so the test stops at the boundary rather than past it.
    local.set(1);
    atomic.set(1);
    local.dec();
    atomic.dec();
    try testing.expectEqual(@as(u64, 0), local.get());
    try testing.expectEqual(@as(u64, 0), atomic.get());
}

test "a signed gauge goes negative" {
    var local: Local(i64) = .zero;
    var atomic: Atomic(i64) = .zero;

    local.sub(1);
    atomic.sub(1);
    try testing.expectEqual(@as(i64, -1), local.get());
    try testing.expectEqual(@as(i64, -1), atomic.get());

    local.set(math.minInt(i64) + 1);
    atomic.set(math.minInt(i64) + 1);
    local.dec();
    atomic.dec();
    try testing.expectEqual(@as(i64, math.minInt(i64)), local.get());
    try testing.expectEqual(@as(i64, math.minInt(i64)), atomic.get());
}

test "a float gauge reaches the writer as the number it holds" {
    var depth: Local(f64) = .zero;
    depth.set(0.5);
    depth.add(1.0);
    depth.sub(0.25);
    try testing.expectEqual(@as(f64, 1.25), depth.get());

    const Writer = @import("root.zig").prometheus.Writer;
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w: Writer = .init(&out);
    depth.set(1.5);
    try w.writeMetric("queue_depth_ratio", .{}, depth.get());
    try testing.expectEqualStrings("queue_depth_ratio 1.5\n", out.buffered());
}

test "an atomic float sums two adds through the loop" {
    var total: Atomic(f64) = .zero;
    total.add(1.5);
    total.add(2.25);
    try testing.expectEqual(@as(f64, 3.75), total.get());

    var narrow: Atomic(f32) = .zero;
    narrow.add(0.5);
    narrow.add(0.25);
    try testing.expectEqual(@as(f32, 0.75), narrow.get());
}

test "an atomic float converges under contention" {
    // Four threads adding the same amount to one gauge: the compare-exchange
    // loop retries until every add lands, so the total is exact.
    const Worker = struct {
        fn run(gauge: *Atomic(f64)) void {
            for (0..1000) |_| gauge.add(1.0);
        }
    };
    var total: Atomic(f64) = .zero;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{&total});
    for (threads) |thread| thread.join();
    try testing.expectEqual(@as(f64, 4000.0), total.get());
}

test "an atomic float subtracts and goes negative" {
    var level: Atomic(f64) = .zero;
    level.sub(1.5);
    try testing.expectEqual(@as(f64, -1.5), level.get());
    level.set(0.5);
    level.dec();
    try testing.expectEqual(@as(f64, -0.5), level.get());
}

test "the integer type is the gauge's, not the platform's" {
    var byte: Local(u8) = .zero;
    byte.set(255);
    byte.add(1);
    try testing.expectEqual(@as(u8, 0), byte.get());

    var narrow: Atomic(u8) = .zero;
    narrow.set(255);
    narrow.add(1);
    try testing.expectEqual(@as(u8, 0), narrow.get());
}

test "a gauge is one word, in either mode" {
    // The claim a reader cannot see from the type: a gauge costs a word and
    // adds no padding of its own, and an atomic float is no wider than an
    // atomic integer.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Local(u64)));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Atomic(u64)));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Local(f64)));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Atomic(f64)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Local(u64)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Atomic(u64)));

    const Mixed = struct {
        a: u32,
        b: u32,
        depth: Local(u64),
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(Mixed));

    try testing.expectEqual(@sizeOf(Local(u64)), @sizeOf(Local(i64)));
    try testing.expectEqual(@sizeOf(Local(u64)), @sizeOf(Local(f64)));
}
