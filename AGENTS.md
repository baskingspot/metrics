# AGENTS.md

Working notes for AI coding agents in baskingspot/metrics.

## What this is

Prometheus text exposition format for Zig: write metrics to any writer, no HTTP. It is incubating: unstable, with no promises about its API.

## Environment

Zig 0.17. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig 0.17, `ziglint`, and the base tools, and nothing comes from the system PATH. `just ci` runs the full gate.

`zig fmt` must leave the tree unchanged. `@intFromEnum` is `@backingInt` under 0.17's formatter, so write the spelling the formatter keeps.

The justfile is the command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before you commit.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt` and lint with `ziglint`. `just fmt` and `just lint` run both.
- Two layers in one file, because Zig cannot add a method from another: `src/writer.zig` has a primitives half (`help`, `kind`, `name`, `value`, `line`) and a compositions half (`writeMetric`, `writeFamily`, `writeHistogram`, `FamilyWriter.writeHistogramSeries`), separated by a doc comment. A composition may only write through the primitives, and the test `the composition is the primitives, byte for byte` is what enforces it.
- No HTTP, allocator, clock, thread, or `var` in the library. The only error is the sink's.
- Ordering, family uniqueness, and help-or-no-help are the caller's. Do not add a registry, a document type, or a sample sequence.
- `Counter` is the only recording type, and it has no write method: the writer writes, `get` supplies the number. Do not add `set`, a gauge, or a registry.
- The format lives under `metrics.prometheus`, so a second format is a namespace beside it, not a flag. `Counter` is not under it, because a counter is not format-specific.
- Merging is additive and wraps: `Fixed.merge`/`mergeAll` for local histograms, and `Snapshot.merge`/`mergeAll` for what an atomic one fills. `mergeAll` exists because a fold that owns its accumulator keeps it in registers, which measures 2.7x a caller's merge loop (14 ns against 38 ns, sixteen workers of twelve buckets). `Fixed.mergeAll` takes `[]const *const Self` and `Snapshot.mergeAll` takes `[]const Snapshot`: the first folds histograms the caller owns in its own structs, the second folds a buffer the caller just filled. It is defined as the merge loop, and a test pins that they agree. Do not add `noalias` to `merge` to close the remaining gap: it buys the same registers by making `h.merge(&h)` undefined, and silently wrong counts are the worst failure a metrics library has.
- Bucket adds go through `addBuckets`: vector-width chunks and a scalar tail. The width is 2 lanes on aarch64, because `@Vector` cannot reach SVE's wide registers and `std.simd` answers 256 bits for any SVE core, which measures 1.4x worse there. Everywhere else it is `std.simd`'s answer, which is the register x86 really has.
- Names are comptime, which is what makes a bad name a compile error. The predicates live in `name.zig` and are tested there; the `comptime if` in the writer is only the wiring, and there are no compile-fail snippets pinning compiler messages. A guard with no runtime predicate and no test (a non-histogram `Metric`, a labels struct carrying `le`) stays a one-line `comptime if`, because deleting it is a visible diff.
- Invalid UTF-8 in a label value is `std.debug.assert`, not an error. Do not turn it into one without settling it with Matt.
- `testingx` supplies the test runner, the fixtures, and the benchmark harness. It is lazy and referenced only after `if (b.pkg_hash.len != 0) return;`, so a consumer fetches nothing but the module. Do not move the early return below it.
- The test fixtures are synthetic. Do not paste metric names, help text, or label sets from a production service.
- The oracle is `prom2json`, from the flake. `just check-golden` pipes every golden document through it and `just check-corpus N SEED` renders N seeded random documents and fails on the first rejection, keeping the txtar archive for replay.
- A compile-fail case is a file in `test/compile_fail/` plus an `.expect` holding the message it must fail with. `just check-compile-fail` runs them and fails if one compiles or fails for the wrong reason.
- This repo's GitHub settings come from `baskingspot/.github`, with `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, run `release-prep.py VERSION`, review the diff, commit it signed, push, then dispatch `release.yml` with the version. The prep moves the Unreleased section into a dated heading, sets `.version` in `build.zig.zon`, and points the install command at the tag. The workflow changes no files and refuses a version the changelog does not carry. Do not tag by hand.
