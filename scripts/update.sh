#!/bin/bash
# Update an existing install in place: pull the source, rebuild, reinstall
# whatever actually changed.
#
#   ./scripts/update.sh            pull and reinstall
#   ./scripts/update.sh --check    say what an update would bring, change nothing
#
# There is no download to verify and no signature to check because there is no
# binary release — this project builds from source, so an update is a fast
# forward of the checkout it was built from. `make up` then reinstalls only the
# stale pieces, which is why the common case needs no password.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

. ./scripts/ui.sh
ui_trap_errors

CHECK_ONLY=0
case "${1:-}" in
    "")        ;;
    --check)   CHECK_ONLY=1 ;;
    -h|--help) printf 'usage: %s [--check]\n' "${0##*/}"; exit 0 ;;
    *)         die "Unknown option: $1" "usage: ${0##*/} [--check]" ;;
esac

BOOTSTRAP="curl -fsSL https://raw.githubusercontent.com/adilkairolla/fan-control/main/scripts/bootstrap.sh | bash"

# ------------------------------------------------------------- preflight

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die \
    "$ROOT is not a git checkout." "\
There is nothing to pull. Reinstall from scratch instead:

  $BOOTSTRAP"

git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || die \
    "This checkout has no 'origin' remote." "\
Point it at one, then try again:

  git -C $ROOT remote add origin https://github.com/adilkairolla/fan-control.git"

# A fast-forward into a dirty tree either fails or silently strands the edits.
# Better to stop before touching anything than to half-apply an update.
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
    die "You have uncommitted changes in $ROOT." "\
Nothing has been touched.

  See them:      git -C $ROOT status
  Keep them:     git -C $ROOT stash
  Discard them:  git -C $ROOT checkout .

Then run this again."
fi

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" != "HEAD" ]] || die "This checkout is on a detached HEAD." "\
Updates fast-forward a branch, and there is no branch here to move.

  git -C $ROOT checkout main"

# Prefer the configured upstream; a --depth 1 clone from bootstrap.sh has one.
UPSTREAM="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null \
            || echo "origin/$BRANCH")"

# One updater at a time. Double-clicking the app's Update button is easy —
# Terminal takes a moment to appear, so the first click looks like nothing
# happened — and two concurrent `make up` runs race on /Applications and on
# launchctl. mkdir is the atomic primitive here; macOS ships no flock(1).
LOCK="${TMPDIR:-/tmp}/fan-control-update.lock"
mkdir "$LOCK" 2>/dev/null || die "Another update is already running." "\
Wait for it to finish.

If that is wrong — a previous run was interrupted — clear the lock:
  rmdir $LOCK"
ui_at_exit "rmdir '$LOCK' 2>/dev/null || true"

# ----------------------------------------------------------------- fetch

step "Checking for updates"
info "$UPSTREAM"

if ! run "Fetching" git -C "$ROOT" fetch --quiet origin "$BRANCH"; then
    ui_show_log 10
    die "Could not reach the remote." "\
Usually this just means you are offline. Nothing has changed; try again when
you have a connection.

Your current install keeps working — it does not need the network."
fi

LOCAL="$(git -C "$ROOT" rev-parse HEAD)"
REMOTE="$(git -C "$ROOT" rev-parse "$UPSTREAM")"

if [[ "$LOCAL" == "$REMOTE" ]]; then
    ok "already up to date"
    note "$(git -C "$ROOT" rev-parse --short=9 HEAD) · $(git -C "$ROOT" log -1 --format=%cd --date=short)"
    printf '\n'
    exit 0
fi

# Ahead of the remote, or diverged — someone is developing here, not consuming.
if [[ "$(git -C "$ROOT" merge-base "$LOCAL" "$REMOTE")" != "$LOCAL" ]]; then
    die "$ROOT has local commits that $UPSTREAM does not." "\
This updater only fast-forwards. Merging or rebasing your own work is your
call to make, not a script's.

  git -C $ROOT log --oneline $UPSTREAM..HEAD
  git -C $ROOT rebase $UPSTREAM"
fi

COUNT="$(git -C "$ROOT" rev-list --count "HEAD..$UPSTREAM")"
ok "$COUNT new commit$( (( COUNT == 1 )) || printf s )"
printf '\n'
# Explicitly follow ui.sh's decision rather than git's own isatty check — git
# is writing into a pipe here, so `auto` would strip colour that the terminal
# on the other end can render, and `always` would leak escapes into a redirect.
_color=$( (( UI_TTY )) && echo always || echo never )
git -C "$ROOT" log --no-decorate --color="$_color" \
    --format="    %C(dim)%h%Creset  %s" "HEAD..$UPSTREAM" | head -20
(( COUNT > 20 )) && note "… and $(( COUNT - 20 )) more"

if (( CHECK_ONLY )); then
    printf '\n'
    note "run without --check to apply"
    printf '\n'
    exit 0
fi

# ------------------------------------------------------------------ pull

step "Updating source"
if ! run "Fast-forwarding" git -C "$ROOT" merge --ff-only "$UPSTREAM" --quiet; then
    ui_show_log 15
    die "The fast-forward failed." "\
Nothing was installed and your current install still works.

  git -C $ROOT status"
fi
ok "now at $(git -C "$ROOT" rev-parse --short=9 HEAD)"

# `up.sh` is idempotent and reinstalls only what is stale, so it is both the
# installer and the second half of the updater.
#
# Deliberately not `exec`: the lock has to outlive the build, and exec would
# replace this shell before ui.sh's EXIT trap could release it — leaving a
# lock directory that blocks every future update.
#
# A note for whoever changes the merge above. Bash reads a script incrementally
# and seeks back into the file between commands, so a script that rewrites
# itself mid-run resumes at a byte offset that now points at unrelated text —
# verified: it re-executes earlier lines and chokes on fragments. This script
# survives updating itself only because git never writes in place; it builds
# the new file and renames it over the old, so the fd bash is holding still
# refers to the original inode. Anything here that edits update.sh in place
# (sed -i, a patch step) would break that and needs to re-exec from a copy.
if ! make -C "$ROOT" up; then
    status=$?
    die "The source updated, but the rebuild did not finish." "\
You are now on $(git -C "$ROOT" rev-parse --short=9 HEAD), and the previously
installed app and helper are still the ones running — an unfinished build
replaces nothing.

Fix whatever the output above reports, then:
  make -C $ROOT up

Or go back to the previous commit:
  git -C $ROOT reset --hard HEAD~1 && make -C $ROOT up"
    exit $status
fi
