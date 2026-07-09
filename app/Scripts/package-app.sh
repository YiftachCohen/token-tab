#!/usr/bin/env bash
# Token Tab — package a distributable, notarized Token Tab.app.
#
# One command from source to a zip you can hand to anyone:
#   build (universal) → Developer ID sign (hardened runtime) → zip → notarize →
#   staple → re-zip → sha256. Output lands in dist/.
#
# Signing happens locally on purpose: the Developer ID private key never leaves this
# machine, which matches the project's trust model (see RELEASING.md).
#
# Usage:  app/Scripts/package-app.sh [version] [--skip-notarize] [--dmg]
#           version   defaults to the version field in package.json
#           --dmg     also produce a drag-to-Applications DMG (signed, notarized,
#                     stapled like the zip — a second notary round-trip)
#
# Env:
#   CODESIGN_IDENTITY         override the auto-detected "Developer ID Application" cert
#   TOKENTAB_NOTARY_PROFILE   notarytool keychain profile (default: token-tab-notary)
#
# One-time notarization setup (needs an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials token-tab-notary \
#     --apple-id you@example.com --team-id TU799P6CL2
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # app/
ROOT="$(cd "$HERE/.." && pwd)"
APP="$HERE/Token Tab.app"
DIST="$ROOT/dist"
PROFILE="${TOKENTAB_NOTARY_PROFILE:-token-tab-notary}"

VERSION=""
SKIP_NOTARIZE=0
MAKE_DMG=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --dmg) MAKE_DMG=1 ;;
    *) VERSION="$arg" ;;
  esac
done
[ -n "$VERSION" ] || VERSION="$(node -p 'require(process.argv[1]).version' "$ROOT/package.json")"

# Resolve the signing identity: an explicit env wins, else the first Developer ID
# Application cert in the keychain. Distribution needs a real identity — ad-hoc
# builds are what build-app.sh already does.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -z "$CODESIGN_IDENTITY" ]; then
  echo "✗ No 'Developer ID Application' certificate found in the keychain." >&2
  echo "  Distribution requires one (Apple Developer Program). For a local build," >&2
  echo "  use app/Scripts/build-app.sh instead." >&2
  exit 1
fi

echo "▸ Packaging Token Tab $VERSION"
echo "  identity: $CODESIGN_IDENTITY"

# 1. Build + sign the universal bundle (build-app.sh does assemble/stamp/sign).
CODESIGN_IDENTITY="$CODESIGN_IDENTITY" ARCHS="arm64 x86_64" VERSION="$VERSION" \
  bash "$HERE/Scripts/build-app.sh" release

echo "▸ Verifying signature…"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/TokenTab"
lipo -info "$APP/Contents/MacOS/TokenTabLiveHelper"

mkdir -p "$DIST"
ZIP="$DIST/Token-Tab-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"

# 2. Notarize. notarytool takes the zip; the staple goes on the .app, so re-zip after.
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  echo "▸ Skipping notarization (--skip-notarize) — this zip will hit Gatekeeper on other Macs."
else
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "✗ No notary credentials under keychain profile '$PROFILE'." >&2
    echo "  One-time setup (app-specific password from appleid.apple.com):" >&2
    echo "    xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "      --apple-id <your-apple-id> --team-id <your-team-id>" >&2
    echo "  Or re-run with --skip-notarize for an un-notarized zip." >&2
    exit 1
  fi
  echo "▸ Notarizing (this waits on Apple, typically 1–5 min)…"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  echo "▸ Stapling ticket…"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# 3. Final zip + checksum. ditto preserves the bundle metadata Finder expects.
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

# 4. Optional DMG: the stapled app + an /Applications symlink on a compressed image.
#    The DMG is signed and notarized in its own right (a container needs its own
#    ticket for a staple; the app inside already carries one either way).
if [ "$MAKE_DMG" -eq 1 ]; then
  DMG="$DIST/Token-Tab-$VERSION.dmg"
  rm -f "$DMG" "$DMG.sha256"
  echo "▸ Building DMG…"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Token Tab" -srcfolder "$STAGE" -format UDZO -ov -quiet "$DMG"
  rm -rf "$STAGE"
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
  if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    echo "▸ Notarizing DMG (second round-trip)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  (cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
fi

echo "▸ Gatekeeper assessment:"
spctl -a -vv "$APP" || [ "$SKIP_NOTARIZE" -eq 1 ]   # un-notarized builds fail this; that's expected

echo "✓ Artifacts:"
(cd "$DIST" && cat "Token-Tab-$VERSION".*.sha256)
