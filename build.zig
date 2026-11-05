const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("prometheus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.pkg_hash.len != 0) return;

    const test_step = b.step("test", "Run the unit tests and the guide's examples");

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    passthruArgs(b, run_mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // The guide's examples are real programs against the public module, tested
    // with everything else so a guide page cannot show code that does not build.
    const examples_mod = b.createModule(.{
        .root_source_file = b.path("docs/examples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "prometheus", .module = mod }},
    });
    const example_tests = b.addTest(.{ .root_module = examples_mod });
    const run_example_tests = b.addRunArtifact(example_tests);
    test_step.dependOn(&run_example_tests.step);

    // The two oracle gates drive real programs against the public module: one
    // fixed document, and the seeded corpus. Neither is installed.
    addTool(b, mod, target, optimize, "fixture", "tools/fixture.zig");
    addTool(b, mod, target, optimize, "corpus", "tools/corpus.zig");
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
            .imports = &.{.{ .name = "prometheus", .module = mod }},
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
