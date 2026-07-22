#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT_DIR/scripts/parse-duration.sh"
SCHEDULER="$ROOT_DIR/scripts/schedule-job.sh"
SCHEDULE_POPUP="$ROOT_DIR/scripts/popup-schedule.sh"
LIST_POPUP="$ROOT_DIR/scripts/popup-list.sh"
CLEANUP_SCRIPT="$ROOT_DIR/scripts/cleanup.sh"
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

process_is_running() {
    local process_id="$1"
    local process_state

    if ! kill -0 "$process_id" 2>/dev/null; then
        return 1
    fi
    process_state="$(ps -p "$process_id" -o stat= 2>/dev/null || true)"
    case "$process_state" in
        *Z*) return 1 ;;
    esac
    return 0
}

wait_for_process_exit() {
    local process_id="$1"
    local attempts=30

    while [ "$attempts" -gt 0 ]; do
        if ! process_is_running "$process_id"; then
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 0.1
    done

    return 1
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

LAUNCH_FAILURE_STATE="$TEST_ROOT/launch-failure-state"
LAUNCH_FAILURE_OUTPUT=''
if LAUNCH_FAILURE_OUTPUT="$(env \
    PATH="$ROOT_DIR/tests/fixtures-launch-failure:$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$LAUNCH_FAILURE_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/launch-failure-tmux.log" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Must not publish' \
        --key 'Enter' \
        --delay 60 2>/dev/null)"; then
    fail 'returns nonzero when the detached worker cannot launch'
else
    pass 'returns nonzero when the detached worker cannot launch'
fi
if [ -z "$LAUNCH_FAILURE_OUTPUT" ]; then
    pass 'does not print a job ID when the detached worker cannot launch'
else
    fail 'does not print a job ID when the detached worker cannot launch' "unexpected output: $LAUNCH_FAILURE_OUTPUT"
fi
if [ ! -d "$LAUNCH_FAILURE_STATE/jobs" ] || ! find "$LAUNCH_FAILURE_STATE/jobs" -mindepth 1 -maxdepth 1 -type d | rg -q .; then
    pass 'does not publish a pending job when the detached worker cannot launch'
else
    fail 'does not publish a pending job when the detached worker cannot launch'
fi

SUCCESS_STATE="$TEST_ROOT/success-state"
SUCCESS_LOG="$TEST_ROOT/success-tmux.log"
SUCCESS_JOB="$(schedule_test_job "$SUCCESS_STATE" "$SUCCESS_LOG" 1 1 'Continue -- safely')"
if wait_for_pattern "$SUCCESS_STATE/jobs-history.log" $'\tsent\t'; then
    pass 'background worker records successful delivery'
else
    fail 'background worker records successful delivery' 'timed out waiting for sent history'
fi
assert_contains 'sends text literally to the captured pane ID' "$SUCCESS_LOG" $'send-keys\t-t\t%42\t-l\t--\tContinue -- safely'
assert_contains 'sends the configured key to the captured pane ID' "$SUCCESS_LOG" $'send-keys\t-t\t%42\t--\tEnter'
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

RECONCILE_STATE="$TEST_ROOT/reconcile-state"
RECONCILE_STALE_JOB='stale-running-job'
RECONCILE_FRESH_JOB='fresh-running-job'
RECONCILE_STAGING_JOB='stale-staging-job'
RECONCILE_STALE_DIR="$RECONCILE_STATE/running/$RECONCILE_STALE_JOB"
RECONCILE_FRESH_DIR="$RECONCILE_STATE/running/$RECONCILE_FRESH_JOB"
RECONCILE_STAGING_DIR="$RECONCILE_STATE/staging/$RECONCILE_STAGING_JOB"
mkdir -p "$RECONCILE_STALE_DIR" "$RECONCILE_FRESH_DIR" "$RECONCILE_STAGING_DIR"
NOW_EPOCH="$(date +%s)"
bash -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' \
    "$SCHEDULER" --run-staged "$RECONCILE_STATE" "$RECONCILE_STALE_JOB" &
RECONCILE_STALE_PID=$!
bash -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' \
    "$SCHEDULER" --run-staged "$RECONCILE_STATE" "$RECONCILE_FRESH_JOB" &
RECONCILE_FRESH_PID=$!
bash -c 'trap "exit 0" TERM INT; while :; do sleep 1; done' \
    "$SCHEDULER" --run-staged "$RECONCILE_STATE" "$RECONCILE_STAGING_JOB" 'staging-token' &
RECONCILE_STAGING_PID=$!
printf '%s\n' "$((NOW_EPOCH - 600))" > "$RECONCILE_STALE_DIR/claimed-at"
printf '%s\n' "$RECONCILE_STALE_PID" > "$RECONCILE_STALE_DIR/worker-pid"
printf '%s\n' 'background' > "$RECONCILE_STALE_DIR/backend"
printf '%s\n' 'work:1.0' > "$RECONCILE_STALE_DIR/display-target"
printf '%s\n' "$NOW_EPOCH" > "$RECONCILE_FRESH_DIR/claimed-at"
printf '%s\n' "$RECONCILE_FRESH_PID" > "$RECONCILE_FRESH_DIR/worker-pid"
printf '%s\n' 'background' > "$RECONCILE_FRESH_DIR/backend"
printf '%s\n' 'work:1.1' > "$RECONCILE_FRESH_DIR/display-target"
printf '%s\n' "$((NOW_EPOCH - 600))" > "$RECONCILE_STAGING_DIR/created-at"
printf '%s\n' "$RECONCILE_STAGING_PID" > "$RECONCILE_STAGING_DIR/worker-pid"
printf '%s\n' 'staging-token' > "$RECONCILE_STAGING_DIR/worker-token"
printf '%s\n' 'background' > "$RECONCILE_STAGING_DIR/backend"
printf '%s\n' 'work:1.2' > "$RECONCILE_STAGING_DIR/display-target"
if env TMUX_SEND_DELAYED_STATE_DIR="$RECONCILE_STATE" \
    "$SCHEDULER" reconcile --older-than 300 >/dev/null 2>&1; then
    pass 'reconciles claimed jobs older than the configured threshold'
else
    fail 'reconciles claimed jobs older than the configured threshold'
fi
if [ ! -d "$RECONCILE_STALE_DIR" ]; then
    pass 'removes a stale claimed job without requeueing it'
else
    fail 'removes a stale claimed job without requeueing it'
fi
if wait_for_process_exit "$RECONCILE_STALE_PID"; then
    pass 'stops the exact worker for a stale claimed job'
else
    fail 'stops the exact worker for a stale claimed job' "worker $RECONCILE_STALE_PID is still running"
fi
assert_contains 'records an unknown-delivery failure for a stale claimed job' \
    "$RECONCILE_STATE/jobs-history.log" $'\tstale-running-job\tfailed\twork:1.0\tdelivery outcome is unknown'
if [ -d "$RECONCILE_FRESH_DIR" ] && process_is_running "$RECONCILE_FRESH_PID"; then
    pass 'leaves a fresh claimed job and its worker untouched'
else
    fail 'leaves a fresh claimed job and its worker untouched'
fi
if [ ! -d "$RECONCILE_STAGING_DIR" ] && wait_for_process_exit "$RECONCILE_STAGING_PID"; then
    pass 'reconciles stale unpublished jobs and their workers'
else
    fail 'reconciles stale unpublished jobs and their workers'
fi
assert_contains 'records a stale unpublished scheduling failure' \
    "$RECONCILE_STATE/jobs-history.log" $'\tstale-staging-job\tfailed\twork:1.2\tscheduling did not complete'
kill -TERM "$RECONCILE_STALE_PID" "$RECONCILE_FRESH_PID" "$RECONCILE_STAGING_PID" 2>/dev/null || true
wait "$RECONCILE_STALE_PID" 2>/dev/null || true
wait "$RECONCILE_FRESH_PID" 2>/dev/null || true
wait "$RECONCILE_STAGING_PID" 2>/dev/null || true

DOT_JOB_ERROR="$(env \
    TMUX_SEND_DELAYED_STATE_DIR="$TEST_ROOT/dot-job-state" \
    "$SCHEDULER" cancel '..' 2>&1 || true)"
assert_output 'rejects dot-segment job IDs before accessing state' '1' bash -c "printf '%s' \"\$1\" | rg -q '^Usage:' && printf 1" _ "$DOT_JOB_ERROR"

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

SYSTEMD_FAILURE_STATE="$TEST_ROOT/systemd-failure-state"
SYSTEMD_FAILURE_CONFIG="$TEST_ROOT/systemd-failure-config"
SYSTEMD_FAILURE_LOG="$TEST_ROOT/systemd-failure-systemctl.log"
SYSTEMD_FAILURE_JOB="$(env \
    PATH="$ROOT_DIR/tests/fixtures-linux:$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_FAILURE_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_FAILURE_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/systemd-failure-tmux.log" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_FAILURE_LOG" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Retain failed teardown' \
        --key 'Enter' \
        --delay 120 \
        --use-systemd)"
SYSTEMD_FAILURE_TIMER="$SYSTEMD_FAILURE_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_FAILURE_JOB.timer"
SYSTEMD_FAILURE_SERVICE="$SYSTEMD_FAILURE_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_FAILURE_JOB.service"
if env \
    PATH="$ROOT_DIR/tests/fixtures-systemctl-failure:$FIXTURES_DIR:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_FAILURE_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_FAILURE_STATE" \
    "$SCHEDULER" cancel "$SYSTEMD_FAILURE_JOB" >/dev/null 2>&1; then
    fail 'cancellation fails closed when systemd teardown fails'
else
    pass 'cancellation fails closed when systemd teardown fails'
fi
if [ -d "$SYSTEMD_FAILURE_STATE/cancelled/$SYSTEMD_FAILURE_JOB" ]; then
    pass 'failed systemd teardown retains quarantined job metadata'
else
    fail 'failed systemd teardown retains quarantined job metadata'
fi
if [ -f "$SYSTEMD_FAILURE_TIMER" ] && [ -f "$SYSTEMD_FAILURE_SERVICE" ]; then
    pass 'failed systemd teardown retains unit files for retry'
else
    fail 'failed systemd teardown retains unit files for retry'
fi
env \
    PATH="$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_FAILURE_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_FAILURE_STATE" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_FAILURE_LOG" \
    "$CLEANUP_SCRIPT" >/dev/null
if [ ! -d "$SYSTEMD_FAILURE_STATE/cancelled/$SYSTEMD_FAILURE_JOB" ] && \
    [ ! -e "$SYSTEMD_FAILURE_TIMER" ] && [ ! -e "$SYSTEMD_FAILURE_SERVICE" ]; then
    pass 'cleanup retries and completes a quarantined systemd teardown'
else
    fail 'cleanup retries and completes a quarantined systemd teardown'
fi

SYSTEMD_AMBIGUOUS_STATE="$TEST_ROOT/systemd-ambiguous-state"
SYSTEMD_AMBIGUOUS_CONFIG="$TEST_ROOT/systemd-ambiguous-config"
SYSTEMD_AMBIGUOUS_LOG="$TEST_ROOT/systemd-ambiguous-systemctl.log"
SYSTEMD_AMBIGUOUS_JOB="$(env \
    PATH="$ROOT_DIR/tests/fixtures-linux:$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_AMBIGUOUS_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_AMBIGUOUS_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/systemd-ambiguous-tmux.log" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_AMBIGUOUS_LOG" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Do not lose ambiguous teardown' \
        --key 'Enter' \
        --delay 120 \
        --use-systemd)"
SYSTEMD_AMBIGUOUS_TIMER="$SYSTEMD_AMBIGUOUS_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_AMBIGUOUS_JOB.timer"
SYSTEMD_AMBIGUOUS_SERVICE="$SYSTEMD_AMBIGUOUS_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_AMBIGUOUS_JOB.service"
if env \
    PATH="$ROOT_DIR/tests/fixtures-systemctl-ambiguous:$FIXTURES_DIR:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_AMBIGUOUS_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_AMBIGUOUS_STATE" \
    "$SCHEDULER" cancel "$SYSTEMD_AMBIGUOUS_JOB" >/dev/null 2>&1; then
    fail 'cancellation fails closed when systemd state is ambiguous'
else
    pass 'cancellation fails closed when systemd state is ambiguous'
fi
if [ -d "$SYSTEMD_AMBIGUOUS_STATE/cancelled/$SYSTEMD_AMBIGUOUS_JOB" ]; then
    pass 'ambiguous systemd teardown retains quarantined metadata'
else
    fail 'ambiguous systemd teardown retains quarantined metadata'
fi
if [ -f "$SYSTEMD_AMBIGUOUS_TIMER" ] && [ -f "$SYSTEMD_AMBIGUOUS_SERVICE" ]; then
    pass 'ambiguous systemd teardown retains unit files'
else
    fail 'ambiguous systemd teardown retains unit files'
fi
env \
    PATH="$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_AMBIGUOUS_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_AMBIGUOUS_STATE" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_AMBIGUOUS_LOG" \
    "$CLEANUP_SCRIPT" >/dev/null

SYSTEMD_REMOVED_STATE="$TEST_ROOT/systemd-removed-state"
SYSTEMD_REMOVED_CONFIG="$TEST_ROOT/systemd-removed-config"
SYSTEMD_REMOVED_LOG="$TEST_ROOT/systemd-removed-systemctl.log"
SYSTEMD_REMOVED_JOB="$(env \
    PATH="$ROOT_DIR/tests/fixtures-linux:$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_REMOVED_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_REMOVED_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/systemd-removed-tmux.log" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_REMOVED_LOG" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Recover completed teardown' \
        --key 'Enter' \
        --delay 120 \
        --use-systemd)"
SYSTEMD_REMOVED_TIMER="$SYSTEMD_REMOVED_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_REMOVED_JOB.timer"
SYSTEMD_REMOVED_SERVICE="$SYSTEMD_REMOVED_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_REMOVED_JOB.service"
mv \
    "$SYSTEMD_REMOVED_STATE/jobs/$SYSTEMD_REMOVED_JOB" \
    "$SYSTEMD_REMOVED_STATE/cancelled/$SYSTEMD_REMOVED_JOB"
printf '%s\n' 'cancelled' > "$SYSTEMD_REMOVED_STATE/cancelled/$SYSTEMD_REMOVED_JOB/terminal-status"
printf '%s\n' 'work:1.0' > "$SYSTEMD_REMOVED_STATE/cancelled/$SYSTEMD_REMOVED_JOB/terminal-target"
printf '%s\n' 'cancelled by user' > "$SYSTEMD_REMOVED_STATE/cancelled/$SYSTEMD_REMOVED_JOB/terminal-detail"
rm -f -- "$SYSTEMD_REMOVED_TIMER" "$SYSTEMD_REMOVED_SERVICE"
if env \
    PATH="$ROOT_DIR/tests/fixtures-systemctl-already-removed:$FIXTURES_DIR:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_REMOVED_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_REMOVED_STATE" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_REMOVED_LOG" \
    "$CLEANUP_SCRIPT" >/dev/null 2>&1; then
    pass 'cleanup completes an already-finished systemd teardown'
else
    fail 'cleanup completes an already-finished systemd teardown'
fi
if [ ! -d "$SYSTEMD_REMOVED_STATE/cancelled/$SYSTEMD_REMOVED_JOB" ]; then
    pass 'already-finished systemd teardown removes transition metadata'
else
    fail 'already-finished systemd teardown removes transition metadata'
fi
assert_contains 'already-finished systemd teardown records history' \
    "$SYSTEMD_REMOVED_STATE/jobs-history.log" \
    $'\t'"$SYSTEMD_REMOVED_JOB"$'\tcancelled\twork:1.0\tcancelled by user'
assert_contains 'already-finished teardown verifies the timer is inactive' \
    "$SYSTEMD_REMOVED_LOG" \
    $'--user\tis-active\ttmux-lagput-'"$SYSTEMD_REMOVED_JOB"'.timer'
assert_contains 'already-finished teardown verifies the timer is not enabled' \
    "$SYSTEMD_REMOVED_LOG" \
    $'--user\tis-enabled\ttmux-lagput-'"$SYSTEMD_REMOVED_JOB"'.timer'
assert_contains 'already-finished teardown verifies the service is inactive' \
    "$SYSTEMD_REMOVED_LOG" \
    $'--user\tis-active\ttmux-lagput-'"$SYSTEMD_REMOVED_JOB"'.service'
assert_contains 'already-finished teardown verifies the service is not enabled' \
    "$SYSTEMD_REMOVED_LOG" \
    $'--user\tis-enabled\ttmux-lagput-'"$SYSTEMD_REMOVED_JOB"'.service'

SYSTEMD_PUBLISH_STATE="$TEST_ROOT/systemd-publish-state"
SYSTEMD_PUBLISH_CONFIG="$TEST_ROOT/systemd-publish-config"
SYSTEMD_PUBLISH_LOG="$TEST_ROOT/systemd-publish-systemctl.log"
SYSTEMD_PUBLISH_JOB_FILE="$TEST_ROOT/systemd-publish-job-id"
if env \
    PATH="$ROOT_DIR/tests/fixtures-systemctl-publish-failure:$ROOT_DIR/tests/fixtures-linux:$FIXTURES_DIR:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_PUBLISH_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_PUBLISH_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/systemd-publish-tmux.log" \
    SYSTEMCTL_PUBLISH_JOB_FILE="$SYSTEMD_PUBLISH_JOB_FILE" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Retain failed publication' \
        --key 'Enter' \
        --delay 120 \
        --use-systemd >/dev/null 2>&1; then
    fail 'scheduling fails when an armed systemd job cannot be published'
else
    pass 'scheduling fails when an armed systemd job cannot be published'
fi
SYSTEMD_PUBLISH_JOB="$(read_first_line "$SYSTEMD_PUBLISH_JOB_FILE")"
SYSTEMD_PUBLISH_TIMER="$SYSTEMD_PUBLISH_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_PUBLISH_JOB.timer"
SYSTEMD_PUBLISH_SERVICE="$SYSTEMD_PUBLISH_CONFIG/systemd/user/tmux-lagput-$SYSTEMD_PUBLISH_JOB.service"
if [ -d "$SYSTEMD_PUBLISH_STATE/staging/$SYSTEMD_PUBLISH_JOB" ] || \
    [ -d "$SYSTEMD_PUBLISH_STATE/abandoned/$SYSTEMD_PUBLISH_JOB" ]; then
    pass 'failed publication retains systemd job metadata for cleanup'
else
    fail 'failed publication retains systemd job metadata for cleanup'
fi
if [ -f "$SYSTEMD_PUBLISH_TIMER" ] && [ -f "$SYSTEMD_PUBLISH_SERVICE" ]; then
    pass 'failed publication retains armed systemd unit files for cleanup'
else
    fail 'failed publication retains armed systemd unit files for cleanup'
fi
rm -f -- "$SYSTEMD_PUBLISH_STATE/jobs/$SYSTEMD_PUBLISH_JOB"
env \
    PATH="$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$SYSTEMD_PUBLISH_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$SYSTEMD_PUBLISH_STATE" \
    SYSTEMCTL_TEST_LOG="$SYSTEMD_PUBLISH_LOG" \
    "$CLEANUP_SCRIPT" >/dev/null
if [ ! -e "$SYSTEMD_PUBLISH_TIMER" ] && [ ! -e "$SYSTEMD_PUBLISH_SERVICE" ]; then
    pass 'cleanup completes retained publication teardown'
else
    fail 'cleanup completes retained publication teardown'
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

CLEANUP_STATE="$TEST_ROOT/cleanup-state"
CLEANUP_LOG="$TEST_ROOT/cleanup-tmux.log"
CLEANUP_SYSTEMD_LOG="$TEST_ROOT/cleanup-systemctl.log"
CLEANUP_CONFIG="$TEST_ROOT/cleanup-config"
CLEANUP_BACKGROUND_JOB="$(schedule_test_job "$CLEANUP_STATE" "$CLEANUP_LOG" 1 120 'Background cleanup')"
CLEANUP_BACKGROUND_PID="$(read_first_line "$CLEANUP_STATE/jobs/$CLEANUP_BACKGROUND_JOB/worker-pid")"
CLEANUP_SYSTEMD_JOB="$(env \
    PATH="$ROOT_DIR/tests/fixtures-linux:$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$CLEANUP_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$CLEANUP_STATE" \
    TMUX_TEST_LOG="$CLEANUP_LOG" \
    SYSTEMCTL_TEST_LOG="$CLEANUP_SYSTEMD_LOG" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.1' \
        --text 'Systemd cleanup' \
        --key 'Enter' \
        --delay 120 \
        --use-systemd)"
CLEANUP_TIMER="$CLEANUP_CONFIG/systemd/user/tmux-lagput-$CLEANUP_SYSTEMD_JOB.timer"
CLEANUP_SERVICE="$CLEANUP_CONFIG/systemd/user/tmux-lagput-$CLEANUP_SYSTEMD_JOB.service"
CLEANUP_RUNNING_JOB='cleanup-running-job'
CLEANUP_STAGING_JOB='cleanup-staging-job'
CLEANUP_CANCELLED_JOB='cleanup-cancelled-job'
CLEANUP_INCOMPLETE_JOB='cleanup-incomplete-job'
CLEANUP_FINISHING_JOB='cleanup-finishing-job'
CLEANUP_ABANDONED_JOB='cleanup-abandoned-job'
mkdir -p \
    "$CLEANUP_STATE/running/$CLEANUP_RUNNING_JOB" \
    "$CLEANUP_STATE/staging/$CLEANUP_STAGING_JOB" \
    "$CLEANUP_STATE/cancelled/$CLEANUP_CANCELLED_JOB" \
    "$CLEANUP_STATE/cancelled/$CLEANUP_INCOMPLETE_JOB" \
    "$CLEANUP_STATE/finishing/$CLEANUP_FINISHING_JOB" \
    "$CLEANUP_STATE/abandoned/$CLEANUP_ABANDONED_JOB"
printf '%s\n' "$((NOW_EPOCH - 600))" > "$CLEANUP_STATE/running/$CLEANUP_RUNNING_JOB/claimed-at"
printf '%s\n' 'work:1.2' > "$CLEANUP_STATE/running/$CLEANUP_RUNNING_JOB/display-target"
printf '%s\n' 'work:1.3' > "$CLEANUP_STATE/cancelled/$CLEANUP_CANCELLED_JOB/display-target"
printf '%s\n' 'cancelled' > "$CLEANUP_STATE/cancelled/$CLEANUP_CANCELLED_JOB/terminal-status"
printf '%s\n' 'cancelled during cleanup' > "$CLEANUP_STATE/cancelled/$CLEANUP_CANCELLED_JOB/terminal-detail"
printf '%s\n' 'work:1.6' > "$CLEANUP_STATE/cancelled/$CLEANUP_INCOMPLETE_JOB/display-target"
printf '%s\n' 'work:1.4' > "$CLEANUP_STATE/finishing/$CLEANUP_FINISHING_JOB/display-target"
printf '%s\n' 'sent' > "$CLEANUP_STATE/finishing/$CLEANUP_FINISHING_JOB/terminal-status"
printf '%s\n' 'delayed input delivered' > "$CLEANUP_STATE/finishing/$CLEANUP_FINISHING_JOB/terminal-detail"
printf '%s\n' 'work:1.5' > "$CLEANUP_STATE/abandoned/$CLEANUP_ABANDONED_JOB/display-target"
printf '%s\n' 'failed' > "$CLEANUP_STATE/abandoned/$CLEANUP_ABANDONED_JOB/terminal-status"
printf '%s\n' 'delivery outcome is unknown' > "$CLEANUP_STATE/abandoned/$CLEANUP_ABANDONED_JOB/terminal-detail"
printf '%s\n' $'2026-01-01T00:00:00Z\tprior-job\tfailed\twork:1.9\tprior failure retained' > "$CLEANUP_STATE/jobs-history.log"
if env \
    PATH="$FIXTURES_DIR:$PATH" \
    HOME="$TEST_ROOT/home" \
    XDG_CONFIG_HOME="$CLEANUP_CONFIG" \
    TMUX_SEND_DELAYED_STATE_DIR="$CLEANUP_STATE" \
    SYSTEMCTL_TEST_LOG="$CLEANUP_SYSTEMD_LOG" \
    "$CLEANUP_SCRIPT" >/dev/null 2>&1; then
    pass 'cleanup command completes successfully'
else
    fail 'cleanup command completes successfully'
fi
if wait_for_process_exit "$CLEANUP_BACKGROUND_PID"; then
    pass 'cleanup stops pending background workers'
else
    fail 'cleanup stops pending background workers' "worker $CLEANUP_BACKGROUND_PID is still running"
fi
assert_contains 'cleanup disables pending systemd timers' "$CLEANUP_SYSTEMD_LOG" \
    $'--user\tdisable\t--now\ttmux-lagput-'"$CLEANUP_SYSTEMD_JOB"'.timer'
if [ ! -e "$CLEANUP_TIMER" ] && [ ! -e "$CLEANUP_SERVICE" ]; then
    pass 'cleanup removes generated systemd unit files'
else
    fail 'cleanup removes generated systemd unit files'
fi
for cleanup_directory in jobs running staging cancelled finishing abandoned; do
    if [ -d "$CLEANUP_STATE/$cleanup_directory" ] && \
        ! find "$CLEANUP_STATE/$cleanup_directory" -mindepth 1 -maxdepth 1 | rg -q .; then
        pass "cleanup leaves $cleanup_directory state empty"
    else
        fail "cleanup leaves $cleanup_directory state empty"
    fi
done
if [ -d "$CLEANUP_STATE" ]; then
    pass 'cleanup retains the state directory'
else
    fail 'cleanup retains the state directory'
fi
assert_contains 'cleanup retains existing history' "$CLEANUP_STATE/jobs-history.log" \
    $'\tprior-job\tfailed\twork:1.9\tprior failure retained'
assert_contains 'cleanup records background job cancellation' "$CLEANUP_STATE/jobs-history.log" \
    $'\t'"$CLEANUP_BACKGROUND_JOB"$'\tcancelled\twork:1.0\t'
assert_contains 'cleanup records systemd job cancellation' "$CLEANUP_STATE/jobs-history.log" \
    $'\t'"$CLEANUP_SYSTEMD_JOB"$'\tcancelled\twork:1.1\t'
assert_contains 'cleanup records unknown delivery for claimed jobs' "$CLEANUP_STATE/jobs-history.log" \
    $'\tcleanup-running-job\tfailed\twork:1.2\tdelivery outcome is unknown'
assert_contains 'cleanup recovers a stranded cancelled job' "$CLEANUP_STATE/jobs-history.log" \
    $'\tcleanup-cancelled-job\tcancelled\twork:1.3\tcancelled during cleanup'
assert_contains 'cleanup conservatively recovers incomplete transition metadata' "$CLEANUP_STATE/jobs-history.log" \
    $'\tcleanup-incomplete-job\tfailed\twork:1.6\tdelivery outcome is unknown'
assert_contains 'cleanup recovers a stranded finishing job' "$CLEANUP_STATE/jobs-history.log" \
    $'\tcleanup-finishing-job\tsent\twork:1.4\tdelayed input delivered'
assert_contains 'cleanup recovers a stranded abandoned job' "$CLEANUP_STATE/jobs-history.log" \
    $'\tcleanup-abandoned-job\tfailed\twork:1.5\tdelivery outcome is unknown'
if [ -f "$CLEANUP_STATE/disabled" ]; then
    pass 'cleanup blocks new jobs until the plugin is loaded again'
else
    fail 'cleanup blocks new jobs until the plugin is loaded again'
fi
if env \
    PATH="$FIXTURES_DIR:$PATH" \
    TMUX_SEND_DELAYED_STATE_DIR="$CLEANUP_STATE" \
    TMUX_TEST_LOG="$CLEANUP_LOG" \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'work:1.0' \
        --text 'Blocked after cleanup' \
        --key 'Enter' \
        --delay 60 >/dev/null 2>&1; then
    fail 'scheduler refuses new jobs after cleanup'
else
    pass 'scheduler refuses new jobs after cleanup'
fi
env \
    PATH="$FIXTURES_DIR:$PATH" \
    TMUX_SEND_DELAYED_STATE_DIR="$CLEANUP_STATE" \
    TMUX_TEST_LOG="$CLEANUP_LOG" \
    "$PLUGIN_ENTRYPOINT" >/dev/null 2>&1
if [ ! -f "$CLEANUP_STATE/disabled" ]; then
    pass 'loading the plugin re-enables scheduling after cleanup'
else
    fail 'loading the plugin re-enables scheduling after cleanup'
fi
if [ -d "$CLEANUP_STATE/jobs/$CLEANUP_BACKGROUND_JOB" ]; then
    env TMUX_SEND_DELAYED_STATE_DIR="$CLEANUP_STATE" "$SCHEDULER" cancel "$CLEANUP_BACKGROUND_JOB" >/dev/null 2>&1 || true
fi
if [ -d "$CLEANUP_STATE/jobs/$CLEANUP_SYSTEMD_JOB" ]; then
    env \
        PATH="$FIXTURES_DIR:$PATH" \
        HOME="$TEST_ROOT/home" \
        XDG_CONFIG_HOME="$CLEANUP_CONFIG" \
        TMUX_SEND_DELAYED_STATE_DIR="$CLEANUP_STATE" \
        SYSTEMCTL_TEST_LOG="$CLEANUP_SYSTEMD_LOG" \
        "$SCHEDULER" cancel "$CLEANUP_SYSTEMD_JOB" >/dev/null 2>&1 || true
fi

LAUNCH_LOG="$TEST_ROOT/launch-tmux.log"
env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_TEST_LOG="$LAUNCH_LOG" \
    TMUX_TEST_LOG_PRINT_MESSAGES=1 \
    TMUX_TEST_PANE_ID='%42' \
    TMUX_TEST_DISPLAY_TARGET='work:1.0' \
    "$SCHEDULE_POPUP" --open '%42' 'client-a' >/dev/null 2>&1 || true
assert_contains 'schedule popup receives the captured pane ID' "$LAUNCH_LOG" 'TMUX_SEND_DELAYED_PANE_ID=%42'
assert_contains 'schedule popup receives the captured display target' "$LAUNCH_LOG" 'TMUX_SEND_DELAYED_DISPLAY_TARGET=work:1.0'
assert_contains 'schedule popup resolves its label for the triggering client' "$LAUNCH_LOG" $'display-message\t-p\t-t\t%42\t-c\tclient-a'
assert_contains 'schedule popup targets the triggering client and pane' "$LAUNCH_LOG" $'display-popup\t-EE\t-t\t%42\t-c\tclient-a'
assert_contains 'schedule popup has native responsive chrome' "$LAUNCH_LOG" $'-T\tSchedule delayed send\t-w\t70%\t-h\t16\t-b\trounded'

LIST_LAUNCH_LOG="$TEST_ROOT/list-launch-tmux.log"
env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_TEST_LOG="$LIST_LAUNCH_LOG" \
    "$LIST_POPUP" --open '%42' 'client-a' >/dev/null 2>&1 || true
assert_contains 'list popup targets the triggering client and pane' "$LIST_LAUNCH_LOG" $'display-popup\t-EE\t-t\t%42\t-c\tclient-a'
assert_contains 'list popup has native responsive chrome' "$LIST_LAUNCH_LOG" $'-T\tPending delayed sends\t-w\t80%\t-h\t70%\t-b\trounded'

POPUP_OPTIONS="$TEST_ROOT/popup-options"
printf '%s\t%s\n' \
    '@send-delayed-popup-width' '72%' \
    '@send-delayed-popup-height' '14' \
    '@send-delayed-list-popup-width' '88%' \
    '@send-delayed-list-popup-height' '65%' \
    '@send-delayed-popup-border-lines' 'double' > "$POPUP_OPTIONS"
CUSTOM_POPUP_LOG="$TEST_ROOT/custom-popup-tmux.log"
env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_TEST_LOG="$CUSTOM_POPUP_LOG" \
    TMUX_TEST_OPTIONS_FILE="$POPUP_OPTIONS" \
    "$SCHEDULE_POPUP" --open '%42' 'client-a' >/dev/null 2>&1 || true
env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_TEST_LOG="$CUSTOM_POPUP_LOG" \
    TMUX_TEST_OPTIONS_FILE="$POPUP_OPTIONS" \
    "$LIST_POPUP" --open '%42' 'client-a' >/dev/null 2>&1 || true
assert_contains 'schedule popup honours configured geometry and border' "$CUSTOM_POPUP_LOG" $'-w\t72%\t-h\t14\t-b\tdouble'
assert_contains 'list popup honours configured geometry and border' "$CUSTOM_POPUP_LOG" $'-w\t88%\t-h\t65%\t-b\tdouble'

FORM_STATE="$TEST_ROOT/form-state"
FORM_LOG="$TEST_ROOT/form-tmux.log"
FORM_OUTPUT="$(printf '\nContinue\n30s\nnone\n\n' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$FORM_STATE" \
    TMUX_TEST_LOG="$FORM_LOG" \
    TMUX_SEND_DELAYED_PANE_ID='%42' \
    TMUX_SEND_DELAYED_DISPLAY_TARGET='work:1.0' \
    TMUX_SEND_DELAYED_CLIENT_NAME='client-a' \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$SCHEDULE_POPUP" --form 2>&1)"
assert_output 'plain form reports empty text inline' '1' bash -c "printf '%s' \"\$1\" | rg -F -q 'Text cannot be empty.' && printf 1" _ "$FORM_OUTPUT"
assert_contains 'shows scheduling success to the triggering client' "$FORM_LOG" $'display-message\t-c\tclient-a\t-d\t3000\tScheduled in 30s -> work:1.0'
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

FORMAT_STATE="$TEST_ROOT/format-state"
FORMAT_LOG="$TEST_ROOT/format-tmux.log"
printf 'Literal format target\n30s\nnone\n\n' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$FORMAT_STATE" \
    TMUX_TEST_LOG="$FORMAT_LOG" \
    TMUX_SEND_DELAYED_PANE_ID='%42' \
    TMUX_SEND_DELAYED_DISPLAY_TARGET='hash#{pane_id}:1.0' \
    TMUX_SEND_DELAYED_CLIENT_NAME='client-a' \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$SCHEDULE_POPUP" --form >/dev/null 2>&1
assert_contains 'keeps tmux formats literal in scheduling feedback' "$FORMAT_LOG" 'Scheduled in 30s -> hash##{pane_id}:1.0'
for job_dir in "$FORMAT_STATE"/jobs/*; do
    [ -d "$job_dir" ] || continue
    env TMUX_SEND_DELAYED_STATE_DIR="$FORMAT_STATE" "$SCHEDULER" cancel "${job_dir##*/}" >/dev/null
