#!/usr/bin/env zsh
# Xcode Cloud post-clone hook. Xcode Cloud builds and tests the SwiftPM package
# from its workflow configuration; this hook surfaces the toolchain in the build
# log, warms the package graph, and regenerates the app icon so the bundle that
# Xcode Cloud produces matches a local build.
set -eo pipefail

swift --version
cd "$CI_PRIMARY_REPOSITORY_PATH"
swift package resolve
./Scripts/generate_icon.sh
