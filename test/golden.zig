//! Document-level golden tests.
//!
//! Each case writes with the public API and compares against its section of
//! `testdata/golden.txtar`, which is embedded at compile time. The archive holds
//! the expected bytes only: an input here is a Zig call, not text.

const std = @import("std");
const prometheus = @import("prometheus");
const testingx = @import("testingx");
const testing = std.testing;
const Io = std.Io;

const fixtures = testingx.fixtures(@embedFile("testdata/golden.txtar"));

const document_size = 16 * 1024;

fn expect(comptime name: []const u8, actual: []const u8) !void {
    try testing.expectEqualStrings(fixtures.get(name), actual);
}

test "a labeled family" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    const family = try prometheus.writeFamily(&w, .{
        .name = "requests_total",
        .kind = .counter,
        .help = "Requests served, by method and status.",
    });
    try family.write(.{ .method = "GET", .status = "200" }, 1841);
    try family.write(.{ .method = "POST", .status = "500" }, 3);
    try expect("labeled.expected", out.buffered());
}

test "an unlabeled family" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    const family = try prometheus.writeFamily(&w, .{
        .name = "up",
        .kind = .gauge,
        .help = "One per scrape.",
    });
    try family.write(.{}, 1);
    try expect("unlabeled.expected", out.buffered());
}

test "one line with no header" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try prometheus.writeMetric(&w, "up", .{}, 1);
    try expect("line_only.expected", out.buffered());
}

test "an integer label value" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    const family = try prometheus.writeFamily(&w, .{
        .name = "listener_port",
        .kind = .gauge,
    });
    try family.write(.{ .port = 5432 }, 1);
    try expect("integer_label.expected", out.buffered());
}

test "a label value escapes backslash quote and newline" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    const family = try prometheus.writeFamily(&w, .{
        .name = "worker_log",
        .kind = .counter,
    });
    try family.write(.{ .message = "say \"hi\"\nthen\\leave" }, 1);
    try expect("escape_label.expected", out.buffered());
}

test "HELP escapes a backslash and a newline, not a quote" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    const family = try prometheus.writeFamily(&w, .{
        .name = "escaped",
        .kind = .gauge,
        .help = "a\\b\"c\nd",
    });
    try family.write(.{}, 1);
    try expect("escape_help.expected", out.buffered());
}

test "an empty HELP writes the line without text" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    const family = try prometheus.writeFamily(&w, .{ .name = "bare", .kind = .counter });
    try family.write(.{}, 0);
    try expect("empty_help.expected", out.buffered());
}

test "three families in one document" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);

    const first = try prometheus.writeFamily(&w, .{
        .name = "first_total",
        .kind = .counter,
        .help = "First family.",
    });
    try first.write(.{ .k = "a" }, 1);
    try first.write(.{ .k = "b" }, 2);

    const second = try prometheus.writeFamily(&w, .{ .name = "second", .kind = .gauge });
    try second.write(.{}, 3);

    const third = try prometheus.writeFamily(&w, .{ .name = "third_bytes", .kind = .untyped });
    try third.write(.{}, 4);

    try expect("three_families.expected", out.buffered());
}

test "a histogram with one bucket" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try prometheus.writeHistogram(
        &w,
        .{ .name = "latency_seconds", .kind = .histogram },
        .{},
        &.{10},
        &[_]u64{3},
        5.5,
        3,
    );
    try expect("histogram_one_bucket.expected", out.buffered());
}

test "a histogram with only the implicit bucket" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try prometheus.writeHistogram(
        &w,
        .{ .name = "latency_seconds", .kind = .histogram },
        .{},
        &.{},
        &[_]u64{},
        1.25,
        7,
    );
    try expect("histogram_inf_only.expected", out.buffered());
}

// Observations above the top limit land only in the implicit `+Inf` bucket, so
// the last finite count can be below the total.
test "a histogram with a tail above its top limit" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try prometheus.writeHistogram(
        &w,
        .{ .name = "latency_seconds", .kind = .histogram },
        .{},
        &.{ 10, 20 },
        &[_]u64{ 1, 2 },
        45,
        3,
    );
    try expect("histogram_tail.expected", out.buffered());
}

test "le uses the same formatter as a sample value" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try prometheus.writeHistogram(
        &w,
        .{ .name = "latency_seconds", .kind = .histogram },
        .{ .method = "GET" },
        &.{ 1e-7, 0.001, 1e6 },
        &[_]u64{ 0, 1, 1 },
        0.001,
        1,
    );
    try expect("histogram_le_format.expected", out.buffered());
}

// Twenty buckets is an ordinary layout; the comptime `le` formatting used to
// run out of branches at seventeen.
test "a histogram with thirty limits" {
    const limits = comptime blk: {
        var out: [30]f64 = undefined;
        for (0..30) |i| out[i] = @floatFromInt(i + 1);
        break :blk out;
    };
    const counts = comptime blk: {
        var out: [30]u64 = undefined;
        for (0..30) |i| out[i] = i + 1;
        break :blk out;
    };
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    try prometheus.writeHistogram(
        &w,
        .{ .name = "latency_seconds", .kind = .histogram },
        .{},
        &limits,
        &counts,
        465,
        30,
    );
    try expect("histogram_thirty.expected", out.buffered());
}

