#!/bin/bash
# One-command install, for people who have not cloned the repo yet:
#
#   curl -fsSL https://raw.githubusercontent.com/adilkairolla/fan-control/main/scripts/bootstrap.sh | bash
#
# Clones (or updates) into ~/.fan-control, builds from source, and hands off to
# `make up`. Re-running it is an upgrade. Nothing here needs root; `make up`
# asks for your password once, only if the privileged fan-control helper is
# missing or stale.
set -euo pipefail

REPO="https://github.com/adilkairolla/fan-control.git"
DEST="${FAN_CONTROL_DIR:-$HOME/.fan-control}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ "$(uname -m)" == "arm64" ]]  || die "Apple Silicon only — the SMC keys differ on Intel."

# Command Line Tools are enough; Xcode is not required.
command -v swift >/dev/null 2>&1 \
    || die "Swift not found. Install the Command Line Tools:  xcode-select --install"
command -v git >/dev/null 2>&1 \
    || die "git not found. Install the Command Line Tools:  xcode-select --install"

if [[ -d "$DEST/.git" ]]; then
    step "Updating $DEST"
    git -C "$DEST" pull --ff-only
else
    step "Cloning into $DEST"
    git clone --depth 1 "$REPO" "$DEST"
fi

step "Building and installing"
exec make -C "$DEST" up
