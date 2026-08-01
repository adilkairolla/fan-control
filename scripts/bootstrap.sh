#!/bin/bash
# One-command install, for people who have not cloned the repo yet:
#
#   curl -fsSL https://raw.githubusercontent.com/adilkairolla/fan-control/main/scripts/bootstrap.sh | bash
#
# Clones (or updates) into ~/.fan-control, builds from source, and hands off to
# `make up`. Re-running it is an upgrade. Nothing here needs root; `make up`
# asks for your password once, only if the privileged fan-control helper is
# missing or stale.
#
# Every check below runs before the clone, so an unsupported machine finds out
# in under a second rather than a minute into a build.
set -euo pipefail

REPO_URL="https://github.com/adilkairolla/fan-control.git"
REPO_WEB="https://github.com/adilkairolla/fan-control"
DEST="${FAN_CONTROL_DIR:-$HOME/.fan-control}"

# ---------------------------------------------------------------- output
#
# Fetched over curl and piped into bash, so ui.sh is not on disk yet. These are
# the same shapes ui.sh uses; once the clone lands, `make up` uses the real one.

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Z=$'\033[0m'
else
    B=""; D=""; R=""; G=""; Z=""
fi

step() { printf '\n%s%s%s\n' "$B" "$1" "$Z"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
info() { printf '  %s·%s %s\n' "$D" "$Z" "$1"; }

die() {
    printf '\n%s%s✗ %s%s\n' "$B" "$R" "$1" "$Z" >&2
    [[ -n "${2:-}" ]] && { printf '\n' >&2; printf '%s\n' "$2" | sed 's/^/  /' >&2; }
    printf '\n' >&2
    exit 1
}

printf '\n%sFan Control%s %s— fan control and monitoring for Apple Silicon Macs%s\n' \
    "$B" "$Z" "$D" "$Z"

# ------------------------------------------------------------- the machine

step "Checking this Mac"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only." "This is $(uname -s)."

# `uname -m` reports the *process* architecture, so a terminal opened under
# Rosetta says x86_64 on hardware that is plainly Apple Silicon. Ask about the
# hardware instead, then deal with the translated shell separately — the two
# failures need completely different advice.
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]]; then
    die "Apple Silicon only." "\
The SMC keys this reads and writes differ on Intel Macs, and guessing at them
is how you end up with fans that do not spin.

Macs Fan Control supports Intel hardware:
  https://crystalidea.com/macs-fan-control"
fi

if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]]; then
    die "This terminal is running under Rosetta." "\
The build would produce Intel binaries for an Apple Silicon Mac.

Open a native terminal, or re-run under:
  arch -arm64 zsh

Terminal.app remembers this per-app: Get Info → uncheck \"Open using Rosetta\"."
fi

_os="$(sw_vers -productVersion)"
(( ${_os%%.*} >= 14 )) \
    || die "macOS 14 or newer required." "This is macOS ${_os}."
ok "macOS ${_os} on Apple Silicon"

[[ $EUID -ne 0 ]] || die "Do not run this with sudo." "\
Only the fan-control helper needs root, and the installer asks for that on its
own. Building as root leaves root-owned caches in your home directory.

  curl -fsSL ${REPO_WEB}/raw/main/scripts/bootstrap.sh | bash"

# --------------------------------------------------------------- the tools

# /usr/bin/swift is one of ~78 hard links to the same xcrun stub and exists
# whether or not a toolchain sits behind it, so `command -v swift` always
# passes. Without the tools the real failure arrives a minute into the build as
# "xcrun: error: invalid active developer path". Ask the toolchain itself.
if ! xcode-select -p >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
    die "The Command Line Tools are not installed." "\
  xcode-select --install

That opens a system dialog; it takes a few minutes. Then run this again.
Xcode itself is not required."
fi
ok "Swift toolchain ready"

command -v git >/dev/null 2>&1 \
    || die "git not found." "It ships with the Command Line Tools:
  xcode-select --install"

# ------------------------------------------------------------- the checkout

step "Source"

if [[ -e "$DEST" && ! -d "$DEST/.git" ]]; then
    die "$DEST exists but is not a git checkout." "\
Move it aside and run this again:
  mv $DEST ${DEST}.bak

Or install somewhere else:
  FAN_CONTROL_DIR=~/src/fan-control curl -fsSL ${REPO_WEB}/raw/main/scripts/bootstrap.sh | bash"
fi

if [[ -d "$DEST/.git" ]]; then
    # A checkout pointed at someone's fork is almost certainly deliberate.
    # Updating it from upstream anyway would quietly discard that choice.
    _origin="$(git -C "$DEST" remote get-url origin 2>/dev/null || echo "")"
    if [[ -n "$_origin" && "${_origin%.git}" != "${REPO_URL%.git}" ]]; then
        die "$DEST tracks a different repository." "\
  origin: ${_origin}
  this:   ${REPO_URL}

Update that checkout on its own terms:
  make -C $DEST up

Or install this one elsewhere:
  FAN_CONTROL_DIR=~/src/fan-control curl -fsSL ${REPO_WEB}/raw/main/scripts/bootstrap.sh | bash"
    fi

    if ! git -C "$DEST" diff --quiet || ! git -C "$DEST" diff --cached --quiet; then
        die "$DEST has uncommitted changes." "\
Updating would either fail or strand your edits, so nothing has been touched.

  Keep them:     git -C $DEST stash
  Discard them:  git -C $DEST checkout .

Then run this again."
    fi

    info "updating $DEST"
    if ! git -C "$DEST" pull --ff-only --quiet 2>/dev/null; then
        die "Could not fast-forward $DEST." "\
Usually this means local commits, or no network.

  git -C $DEST status
  git -C $DEST log --oneline -3"
    fi
    ok "up to date at $(git -C "$DEST" rev-parse --short=9 HEAD)"
else
    info "cloning into $DEST"
    if ! git clone --depth 1 --quiet "$REPO_URL" "$DEST" 2>/dev/null; then
        die "Could not clone $REPO_URL." "\
Check that you are online, then run this again. If you are behind a proxy,
git needs to know about it:
  git config --global http.proxy http://your-proxy:port"
    fi
    ok "cloned at $(git -C "$DEST" rev-parse --short=9 HEAD)"
fi

# The rest of the flow — build, helper, app, login item — belongs to `make up`,
# which is idempotent and is also what an update runs. One code path.
exec make -C "$DEST" up
