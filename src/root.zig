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

/// The sink's failure, plus the six input checks. The comptime door returns
/// only the sink's, `MismatchedKind`'s neighbours are compile errors.
pub const Error = errors.Error;

/// Write a family's header and all of its samples.
///
/// `samples` is anything iterable whose elements have `.labels` and `.value`:
/// a slice, an array literal, or a tuple. The descriptor is comptime, so a bad
/// metric name, a bad label name, and a kind that should have used
/// `histogramFamily` do not compile.
pub fn family(w: *Io.Writer, comptime f: Family, samples: anytype) Error!void {
    return f.writeSamples(w, samples);
}

/// Write a histogram family's header and all of its samples. The descriptor's
/// `limits` are the bucket upper bounds; an empty slice is one `+Inf` bucket.
pub fn histogramFamily(w: *Io.Writer, comptime f: Family, histograms: anytype) Error!void {
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
