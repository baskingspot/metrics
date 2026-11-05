//! Document-level golden tests, and the runtime door's error paths.
//!
//! Every golden case runs through `prometheus.family` (comptime descriptor) and
//! `prometheus.runtime.family` (runtime descriptor), and both must produce the
//! bytes in `testdata/golden.txtar`. The two doors share one emitter, so the
//! comparison is a free differential check on the whole encoder.

const std = @import("std");
const prometheus = @import("prometheus");
const testingx = @import("testingx");
const testing = std.testing;
const Io = std.Io;
const Family = prometheus.Family;

const fixtures = testingx.fixtures(@embedFile("testdata/golden.txtar"));

const document_size = 16 * 1024;

fn expectSamples(comptime name: []const u8, comptime f: Family, samples: anytype) !void {
    const expected = fixtures.get(name);

    var comptime_buffer: [document_size]u8 = undefined;
    var comptime_writer: Io.Writer = .fixed(&comptime_buffer);
    try prometheus.family(&comptime_writer, f, samples);

    var runtime_buffer: [document_size]u8 = undefined;
    var runtime_writer: Io.Writer = .fixed(&runtime_buffer);
    try prometheus.runtime.family(&runtime_writer, f, samples);

    try testing.expectEqualStrings(expected, comptime_writer.buffered());
    try testing.expectEqualStrings(comptime_writer.buffered(), runtime_writer.buffered());
}

fn expectHistograms(comptime name: []const u8, comptime f: Family, histograms: anytype) !void {
    const expected = fixtures.get(name);

    var comptime_buffer: [document_size]u8 = undefined;
    var comptime_writer: Io.Writer = .fixed(&comptime_buffer);
    try prometheus.histogramFamily(&comptime_writer, f, histograms);

    var runtime_buffer: [document_size]u8 = undefined;
    var runtime_writer: Io.Writer = .fixed(&runtime_buffer);
    try prometheus.runtime.histogramFamily(&runtime_writer, f, histograms);

    try testing.expectEqualStrings(expected, comptime_writer.buffered());
    try testing.expectEqualStrings(comptime_writer.buffered(), runtime_writer.buffered());
}

test "a labeled family" {
    try expectSamples("labeled.expected", .{
        .name = "requests_total",
        .kind = .counter,
        .help = "Requests served, by method and status.",
    }, &.{
        .{ .labels = .{ .method = "GET", .status = "200" }, .value = 1841 },
        .{ .labels = .{ .method = "POST", .status = "500" }, .value = 3 },
    });
}

test "an unlabeled family" {
    try expectSamples("unlabeled.expected", .{
        .name = "up",
        .kind = .gauge,
        .help = "One per scrape.",
    }, &.{.{ .labels = .{}, .value = 1 }});
}

test "an integer label value" {
    try expectSamples("integer_label.expected", .{
        .name = "listener_port",
        .kind = .gauge,
    }, &.{.{ .labels = .{ .port = 5432 }, .value = 1 }});
}

test "a label value escapes backslash quote and newline" {
    try expectSamples("escape_label.expected", .{
        .name = "worker_log",
        .kind = .counter,
    }, &.{.{ .labels = .{ .message = "say \"hi\"\nthen\\leave" }, .value = 1 }});
}

test "HELP escapes a backslash and a newline, not a quote" {
    try expectSamples("escape_help.expected", .{
        .name = "escaped",
        .kind = .gauge,
        .help = "a\\b\"c\nd",
    }, &.{.{ .labels = .{}, .value = 1 }});
}

test "an empty HELP writes no line" {
    try expectSamples("empty_help.expected", .{
        .name = "bare",
        .kind = .counter,
        .help = "",
    }, &.{.{ .labels = .{}, .value = 0 }});
}

test "the Go 'g' value table" {
    try expectSamples("values.expected", .{
        .name = "values",
        .kind = .untyped,
    }, &.{
        .{ .labels = .{ .case = "one_tenth" }, .value = 0.1 },
        .{ .labels = .{ .case = "ten_thousandth" }, .value = 0.0001 },
        .{ .labels = .{ .case = "small" }, .value = 1e-7 },
        .{ .labels = .{ .case = "nines" }, .value = 999999 },
        .{ .labels = .{ .case = "million" }, .value = 1e6 },
        .{ .labels = .{ .case = "million_and_change" }, .value = 1234567.0 },
        .{ .labels = .{ .case = "large" }, .value = 1e21 },
        .{ .labels = .{ .case = "huge" }, .value = 1e300 },
        .{ .labels = .{ .case = "three" }, .value = 3.0 },
        .{ .labels = .{ .case = "third" }, .value = 1.0 / 3.0 },
        .{ .labels = .{ .case = "two_to_53" }, .value = 9007199254740993.0 },
        .{ .labels = .{ .case = "min_normal" }, .value = 2.2250738585072014e-308 },
        .{ .labels = .{ .case = "negative_zero" }, .value = -0.0 },
        .{ .labels = .{ .case = "zero" }, .value = 0.0 },
        .{ .labels = .{ .case = "nan" }, .value = std.math.nan(f64) },
        .{ .labels = .{ .case = "inf" }, .value = std.math.inf(f64) },
        .{ .labels = .{ .case = "negative_inf" }, .value = -std.math.inf(f64) },
        .{ .labels = .{ .case = "subnormal" }, .value = 5e-324 },
    });
}

