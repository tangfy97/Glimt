#!/bin/zsh
# Builds the Mac App Store version of Glimt (the AppStore configuration, in the App Sandbox).
#
#   scripts/appstore.sh 0.1.0 1           # signed installer package in build/appstore
#   scripts/appstore.sh 0.1.0 1 upload    # the same, sent to App Store Connect
#
# The arguments are the version and the build number; every upload needs a new build number.
# Signing is automatic: Xcode must be signed in to an account in the team below, and it creates
# the distribution certificate and provisioning profile the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/appstore.sh <version> <build> [upload]}
build=${2:?usage: scripts/appstore.sh <version> <build> [upload]}
destination=${3:-export}
team=${TEAM_ID:-X933P26489}
out=build/appstore
rm -rf "$out" && mkdir -p "$out"

xcodegen generate --quiet
xcodebuild -project Glimt.xcodeproj -scheme Glimt -configuration AppStore \
  -derivedDataPath build/DerivedData.noindex -destination 'generic/platform=macOS' \
  -archivePath "$out/Glimt.xcarchive" -allowProvisioningUpdates \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  archive -quiet

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$destination</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$out/Glimt.xcarchive" -exportPath "$out" \
  -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates

# Keep the archived app out of Launchpad and Open With.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/$out/Glimt.xcarchive/Products/Applications/Glimt.app" 2>/dev/null || true
ls -l "$out"
