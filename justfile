# prometheus: Prometheus text exposition format for Zig: write metrics to any writer, no HTTP. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, the shared ast-grep rules, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint-0-16
    baskingspot-lint src
    zig fmt --check src build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md .github .oxfmtrc.jsonc
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md .github .oxfmtrc.jsonc
    just --fmt

[doc("The per-version gate: the module suite")]
[group("ci")]
check: test

[doc("Everything CI runs: the gate and lint")]
[group("ci")]
ci: check lint
