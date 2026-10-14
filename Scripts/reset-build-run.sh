#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUNDLE_ID="com.justin.henry.karui.mac"
DERIVED_DATA="$ROOT/.build/DerivedData"
IDENTITY="Developer ID Application: Justin Henry Garcia (XDWKSAH7W3)"
RESET=1

if [[ "${1:-}" == "--no-reset" ]]; then
  RESET=0
elif [[ $# -gt 0 ]]; then
  print -u2 "Usage: $0 [--no-reset]"
  exit 64
fi

if (( RESET )); then
  "$ROOT/Scripts/reset-permissions.sh"
else
  /usr/bin/pkill -x Karui 2>/dev/null || true
fi

cd "$ROOT"
/opt/homebrew/bin/xcodegen generate --quiet
/bin/rm -rf "$DERIVED_DATA"
/usr/bin/xcodebuild \
  -project KaruiMac.xcodeproj \
  -scheme KaruiMac \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM=XDWKSAH7W3 \
  build

APP="$DERIVED_DATA/Build/Products/Debug/Karui.app"
# Xcode's generated entitlements add the application and team identifiers from the
# provisioning profile, which CloudKit needs; the source file alone lacks them.
ENTITLEMENTS="$DERIVED_DATA/Build/Intermediates.noindex/KaruiMac.build/Debug/KaruiMac.build/Karui.app.xcent"
[[ -f "$ENTITLEMENTS" ]] || ENTITLEMENTS="$ROOT/KaruiMac/Resources/KaruiMac.entitlements"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]]
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
/usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.application-identifier" || { print -u2 "error: application-identifier entitlement missing after signing"; exit 1; }
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/open "$APP"
print "Launched $APP"