done

GUM_FORM_STATE="$TEST_ROOT/gum-form-state"
GUM_FORM_LOG="$TEST_ROOT/gum-form.log"
GUM_FORM_TMUX_LOG="$TEST_ROOT/gum-form-tmux.log"
GUM_FORM_INPUTS="$TEST_ROOT/gum-form-inputs"
GUM_FORM_INPUT_INDEX="$TEST_ROOT/gum-form-input-index"
printf '%s\n' 'Cancel with gum' '30s' 'Enter' > "$GUM_FORM_INPUTS"
env \
    PATH="$ROOT_DIR/tests/fixtures-gum:$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$GUM_FORM_STATE" \
    TMUX_TEST_LOG="$GUM_FORM_TMUX_LOG" \
    TMUX_SEND_DELAYED_PANE_ID='%42' \
    TMUX_SEND_DELAYED_DISPLAY_TARGET='work:1.0' \
    GUM_TEST_LOG="$GUM_FORM_LOG" \
    GUM_TEST_INPUTS_FILE="$GUM_FORM_INPUTS" \
    GUM_TEST_INPUT_INDEX_FILE="$GUM_FORM_INPUT_INDEX" \
    GUM_TEST_CHOOSE_STATUS=130 \
    SEND_DELAYED_FORCE_GUM=1 \
    "$SCHEDULE_POPUP" --form >/dev/null 2>&1 || true
