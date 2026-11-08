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
//! Buckets are cumulative at observe, so the scrape reads what the writer
//! wants and `writeHistogramSeries` takes it unchanged. Reading differs by
//! mode: a local histogram hands out its buckets as a slice, and an atomic one
//! fills a `Snapshot` the caller owns, because a slice of atomics read without
//! `@atomicLoad` is a race.

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

        const is_atomic = S.atomic;

        /// What a scrape reads: the bucket counts, how many observations
        /// there were, and what they summed to. The caller owns the storage,
        /// so this is `[bounds.len]u64` plus two words on the stack. Atomic
        /// slots need it filled; a local histogram can take `counts` and skip
        /// the copy.
        pub const Snapshot = struct {
            buckets: [bounds.len]u64,
            observed: u64,
            total: u64,
        };

        buckets: [bounds.len]S,
        observed: S,
        total: S,

        /// Fill `out` with everything a scrape needs: the counts are already
        /// cumulative, so `&out.buckets`, `out.total`, and `out.observed` go
        /// straight to `writeHistogramSeries`. An atomic histogram has this;
        /// a local one has `counts`.
        pub fn snapshot(self: *const Self, out: *Snapshot) void {
            inline for (0..bounds.len) |i| out.buckets[i] = self.buckets[i].get();
            out.total = self.total.get();
            out.observed = self.observed.get();
        }

        /// The bucket counts, borrowed from the histogram. The slots are one
        /// integer each and nothing sits between them, so this is the
        /// histogram's own bytes rather than a copy.
        pub fn counts(self: *const Self) []const u64 {
            comptime assert(!is_atomic);
            comptime assert(@sizeOf(Slot) == @sizeOf(u64));
            comptime assert(@alignOf(Slot) == @alignOf(u64));
            const slots: [*]const u64 = @ptrCast(&self.buckets);
            return slots[0..bounds.len];
        }

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

        /// A histogram with nothing observed.
        pub const zero: Self = .{
            .buckets = @splat(.zero),
            .observed = .zero,
            .total = .zero,
        };
    };
}

/// `count` bounds from `start`, each `width` above the one before, for
/// `Fixed(S, &histogram.linear(1, 10, 5))`. The `+Inf` bucket is implicit, so
/// `count` is the finite buckets only.
pub fn linear(comptime start: f64, comptime width: f64, comptime count: usize) [count]f64 {
    var bounds: [count]f64 = undefined;
    for (0..count) |i| {
        const step: f64 = @floatFromInt(i);
        bounds[i] = start + width * step;
    }
    return bounds;
}

/// `count` bounds from `start`, each one `factor` times the last, for
/// `Fixed(S, &histogram.exponential(1, 2, 10))`. Same implicit `+Inf`.
pub fn exponential(comptime start: f64, comptime factor: f64, comptime count: usize) [count]f64 {
    var bounds: [count]f64 = undefined;
    var bound = start;
    for (0..count) |i| {
        bounds[i] = bound;
        bound *= factor;
    }
    return bounds;
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

    try testing.expectEqualSlices(u64, &.{ 0, 0 }, histogram.counts());
    try testing.expectEqual(@as(u64, 1), histogram.observed.get());
    try testing.expectEqual(@as(u64, 101), histogram.total.get());
}

test "the top bucket and the count agree when nothing overflows it" {
    const Histogram = Fixed(counter.Local(u64), &.{ 10, 100 });
    var histogram: Histogram = .zero;
    histogram.observe(1);
    histogram.observe(50);
    histogram.observe(100);

    const counts = histogram.counts();
    try testing.expectEqual(@as(u64, 3), counts[counts.len - 1]);
    try testing.expectEqual(histogram.observed.get(), counts[counts.len - 1]);
}

test "counts on a local histogram is a view, not a copy" {
    const Histogram = Fixed(counter.Local(u64), &.{10});
    var histogram: Histogram = .zero;
    histogram.observe(5);

    const counts = histogram.counts();
    try testing.expectEqual(@as(u64, 1), counts[0]);
    histogram.observe(5);
    try testing.expectEqual(@as(u64, 2), counts[0]);
}

test "the sum is exact above 2^53" {
    const big: u64 = (1 << 53) + 1;
    const Histogram = Fixed(counter.Local(u64), &.{});
    var histogram: Histogram = .zero;
    histogram.observe(big);
    histogram.observe(1);

    try testing.expectEqual(big + 1, histogram.total.get());
}

test "empty bounds are legal and keep only the count" {
    const Histogram = Fixed(counter.Local(u64), &.{});
    var histogram: Histogram = .zero;
    histogram.observe(7);
    histogram.observe(9);

    try testing.expectEqual(@as(usize, 0), histogram.counts().len);
    try testing.expectEqual(@as(u64, 2), histogram.observed.get());
    try testing.expectEqual(@as(u64, 16), histogram.total.get());
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

    var snap: Atomic.Snapshot = undefined;
    atomic.snapshot(&snap);
    try testing.expectEqualSlices(u64, &snap.buckets, local.counts());
    try testing.expectEqual(snap.observed, local.observed.get());
    try testing.expectEqual(snap.total, local.total.get());
}

test "linear bounds step by width" {
    const bounds = linear(1, 10, 4);
    try testing.expectEqualSlices(f64, &.{ 1, 11, 21, 31 }, &bounds);
}

test "exponential bounds multiply by the factor" {
    const bounds = exponential(1, 2, 4);
    try testing.expectEqualSlices(f64, &.{ 1, 2, 4, 8 }, &bounds);
}

test "a histogram takes generated bounds" {
    const Histogram = Fixed(counter.Local(u64), &linear(1, 10, 3));
    var histogram: Histogram = .zero;
    histogram.observe(5);
    try testing.expectEqualSlices(u64, &.{ 0, 1, 1 }, histogram.counts());
}
