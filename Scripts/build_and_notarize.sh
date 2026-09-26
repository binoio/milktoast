#!/usr/bin/env zsh
# Build, sign, notarize, and staple a distributable Milktoast.app, then wrap it in a DMG.
#
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=milktoast-notary \
#     ./Scripts/build_and_notarize.sh
#
# Create NOTARY_PROFILE once with:
#   xcrun notarytool store-credentials milktoast-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -eo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a stored notarytool credential profile}"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/build/Milktoast.app"
DIST="$ROOT/dist"
ZIP="$DIST/Milktoast-$VERSION.zip"
DMG="$DIST/Milktoast-$VERSION.dmg"

"$ROOT/Scripts/build.sh"

mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"

echo "==> Submitting for notarization"
# notarytool needs a zip (or dmg/pkg); ditto preserves the bundle's symlinks.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
# Re-zip so the archive contains the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Milktoast.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Milktoast $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo "Ready: $ZIP"
echo "Ready: $DMG"
