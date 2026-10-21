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
  # Notarization rejects get-task-allow, which Xcode otherwise adds to manually signed builds.
  signing=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

# Submits a file for notarization and stops with Apple's log unless it is accepted.
notarize() {
  local result id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  id=$(plutil -extract id raw - <<< "$result")
  if [[ $(plutil -extract status raw - <<< "$result") != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    echo "error: notarization of $1 was not accepted." >&2
    exit 1
  fi
}

xcodegen generate --quiet
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration Release \
  -derivedDataPath build/DerivedData.noindex -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$version" "${signing[@]}" build -quiet
ditto build/DerivedData.noindex/Build/Products/Release/Glimt.app "$out/Glimt.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/build/DerivedData.noindex/Build/Products/Release/Glimt.app" 2>/dev/null || true

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$out/Glimt.app" "$out/notarize.zip"
  notarize "$out/notarize.zip"
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
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notarize "$out/Glimt-$version.dmg"
    xcrun stapler staple "$out/Glimt-$version.dmg"
  fi
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/$out/Glimt.app" 2>/dev/null || true
rm -rf "$out/Glimt.app"
(cd "$out" && shasum -a 256 Glimt-"$version".zip Glimt-"$version".dmg | tee SHA256SUMS)
