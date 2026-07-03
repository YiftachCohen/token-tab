#!/usr/bin/env bash
# Token Tab — the trust-invariant audit, as one runnable script.
#
# The single source of truth for the checks described in AGENTS.md ("Invariants") and
# README.md ("Audit it yourself"). Run by BOTH .github/workflows/ci.yml (pushes/PRs)
# and .github/workflows/release.yml (tags) so no release artifact can be drafted from
# a commit that skipped the audit. Also fine to run locally: .github/scripts/trust-audit.sh
set -u

fail=0
report() { if [ -n "$2" ]; then echo "::error::$1"; echo "$2"; fail=1; fi; }

# JS core (src/): no network, no subprocess, never reads content.
report "src/ makes a network call"          "$(grep -RnE 'fetch|http|https|net\.|URLSession|Socket|dns' src/ || true)"
report "src/ spawns a subprocess"           "$(grep -RnE 'child_process|spawn|execFile' src/ || true)"
report "src/ reads message content"         "$(grep -RnE '\.content' src/ | grep -v '//' || true)"

# Native app (app/Sources): sandbox forbids network/subprocess; no content field.
report "app/Sources makes a network call"   "$(grep -RnE 'URLSession|NWConnection|CFSocket|getaddrinfo|Socket' app/Sources || true)"
report "app/Sources spawns a subprocess"    "$(grep -RnE 'Process\(|posix_spawn|NSTask|popen|execv' app/Sources || true)"
report "app/Sources reads message content"  "$(grep -RnE 'message\.content|\"content\"' app/Sources | grep -v '//' || true)"

# Zero runtime dependencies.
deps="$(node -e 'const d=require("./package.json").dependencies||{};process.stdout.write(Object.keys(d).join(","))')"
if [ -n "$deps" ]; then echo "::error::package.json declares runtime dependencies: $deps"; fail=1; fi

if [ "$fail" -ne 0 ]; then echo "Trust invariant violated — see errors above."; fi
exit $fail
