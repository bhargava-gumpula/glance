#!/bin/zsh
# Build Glance.app and launch it.
# Signs with the "Glance Dev" identity so macOS permissions survive rebuilds.
# Without it, falls back to ad-hoc signing (permissions must be re-granted after each build).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c debug
APP=build/Glance.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/Glance "$APP/Contents/MacOS/Glance"

# 8-bit penguin icon, rendered from Pip's pixel grid.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
.build/debug/Glance --make-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ie.dublinhacx.glance</string>
  <key>CFBundleName</key><string>Glance</string>
  <key>CFBundleExecutable</key><string>Glance</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>So you can talk to Glance instead of typing.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Turns your speech into a question when you are offline.</string>
</dict></plist>
PLIST

if security find-identity -p codesigning | grep -q '"Glance Dev"'; then
  codesign --force --sign "Glance Dev" "$APP"
else
  echo "warning: 'Glance Dev' signing identity not found; signing ad-hoc (permissions reset on every rebuild)" >&2
  codesign --force --sign - "$APP"
fi

pkill -x Glance 2>/dev/null || true
open "$APP"
echo "Launched $APP"
