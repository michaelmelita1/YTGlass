#!/bin/bash
# Turns an injected YouTube IPA into an app the iOS Simulator runs (Apple Silicon only): every arm64 binary is relabelled
# as an iOS Simulator binary (vtool), the extensions are dropped, and everything is signed ad hoc.
# Usage: Scripts/make-sim-app.sh <injected.ipa> <output folder>  → <output folder>/Payload/YouTube.app
set -euo pipefail
IPA="$1"; OUT="$2"
rm -rf "$OUT"; mkdir -p "$OUT"
unzip -q "$IPA" -d "$OUT"
APP=$(ls -d "$OUT"/Payload/*.app)
rm -rf "$APP/PlugIns" "$APP/Extensions" "$APP/Watch" "$APP/embedded.mobileprovision"
find "$APP" -name _CodeSignature -type d -prune -exec rm -rf {} +
while IFS= read -r f; do
    case "$(file -b "$f")" in *Mach-O*) ;; *) continue ;; esac
    if lipo -info "$f" 2>/dev/null | grep -q "Architectures in the fat file"; then
        lipo "$f" -thin arm64 -output "$f.thin" && mv "$f.thin" "$f"
    fi
    if otool -l "$f" | grep -q LC_VERSION_MIN_IPHONEOS; then
        python3 "$(dirname "$0")/macho-iossim.py" "$f" >/dev/null
        continue
    fi
    read -r minos sdk < <(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{m=$2} b&&/sdk/{print m, $2; exit}') || true
    vtool -set-build-version iossim "$minos" "$sdk" -replace -output "$f.sim" "$f" 2>/dev/null && mv "$f.sim" "$f"
    unset minos sdk
done < <(find "$APP" -type f)
# Inside out: frameworks and dylibs first, then the app.
find "$APP/Frameworks" -depth \( -name "*.framework" -o -name "*.dylib" \) -exec codesign -f -s - {} \; 2>/dev/null
# No entitlements: the Simulator refuses to start an ad hoc app that claims them ("Security policy issue").
codesign -f -s - "$APP"
echo "$APP"