assert_contains 'gum review uses an explicit schedule-or-edit choice' "$GUM_FORM_LOG" $'gum\tchoose'
if [ ! -d "$GUM_FORM_STATE/jobs" ] || ! find "$GUM_FORM_STATE/jobs" -mindepth 1 -maxdepth 1 -type d | rg -q .; then
    pass 'Escape from the gum review does not schedule a job'
else
    fail 'Escape from the gum review does not schedule a job'
fi

REVIEW_STATE="$TEST_ROOT/review-state"
printf 'Do not send\n30s\nEnter\nn\n\033' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$REVIEW_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/review-tmux.log" \
    TMUX_SEND_DELAYED_PANE_ID='%42' \
    TMUX_SEND_DELAYED_DISPLAY_TARGET='work:1.0' \
    TMUX_SEND_DELAYED_CLIENT_NAME='client-a' \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$SCHEDULE_POPUP" --form >/dev/null 2>&1 || true
if [ ! -d "$REVIEW_STATE/jobs" ] || ! find "$REVIEW_STATE/jobs" -mindepth 1 -maxdepth 1 -type d | rg -q .; then
    pass 'declining the review does not schedule a job'
else
    fail 'declining the review does not schedule a job'
    for job_dir in "$REVIEW_STATE"/jobs/*; do
        [ -d "$job_dir" ] || continue
        env TMUX_SEND_DELAYED_STATE_DIR="$REVIEW_STATE" "$SCHEDULER" cancel "${job_dir##*/}" >/dev/null
    done