test "the value table" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    const family = try prometheus.writeFamily(&w, .{ .name = "values", .kind = .untyped });
    const cases = [_]struct { name: []const u8, value: f64 }{
        .{ .name = "one_tenth", .value = 0.1 },
        .{ .name = "ten_thousandth", .value = 0.0001 },
        .{ .name = "small", .value = 1e-7 },
        .{ .name = "nines", .value = 999999.0 },
        .{ .name = "million", .value = 1e6 },
        .{ .name = "million_and_change", .value = 1234567.0 },
        .{ .name = "large", .value = 1e21 },
        .{ .name = "huge", .value = 1e300 },
        .{ .name = "three", .value = 3.0 },
        .{ .name = "third", .value = 1.0 / 3.0 },
        .{ .name = "two_to_53", .value = 9007199254740993.0 },
        .{ .name = "min_normal", .value = 2.2250738585072014e-308 },
        .{ .name = "negative_zero", .value = -0.0 },
        .{ .name = "zero", .value = 0.0 },
        .{ .name = "nan", .value = std.math.nan(f64) },
        .{ .name = "inf", .value = std.math.inf(f64) },
        .{ .name = "negative_inf", .value = -std.math.inf(f64) },
        .{ .name = "subnormal", .value = 5e-324 },
    };
    for (cases) |case| try family.write(.{ .case = case.name }, case.value);
    try expect("values.expected", out.buffered());
}

test "an integer keeps every digit" {
    var buffer: [document_size]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var w = prometheus.Writer.init(&out);
    const family = try prometheus.writeFamily(&w, .{ .name = "counters", .kind = .untyped });
    try family.write(.{ .case = "u64_max" }, std.math.maxInt(u64));
    try family.write(.{ .case = "above_2_53" }, 9007199254740993);
    try expect("integers.expected", out.buffered());
}

// A rejected histograms-length pair is a caller bug the assert catches; the
// property here is the bytes, over generated bucket sets.
const HistogramCase = struct { limits: []const f64, counts: []const u64, sum: f64, count: u64 };

test "property: a histogram document keeps every bucket invariant" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    var limits: [8]f64 = undefined;
    var counts: [8]u64 = undefined;
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const bucket_count = random.intRangeAtMost(usize, 0, 8);
        var previous: f64 = 0;
        var cumulative: u64 = 0;
        for (0..bucket_count) |i| {
            previous += random.float(f64) * 100 + 1;
            cumulative += random.intRangeAtMost(u64, 0, 5);
            limits[i] = previous;
            counts[i] = cumulative;
        }
        const tail = random.intRangeAtMost(u64, 0, 3);
        const total = cumulative + tail;

        var buffer: [document_size]u8 = undefined;
        var out: Io.Writer = .fixed(&buffer);
        var w = prometheus.Writer.init(&out);
        try prometheus.writeHistogram(
            &w,
            .{ .name = "h", .kind = .histogram },
            .{ .k = "v" },
            limits[0..bucket_count],
            counts[0..bucket_count],
            random.float(f64) * 1000,
            total,
        );

        var lines: [32][]const u8 = undefined;
        var line_count: usize = 0;
        var split = std.mem.splitScalar(u8, out.buffered(), '\n');
        while (split.next()) |line| {
            if (line.len == 0) continue;
            lines[line_count] = line;
            line_count += 1;
        }

        try testing.expectEqualStrings("# HELP h", lines[0]);
        try testing.expectEqualStrings("# TYPE h histogram", lines[1]);
        try testing.expectEqual(bucket_count + 5, line_count);

        for (0..bucket_count) |i| {
            const line = lines[2 + i];
            try testing.expect(std.mem.startsWith(u8, line, "h_bucket{k=\"v\",le=\""));
            try testing.expectEqual(limits[i], try std.fmt.parseFloat(f64, try lineLe(line)));
            try testing.expectEqual(counts[i], try std.fmt.parseInt(u64, lineValue(line), 10));
        }

        const inf_line = lines[2 + bucket_count];
        try testing.expect(std.mem.startsWith(u8, inf_line, "h_bucket{k=\"v\",le=\"+Inf\"} "));
        try testing.expectEqual(total, try std.fmt.parseInt(u64, lineValue(inf_line), 10));

        try testing.expect(std.mem.startsWith(u8, lines[3 + bucket_count], "h_sum{k=\"v\"} "));
        try testing.expect(std.mem.startsWith(u8, lines[4 + bucket_count], "h_count{k=\"v\"} "));
        try testing.expectEqual(
            total,
            try std.fmt.parseInt(u64, lineValue(lines[4 + bucket_count]), 10),
        );
    }
}

/// Everything after the last space: the value on a sample line.
fn lineValue(line: []const u8) []const u8 {
    var at = line.len;
    while (at > 0 and line[at - 1] != ' ') at -= 1;
    return line[at..];
}

/// The `le` label's value on a bucket line.
fn lineLe(line: []const u8) ![]const u8 {
    const start = (std.mem.find(u8, line, "le=\"") orelse return error.NoLe) + 4;
    const end = (std.mem.findScalar(u8, line[start..], '"') orelse return error.NoLe) + start;
    return line[start..end];
}
