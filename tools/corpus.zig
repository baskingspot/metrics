//! Emit random exposition documents for the oracle gate.
//!
//! `corpus OUTDIR COUNT SEED` writes COUNT documents into OUTDIR. Every one is
//! produced by the library, so a document Prometheus's parser rejects is a
//! library bug, and the seed reproduces the run.
//!
//! A development tool, not library code: it allocates, writes files, and is
//! exempt from the formatter and linter rules per the org's load-bearing-code
//! definition.
//!
//! Label shapes are a fixed set of structs, because a label name is a comptime
//! struct field in the API. Everything a bug hides in still varies: label
//! values, escapes, control characters, emoji, sample counts, and values,
//! including the awkward f64s.

const std = @import("std");
const prometheus = @import("prometheus");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const math = std.math;

const fragments = [_][]const u8{
    "a", "Z", "0", "_", "\\", "\"", "\n", "\t", "\r", "\x00",
    "é", "ß", "日", "本", "🦎", "",  " ",  "-",  "=",  "{",
};

const metric_names = [_][]const u8{
    "fixture_a",       "fixture_b_total", "fixture_c", "fixture_d",
    "fixture_e_bytes", "fixture_f",       "fixture_g", "fixture_h",
    "fixture_i",       "fixture_j",       "fixture_k", "fixture_l",
};

const edge_values = [_]f64{
    0,      -0.0,           1e300, 5e-324, 1e6, 0.0001,
    1e-7,   1234567,        999999, 1.0 / 3.0,
    9007199254740993.0,     2.2250738585072014e-308,
    math.inf(f64),          -math.inf(f64), math.nan(f64),
};

/// One document is at most 12 samples of a few hundred bytes each.
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
    for (0..count) |index| {
        const text = try document(arena, random);
        var name_buffer: [256]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}/doc-{d:0>5}.prom", .{ outdir, index });
        try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = name, .data = text });
    }
    std.debug.print("corpus: {d} documents in {s}, seed {d}\n", .{ count, outdir, seed });
}

fn document(arena: Allocator, random: std.Random) ![]const u8 {
    var w: Io.Writer = .fixed(try arena.alloc(u8, document_capacity));
    for (0..random.intRangeAtMost(usize, 1, 12)) |_| {
        const name = metric_names[random.uintLessThan(usize, metric_names.len)];
        try emit_sample(&w, name, arena, random);
    }
    return w.buffered();
}

fn emit_sample(w: *Io.Writer, name: []const u8, arena: Allocator, random: std.Random) !void {
    switch (random.uintLessThan(u8, 5)) {
        0 => try emit(w, name, .{}, random),
        1 => try emit(w, name, .{ .k = try label_text(arena, random) }, random),
        2 => try emit(w, name, .{
            .a = try label_text(arena, random),
            .b = try label_text(arena, random),
        }, random),
        3 => try emit(w, name, .{
            .method = try label_text(arena, random),
            .code = random.int(u16),
            .host = try label_text(arena, random),
        }, random),
        else => try emit(w, name, .{
            .a = try label_text(arena, random),
            .b = try label_text(arena, random),
            .c = try label_text(arena, random),
            .d = try label_text(arena, random),
        }, random),
    }
}

/// The value type is chosen here so each call site is monomorphic.
fn emit(w: *Io.Writer, name: []const u8, labels: anytype, random: std.Random) !void {
    switch (random.uintLessThan(u8, 3)) {
        0 => try prometheus.sample(w, name, labels, random.int(u64)),
        1 => try prometheus.sample(w, name, labels, random.int(i64)),
        else => try prometheus.sample(w, name, labels, edge_value(random)),
    }
}

fn edge_value(random: std.Random) f64 {
    return edge_values[random.uintLessThan(usize, edge_values.len)];
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
