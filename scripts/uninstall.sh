#!/bin/bash
# Removes the daemon and hands the fans back to the system controller.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root:  sudo $0"
    exit 1
fi

LABEL="com.fancontrol.fand"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

echo "==> Stopping daemon (this restores fans to auto)"
launchctl bootout "system/${LABEL}" 2>/dev/null || true
sleep 1

echo "==> Removing files"
rm -f "$PLIST"
rm -f /usr/local/libexec/fand
rm -f /usr/local/bin/fanctl
rm -f /var/run/fancontrold.sock

echo
echo "Removed. Config and history were left in place:"
echo "  /Library/Application Support/FanControl"
echo "Delete that directory too if you want a clean slate."
echo
echo "If /Applications/FanControl.app is installed, quit and delete it as well."
