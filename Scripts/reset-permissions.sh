#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.justin.henry.karui.mac"

/usr/bin/pkill -x Karui 2>/dev/null || true
/usr/bin/tccutil reset SystemPolicyAllFiles "$BUNDLE_ID"
/usr/bin/defaults delete "$BUNDLE_ID" 2>/dev/null || true

print "Reset Karui's Full Disk Access and preferences for $BUNDLE_ID"
