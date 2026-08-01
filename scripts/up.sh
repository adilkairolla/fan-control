#!/bin/bash
# One command to bring the whole thing up: daemon, app, login item.
#
# Idempotent — safe to re-run after any code change. It reinstalls only the
# pieces that are actually stale, so the common case is fast and needs no
# password at all.
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.fancontrol.fand"
AGENT_LABEL="com.fancontrol.app"
HELPER="/usr/local/libexec/fand"
CLI="/usr/local/bin/fanctl"
APP_SRC="build/FanControl.app"
APP_DST="/Applications/FanControl.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"

if [[ $EUID -eq 0 ]]; then
    echo "Run this as yourself, not with sudo — it will ask for a password only"
    echo "if the privileged helper actually needs installing."
    exit 1
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '      %s\n' "$1"; }

# ---------------------------------------------------------------- build
step "Building"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
ok "binaries built"

# ------------------------------------------------------- daemon (root)
step "Fan control helper"

needs_install=0
reason=""
if [[ ! -x "$HELPER" ]]; then
    needs_install=1; reason="not installed yet"
elif ! cmp -s "$BIN_PATH/fand" "$HELPER"; then
    needs_install=1; reason="binary changed since last install"
elif ! sudo -n launchctl print "system/${LABEL}" >/dev/null 2>&1 \
     && ! launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    needs_install=1; reason="installed but not running"
fi

if (( needs_install )); then
    info "$reason — installing (needs your password once)"
    sudo ./scripts/install.sh >/dev/null
    ok "helper installed and running"
else
    ok "helper already current and running"
fi

# ------------------------------------------------------------- the app
step "Menu bar app"
./scripts/build-app.sh >/dev/null
ok "bundle assembled"

pkill -x FanControl 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
ok "installed to $APP_DST"

# --------------------------------------------------------- login item
# The daemon already starts at boot via RunAtLoad. A menu bar app that
# disappeared on reboot while its daemon kept running would be worse than
# either extreme, so register a matching LaunchAgent. No sudo: this is a
# per-user agent.
step "Start at login"
mkdir -p "$(dirname "$AGENT_PLIST")"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_DST}/Contents/MacOS/FanControl</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
ok "will relaunch after reboot  (undo with: make down)"

# ------------------------------------------------------------- launch
step "Launching"
open "$APP_DST"
sleep 2

if pgrep -x FanControl >/dev/null; then
    ok "app running"
else
    printf '    \033[31m✗\033[0m app did not stay running\n'
fi

# -------------------------------------------------------------- verify
step "Status"
if [[ -x "$CLI" ]]; then
    if "$CLI" status 2>/dev/null; then
        :
    else
        printf '    \033[33m!\033[0m daemon not answering yet — check /var/log/fancontrol.log\n'
    fi
fi

cat <<'DONE'

Everything is up.

  menu bar          temperature and fan speed, click for controls
  ⌥⌘F               open the dashboard
  fanctl watch      live view in the terminal
  fanctl profile Silent
  fanctl auto       hand the fans back to macOS

  make down         stop everything and remove the login item
DONE
