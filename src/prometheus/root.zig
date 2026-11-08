//! The Prometheus text exposition format.
const writer = @import("writer.zig");
pub const Writer = writer.Writer;
pub const Kind = writer.Kind;
pub const Metric = writer.Metric;
pub const FamilyWriter = writer.FamilyWriter;

test {
    _ = writer;
}
