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
//!
//! A histogram is additive, which is what a per-worker collect-then-aggregate
//! scrape needs: `merge` adds one histogram into another and `mergeAll` folds a
//! slice of them into one `Snapshot`, adding the buckets, the count, and the
//! sum. `mergeAllPtrs` is the same fold over pointers, for histograms that live
//! in another struct. All of it wraps like the counters it adds, and none of it
//! takes a lock.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const math = std.math;
const builtin = @import("builtin");

const counter = @import("counter.zig");

/// A histogram with `bounds.len` finite buckets. `S` is a recording counter
/// type whose value is `u64`, such as `counter.Atomic(u64)`.
pub fn Fixed(comptime S: type, comptime bounds: []const f64) type {
    comptime checkType(S);
    comptime checkBounds(bounds);
    return struct {
        const Self = @This();

        /// The bucket limits, the array `writeHistogram` takes.
        pub const limits = bounds;
        pub const Slot = S;

        const is_atomic = S.atomic;

        /// What a scrape reads: the bucket counts, how many observations
        /// there were, and what they summed to. The caller owns the storage,
        /// so this is `[bounds.len]u64` plus two words on the stack. Atomic
        /// slots need it filled; a local histogram can take `counts` and skip
        /// the copy.
        pub const Snapshot = struct {
            /// The bucket limits this snapshot counts, so a writer can take a
            /// folded `Snapshot` where it takes the histogram it came from.
            pub const limits = bounds;

            buckets: [bounds.len]u64,
            observed: u64,
            total: u64,

            /// A snapshot with nothing counted, which is what a fold starts
            /// from.
            pub const zero: Snapshot = .{
                .buckets = @splat(0),
                .observed = 0,
                .total = 0,
            };

            /// Add every number in `other` into this snapshot: the buckets,
            /// the count, and the sum. Wraps at `maxInt(u64)`, like the
            /// counters being folded, so a merge cannot saturate what the
            /// observations would have wrapped.
            pub fn merge(self: *Snapshot, other: *const Snapshot) void {
                addBuckets(bounds.len, &self.buckets, &other.buckets);
                self.observed +%= other.observed;
                self.total +%= other.total;
            }

            /// Every snapshot in `others` added together, as if each one were
            /// merged in turn. One call holds the total in registers instead of
            /// writing it back per `merge`, which measures about 2.7x a
            /// caller's merge loop at twelve buckets.
            pub fn mergeAll(others: []const Snapshot) Snapshot {
                var out: Snapshot = .zero;
                for (others) |*other| out.merge(other);
                return out;
            }

            /// `mergeAll` over a slice of pointers, for the snapshots that
            /// live in another struct instead of in a buffer of their own. The
            /// two agree count for count; only the indirection differs.
            pub fn mergeAllPtrs(others: []const *const Snapshot) Snapshot {
                var out: Snapshot = .zero;
                for (others) |other| out.merge(other);
                return out;
            }
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
            return bucketWordsConst(self);
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

        /// Add `other` into this histogram: its buckets, its count, and its
        /// sum. `other` is read before this histogram is written, so the two
        /// may be the same histogram, which doubles it.
        pub fn merge(self: *Self, other: *const Self) void {
            comptime assert(!is_atomic);
            addBuckets(bounds.len, bucketWords(self), bucketWordsConst(other));
            self.observed.add(other.observed.get());
            self.total.add(other.total.get());
        }

        /// Every histogram in `histograms` added together, as if each one were
        /// merged in turn, and handed back as the snapshot a scrape writes.
        /// One call holds the total in registers instead of writing it back
        /// per `merge`.
        pub fn mergeAll(histograms: []const Self) Snapshot {
            comptime assert(!is_atomic);
            var out: Snapshot = .zero;
            for (histograms) |*histogram| foldInto(histogram, &out);
            return out;
        }

        /// `mergeAll` over a slice of pointers, for the histograms that live
        /// in another struct instead of in a run of their own: a worker's
        /// histogram is a field of the worker's struct, not next to the next
        /// worker's, and copying it into an array to fold it is the work this
        /// avoids. The two agree count for count; only the indirection
        /// differs.
        pub fn mergeAllPtrs(histograms: []const *const Self) Snapshot {
            comptime assert(!is_atomic);
            var out: Snapshot = .zero;
            for (histograms) |histogram| foldInto(histogram, &out);
            return out;
        }

        /// One histogram's numbers added into a snapshot, which is the whole
        /// body of both folds.
        fn foldInto(histogram: *const Self, out: *Snapshot) void {
            addBuckets(bounds.len, &out.buckets, bucketWordsConst(histogram));
            out.observed +%= histogram.observed.get();
            out.total +%= histogram.total.get();
        }

        /// The buckets as plain words, borrowed and writable, which is what a
        /// merge adds into.
        fn bucketWords(self: *Self) *[bounds.len]u64 {
            comptime checkSlots();
            return @ptrCast(&self.buckets);
        }

        /// The same view, read-only, which is what `counts` hands out and what
        /// a fold reads.
        fn bucketWordsConst(self: *const Self) *const [bounds.len]u64 {
            comptime checkSlots();
            return @ptrCast(&self.buckets);
        }

        /// What makes a slot readable as a plain word: one integer per slot
        /// with no padding, and not atomic, where a plain read would race.
        fn checkSlots() void {
            comptime assert(!is_atomic);
            comptime assert(@sizeOf(Slot) == @sizeOf(u64));
            comptime assert(@alignOf(Slot) == @alignOf(u64));
        }

        /// A histogram with nothing observed.
        pub const zero: Self = .{
            .buckets = @splat(.zero),
            .observed = .zero,
            .total = .zero,
        };
    };
}

/// How many counts one bucket add moves: the register this target really has.
///
/// aarch64 answers 256 bits for any SVE core, but SVE's wide registers are not
/// reachable through `@Vector`, so a 256-bit value is two NEON ops with no gain
/// over one. Measured folding sixteen 32-bucket histograms: 81 ns at four
/// lanes, 56 ns at two. On x86 the answer is the register itself.
const lanes: usize = if (builtin.cpu.arch.isAARCH64())
    2
else
    std.simd.suggestVectorLength(u64) orelse 1;

/// `dest` plus `src` over `n` counts, one vector register at a time, with a
/// scalar for each count that does not fill one. Wrapping, because the counts
/// are counters.
fn addBuckets(comptime n: usize, dest: *[n]u64, src: *const [n]u64) void {
    const Vec = @Vector(lanes, u64);
    comptime var i: usize = 0;
    inline while (i + lanes <= n) : (i += lanes) {
        const a: Vec = dest[i..][0..lanes].*;
        const b: Vec = src[i..][0..lanes].*;
        dest[i..][0..lanes].* = a +% b;
    }
    inline while (i < n) : (i += 1) dest[i] +%= src[i];
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
        @compileError(
            "metrics: histogram.Fixed's slot is a recording counter type, not " ++ @typeName(S),
        );
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
                @compileError(
                    "metrics: histogram.Fixed bounds must be ascending, and this one is not",
                );
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

    // A fold over histograms with no buckets is the count and the sum alone.
    var folded: Histogram = .zero;
    folded.observe(1);
    const total = Histogram.mergeAll(&.{ histogram, folded });
    try testing.expectEqual(@as(usize, 0), total.buckets.len);
    try testing.expectEqual(@as(u64, 3), total.observed);
    try testing.expectEqual(@as(u64, 17), total.total);
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

test "a merge counts what observing both halves would have" {
    const Histogram = Fixed(counter.Local(u64), &.{ 1, 10, 100, 1e6 });
    const first = [_]u64{ 0, 1, 9, 10, 500 };
    const second = [_]u64{ 11, 99, 100, 1e6 + 1, 42 };

    var merged: Histogram = .zero;
    var one: Histogram = .zero;
    var other: Histogram = .zero;
    for (first) |v| {
        one.observe(v);
        merged.observe(v);
    }
    for (second) |v| {
        other.observe(v);
        merged.observe(v);
    }

    var folded: Histogram = .zero;
    folded.merge(&one);
    folded.merge(&other);

    try testing.expectEqualSlices(u64, merged.counts(), folded.counts());
    try testing.expectEqual(merged.observed.get(), folded.observed.get());
    try testing.expectEqual(merged.total.get(), folded.total.get());
}

test "a histogram merged with itself doubles, because it may alias" {
    const Histogram = Fixed(counter.Local(u64), &.{ 10, 100 });
    var histogram: Histogram = .zero;
    histogram.observe(5);
    histogram.observe(50);

    var twice: Histogram = .zero;
    twice.merge(&histogram);
    twice.merge(&histogram);

    // The second bucket is cumulative, so it already held both observations.
    try testing.expectEqualSlices(u64, &.{ 2, 4 }, twice.counts());
    try testing.expectEqual(@as(u64, 4), twice.observed.get());
    try testing.expectEqual(@as(u64, 110), twice.total.get());
}

test "a snapshot names the limits it was folded from" {
    const Histogram = Fixed(counter.Local(u64), &.{ 1, 10, 100 });
    try testing.expectEqualSlices(f64, Histogram.limits, Histogram.Snapshot.limits);
    try testing.expectEqual(Histogram.limits.ptr, Histogram.Snapshot.limits.ptr);
}

test "a snapshot merge and a histogram merge agree" {
    const Histogram = Fixed(counter.Local(u64), &.{ 1, 10, 100, 1e6 });
    var one: Histogram = .zero;
    var other: Histogram = .zero;
    one.observe(3);
    other.observe(70);

    var merged_histograms: Histogram = .zero;
    merged_histograms.merge(&one);
    merged_histograms.merge(&other);

    var left: Histogram.Snapshot = undefined;
    var right: Histogram.Snapshot = undefined;
    one.snapshot(&left);
    other.snapshot(&right);
    right.merge(&left);

    var snap: Histogram.Snapshot = undefined;
    merged_histograms.snapshot(&snap);
    try testing.expectEqualSlices(u64, &snap.buckets, &right.buckets);
    try testing.expectEqual(snap.observed, right.observed);
    try testing.expectEqual(snap.total, right.total);
}

test "a fold is the merge loop, count for count" {
    const Histogram = Fixed(counter.Local(u64), &.{ 1, 10, 100, 1e6 });

    var workers: [7]Histogram = undefined;
    for (&workers, 0..) |*histogram, i| {
        histogram.* = .zero;
        var v: u64 = i * 37;
        while (v < 1e6) : (v += 91) histogram.observe(v);
    }

    var looped: Histogram = .zero;
    for (&workers) |*histogram| looped.merge(histogram);

    var snapshots: [workers.len]Histogram.Snapshot = undefined;
    for (&workers, 0..) |*histogram, i| histogram.snapshot(&snapshots[i]);

    var pointers: [workers.len]*const Histogram = undefined;
    for (&workers, 0..) |*histogram, i| pointers[i] = histogram;

    var snapshot_pointers: [workers.len]*const Histogram.Snapshot = undefined;
    for (&snapshots, 0..) |*snap, i| snapshot_pointers[i] = snap;

    var from_loop: Histogram.Snapshot = undefined;
    looped.snapshot(&from_loop);

    // Every entry point is the loop, count for count, and the value and
    // pointer forms of a fold agree with each other.
    const folds = [_]Histogram.Snapshot{
        Histogram.mergeAll(&workers),
        Histogram.mergeAllPtrs(&pointers),
        Histogram.Snapshot.mergeAll(&snapshots),
        Histogram.Snapshot.mergeAllPtrs(&snapshot_pointers),
    };
    for (folds) |folded| {
        try testing.expectEqualSlices(u64, &from_loop.buckets, &folded.buckets);
        try testing.expectEqual(from_loop.observed, folded.observed);
        try testing.expectEqual(from_loop.total, folded.total);
    }
}

test "a fold of nothing is the empty snapshot" {
    const Histogram = Fixed(counter.Local(u64), &.{ 1, 10 });
    const folds = [_]Histogram.Snapshot{
        Histogram.mergeAll(&.{}),
        Histogram.mergeAllPtrs(&.{}),
        Histogram.Snapshot.mergeAll(&.{}),
        Histogram.Snapshot.mergeAllPtrs(&.{}),
    };
    for (folds) |folded| {
        try testing.expectEqualDeep(Histogram.Snapshot.zero, folded);
        try testing.expectEqualSlices(u64, &.{ 0, 0 }, &folded.buckets);
    }
}

test "a merge wraps like the counters it adds" {
    const Histogram = Fixed(counter.Local(u64), &.{10});
    var histogram: Histogram = .zero;
    histogram.buckets[0].add(math.maxInt(u64));
    histogram.observed.add(math.maxInt(u64));
    histogram.total.add(math.maxInt(u64));

    var merged: Histogram = .zero;
    merged.merge(&histogram);
    merged.merge(&histogram);

    try testing.expectEqualSlices(u64, &.{math.maxInt(u64) - 1}, merged.counts());
    try testing.expectEqual(math.maxInt(u64) - 1, merged.observed.get());
    try testing.expectEqual(math.maxInt(u64) - 1, merged.total.get());

    var snap: Histogram.Snapshot = undefined;
    merged.snapshot(&snap);
    snap.merge(&snap);
    try testing.expectEqual(math.maxInt(u64) - 3, snap.observed);
}

test "a fold past a vector boundary still adds every bucket" {
    // Lengths on either side of the vector width, so the scalar tail and the
    // empty vector loop are both exercised.
    inline for (.{ 0, 1, 2, 3, 5, 8, 13 }) |n| {
        const Histogram = Fixed(counter.Local(u64), &linear(1, 1, n));
        var workers: [3]Histogram = undefined;
        for (&workers, 0..) |*histogram, i| {
            histogram.* = .zero;
            for (0..n) |b| {
                var left = i + 1;
                while (left > 0) : (left -= 1) histogram.buckets[b].inc();
            }
            histogram.observed.add(i + 1);
            histogram.total.add(i + 1);
        }

        var pointers: [workers.len]*const Histogram = undefined;
        for (&workers, 0..) |*histogram, i| pointers[i] = histogram;

        const folded = Histogram.mergeAllPtrs(&pointers);
        // Bucket `b` holds 1 + 2 + 3 observations and every bucket above it
        // holds at least as many, because nothing observed exceeds a bound.
        for (folded.buckets) |count| try testing.expectEqual(@as(u64, 6), count);
        try testing.expectEqual(@as(u64, 6), folded.observed);
        try testing.expectEqual(@as(u64, 6), folded.total);
    }
}
