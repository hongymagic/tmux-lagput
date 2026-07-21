#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT_DIR/scripts/parse-duration.sh"
SCHEDULER="$ROOT_DIR/scripts/schedule-job.sh"
SCHEDULE_POPUP="$ROOT_DIR/scripts/popup-schedule.sh"
LIST_POPUP="$ROOT_DIR/scripts/popup-list.sh"
PLUGIN_ENTRYPOINT="$ROOT_DIR/tmux-lagput.tmux"
FIXTURES_DIR="$ROOT_DIR/tests/fixtures"
PASSED=0
FAILED=0
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tmux-lagput-test.XXXXXX")"

cleanup() {
    if [[ "$TEST_ROOT" == "${TMPDIR:-/tmp}/tmux-lagput-test."* ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}

trap cleanup EXIT

pass() {
    PASSED=$((PASSED + 1))
    printf 'ok %d - %s\n' "$((PASSED + FAILED))" "$1"
}

fail() {
    FAILED=$((FAILED + 1))
    printf 'not ok %d - %s\n' "$((PASSED + FAILED))" "$1" >&2
    if [ "$#" -gt 1 ]; then
        printf '  %s\n' "$2" >&2
    fi
}

assert_output() {
    local description="$1"
    local expected="$2"
    shift 2

    local actual
    if ! actual="$("$@" 2>/dev/null)"; then
        fail "$description" "command failed"
        return
    fi

    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description" "expected '$expected', got '$actual'"
    fi
}

assert_fails() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        fail "$description" "command unexpectedly succeeded"
    else
        pass "$description"
    fi
}

assert_contains() {
    local description="$1"
    local file="$2"
    local expected="$3"

    if [ -f "$file" ] && rg -F -q -- "$expected" "$file"; then
        pass "$description"
    else
        fail "$description" "'$expected' not found in $file"
    fi
}

assert_not_contains() {
    local description="$1"
    local file="$2"
    local unexpected="$3"

    if [ ! -f "$file" ] || ! rg -F -q -- "$unexpected" "$file"; then
        pass "$description"
    else
        fail "$description" "unexpected '$unexpected' found in $file"
    fi
}

assert_file_exists() {
    local description="$1"
    local file="$2"

    if [ -f "$file" ]; then
        pass "$description"
    else
        fail "$description" "missing file: $file"
    fi
}

wait_for_pattern() {
    local file="$1"
    local pattern="$2"
    local attempts=50

    while [ "$attempts" -gt 0 ]; do
        if [ -f "$file" ] && rg -F -q -- "$pattern" "$file"; then
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 0.1
    done

    return 1
}

read_first_line() {
    local file="$1"
    local value=''
    IFS= read -r value < "$file" || true
    printf '%s' "$value"
}

schedule_test_job() {
    local state_dir="$1"
    local log_file="$2"
    local target_exists="$3"
    local delay="$4"
    local text="$5"

    env \
        PATH="$FIXTURES_DIR:$PATH" \
        TMUX_SEND_DELAYED_STATE_DIR="$state_dir" \
        TMUX_TEST_LOG="$log_file" \
        TMUX_TEST_TARGET_EXISTS="$target_exists" \
        "$SCHEDULER" schedule \
            --target '%42' \
            --display-target 'work:1.0' \
            --text "$text" \
            --key 'Enter' \
            --delay "$delay"
}

printf 'TAP version 13\n'

assert_output 'parses seconds' '90' "$PARSER" '90s'
assert_output 'parses minutes' '1800' "$PARSER" '30m'
assert_output 'parses hours' '18000' "$PARSER" '5h'
assert_output 'parses compound durations' '93600' "$PARSER" '1d2h'
assert_output 'accepts uppercase units' '3723' "$PARSER" '1H2M3S'
assert_fails 'rejects an empty duration' "$PARSER" ''
assert_fails 'rejects a zero duration' "$PARSER" '0s'
assert_fails 'rejects a unitless duration' "$PARSER" '30'
assert_fails 'rejects malformed duration text' "$PARSER" '1h later'

SUCCESS_STATE="$TEST_ROOT/success-state"
SUCCESS_LOG="$TEST_ROOT/success-tmux.log"
SUCCESS_JOB="$(schedule_test_job "$SUCCESS_STATE" "$SUCCESS_LOG" 1 1 'Continue -- safely')"
if wait_for_pattern "$SUCCESS_STATE/jobs-history.log" $'\tsent\t'; then
    pass 'background worker records successful delivery'
else
    fail 'background worker records successful delivery' 'timed out waiting for sent history'
fi
assert_contains 'sends text literally to the captured pane ID' "$SUCCESS_LOG" $'send-keys\t-t\t%42\t-l\t--\tContinue -- safely'
assert_contains 'sends the configured key to the captured pane ID' "$SUCCESS_LOG" $'send-keys\t-t\t%42\tEnter'
if [ ! -d "$SUCCESS_STATE/jobs/$SUCCESS_JOB" ]; then
    pass 'removes a completed job from pending state'
else
    fail 'removes a completed job from pending state'
fi

FAILURE_STATE="$TEST_ROOT/failure-state"
FAILURE_LOG="$TEST_ROOT/failure-tmux.log"
schedule_test_job "$FAILURE_STATE" "$FAILURE_LOG" 0 1 'Never sent' >/dev/null
if wait_for_pattern "$FAILURE_STATE/jobs-history.log" $'\tfailed\t'; then
    pass 'records a missing target pane as a failure'
else
    fail 'records a missing target pane as a failure' 'timed out waiting for failed history'
fi
assert_not_contains 'does not send text when the captured pane is gone' "$FAILURE_LOG" 'send-keys'

RESTART_STATE="$TEST_ROOT/restart-state"
RESTART_LOG="$TEST_ROOT/restart-tmux.log"
RESTART_SOCKET="$TEST_ROOT/tmux-socket"
REPLACEMENT_SOCKET="$TEST_ROOT/replacement-tmux-socket"
touch "$RESTART_SOCKET"
touch "$REPLACEMENT_SOCKET"
env \
    PATH="$FIXTURES_DIR:$PATH" \
    TMUX="$RESTART_SOCKET,123,0" \
    TMUX_SEND_DELAYED_STATE_DIR="$RESTART_STATE" \
    TMUX_TEST_LOG="$RESTART_LOG" \
    TMUX_TEST_TARGET_EXISTS=1 \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Wrong server' \
        --key 'Enter' \
        --delay 1 >/dev/null
mv -f -- "$REPLACEMENT_SOCKET" "$RESTART_SOCKET"
if wait_for_pattern "$RESTART_STATE/jobs-history.log" $'\tfailed\t'; then
    pass 'rejects a pane ID after the captured tmux server changes'
else
    fail 'rejects a pane ID after the captured tmux server changes' 'timed out waiting for failed history'
fi
assert_not_contains 'never sends to a pane ID reused by another tmux server' "$RESTART_LOG" 'send-keys'

CANCEL_STATE="$TEST_ROOT/cancel-state"
CANCEL_LOG="$TEST_ROOT/cancel-tmux.log"
CANCEL_JOB_ONE="$(schedule_test_job "$CANCEL_STATE" "$CANCEL_LOG" 1 2 'First')"
CANCEL_JOB_TWO="$(schedule_test_job "$CANCEL_STATE" "$CANCEL_LOG" 1 2 'Second')"
CANCEL_WORKER_PID="$(read_first_line "$CANCEL_STATE/jobs/$CANCEL_JOB_ONE/worker-pid")"
if [ "$CANCEL_JOB_ONE" != "$CANCEL_JOB_TWO" ]; then
    pass 'creates unique IDs for concurrent jobs'
else
    fail 'creates unique IDs for concurrent jobs'
fi
env TMUX_SEND_DELAYED_STATE_DIR="$CANCEL_STATE" "$SCHEDULER" cancel "$CANCEL_JOB_ONE" >/dev/null
env TMUX_SEND_DELAYED_STATE_DIR="$CANCEL_STATE" "$SCHEDULER" cancel "$CANCEL_JOB_TWO" >/dev/null
assert_contains 'records cancellation in job history' "$CANCEL_STATE/jobs-history.log" $'\tcancelled\t'
worker_stopped=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$CANCEL_WORKER_PID" 2>/dev/null; then
        worker_stopped=1
        break
    fi
    sleep 0.05
done
if [ "$worker_stopped" -eq 1 ]; then
    pass 'stops the detached worker when its job is cancelled'
else
    fail 'stops the detached worker when its job is cancelled' "worker $CANCEL_WORKER_PID is still running"
fi
sleep 2.2
assert_not_contains 'cancelled jobs never send text' "$CANCEL_LOG" 'send-keys'

SYSTEMD_STATE="$TEST_ROOT/systemd state"
SYSTEMD_LOG="$TEST_ROOT/systemctl.log"
SYSTEMD_CONFIG="$TEST_ROOT/systemd config"
SYSTEMD_JOB="$(env \
    PATH="$ROOT_DIR/tests/fixtures-linux:$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/systemd-tmux.log" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_LOG" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Persistent' \
        --key 'Enter' \
        --delay 30 \
        --use-systemd)"
SYSTEMD_TIMER="$SYSTEMD_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_JOB.timer"
SYSTEMD_SERVICE="$SYSTEMD_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_JOB.service"
assert_file_exists 'creates a persistent systemd timer on Linux' "$SYSTEMD_TIMER"
assert_file_exists 'creates a matching systemd service on Linux' "$SYSTEMD_SERVICE"
assert_contains 'marks the systemd timer persistent' "$SYSTEMD_TIMER" 'Persistent=true'
assert_contains 'quotes a state path containing spaces in ExecStart' "$SYSTEMD_SERVICE" "\"$SYSTEMD_STATE\""
assert_contains 'enables the generated systemd timer' "$SYSTEMD_LOG" $'--user\tenable\t--now\ttmux-lagput-'
env \
    PATH="$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_STATE" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_LOG" \
    "$SCHEDULER" cancel "$SYSTEMD_JOB" >/dev/null
if [ ! -e "$SYSTEMD_TIMER" ] && [ ! -e "$SYSTEMD_SERVICE" ]; then
    pass 'removes systemd unit files when a job is cancelled'
else
    fail 'removes systemd unit files when a job is cancelled'
fi

DARWIN_STATE="$TEST_ROOT/darwin-state"
DARWIN_JOB="$(env \
    PATH="$ROOT_DIR/tests/fixtures-darwin:$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    TMUX_SEND_DELAYED_STATE_DIR="$DARWIN_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/darwin-tmux.log" \
    SYSTEMCTL_TEST_LOG="$TEST_ROOT/darwin-systemctl.log" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Portable' \
        --key 'Enter' \
        --delay 2 \
        --use-systemd)"
assert_contains 'falls back to a background worker on macOS' "$DARWIN_STATE/jobs/$DARWIN_JOB/backend" 'background'
env TMUX_SEND_DELAYED_STATE_DIR="$DARWIN_STATE" "$SCHEDULER" cancel "$DARWIN_JOB" >/dev/null

LAUNCH_LOG="$TEST_ROOT/launch-tmux.log"
env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_TEST_LOG="$LAUNCH_LOG" \
    TMUX_TEST_PANE_ID='%42' \
    TMUX_TEST_DISPLAY_TARGET='work:1.0' \
    "$SCHEDULE_POPUP" --open '%42' >/dev/null 2>&1 || true
assert_contains 'schedule popup receives the captured pane ID' "$LAUNCH_LOG" 'TMUX_SEND_DELAYED_PANE_ID=%42'
assert_contains 'schedule popup receives the captured display target' "$LAUNCH_LOG" 'TMUX_SEND_DELAYED_DISPLAY_TARGET=work:1.0'

FORM_STATE="$TEST_ROOT/form-state"
FORM_OUTPUT="$(printf '\nContinue\n1s\nnone\n' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$FORM_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/form-tmux.log" \
    TMUX_SEND_DELAYED_PANE_ID='%42' \
    TMUX_SEND_DELAYED_DISPLAY_TARGET='work:1.0' \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$SCHEDULE_POPUP" --form 2>&1)"
assert_output 'plain form reports empty text inline' '1' bash -c "printf '%s' \"\$1\" | rg -F -q 'Text cannot be empty.' && printf 1" _ "$FORM_OUTPUT"
FORM_JOB=''
for job_dir in "$FORM_STATE"/jobs/*; do
    if [ -d "$job_dir" ]; then
        FORM_JOB="${job_dir##*/}"
        break
    fi