test "an integer keeps every digit" {
    try expectSamples("integers.expected", .{
        .name = "counters",
        .kind = .untyped,
    }, &.{
        .{ .labels = .{ .case = "u64_max" }, .value = std.math.maxInt(u64) },
        .{ .labels = .{ .case = "above_2_53" }, .value = 9007199254740993 },
    });
}

test "a histogram with one bucket" {
    try expectHistograms("histogram_one_bucket.expected", .{
        .name = "latency_seconds",
        .kind = .histogram,
        .limits = &.{10},
    }, &.{.{ .labels = .{}, .counts = &[_]u64{3}, .sum = 5.5, .count = 3 }});
}

test "a histogram with only the implicit bucket" {
    try expectHistograms("histogram_inf_only.expected", .{
        .name = "latency_seconds",
        .kind = .histogram,
    }, &.{.{ .labels = .{}, .counts = &[_]u64{}, .sum = 1.25, .count = 7 }});
}

test "le uses the same formatter as a sample value" {
    try expectHistograms("histogram_le_format.expected", .{
        .name = "latency_seconds",
        .kind = .histogram,
        .limits = &.{ 1e-7, 0.001, 1e6 },
    }, &.{.{
        .labels = .{ .method = "GET" },
        .counts = &[_]u64{ 0, 1, 1 },
        .sum = 0.001,
        .count = 1,
    }});
}

test "three families in one document do not interleave" {
    const expected = fixtures.get("three_families.expected");

    const first = Family{ .name = "first_total", .kind = .counter, .help = "First family." };
    const second = Family{ .name = "second", .kind = .gauge };
    const third = Family{ .name = "third_bytes", .kind = .untyped, .help = "" };

    var comptime_buffer: [document_size]u8 = undefined;
    var comptime_writer: Io.Writer = .fixed(&comptime_buffer);
    try prometheus.family(&comptime_writer, .{
        .name = "first_total",
        .kind = .counter,
        .help = "First family.",
    }, &.{
        .{ .labels = .{ .k = "a" }, .value = 1 },
        .{ .labels = .{ .k = "b" }, .value = 2 },
    });
    try prometheus.family(&comptime_writer, .{ .name = "second", .kind = .gauge }, &.{
        .{ .labels = .{}, .value = 3 },
    });
    try prometheus.family(&comptime_writer, .{
        .name = "third_bytes",
        .kind = .untyped,
        .help = "",
    }, &.{.{ .labels = .{}, .value = 4 }});

    var runtime_buffer: [document_size]u8 = undefined;
    var runtime_writer: Io.Writer = .fixed(&runtime_buffer);
    try prometheus.runtime.family(&runtime_writer, first, &.{
        .{ .labels = .{ .k = "a" }, .value = 1 },
        .{ .labels = .{ .k = "b" }, .value = 2 },
    });
    try prometheus.runtime.family(&runtime_writer, second, &.{
        .{ .labels = .{}, .value = 3 },
    });
    try prometheus.runtime.family(&runtime_writer, third, &.{
        .{ .labels = .{}, .value = 4 },
    });

    try testing.expectEqualStrings(expected, comptime_writer.buffered());
    try testing.expectEqualStrings(comptime_writer.buffered(), runtime_writer.buffered());
}

/// A sample type the error cases can leave empty without an inference problem.
const CounterSample = struct {
    labels: struct { k: u8 = 0 },
    value: u64,
};