fi

REVIEW_ESCAPE_STATE="$TEST_ROOT/review-escape-state"
REVIEW_ESCAPE_OUTPUT="$(printf 'Cancel at review\n30s\nEnter\n\033' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$REVIEW_ESCAPE_STATE" \
    TMUX_TEST_LOG="$TEST_ROOT/review-escape-tmux.log" \
    TMUX_SEND_DELAYED_PANE_ID='%42' \
    TMUX_SEND_DELAYED_DISPLAY_TARGET='work:1.0' \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$SCHEDULE_POPUP" --form 2>&1)"
assert_output 'Escape closes directly from the review screen' '1' bash -c "printf '%s' \"\$1\" | rg -F -o 'Target  work:1.0' | wc -l | tr -d ' '" _ "$REVIEW_ESCAPE_OUTPUT"

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
PREVIEW_OUTPUT="$(env \
    TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" \
    "$LIST_POPUP" --preview-job "$LIST_JOB" 2>&1 || true)"
assert_output 'job preview shows complete scheduling details' '1' bash -c "printf '%s' \"\$1\" | rg -q 'Target.*work:1.0' && printf '%s' \"\$1\" | rg -q 'Pane.*%42' && printf '%s' \"\$1\" | rg -q 'Text.*Review deployment' && printf '%s' \"\$1\" | rg -q 'Backend.*background' && printf '%s' \"\$1\" | rg -q 'Job ID.*$LIST_JOB' && printf 1" _ "$PREVIEW_OUTPUT"
CONTROL_JOB="$(schedule_test_job "$LIST_STATE" "$LIST_LOG" 1 30 $'Alert \033[31mred')"
CONTROL_PREVIEW="$(env \
    TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" \
    "$LIST_POPUP" --preview-job "$CONTROL_JOB" 2>&1 || true)"
