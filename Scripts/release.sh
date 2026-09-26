#!/usr/bin/env zsh
# Cut a release: verify the tree is clean and tested, build a notarized DMG,
# and tag the commit.
#
#   ./Scripts/release.sh 1.1.0
set -eo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

VERSION="${1:?usage: release.sh <version>}"

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "Working tree is dirty; commit or stash first." >&2
  exit 1
fi

echo "==> Testing"
"$ROOT/Scripts/test.sh"

echo "$VERSION" > "$ROOT/VERSION"

NOTES="$ROOT/ReleaseNotes/Milktoast-$VERSION.md"
if [[ ! -f "$NOTES" ]]; then
  echo "Missing release notes: $NOTES" >&2
  echo "Write them first, then re-run." >&2
  exit 1
fi

echo "==> Building notarized artifacts"
"$ROOT/Scripts/build_and_notarize.sh"

git add VERSION "$NOTES"
git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Milktoast $VERSION"

echo "Tagged v$VERSION. Push with: git push && git push --tags"
