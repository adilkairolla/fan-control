#!/bin/bash
# Shared terminal output. Sourced by every script here; never run directly.
#
# Three ideas run through it:
#
#   Quiet on success, loud on failure. A build prints one line and a duration
#   when it works, and its full output only when it does not. Scrolling a
#   thousand lines of successful compiler chatter hides the one line that
#   matters when something breaks.
#
#   Every error says what to do next. A failure that only states what went
#   wrong leaves the reader to guess the remedy, and the remedy is the thing
#   the author already knows.
#
#   Degrade honestly. No colour when the output is not a terminal, when
#   NO_COLOR is set, or when TERM is dumb; no spinner unless someone is there
#   to watch it animate. Piping any of these scripts into a file should produce
#   a clean transcript, not a screenful of escape sequences.

# Guard against double-sourcing — up.sh is invoked from update.sh via make.
[[ -n "${UI_SOURCED:-}" ]] && return 0
UI_SOURCED=1

# ---------------------------------------------------------------- capability

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    UI_TTY=1
    UI_BOLD=$'\033[1m'; UI_DIM=$'\033[2m'
    UI_RED=$'\033[31m'; UI_GREEN=$'\033[32m'; UI_YELLOW=$'\033[33m'
    UI_BLUE=$'\033[34m'; UI_RESET=$'\033[0m'
else
    UI_TTY=0
    UI_BOLD=""; UI_DIM=""
    UI_RED=""; UI_GREEN=""; UI_YELLOW=""; UI_BLUE=""; UI_RESET=""
fi

UI_WIDTH=$( [[ $UI_TTY == 1 ]] && tput cols 2>/dev/null || echo 80 )
(( UI_WIDTH >= 40 )) || UI_WIDTH=80

# ------------------------------------------------------------------ cleanup
#
# One EXIT trap lives here. Scripts add their own work with `ui_at_exit`
# instead of installing a second trap, because the last `trap ... EXIT` wins
# and silently discards the first — which is how a lock file outlives the
# process holding it.

UI_EXIT_HOOKS=()
UI_SPINNER_PID=""

ui_at_exit() { UI_EXIT_HOOKS+=("$1"); }

_ui_on_exit() {
    local status=$?
    _ui_spinner_stop
    local hook
    for hook in "${UI_EXIT_HOOKS[@]:-}"; do
        [[ -n "$hook" ]] && eval "$hook" || true
    done
    # Leave the cursor visible whatever happened.
    (( UI_TTY )) && printf '\033[?25h'
    return $status
}
trap _ui_on_exit EXIT

_ui_on_interrupt() {
    _ui_spinner_stop
    printf '\n%s  interrupted%s — nothing further was changed.\n' \
        "$UI_YELLOW" "$UI_RESET"
    exit 130
}
trap _ui_on_interrupt INT TERM

# -------------------------------------------------------------------- lines

# A blank line before every heading, except the first — so a transcript has
# rhythm without opening on an empty line.
UI_FIRST_STEP=1

step() {
    (( UI_FIRST_STEP )) || printf '\n'
    UI_FIRST_STEP=0
    printf '%s%s%s\n' "$UI_BOLD" "$1" "$UI_RESET"
}

