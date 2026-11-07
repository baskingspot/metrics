//! Metrics for Zig: recording primitives, and an exposition writer per format.
//! No HTTP.
//!
//! `prometheus.Writer` is the format: primitives (`help`, `kind`, `name`,
//! `value`, `line`) and the compositions built on them (`writeMetric`,
//! `writeFamily`, `writeHistogram`, and the series form a multi-series
//! histogram family loops). Each exposition format is its own namespace, so a
//! second one would sit beside it rather than become a flag.
//!
//! `counter` and `gauge` are the recording side: an integer with the storage and
//! the concurrency model chosen where it is declared, and no write method. The
//! writer writes; `get` supplies the number.

const writer = @import("writer.zig");

/// Recording types. `counter.Local(u64)` holds a number that only goes up;
/// `gauge.Local(i64)` holds one that moves both ways. The constructor names the
/// storage and the argument names the value type.
pub const counter = @import("counter.zig");
pub const gauge = @import("gauge.zig");

/// The Prometheus text exposition format.
pub const prometheus = struct {
    pub const Writer = writer.Writer;
    pub const Kind = writer.Kind;
    pub const Metric = writer.Metric;
    pub const FamilyWriter = writer.FamilyWriter;
};

test {
    _ = @import("counter.zig");
    _ = @import("gauge.zig");
    _ = @import("storage.zig");
    _ = writer;
}
