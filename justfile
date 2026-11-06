# prometheus: Prometheus text exposition format for Zig: write metrics to any writer, no HTTP. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests: the module, including the golden tables and the round-trip properties")]
[group("test")]
test:
    zig build test --summary all

[doc("Emit N random documents with SEED and feed each to prom2json. Fails on the first rejection, prints the seed, and keeps the txtar archive")]
[group("test")]
check-corpus N="50" SEED="1":
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(mktemp -d)
    cleanup() {
        if [ $? -eq 0 ]; then
            rm -rf "$out"
        else
            echo "corpus replay: $out/corpus.txtar (seed {{ SEED }})" >&2
        fi
    }
    trap cleanup EXIT
    zig build corpus -- "$out" {{ N }} {{ SEED }}
    for doc in "$out"/*.prom; do
        if ! prom2json "$doc" > /dev/null; then
            echo "prom2json rejected $doc (seed {{ SEED }})" >&2
            cat "$doc" >&2
            exit 1
        fi
    done
    echo "corpus: $(ls "$out"/*.prom | wc -l | tr -d ' ') documents accepted by prom2json (seed {{ SEED }})"

# A lazy dependency that developer-only code unwraps compiles fine with a warm
# `zig-pkg` and panics on the first configure pass of a cold one: the fetch
# happens after build.zig returns null once. CI caught exactly that here, and
# no local run could, so the check is a recipe rather than a habit. It is not
# part of `ci` because a full rebuild is not a few seconds.
[doc("Cold-cache gate: delete zig-pkg and .zig-cache, then build the tests and the benchmark. Catches a lazy dependency unwrapped instead of guarded")]
[group("test")]
check-cold:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf zig-pkg .zig-cache
    zig build test
    zig build bench -- --count=1

# The goldens are the comptime door's bytes, and the corpus never produces an
# integer value, so without this the oracle would only ever see floats from the
# runtime door. It splits the archive on the txtar markers, which is safe
# because a golden document holds no NUL.
[doc("Pipe every golden document through prom2json, so the comptime door and the integer values reach the oracle on both lanes")]
[group("test")]
check-golden:
    #!/usr/bin/env bash
    set -euo pipefail
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    current=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "-- "*" --")
                current=${line#-- }
                current=${current% --}
                : > "$out/$current"
                ;;
            *)
                if [ -n "$current" ]; then printf '%s\n' "$line" >> "$out/$current"; fi
                ;;
        esac
    done < test/testdata/golden.txtar
    for doc in "$out"/*.expected; do
        if ! prom2json "$doc" > /dev/null; then
            echo "prom2json rejected $doc" >&2
            cat "$doc" >&2
            exit 1
        fi
    done
    echo "golden: $(ls "$out" | wc -l | tr -d ' ') documents accepted by prom2json"

[doc("Run the encode benchmarks in ReleaseFast through testingx, reporting bytes per second. Pass --count=N to repeat")]
[group("test")]
bench:
    zig build bench -- --count=5

[doc("Build and run the encode benchmark once, so a benchmark that stops compiling fails CI")]
[group("ci")]
check-bench:
    zig build bench -- --count=1

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, the shared ast-grep rules, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint-0-16
    baskingspot-lint src
    zig fmt --check src test tools bench build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md docs/content docs/config.toml docs/static .github .oxfmtrc.jsonc wrangler.jsonc
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src test tools bench build.zig build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md docs/content docs/config.toml docs/static .github .oxfmtrc.jsonc wrangler.jsonc
    just --fmt

[doc("The per-version gate: the module suite and the oracle pass over the goldens, on either compiler")]
[group("ci")]
check: test check-golden

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
ci: check lint check-corpus check-bench doc
