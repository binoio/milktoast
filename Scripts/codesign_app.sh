#!/usr/bin/env zsh
#
# codesign_app.sh: Sign Milktoast.app inside-out (never --deep) with the
# hardened runtime and the app's entitlements.
#
# Order matters: nested code must be signed before the code that contains it,
# or the outer signature seals a bundle whose contents then change. The bundled
# FFmpeg libraries go first, then the helper executables, then the app.
#
# Usage: Scripts/codesign_app.sh <path/to/Milktoast.app> <signing-identity>

set -euo pipefail

APP_BUNDLE="${1:?usage: codesign_app.sh <app> <identity>}"
IDENTITY="${2:?usage: codesign_app.sh <app> <identity>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/Support/Milktoast.entitlements"

CODESIGN_FLAGS=(--force --options runtime --timestamp -s "$IDENTITY")

SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# Strip quarantine and any resource forks Finder may have added; they make
# codesign fail with "resource fork, Finder information, or similar detritus".
xattr -cr "$APP_BUNDLE"

echo "Step 1/4: Signing Sparkle.framework..."
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    # Sparkle's helpers are separately signed executables; its XPC services keep
    # the entitlements they shipped with.
    codesign "${CODESIGN_FLAGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    codesign "${CODESIGN_FLAGS[@]}" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
    codesign "${CODESIGN_FLAGS[@]}" --preserve-metadata=entitlements \
        "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
    codesign "${CODESIGN_FLAGS[@]}" --preserve-metadata=entitlements \
        "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
    codesign "${CODESIGN_FLAGS[@]}" "$SPARKLE_FRAMEWORK"
else
    echo "          not embedded; skipping"
fi

echo "Step 2/4: Signing bundled FFmpeg libraries..."
libs=("$APP_BUNDLE"/Contents/Frameworks/*.dylib(N))
if (( ${#libs} )); then
    for lib in $libs; do
        codesign "${CODESIGN_FLAGS[@]}" "$lib"
    done
    echo "          signed ${#libs} libraries"
else
    echo "          none embedded; skipping"
fi

echo "Step 3/4: Signing helper executables..."
helpers=("$APP_BUNDLE"/Contents/Helpers/*(N))
if (( ${#helpers} )); then
    for helper in $helpers; do
        codesign "${CODESIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$helper"
    done
    echo "          signed ${#helpers} helpers"
else
    echo "          none embedded; skipping"
fi

echo "Step 4/4: Signing app bundle with entitlements..."
codesign "${CODESIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

echo "Code signing complete (inner-to-outer)."
