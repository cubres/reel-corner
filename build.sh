#!/bin/bash
# Compiles "Reel Corner.app". Use ./install.sh to actually install it.
set -euo pipefail
cd "$(dirname "$0")"

APP="Reel Corner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Reel Corner</string>
  <key>CFBundleDisplayName</key><string>Reel Corner</string>
  <key>CFBundleExecutable</key><string>ReelCorner</string>
  <key>CFBundleIdentifier</key><string>com.reelcorner.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

echo "compiling..."
swiftc -O \
  -framework Cocoa -framework WebKit -framework Carbon \
  -o "$APP/Contents/MacOS/ReelCorner" \
  src/*.swift

codesign --force --deep --sign - "$APP" 2>/dev/null
echo "built $(pwd)/$APP"
