#!/bin/zsh
# Installs one of the icon concepts as the app icon.
#   scripts/make-icon.sh [docs/design/icons/a-midnight-sun.svg]
set -euo pipefail
cd "$(dirname "$0")/.."
svg=${1:-docs/design/icons/a-midnight-sun.svg}
mkdir -p build Glimt/Assets.xcassets
[[ -f Glimt/Assets.xcassets/Contents.json ]] || echo '{"info":{"author":"xcode","version":1}}' > Glimt/Assets.xcassets/Contents.json
swiftc -O -o build/render-icon scripts/RenderIcon.swift
rm -rf Glimt/Assets.xcassets/AppIcon.appiconset
build/render-icon "$svg" Glimt/Assets.xcassets/AppIcon.appiconset
