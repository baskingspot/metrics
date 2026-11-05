//! Emit random exposition documents for the oracle gate.
//!
//! `corpus OUTDIR COUNT SEED` writes COUNT documents into OUTDIR, one file per
//! document for the pipe, and the same set as one txtar archive so a failing
//! run leaves a single replayable artifact.
//!
//! What varies, because each of these was a place the oracle could not see:
//! both doors (a comptime catalog and random runtime descriptors), integer
//! values as well as floats, six label shapes, random label text including
//! every byte that needs escaping, histograms with tails above the top limit,
//! and empty or missing HELP.
//!
//! A development tool, not library code: it allocates, writes files, and is
//! exempt from the formatter and linter rules per the org's load-bearing-code
//! definition.

const std = @import("std");
const prometheus = @import("prometheus");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const math = std.math;

const Family = prometheus.Family;

const fragments = [_][]const u8{
    "a", "Z", "0", "_", "\\", "\"", "\n", "\t", "\r", "\x00",
    "é",
    "ß",
    "日",
    "本",
    "🦎",
    "",  " ", "-", "=", "{",
};

/// The comptime door needs its names, helps, and limits at compile time, so it
/// draws from a fixed catalog. The runtime door draws from the generator.
const comptime_families = [_]Family{
    .{ .name = "corpus_ct_a", .kind = .counter, .help = "Comptime counter." },
    .{ .name = "corpus_ct_b_total", .kind = .counter },
    .{ .name = "corpus_ct_c", .kind = .gauge, .help = "Back\\slash\nand newline." },
    .{ .name = "corpus_ct_d_bytes", .kind = .untyped, .help = "é 日本 🦎" },
    .{ .name = "corpus_ct_e", .kind = .gauge, .help = "\"Quoted\", and a tab\there." },
};

const comptime_histograms = [_]Family{
    .{
        .name = "corpus_ct_latency_seconds",
        .kind = .histogram,
        .help = "Latency.",
        .limits = &.{ 0.005, 0.05, 0.5 },
    },
    .{
        .name = "corpus_ct_payload_bytes",
        .kind = .histogram,
        .limits = &.{ 64, 1024, 65536 },
    },
    .{
        .name = "corpus_ct_unbucketed",
        .kind = .histogram,
        .help = "No limits.",
    },
};

const runtime_kinds = [_]prometheus.Kind{ .counter, .gauge, .untyped };

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

/// One document is one door and one shape. Mixing a bare family with a
/// histogram in one document is legal but says nothing extra, and two families
/// of the same name would be a second HELP line, which is the driver's bug.
fn document(arena: Allocator, random: std.Random) ![]const u8 {
    var w: Io.Writer = .fixed(try arena.alloc(u8, document_capacity));
    const comptime_door = random.boolean();
    if (random.boolean()) {
        // The comptime catalog is walked once, so no name repeats and no
        // second HELP line appears; runtime names are random enough.
        if (comptime_door) {
            try emit_comptime_family(&w, arena, random);
        } else {
            for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
                try emit_runtime_family(&w, arena, random);
            }
        }
    } else {
        if (comptime_door) {
            try emit_comptime_histogram(&w, arena, random);
        } else {
            for (0..random.intRangeAtMost(usize, 1, 3)) |_| {
                try emit_runtime_histogram(&w, arena, random);
            }
        }
    }
    return w.buffered();
}

// -- The comptime door -----------------------------------------------------

/// Each catalog entry goes out at most once per document, so a name never
/// repeats, which would be a second HELP line.
fn emit_comptime_family(w: *Io.Writer, arena: Allocator, random: std.Random) !void {
    inline for (comptime_families) |family| {
        if (random.boolean()) try emit_samples(w, family, arena, random);
    }
}

fn emit_comptime_histogram(w: *Io.Writer, arena: Allocator, random: std.Random) !void {
    inline for (comptime_histograms) |family| {
        if (random.boolean()) try emit_histograms(w, family, family.limits, arena, random);
    }
}

// -- The runtime door ------------------------------------------------------

fn emit_runtime_family(w: *Io.Writer, arena: Allocator, random: std.Random) !void {
    const family = Family{
        .name = try metric_name(arena, random),
        .kind = runtime_kinds[random.uintLessThan(usize, runtime_kinds.len)],
        .help = if (random.boolean()) try label_text(arena, random) else "",
    };
    try emit_runtime_samples(w, family, arena, random);
}

fn emit_runtime_histogram(w: *Io.Writer, arena: Allocator, random: std.Random) !void {
    var limits: [8]f64 = undefined;
    const bucket_count = random.intRangeAtMost(usize, 0, limits.len);
    var previous: f64 = 0;
    for (0..bucket_count) |i| {
        // Strictly ascending: every step is at least 1.
        previous += random.float(f64) * 1000 + 1;
        limits[i] = previous;
    }
    const family = Family{
        .name = try metric_name(arena, random),
        .kind = .histogram,
        .help = if (random.boolean()) try label_text(arena, random) else "",
        .limits = limits[0..bucket_count],
    };
    try emit_runtime_histograms(w, family, family.limits, arena, random);
}

// -- Samples through either door -------------------------------------------

const shapes = [_]type{ NoLabels, OneLabel, TwoLabels, ThreeLabels, JobInstance, PathStatus };
const values = [_]type{ u64, i64, f64 };

