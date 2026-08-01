#!/bin/bash
# One command to bring the whole thing up: daemon, app, login item.
#
# Idempotent — safe to re-run after any change. It reinstalls only the pieces
# that are actually stale, so the common case is fast and needs no password at
# all. This is also the second half of every update, which is why it has to be
# safe to run against an install that is already correct.
set -euo pipefail

cd "$(dirname "$0")/.."
. ./scripts/ui.sh
ui_trap_errors

LABEL="com.fancontrol.fand"
AGENT_LABEL="com.fancontrol.app"
HELPER="/usr/local/libexec/fand"
CLI="/usr/local/bin/fanctl"
APP_SRC="build/FanControl.app"
APP_DST="/Applications/FanControl.app"
APP_DIR="/Applications"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"

if [[ $EUID -eq 0 ]]; then
    die "Run this as yourself, not with sudo." "\
It asks for a password only if the privileged helper actually needs
installing. Running the whole build as root leaves root-owned SwiftPM caches
in your home directory, which then break the next ordinary build.

  make up"
fi

# ---------------------------------------------------------------- preflight

step "Checking this Mac"

if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]]; then
    die "Apple Silicon only." "The SMC keys differ on Intel Macs."
fi
_os="$(sw_vers -productVersion)"
(( ${_os%%.*} >= 14 )) || die "macOS 14 or newer required." "This is macOS ${_os}."

if ! xcode-select -p >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
    die "The Command Line Tools are not installed." "  xcode-select --install"
fi
ok "macOS ${_os}, Apple Silicon, Swift toolchain ready"

# Writing the bundle is the one step with no fallback, and finding out after a
# minute of compiling is a poor way to learn the volume is read-only.
if [[ ! -w "$APP_DIR" ]]; then
    die "$APP_DIR is not writable." "\
On a managed Mac this is usually MDM policy. You can still run everything from
the build directory without installing:

  make run"
fi

# ---------------------------------------------------------------- build

step "Building"

if ! run "Compiling Swift packages" swift build -c release; then
    ui_show_log 40
    die "The build failed." "\
The compiler output above says why. If it mentions a missing SDK or an
invalid developer path, the Command Line Tools need reinstalling:

  sudo rm -rf /Library/Developer/CommandLineTools
  xcode-select --install"
fi

BIN_PATH="$(swift build -c release --show-bin-path)"

if ! run "Assembling FanControl.app" ./scripts/build-app.sh; then
    ui_show_log 25
    die "Could not assemble the app bundle." \
        "scripts/build-app.sh failed; its output is above."
fi

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
    info "$reason"

    # Authenticate before the spinner starts. sudo prompts on /dev/tty, so the
    # prompt would otherwise appear underneath an animating progress line —
    # legible enough to be confusing, and easy to miss entirely.
    if ! sudo -n true 2>/dev/null; then
        # /dev/tty, not stdin: under `curl | bash` stdin is the pipe, and
        # testing that would reject the primary install path. sudo reads the
        # password from the terminal device, so that is what has to exist —
        # and when it does not, sudo waits for input that can never arrive.
        # 2>/dev/null first: redirections apply left to right, so putting it
        # after would let the shell's own "/dev/tty: Device not configured"
        # escape to the terminal before it is suppressed.
        if ! { : 2>/dev/null </dev/tty; }; then
            die "The helper needs installing, but there is no terminal to ask on." "\
Run this from an interactive shell, or install the helper separately first:

  sudo $(pwd)/scripts/install.sh

Monitoring needs none of this — only fan control does."
        fi
        note "installing the helper needs your password, once"
        sudo -v || die "Password not accepted, so the helper was not installed." "\
Nothing else has changed — the app was not touched and any running helper is
still running. Monitoring works without the helper; only fan *control* needs
it. Try again with:

  make up"
    fi

    if ! run "Installing privileged helper" sudo ./scripts/install.sh; then
        ui_show_log 30
        die "The helper did not install." "\
Its output is above. Your previous install, if any, is untouched — the daemon
restores the fans to macOS on the way down, so nothing is left holding them.

Check the daemon log for more:
  tail -20 /var/log/fancontrol.log"
    fi
    ok "helper installed and running"
else
    ok "already current and running"
fi

# ------------------------------------------------------------- the app

step "Menu bar app"

# Quitting first: the bundle cannot be replaced underneath a running process
# without leaving a half-copied app behind.
if pgrep -x FanControl >/dev/null 2>&1; then
    pkill -x FanControl 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x FanControl >/dev/null 2>&1 || break
        sleep 0.2
    done
    pgrep -x FanControl >/dev/null 2>&1 && pkill -9 -x FanControl 2>/dev/null || true
fi

rm -rf "$APP_DST"
if ! cp -R "$APP_SRC" "$APP_DST" 2>/dev/null; then
    die "Could not install to $APP_DST." "\
The old copy has already been removed, so finish by hand:
  cp -R $(pwd)/$APP_SRC $APP_DST"
fi
ok "installed to $APP_DST"

# --------------------------------------------------------- login item
# The daemon already starts at boot via RunAtLoad. A menu bar app that
# disappeared on reboot while its daemon kept running would be worse than
# either extreme, so register a matching LaunchAgent. No sudo: this is a
# per-user agent.

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
if launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null; then
    ok "starts at login  ·  undo with make down"
else
    # Not fatal: the app is installed and will be launched below either way.
    warn "could not register the login item — the app still runs, but will not"
    note "come back after a reboot. Try: make down && make up"
fi

# ------------------------------------------------------------- launch

open "$APP_DST"
_running=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if pgrep -x FanControl >/dev/null 2>&1; then _running=1; break; fi
    sleep 0.3
done

if (( _running )); then
    ok "running — look for the temperature in your menu bar"
else
    warn "the app did not stay running"
    note "launch it by hand to see why: $APP_DST/Contents/MacOS/FanControl"
fi

# -------------------------------------------------------------- verify

step "Status"

if [[ -x "$CLI" ]]; then
    _answered=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if "$CLI" status >/dev/null 2>&1; then _answered=1; break; fi
        sleep 0.4
    done
    if (( _answered )); then
        "$CLI" status
    else
        warn "the helper is not answering yet"
        note "it restarts on its own; check with: fanctl status"
        note "or read the log: tail -20 /var/log/fancontrol.log"
    fi
else
    info "monitoring only — fanctl is not installed, so there is no helper"
    note "run make up again to install it"
fi

ui_done "Everything is up."
cat <<DONE

  menu bar        temperature and fan speed, click for controls
  ⌥⌘F             open the dashboard
  fanctl watch    live view in the terminal
  fanctl profile Silent
  fanctl auto     hand the fans back to macOS

  make update     pull the latest source and reinstall
  make down       stop everything and remove the login item
DONE
