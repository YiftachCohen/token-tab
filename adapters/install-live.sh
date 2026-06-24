#!/usr/bin/env bash
# Token Tab — install the live sidecar as a per-user LaunchAgent.
#
# This is the "blessed" way to keep the live server-% fresh: it runs
# adapters/write-live.mjs on a timer so the menu-bar app always has a recent
# reading to display. The app itself never runs this — it's sandboxed with no
# network. Everything the network/keychain touches lives in this scheduled
# helper, which YOU install here and can remove at any time.
#
# Usage:
#   adapters/install-live.sh            # install + load (refresh every 5 min)
#   adapters/install-live.sh uninstall  # stop + remove the LaunchAgent
#   adapters/install-live.sh print      # print the plist it would write (no changes)
#
# Override the cadence:  TOKENTAB_LIVE_INTERVAL=120 adapters/install-live.sh
set -euo pipefail

LABEL="com.tokentab.live"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # adapters/
SIDECAR="$HERE/write-live.mjs"
LOG="$HOME/Library/Logs/token-tab-live.log"
INTERVAL="${TOKENTAB_LIVE_INTERVAL:-300}"
DOMAIN="gui/$(id -u)"

# Resolve node (baked in absolutely — launchd has a minimal PATH) and claude
# (passed as TOKENTAB_CLAUDE_BIN so the sidecar finds it without a login shell).
NODE="$(command -v node || true)"
CLAUDE="$(command -v claude || true)"
for c in /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "$HOME/.bun/bin/claude"; do
  [ -z "$CLAUDE" ] && [ -x "$c" ] && CLAUDE="$c"
done

gen_plist() {
  local claude_env=""
  [ -n "$CLAUDE" ] && claude_env="
    <key>TOKENTAB_CLAUDE_BIN</key><string>$CLAUDE</string>"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$SIDECAR</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>$claude_env
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
}

case "${1:-install}" in
  print)
    gen_plist
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✓ live helper removed ($LABEL)"
    ;;
  install)
    [ -n "$NODE" ] || { echo "✗ node not found on PATH — install Node, then re-run"; exit 1; }
    [ -f "$SIDECAR" ] || { echo "✗ sidecar missing at $SIDECAR"; exit 1; }
    [ -n "$CLAUDE" ] || echo "⚠ claude not found in the usual spots — set TOKENTAB_CLAUDE_BIN if live can't resolve it"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    gen_plist > "$PLIST"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
    echo "✓ live helper installed — refreshing every ${INTERVAL}s"
    echo "  reads:  $SIDECAR"
    echo "  log:    $LOG"
    echo "  remove: $0 uninstall"
    ;;
  *)
    echo "usage: $0 [install|uninstall|print]"; exit 2
    ;;
esac