/// The label shape and the value type are types, so they are chosen with an
/// unrolled dispatch instead of an if-chain over values.
fn emit_samples(
    w: *Io.Writer,
    comptime family: Family,
    arena: Allocator,
    random: std.Random,
) !void {
    const shape = random.uintLessThan(usize, shapes.len);
    const value_kind = random.uintLessThan(usize, values.len);
    inline for (shapes, 0..) |Labels, si| {
        if (shape == si) {
            inline for (values, 0..) |Value, vi| {
                if (value_kind == vi) {
                    const samples = try make_samples(Labels, Value, arena, random);
                    try prometheus.family(w, family, samples);
                }
            }
        }
    }
}

fn emit_runtime_samples(w: *Io.Writer, family: Family, arena: Allocator, random: std.Random) !void {
    const shape = random.uintLessThan(usize, shapes.len);
    const value_kind = random.uintLessThan(usize, values.len);
    inline for (shapes, 0..) |Labels, si| {
        if (shape == si) {
            inline for (values, 0..) |Value, vi| {
                if (value_kind == vi) {
                    const samples = try make_samples(Labels, Value, arena, random);
                    try prometheus.runtime.family(w, family, samples);
                }
            }
        }
    }
}

fn Sample(comptime Labels: type, comptime Value: type) type {
    return struct {
        labels: Labels,
        value: Value,
    };
}

fn make_samples(
    comptime Labels: type,
    comptime Value: type,
    arena: Allocator,
    random: std.Random,
) ![]const Sample(Labels, Value) {
    const samples = try arena.alloc(Sample(Labels, Value), random.intRangeAtMost(usize, 0, 4));
    for (samples) |*sample| {
        sample.* = .{
            .labels = try labels_of(Labels, arena, random),
            .value = value_of(Value, random),
        };
    }
    return samples;
}

fn labels_of(comptime Labels: type, arena: Allocator, random: std.Random) !Labels {
    if (comptime Labels == NoLabels) return .{};
    if (comptime Labels == OneLabel) return .{ .k = try label_text(arena, random) };
    if (comptime Labels == TwoLabels) return .{
        .a = try label_text(arena, random),
        .b = try label_text(arena, random),
    };
    if (comptime Labels == ThreeLabels) return .{
        .method = try label_text(arena, random),
        .code = random.int(u16),
        .host = try label_text(arena, random),
    };
    if (comptime Labels == JobInstance) return .{
        .job = try label_text(arena, random),
        .instance = try label_text(arena, random),
    };
    if (comptime Labels == PathStatus) return .{
        .path = try label_text(arena, random),
        .status_class = random.int(u16),
        .bucket = try label_text(arena, random),
    };
    @compileError("corpus: no generator for this label shape");
}

fn value_of(comptime Value: type, random: std.Random) Value {
    if (comptime Value == u64) return random.int(u64);
    if (comptime Value == i64) return random.int(i64);
    if (comptime Value == f64) return random_float(random);
    @compileError("corpus: no generator for this value type");
}

fn random_float(random: std.Random) f64 {
    return switch (random.uintLessThan(u8, 4)) {
        0 => @bitCast(random.int(u64)),
        1, 2 => edge_values[random.uintLessThan(usize, edge_values.len)],
        else => random.float(f64) * 1e6,
    };
}

// -- Histograms through either door ----------------------------------------

fn emit_histograms(
    w: *Io.Writer,
    comptime family: Family,
    limits: []const f64,
    arena: Allocator,
    random: std.Random,
) !void {
    const shape = random.uintLessThan(usize, shapes.len);
    inline for (shapes, 0..) |Labels, si| {
        if (shape == si) {
            const samples = try make_histograms(Labels, limits, arena, random);
            try prometheus.histogramFamily(w, family, samples);
        }
    }
}

fn emit_runtime_histograms(
    w: *Io.Writer,
    family: Family,
    limits: []const f64,
    arena: Allocator,
    random: std.Random,
) !void {
    const shape = random.uintLessThan(usize, shapes.len);
    inline for (shapes, 0..) |Labels, si| {
        if (shape == si) {
            const samples = try make_histograms(Labels, limits, arena, random);
            try prometheus.runtime.histogramFamily(w, family, samples);
        }
    }
}

fn Histogram(comptime Labels: type) type {
    return struct {
        labels: Labels,
        counts: []const u64,
        sum: f64,
        count: u64,
    };
}

fn make_histograms(
    comptime Labels: type,
    limits: []const f64,
    arena: Allocator,
    random: std.Random,
) ![]const Histogram(Labels) {
    const samples = try arena.alloc(Histogram(Labels), random.intRangeAtMost(usize, 0, 3));
    for (samples) |*sample| {
        const counts = try arena.alloc(u64, limits.len);
        var cumulative: u64 = 0;
        for (counts) |*count| {
            cumulative += random.intRangeAtMost(u64, 0, 100);
            count.* = cumulative;
        }
        // A tail above the top limit is legal and belongs only to `+Inf`.
        const tail = random.intRangeAtMost(u64, 0, 5);
        sample.* = .{
            .labels = try labels_of(Labels, arena, random),
            .counts = counts,
            .sum = random_float(random),
            .count = cumulative + tail,
        };
    }
    return samples;
}

// -- Names and label text --------------------------------------------------

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

const NoLabels = struct {};
const OneLabel = struct { k: []const u8 };
const TwoLabels = struct { a: []const u8, b: []const u8 };
const ThreeLabels = struct { method: []const u8, code: u16, host: []const u8 };
const JobInstance = struct { job: []const u8, instance: []const u8 };
const PathStatus = struct { path: []const u8, status_class: u16, bucket: []const u8 };
