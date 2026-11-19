#!/usr/bin/env bash
# Checks a release disk image the way a downloader's Mac will see it: the image's
# own signature and notarization ticket, then the app inside it, and the window's
# Applications link and layout.
#
#   ./Scripts/verify-dmg.sh <Karui.dmg> [expected version]
set -euo pipefail

DMG="${1:?usage: verify-dmg.sh <Karui.dmg> [expected version]}"
EXPECTED_VERSION="${2:-}"

codesign --verify --strict --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

MOUNT="$(mktemp -d /tmp/karui-dmg.XXXXXX)"
detach() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap detach EXIT
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet

APP="$MOUNT/Karui.app"
[[ -d "$APP" ]] || { echo "error: Karui.app is not in the disk image" >&2; exit 1; }
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || { echo "error: the Applications link is missing" >&2; exit 1; }
[[ -f "$MOUNT/.DS_Store" ]] || { echo "error: the window layout (.DS_Store) is missing" >&2; exit 1; }
[[ -f "$MOUNT/.background.tiff" ]] || { echo "error: the window background is missing" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
if [[ -n "$EXPECTED_VERSION" ]]; then
  ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  [[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || {
    echo "error: the disk image holds Karui $ACTUAL_VERSION, not $EXPECTED_VERSION" >&2; exit 1
  }
fi
echo "Disk image verified: $DMG"
