#!/bin/bash
# Puts a new YTGlass.dylib into the YouTube app already installed in the Simulator, without reinstalling it, so the
# app keeps its data and its sign-in (a reinstall signs the app anew, and it can no longer read its keychain).
# Usage: Scripts/sim-update-dylib.sh <YTGlass.dylib> [simulator UDID]
set -euo pipefail
DYLIB="$1"; UDID="${2:-booted}"
APP=$(xcrun simctl get_app_container "$UDID" com.google.ios.youtube app)
TMP=$(mktemp -d)
cp "$DYLIB" "$TMP/YTGlass.dylib"
read -r minos sdk < <(otool -l "$TMP/YTGlass.dylib" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{m=$2} b&&/sdk/{print m, $2; exit}')
vtool -set-build-version iossim "$minos" "$sdk" -replace -output "$TMP/YTGlass.sim" "$TMP/YTGlass.dylib" 2>/dev/null
codesign -f -s - "$TMP/YTGlass.sim" 2>/dev/null
xcrun simctl terminate "$UDID" com.google.ios.youtube 2>/dev/null || true
cp "$TMP/YTGlass.sim" "$APP/Frameworks/YTGlass.dylib"
rm -rf "$TMP"
echo "$APP/Frameworks/YTGlass.dylib"
