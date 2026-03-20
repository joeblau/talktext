#!/bin/bash
set -euo pipefail

APP_NAME="TalkText"
BUNDLE_DIR="$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
VERSION="$(tr -d '\n' < VERSION)"
MODEL_NAME="ggml-base.en.bin"

cd "$(dirname "$0")"

echo "==> Building release..."
cd TalkText
swift build -c release 2>&1
cd ..

echo "==> Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES/models"

cp "TalkText/.build/release/TalkText" "$MACOS/TalkText"
cp "models/$MODEL_NAME" "$RESOURCES/models/$MODEL_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TalkText</string>
    <key>CFBundleIdentifier</key>
    <string>com.joeblau.talktext</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>TalkText</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>TalkText needs microphone access to record and transcribe your voice.</string>
</dict>
</plist>
PLIST

echo "==> Done! App bundle created at: $(pwd)/$BUNDLE_DIR"
echo ""
echo "To run:  open $BUNDLE_DIR"
echo ""
echo "On first launch, macOS will prompt for:"
echo "  1. Microphone access"
echo "  2. Accessibility (System Settings > Privacy & Security > Accessibility)"
