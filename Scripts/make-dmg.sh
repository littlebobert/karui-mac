#!/usr/bin/env bash
# Builds the disk image people download from the website: a Finder window with
# Karui, an arrow and Applications, drawn by Packaging/dmg-background.swift.
# Sparkle doesn't use it; updates stay on the zip (see notarize-release.sh).
#
#   ./Scripts/make-dmg.sh <Karui.app> <output.dmg>
#
# Signs the image with Developer ID when CODESIGN_IDENTITY is set (the release
# scripts set it); notarize-release.sh notarizes and staples it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: make-dmg.sh <Karui.app> <output.dmg>}"
OUTPUT="${2:?usage: make-dmg.sh <Karui.app> <output.dmg>}"
VOLUME_NAME="${DMG_VOLUME_NAME:-Karui}"
DMGBUILD_VERSION="1.6.5"
VENV="$ROOT_DIR/.build/dmg-venv"
WORK="$ROOT_DIR/.build/dmg"

[[ -d "$APP" ]] || { echo "error: app not found: $APP" >&2; exit 1; }

# dmgbuild writes the window's layout (.DS_Store) itself, so no Finder scripting
# or Automation permission is needed.
if [[ "$("$VENV/bin/dmgbuild" --version 2>/dev/null || true)" != *"$DMGBUILD_VERSION"* ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
fi

rm -rf "$WORK"
mkdir -p "$WORK"
swift "$ROOT_DIR/Packaging/dmg-background.swift" "$WORK/background.png" "$WORK/background@2x.png"
# One TIFF with both sizes, so the window is sharp on Retina displays.
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
"$VENV/bin/dmgbuild" \
  -s "$ROOT_DIR/Packaging/dmg-settings.py" \
  -D app="$APP" \
  -D background="$WORK/background.tiff" \
  "$VOLUME_NAME" "$OUTPUT"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$OUTPUT"
  codesign --verify --strict --verbose=2 "$OUTPUT"
fi

printf '%s\n' "$OUTPUT"
