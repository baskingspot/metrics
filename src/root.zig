//! Prometheus text exposition format for Zig: write metrics to any writer, no
//! HTTP.
//!
//! One sample line, or one family at a time with its header written once. The
//! sink is any `std.Io.Writer`, so a buffer, a file, and a socket are the
//! caller's problem and this module never sees a socket.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const errors = @import("errors.zig");
/// What every writer in this module can fail with: the sink's own failure, plus
/// the two input checks that keep one caller's typo out of a document.
pub const Error = errors.Error;
pub const Family = @import("Family.zig");
const labels = @import("labels.zig");
const names = @import("name.zig");
const values = @import("value.zig");

/// Write one sample line: `name{label="value"} 1` and a newline.
///
/// This writes no header. A document whose samples need `# HELP` and `# TYPE`
/// uses `family`.
pub fn sample(w: *Io.Writer, name: []const u8, labels_: anytype, value: anytype) Error!void {
    try names.checkMetricName(name);
    try w.writeAll(name);
    try labels.writeGroup(w, labels_);
    try w.writeByte(' ');
    try values.write(w, value);
    try w.writeByte('\n');
}

/// Write the family's header and return the handle its samples are written
/// through. The name and kind are comptime, so a histogram here or an illegal
/// metric name does not compile.
pub fn family(w: *Io.Writer, comptime f: Family) Error!Family.Samples {
    return f.writeHeader(w);
}

/// Write a histogram family's header and return the handle its bucket lines are
/// written through. The caller supplies its own cumulative counts; `Buckets`
/// documents what each one must satisfy.
pub fn histogramFamily(w: *Io.Writer, comptime f: Family) Error!Family.Histograms {
    return f.writeHistogramHeader(w);
}

fn expectRender(expected: []const u8, metric: []const u8, labels_: anytype, value: anytype) !void {
    var buffer: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try sample(&w, metric, labels_, value);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "a labeled sample" {
    try expectRender(
        "requests_total{method=\"GET\",status=\"200\"} 1841\n",
        "requests_total",
        .{ .method = "GET", .status = "200" },
        1841,
    );
}

test "an unlabeled sample" {
    try expectRender("up 1\n", "up", .{}, 1);
    const NoLabels = struct {};
    try expectRender("up 0\n", "up", NoLabels{}, 0);
}

test "integer label values are decimal inside the quotes" {
    try expectRender("a{port=\"5432\"} 1\n", "a", .{ .port = 5432 }, 1);
    try expectRender("a{port=\"0\"} 1\n", "a", .{ .port = 0 }, 1);
}

test "a label value escapes backslash quote and newline" {
    try expectRender(
        "a{k=\"x\\\\y\\\"z\\nw\"} 1\n",
        "a",
        .{ .k = "x\\y\"z\nw" },
        1,
    );
}

test "a label value leaves tab carriage return NUL and emoji raw" {
    try expectRender("a{k=\"\t\r\x00z🦎\"} 1\n", "a", .{ .k = "\t\r\x00z🦎" }, 1);
}

test "invalid UTF-8 in a label value is an error, not bytes" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const bad: []const u8 = &.{ 0xff, 0xfe };
    try testing.expectError(error.InvalidUtf8, sample(&w, "a", .{ .k = bad }, 1));
    try testing.expectEqualStrings("a{k=\"", w.buffered());
}

test "a metric name outside the legacy charset is an error" {
    var buffer: [64]u8 = undefined;
    const bad = [_][]const u8{ "", "1a", "a-b", "a b", "é", "a.b" };
    for (bad) |metric| {
        var w: Io.Writer = .fixed(&buffer);
        try testing.expectError(error.InvalidName, sample(&w, metric, .{}, 1));
    }
    const good = [_][]const u8{ "a", "_a", ":a", "a:b", "a_1", "A9" };
    for (good) |metric| {
        var w: Io.Writer = .fixed(&buffer);
        try sample(&w, metric, .{}, 1);
    }
}

