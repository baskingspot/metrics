//! Must panic: `scratch` asserts that the words cover `count` samples. This is
//! a program rather than a test because the panic handler is process-wide, so
//! the recipe runs it and requires a nonzero exit.

const std = @import("std");
const prometheus = @import("prometheus");

const Sample = struct { value: u64 };

pub fn main(init: std.process.Init) !void {
    _ = init;
    var words: [1]u64 = undefined;
    // One word is one sample's worth; three is three times too many.
    _ = prometheus.scratch(Sample, &words, 3);
}
