//! Prometheus text exposition format for Zig: write metrics to any writer, no
//! HTTP.
//!
//! One family per call: the header and every sample, to any `std.Io.Writer`.
//! Two doors over one emitter. `family` and `histogramFamily` take a comptime
//! descriptor and turn a bad name, a bad label name, a wrong kind, and bad
//! limits into compile errors. The `runtime` namespace takes the same
//! descriptor as a value and validates it at run time, for a name composed at
//! runtime.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const errors = @import("errors.zig");

pub const Family = @import("Family.zig");
pub const Kind = Family.Kind;

/// The full set: the sink, plus every input check the runtime door can make.
/// Use this when one `catch` should cover both doors.
pub const Error = errors.Error;

/// What `family` can fail with. The descriptor's own checks are compile errors,
/// so what is left is the sink and a label value or help text that is not valid
/// UTF-8.
pub const FamilyError = errors.FamilyError;

/// What `histogramFamily` can fail with: `FamilyError` plus counts that are not
/// cumulative or that overstate the total.
pub const HistogramError = errors.HistogramError;

/// Write a family's header and all of its samples.
///
/// `samples` is anything iterable whose elements have `.labels` and `.value`:
/// a slice, an array literal, or a tuple. The descriptor is comptime, so a bad
/// metric name, a bad label name, and a kind that should have used
/// `histogramFamily` do not compile.
pub fn family(w: *Io.Writer, comptime f: Family, samples: anytype) FamilyError!void {
    return f.writeSamples(w, samples);
}

/// Write a histogram family's header and all of its samples. The descriptor's
/// `limits` are the bucket upper bounds; an empty slice is one `+Inf` bucket.
pub fn histogramFamily(
    w: *Io.Writer,
    comptime f: Family,
    histograms: anytype,
) HistogramError!void {
    return f.writeHistograms(w, histograms);
}

/// Reinterpret caller-owned words as `count` samples.
///
/// The one-call writers gather a family into one slice, so a consumer that
/// cannot allocate supplies the buffer here: fill the slice, call `family`, and
/// reuse the same words for the next family, because the write is synchronous.
///
/// The word type is `u64` on purpose. Alignment 8 is a property of the slice,
/// so no `@alignCast` runs on a buffer the caller may have allocated short, and
/// a sample of a few labels plus a `u64` needs no more than that. `S` with
/// alignment above 8 is a compile error, not a runtime surprise.
///
/// `std.mem.bytesAsSlice` is not used underneath: it divides the *whole* byte
/// length by `@sizeOf(S)` with `@divExact`, so a buffer holding one spare word
/// past a whole number of samples would panic there rather than be ignored.
pub fn scratch(comptime S: type, words: []u64, count: usize) []S {
    comptime if (@alignOf(S) > @alignOf(u64)) {
        @compileError("prometheus: scratch() hands back 8-byte alignment, and " ++
            @typeName(S) ++ " needs more; use a wider word type");
    };

    const bytes = std.mem.sliceAsBytes(words);
    assert(bytes.len >= count * @sizeOf(S));
    if (count == 0) return &.{};

    const samples: [*]align(@alignOf(u64)) S = @ptrCast(bytes.ptr);
    return samples[0..count];
}

/// The same two writers over a runtime descriptor.
pub const runtime = struct {
    pub fn family(w: *Io.Writer, f: Family, samples: anytype) Error!void {
        return f.writeSamplesRuntime(w, samples);
    }

    pub fn histogramFamily(w: *Io.Writer, f: Family, histograms: anytype) Error!void {
        return f.writeHistogramsRuntime(w, histograms);
    }
};

test {
    // The unit tests live beside the code they cover, and this pulls them into
    // the module's one test binary.
    _ = @import("escape.zig");
    _ = @import("name.zig");
    _ = @import("value.zig");
}

test "the comptime door's error set is exact for family" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    callFamilyWithExactSet(&w) catch |err| switch (err) {
        // No else arm: if the set ever grows, this stops compiling.
        error.WriteFailed, error.InvalidUtf8 => {},
    };
}

fn callFamilyWithExactSet(w: *Io.Writer) FamilyError!void {
    return family(w, .{ .name = "ok", .kind = .counter }, &.{});
}

test "the comptime door's error set is exact for histogramFamily" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    callHistogramWithExactSet(&w) catch |err| switch (err) {
        error.WriteFailed, error.InvalidUtf8, error.InvalidBuckets => {},
    };
}

fn callHistogramWithExactSet(w: *Io.Writer) HistogramError!void {
    return histogramFamily(w, .{ .name = "ok", .kind = .histogram }, &.{});
}

test "scratch renders the same bytes as an array literal" {
    // 16 bytes of labels plus a u64: 24 bytes, so eight words hold two samples
    // and one spare sample's worth. That remainder is exactly what
    // `bytesAsSlice` would have divided away.
    const Sample = struct { labels: struct { k: []const u8 }, value: u64 };
    try testing.expectEqual(@as(usize, 24), @sizeOf(Sample));

    var words: [8]u64 = @splat(0);
    const gathered = scratch(Sample, &words, 2);
    gathered[0] = .{ .labels = .{ .k = "a" }, .value = 1 };
    gathered[1] = .{ .labels = .{ .k = "b" }, .value = 2 };

    const literal = [_]Sample{
        .{ .labels = .{ .k = "a" }, .value = 1 },
        .{ .labels = .{ .k = "b" }, .value = 2 },
    };

    var gathered_buffer: [512]u8 = undefined;
    var gathered_writer: Io.Writer = .fixed(&gathered_buffer);
    try family(&gathered_writer, .{ .name = "s", .kind = .gauge }, gathered);

    var literal_buffer: [512]u8 = undefined;
    var literal_writer: Io.Writer = .fixed(&literal_buffer);
    try family(&literal_writer, .{ .name = "s", .kind = .gauge }, &literal);

    try testing.expectEqualStrings(literal_writer.buffered(), gathered_writer.buffered());
}

test "scratch of zero samples is empty" {
    const Sample = struct { value: u64 };
    var words: [1]u64 = undefined;
    try testing.expectEqual(@as(usize, 0), scratch(Sample, &words, 0).len);
}
