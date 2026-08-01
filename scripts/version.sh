#!/bin/bash
# Single source of truth for what a build calls itself. Sourced, not run.
#
# Exports VERSION, COMMIT, COMMIT_DATE, BUILD_NUMBER and SOURCE_ROOT. Every
# value degrades to something honest outside a git checkout — a build from a
# downloaded tarball should say "unknown", not lie about a commit.

VERSION="0.1.0"

_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Assert rather than trust. Without BASH_SOURCE — sourced from zsh, say — the
# line above silently resolves to the caller's parent directory, and every
# value below comes out plausible and wrong: a bogus source root stamped into
# the app's Info.plist breaks its Update button, and nobody finds out until
# they press it.
if [[ ! -f "$_root/Package.swift" ]]; then
    printf 'version.sh: resolved %s, which is not the fan-control checkout.\n' "$_root" >&2
    printf '            It must be sourced from a bash script in scripts/.\n' >&2
    return 1 2>/dev/null || exit 1
fi

SOURCE_ROOT="$_root"

# `install.sh` sources this as root against a checkout owned by the invoking
# user, which trips git's dubious-ownership guard. Waiving it is safe for the
# read-only queries below — none of them run a hook — and the same script
# already builds and installs binaries out of this directory, so the repo is
# trusted by the time we get here.
_git() { git -c safe.directory='*' -C "$_root" "$@"; }

if _git rev-parse --git-dir >/dev/null 2>&1; then
    COMMIT="$(_git rev-parse --short=9 HEAD)"
    COMMIT_DATE="$(_git log -1 --format=%cd --date=short)"
    # CFBundleVersion has to increase for macOS to regard a bundle as newer,
    # and a hash does not order. The commit count does. A --depth 1 clone —
    # what the installer makes — counts from where it was cut rather than from
    # the true root, which is fine: it only ever has to increase on this
    # machine, and it does.
    BUILD_NUMBER="$(_git rev-list --count HEAD)"
    # A build with edits on top is not the commit it claims to be.
    if ! _git diff --quiet || ! _git diff --cached --quiet; then
        COMMIT="${COMMIT}+"
    fi
else
    COMMIT="unknown"
    COMMIT_DATE="unknown"
    BUILD_NUMBER="0"
fi

unset _root
