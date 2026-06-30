#!/bin/sh
# Tron: battery charge limiter for Apple Silicon. Installs a root launchd daemon.
set -e
BIN=/usr/local/bin/tron
PLIST=/Library/LaunchDaemons/com.tron.plist
LIMIT_FILE=/etc/tron-limit

swiftc -O "$(dirname "$0")/tron.swift" -o /tmp/tron
sudo install -m 755 /tmp/tron "$BIN"
[ -f "$LIMIT_FILE" ] || echo 80 | sudo tee "$LIMIT_FILE" >/dev/null
sudo rm -f /etc/tron-key   # obsolete (keys are now auto-detected per chip)

sudo tee "$PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tron</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/tron.log</string>
</dict></plist>
EOF

sudo launchctl bootout system "$PLIST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"
echo "tron installed. limit=$(cat "$LIMIT_FILE")%"
echo "  change limit:   echo 75 | sudo tee $LIMIT_FILE"
echo "  sailing mode:   echo '80 60' | sudo tee $LIMIT_FILE   # drain to 60 before recharging to 80"
echo "  drain mode:     echo drain | sudo tee /etc/tron-mode  # actively discharge to limit (back: echo hold)"
echo "  heat ceiling:   echo 35 | sudo tee /etc/tron-temp    # pause charging above this battery °C (default 35)"
echo "  top up full:    sudo $BIN full         # charge to 100% once, then revert to band"
echo "  drain to level: sudo $BIN drain-to 50  # discharge to 50% once, then revert to band"
echo "  status:         sudo $BIN status"
echo "  restart:        sudo $BIN restart      # clear a wedged SMC by restarting the daemon"
echo "  uninstall:      ./uninstall.sh"
