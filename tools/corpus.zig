//! Emit random exposition documents for the oracle gate.
//!
//! `corpus OUTDIR COUNT SEED` writes COUNT documents into OUTDIR, one file per
//! document for the pipe, and the same set as one txtar archive so a failing
//! run leaves a single replayable artifact.
//!
//! Every document comes from the `runtime` door, because that is the one that
//! takes a composed name and random help text. The comptime door's own bytes
//! are the golden fixtures' job.
//!
//! A development tool, not library code: it allocates, writes files, and is
//! exempt from the formatter and linter rules per the org's load-bearing-code
//! definition.

const std = @import("std");
const prometheus = @import("prometheus");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const math = std.math;

const fragments = [_][]const u8{
    "a", "Z", "0", "_", "\\", "\"", "\n", "\t", "\r", "\x00",
    "é",
    "ß",
    "日",
    "本",
    "🦎",
    "",  " ", "-", "=", "{",
};

const kinds = [_]prometheus.Kind{ .counter, .gauge, .untyped };

const edge_values = [_]f64{
    0,             -0.0,           1e300,         5e-324,    1e6,                0.0001,
    1e-7,          1234567,        999999,        1.0 / 3.0, 9007199254740993.0, 2.2250738585072014e-308,
    math.inf(f64), -math.inf(f64), math.nan(f64),
};

const document_capacity = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: corpus OUTDIR COUNT SEED\n", .{});
        return error.BadArguments;
    }
    const outdir = args[1];
    const count = try std.fmt.parseInt(u32, args[2], 10);
    const seed = try std.fmt.parseInt(u64, args[3], 10);

    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    try Io.Dir.cwd().createDirPath(init.io, outdir);

    var archive: std.ArrayList(u8) = .empty;
    try archive.appendSlice(arena, "Prometheus corpus. Each section is one document, and the seed is in the comment.\n");

    for (0..count) |index| {
        const text = try document(arena, random);
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "doc-{d:0>5}", .{index});
        try archive.appendSlice(arena, "-- ");
        try archive.appendSlice(arena, name);
        try archive.appendSlice(arena, " --\n");
        try archive.appendSlice(arena, text);

        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}.prom", .{ outdir, name });
        try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = text });
    }

    var archive_path: [256]u8 = undefined;
    const txtar = try std.fmt.bufPrint(&archive_path, "{s}/corpus.txtar", .{outdir});
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = txtar, .data = archive.items });

    std.debug.print("corpus: {d} documents in {s}, seed {d}\n", .{ count, outdir, seed });
}

fn document(arena: Allocator, random: std.Random) ![]const u8 {
    var w: Io.Writer = .fixed(try arena.alloc(u8, document_capacity));
    // One document is either bare families or histograms. Mixing them can put a
    // header-less series in a family that already has a TYPE line.
    if (random.boolean()) {
        for (0..random.intRangeAtMost(usize, 1, 6)) |_| {
            try emit_family(&w, arena, random);
        }
    } else {
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            try emit_histogram(&w, arena, random);
        }
    }
    return w.buffered();
}

fn emit_family(w: *Io.Writer, arena: Allocator, random: std.Random) !void {
    const family = prometheus.Family{
        .name = try metric_name(arena, random),
        .kind = kinds[random.uintLessThan(usize, kinds.len)],
        .help = if (random.boolean()) try label_text(arena, random) else "",
    };
    switch (random.uintLessThan(u8, 4)) {
        0 => {
            const samples = try one_sample(arena, random);
            try prometheus.runtime.family(w, family, samples);
        },
        1 => {
            const samples = try two_samples(arena, random);
            try prometheus.runtime.family(w, family, samples);
        },
        2 => {
            const samples = try three_samples(arena, random);
            try prometheus.runtime.family(w, family, samples);
        },
        else => {
            const samples = try no_samples(arena, random);
            try prometheus.runtime.family(w, family, samples);
        },
    }
}

const NoLabels = struct {};
const OneLabel = struct { k: []const u8 };
const TwoLabels = struct { a: []const u8, b: []const u8 };
const ThreeLabels = struct { method: []const u8, code: u16, host: []const u8 };

fn Sample(comptime Labels: type) type {
    // f64, so a random bit pattern of them is the value coverage: NaN, the
    // infinities, subnormals, and the exponent edges. Integers take a different
    // branch of the writer and the golden fixtures pin them.
    return struct {
        labels: Labels,
        value: f64,
    };
}

