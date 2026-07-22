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
