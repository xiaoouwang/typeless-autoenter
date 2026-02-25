#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="TypelessAutoEnter.app"
MACOS="$APP/Contents/MacOS"
BIN="typeless-autoenter"

# -- compile --
clang -fobjc-arc typeless-autoenter.m \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework Carbon \
    -O2 -Wall -Wextra \
    -o "$BIN"

# -- assemble .app bundle --
rm -rf "$APP"
mkdir -p "$MACOS"
mv "$BIN" "$MACOS/$BIN"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.user.typeless-autoenter</string>
    <key>CFBundleName</key>
    <string>TypelessAutoEnter</string>
    <key>CFBundleExecutable</key>
    <string>typeless-autoenter</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# -- code sign (ad-hoc) --
codesign --force --sign - "$APP"

echo "build done → ./$APP"
echo "binary at  → ./$MACOS/$BIN"
