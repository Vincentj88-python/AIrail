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

# The MacBook display's size in points, for the regions below.
WIDTH=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F'[: x]+' '/Resolution/ {print $3; exit}')
HEIGHT=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F'[: x]+' '/Resolution/ {print $4; exit}')
WIDTH=${WIDTH:-1512}; HEIGHT=${HEIGHT:-982}
# Retina reports pixels; the rail lives in points (half of that).
if [ "$WIDTH" -gt 2000 ]; then WIDTH=$((WIDTH / 2)); HEIGHT=$((HEIGHT / 2)); fi
MID_Y=$((HEIGHT / 2))

shoot() { # name, region "x,y,w,h", launch args…
  local name="$1"; local region="$2"; shift 2
  echo "▸ $name"
  open -n "$APP" --args -connectedAccounts '()' "$@"
  sleep 3
  screencapture -x -R "$region" "$OUT/$name.png"
  osascript -e "quit app \"$SCHEME\"" || true
  sleep 1
}

# 1. Idle: the hairline on the left edge, mid-screen.
shoot "01-collapsed-hairline" "0,$((MID_Y - 120)),200,240" -railPosition left
# 2. Hover: the expanded rail with marks and captions (--expanded opens it).
shoot "02-expanded-rail" "0,$((MID_Y - 220)),260,440" -railPosition left --expanded
# 3. The card: the HUD for Claude at a high demo percent (--demo raises the peak).
shoot "03-card" "0,$((MID_Y - 380)),620,760" -railPosition left --expanded --overlay=claude --demo=91
# 4. Top: the island grown out of the notch (or the top centre), with the headroom caption.
shoot "04-island" "$((WIDTH / 2 - 260)),0,520,140" -railPosition top --expanded

rm -rf "$BUILD_DIR"
if [ -d /Applications/$SCHEME.app ]; then
  echo "▸ Relaunching /Applications/$SCHEME.app"
  open -a "/Applications/$SCHEME.app"
fi
echo "✓ $OUT"
ls -1 "$OUT"
