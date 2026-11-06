//! Prometheus text exposition format for Zig: write metrics to any writer, no
//! HTTP.
//!
//! Two layers. `Writer` is the expfmt cursor: `help`, `kind`, `name`, `value`,
//! and `line`, each writing one record and nothing else. Above it,
//! `writeMetric`, `writeFamily`, and `writeHistogram` are built only out of
//! those methods, so a caller can step down to the primitives and write a shape
//! this library does not have.

pub const Writer = @import("writer.zig").Writer;
pub const Kind = @import("writer.zig").Kind;
pub const Metric = @import("compose.zig").Metric;
pub const FamilyWriter = @import("compose.zig").FamilyWriter;
pub const writeMetric = @import("compose.zig").writeMetric;
pub const writeFamily = @import("compose.zig").writeFamily;
pub const writeHistogram = @import("compose.zig").writeHistogram;

test {
    _ = @import("writer.zig");
    _ = @import("compose.zig");
}
