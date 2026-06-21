#!/bin/bash
# Token Tab — SwiftBar plugin (the "tonight" on-ramp; the native app is the keeper).
#
# Refresh: every 30s (the ".30s." in the filename — SwiftBar reads it from there).
# Install: symlink this file into your SwiftBar plugin folder, e.g.
#   ln -s "$PWD/swiftbar/token-tab.30s.sh" ~/Library/Application\ Support/SwiftBar/token-tab.30s.sh
# Then SwiftBar → Refresh. See swiftbar/README.md.
#
# This wrapper exists because SwiftBar runs plugins with a minimal PATH, so a bare
# `node` shebang often fails. It (1) resolves a JS runtime from known locations and
# (2) resolves the repo even when invoked via a symlink in the plugin folder.

set -euo pipefail

# 1. Resolve this script's real location (follow symlinks), then the repo root.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  TARGET="$(readlink "$SELF")"
  case "$TARGET" in
    /*) SELF="$TARGET" ;;
    *) SELF="$(dirname "$SELF")/$TARGET" ;;
  esac
done
REPO="$(cd "$(dirname "$SELF")/.." && pwd)"

# 2. Resolve a JS runtime (Homebrew arm/intel, system, bun, then PATH).
RT=""
for c in /opt/homebrew/bin/node /usr/local/bin/node "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun; do
  [ -x "$c" ] && RT="$c" && break
done
[ -z "$RT" ] && RT="$(command -v node || command -v bun || true)"

if [ -z "$RT" ]; then
  echo "Token Tab ⚠️"
  echo "---"
  echo "No node/bun found on PATH. Install Node or Bun. | color=red"
  exit 0
fi

exec "$RT" "$REPO/src/token-tab.mjs" --swiftbar