fn no_samples(arena: Allocator, random: std.Random) ![]const Sample(NoLabels) {
    const samples = try arena.alloc(Sample(NoLabels), random.intRangeAtMost(usize, 0, 4));
    for (samples) |*sample| sample.* = .{ .labels = .{}, .value = random_value(random) };
    return samples;
}

fn one_sample(arena: Allocator, random: std.Random) ![]const Sample(OneLabel) {
    const samples = try arena.alloc(Sample(OneLabel), random.intRangeAtMost(usize, 0, 4));
    for (samples) |*sample| {
        sample.* = .{
            .labels = .{ .k = try label_text(arena, random) },
            .value = random_value(random),
        };
    }
    return samples;
}

fn two_samples(arena: Allocator, random: std.Random) ![]const Sample(TwoLabels) {
    const samples = try arena.alloc(Sample(TwoLabels), random.intRangeAtMost(usize, 0, 4));
    for (samples) |*sample| {
        sample.* = .{
            .labels = .{
                .a = try label_text(arena, random),
                .b = try label_text(arena, random),
            },
            .value = random_value(random),
        };
    }
    return samples;
}

fn three_samples(arena: Allocator, random: std.Random) ![]const Sample(ThreeLabels) {
    const samples = try arena.alloc(Sample(ThreeLabels), random.intRangeAtMost(usize, 0, 4));
    for (samples) |*sample| {
        sample.* = .{
            .labels = .{
                .method = try label_text(arena, random),
                .code = random.int(u16),
                .host = try label_text(arena, random),
            },
            .value = random_value(random),
        };
    }
    return samples;
}

fn emit_histogram(w: *Io.Writer, arena: Allocator, random: std.Random) !void {
    var limits: [8]f64 = undefined;
    const bucket_count = random.intRangeAtMost(usize, 0, limits.len);
    var previous: f64 = 0;
    for (0..bucket_count) |i| {
        // Strictly ascending: every step is at least 1.
        previous += random.float(f64) * 1000 + 1;
        limits[i] = previous;
    }
    const family = prometheus.Family{
        .name = try metric_name(arena, random),
        .kind = .histogram,
        .help = if (random.boolean()) try label_text(arena, random) else "",
        .limits = limits[0..bucket_count],
    };

    const Histogram = struct {
        labels: TwoLabels,
        counts: []const u64,
        sum: f64,
        count: u64,
    };
    var counts: [8]u64 = undefined;
    var cumulative: u64 = 0;
    for (0..bucket_count) |i| {
        cumulative += random.intRangeAtMost(u64, 0, 100);
        counts[i] = cumulative;
    }
    // A tail above the top limit is legal and belongs only to `+Inf`.
    const total = cumulative + random.intRangeAtMost(u64, 0, 5);
    const sample = [1]Histogram{.{
        .labels = .{
            .a = try label_text(arena, random),
            .b = try label_text(arena, random),
        },
        .counts = counts[0..bucket_count],
        .sum = random.float(f64) * 1000,
        .count = total,
    }};
    try prometheus.runtime.histogramFamily(w, family, &sample);
}

fn random_value(random: std.Random) f64 {
    return switch (random.uintLessThan(u8, 4)) {
        0 => @bitCast(random.int(u64)),
        1, 2 => edge_values[random.uintLessThan(usize, edge_values.len)],
        else => random.float(f64) * 1e6,
    };
}

/// Valid UTF-8 only: a document that a correct writer must refuse belongs in
/// the unit tests, not the corpus.
fn label_text(arena: Allocator, random: std.Random) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..random.intRangeAtMost(usize, 0, 8)) |_| {
        try text.appendSlice(arena, fragments[random.uintLessThan(usize, fragments.len)]);
    }
    return text.items;
}

fn metric_name(arena: Allocator, random: std.Random) ![]const u8 {
    const prefixes = [_][]const u8{ "corpus_", "fixture_", ":corpus:", "_corpus" };
    var name: std.ArrayList(u8) = .empty;
    try name.appendSlice(arena, prefixes[random.uintLessThan(usize, prefixes.len)]);
    for (0..random.intRangeAtMost(usize, 1, 12)) |_| {
        const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_";
        try name.append(arena, alphabet[random.uintLessThan(usize, alphabet.len)]);
    }
    return name.items;
}
