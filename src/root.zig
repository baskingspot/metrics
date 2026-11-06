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
