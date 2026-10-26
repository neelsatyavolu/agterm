#!/bin/sh
# Builds a release agterm.app in ./dist. Usage: scripts/bundle.sh
# Signs with $APPLE_SIGNING_IDENTITY (hardened runtime) when it is set, otherwise ad hoc.
# To sign with the Developer ID and install, use ./install.sh; to publish, scripts/release.sh.
set -eu
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
FEED_URL="https://github.com/neelsatyavolu/agterm/releases/latest/download/appcast.xml"
# Public half of the EdDSA key that signs updates (private half: 1Password "agterm Sparkle Update Key").
SPARKLE_PUBLIC_KEY="9PP4QvxMnBnPLbBlDqNSB3pBnCVE93Nv1d9lPayHwzM="

# Universal: Apple silicon and Intel.
ARCHS="--arch arm64 --arch x86_64"
# shellcheck disable=SC2086
swift build -c release $ARCHS
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCHS --show-bin-path)"
APP=dist/agterm.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
# Also the sessions helper (`agterm --sessions-helper`), which keeps tabs' shells running while
# agterm is quit; one executable, so the helper has the app's code identity and privacy permissions.
cp "$BIN/AgTerm" "$APP/Contents/MacOS/agterm"
cp -R "$BIN"/*.bundle "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -X Resources/agterm-notify.wav "$APP/Contents/Resources/"
# What's New reads it after an update.
cp -X CHANGELOG.md "$APP/Contents/Resources/"
# agmux's memory and consult servers, for Macs without agmux (Resources/mcp/README.md).
cp -R -X Resources/mcp "$APP/Contents/Resources/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>agterm</string>
  <key>CFBundleDisplayName</key><string>agterm</string>
  <key>CFBundleIdentifier</key><string>co.xanom.agterm</string>
  <key>CFBundleExecutable</key><string>agterm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Neel Satyavolu. MIT License.</string>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# Sign inside out: Sparkle's helpers, the framework, then the app (no --deep).
ID="${APPLE_SIGNING_IDENTITY:--}"
sign() {
  if [ "$ID" = "-" ]; then
    codesign --force --sign - "$@"
  else
    codesign --force --timestamp --options runtime \
      ${AGTERM_SIGN_KEYCHAIN:+--keychain "$AGTERM_SIGN_KEYCHAIN"} --sign "$ID" "$@"
  fi
}
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
codesign --verify --deep --strict "$APP"
# The sessions helper runs this executable, so it must carry the app's identifier.
codesign -dv "$APP/Contents/MacOS/agterm" 2>&1 | grep -qx "Identifier=co.xanom.agterm" \
  || { echo "error: $APP/Contents/MacOS/agterm isn't signed as co.xanom.agterm" >&2; exit 1; }
echo "built $APP ($VERSION)"
