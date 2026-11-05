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

[doc("Compile the snippets in test/compile_fail and fail unless each is rejected at comptime with its own message")]
[group("test")]
check-compile-fail:
    #!/usr/bin/env bash
    set -euo pipefail
    for source in test/compile_fail/*.zig; do
        expected=$(cat "${source%.zig}.expect")
        if output=$(zig test --dep prometheus -Mroot="$source" -Mprometheus=src/root.zig 2>&1); then
            echo "compiled, but must not: $source" >&2
            exit 1
        fi
        if ! printf '%s' "$output" | grep -qF "$expected"; then
            echo "$source failed for the wrong reason; expected: $expected" >&2
            printf '%s\n' "$output" >&2
            exit 1
        fi
    done
    echo "compile-fail: $(ls test/compile_fail/*.zig | wc -l | tr -d ' ') cases rejected at comptime"

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, the shared ast-grep rules, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint-0-16
    baskingspot-lint src
    zig fmt --check src test tools build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md docs/content docs/config.toml docs/static .github .oxfmtrc.jsonc wrangler.jsonc
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src test tools build.zig build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md docs/content docs/config.toml docs/static .github .oxfmtrc.jsonc wrangler.jsonc
    just --fmt

[doc("The per-version gate: the module suite, the oracle fixture, and the compile-fail snippets, on either compiler")]
[group("ci")]
check: test check-fixture check-compile-fail

[doc("Build the site into zig-out/site/prometheus/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/")]
[group("docs")]
doc: api
    baskingspot-docs build prometheus

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve prometheus

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title prometheus --repo-url https://github.com/baskingspot/prometheus --rev main --format json --out docs/data

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Everything CI runs: the gate, lint, the seeded corpus, and the site build")]
[group("ci")]
ci: check lint check-corpus doc
