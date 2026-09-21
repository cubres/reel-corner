#!/bin/bash
# Removes Reel Corner and undoes its function-key remapping.
# Your Instagram login and settings are left alone unless you pass --all.
set -euo pipefail
cd "$(dirname "$0")"

APP_ID="com.reelcorner.app"

echo "==> Stopping"
launchctl bootout "gui/$(id -u)/$APP_ID" 2>/dev/null || true
pkill -f "Reel Corner.app/Contents/MacOS/ReelCorner" 2>/dev/null || true

echo "==> Restoring function keys"
python3 fkeys.py uninstall || true

echo "==> Removing app and login item"
rm -rf "/Applications/Reel Corner.app"
rm -f "$HOME/Library/LaunchAgents/$APP_ID.plist"

if [ "${1:-}" = "--all" ]; then
  rm -rf "$HOME/Library/Application Support/ReelCorner"
  rm -f  "$HOME/Library/Logs/ReelCorner.log"
  echo "==> Removed settings and log too"
fi
echo "Done."
