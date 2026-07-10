#!/usr/bin/env bash
set -euo pipefail

# Build a drag-and-drop DMG installer for LocalFlow.app.
#
# Usage: ./scripts/build-dmg.sh path/to/LocalFlow.app [output-dir]

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 path/to/LocalFlow.app [output-dir]" >&2
  exit 1
fi

APP_PATH="$1"
OUTPUT_DIR="${2:-.}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app bundle not found at $APP_PATH" >&2
  exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "Error: create-dmg not found. Install it with: brew install create-dmg" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

VOL_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"

if timeout 120 create-dmg \
  --volname "LocalFlow" \
  --volicon "$VOL_ICON" \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "LocalFlow.app" 180 170 \
  --app-drop-link 480 170 \
  "$OUTPUT_DIR/LocalFlow.dmg" \
  "$APP_PATH"; then
  exit 0
else
  echo "create-dmg's Finder-prettifying step timed out or failed (no GUI session available, or another error); retrying without it -- the resulting DMG will work but won't have custom icon positions/window size" >&2

  while IFS= read -r vol; do
    hdiutil detach -force "$vol" || true
  done < <(hdiutil info | grep -oE "/Volumes/(LocalFlow|dmg\.)[^[:space:]]*")

  rm -f "$OUTPUT_DIR/LocalFlow.dmg"

  create-dmg \
    --volname "LocalFlow" \
    --volicon "$VOL_ICON" \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "LocalFlow.app" 180 170 \
    --app-drop-link 480 170 \
    --skip-jenkins \
    "$OUTPUT_DIR/LocalFlow.dmg" \
    "$APP_PATH"
fi
