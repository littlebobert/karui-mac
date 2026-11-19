#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-$ROOT_DIR/.env.release}"
if [[ -f "$RELEASE_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$RELEASE_ENV_FILE"
  set +a
fi

DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/.build/ReleaseDerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/Karui.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-sasu-notary}"
OUTPUT_DIR="$ROOT_DIR/.build/releases"
NOTARY_ZIP="$OUTPUT_DIR/Karui-notary.zip"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Justin Henry Garcia (XDWKSAH7W3)}"

[[ -d "$APP" ]] || "$ROOT_DIR/Scripts/build-release.sh" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
# The zip is what Sparkle installs (the appcast points at it); the disk image is
# what people download from the website. Both carry the same stapled app.
RELEASE_ZIP="$OUTPUT_DIR/Karui-$VERSION-mac.zip"
RELEASE_DMG="$OUTPUT_DIR/Karui-$VERSION-mac.dmg"
mkdir -p "$OUTPUT_DIR"
rm -f "$NOTARY_ZIP" "$RELEASE_ZIP" "$RELEASE_DMG"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null
/usr/bin/ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"

/usr/bin/ditto --noextattr --norsrc -c -k --keepParent "$APP" "$RELEASE_ZIP"
VERIFY_DIR="$(mktemp -d "$OUTPUT_DIR/verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
/usr/bin/unzip -q "$RELEASE_ZIP" -d "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/Karui.app"
xcrun stapler validate "$VERIFY_DIR/Karui.app"
spctl --assess --type execute --verbose=4 "$VERIFY_DIR/Karui.app"
shasum -a 256 "$RELEASE_ZIP" > "$RELEASE_ZIP.sha256"

# The disk image holds the app stapled above, so it opens offline too; the image
# itself is signed, notarized and stapled so Gatekeeper accepts it when opened.
CODESIGN_IDENTITY="$IDENTITY" "$ROOT_DIR/Scripts/make-dmg.sh" "$APP" "$RELEASE_DMG" >/dev/null
xcrun notarytool submit "$RELEASE_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$RELEASE_DMG"
"$ROOT_DIR/Scripts/verify-dmg.sh" "$RELEASE_DMG"
shasum -a 256 "$RELEASE_DMG" > "$RELEASE_DMG.sha256"

printf '%s\n' "$RELEASE_ZIP"
printf '%s\n' "$RELEASE_DMG"
