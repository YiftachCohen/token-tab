#!/bin/bash
# Token Tab — OPT-IN live SwiftBar plugin (server %s via `claude -p "/usage"`).
#
# Install THIS file (instead of, or alongside, token-tab.30s.sh) to enable the
# live server percentages in the menu bar. It refreshes every 2 minutes (the
# ".2m." in the filename), not 30s, because each refresh spawns the full `claude`
# CLI and the research is explicit: do not poll /usage every 30s.
#
# The default token-tab.30s.sh stays purely local and never spawns anything.
# Installing this plugin IS how you opt in on the menu bar.
#
# Install: symlink into your SwiftBar plugin folder, e.g.
#   ln -s "$PWD/swiftbar/token-tab-live.2m.sh" ~/Library/Application\ Support/SwiftBar/token-tab-live.2m.sh
# Then SwiftBar -> Refresh.

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

# 2. Resolve a JS runtime (SwiftBar gives plugins a minimal PATH, so a bare
#    `node` shebang often fails).
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

# 3. Resolve the `claude` binary the same way, for the same reason: SwiftBar's
#    minimal PATH usually won't have it. The adapter also resolves this itself,
#    but exporting it here is belt-and-suspenders.
if [ -z "${TOKENTAB_CLAUDE_BIN:-}" ]; then
  for c in /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.claude/local/claude" "$HOME/.local/bin/claude" "$HOME/.bun/bin/claude"; do
    [ -x "$c" ] && export TOKENTAB_CLAUDE_BIN="$c" && break
  done
fi

export TOKENTAB_LIVE=1

exec "$RT" "$REPO/src/token-tab.mjs" --swiftbar
