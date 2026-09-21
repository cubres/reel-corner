#!/bin/bash
# Reel Corner - build, install, autostart, and set up the function keys.
# Safe to re-run: it merges with whatever key remapping you already have.
set -euo pipefail
cd "$(dirname "$0")"

APP_ID="com.reelcorner.app"
APP_DIR="/Applications/Reel Corner.app"
AGENT="$HOME/Library/LaunchAgents/$APP_ID.plist"
SUPPORT="$HOME/Library/Application Support/ReelCorner"

echo "==> Building"
./build.sh >/dev/null

echo "==> Installing to $APP_DIR"
rm -rf "$APP_DIR"
cp -R "Reel Corner.app" "$APP_DIR"

echo "==> Autostart at login"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$APP_ID</string>
  <key>ProgramArguments</key>
  <array><string>$APP_DIR/Contents/MacOS/ReelCorner</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$APP_ID" 2>/dev/null || true

echo "==> Function keys"
python3 fkeys.py install || echo "    (skipped - see the message above)"

sleep 1
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo
echo "Reel Corner is running. Look for the ▶ icon in your menu bar."
echo "Settings (keys, panel size): $SUPPORT/config.json  - edits apply within 2 seconds."
