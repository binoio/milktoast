#!/usr/bin/env zsh
# Remove Milktoast, its CLI symlink, its cache, and its preferences.
#   ./Scripts/uninstall.sh
set -eo pipefail

DEST="/Applications/Milktoast.app"
CLI_LINK="/usr/local/bin/milktoast"
CACHE="$HOME/Library/Caches/io.bino.milktoast"
PREFS="$HOME/Library/Preferences/io.bino.milktoast.plist"

if [[ -d "$DEST" ]]; then
  echo "==> Removing $DEST"
  rm -rf "$DEST" 2>/dev/null || sudo rm -rf "$DEST"
fi

if [[ -L "$CLI_LINK" ]]; then
  echo "==> Removing $CLI_LINK"
  rm -f "$CLI_LINK" 2>/dev/null || sudo rm -f "$CLI_LINK"
fi

if [[ -d "$CACHE" ]]; then
  echo "==> Removing cached remuxes ($(du -sh "$CACHE" | cut -f1))"
  rm -rf "$CACHE"
fi

if [[ -f "$PREFS" ]]; then
  echo "==> Removing preferences"
  defaults delete io.bino.milktoast 2>/dev/null || true
  rm -f "$PREFS"
fi

# Drop the stale Launch Services registration so Milktoast stops appearing under
# "Open With" for .mkv files.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$DEST" 2>/dev/null || true

echo "Done."
