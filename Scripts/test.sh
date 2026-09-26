#!/usr/bin/env zsh
# Run the Milktoast test suite.
#   ./Scripts/test.sh           native run (unit + ffmpeg integration tests)
#   ./Scripts/test.sh --docker  containerized run of the portable engine suite
set -eo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

if [[ "$1" == "--docker" ]]; then
  docker build -t milktoast-tests . || docker-compose build tests
  docker run --rm milktoast-tests
else
  if ! command -v ffmpeg >/dev/null; then
    echo "note: ffmpeg is not on PATH — the integration tests will skip themselves."
  fi
  swift test
fi
