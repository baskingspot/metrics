//! Metrics for Zig: recording primitives, and an exposition writer per format.
//! No HTTP.
//!
//! `prometheus.Writer` is the format: primitives (`help`, `kind`, `name`,
//! `value`, `line`) and the compositions built on them (`writeMetric`,
//! `writeFamily`, `writeHistogram`, and the series form a multi-series
//! histogram family loops). Each exposition format is its own namespace, so a
//! second one would sit beside it rather than become a flag.
//!
//! `Int` and `Atomic` are the recording side: an unsigned integer and an add,
//! with the storage and the concurrency model chosen where it is declared, and
//! no write method. The writer writes; `get` supplies the number.

const writer = @import("writer.zig");

/// Recording types. `counter.Int(u64)` holds a number that only goes up.
pub const counter = @import("counter.zig");

/// The Prometheus text exposition format.
pub const prometheus = struct {
    pub const Writer = writer.Writer;
    pub const Kind = writer.Kind;
    pub const Metric = writer.Metric;
    pub const FamilyWriter = writer.FamilyWriter;
};

test {
    _ = @import("counter.zig");
    _ = writer;
}