test "every sample line ends with a newline" {
    var buffer: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try sample(&w, "a", .{ .k = "v" }, 1.5);
    try sample(&w, "b", .{}, std.math.nan(f64));
    try testing.expectEqual(@as(u8, '\n'), w.buffered()[w.buffered().len - 1]);
}

test "a document written family by family has contiguous samples" {
    var buffer: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);

    const first = try family(&w, .{
        .name = "first_total",
        .kind = .counter,
        .help = "First family.",
    });
    try first.write(.{ .k = "a" }, 1);
    try first.write(.{ .k = "b" }, 2);

    const second = try family(&w, .{ .name = "second", .kind = .gauge });
    try second.write(.{}, 3);

    const third = try family(&w, .{ .name = "third_bytes", .kind = .untyped, .help = "" });
    try third.write(.{}, 4);

    try testing.expectEqualStrings(
        \\# HELP first_total First family.
        \\# TYPE first_total counter
        \\first_total{k="a"} 1
        \\first_total{k="b"} 2
        \\# TYPE second gauge
        \\second 3
        \\# TYPE third_bytes untyped
        \\third_bytes 4
        \\
    , w.buffered());
}

test "HELP escapes a backslash and a newline, not a quote" {
    var buffer: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const f = try family(&w, .{
        .name = "escaped",
        .kind = .gauge,
        .help = "a\\b\"c\nd",
    });
    try f.write(.{}, 1);
    try testing.expectEqualStrings(
        "# HELP escaped a\\\\b\"c\\nd\n# TYPE escaped gauge\nescaped 1\n",
        w.buffered(),
    );
}

test "an empty HELP writes no line" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const f = try family(&w, .{ .name = "bare", .kind = .counter, .help = "" });
    try f.write(.{}, 0);
    try testing.expectEqualStrings("# TYPE bare counter\nbare 0\n", w.buffered());
}

test "a family with no samples is its header alone" {
    var buffer: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    _ = try family(&w, .{ .name = "empty_total", .kind = .counter, .help = "Nothing yet." });
    try testing.expectEqualStrings(
        "# HELP empty_total Nothing yet.\n# TYPE empty_total counter\n",
        w.buffered(),
    );
}

