#!/bin/bash
# Re-shoot the README captures from a real build, so text and pictures never
# drift apart. Every capture shows demo data (the `demo` badge is real) —
# nothing is read from any sign-in and no usage endpoint is asked, because the
# accounts list and the placement are forced through the defaults argument
# domain, which persists nothing:
#
#   -connectedAccounts '()'   no accounts → the demo rail
#   -railPosition left|top    where to put it
#
# Needs: Screen Recording permission for the Terminal running this (one-time
# prompt; without it captures show only the wallpaper), and the built-in
# display as the main display. Regions are in points on that display; adjust
# them once for your desk. Output goes to screenshots/.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="$PWD/screenshots"
BUILD_DIR="$(mktemp -d)"
SCHEME="AIrail"
mkdir -p "$OUT"

echo "▸ Building a Debug $SCHEME"
xcodebuild -scheme "$SCHEME" -configuration Debug -derivedDataPath "$BUILD_DIR" build >/dev/null
APP="$BUILD_DIR/Build/Products/Debug/$SCHEME.app"
[ -d "$APP" ] || { echo "✗ no app at $APP"; exit 1; }

if pgrep -xq "$SCHEME"; then
  echo "▸ Quitting the running $SCHEME"
  osascript -e "quit app \"$SCHEME\"" || true
  sleep 1
fi

# The built-in display: its index for screencapture, its name for the rail
# setting, its size in points and its scale for the crop.
DISPLAY_INFO="$(swift - <<'SWIFT' 2>/dev/null | grep '|' | head -1
import AppKit
for (index, screen) in NSScreen.screens.enumerated() {
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    if CGDisplayIsBuiltin(id) != 0 {
        print("\(index + 1)|\(screen.localizedName)|\(Int(screen.frame.width))|\(Int(screen.frame.height))|\(Int(screen.backingScaleFactor))")
    }
}
SWIFT
)"
[ -n "$DISPLAY_INFO" ] || { echo "✗ no built-in display attached"; exit 1; }
IFS='|' read -r DISPLAY_INDEX DISPLAY_NAME WIDTH HEIGHT SCALE <<< "$DISPLAY_INFO"
echo "▸ Shooting on display $DISPLAY_INDEX ($DISPLAY_NAME, ${WIDTH}×${HEIGHT} @${SCALE}x)"
MID_Y=$((HEIGHT / 2))
SHOT="$BUILD_DIR/shot.png"

shoot() { # name  x y w h (points on the built-in display)  launch args…
  local name="$1" x="$2" y="$3" w="$4" h="$5"; shift 5
  echo "▸ $name"
  open -n "$APP" --args -connectedAccounts '()' -railDisplay "$DISPLAY_NAME" "$@"
  sleep 4
  screencapture -x -D "$DISPLAY_INDEX" "$SHOT"
  sips --cropOffset $((y * SCALE)) $((x * SCALE)) --cropToHeightWidth $((h * SCALE)) $((w * SCALE)) "$SHOT" --out "$OUT/$name.png" >/dev/null
  osascript -e "quit app \"$SCHEME\"" || true
  sleep 1
}

# 1. Idle: the hairline on the left edge, mid-screen.
shoot "01-collapsed-hairline" 0 $((MID_Y - 120)) 200 240 -railPosition left
# 2. Hover: the expanded rail with marks and captions (--expanded opens it).
shoot "02-expanded-rail" 0 $((MID_Y - 270)) 260 540 -railPosition left --expanded
# 3. The card: the HUD for the busiest demo account at a high figure (--demo raises it).
shoot "03-card" 0 30 600 $((HEIGHT - 60)) -railPosition left --expanded --overlay=cursor --demo=91
# 4. Top: the island grown out of the notch, with the headroom caption.
shoot "04-island" $((WIDTH / 2 - 280)) 0 560 125 -railPosition top --expanded

rm -rf "$BUILD_DIR"
if [ -d /Applications/$SCHEME.app ]; then
  echo "▸ Relaunching /Applications/$SCHEME.app"
  open -a "/Applications/$SCHEME.app"
fi
echo "✓ $OUT"
ls -1 "$OUT"
