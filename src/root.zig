//! Prometheus text exposition format for Zig: write metrics to any writer, no
//! HTTP.
//!
//! One value, `Writer`, over a `std.Io.Writer`. Its methods are the primitives
//! (`help`, `kind`, `name`, `value`, `line`) and the compositions built on them
//! (`writeMetric`, `writeFamily`, `writeHistogram`, and the series form a
//! multi-series histogram family loops).

pub const Writer = @import("writer.zig").Writer;
pub const Kind = @import("writer.zig").Kind;
pub const Metric = @import("writer.zig").Metric;
pub const FamilyWriter = @import("writer.zig").FamilyWriter;

test {
    _ = @import("writer.zig");
}
