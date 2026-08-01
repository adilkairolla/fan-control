#!/bin/bash
# Stops everything up.sh started and removes the login item.
#
# Leaves the daemon *installed* but stopped — stopping it restores the fans to
# Apple's controller, which is the important part. Use scripts/uninstall.sh to
# remove it from disk entirely.
set -euo pipefail

cd "$(dirname "$0")/.."
. ./scripts/ui.sh
ui_trap_errors

LABEL="com.fancontrol.fand"
AGENT_LABEL="com.fancontrol.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"

step "Stopping Fan Control"

launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
rm -f "$AGENT_PLIST"
ok "login item removed"

pkill -x FanControl 2>/dev/null || true
ok "menu bar app stopped"

# The one step that matters. bootout sends SIGTERM, and fand's signal handler
# is what hands the fans back — the SMC has no deadman timer, so a daemon that
# died without doing this would leave them pinned at the last commanded speed
# indefinitely.
if [[ -x /usr/local/libexec/fand ]]; then
    if ! sudo -n true 2>/dev/null; then
        if ! { : 2>/dev/null </dev/tty; }; then
            die "Stopping the helper needs a password, and there is no terminal." "\
Run this from an interactive shell, or stop it directly:

  sudo launchctl bootout system/${LABEL}"
        fi
        note "stopping the helper needs your password"
        sudo -v || die "Password not accepted — the helper is still running." "\
Your fans are still under its control. Try again:

  make down"
    fi
    sudo launchctl bootout "system/${LABEL}" 2>/dev/null || true

    _stopped=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x fand >/dev/null 2>&1; then _stopped=1; break; fi
        sleep 0.3
    done

    if (( _stopped )); then
        ok "helper stopped — fans returned to macOS"
    else
        warn "the helper is still running"
        note "it has KeepAlive set, so launchd may be restarting it:"
        note "sudo launchctl print system/${LABEL}"
    fi
else
    info "no helper installed"
fi

ui_done "Stopped. Your fans are Apple's again."
cat <<DONE

  make up                        bring it all back
  sudo ./scripts/uninstall.sh    remove the helper from disk too
DONE
