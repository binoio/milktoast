#!/usr/bin/env zsh
# Install the built app into /Applications and link the CLI into PATH.
#   ./Scripts/install.sh
set -eo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/Milktoast.app"
DEST="/Applications/Milktoast.app"
CLI_LINK="/usr/local/bin/milktoast"

[[ -d "$APP" ]] || { echo "Build first: ./Scripts/build.sh" >&2; exit 1 }

echo "==> Installing $DEST"
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "==> Linking $CLI_LINK"
if [[ -w "${CLI_LINK:h}" ]] || sudo -n true 2>/dev/null; then
  sudo mkdir -p "${CLI_LINK:h}"
  sudo ln -sf "$DEST/Contents/Helpers/milktoast" "$CLI_LINK"
else
  echo "    skipped (no write access to ${CLI_LINK:h}); run with sudo to link the CLI."
fi

# Teach Launch Services about the new bundle so it shows up under "Open With"
# straight away instead of after the next login.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST"

echo "Installed. To make Milktoast the default for .mkv: select a file in Finder,"
echo "press Cmd-I, set \"Open with\" to Milktoast, then click \"Change All…\"."
