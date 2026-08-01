#!/bin/bash
# Stops everything up.sh started and removes the login item.
#
# Leaves the daemon *installed* but stopped — stopping it restores the fans to
# Apple's controller, which is the important part. Use scripts/uninstall.sh to
# remove it from disk entirely.
set -euo pipefail

LABEL="com.fancontrol.fand"
AGENT_LABEL="com.fancontrol.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }

step "Login item"
launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
rm -f "$AGENT_PLIST"
ok "removed"

step "Menu bar app"
pkill -x FanControl 2>/dev/null || true
ok "stopped"

step "Fan control helper"
# bootout sends SIGTERM, which is what makes fand hand the fans back.
sudo launchctl bootout "system/${LABEL}" 2>/dev/null || true
sleep 1
ok "stopped — fans returned to the system controller"

echo
echo "Bring it all back with:  make up"
echo "Remove the helper from disk:  sudo ./scripts/uninstall.sh"
