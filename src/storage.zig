//! The storage a recording type sits on: one plain field, or an atomic.
//!
//! `Local(T)` is a plain field. `Atomic(T)` is an integer atomic for an integer,
//! and for a float an integer atomic holding the bit pattern, because there is
//! no atomic float add to call.
//!
//! Both expose the same five operations over `Value = T`, so `counter` and
//! `gauge` are thin wrappers and never branch on the mode. `sub` returns the
//! value it replaced, which is what lets a gauge assert an underflow against the
//! value the subtraction observed instead of loading first and racing.

const std = @import("std");
const AtomicValue = std.atomic.Value;
const assert = std.debug.assert;

/// A plain field.
pub fn Local(comptime T: type) type {
    comptime checkNumber(T, "storage.Local");
    return struct {
        const Self = @This();

        pub const Value = T;

        value: T,

        pub inline fn load(self: *const Self) T {
            return self.value;
        }

        pub inline fn store(self: *Self, v: T) void {
            self.value = v;
        }

        /// Add `n`, wrapping at the type's bounds.
        pub inline fn add(self: *Self, n: T) void {
            if (comptime isFloat(T)) {
                self.value += n;
            } else {
                self.value +%= n;
            }
        }

        /// Subtract `n`, wrapping at the type's bounds. Returns the value the
        /// subtraction replaced.
        pub inline fn sub(self: *Self, n: T) T {
            const previous = self.value;
            if (comptime isFloat(T)) {
                self.value -= n;
            } else {
                self.value = previous -% n;
            }
            return previous;
        }

        pub const zero: Self = .{ .value = 0 };
    };
}

/// An integer atomic, or an atomic float stored as one.
pub fn Atomic(comptime T: type) type {
    comptime checkNumber(T, "storage.Atomic");
    comptime if (isFloat(T)) {
        if (floatBits(T) != 32 and floatBits(T) != 64) {
            @compileError("metrics: storage.Atomic(" ++ @typeName(T) ++ ") has no atomic storage; use f32 or f64");
        }
    } else if (!isAtomicWidth(@typeInfo(T).int.bits)) {
        @compileError("metrics: storage.Atomic(" ++ @typeName(T) ++
            ") has no atomic storage; use 8, 16, 32, or 64 bits");
    };
    return if (isFloat(T)) AtomicFloat(T) else AtomicInteger(T);
}

fn AtomicInteger(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Value = T;

        value: AtomicValue(T),

        pub inline fn load(self: *const Self) T {
            return self.value.load(.monotonic);
        }

        pub inline fn store(self: *Self, v: T) void {
            self.value.store(v, .monotonic);
        }

        pub inline fn add(self: *Self, n: T) void {
            _ = self.value.fetchAdd(n, .monotonic);
        }

        /// Returns the value the subtraction replaced.
        pub inline fn sub(self: *Self, n: T) T {
            return self.value.fetchSub(n, .monotonic);
        }

        pub const zero: Self = .{ .value = .init(0) };
    };
}

/// An atomic `f32` or `f64`. There is no atomic float add to call, so this is an
/// integer atomic holding the bit pattern: `load` and `store` are a load and a
/// store on it, and `add` and `sub` are a compare-exchange loop.
fn AtomicFloat(comptime T: type) type {
    comptime assert(isFloat(T));
    return struct {
        const Self = @This();
        const Bits = BitsOf(T);

        pub const Value = T;

        value: AtomicValue(Bits),

        pub inline fn load(self: *const Self) T {
            return @bitCast(self.value.load(.monotonic));
        }

        pub inline fn store(self: *Self, v: T) void {
            self.value.store(@bitCast(v), .monotonic);
        }

        pub inline fn add(self: *Self, n: T) void {
            _ = self.fetchAdd(n);
        }

        /// Returns the value the subtraction replaced.
        pub inline fn sub(self: *Self, n: T) T {
            return self.fetchAdd(-n);
        }

        fn fetchAdd(self: *Self, n: T) T {
            // A no-op add does not need to contend for the line.
            if (n == 0) return self.load();
            var current: Bits = self.value.load(.monotonic);
            while (true) {
                const next: Bits = @bitCast(@as(T, @bitCast(current)) + n);
                if (self.value.cmpxchgWeak(current, next, .monotonic, .monotonic)) |observed| {
                    current = observed;
                } else return @bitCast(current);
            }
        }

        pub const zero: Self = .{ .value = .init(0) };
    };
}

/// The integer an atomic float is stored in.
fn BitsOf(comptime T: type) type {
    return switch (floatBits(T)) {
        32 => u32,
        64 => u64,
        else => @compileError("metrics: an atomic float is f32 or f64, not " ++ @typeName(T)),
    };
}

fn floatBits(comptime T: type) u16 {
    return @typeInfo(T).float.bits;
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

fn checkNumber(comptime T: type, comptime constructor: []const u8) void {
    if (comptime !isNumber(T)) {
        @compileError("metrics: " ++ constructor ++ "(T) takes an integer, f32, or f64, not " ++ @typeName(T));
    }
}

fn isAtomicWidth(comptime bits: u16) bool {
    return bits == 8 or bits == 16 or bits == 32 or bits == 64;
}
