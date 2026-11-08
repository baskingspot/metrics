//! The storage a recording type sits on: one plain field, or one atomic.
//!
//! `Storage(.local, T)` is a plain field. `Storage(.atomic, T)` is an atomic
//! integer for an integer, and for a float an atomic unsigned integer of the
//! same width holding the bit pattern, because there is no atomic float add to
//! call.
//!
//! Both expose the same five operations over `Value = T`, so `counter` and
//! `gauge` never branch on the mode: `load`, `store`, `add`, `sub`, and
//! `zero`. The arithmetic wraps at the type's bounds and reports nothing; a
//! value that underflows is the caller's arithmetic bug to avoid, not something
//! this layer hands back.
//!
//! Nothing here wraps `std.atomic.Value`: the builtins are the whole interface
//! this needs, and `@atomicRmw` on the value type is a shorter path to the same
//! bytes.

const std = @import("std");
const testing = std.testing;

pub const Mode = enum { local, atomic };

pub fn Storage(comptime mode: Mode, comptime T: type) type {
    comptime checkType(mode, T);
    return struct {
        const Self = @This();
        const Field = FieldType(mode, T);
        const Bits = switch (@typeInfo(T)) {
            .float => BitsOf(T),
            else => void,
        };

        pub const Value = T;

        raw: Field,

        pub const zero: Self = .{ .raw = 0 };

        pub inline fn load(self: *const Self) T {
            return switch (mode) {
                .local => self.raw,
                .atomic => self.atomicLoad(),
            };
        }

        pub inline fn atomicLoad(self: *const Self) T {
            return if (comptime isFloat(T))
                @bitCast(@atomicLoad(Bits, &self.raw, .monotonic))
            else
                @atomicLoad(T, &self.raw, .monotonic);
        }

        pub inline fn store(self: *Self, v: T) void {
            switch (mode) {
                .local => self.raw = v,
                .atomic => self.atomicStore(v),
            }
        }

        pub inline fn atomicStore(self: *Self, v: T) void {
            if (comptime isFloat(T)) {
                @atomicStore(Bits, &self.raw, @bitCast(v), .monotonic);
            } else {
                @atomicStore(T, &self.raw, v, .monotonic);
            }
        }

        /// Add `n`, wrapping at the type's bounds.
        pub inline fn add(self: *Self, n: T) void {
            switch (mode) {
                .local => {
                    if (comptime isFloat(T)) self.raw += n else self.raw +%= n;
                },
                .atomic => self.atomicAdd(n),
            }
        }

        /// Subtract `n`, wrapping at the type's bounds.
        pub inline fn sub(self: *Self, n: T) void {
            switch (mode) {
                .local => {
                    if (comptime isFloat(T)) self.raw -= n else self.raw -%= n;
                },
                .atomic => self.atomicSub(n),
            }
        }

        /// The compare-exchange loop an atomic float needs: load the bit
        /// pattern, compute the next one, retry if another thread won the race.
        inline fn atomicAdd(self: *Self, n: T) void {
            // A no-op add does not need to contend for the line.
            if (n == 0) return;

            if (comptime !isFloat(T)) {
                _ = @atomicRmw(T, &self.raw, .Add, n, .monotonic);
                return;
            }

            var current = @atomicLoad(Bits, &self.raw, .monotonic);
            while (true) {
                const next: Bits = @bitCast(@as(T, @bitCast(current)) + n);
                if (@cmpxchgWeak(Bits, &self.raw, current, next, .monotonic, .monotonic)) |observed| {
                    current = observed;
                } else return;
            }
        }

        inline fn atomicSub(self: *Self, n: T) void {
            // A no-op add does not need to contend for the line.
            if (n == 0) return;

            if (comptime !isFloat(T)) {
                _ = @atomicRmw(T, &self.raw, .Sub, n, .monotonic);
                return;
            }

            var current = @atomicLoad(Bits, &self.raw, .monotonic);
            while (true) {
                const next: Bits = @bitCast(@as(T, @bitCast(current)) - n);
                if (@cmpxchgWeak(Bits, &self.raw, current, next, .monotonic, .monotonic)) |observed| {
                    current = observed;
                } else return;
            }
        }
    };
}

/// The field the storage keeps: `T` itself when local, and for an atomic float
/// the unsigned integer of the same width.
fn FieldType(comptime mode: Mode, comptime T: type) type {
    if (mode == .local) return T;
    return if (isFloat(T)) BitsOf(T) else T;
}

/// The integer an atomic float is stored in: 32 bits for an `f32`, 64 for an
/// `f64`.
fn BitsOf(comptime T: type) type {
    return switch (@typeInfo(T).float.bits) {
        32 => u32,
        64 => u64,
        else => @compileError("metrics: an atomic float is f32 or f64, not " ++ @typeName(T)),
    };
}

pub fn isInteger(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

pub fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

pub fn isNumber(comptime T: type) bool {
    return isInteger(T) or isFloat(T);
}

fn checkType(comptime mode: Mode, comptime T: type) void {
    comptime if (!isNumber(T)) {
        @compileError("metrics: storage.Storage(T) takes an integer, f32, or f64, not " ++ @typeName(T));
    };
    comptime if (isFloat(T) and @typeInfo(T).float.bits != 32 and @typeInfo(T).float.bits != 64) {
        @compileError("metrics: a gauge float is f32 or f64, not " ++ @typeName(T));
    };
    comptime if (mode == .atomic and isInteger(T) and !isAtomicWidth(@typeInfo(T).int.bits)) {
        @compileError("metrics: storage.Storage(.atomic, " ++ @typeName(T) ++
            ") has no atomic storage; use 8, 16, 32, or 64 bits");
    };
}

fn isAtomicWidth(comptime bits: u16) bool {
    return bits == 8 or bits == 16 or bits == 32 or bits == 64;
}

test "a local and an atomic storage agree step for step" {
    var local: Storage(.local, u64) = .zero;
    var atomic: Storage(.atomic, u64) = .zero;

    const steps = [_]u64{ 1, 0, 7, std.math.maxInt(u64), 3 };
    for (steps) |step| {
        local.add(step);
        atomic.add(step);
        try testing.expectEqual(local.load(), atomic.load());
    }

    const before = local.load();
    local.sub(0);
    atomic.sub(0);
    try testing.expectEqual(before, local.load());
    try testing.expectEqual(before, atomic.load());
}

test "an atomic float is an integer atomic holding the bit pattern" {
    var storage_value: Storage(.atomic, f64) = .zero;
    storage_value.store(1.5);
    try testing.expectEqual(@as(f64, 1.5), storage_value.load());
    storage_value.add(2.25);
    try testing.expectEqual(@as(f64, 3.75), storage_value.load());
    storage_value.sub(1.25);
    try testing.expectEqual(@as(f64, 2.5), storage_value.load());
    try testing.expectEqual(@as(usize, 8), @sizeOf(@TypeOf(storage_value.raw)));
}
