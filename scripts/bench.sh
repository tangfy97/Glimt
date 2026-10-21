#!/bin/zsh
# Builds Release and runs the built-in benchmark against a folder.
#   scripts/bench.sh [folder] [steps] [interval-ms]
set -euo pipefail
cd "$(dirname "$0")/.."
folder=${1:-.fixtures/photos}
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration Release -derivedDataPath build/DerivedData.noindex build -quiet
GLIMT_BENCH=${2:-40} GLIMT_BENCH_INTERVAL_MS=${3:-120} \
  build/DerivedData.noindex/Build/Products/Release/Glimt.app/Contents/MacOS/Glimt "$(cd "$folder" && pwd)"
# Keep build products out of Launchpad / Open With; the installed copy is /Applications/Glimt.app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u \
  "$PWD/build/DerivedData.noindex/Build/Products/Release/Glimt.app" 2>/dev/null || true
