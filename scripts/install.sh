#!/bin/bash
# Installs the fan control daemon as a system LaunchDaemon.
#
# Requires root because SMC writes do. The daemon is the only privileged piece;
# the menu bar app and fanctl both run as you and talk to it over a socket.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $EUID -ne 0 ]]; then
    echo "This installs a system LaunchDaemon and must run as root:"
    echo "    sudo $0"
    exit 1
fi

LABEL="com.fancontrol.fand"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LIBEXEC="/usr/local/libexec"
BINDIR="/usr/local/bin"
SUPPORT="/Library/Application Support/FanControl"
LOG="/var/log/fancontrol.log"

echo "==> Building (release)"
# Build as the invoking user so SPM's caches don't end up root-owned.
REAL_USER="${SUDO_USER:-$(whoami)}"
sudo -u "$REAL_USER" swift build -c release
BIN_PATH="$(sudo -u "$REAL_USER" swift build -c release --show-bin-path)"

echo "==> Stopping any running instance"
# bootout sends SIGTERM, which makes fand restore the fans before exiting.
launchctl bootout "system/${LABEL}" 2>/dev/null || true
sleep 1

echo "==> Installing binaries"
mkdir -p "$LIBEXEC" "$BINDIR" "$SUPPORT"
install -m 755 -o root -g wheel "$BIN_PATH/fand"   "$LIBEXEC/fand"
install -m 755 -o root -g wheel "$BIN_PATH/fanctl" "$BINDIR/fanctl"
chmod 755 "$SUPPORT"

echo "==> Writing $PLIST"
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

echo "==> Starting daemon"
launchctl bootstrap system "$PLIST"
launchctl enable "system/${LABEL}"
sleep 2

if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "==> Daemon is running"
else
    echo "!! Daemon did not start. Check $LOG"
    exit 1
fi

echo
echo "Installed."
echo "  fanctl status          check it works"
echo "  fanctl watch           live view"
echo "  tail -f $LOG           daemon log"
echo
echo "Build and install the menu bar app with:"
echo "  ./scripts/build-app.sh && cp -R build/FanControl.app /Applications/"
