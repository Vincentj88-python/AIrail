#!/bin/bash
# Build a signed, self-contained AIrail.app and wrap it in a DMG for release.
#
# AIrail isn't sandboxed (it reads other tools' sign-ins), so it can't ship on
# the App Store. Until there's an Apple Developer ID for notarization, releases
# are signed with a stable self-signed certificate ("AIrail Dev"). Users get a
# one-time Gatekeeper prompt on first launch (System Settings › Privacy &
# Security › Open Anyway); signing with the SAME cert every release keeps the
# macOS Keychain "Always Allow" sticking across versions.
#
# The build itself is only ad-hoc signed. The one real signature is applied
# here afterwards: hardened runtime, a secure timestamp, and no entitlements
# at all. Xcode injects `com.apple.security.get-task-allow` for any
# non-distribution identity (self-signed included), which let any same-user
# process attach a debugger to the shipped 0.2.0; a re-sign without
# --entitlements carries none of that over. The timestamp (a public RFC 3161
# request to Apple, no account needed) keeps the signature valid after the
# certificate itself expires. The script refuses to package an app that fails
# any of the three checks below.
#
# When a Developer ID is available: set AIRAIL_SIGN_IDENTITY to it and add a
# `notarytool submit … && stapler` step after the DMG is built. Nothing else
# changes — the signing step below is already the one notarization wants.
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="AIrail"
SIGN_IDENTITY="${AIRAIL_SIGN_IDENTITY:-AIrail Dev}"
APP_NAME="AIrail"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)"
COMMIT="$(git describe --always --dirty --exclude='*' 2>/dev/null || true)"
BUILD_DIR="$(mktemp -d)"
OUT_DIR="$PWD/dist"
DMG="$OUT_DIR/${APP_NAME}-${VERSION}.dmg"

echo "▸ Building $APP_NAME $VERSION${COMMIT:+ ($COMMIT)}"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "✗ build produced no app at $APP"; exit 1; }

# GENERATE_INFOPLIST_FILE ignores custom INFOPLIST_KEY_* settings, so the
# commit goes in here, before signing; Settings › General reads it back.
# Outside a git checkout there is no commit to stamp, and the key is left out.
if [ -n "$COMMIT" ]; then
  /usr/libexec/PlistBuddy -c "Add :AIrailCommit string $COMMIT" "$APP/Contents/Info.plist"
fi

echo "▸ Signing with $SIGN_IDENTITY (hardened runtime, timestamped, no entitlements)"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"

echo "▸ Verifying signature"
codesign --verify --strict --verbose=1 "$APP"
DETAILS="$(codesign -dvv "$APP" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>&1)"
grep -E "^(Authority|Identifier|CodeDirectory|Timestamp)" <<< "$DETAILS" | sed 's/^/    /'
if grep -q "get-task-allow" <<< "$ENTITLEMENTS"; then
  echo "✗ get-task-allow survived the re-sign — the app would be debuggable"; exit 1
fi
grep -qE '^CodeDirectory .*flags=0x10000\(runtime\)' <<< "$DETAILS" \
  || { echo "✗ hardened runtime is not set (expected flags=0x10000(runtime))"; exit 1; }
grep -q '^Timestamp=' <<< "$DETAILS" \
  || { echo "✗ the signature carries no secure timestamp"; exit 1; }

# With a Developer ID and a stored notarytool profile, Apple checks the app
# before it is packaged, and the ticket is stapled so it opens offline:
#   xcrun notarytool store-credentials AIrail --apple-id … --team-id … --password …
#   AIRAIL_SIGN_IDENTITY="Developer ID Application: …" AIRAIL_NOTARY_PROFILE=AIrail ./scripts/release.sh
if [[ "$SIGN_IDENTITY" == Developer\ ID* && -n "${AIRAIL_NOTARY_PROFILE:-}" ]]; then
  echo "▸ Notarizing the app with profile $AIRAIL_NOTARY_PROFILE"
  ZIP="$BUILD_DIR/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$AIRAIL_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

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

if [[ "$SIGN_IDENTITY" == Developer\ ID* && -n "${AIRAIL_NOTARY_PROFILE:-}" ]]; then
  echo "▸ Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$AIRAIL_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

# A Homebrew tap checkout in AIRAIL_TAP gets its cask rewritten for this
# version; commit and push it after the GitHub release exists.
if [ -n "${AIRAIL_TAP:-}" ]; then
  mkdir -p "$AIRAIL_TAP/Casks"
  cat > "$AIRAIL_TAP/Casks/airail.rb" <<CASK
cask "airail" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/Vincentj88-python/AIrail/releases/download/v#{version}/AIrail-#{version}.dmg"
  name "AIrail"
  desc "Screen-edge rail that tracks usage of the AI coding tools you run"
  homepage "https://github.com/Vincentj88-python/AIrail"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "AIrail.app"

  uninstall quit: "com.codeandvin.airail"

  zap trash: [
    "~/Library/Application Support/AIrail",
    "~/Library/Preferences/com.codeandvin.airail.plist",
    "~/Library/Logs/DiagnosticReports/AIrail*",
  ]
end
CASK
  echo "▸ Wrote $AIRAIL_TAP/Casks/airail.rb"
fi

rm -rf "$BUILD_DIR"
echo "✓ $DMG"
echo "  $(du -h "$DMG" | cut -f1)  —  sha256 $SHA"
echo "  gh release create v$VERSION \"$DMG\" --title \"v$VERSION\" --notes-file NOTES.md"