done
if [ -n "$FORM_JOB" ]; then
    pass 'plain form schedules a validated job'
    assert_output 'none omits the trailing key' '' read_first_line "$FORM_STATE/jobs/$FORM_JOB/key"
    env TMUX_SEND_DELAYED_STATE_DIR="$FORM_STATE" "$SCHEDULER" cancel "$FORM_JOB" >/dev/null
else
    fail 'plain form schedules a validated job'
fi

ESCAPE_STATE="$TEST_ROOT/escape-state"
printf '\033' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$ESCAPE_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/escape-tmux.log" \
    TMUX_SEND_DELAYED_PANE_ID='%42' \
    TMUX_SEND_DELAYED_DISPLAY_TARGET='work:1.0' \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$SCHEDULE_POPUP" --form >/dev/null 2>&1 || true
if [ ! -d "$ESCAPE_STATE/jobs" ] || ! find "$ESCAPE_STATE/jobs" -mindepth 1 -maxdepth 1 -type d | rg -q .; then
    pass 'Escape closes the schedule form without creating a job'
else
    fail 'Escape closes the schedule form without creating a job'
fi

LIST_STATE="$TEST_ROOT/list-state"
LIST_LOG="$TEST_ROOT/list-tmux.log"
LIST_JOB="$(schedule_test_job "$LIST_STATE" "$LIST_LOG" 1 30 'Review deployment')"
LIST_OUTPUT="$(printf '1\ny\n\033' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" \
    TMUX_TEST_LOG="$LIST_LOG" \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$LIST_POPUP" --form 2>&1)"
