//! A fixed-bucket histogram: a bucket array, a count, and a sum, each slot the
//! same recording counter type the caller picks.
//!
//! `Fixed(counter.Atomic(u64), &.{ 10, 100 })` gives atomic buckets for a
//! scrape that reads while workers observe. `Fixed(counter.Local(u64), ...)`
//! gives plain fields for a histogram one thread owns. The sum is exact because
//! it is an integer counter, not a float, so nothing loses digits above 2^53.
//!
//! Observations are `u64`: a byte count, a subscriber count, or microseconds.
//! Microseconds stand in for seconds the same way the counter accumulates
//! nanoseconds, which keeps the comparison and the sum in whole numbers.
//!
//! Buckets are cumulative at observe, so `counts` is already what the writer
//! wants and `writeHistogramSeries` takes it unchanged.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const counter = @import("counter.zig");

/// A histogram with `bounds.len` finite buckets. `S` is a recording counter
/// type whose value is `u64`, such as `counter.Atomic(u64)`.
pub fn Fixed(comptime S: type, comptime bounds: []const f64) type {
    comptime checkType(S);
    comptime checkBounds(bounds);
    return struct {
        const Self = @This();

        pub const Bounds = bounds;
        pub const Slot = S;

        buckets: [bounds.len]S,
        observed: S,
        total: S,

        /// One observation of `v`. Every bucket whose bound is at or above `v`
        /// goes up, which is what makes the counts cumulative.
        pub fn observe(self: *Self, v: u64) void {
            // Bounds are `f64` and observations are `u64`, so this converts.
            // Exact below 2^53 (nine petabytes, or 104 days of microseconds)
            // and approximate above it.
            const value: f64 = @floatFromInt(v);
            inline for (bounds, 0..) |bound, i| {
                if (value <= bound) self.buckets[i].inc();
            }
            self.observed.inc();
            self.total.add(v);
        }

        /// How many observations there were.
        pub fn count(self: *const Self) u64 {
            return self.observed.get();
        }

        /// The sum of the observed values, which is exact because the slot's
        /// value type is `u64`.
        pub fn sumValue(self: *const Self) u64 {
            return self.total.get();
        }

        /// Fill `out` from the slots and hand back the slice. The caller owns
        /// the storage: `[bounds.len]u64` on the stack, no allocation, and the
        /// result goes straight to `writeHistogramSeries`.
        pub fn counts(self: *const Self, out: *[bounds.len]u64) []const u64 {
            inline for (0..bounds.len) |i| out[i] = self.buckets[i].get();
            return out;
        }

        /// A histogram with nothing observed.
        pub const zero: Self = .{
            .buckets = @splat(.zero),
            .observed = .zero,
            .total = .zero,
        };
    };
}

fn checkType(comptime S: type) void {
    comptime if (!@hasDecl(S, "zero") or !@hasDecl(S, "inc") or !@hasDecl(S, "get")) {
        @compileError("metrics: histogram.Fixed's slot is a recording counter type, not " ++ @typeName(S));
    };
    comptime if (@typeInfo(S.ValueType) != .int) {
        @compileError("metrics: histogram.Fixed's slot counts an integer, and " ++
            @typeName(S.ValueType) ++ " is not one");
    };
}

fn checkBounds(comptime bounds: []const f64) void {
    comptime {
        var previous: f64 = -std.math.inf(f64);
        for (bounds, 0..) |bound, i| {
            if (!std.math.isFinite(bound)) {
                @compileError("metrics: histogram.Fixed bounds must be finite");
            }
            if (i > 0 and !(bound > previous)) {
                @compileError("metrics: histogram.Fixed bounds must be ascending, and this one is not");
            }
            previous = bound;
        }
    }
}

test "a value on a bound lands in that bucket and every one above it" {
    var histogram: Fixed(counter.Atomic(u64), &.{ 10, 100 }) = .zero;
    histogram.observe(10);

    var buffer: [2]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 1, 1 }, histogram.counts(&buffer));
    try testing.expectEqual(@as(u64, 1), histogram.count());
    try testing.expectEqual(@as(u64, 10), histogram.sumValue());
}

test "a value above the largest bound increments only the count" {
    var histogram: Fixed(counter.Local(u64), &.{ 10, 100 }) = .zero;
    histogram.observe(101);

    var buffer: [2]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 0, 0 }, histogram.counts(&buffer));
    try testing.expectEqual(@as(u64, 1), histogram.count());
    try testing.expectEqual(@as(u64, 101), histogram.sumValue());
}

test "the top bucket and the count agree when nothing overflows it" {
    var histogram: Fixed(counter.Local(u64), &.{ 10, 100 }) = .zero;
    histogram.observe(1);
    histogram.observe(50);
    histogram.observe(100);

    var buffer: [2]u64 = undefined;
    const counts = histogram.counts(&buffer);
    try testing.expectEqual(@as(u64, 3), counts[counts.len - 1]);
    try testing.expectEqual(histogram.count(), counts[counts.len - 1]);
}

test "the sum is exact above 2^53" {
    const big: u64 = (1 << 53) + 1;
    var histogram: Fixed(counter.Local(u64), &.{}) = .zero;
    histogram.observe(big);
    histogram.observe(1);
    try testing.expectEqual(big + 1, histogram.sumValue());
}

test "empty bounds are legal and keep only the count" {
    var histogram: Fixed(counter.Local(u64), &.{}) = .zero;
    histogram.observe(7);
    histogram.observe(9);

    var buffer: [0]u64 = undefined;
    try testing.expectEqual(@as(usize, 0), histogram.counts(&buffer).len);
    try testing.expectEqual(@as(u64, 2), histogram.count());
    try testing.expectEqual(@as(u64, 16), histogram.sumValue());
}

test "both slot types agree step for step" {
    const bounds = [_]f64{ 1, 10, 1e6 };
    const Atomic = Fixed(counter.Atomic(u64), &bounds);
    const Local = Fixed(counter.Local(u64), &bounds);

    var atomic: Atomic = .zero;
    var local: Local = .zero;

    const observations = [_]u64{ 0, 1, 2, 10, 11, 1e6, 1e6 + 1, 500 };
    for (observations) |v| {
        atomic.observe(v);
        local.observe(v);
    }

    var atomic_counts: [bounds.len]u64 = undefined;
    var local_counts: [bounds.len]u64 = undefined;
    try testing.expectEqualSlices(u64, local.counts(&local_counts), atomic.counts(&atomic_counts));
    try testing.expectEqual(local.count(), atomic.count());
    try testing.expectEqual(local.sumValue(), atomic.sumValue());
}
