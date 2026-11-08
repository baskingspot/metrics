//! A recording gauge: a number that moves both ways, with the storage chosen by
//! the constructor and the value type by the argument.
//!
//! `Local(T)` is one field and belongs to whoever holds it, which is a worker
//! thread or a struct the caller already owns. `Atomic(T)` stores the same value
//! with monotonic atomic operations, and a float as the integer of its bit
//! pattern, for a gauge a scrape reads while another thread writes it.
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
const Io = std.Io;

const storage = @import("storage.zig");

/// A gauge whose field the caller owns. Only the owner writes it.
///
/// The name says the storage; the argument says the value type. `Local(i64)` is
/// an `i64` field, `Local(f64)` an `f64`, and `Atomic(u32)` an atomic `u32`.
pub fn Local(comptime T: type) type {
    comptime checkNumber(T, "gauge.Local");
    return Gauge(storage.Storage(.local, T));
}

/// A gauge any thread may write and any thread may read: an integer or a float.
pub fn Atomic(comptime T: type) type {
    comptime checkNumber(T, "gauge.Atomic");
    return Gauge(storage.Storage(.atomic, T));
}

fn checkNumber(comptime T: type, comptime constructor: []const u8) void {
    comptime if (!storage.isNumber(T)) {
        @compileError("metrics: " ++ constructor ++ "(T) takes an integer, f32, or f64, not " ++ @typeName(T));
    };
}

fn Gauge(comptime S: type) type {
    return struct {
        const Self = @This();

        pub const ValueType = S.Value;

        value: S,

        /// Replace the value.
        pub inline fn set(self: *Self, v: S.Value) void {
            self.value.store(v);
        }

        /// Add `n`. Wraps at `maxInt(T)`.
        pub inline fn add(self: *Self, n: S.Value) void {
            self.value.add(n);
        }

        /// Subtract `n`, wrapping at the type's bounds.
        ///
        /// Nothing here looks for a dip below the type's floor. A gauge that
        /// goes negative is a `+` and a `-` that do not match, and the
        /// arithmetic cannot find the second one; saturating would turn the
        /// mismatch into a flat line, which is the same bug with less evidence.
        /// A float has no floor at all: going negative is the point.
        pub inline fn sub(self: *Self, n: S.Value) void {
            self.value.sub(n);
        }

        /// One more.
        pub inline fn inc(self: *Self) void {
            self.add(1);
        }

        /// One less.
        pub inline fn dec(self: *Self) void {
            self.sub(1);
        }

        /// The value now.
        pub inline fn get(self: *const Self) S.Value {
            return self.value.load();
        }

        /// A gauge at zero.
        pub const zero: Self = .{ .value = S.zero };
    };
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

    // A decrement to exactly zero is the boundary. One more wraps, and the
    // wrap is the caller's to avoid, so the test stops here.
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
