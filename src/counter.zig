//! A recording counter: a `u64` and an add, with the concurrency model chosen
//! by the caller.
//!
//! `Counter(.plain)` is one field and a `+%`. It belongs to whoever holds it,
//! which is a worker thread or a struct the caller already owns. `Counter(.atomic)`
//! is `std.atomic.Value(u64)` with monotonic operations, for the case where a
//! scrape reads a counter another thread is incrementing.
//!
//! Both wrap at `maxInt(u64)` and keep counting. A counter does not saturate:
//! saturating turns a visible reset into a silent flat line.
//!
//! There is no `set` and no write method. A counter only goes up, and the bytes
//! on the wire are the writer's job: read it with `get` and pass the number.

const std = @import("std");
const testing = std.testing;
const math = std.math;
const Value = std.atomic.Value;

pub const Mode = enum { atomic, plain };

pub fn Counter(comptime mode: Mode) type {
    return struct {
        const Self = @This();

        pub const concurrency = mode;

        count: Storage,

        /// One more. Wraps at `maxInt(u64)`.
        pub inline fn inc(self: *Self) void {
            self.add(1);
        }

        /// Add `n`. Wraps at `maxInt(u64)`.
        pub inline fn add(self: *Self, n: u64) void {
            switch (mode) {
                .plain => self.count +%= n,
                .atomic => _ = self.count.fetchAdd(n, .monotonic),
            }
        }

        /// The value now. With `.atomic` this is a monotonic load, which is all
        /// a scrape needs: it orders nothing else.
        pub inline fn get(self: *const Self) u64 {
            return switch (mode) {
                .plain => self.count,
                .atomic => self.count.load(.monotonic),
            };
        }

        const Storage = switch (mode) {
            .plain => u64,
            .atomic => Value(u64),
        };

        pub const zero: Storage = switch (mode) {
            .plain => 0,
            .atomic => .init(0),
        };
    };
}

test "a plain counter adds, reads, and wraps" {
    var counter: Counter(.plain) = .zero;
    try testing.expectEqual(@as(u64, 0), counter.get());

    counter.inc();
    counter.add(41);
    try testing.expectEqual(@as(u64, 42), counter.get());

    counter.add(std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, 41), counter.get());
}

test "an atomic counter adds, reads, and wraps the same way" {
    var counter: Counter(.atomic) = .zero;
    try testing.expectEqual(@as(u64, 0), counter.get());

    counter.inc();
    counter.add(41);
    try testing.expectEqual(@as(u64, 42), counter.get());

    counter.add(std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, 41), counter.get());
}

test "the two modes agree step for step" {
    var plain: Counter(.plain) = .zero;
    var atomic: Counter(.atomic) = .zero;
    const steps = [_]u64{ 1, 0, 7, math.maxInt(u64), 3, math.maxInt(u64) / 2 };
    for (steps) |step| {
        plain.add(step);
        atomic.add(step);
        try testing.expectEqual(plain.get(), atomic.get());
    }
}

test "the storage is what the mode says" {
    try testing.expect(Counter(.plain).Storage == u64);
    try testing.expect(Counter(.atomic).Storage == Value(u64));
}

test "a counter is one word, in either mode" {
    // Every consumer of this type is a counter next to other counters, so the
    // claim that matters is that a counter costs a word and adds no padding of
    // its own. That is not visible by reading the type.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Counter(.plain)));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Counter(.atomic)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Counter(.plain)));
    try testing.expectEqual(@as(usize, 8), @alignOf(Counter(.atomic)));

    // One counter beside a u64: two words. Field offsets in an auto-layout
    // struct are the compiler's business, so the size is the claim here.
    const Pair = struct { bytes: u64, errors: Counter(.plain) };
    try testing.expectEqual(@as(usize, 16), @sizeOf(Pair));

    // A block of counters beside two u64s, which is the shape a worker struct
    // has: four words, no gap added by a counter.
    const Worker = struct {
        started: u64,
        requests: Counter(.plain),
        errors: Counter(.plain),
        bytes: u64,
    };
    try testing.expectEqual(@as(usize, 32), @sizeOf(Worker));

    // With two u32s ahead of them, counters fill the rest of the words rather
    // than pushing the struct to another one.
    const Mixed = struct {
        a: u32,
        b: u32,
        errors: Counter(.plain),
    };
    try testing.expectEqual(@as(usize, 16), @sizeOf(Mixed));

    // The atomic mode is the same size, so swapping the mode never moves a
    // field or changes the layout of the struct that holds it.
    const AtomicWorker = struct {
        started: u64,
        requests: Counter(.atomic),
        errors: Counter(.atomic),
        bytes: u64,
    };
    try testing.expectEqual(@sizeOf(Worker), @sizeOf(AtomicWorker));
}
