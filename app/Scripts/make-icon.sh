#!/usr/bin/env bash
# Token Tab — build app/Bundle/AppIcon.icns from the gauge design.
#
# Renders the iconset with make-icon.swift (Core Graphics, no external rasterizer),
# packs it with iconutil, and drops AppIcon.icns into app/Bundle/ where build-app.sh
# picks it up. Re-run any time the gauge mark changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # app/
ICONSET="$(mktemp -d)/AppIcon.iconset"
OUT="$HERE/Bundle/AppIcon.icns"
mkdir -p "$ICONSET"

echo "▸ Rendering iconset…"
swift "$HERE/Scripts/make-icon.swift" "$ICONSET"

echo "▸ Packing icns…"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "✓ Wrote $OUT"
