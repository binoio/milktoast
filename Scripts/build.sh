#!/usr/bin/env zsh
# Build Milktoast and assemble the macOS .app bundle from the SwiftPM products.
#
#   ./Scripts/build.sh                 release build, ffmpeg bundled if present
#   ./Scripts/build.sh --debug         debug build (faster; used by run.sh)
#   ./Scripts/build.sh --no-helpers    do not embed ffmpeg; use the system copy
#
# Signing: set CODESIGN_IDENTITY to a Developer ID Application identity for a
# distributable build. Without it the bundle is ad-hoc signed, which is fine
# locally but will be blocked by Gatekeeper on another Mac.
set -eo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

CONFIG="release"
BUNDLE_HELPERS=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --no-helpers) BUNDLE_HELPERS=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product Milktoast
swift build -c "$CONFIG" --product milktoastcli

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Milktoast.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BIN_DIR/Milktoast" "$APP/Contents/MacOS/Milktoast"
# The headless driver ships inside the bundle so `milktoast` on the command line and
# the app always agree on behaviour. Scripts/install.sh links it into PATH.
# It goes in Helpers, not MacOS: the default macOS filesystem is
# case-insensitive, so "MacOS/milktoast" and "MacOS/Milktoast" would be the same file.
cp "$BIN_DIR/milktoastcli" "$APP/Contents/Helpers/milktoast"
chmod +x "$APP/Contents/MacOS/Milktoast" "$APP/Contents/Helpers/milktoast"

cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
print -n "APPL????" > "$APP/Contents/PkgInfo"

# Marketing version from VERSION; build number from the commit count so it
# increases monotonically across releases.
if [[ -f "$ROOT/VERSION" ]]; then
  VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# App icon (regenerate with Scripts/generate_icon.sh).
if [[ -f "$ROOT/Support/Icons/AppIcon.icns" ]]; then
  cp "$ROOT/Support/Icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    (no AppIcon.icns — run Scripts/generate_icon.sh)"
fi

if (( BUNDLE_HELPERS )); then
  echo "==> Bundling ffmpeg"
  if ! "$ROOT/Scripts/bundle_helpers.sh" "$APP"; then
    echo "    ffmpeg was not embedded; Milktoast will look for it on PATH at runtime."
  fi
fi

echo "==> Signing"
IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Support/Milktoast.entitlements"
xattr -cr "$APP"

# Sign inside-out: nested code first, the bundle last.
for dylib in "$APP"/Contents/Frameworks/*.dylib(N); do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$dylib" >/dev/null
done
for helper in "$APP"/Contents/Helpers/*(N); do
  [[ -f "$helper" ]] || continue
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$helper" >/dev/null
done
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict "$APP" && echo "    signature OK ($IDENTITY)"

echo "Built: $APP"
