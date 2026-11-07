//! A recording gauge: a number that moves both ways, with the storage and the
//! concurrency model chosen where it is declared.
//!
//! `Int(T)` and `Float(T)` are one field. They belong to whoever holds them,
//! which is a worker thread or a struct the caller already owns. `Atomic(T)`
//! takes either and is a `std.atomic.Value` with monotonic operations, for a
//! gauge a scrape reads while another thread writes it.
//!
//! A gauge holds a temperature, a delta, a queue depth that dips below its last
//! reading, so its integer may be signed and its float is `f32` or `f64`. The
//! counter has neither.
//!
//! An atomic float is an integer atomic holding the bit pattern: `set` and `get`
//! are a store and a load, and `add` and `sub` are a compare-exchange loop.
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

/// A gauge whose field the caller owns, holding an integer. Only the owner
/// writes it.
pub fn Int(comptime T: type) type {
    comptime if (@typeInfo(T) != .int) {
        @compileError("metrics: gauge.Int(T) takes an integer, not " ++ @typeName(T));
    };
    return Gauge(.plain, T);
}

/// A gauge whose field the caller owns, holding an `f32` or an `f64`.
pub fn Float(comptime T: type) type {
    comptime if (@typeInfo(T) != .float) {
        @compileError("metrics: gauge.Float(T) takes f32 or f64, not " ++ @typeName(T));
    };
    return Gauge(.plain, T);
}

/// A gauge any thread may write and any thread may read: an integer or a float.
pub fn Atomic(comptime T: type) type {
    return Gauge(.atomic, T);
}

fn Gauge(comptime mode: Mode, comptime T: type) type {
    comptime checkType(mode, T);
    return struct {
        const Self = @This();
        const Bits = AtomicBits(T);

        pub const concurrency = mode;
        pub const ValueType = T;

        value: Storage,

        /// Replace the value.
        pub inline fn set(self: *Self, v: T) void {
            switch (mode) {
                .plain => self.value = v,
                .atomic => self.value.store(bitCastToBits(v), .monotonic),
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
                .atomic => {
                    if (comptime isFloat(T)) {
                        self.fetchFloat(n);
                    } else {
                        _ = self.value.fetchAdd(n, .monotonic);
                    }
                },
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
                    if (comptime isFloat(T)) {
                        self.fetchFloat(-n);
                    } else {
                        const previous = self.value.fetchSub(n, .monotonic);
                        if (comptime hasFloor(T)) assert(previous >= n);
                    }
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
                .atomic => @bitCast(self.value.load(.monotonic)),
            };
        }

        /// The compare-exchange loop an atomic float needs. An integer atomic
        /// has `fetchAdd`; a float one does not, so this loads the bit pattern,
        /// computes the new one, and retries if another thread won the race.
        fn fetchFloat(self: *Self, n: T) void {
            // A no-op add does not need to contend for the line.
            if (n == 0) return;
            var current: Bits = self.value.load(.monotonic);
            while (true) {
                const next: Bits = bitCastToBits(@as(T, @bitCast(current)) + n);
                if (self.value.cmpxchgWeak(current, next, .monotonic, .monotonic)) |observed| {
                    current = observed;
                } else return;
            }
        }

        const Storage = switch (mode) {
            .plain => T,
            .atomic => Value(Bits),
        };

        /// A gauge at zero. The way to make one: `Int(u64).zero`.
        pub const zero: Self = .{ .value = switch (mode) {
            .plain => 0,
            .atomic => .init(0),
        } };
    };
}

/// The integer an atomic gauge stores: the type itself for an integer, and the
/// bit pattern for a float.
fn AtomicBits(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => T,
        .float => |info| switch (info.bits) {
            32 => u32,
            64 => u64,
            else => @compileError("metrics: an atomic gauge is 32 or 64 bits, not " ++ @typeName(T)),
        },
        else => @compileError("metrics: a gauge's type is an integer or a float, not " ++ @typeName(T)),
    };
}

fn bitCastToBits(v: anytype) AtomicBits(@TypeOf(v)) {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .int => v,
        .float => @bitCast(v),
        else => @compileError("unreachable"),
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
        .float => {},
        else => @compileError("metrics: a gauge's type is an integer or a float, not " ++ @typeName(T)),
    }
}

fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// True when `sub` has a floor to enforce: an unsigned type has one at zero, a
/// signed integer and a float do not.
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

test "a float gauge reaches the writer as the number it holds" {
    var depth: Float(f64) = .zero;
    depth.set(0.5);
    depth.add(1.0);
    depth.sub(0.25);
    try testing.expectEqual(@as(f64, 1.25), depth.get());

    const metrics_writer = @import("root.zig").prometheus.Writer;
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w: metrics_writer = .init(&out);
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
    // Four threads adding the same amount to one gauge: the CAS loop retries
    // until every add lands, so the total is exact even though the adds race.
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
    try testing.expectEqual(@as(usize, 8), @sizeOf(Float(f64)));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Atomic(f64)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Int(u64)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Atomic(u64)));

    // A gauge lands in space the struct already had.
    const Mixed = struct {
        a: u32,
        b: u32,
        depth: Int(u64),
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(Mixed));

    // A signed gauge and a float one are the same width as an unsigned one.
    try testing.expectEqual(@sizeOf(Int(u64)), @sizeOf(Int(i64)));
    try testing.expectEqual(@sizeOf(Int(u64)), @sizeOf(Float(f64)));
}
