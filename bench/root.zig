//! Every benchmark in the suite. `just bench` runs this file in ReleaseFast
//! through testingx, which prints the Go benchmark format so `benchstat`
//! compares two runs with no glue.
//!
//! `encode` is what the writer costs per byte of exposition, and `merge` is
//! what folding per-worker histograms costs per count. Each module names its
//! own rows.

const std = @import("std");
const testingx = @import("testingx");

const encode = @import("encode.zig");
const merge = @import("merge.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try encode.benchmarkMain(b);
    try merge.benchmarkMain(b);
}
