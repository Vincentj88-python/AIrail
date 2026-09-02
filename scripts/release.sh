#!/bin/bash
# Build a signed, self-contained AIrail.app and wrap it in a DMG for release.
#
# AIrail isn't sandboxed (it reads other tools' sign-ins), so it can't ship on
# the App Store. Until there's an Apple Developer ID for notarization, releases
# are signed with a stable self-signed certificate ("AIrail Dev"). Users get a
# one-time Gatekeeper prompt on first launch (right-click → Open, or System
# Settings › Privacy & Security › Open Anyway); signing with the SAME cert every
# release keeps the macOS Keychain "Always Allow" sticking across versions.
#
# When a Developer ID is available: set SIGN_IDENTITY to it, add
# --options runtime to the build, and add a `notarytool submit … && stapler`
# step after the DMG is built. Nothing else changes.
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="AIrail"
SIGN_IDENTITY="${AIRAIL_SIGN_IDENTITY:-AIrail Dev}"
APP_NAME="AIrail"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)"
BUILD_DIR="$(mktemp -d)"
OUT_DIR="$PWD/dist"
DMG="$OUT_DIR/${APP_NAME}-${VERSION}.dmg"

echo "▸ Building $APP_NAME $VERSION (signed: $SIGN_IDENTITY)"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "✗ build produced no app at $APP"; exit 1; }

echo "▸ Verifying signature"
codesign --verify --strict --verbose=1 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|Identifier" | sed 's/^/    /'

echo "▸ Staging DMG contents"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating $DMG"
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format ULFO \
  -ov "$DMG" >/dev/null

rm -rf "$BUILD_DIR"
echo "✓ $DMG"
echo "  $(du -h "$DMG" | cut -f1)  —  attach to the GitHub release, or open it to install."
