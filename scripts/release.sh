#!/bin/zsh
# Builds a release of Glimt: Glimt-<version>.zip and Glimt-<version>.dmg in build/release.
#
#   scripts/release.sh 0.1.0
#
# Signed and notarized (for publishing) when these are set:
#   DEVELOPER_ID    the signing identity, e.g. "Developer ID Application: TangSpark (ABCDE12345)"
#   NOTARY_PROFILE  a notarytool keychain profile, created once with
#                   xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password …
# Without them, the build is signed ad hoc: fine for testing on this Mac, not for publishing.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh <version>}
out=build/release
rm -rf "$out" && mkdir -p "$out"

signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  signing=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

xcodegen generate --quiet
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration Release \
  -derivedDataPath build/DerivedData.noindex -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$version" "${signing[@]}" build -quiet
ditto build/DerivedData.noindex/Build/Products/Release/Glimt.app "$out/Glimt.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/build/DerivedData.noindex/Build/Products/Release/Glimt.app" 2>/dev/null || true

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$out/Glimt.app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$out/Glimt.app"
  rm "$out/notarize.zip"
else
  echo "warning: DEVELOPER_ID or NOTARY_PROFILE not set; this build is not notarized and is for testing only." >&2
fi

ditto -c -k --keepParent "$out/Glimt.app" "$out/Glimt-$version.zip"
staging=$(mktemp -d)
ditto "$out/Glimt.app" "$staging/Glimt.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Glimt $version" -srcfolder "$staging" -format UDZO -quiet "$out/Glimt-$version.dmg"
rm -rf "$staging"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$out/Glimt-$version.dmg"
  [[ -n "${NOTARY_PROFILE:-}" ]] && xcrun notarytool submit "$out/Glimt-$version.dmg" --keychain-profile "$NOTARY_PROFILE" --wait && xcrun stapler staple "$out/Glimt-$version.dmg"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/$out/Glimt.app" 2>/dev/null || true
rm -rf "$out/Glimt.app"
(cd "$out" && shasum -a 256 Glimt-"$version".zip Glimt-"$version".dmg | tee SHA256SUMS)