if [[ "$CONTROL_PREVIEW" != *$'\033'* ]] && [[ "$CONTROL_PREVIEW" == *'Alert '*'red'* ]]; then
    pass 'job preview strips terminal control characters'
else
    fail 'job preview strips terminal control characters'
fi
assert_fails 'job preview rejects unsafe job IDs' env \
    TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" \
    "$LIST_POPUP" --preview-job '../outside'
assert_fails 'job preview rejects parent-directory job IDs' env \
    TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" \
    "$LIST_POPUP" --preview-job '..'
env TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" "$SCHEDULER" cancel "$CONTROL_JOB" >/dev/null
LIST_OUTPUT="$(printf '1\ny\n\033' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" \
    TMUX_TEST_LOG="$LIST_LOG" \
    TMUX_SEND_DELAYED_CLIENT_NAME='client-a' \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$LIST_POPUP" --form 2>&1)"
assert_output 'list popup shows target, text, and remaining time' '1' bash -c "printf '%s' \"\$1\" | rg -q 'work:1.0.*Review deployment.*[0-9].*[smhd]' && printf 1" _ "$LIST_OUTPUT"
assert_contains 'shows cancellation success to the triggering client' "$LIST_LOG" $'display-message\t-c\tclient-a\t-d\t3000\tCancelled delayed send -> work:1.0'
if [ ! -d "$LIST_STATE/jobs/$LIST_JOB" ]; then
    pass 'list popup cancels the selected pending job'
