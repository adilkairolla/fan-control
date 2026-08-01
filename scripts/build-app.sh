#!/bin/bash
# Assembles FanControl.app from the SPM build output.
#
# There is no Xcode project here — Command Line Tools can build the binaries but
# not produce a bundle, so we lay one out by hand. That is all a .app is.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="FanControl"
BUNDLE_ID="com.fancontrol.app"

# shellcheck source=version.sh
. "$(dirname "$0")/version.sh"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="build/${APP_NAME}.app"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/FanControlApp" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>Fan Control</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${BUILD_NUMBER}</string>
    <!-- Provenance, not decoration: the app's Update button needs to find the
         checkout it was built from, and nothing is baked into the binary
         because a generated source file would leave the tree permanently
         dirty and block the fast-forward that an update is. -->
    <key>FCSourceCommit</key>            <string>${COMMIT}</string>
    <key>FCSourceDate</key>              <string>${COMMIT_DATE}</string>
    <key>FCSourceRoot</key>              <string>${SOURCE_ROOT}</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Menu bar agent: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Without a Developer ID this is as far as signing goes, and
# it is enough: locally built bundles carry no quarantine attribute, so
# Gatekeeper never gets involved.
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null \
    || echo "    (codesign unavailable — the app will still run)"

echo
echo "Built $APP_DIR  ($VERSION, $COMMIT)"
echo "Run it with:  open $APP_DIR"
echo "Install to /Applications:  cp -R $APP_DIR /Applications/"
