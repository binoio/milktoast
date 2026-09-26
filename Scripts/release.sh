#!/usr/bin/env zsh
#
# release.sh: Build, sign, notarize (App Store Connect API), staple, and
# publish a Milktoast release.
#
# One-time setup:
#   1. A "Developer ID Application" identity in the keychain
#      (override with MILKTOAST_SIGN_IDENTITY).
#   2. Notary credentials in a keychain profile — any profile for the same team
#      works, so an existing edith-notary/atmo-notary is picked up automatically:
#        xcrun notarytool store-credentials milktoast-notary \
#          --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#      (override with MILKTOAST_NOTARY_PROFILE; never commit credentials)
#   3. Sparkle EdDSA key pair in the login Keychain (Sparkle's generate_keys).
#      The public half is committed as SUPublicEDKey in Support/Info.plist and
#      the preflight verifies the two match.
#   4. gh auth login with access to binoio/milktoast.
#
# Per release: bump VERSION, write ReleaseNotes/Milktoast-X.Y.Z.md, commit, run.
#
#   ./Scripts/release.sh            full release
#   ./Scripts/release.sh --dry-run  build, sign, notarize, staple — but do not
#                                   tag, push, or publish

set -euo pipefail

IDENTITY="${MILKTOAST_SIGN_IDENTITY:-Developer ID Application: Michael Bino (43L352U8Y8)}"
REPO="binoio/milktoast"
BUNDLE_ID="io.bino.milktoast"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Resolve the notarytool keychain profile: explicit env var first, then any
# same-team profile already on this machine.
NOTARY_PROFILE=""
for candidate in "${MILKTOAST_NOTARY_PROFILE:-}" milktoast-notary edith-notary atmo-notary kona-notary; do
    [[ -n "$candidate" ]] || continue
    if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
        NOTARY_PROFILE="$candidate"
        break
    fi
done
[[ -n "$NOTARY_PROFILE" ]] || {
    echo "error: no notarytool keychain profile found (run: xcrun notarytool store-credentials milktoast-notary ...)" >&2
    exit 1
}

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
APP="build/Milktoast.app"
DIST="dist"
ZIP="${DIST}/Milktoast-${VERSION}.zip"
DMG="${DIST}/Milktoast-${VERSION}.dmg"
NOTES_MD="ReleaseNotes/Milktoast-${VERSION}.md"
NOTES_HTML="ReleaseNotes/Milktoast-${VERSION}.html"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"

echo "==> Preflight for Milktoast ${VERSION} (notary profile: ${NOTARY_PROFILE})"
if (( ! DRY_RUN )); then
    [[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean" >&2; exit 1; }
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo "error: tag $TAG already exists" >&2; exit 1
    fi
    LATEST_TAG=$(git tag -l 'v*' | sort -V | tail -1)
    if [[ -n "$LATEST_TAG" && "$(print -l "$LATEST_TAG" "$TAG" | sort -V | tail -1)" != "$TAG" ]]; then
        echo "error: version ($VERSION) is not newer than latest tag ($LATEST_TAG)" >&2; exit 1
    fi
    gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated" >&2; exit 1; }
fi
[[ -f "$NOTES_MD" ]] || { echo "error: $NOTES_MD missing" >&2; exit 1; }
[[ -f "$NOTES_HTML" ]] || { echo "error: $NOTES_HTML missing (embedded in the appcast)" >&2; exit 1; }
# Capture before testing: with pipefail, `grep -q` exiting early would kill the
# producer with SIGPIPE and fail the pipeline even on a match.
IDENTITIES=$(security find-identity -v -p codesigning)
[[ "$IDENTITIES" == *"Developer ID Application"* ]] || {
    echo "error: no Developer ID Application signing identity in keychain" >&2; exit 1
}

echo "==> Testing"
swift test

echo "==> Building (release, ffmpeg and Sparkle embedded)"
CODESIGN_IDENTITY="$IDENTITY" ./Scripts/build.sh

SPARKLE_BIN=$(find .build/artifacts -type d -name bin -path "*parkle*" | head -1)
[[ -n "$SPARKLE_BIN" ]] || { echo "error: Sparkle tools not found under .build/artifacts" >&2; exit 1; }

echo "==> Verifying bundle"
PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" == "$BUNDLE_ID" ]] \
    || { echo "error: wrong bundle id" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] \
    || { echo "error: bundle version does not match VERSION" >&2; exit 1; }
for helper in ffmpeg ffprobe milktoast; do
    [[ -x "$APP/Contents/Helpers/$helper" ]] || { echo "error: $helper not bundled" >&2; exit 1; }
done
# Every FFmpeg dependency must have been rewritten to travel inside the bundle;
# an absolute Homebrew path here means the app only runs on this machine.
STRAY=$(otool -L "$APP/Contents/Helpers/ffmpeg" | tail -n +2 | awk '{print $1}' \
    | grep -v '^@' | grep -v '^/usr/lib/' | grep -v '^/System/Library/' || true)
[[ -z "$STRAY" ]] || { echo "error: ffmpeg still links outside the bundle:\n$STRAY" >&2; exit 1; }
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || { echo "error: app icon missing" >&2; exit 1; }
[[ -d "$FRAMEWORK" ]] || { echo "error: Sparkle.framework not embedded" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$PLIST")" == https://* ]] \
    || { echo "error: SUFeedURL missing or not https" >&2; exit 1; }
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
[[ "$PUBLIC_KEY" == "$KEYCHAIN_KEY" ]] \
    || { echo "error: SUPublicEDKey ($PUBLIC_KEY) does not match the EdDSA key in the login Keychain ($KEYCHAIN_KEY)" >&2; exit 1; }
# Sparkle compares CFBundleVersion, so it has to increase on every release.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
LOAD_COMMANDS=$(otool -l "$APP/Contents/MacOS/Milktoast")
[[ "$LOAD_COMMANDS" == *"@executable_path/../Frameworks"* ]] \
    || { echo "error: Frameworks rpath missing" >&2; exit 1; }

echo "==> Notarizing the app via App Store Connect API"
mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"
# notarytool needs an archive; ditto preserves the bundle's symlinks.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# Re-archive so the zip carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building and notarizing the disk image"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Milktoast.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Milktoast ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp -s "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying the signed result"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo "==> Generating appcast (EdDSA signature from login Keychain)"
WORK="${DIST}/appcast-work"
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ZIP" "$WORK/"
cp "$NOTES_HTML" "$WORK/Milktoast-${VERSION}.html"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
    --embed-release-notes \
    -o docs/appcast.xml "$WORK"

if (( DRY_RUN )); then
    echo "==> Dry run: built, signed, notarized, stapled, appcast generated. Not published."
    echo "    $ZIP"
    echo "    $DMG"
    echo "    docs/appcast.xml (build ${BUILD_NUMBER}; not committed)"
    exit 0
fi

echo "==> Publishing (release first, so the download URL exists before the feed goes live)"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" \
    --repo "$REPO" \
    --title "Milktoast ${VERSION}" \
    --notes-file "$NOTES_MD"

git add docs/appcast.xml
git commit -m "Publish appcast for ${VERSION}"
git push origin HEAD

echo "==> Done: Milktoast ${VERSION} released (build ${BUILD_NUMBER})."
echo "    https://github.com/${REPO}/releases/tag/${TAG}"
echo "    Pages will deploy the appcast shortly."