else
    fail 'list popup cancels the selected pending job'
    env TMUX_SEND_DELAYED_STATE_DIR="$LIST_STATE" "$SCHEDULER" cancel "$LIST_JOB" >/dev/null
fi

LIST_FORMAT_STATE="$TEST_ROOT/list-format-state"
LIST_FORMAT_LOG="$TEST_ROOT/list-format-tmux.log"
LIST_FORMAT_JOB="$(env \
    PATH="$FIXTURES_DIR:$PATH" \
    TMUX_SEND_DELAYED_STATE_DIR="$LIST_FORMAT_STATE" \
    TMUX_TEST_LOG="$LIST_FORMAT_LOG" \
    TMUX_TEST_TARGET_EXISTS=1 \
    "$SCHEDULER" schedule \
        --target '%42' \
        --display-target 'hash#{pane_id}:1.0' \
        --text 'Literal cancellation target' \
        --key 'Enter' \
        --delay 60)"
printf '1\ny\n\033' | env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$LIST_FORMAT_STATE" \
    TMUX_TEST_LOG="$LIST_FORMAT_LOG" \
    TMUX_SEND_DELAYED_CLIENT_NAME='client-a' \
    SEND_DELAYED_FORCE_PLAIN=1 \
    "$LIST_POPUP" --form >/dev/null 2>&1
