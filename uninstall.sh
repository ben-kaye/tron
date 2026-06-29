#!/bin/sh
# Tron: remove the daemon, restore normal charging.
set -e
BIN=/usr/local/bin/tron
PLIST=/Library/LaunchDaemons/com.tron.plist

sudo launchctl bootout system "$PLIST" 2>/dev/null || true
[ -x "$BIN" ] && sudo "$BIN" on || true   # re-enable charging before removing
sudo rm -f "$BIN" "$PLIST" /etc/tron-limit /etc/tron-mode /etc/tron-once
echo "tron uninstalled, charging re-enabled."
