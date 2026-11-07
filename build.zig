const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("metrics", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.pkg_hash.len != 0) return;

    // testingx provides the test runner. It is lazy because only the root
    // build uses it; a consumer never fetches it. On the first configure pass
    // it is not fetched yet, `lazyDependency` returns null, and the build
    // runner fetches it and reruns this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target });
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (testingx_dep) |dep|
        .{ .path = dep.path("src/runner.zig"), .mode = .simple }
    else
        null;

    const test_step = b.step("test", "Run the unit tests and the guide's examples");

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = test_runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    passthruArgs(b, run_mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // The golden documents and the runtime door's error paths. The archive is
    // embedded at compile time, so the case data is a file a person can read
    // and a diff shows bytes. It needs testingx for the fixture reader, so it
    // waits for the fetch like the runner does: on the first configure pass the
    // dependency is null, the runner fetches it, and this script runs again.
    if (testingx_dep) |dep| {
        const golden_mod = b.createModule(.{
            .root_source_file = b.path("test/golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "metrics", .module = mod },
                .{ .name = "testingx", .module = dep.module("testingx") },
            },
        });
        const golden_tests = b.addTest(.{ .root_module = golden_mod, .test_runner = test_runner });
        const run_golden_tests = b.addRunArtifact(golden_tests);
        test_step.dependOn(&run_golden_tests.step);
    }

    // The guide's examples are real programs against the public module, tested
    // with everything else so a guide page cannot show code that does not build.
    const examples_mod = b.createModule(.{
        .root_source_file = b.path("docs/examples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "metrics", .module = mod }},
    });
    const example_tests = b.addTest(.{ .root_module = examples_mod, .test_runner = test_runner });
    const run_example_tests = b.addRunArtifact(example_tests);
    test_step.dependOn(&run_example_tests.step);

    // The oracle gate: a seeded corpus of documents, one file each and the set
    // as one txtar. It is a development program, not an installed one.
    addTool(b, mod, target, optimize, "corpus", "tools/corpus.zig");

    // testingx's addBench builds the suite as a ReleaseFast executable. While
    // the lazy dependency is unfetched `lazyImport` returns null and no bench
    // step is defined; the build runner fetches it and reruns this script.
    if (b.lazyImport(@This(), "testingx")) |testingx| {
        const bench_dep = b.lazyDependency("testingx", .{ .target = target }).?;
        const bench_step = b.step("bench", "Run the encode benchmarks (ReleaseFast)");
        const run_bench = testingx.addBench(b, .{
            .name = "bench-encode",
            .module = bench_dep.module("testingx"),
            .root_source_file = b.path("bench/encode.zig"),
            .imports = &.{.{ .name = "metrics", .module = mod }},
        });
        passthruArgs(b, run_bench);
        bench_step.dependOn(&run_bench.step);
    }
}

fn addTool(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
) void {
    const tool = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "metrics", .module = mod }},
        }),
    });
    const run = b.addRunArtifact(tool);
    passthruArgs(b, run);
    b.step(name, b.fmt("Run tools/{s}.zig", .{name})).dependOn(&run.step);
}

/// `b.args` (removed in Zig 0.17) and `Run.addPassthruArgs` are the same
/// feature on either side of the split. Probe the build API, not the version.
fn passthruArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run.addPassthruArgs();
    } else if (b.args) |args| {
        run.addArgs(args);
    }
}
