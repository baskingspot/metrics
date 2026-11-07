//! Prometheus text exposition format for Zig: write metrics to any writer, no
//! HTTP.
//!
//! `prometheus.Writer` is the format: primitives (`help`, `kind`, `name`,
//! `value`, `line`) and the compositions built on them (`writeMetric`,
//! `writeFamily`, `writeHistogram`, and the series form a multi-series
//! histogram family loops). Each exposition format is its own namespace, so a
//! second one would sit beside it rather than become a flag.
//!
//! `Counter` is the recording side: a `u64` and an add, chosen plain or atomic
//! where it is declared, with no write method. The writer writes; `get` supplies
//! the number.

const writer = @import("writer.zig");

pub const Counter = @import("counter.zig").Counter;

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
