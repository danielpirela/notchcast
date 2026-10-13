#!/usr/bin/env bash
# Builds Notchcast.app (Apple Silicon) next to this script. No Xcode GUI needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" >/dev/null && pwd -P)"
APP="$ROOT/Notchcast.app"

swift build --package-path "$ROOT" -c release --arch arm64
BIN_DIR="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Notchcast" "$APP/Contents/MacOS/Notchcast"

/usr/bin/tee "$APP/Contents/Info.plist" >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Notchcast</string>
    <key>CFBundleDisplayName</key><string>Notchcast</string>
    <key>CFBundleIdentifier</key><string>local.notchcast</string>
    <key>CFBundleExecutable</key><string>Notchcast</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
