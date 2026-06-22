#!/usr/bin/env bash
# Token Tab — regenerate the web/README branding assets from the gauge mark.
#
# Renders the favicon sizes and the README hero with make-icon.swift (Core Graphics),
# then branding.py packs favicon.ico and draws the wordmark lockup (light + dark ink).
# Outputs land in app/Branding/ and are committed (unlike AppIcon.icns, which is a build
# artifact). The .icns itself comes from make-icon.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # app/
BRAND="$HERE/Branding"
mkdir -p "$BRAND"

echo "▸ Rendering favicons + apple-touch-icon…"
swift "$HERE/Scripts/make-icon.swift" "$BRAND" favicon

echo "▸ Rendering README hero…"
swift "$HERE/Scripts/make-icon.swift" "$BRAND" hero

echo "▸ Packing favicon.ico + wordmark…"
python3 "$HERE/Scripts/branding.py" "$BRAND"

echo "✓ Branding assets written to $BRAND"