assert_output 'list popup shows target, text, and remaining time' '1' bash -c "printf '%s' \"\$1\" | rg -q 'work:1.0.*Review deployment.*[0-9].*[smhd]' && printf 1" _ "$LIST_OUTPUT"
if [ ! -d "$LIST_STATE/jobs/$LIST_JOB" ]; then
    pass 'list popup cancels the selected pending job'
else
    fail 'list popup cancels the selected pending job'
    env TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" "$SCHEDULER" cancel "$LIST_JOB" >/dev/null
fi

ENTRYPOINT_LOG="$TEST_ROOT/entrypoint-tmux.log"
env PATH="$FIXTURES_DIR:/usr/bin:/bin" TMUX_TEST_LOG="$ENTRYPOINT_LOG" bash "$PLUGIN_ENTRYPOINT" >/dev/null 2>&1 || true
assert_contains 'binds the requested default schedule key' "$ENTRYPOINT_LOG" $'bind-key\tT\trun-shell'
assert_contains 'binds a non-colliding default list key' "$ENTRYPOINT_LOG" $'bind-key\tC-t\trun-shell'
assert_contains 'passes pane ID format expansion from the key binding' "$ENTRYPOINT_LOG" '#{pane_id}'

printf '1..%d\n' "$((PASSED + FAILED))"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
