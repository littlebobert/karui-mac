#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/.build/ReleaseDerivedData}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Justin Henry Garcia (XDWKSAH7W3)}"
TEAM_ID="${DEVELOPMENT_TEAM:-XDWKSAH7W3}"
APP="$DERIVED_DATA/Build/Products/Release/Karui.app"

cd "$ROOT_DIR"
command -v xcodegen >/dev/null || { echo "error: xcodegen is required" >&2; exit 1; }
IDENTITIES="$(security find-identity -v -p codesigning)"
grep -Fq "$IDENTITY" <<<"$IDENTITIES" || {
  echo "error: expected signing identity not found: $IDENTITY" >&2
  exit 1
}

xcodegen generate
xcodebuild \
  -project KaruiMac.xcodeproj \
  -scheme KaruiMac \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean build

[[ -d "$APP" ]] || { echo "error: release app not found: $APP" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "com.justin.henry.karui.mac" ]] || {
  echo "error: unexpected bundle identifier" >&2; exit 1
}
[[ "$(lipo -archs "$APP/Contents/MacOS/Karui")" == "arm64" ]] || {
  echo "error: release executable must be arm64-only" >&2; exit 1
}

# Xcode's generated entitlements add the application and team identifiers from the
# provisioning profile, which CloudKit needs; the source file alone lacks them.
ENTITLEMENTS="$DERIVED_DATA/Build/Intermediates.noindex/KaruiMac.build/Release/KaruiMac.build/Karui.app.xcent"
[[ -f "$ENTITLEMENTS" ]] || { echo "error: generated entitlements not found: $ENTITLEMENTS" >&2; exit 1; }
codesign --force --deep --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
  --options runtime --timestamp "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -Fq "get-task-allow"; then
  echo "error: release app contains get-task-allow" >&2
  exit 1
fi
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.application-identifier" || {
  echo "error: application-identifier entitlement missing after signing" >&2; exit 1
}
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || { echo "error: provisioning profile not embedded" >&2; exit 1; }
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$SIGNATURE_DETAILS" || {
  echo "error: release app was not signed by team $TEAM_ID" >&2
  exit 1
}

printf '%s\n' "$APP"
