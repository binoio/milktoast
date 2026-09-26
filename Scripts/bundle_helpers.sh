#!/usr/bin/env zsh
# Copy ffmpeg and ffprobe — plus every non-system dylib they pull in — into the
# app bundle and rewrite their load commands so the copies are self-contained.
#
#   Scripts/bundle_helpers.sh <path-to-Milktoast.app>
#
# Layout produced:
#   Milktoast.app/Contents/Helpers/ffmpeg         (@executable_path/../Frameworks/...)
#   Milktoast.app/Contents/Helpers/ffprobe
#   Milktoast.app/Contents/Frameworks/libavcodec.dylib  (@loader_path/... between them)
#
# Override the source binaries with FFMPEG_PATH / FFPROBE_PATH.
set -eo pipefail

APP="${1:?usage: bundle_helpers.sh <path-to-Milktoast.app>}"
HELPERS="$APP/Contents/Helpers"
FRAMEWORKS="$APP/Contents/Frameworks"

FFMPEG_SRC="${FFMPEG_PATH:-$(command -v ffmpeg || true)}"
FFPROBE_SRC="${FFPROBE_PATH:-$(command -v ffprobe || true)}"

if [[ -z "$FFMPEG_SRC" || -z "$FFPROBE_SRC" ]]; then
  echo "bundle_helpers: ffmpeg/ffprobe not found." >&2
  echo "  Install them (brew install ffmpeg) or set FFMPEG_PATH and FFPROBE_PATH." >&2
  exit 1
fi

mkdir -p "$HELPERS" "$FRAMEWORKS"
cp -f "$FFMPEG_SRC" "$HELPERS/ffmpeg"
cp -f "$FFPROBE_SRC" "$HELPERS/ffprobe"
chmod +x "$HELPERS/ffmpeg" "$HELPERS/ffprobe"

# A dependency is "system" when dyld will always find it on any Mac; everything
# else has to travel with the app.
is_system_dylib() {
  [[ "$1" == /usr/lib/* || "$1" == /System/Library/* ]]
}

# Mach-O files still needing their load commands rewritten.
typeset -a worklist
worklist=("$HELPERS/ffmpeg" "$HELPERS/ffprobe")
typeset -A seen

while (( ${#worklist} > 0 )); do
  target="${worklist[1]}"
  shift worklist

  # Skip the first line of otool -L output: it names the file itself.
  deps=("${(@f)$(otool -L "$target" | tail -n +2 | awk '{print $1}')}")

  for dep in $deps; do
    [[ -z "$dep" ]] && continue
    is_system_dylib "$dep" && continue
    # Already-rewritten references need no further work.
    [[ "$dep" == @* ]] && continue

    base="${dep:t}"
    dest="$FRAMEWORKS/$base"

    if [[ ! -f "$dest" ]]; then
      if [[ ! -f "$dep" ]]; then
        echo "bundle_helpers: missing dependency $dep (referenced by ${target:t})" >&2
        exit 1
      fi
      cp -f "$dep" "$dest"
      chmod u+w "$dest"
      install_name_tool -id "@loader_path/$base" "$dest"
      # A freshly copied dylib may itself link other non-system dylibs.
      worklist+=("$dest")
    fi

    if [[ "$target" == "$HELPERS/"* ]]; then
      install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" "$target"
    else
      install_name_tool -change "$dep" "@loader_path/$base" "$target"
    fi
  done

  seen[$target]=1
done

count=$(ls -1 "$FRAMEWORKS" 2>/dev/null | wc -l | tr -d ' ')
echo "Bundled ffmpeg/ffprobe from ${FFMPEG_SRC:h} with $count support libraries."
