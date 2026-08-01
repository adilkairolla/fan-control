#!/bin/bash
# Installs the fan control daemon as a system LaunchDaemon.
#
# Requires root because SMC writes do. The daemon is the only privileged piece;
# the menu bar app and fanctl both run as you and talk to it over a socket.
set -euo pipefail

cd "$(dirname "$0")/.."
. ./scripts/ui.sh
ui_trap_errors

if [[ $EUID -ne 0 ]]; then
    die "This installs a system LaunchDaemon and must run as root." "\
Only SMC *writes* need privileges, which is why this one piece is separate
from everything else.

  sudo $0

Or let the installer decide whether it is even needed:
  make up"
fi

LABEL="com.fancontrol.fand"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LIBEXEC="/usr/local/libexec"
BINDIR="/usr/local/bin"
SUPPORT="/Library/Application Support/FanControl"
LOG="/var/log/fancontrol.log"

step "Helper"

# Build as the invoking user so SPM's caches don't end up root-owned — a
# root-owned .build directory breaks every subsequent ordinary build, and the
# error it produces points nowhere near this line.
REAL_USER="${SUDO_USER:-$(whoami)}"
if ! run "Compiling" sudo -u "$REAL_USER" swift build -c release; then
    ui_show_log 30
    die "The helper did not build." "Nothing has been installed or stopped."
fi
BIN_PATH="$(sudo -u "$REAL_USER" swift build -c release --show-bin-path)"

# bootout sends SIGTERM, which makes fand restore the fans before exiting.
# From here until the daemon is back up, the fans are Apple's again — which is
# the safe direction to fail in.
launchctl bootout "system/${LABEL}" 2>/dev/null || true
sleep 1

mkdir -p "$LIBEXEC" "$BINDIR" "$SUPPORT"
install -m 755 -o root -g wheel "$BIN_PATH/fand"   "$LIBEXEC/fand"
install -m 755 -o root -g wheel "$BIN_PATH/fanctl" "$BINDIR/fanctl"
chmod 755 "$SUPPORT"

# What these two binaries are, recorded where an unprivileged `fanctl version`
# can read it. Separate from the app's own stamp on purpose: when the two
# disagree, one half of the install is stale and that is worth being able to see.
# shellcheck source=version.sh
. "$(dirname "$0")/version.sh"
cat > "$SUPPORT/version.json" <<JSON
{
  "version": "${VERSION}",
  "commit": "${COMMIT}",
  "date": "${COMMIT_DATE}",
  "sourceRoot": "${SOURCE_ROOT}"
}
JSON
chmod 644 "$SUPPORT/version.json"

ok "binaries installed"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${LIBEXEC}/fand</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- If the daemon dies while holding the fans in manual, restarting it is
         what returns them to a known state. This is a safety property, not a
         convenience. -->
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

if ! launchctl bootstrap system "$PLIST" 2>/dev/null; then
    die "launchd refused to load the daemon." "\
  sudo launchctl print system/${LABEL}
  tail -20 $LOG

The fans are back under Apple's control either way — bootout restores them
before the old daemon exits."
fi
launchctl enable "system/${LABEL}" 2>/dev/null || true

_up=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if launchctl print "system/${LABEL}" >/dev/null 2>&1; then _up=1; break; fi
    sleep 0.4
done

if (( _up )); then
    ok "daemon running"
else
    die "The daemon did not stay running." "\
launchd loaded it and it exited. The log says why:

  tail -20 $LOG

Your fans are under Apple's control, not stuck at whatever the last
commanded speed was — fand restores them on the way out."
fi
