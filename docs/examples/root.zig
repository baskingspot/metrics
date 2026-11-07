//! Every example the guide embeds. Each file is a complete program that
//! `zig build test` compiles and runs, so a guide page cannot show code that
//! does not build.

const std = @import("std");

pub const write_samples = @import("write_samples.zig");
pub const sinks = @import("sinks.zig");
pub const escaping = @import("escaping.zig");
pub const histogram = @import("histogram.zig");
pub const counter = @import("counter.zig");
pub const gauge = @import("gauge.zig");

test {
    std.testing.refAllDecls(@This());
}
