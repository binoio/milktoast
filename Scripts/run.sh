#!/usr/bin/env zsh
# Build (debug) and launch the app bundle, optionally opening a movie.
#   ./Scripts/run.sh
#   ./Scripts/run.sh ~/Movies/Example.mkv
set -eo pipefail

ROOT="${0:A:h:h}"
"$ROOT/Scripts/build.sh" --debug --no-helpers

APP="$ROOT/build/Milktoast.app"
if (( $# > 0 )); then
  open -a "$APP" "$@"
else
  open "$APP"
fi
