#!/bin/bash
set -e

APP_NAME="TalkText"
BUNDLE_DIR="$APP_NAME.app"
CONTENTS="$BUNDLE_DIR/Contents"
MACOS="$CONTENTS/MacOS"

cd "$(dirname "$0")"

echo "==> Building release..."
cd TalkText
swift build -c release 2>&1
cd ..

echo "==> Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS"

cp "TalkText/.build/release/TalkText" "$MACOS/TalkText"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TalkText</string>
    <key>CFBundleIdentifier</key>
    <string>com.joeblau.talktext</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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
