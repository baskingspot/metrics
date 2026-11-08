//! Metrics for Zig: recording primitives, and an exposition writer per format.
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

pub const counter = @import("counter.zig");
pub const gauge = @import("gauge.zig");
pub const histogram = @import("histogram.zig");
pub const prometheus = @import("prometheus/root.zig");

test {
    _ = @import("counter.zig");
    _ = @import("histogram.zig");
    _ = @import("gauge.zig");
    _ = @import("storage.zig");
    _ = prometheus;
}