ok()   { printf '  %s✓%s %s\n' "$UI_GREEN"  "$UI_RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$UI_YELLOW" "$UI_RESET" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$UI_RED"    "$UI_RESET" "$1"; }
info() { printf '  %s·%s %s\n' "$UI_DIM"    "$UI_RESET" "$1"; }
note() { printf '    %s%s%s\n' "$UI_DIM" "$1" "$UI_RESET"; }

# A status line with a dim trailing fact — a duration, a reason, a path.
# Parenthesised rather than merely dimmed, because dim is the first thing to
# vanish when the output is not a terminal and "Building 12s" then reads as a
# sentence rather than a measurement.
detail() {
    printf '  %s%s%s %s %s(%s)%s\n' \
        "$2" "$1" "$UI_RESET" "$3" "$UI_DIM" "$4" "$UI_RESET"
}

# ------------------------------------------------------------------- errors
#
# die "one-line summary" "what to do about it, possibly several lines"

die() {
    _ui_spinner_stop
    printf '\n%s%s✗ %s%s\n' "$UI_BOLD" "$UI_RED" "$1" "$UI_RESET" >&2
    if [[ -n "${2:-}" ]]; then
        printf '\n' >&2
        printf '%s\n' "$2" | sed 's/^/  /' >&2
    fi
    printf '\n' >&2
    exit 1
}

# Unexpected failures — a command nobody wrapped, under `set -e`. Without this
# the script simply stops, and the reader is left with a half-finished
# transcript and no idea which line gave up.
_ui_on_error() {
    local status=$1 line=$2 command=$3
    _ui_spinner_stop
    printf '\n%s%s✗ Unexpected failure%s\n\n' "$UI_BOLD" "$UI_RED" "$UI_RESET" >&2
    printf '  %s line %s exited %s:\n' "${BASH_SOURCE[1]##*/}" "$line" "$status" >&2
    printf '  %s%s%s\n\n' "$UI_DIM" "$command" "$UI_RESET" >&2
    printf '  This is a bug in the installer rather than something you did.\n' >&2
    printf '  Please report it: https://github.com/adilkairolla/fan-control/issues\n\n' >&2
    exit "$status"
}
ui_trap_errors() { trap '_ui_on_error $? $LINENO "$BASH_COMMAND"' ERR; }

# ------------------------------------------------------------------ spinner

_UI_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

_ui_spinner_start() {
    (( UI_TTY )) || return 0
    printf '\033[?25l'                       # hide the cursor
    (
        local i=0 frame
        while :; do
            frame="${_UI_FRAMES:i%10:1}"
            printf '\r  %s%s%s %s' "$UI_BLUE" "$frame" "$UI_RESET" "$1"
            i=$(( i + 1 ))
            sleep 0.08
        done
    ) &
    UI_SPINNER_PID=$!
    # Keep the job out of the shell's notification messages.
    disown "$UI_SPINNER_PID" 2>/dev/null || true
}

_ui_spinner_stop() {
    [[ -n "$UI_SPINNER_PID" ]] || return 0
    kill "$UI_SPINNER_PID" 2>/dev/null || true
    wait "$UI_SPINNER_PID" 2>/dev/null || true
    UI_SPINNER_PID=""
    (( UI_TTY )) && printf '\r\033[K\033[?25h'
    return 0
}

# ---------------------------------------------------------------------- run
#
#   run "Building" swift build -c release
#
# Captures output, animates while it works, prints one line when it is done.
# On failure the captured output is printed and the caller gets the exit
# status — it decides whether that is fatal.

UI_LAST_LOG=""

run() {
    local label="$1"; shift
    local log start status elapsed
    log="$(mktemp -t fancontrol-step)"
    UI_LAST_LOG="$log"
    start=$SECONDS

    # No progress line when there is no terminal: the result line carries the
    # label and the duration, so announcing the same label first only doubles
    # every entry in the transcript someone is redirecting this into.
    (( UI_TTY )) && _ui_spinner_start "$label"

    status=0
    "$@" >"$log" 2>&1 || status=$?

    _ui_spinner_stop
    elapsed=$(( SECONDS - start ))

    if (( status == 0 )); then
        # Only show a duration once it is long enough for the reader to have
        # noticed the wait; on everything else it is noise.
        if (( elapsed >= 2 )); then
            detail "✓" "$UI_GREEN" "$label" "${elapsed}s"
        else
            ok "$label"
        fi
        rm -f "$log"
        UI_LAST_LOG=""
        return 0
    fi

    detail "✗" "$UI_RED" "$label" "exit $status after ${elapsed}s"
    return "$status"
}

# The tail of the last failed `run`, indented under a heading. Truncated,
# because a Swift compile error can run to hundreds of lines and the first
# screenful is the part that says what is wrong.
ui_show_log() {
    local lines="${1:-40}"
    [[ -n "$UI_LAST_LOG" && -s "$UI_LAST_LOG" ]] || return 0
    local total; total="$(wc -l < "$UI_LAST_LOG" | tr -d ' ')"
    printf '\n'
    if (( total > lines )); then
        note "last $lines of $total lines — full output: $UI_LAST_LOG"
    fi
    printf '\n'
    tail -n "$lines" "$UI_LAST_LOG" | sed 's/^/    /'
    printf '\n'
}

# ------------------------------------------------------------------ closing

ui_rule() {
    printf '%s' "$UI_DIM"
    printf '─%.0s' $(seq 1 $(( UI_WIDTH > 72 ? 72 : UI_WIDTH )))
    printf '%s\n' "$UI_RESET"
}

ui_done() {
    printf '\n'
    ui_rule
    printf '%s%s%s%s\n' "$UI_BOLD" "$UI_GREEN" "$1" "$UI_RESET"
}