test "the runtime door reports what the comptime door refuses to compile" {
    var buffer: [1024]u8 = undefined;
    const no_samples = &[_]CounterSample{};

    var w1: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidMetricName, prometheus.runtime.family(
        &w1,
        .{ .name = "1_requests", .kind = .counter },
        no_samples,
    ));

    const BadLabels = struct { @"not-a-label": u8 };
    var w2: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidLabelName, prometheus.runtime.family(
        &w2,
        .{ .name = "ok", .kind = .counter },
        &.{.{ .labels = BadLabels{ .@"not-a-label" = 1 }, .value = 1 }},
    ));

    const bad_utf8: []const u8 = &.{0xff};
    var w3: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidLabelValue, prometheus.runtime.family(
        &w3,
        .{ .name = "ok", .kind = .counter },
        &.{.{ .labels = .{ .k = bad_utf8 }, .value = 1 }},
    ));

    var w4: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidLabelValue, prometheus.runtime.family(
        &w4,
        .{ .name = "ok", .kind = .counter, .help = bad_utf8 },
        no_samples,
    ));

    var w5: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.MismatchedKind, prometheus.runtime.family(
        &w5,
        .{ .name = "ok", .kind = .histogram },
        no_samples,
    ));

    var w6: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.MismatchedKind, prometheus.runtime.histogramFamily(
        &w6,
        .{ .name = "ok", .kind = .counter },
        &[_]HistogramSample{},
    ));

    const LeLabels = struct { le: u8 };
    var w7: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.DuplicateLabel, prometheus.runtime.histogramFamily(
        &w7,
        .{ .name = "ok", .kind = .histogram },
        &.{.{ .labels = LeLabels{ .le = 1 }, .counts = &[_]u64{}, .sum = 0, .count = 0 }},
    ));

    const countOne = &[_]u64{1};
    var w8: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidHistogram, prometheus.runtime.histogramFamily(
        &w8,
        .{ .name = "ok", .kind = .histogram, .limits = &.{ 2, 1 } },
        &.{.{ .labels = .{}, .counts = countOne, .sum = 0, .count = 1 }},
    ));

    var w9: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidHistogram, prometheus.runtime.histogramFamily(
        &w9,
        .{ .name = "ok", .kind = .histogram, .limits = &.{1} },
        &.{.{ .labels = .{}, .counts = &[_]u64{}, .sum = 0, .count = 0 }},
    ));

    const notCumulative = &[_]u64{ 2, 1 };
    var w10: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidHistogram, prometheus.runtime.histogramFamily(
        &w10,
        .{ .name = "ok", .kind = .histogram, .limits = &.{ 1, 2 } },
        &.{.{ .labels = .{}, .counts = notCumulative, .sum = 0, .count = 1 }},
    ));

    const twoBuckets = &[_]u64{ 1, 2 };
    var w11: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidHistogram, prometheus.runtime.histogramFamily(
        &w11,
        .{ .name = "ok", .kind = .histogram, .limits = &.{ 1, 2 } },
        &.{.{ .labels = .{}, .counts = twoBuckets, .sum = 0, .count = 3 }},
    ));

    const nanLimit = &[_]f64{std.math.nan(f64)};
    var w12: Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidHistogram, prometheus.runtime.histogramFamily(
        &w12,
        .{ .name = "ok", .kind = .histogram, .limits = nanLimit },
        &.{.{ .labels = .{}, .counts = countOne, .sum = 0, .count = 1 }},
    ));
}

const HistogramSample = struct {
    labels: struct { k: []const u8 },
    counts: []const u64,
    sum: f64,
    count: u64,
};

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

// Property 5, through the runtime door because the limits are random: every
// histogram document keeps the invariants the format needs.
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
            // `+ 1` makes every step real, so the limits stay strictly ascending.
            previous += random.float(f64) * 100 + 1;
            cumulative += random.intRangeAtMost(u64, 0, 5);
            limits[i] = previous;
            counts[i] = cumulative;
        }
        const buckets = [1]HistogramSample{.{
            .labels = .{ .k = "v" },
            .counts = counts[0..bucket_count],
            .sum = random.float(f64) * 1000,
            .count = cumulative,
        }};
        const f = Family{
            .name = "h",
            .kind = .histogram,
            .limits = limits[0..bucket_count],
        };

        var buffer: [document_size]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        try prometheus.runtime.histogramFamily(&w, f, &buckets);

        var lines: [32][]const u8 = undefined;
        var line_count: usize = 0;
        var split = std.mem.splitScalar(u8, w.buffered(), '\n');
        while (split.next()) |line| {
            if (line.len == 0) continue;
            lines[line_count] = line;
            line_count += 1;
        }

        // One TYPE line, one bucket line per limit, the implicit +Inf bucket,
        // then sum and count, and nothing else.
        try testing.expectEqualStrings("# TYPE h histogram", lines[0]);
        try testing.expectEqual(bucket_count + 4, line_count);

        for (0..bucket_count) |i| {
            const line = lines[1 + i];
            try testing.expect(std.mem.startsWith(u8, line, "h_bucket{k=\"v\",le=\""));
            try testing.expectEqual(limits[i], try std.fmt.parseFloat(f64, try lineLe(line)));
            try testing.expectEqual(counts[i], try std.fmt.parseInt(u64, lineValue(line), 10));
        }

        const inf_line = lines[1 + bucket_count];
        try testing.expect(std.mem.startsWith(u8, inf_line, "h_bucket{k=\"v\",le=\"+Inf\"} "));
        try testing.expectEqual(cumulative, try std.fmt.parseInt(u64, lineValue(inf_line), 10));

        try testing.expect(std.mem.startsWith(u8, lines[2 + bucket_count], "h_sum{k=\"v\"} "));
        try testing.expectEqual(
            buckets[0].sum,
            try std.fmt.parseFloat(f64, lineValue(lines[2 + bucket_count])),
        );

        try testing.expect(std.mem.startsWith(u8, lines[3 + bucket_count], "h_count{k=\"v\"} "));
        try testing.expectEqual(
            cumulative,
            try std.fmt.parseInt(u64, lineValue(lines[3 + bucket_count]), 10),
        );
    }
}
