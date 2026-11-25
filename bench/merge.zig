//! What folding per-worker histograms costs: the counts added per second, in
//! the two shapes the API allows.
//!
//! `Merge/*/loop` is `merge` once per worker into one accumulator, which is the
//! primitive. `Merge/*/fold` is `mergeAllPtrs` over the whole run, which is the
//! same arithmetic with the accumulator in registers instead of memory, pointer
//! array included. It is the pointer form because that is the slower of the two
//! folds, so the row is the conservative number. The pair is the evidence for
//! the difference the guide quotes, so it runs on every `just bench` and on
//! every CI pass.
//!
//! Bytes per second counts each bucket read once: `buckets * 8 * workers`. A
//! worker count of sixteen is a full machine folding itself in.

const std = @import("std");
const metrics = @import("metrics");
const testingx = @import("testingx");

const counter = metrics.counter;
const histogram = metrics.histogram;

const workers = 16;

fn Histogram(comptime buckets: usize) type {
    return histogram.Fixed(counter.Local(u64), &histogram.linear(1, 100, buckets));
}

/// Deterministic counts, so a run is repeatable and a diff is a real change.
fn fill(comptime buckets: usize, all: *[workers]Histogram(buckets)) void {
    for (all, 0..) |*histogram_, worker| {
        histogram_.* = .zero;
        for (0..buckets) |bucket| {
            var n: u64 = (worker + 1) * (buckets - bucket);
            while (n > 0) : (n -= 1) histogram_.buckets[bucket].inc();
        }
        histogram_.observed.add(worker + 1);
        histogram_.total.add((worker + 1) * 1000);
    }
}

/// `merge` once per worker, into an accumulator that lives in memory.
fn MergeLoop(comptime buckets: usize) type {
    return struct {
        fn run(b: *testingx.B) anyerror!void {
            @setEvalBranchQuota(100_000);
            var all: [workers]Histogram(buckets) = undefined;
            fill(buckets, &all);
            var acc: Histogram(buckets) = .zero;
            defer b.keepAlive(&acc);

            while (try b.loop()) {
                const source = b.blackBox(&all);
                acc = .zero;
                for (source) |*one| acc.merge(one);
            }
            b.setBytes(@intCast(buckets * 8 * workers));
        }
    };
}

/// `mergeAllPtrs` over the run: the accumulator stays in registers. The
/// pointer array is built inside the timed body, because a scrape does that
/// too.
fn MergeFold(comptime buckets: usize) type {
    return struct {
        fn run(b: *testingx.B) anyerror!void {
            @setEvalBranchQuota(100_000);
            var all: [workers]Histogram(buckets) = undefined;
            fill(buckets, &all);
            var acc: Histogram(buckets).Snapshot = .zero;
            defer b.keepAlive(&acc);

            while (try b.loop()) {
                const source = b.blackBox(&all);
                var pointers: [workers]*const Histogram(buckets) = undefined;
                for (source, 0..) |*one, i| pointers[i] = one;
                acc = Histogram(buckets).mergeAllPtrs(&pointers);
            }
            b.setBytes(@intCast(buckets * 8 * workers));
        }
    };
}

pub fn benchmarkMain(b: *testingx.B) !void {
    @setEvalBranchQuota(100_000);
    inline for (.{ 12, 32 }) |buckets| {
        try b.add(std.fmt.comptimePrint("Merge/buckets={d}/loop", .{buckets}), MergeLoop(buckets).run);
        try b.add(std.fmt.comptimePrint("Merge/buckets={d}/fold", .{buckets}), MergeFold(buckets).run);
    }
}
