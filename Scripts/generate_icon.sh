#!/usr/bin/env zsh
# Regenerate the app icon and compile the .icns.
# Output lands in Support/Icons/ and is picked up by Scripts/build.sh.
set -eo pipefail

ROOT="${0:A:h:h}"
OUT="$ROOT/Support/Icons"

rm -rf "$OUT"
mkdir -p "$OUT"
swift "$ROOT/Scripts/generate_icon.swift" "$OUT"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
echo "Compiled $OUT/AppIcon.icns"
