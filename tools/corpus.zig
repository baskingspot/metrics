//! Emit random exposition documents for the oracle gate.
//!
//! `corpus OUTDIR COUNT SEED` writes COUNT documents into OUTDIR, one file per
//! document for the pipe, and the same set as one txtar archive so a failing
//! run leaves a single replayable artifact.
//!
//! A name is comptime in this API, so the catalog is fixed and everything that
//! can vary does: label values including every byte that needs escaping, label
//! shapes, integer and float values, help text with escapes and emoji, and
//! histogram bucket sets with a tail above the top limit.
//!
//! A development tool, not library code: it allocates, writes files, and is
//! exempt from the formatter and linter rules per the org's load-bearing-code
//! definition.

const std = @import("std");
const prometheus = @import("prometheus");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const math = std.math;

const Metric = prometheus.Metric;

const fragments = [_][]const u8{
    "a", "Z", "0", "_", "\\", "\"", "\n", "\t", "\r", "\x00",
    "é",
    "ß",
    "日",
    "本",
    "🦎",
    "",  " ", "-", "=", "{",
};

const families = [_]Metric{
    .{ .name = "corpus_a", .kind = .counter, .help = "A counter." },
    .{ .name = "corpus_b_total", .kind = .counter },
    .{ .name = "corpus_c", .kind = .gauge, .help = "Back\\slash\nand newline." },
    .{ .name = "corpus_d_bytes", .kind = .untyped, .help = "é 日本 🦎" },
    .{ .name = "corpus_e", .kind = .gauge, .help = "\"Quoted\", and a tab\there." },
    .{ .name = ":corpus:f", .kind = .untyped },
};

const histograms = [_]Metric{
    .{
        .name = "corpus_latency_seconds",
        .kind = .histogram,
        .help = "Latency.",
    },
    .{
        .name = "corpus_payload_bytes",
        .kind = .histogram,
    },
};

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
    if (random.boolean()) {
        // Each catalog entry goes out at most once per document, so no name
        // repeats and no second HELP line appears.
        inline for (families) |family| {
            if (random.boolean()) try emit_family(&w, family, arena, random);
        }
    } else {
        inline for (histograms) |family| {
            if (random.boolean()) try emit_histogram(&w, family, arena, random);
        }
    }
    return w.buffered();
}

const shapes = [_]type{ NoLabels, OneLabel, TwoLabels, ThreeLabels, JobInstance, PathStatus };
const values = [_]type{ u64, i64, f64 };

fn emit_family(
    w: *Io.Writer,
    comptime family: Metric,
    arena: Allocator,
    random: std.Random,
) !void {
    const shape = random.uintLessThan(usize, shapes.len);
    const value_kind = random.uintLessThan(usize, values.len);
    inline for (shapes, 0..) |Labels, si| {
        if (shape == si) {
            inline for (values, 0..) |Value, vi| {
                if (value_kind == vi) {
                    const handle = try prometheus.writeFamily(w, family);
                    const samples = try arena.alloc(Sample(Labels, Value), random.intRangeAtMost(usize, 0, 4));
                    for (samples) |*sample| {
                        sample.* = .{
                            .labels = try labels_of(Labels, arena, random),
                            .value = value_of(Value, random),
                        };
                        try handle.write(sample.labels, sample.value);
                    }
                }
            }
        }
    }
}

fn emit_histogram(
    w: *Io.Writer,
    comptime family: Metric,
    arena: Allocator,
    random: std.Random,
) !void {
    var limits: [8]f64 = undefined;
    const bucket_count = random.intRangeAtMost(usize, 0, limits.len);
    var previous: f64 = 0;
    for (0..bucket_count) |i| {
        // Strictly ascending: every step is at least 1.
        previous += random.float(f64) * 1000 + 1;
        limits[i] = previous;
    }
    var counts: [8]u64 = undefined;
    var cumulative: u64 = 0;
    for (0..bucket_count) |i| {
        cumulative += random.intRangeAtMost(u64, 0, 100);
        counts[i] = cumulative;
    }
    // A tail above the top limit is legal and belongs only to `+Inf`.
    const total = cumulative + random.intRangeAtMost(u64, 0, 5);

    const shape = random.uintLessThan(usize, shapes.len);
    inline for (shapes, 0..) |Labels, si| {
        if (shape == si) {
            try prometheus.writeHistogram(
                w,
                family,
                try labels_of(Labels, arena, random),
                limits[0..bucket_count],
                counts[0..bucket_count],
                random_float(random),
                total,
            );
        }
    }
}

fn Sample(comptime Labels: type, comptime Value: type) type {
    return struct {
        labels: Labels,
        value: Value,
    };
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

/// Valid UTF-8 only: a byte string this library must refuse belongs in the unit
/// tests, not the corpus.
fn label_text(arena: Allocator, random: std.Random) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (0..random.intRangeAtMost(usize, 0, 8)) |_| {
        try text.appendSlice(arena, fragments[random.uintLessThan(usize, fragments.len)]);
    }
    return text.items;
}

const NoLabels = struct {};
const OneLabel = struct { k: []const u8 };
const TwoLabels = struct { a: []const u8, b: []const u8 };
const ThreeLabels = struct { method: []const u8, code: u16, host: []const u8 };
const JobInstance = struct { job: []const u8, instance: []const u8 };
const PathStatus = struct { path: []const u8, status_class: u16, bucket: []const u8 };
