#!/usr/bin/env bash
# Token Tab — assemble the sandboxed Token Tab.app from the SwiftPM build.
#
# Produces a real .app bundle, code-signed with the App Sandbox entitlements (no
# network). By default it ad-hoc signs for local use — no Apple Developer account
# needed. For a distributable build, Scripts/package-app.sh drives this script with the
# release knobs below, then notarizes.
#
# Usage:  app/Scripts/build-app.sh [debug|release]   (default: release)
#         open "app/Token Tab.app"
#
# Release knobs (all optional, set as env vars):
#   CODESIGN_IDENTITY   signing identity (default "-" = ad-hoc). A real identity
#                       ("Developer ID Application: …") also turns on the hardened
#                       runtime + secure timestamp that notarization requires.
#   ARCHS               space-separated arch list, e.g. "arm64 x86_64" for a
#                       universal binary (default: host arch only).
#   VERSION             stamp CFBundleShortVersionString in the bundled Info.plist
#                       (the checked-in plist is not touched). CFBundleVersion is
#                       stamped with the git commit count for monotonicity.
set -euo pipefail

CONFIG="${1:-release}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # app/
APP="$HERE/Token Tab.app"
BIN_NAME="TokenTab"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

ARCH_FLAGS=()
for a in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$a"); done

echo "▸ Building ($CONFIG${ARCHS:+, ${ARCHS}})…"
( cd "$HERE" && swift build -c "$CONFIG" ${ARCH_FLAGS+"${ARCH_FLAGS[@]}"} )
BIN_DIR="$(cd "$HERE" && swift build -c "$CONFIG" ${ARCH_FLAGS+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/$BIN_NAME"
HELPER_NAME="TokenTabLiveHelper"
HELPER_BIN="$BIN_DIR/$HELPER_NAME"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }
[ -x "$HELPER_BIN" ] || { echo "✗ helper binary not found at $HELPER_BIN"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
# The live-% helper + its LaunchAgent plist. The helper is sandboxed too (macOS ≥14.2
# rejects unsandboxed agents from a sandboxed app), just with network.client + scoped
# ~/.claude access so it can exec `claude`. It is never spawned by the app — launchd
# runs it, only after the user flips "Live %" on (SMAppService → Login Items).
cp "$HELPER_BIN" "$APP/Contents/MacOS/$HELPER_NAME"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$HERE/Bundle/com.tokentab.liveagent.plist" "$APP/Contents/Library/LaunchAgents/"
# The bundled hero font (Martian Mono, OFL). SwiftPM's Bundle.module layout doesn't fit an
# .app, so ship the raw font asset under Resources/Fonts and let FontLoader find it via
# Bundle.main inside the sandboxed app (see FontLoader.swift). Keep the OFL notice outside
# app/Sources so the source audit stays URL-clean.
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$HERE/Sources/TokenTab/Resources/Fonts/MartianMono.ttf" "$APP/Contents/Resources/Fonts/"
cp "$HERE/Resources/Fonts/OFL.txt"                          "$APP/Contents/Resources/Fonts/"
cp "$HERE/Bundle/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  BUILD_NUM="$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 1)"
  echo "▸ Stamping version $VERSION (build $BUILD_NUM)…"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                          -c "Set :CFBundleVersion $BUILD_NUM" \
                          "$APP/Contents/Info.plist"
fi
# App icon (a gitignored build artifact) — generate from the gauge design if absent.
[ -f "$HERE/Bundle/AppIcon.icns" ] || { echo "▸ Generating AppIcon.icns…"; bash "$HERE/Scripts/make-icon.sh"; }
cp "$HERE/Bundle/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign inside-out: the nested helper first, then the bundle. Since macOS 14.2 a
# sandboxed app may only register agents that are ALSO sandboxed, so the helper gets
# its own sandbox — opened exactly as far as its job needs (network.client for the
# `claude /usage` call, ~/.claude read-write; see TokenTabLiveHelper.entitlements).
# The app keeps its stricter App Sandbox: NO network. Two postures, one bundle.
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  echo "▸ Signing (ad-hoc): helper (sandbox + network.client), then app (sandbox, no network)…"
  codesign --force --sign - \
    --identifier com.tokentab.TokenTabLiveHelper \
    --entitlements "$HERE/Bundle/TokenTabLiveHelper.entitlements" \
    --timestamp=none \
    "$APP/Contents/MacOS/$HELPER_NAME"
  codesign --force --sign - \
    --entitlements "$HERE/Bundle/TokenTab.entitlements" \
    --timestamp=none \
    "$APP"
else
  # Distribution: hardened runtime + secure timestamp are notarization requirements —
  # for every Mach-O in the bundle, the helper included.
  echo "▸ Signing ($CODESIGN_IDENTITY): helper (sandbox + network.client), then app (sandbox, no network; hardened runtime)…"
  codesign --force --sign "$CODESIGN_IDENTITY" \
    --identifier com.tokentab.TokenTabLiveHelper \
    --entitlements "$HERE/Bundle/TokenTabLiveHelper.entitlements" \
    --options runtime \
    --timestamp \
    "$APP/Contents/MacOS/$HELPER_NAME"
  codesign --force --sign "$CODESIGN_IDENTITY" \
    --entitlements "$HERE/Bundle/TokenTab.entitlements" \
    --options runtime \
    --timestamp \
    "$APP"
fi

echo "▸ Verifying entitlements (should show app-sandbox, NO network):"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -Ei 'sandbox|network|user-selected' || true
echo "▸ Helper entitlements (sandboxed too, network.client is its ONE extra power):"
codesign -d --entitlements :- "$APP/Contents/MacOS/$HELPER_NAME" 2>/dev/null | grep -Ei 'sandbox|network' || true

echo "✓ Built: $APP"
echo "  Run:   open \"$APP\""
