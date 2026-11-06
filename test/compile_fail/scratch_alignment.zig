//! Must not compile: `scratch` takes `[]u64`, so it can only hand back
//! 8-byte alignment. A sample that needs more has to come from a wider word
//! type, and the error says so.

const std = @import("std");
const prometheus = @import("prometheus");

const Wide = struct { value: u64 align(16) };

test "a sample with alignment above 8 does not compile" {
    var words: [8]u64 = undefined;
    _ = prometheus.scratch(Wide, &words, 1);
}
