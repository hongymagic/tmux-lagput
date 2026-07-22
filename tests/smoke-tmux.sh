#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMUX_BINARY="${1:-$(command -v tmux 2>/dev/null || true)}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tmux-send-later-smoke.XXXXXX")"
SOCKET_NAME="tmux-send-later-smoke-$$-${RANDOM:-0}"
STATE_DIR="$TEST_ROOT/state"
CAPTURE_FILE="$TEST_ROOT/captured.txt"
MARKER="tmux-send-later-smoke-$$-${RANDOM:-0}"

# Invoked through the EXIT trap.
# Older distro releases report trap-only functions as SC2317; newer releases
# use SC2329 for the same indirect invocation.
# shellcheck disable=SC2317,SC2329
cleanup() {
    if [ -x "$TMUX_BINARY" ]; then
        "$TMUX_BINARY" -L "$SOCKET_NAME" kill-server >/dev/null 2>&1 || true
    fi
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}/tmux-send-later-smoke."*) rm -rf -- "$TEST_ROOT" ;;
    esac
}

fail() {
    printf 'tmux smoke test failed: %s\n' "$1" >&2
    exit 1
}

shell_quote() {
    local value="$1"
    value="${value//\'/\'\\\'\'}"
    printf "'%s'" "$value"
}

trap cleanup EXIT

[ -x "$TMUX_BINARY" ] || fail 'tmux executable not found'
tmux_directory="$(dirname "$TMUX_BINARY")"
export PATH="$tmux_directory:$PATH"

pane_command="exec cat > $(shell_quote "$CAPTURE_FILE")"
"$TMUX_BINARY" -L "$SOCKET_NAME" -f /dev/null new-session -d \
    -s send-later -x 100 -y 30 "$pane_command"
"$TMUX_BINARY" -L "$SOCKET_NAME" run-shell "$ROOT_DIR/tmux-send-later.tmux"

key_descriptions="$("$TMUX_BINARY" -L "$SOCKET_NAME" list-keys -N)"
case "$key_descriptions" in
    *'Schedule pane input for later'*) ;;
    *) fail 'schedule binding description is missing' ;;
esac
case "$key_descriptions" in
    *'Manage pending pane input'*) ;;
    *) fail 'manage binding description is missing' ;;
esac

pane_id="$("$TMUX_BINARY" -L "$SOCKET_NAME" display-message -p -t 'send-later:0.0' '#{pane_id}')"
display_target="$("$TMUX_BINARY" -L "$SOCKET_NAME" display-message -p -t "$pane_id" '#{session_name}:#{window_index}.#{pane_index}')"
socket_path="$("$TMUX_BINARY" -L "$SOCKET_NAME" display-message -p '#{socket_path}')"
server_pid="$("$TMUX_BINARY" -L "$SOCKET_NAME" display-message -p '#{pid}')"

job_id="$(env \
    TMUX="$socket_path,$server_pid,0" \
    TMUX_SEND_LATER_STATE_DIR="$STATE_DIR" \
    "$ROOT_DIR/scripts/schedule-job.sh" schedule \
        --target "$pane_id" \
        --display-target "$display_target" \
        --text "$MARKER" \
        --key Enter \
        --delay 1)" || fail 'scheduler rejected the smoke job'
[ -n "$job_id" ] || fail 'scheduler returned an empty job ID'

attempts=80
while [ "$attempts" -gt 0 ]; do
    captured=''
    if [ -f "$CAPTURE_FILE" ]; then
        IFS= read -r captured < "$CAPTURE_FILE" || true
    fi
    if [ "$captured" = "$MARKER" ] && \
        [ -f "$STATE_DIR/jobs-history.log" ] && \
        rg -F -q -- $'\t'"$job_id"$'\tsent\t' "$STATE_DIR/jobs-history.log"; then
        printf '%s smoke test passed\n' "$("$TMUX_BINARY" -V)"
        exit 0
    fi
    attempts=$((attempts - 1))
    sleep 0.1
done

fail 'the captured pane did not receive the scheduled text'
