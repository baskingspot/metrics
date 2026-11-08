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
const math = std.math;

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
        /// What a scrape reads: the bucket counts, how many observations there
        /// were, and what they summed to. The caller owns the storage, so this
        /// is `[bounds.len]u64` plus two words on the stack.
        pub const Snapshot = struct {
            buckets: [bounds.len]u64,
            observed: u64,
            total: u64,
        };

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

        /// Fill `out` with everything a scrape needs: the counts are already
        /// cumulative, so `&out.buckets`, `out.total`, and `out.observed` go
        /// straight to `writeHistogramSeries`.
        pub fn snapshot(self: *const Self, out: *Snapshot) void {
            inline for (0..bounds.len) |i| out.buckets[i] = self.buckets[i].get();
            out.total = self.total.get();
            out.observed = self.observed.get();
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
        var previous: f64 = -math.inf(f64);
        for (bounds, 0..) |bound, i| {
            if (!math.isFinite(bound)) {
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
    const Histogram = Fixed(counter.Atomic(u64), &.{ 10, 100 });
    var histogram: Histogram = .zero;
    histogram.observe(10);

    var snap: Histogram.Snapshot = undefined;
    histogram.snapshot(&snap);
    try testing.expectEqualSlices(u64, &.{ 1, 1 }, &snap.buckets);
    try testing.expectEqual(@as(u64, 1), snap.observed);
    try testing.expectEqual(@as(u64, 10), snap.total);
}

test "a value above the largest bound increments only the count" {
    const Histogram = Fixed(counter.Local(u64), &.{ 10, 100 });
    var histogram: Histogram = .zero;
    histogram.observe(101);

    var snap: Histogram.Snapshot = undefined;
    histogram.snapshot(&snap);
    try testing.expectEqualSlices(u64, &.{ 0, 0 }, &snap.buckets);
    try testing.expectEqual(@as(u64, 1), snap.observed);
    try testing.expectEqual(@as(u64, 101), snap.total);
}

test "the top bucket and the count agree when nothing overflows it" {
    const Histogram = Fixed(counter.Local(u64), &.{ 10, 100 });
    var histogram: Histogram = .zero;
    histogram.observe(1);
    histogram.observe(50);
    histogram.observe(100);

    var snap: Histogram.Snapshot = undefined;
    histogram.snapshot(&snap);
    try testing.expectEqual(@as(u64, 3), snap.buckets[snap.buckets.len - 1]);
    try testing.expectEqual(snap.observed, snap.buckets[snap.buckets.len - 1]);
}

test "the sum is exact above 2^53" {
    const big: u64 = (1 << 53) + 1;
    const Histogram = Fixed(counter.Local(u64), &.{});
    var histogram: Histogram = .zero;
    histogram.observe(big);
    histogram.observe(1);

    var snap: Histogram.Snapshot = undefined;
    histogram.snapshot(&snap);
    try testing.expectEqual(big + 1, snap.total);
}

test "empty bounds are legal and keep only the count" {
    const Histogram = Fixed(counter.Local(u64), &.{});
    var histogram: Histogram = .zero;
    histogram.observe(7);
    histogram.observe(9);

    var snap: Histogram.Snapshot = undefined;
    histogram.snapshot(&snap);
    try testing.expectEqual(@as(usize, 0), snap.buckets.len);
    try testing.expectEqual(@as(u64, 2), snap.observed);
    try testing.expectEqual(@as(u64, 16), snap.total);
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

    var local_snap: Local.Snapshot = undefined;
    var atomic_snap: Atomic.Snapshot = undefined;
    local.snapshot(&local_snap);
    atomic.snapshot(&atomic_snap);
    try testing.expectEqualSlices(u64, &local_snap.buckets, &atomic_snap.buckets);
    try testing.expectEqual(local_snap.observed, atomic_snap.observed);
    try testing.expectEqual(local_snap.total, atomic_snap.total);
}
