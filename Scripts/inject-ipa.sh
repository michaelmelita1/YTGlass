#!/usr/bin/env bash
# Inject YTGlass.dylib into a decrypted YouTube IPA.
# usage: inject-ipa.sh YouTube.ipa YTGlass.dylib [output.ipa]
# The output is unsigned-for-device; sign it with your sideloading tool
# (Sideloadly, AltStore, SideStore, Feather, ...).
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: inject-ipa.sh input.ipa YTGlass.dylib [output.ipa]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
DYLIB="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
OUTPUT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${3:-$PWD/YouTube_YTGlass.ipa}")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

unzip -q "$INPUT" -d "$WORK"
APP="$(find "$WORK/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
test -n "$APP"

EXECUTABLE="$(python3 - "$APP/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f)["CFBundleExecutable"])
PY
)"

python3 "$ROOT/Tools/macho_inject.py" "$APP/$EXECUTABLE" --add-load '@rpath/YTGlass.dylib'
mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/YTGlass.dylib"
rm -rf "$APP/_CodeSignature"

(cd "$WORK" && zip -qry "$WORK/out.ipa" Payload)
mkdir -p "$(dirname "$OUTPUT")"
mv -f "$WORK/out.ipa" "$OUTPUT"
echo "$OUTPUT"
