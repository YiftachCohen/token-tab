#!/usr/bin/env bash
# Token Tab — assemble the sandboxed Token Tab.app from the SwiftPM build.
#
# Produces a real .app bundle, ad-hoc code-signed with the App Sandbox entitlements (no
# network). Local-only: no Apple Developer account needed. Notarization (for handing the
# app to someone else) is a later step — see the repo README.
#
# Usage:  app/Scripts/build-app.sh [debug|release]   (default: release)
#         open "app/Token Tab.app"
set -euo pipefail

CONFIG="${1:-release}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # app/
APP="$HERE/Token Tab.app"
BIN_NAME="TokenTab"

echo "▸ Building ($CONFIG)…"
( cd "$HERE" && swift build -c "$CONFIG" )
BIN="$(cd "$HERE" && swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
# The bundled hero font (Martian Mono, OFL). SwiftPM's Bundle.module layout doesn't fit an
# .app, so ship the raw asset under Resources/Fonts and let FontLoader find it via
# Bundle.main inside the sandboxed app (see FontLoader.swift).
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$HERE/Sources/TokenTab/Resources/Fonts/MartianMono.ttf" "$APP/Contents/Resources/Fonts/"
cp "$HERE/Sources/TokenTab/Resources/Fonts/OFL.txt"         "$APP/Contents/Resources/Fonts/"
cp "$HERE/Bundle/Info.plist" "$APP/Contents/Info.plist"
# App icon (a gitignored build artifact) — generate from the gauge design if absent.
[ -f "$HERE/Bundle/AppIcon.icns" ] || { echo "▸ Generating AppIcon.icns…"; bash "$HERE/Scripts/make-icon.sh"; }
cp "$HERE/Bundle/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc) with App Sandbox entitlements…"
codesign --force --sign - \
  --entitlements "$HERE/Bundle/TokenTab.entitlements" \
  --timestamp=none \
  "$APP"

echo "▸ Verifying entitlements (should show app-sandbox, NO network):"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -Ei 'sandbox|network|user-selected' || true

echo "✓ Built: $APP"
echo "  Run:   open \"$APP\""
