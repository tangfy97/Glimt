#!/bin/zsh
# Builds Release and runs the end-to-end self-test (GLIMT_SELFTEST=1), which drives a real window
# against real files in a temporary folder. Exits non-zero if any check fails.
#
#   scripts/selftest.sh            # Release
#   scripts/selftest.sh AppStore   # the same checks inside the App Sandbox
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-Release}
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration "$configuration" -derivedDataPath build/DerivedData.noindex build -quiet
app=build/DerivedData.noindex/Build/Products/$configuration/Glimt.app
result=0
# perl's alarm gives the run a time limit, since macOS has no timeout(1).
GLIMT_SELFTEST=1 perl -e 'alarm shift; exec @ARGV' 180 "$app/Contents/MacOS/Glimt" -LastOpenedPath /nonexistent || result=$?
# Keep build products out of Launchpad and Open With.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$app" 2>/dev/null || true
exit $result
