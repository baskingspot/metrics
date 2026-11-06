//! Struct field enumeration across the 0.16 to 0.17 split.
//!
//! 0.17 replaced `@typeInfo(T).@"struct".fields` with parallel arrays, so the
//! field list is not one shape. `@hasField(std.builtin.Type.Struct,
//! "field_names")` is the probe: false on 0.16, true on 0.17.
//!
//! The count and each name are separate calls on purpose. Building a
//! `[]const []const u8` of names in one function and returning it fails on
//! 0.16 with "comptime var pointers are not available at runtime", and the
//! version that compiles yields a short array.
//!
//! Callers write `inline for (0..comptime fieldCount(L)) |i|`.

const std = @import("std");

pub fn fieldCount(comptime T: type) usize {
    if (@hasField(std.builtin.Type.Struct, "field_names")) {
        return @typeInfo(T).@"struct".field_names.len;
    }
    return @typeInfo(T).@"struct".fields.len;
}

pub fn fieldName(comptime T: type, comptime index: usize) []const u8 {
    if (@hasField(std.builtin.Type.Struct, "field_names")) {
        return @typeInfo(T).@"struct".field_names[index];
    }
    return @typeInfo(T).@"struct".fields[index].name;
}

/// True when `T` is a sample iterator: a struct, or a pointer to one, that
/// declares `next`. `std.meta.hasMethod` is not on both compilers, so the probe
/// lives here beside the field one.
///
/// A struct with a *field* named `next` is not an iterator: `@hasDecl` is false
/// for it, and the declared thing has to be a function either way.
pub fn isIterator(comptime T: type) bool {
    const Child = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
    switch (@typeInfo(Child)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(Child, "next")) return false;
    return std.meta.activeTag(@typeInfo(@TypeOf(Child.next))) == .@"fn";
}

pub fn FieldType(comptime T: type, comptime index: usize) type {
    if (@hasField(std.builtin.Type.Struct, "field_names")) {
        return @typeInfo(T).@"struct".field_types[index];
    }
    return @typeInfo(T).@"struct".fields[index].type;
}