assert_contains 'keeps tmux formats literal in cancellation feedback' "$LIST_FORMAT_LOG" 'Cancelled delayed send -> hash##{pane_id}:1.0'
if [ -d "$LIST_FORMAT_STATE/jobs/$LIST_FORMAT_JOB" ]; then
    env TMUX_SEND_DELAYED_STATE_DIR="$LIST_FORMAT_STATE" "$SCHEDULER" cancel "$LIST_FORMAT_JOB" >/dev/null
fi

FZF_STATE="$TEST_ROOT/fzf-state"
FZF_TMUX_LOG="$TEST_ROOT/fzf-tmux.log"
FZF_LOG="$TEST_ROOT/fzf.log"
FZF_GUM_LOG="$TEST_ROOT/fzf-gum.log"
FZF_JOB_ONE="$(schedule_test_job "$FZF_STATE" "$FZF_TMUX_LOG" 1 60 'First searchable job')"
FZF_JOB_TWO="$(schedule_test_job "$FZF_STATE" "$FZF_TMUX_LOG" 1 60 'Second searchable job')"
FZF_DEFAULT_FILE="$TEST_ROOT/fzf-default-opts"
printf '%s\n' '--height=40%' > "$FZF_DEFAULT_FILE"
printf 'y\n' | env \
    PATH="$ROOT_DIR/tests/fixtures-fzf:$ROOT_DIR/tests/fixtures-gum:$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$FZF_STATE" \
    TMUX_TEST_LOG="$FZF_TMUX_LOG" \
    FZF_TEST_LOG="$FZF_LOG" \
    FZF_TEST_MATCH='Second searchable job' \
    FZF_TEST_ACTION='ctrl-x' \
    GUM_TEST_LOG="$FZF_GUM_LOG" \
    FZF_DEFAULT_OPTS='--tmux=center,90%' \
    FZF_DEFAULT_OPTS_FILE="$FZF_DEFAULT_FILE" \
    SEND_DELAYED_FORCE_FZF=1 \
    SEND_DELAYED_FORCE_GUM=1 \
    "$LIST_POPUP" --form >/dev/null 2>&1 || true
assert_contains 'uses fzf for searchable pending jobs' "$FZF_LOG" $'fzf\t'
assert_contains 'fzf exposes palette actions' "$FZF_LOG" '--expect=enter,ctrl-x,ctrl-r'
assert_contains 'fzf renders full job details in a preview' "$FZF_LOG" '--preview'
assert_contains 'fzf keeps its actions concise and accurate' "$FZF_LOG" 'Enter/Ctrl-X cancel | Ctrl-R refresh | Esc close'
assert_contains 'fzf uses a narrow-terminal-friendly preview' "$FZF_LOG" 'down,45%,wrap'
assert_contains 'fzf ignores global layout options that could nest the palette' "$FZF_LOG" $'environment\t\t'
assert_not_contains 'fzf takes precedence over gum' "$FZF_GUM_LOG" $'gum\tfilter'
if [ -d "$FZF_STATE/jobs/$FZF_JOB_ONE" ] && [ ! -d "$FZF_STATE/jobs/$FZF_JOB_TWO" ]; then
    pass 'fzf cancels only the selected pending job'
else
    fail 'fzf cancels only the selected pending job'
fi
env TMUX_SEND_DELAYED_STATE_DIR="$FZF_STATE" "$SCHEDULER" cancel "$FZF_JOB_ONE" >/dev/null

FZF_FALLBACK_STATE="$TEST_ROOT/fzf-fallback-state"
FZF_FALLBACK_TMUX_LOG="$TEST_ROOT/fzf-fallback-tmux.log"
FZF_FALLBACK_LOG="$TEST_ROOT/fzf-fallback.log"
FZF_FALLBACK_GUM_LOG="$TEST_ROOT/fzf-fallback-gum.log"
FZF_FALLBACK_JOB="$(schedule_test_job "$FZF_FALLBACK_STATE" "$FZF_FALLBACK_TMUX_LOG" 1 60 'Fallback to gum')"
env \
    PATH="$ROOT_DIR/tests/fixtures-fzf:$ROOT_DIR/tests/fixtures-gum:$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$FZF_FALLBACK_STATE" \
    TMUX_TEST_LOG="$FZF_FALLBACK_TMUX_LOG" \
    FZF_TEST_LOG="$FZF_FALLBACK_LOG" \
    FZF_TEST_EXIT_STATUS=2 \
    GUM_TEST_LOG="$FZF_FALLBACK_GUM_LOG" \
    GUM_TEST_MATCH='Fallback to gum' \
    SEND_DELAYED_FORCE_FZF=1 \
    SEND_DELAYED_FORCE_GUM=1 \
    "$LIST_POPUP" --form >/dev/null 2>&1 || true
