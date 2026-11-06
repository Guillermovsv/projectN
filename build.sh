#!/bin/bash
# Builds ProjectN.app into ./build. Usage: ./build.sh [--install]  (--install copies it to /Applications)
#   SIGN_IDENTITY="My Cert" ./build.sh   → sign with a stable identity (keeps macOS permissions across rebuilds)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ProjectN.app
swift build -c release
BIN="$(swift build -c release --show-bin-path)/ProjectN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProjectN"

# SwiftTerm ships a resource bundle; copy any bundles next to the binary.
for b in "$(dirname "$BIN")"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ProjectN</string>
  <key>CFBundleDisplayName</key><string>ProjectN</string>
  <key>CFBundleIdentifier</key><string>dev.projectn.app</string>
  <key>CFBundleExecutable</key><string>ProjectN</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Built-in NVoice dictation -->
  <key>NSMicrophoneUsageDescription</key><string>ProjectN listens to your microphone while you hold the fn key so it can transcribe your dictation (NVoice).</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>ProjectN transcribes your dictation on-device (NVoice).</string>
  <key>NSAppleEventsUsageDescription</key><string>ProjectN pastes transcribed text into the active app (NVoice).</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <!-- The built-in browser previews local dev servers over plain http -->
    <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

# A stable identity keeps macOS permissions (Input Monitoring, Accessibility, Microphone — needed by the
# built-in NVoice dictation) across rebuilds. Ad-hoc signing ("-") changes the signature every build,
# so macOS silently ignores the old grant.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  for id in "ProjectN Local Signing" "NVoice Local Signing"; do
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$id\""; then SIGN_IDENTITY="$id"; break; fi
  done
fi
codesign --force --deep --sign "${SIGN_IDENTITY:--}" --identifier dev.projectn.app "$APP" >/dev/null
echo "Signed with: ${SIGN_IDENTITY:-ad-hoc}"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/ProjectN.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/ProjectN.app"
fi
