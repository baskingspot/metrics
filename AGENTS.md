# AGENTS.md

Working notes for AI coding agents in baskingspot/prometheus.

## What this is

Prometheus text exposition format for Zig: write metrics to any writer, no HTTP. It is incubating: unstable, with no promises about its API.

## Environment

Zig 0.16 and 0.17, one behavior. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig 0.17, `ziglint`, and the base tools, `nix develop .#zig-old` provides Zig 0.16, and nothing comes from the system PATH. `src/compat.zig` holds the shims, and no public API may be conditional on the version. `just ci` runs the full gate on 0.17; `just check` is the lane that must pass on 0.16.

Both `zig fmt` versions must leave the tree unchanged. `@intFromEnum` is out for that reason: 0.17's formatter rewrites it to `@backingInt`, which 0.16 cannot parse.

The justfile is the command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before you commit.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran. A run on one compiler says nothing about the other.
- Format with `zig fmt` and lint with `ziglint`. `just fmt` and `just lint` run both.
- `build.zig.zon` has no dependencies. The writer's only sink is `*std.Io.Writer`; there is no HTTP, allocator, clock, thread, or `var` in the library.
- The test fixtures are synthetic. Do not paste metric names, help text, or label sets from a production service.
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