assert_contains 'falls back to gum when fzf cannot start' "$FZF_FALLBACK_GUM_LOG" $'gum\tfilter'
if [ ! -d "$FZF_FALLBACK_STATE/jobs/$FZF_FALLBACK_JOB" ]; then
    pass 'fallback selector cancels the selected pending job'
else
    fail 'fallback selector cancels the selected pending job'
    env TMUX_SEND_DELAYED_STATE_DIR="$FZF_FALLBACK_STATE" "$SCHEDULER" cancel "$FZF_FALLBACK_JOB" >/dev/null
fi

RACE_STATE="$TEST_ROOT/race-state"
RACE_TMUX_LOG="$TEST_ROOT/race-tmux.log"
RACE_FZF_LOG="$TEST_ROOT/race-fzf.log"
RACE_JOB="$(schedule_test_job "$RACE_STATE" "$RACE_TMUX_LOG" 1 60 'Completes while selected')"
env \
    PATH="$ROOT_DIR/tests/fixtures-fzf:$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$RACE_STATE" \
    TMUX_SEND_DELAYED_CLIENT_NAME='client-a' \
    TMUX_TEST_LOG="$RACE_TMUX_LOG" \
    FZF_TEST_LOG="$RACE_FZF_LOG" \
    FZF_TEST_MATCH='Completes while selected' \
    FZF_TEST_MOVE_SELECTED=1 \
    SEND_DELAYED_FORCE_FZF=1 \
    "$LIST_POPUP" --form >/dev/null 2>&1 || true
assert_contains 'reports when a selected job is no longer pending' "$RACE_TMUX_LOG" $'display-message\t-c\tclient-a\t-d\t3000\tSelected delayed send is no longer pending'
if [ -d "$RACE_STATE/running/$RACE_JOB" ]; then
    mv "$RACE_STATE/running/$RACE_JOB" "$RACE_STATE/jobs/$RACE_JOB"
    env TMUX_SEND_DELAYED_STATE_DIR="$RACE_STATE" "$SCHEDULER" cancel "$RACE_JOB" >/dev/null
fi

GUM_STATE="$TEST_ROOT/gum-state"
GUM_TMUX_LOG="$TEST_ROOT/gum-tmux.log"
GUM_LOG="$TEST_ROOT/gum.log"
GUM_JOB="$(schedule_test_job "$GUM_STATE" "$GUM_TMUX_LOG" 1 60 'Filter with gum')"
env \
    PATH="$ROOT_DIR/tests/fixtures-gum:$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_SEND_DELAYED_STATE_DIR="$GUM_STATE" \
    TMUX_TEST_LOG="$GUM_TMUX_LOG" \
    GUM_TEST_LOG="$GUM_LOG" \
    GUM_TEST_MATCH='Filter with gum' \
    SEND_DELAYED_FORCE_GUM=1 \
    "$LIST_POPUP" --form >/dev/null 2>&1 || true
assert_contains 'uses gum filter when fzf is unavailable' "$GUM_LOG" $'gum\tfilter'
if [ ! -d "$GUM_STATE/jobs/$GUM_JOB" ]; then
    pass 'gum filter cancels the selected pending job'
else
    fail 'gum filter cancels the selected pending job'
    env TMUX_SEND_DELAYED_STATE_DIR="$GUM_STATE" "$SCHEDULER" cancel "$GUM_JOB" >/dev/null
fi

ENTRYPOINT_LOG="$TEST_ROOT/entrypoint-tmux.log"
env PATH="$FIXTURES_DIR:/usr/bin:/bin" TMUX_TEST_LOG="$ENTRYPOINT_LOG" bash "$PLUGIN_ENTRYPOINT" >/dev/null 2>&1 || true
assert_contains 'binds the requested default schedule key with a description' "$ENTRYPOINT_LOG" $'bind-key\t-N\tSchedule delayed pane input\tT\trun-shell\t-b'
assert_contains 'binds a non-colliding default list key with a description' "$ENTRYPOINT_LOG" $'bind-key\t-N\tManage delayed pane input\tC-t\trun-shell\t-b'
assert_contains 'passes pane ID format expansion from the key binding' "$ENTRYPOINT_LOG" '#{pane_id}'
assert_contains 'passes client format expansion from the key binding' "$ENTRYPOINT_LOG" '#{client_name}'

DISABLED_SCHEDULE_OPTIONS="$TEST_ROOT/disabled-schedule-options"
printf '%s\t%s\n' '@send-delayed-key' 'none' > "$DISABLED_SCHEDULE_OPTIONS"
DISABLED_SCHEDULE_LOG="$TEST_ROOT/disabled-schedule.log"
env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_TEST_LOG="$DISABLED_SCHEDULE_LOG" \
    TMUX_TEST_OPTIONS_FILE="$DISABLED_SCHEDULE_OPTIONS" \
    bash "$PLUGIN_ENTRYPOINT" >/dev/null 2>&1 || true
assert_not_contains 'can disable the schedule binding' "$DISABLED_SCHEDULE_LOG" 'popup-schedule.sh'
assert_contains 'keeps the list binding when schedule is disabled' "$DISABLED_SCHEDULE_LOG" 'popup-list.sh'

DISABLED_LIST_OPTIONS="$TEST_ROOT/disabled-list-options"
printf '%s\t%s\n' '@send-delayed-list-key' 'none' > "$DISABLED_LIST_OPTIONS"
DISABLED_LIST_LOG="$TEST_ROOT/disabled-list.log"
env \
    PATH="$FIXTURES_DIR:/usr/bin:/bin" \
    TMUX_TEST_LOG="$DISABLED_LIST_LOG" \
    TMUX_TEST_OPTIONS_FILE="$DISABLED_LIST_OPTIONS" \
    bash "$PLUGIN_ENTRYPOINT" >/dev/null 2>&1 || true
assert_not_contains 'can disable the list binding' "$DISABLED_LIST_LOG" 'popup-list.sh'
assert_contains 'keeps the schedule binding when list is disabled' "$DISABLED_LIST_LOG" 'popup-schedule.sh'

printf '1..%d\n' "$((PASSED + FAILED))"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
