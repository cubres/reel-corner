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

echo "generating Swift bridge from shared/bridge.js..."
python3 - <<'GEN'
import json
js = open("shared/bridge.js").read()
# JSON escaping is compatible with Swift string literals as long as non-ASCII stays
# literal - Swift spells unicode escapes \u{...}, not \uXXXX.
lit = json.dumps(js, ensure_ascii=False)
open("src/Bridge.generated.swift", "w").write(
    "// GENERATED from shared/bridge.js by build.sh - do not edit.\n"
    "import Foundation\n\nlet reelBridgeJS = " + lit + "\n")
GEN

echo "compiling..."
swiftc -O \
  -framework Cocoa -framework WebKit -framework Carbon \
  -o "$APP/Contents/MacOS/ReelCorner" \
  src/*.swift

codesign --force --deep --sign - "$APP" 2>/dev/null
echo "built $(pwd)/$APP"