fn expectHistogramRender(expected: []const u8, labels_: anytype, buckets: Family.Buckets) !void {
    var buffer: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    const h = try histogramFamily(&w, .{ .name = "latency_seconds", .kind = .histogram });
    try h.write(labels_, buckets);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "a histogram with one bucket" {
    try expectHistogramRender(
        \\# TYPE latency_seconds histogram
        \\latency_seconds_bucket{le="10"} 3
        \\latency_seconds_bucket{le="+Inf"} 3
        \\latency_seconds_sum 5.5
        \\latency_seconds_count 3
        \\
    , .{}, .{ .limits = &.{10}, .counts = &.{3}, .sum = 5.5, .count = 3 });
}

test "a histogram with only the implicit bucket" {
    try expectHistogramRender(
        \\# TYPE latency_seconds histogram
        \\latency_seconds_bucket{le="+Inf"} 7
        \\latency_seconds_sum 1.25
        \\latency_seconds_count 7
        \\
    , .{}, .{ .limits = &.{}, .counts = &.{}, .sum = 1.25, .count = 7 });
}

test "a histogram puts le last and formats labels first" {
    try expectHistogramRender(
        \\# TYPE latency_seconds histogram
        \\latency_seconds_bucket{method="GET",le="1"} 1
        \\latency_seconds_bucket{method="GET",le="2"} 2
        \\latency_seconds_bucket{method="GET",le="+Inf"} 2
        \\latency_seconds_sum{method="GET"} 3
        \\latency_seconds_count{method="GET"} 2
        \\
    , .{ .method = "GET" }, .{
        .limits = &.{ 1, 2 },
        .counts = &.{ 1, 2 },
        .sum = 3,
        .count = 2,
    });
}

test "le uses the same formatter as a sample value" {
    try expectHistogramRender(
        \\# TYPE latency_seconds histogram
        \\latency_seconds_bucket{le="1e-07"} 0
        \\latency_seconds_bucket{le="0.001"} 1
        \\latency_seconds_bucket{le="1e+06"} 1
        \\latency_seconds_bucket{le="+Inf"} 1
        \\latency_seconds_sum 0.001
        \\latency_seconds_count 1
        \\
    , .{}, .{
        .limits = &.{ 1e-7, 0.001, 1e6 },
        .counts = &.{ 0, 1, 1 },
        .sum = 0.001,
        .count = 1,
    });
}

test "a histogram refuses bucket sets that would emit wrong bytes" {
    var buffer: [512]u8 = undefined;
    const cases = [_]Family.Buckets{
        // counts and limits disagree on length.
        .{ .limits = &.{1}, .counts = &.{}, .sum = 0, .count = 0 },
        // limits are not ascending.
        .{ .limits = &.{ 2, 1 }, .counts = &.{ 1, 1 }, .sum = 0, .count = 1 },
        // a repeated limit would emit the same le twice.
        .{ .limits = &.{ 1, 1 }, .counts = &.{ 1, 1 }, .sum = 0, .count = 1 },
        // a NaN limit.
        .{ .limits = &.{std.math.nan(f64)}, .counts = &.{1}, .sum = 0, .count = 1 },
        // +Inf is the implicit bucket's label.
        .{ .limits = &.{std.math.inf(f64)}, .counts = &.{1}, .sum = 0, .count = 1 },
        // counts are not cumulative.
        .{ .limits = &.{ 1, 2 }, .counts = &.{ 2, 1 }, .sum = 0, .count = 1 },
        // the total disagrees with the last bucket.
        .{ .limits = &.{1}, .counts = &.{1}, .sum = 0, .count = 2 },
    };
    for (cases) |buckets| {
        var w: Io.Writer = .fixed(&buffer);
        const h = try histogramFamily(&w, .{ .name = "x", .kind = .histogram });
        try testing.expectError(error.InvalidBuckets, h.write(.{}, buckets));
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
        const buckets: Family.Buckets = .{
            .limits = limits[0..bucket_count],
            .counts = counts[0..bucket_count],
            .sum = random.float(f64) * 1000,
            .count = cumulative,
        };

        var buffer: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buffer);
        const handle = try histogramFamily(&w, .{ .name = "h", .kind = .histogram });
        try handle.write(.{ .k = "v" }, buckets);

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

        var seen_inf = false;
        for (0..bucket_count) |i| {
            const line = lines[1 + i];
            try testing.expect(std.mem.startsWith(u8, line, "h_bucket{k=\"v\",le=\""));
            const le = try lineLe(line);
            try testing.expectEqual(limits[i], try std.fmt.parseFloat(f64, le));
            try testing.expectEqual(counts[i], try std.fmt.parseInt(u64, lineValue(line), 10));
        }

        const inf_line = lines[1 + bucket_count];
        try testing.expect(std.mem.startsWith(u8, inf_line, "h_bucket{k=\"v\",le=\"+Inf\"} "));
        try testing.expectEqualStrings("+Inf", try lineLe(inf_line));
        try testing.expectEqual(buckets.count, try std.fmt.parseInt(u64, lineValue(inf_line), 10));
        seen_inf = true;
        try testing.expect(seen_inf);

        try testing.expect(std.mem.startsWith(u8, lines[2 + bucket_count], "h_sum{k=\"v\"} "));
        const sum = try std.fmt.parseFloat(f64, lineValue(lines[2 + bucket_count]));
        try testing.expectEqual(buckets.sum, sum);

        try testing.expect(std.mem.startsWith(u8, lines[3 + bucket_count], "h_count{k=\"v\"} "));
        try testing.expectEqual(buckets.count, try std.fmt.parseInt(u64, lineValue(lines[3 + bucket_count]), 10));
    }
}
