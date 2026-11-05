# prometheus: Prometheus text exposition format for Zig: write metrics to any writer, no HTTP. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests: the module, including the golden tables and the round-trip properties")]
[group("test")]
test:
    zig build test --summary all

[doc("Pipe the fixture document through prom2json, Prometheus 3.15.1's own parser. It rejects a bad escape, a raw newline, a bad name, or bad UTF-8")]
[group("test")]
check-fixture:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build fixture | prom2json > /dev/null

[doc("Emit N random documents with SEED and feed each to prom2json. Fails on the first rejection and prints the seed")]
[group("test")]
check-corpus N="200" SEED="1":
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    zig build corpus -- "$out" {{ N }} {{ SEED }}
    for doc in "$out"/*.prom; do
        if ! prom2json "$doc" > /dev/null; then
            echo "prom2json rejected $doc (seed {{ SEED }})" >&2
            cat "$doc" >&2
            exit 1
        fi
    done
    echo "corpus: $(ls "$out" | wc -l | tr -d ' ') documents accepted by prom2json (seed {{ SEED }})"

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

[doc("The per-version gate: the module suite and the oracle fixture, on either compiler")]
[group("ci")]
check: test check-fixture

[doc("Everything CI runs: the gate, lint, and the seeded corpus")]
[group("ci")]
ci: check lint check-corpus
