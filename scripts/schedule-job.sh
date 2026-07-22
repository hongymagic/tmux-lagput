#!/usr/bin/env bash

set -u

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STATE_LOCK_DIR=''

usage() {
    printf '%s\n' \
        'Usage:' \
        '  schedule-job.sh schedule --target PANE_ID --display-target TARGET --text TEXT --key KEY --delay SECONDS [--use-systemd]' \
        '  schedule-job.sh cancel JOB_ID' \
        '  schedule-job.sh reconcile (--older-than SECONDS | --all)' \
        '  schedule-job.sh cleanup' \
        '  schedule-job.sh enable' >&2
    exit 2
}

resolve_state_dir() {
    if [ -n "${TMUX_SEND_DELAYED_STATE_DIR:-}" ]; then
        printf '%s\n' "$TMUX_SEND_DELAYED_STATE_DIR"
        return
    fi

    local configured_state_dir=''
    if command -v tmux >/dev/null 2>&1; then
        configured_state_dir="$(tmux show-option -gqv '@send-delayed-state-dir' 2>/dev/null || true)"
    fi

    if [ -n "$configured_state_dir" ]; then
        printf '%s\n' "$configured_state_dir"
    else
        printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/tmux-lagput"
    fi
}

ensure_state_layout() {
    local state_dir="$1"
    umask 077
    mkdir -p \
        "$state_dir/jobs" \
        "$state_dir/running" \
        "$state_dir/staging" \
        "$state_dir/cancelled" \
        "$state_dir/finishing" \
        "$state_dir/abandoned"
}

read_field() {
    local field_path="$1"
    local value=''

    if [ -f "$field_path" ]; then
        IFS= read -r value < "$field_path" || true
    fi
    printf '%s' "$value"
}

write_field() {
    local job_dir="$1"
    local field_name="$2"
    local value="$3"
    printf '%s\n' "$value" > "$job_dir/$field_name"
}

process_is_running() {
    local process_id="$1"
    local process_state

    kill -0 "$process_id" 2>/dev/null || return 1
    process_state="$(ps -p "$process_id" -o stat= 2>/dev/null || true)"
    case "$process_state" in
        *Z*) return 1 ;;
    esac
    return 0
}

acquire_state_lock() {
    local state_dir="$1"
    local lock_dir="$state_dir/.lifecycle-lock"
    local owner_pid
    local attempts=200

    if [ "$STATE_LOCK_DIR" = "$lock_dir" ]; then
        return 0
    fi
    while [ "$attempts" -gt 0 ]; do
        if mkdir "$lock_dir" 2>/dev/null; then
            if write_field "$lock_dir" 'owner-pid' "$$"; then
                STATE_LOCK_DIR="$lock_dir"
                return 0
            fi
            rm -f -- "$lock_dir/owner-pid"
            rmdir "$lock_dir" 2>/dev/null || true
            return 1
        fi

        owner_pid="$(read_field "$lock_dir/owner-pid")"
        if [[ ! "$owner_pid" =~ ^[0-9]+$ ]] || ! process_is_running "$owner_pid"; then
            rm -f -- "$lock_dir/owner-pid"
            rmdir "$lock_dir" 2>/dev/null || true
        fi
        attempts=$((attempts - 1))
        sleep 0.05
    done
    return 1
}

release_state_lock() {
    local owner_pid

    [ -n "$STATE_LOCK_DIR" ] || return 0
    owner_pid="$(read_field "$STATE_LOCK_DIR/owner-pid")"
    if [ "$owner_pid" = "$$" ]; then
        rm -f -- "$STATE_LOCK_DIR/owner-pid"
        rmdir "$STATE_LOCK_DIR" 2>/dev/null || true
    fi
    STATE_LOCK_DIR=''
}

history_safe() {
    local value="$1"
    value="${value//$'\t'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "$value"
}

append_history() {
    local state_dir="$1"
    local job_id="$2"
    local status="$3"
    local target="$4"
    local detail="$5"
    local timestamp

    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$timestamp" \
        "$(history_safe "$job_id")" \
        "$(history_safe "$status")" \
        "$(history_safe "$target")" \
        "$(history_safe "$detail")" >> "$state_dir/jobs-history.log"
}

valid_job_id() {
    case "$1" in
        .|..) return 1 ;;
    esac
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

socket_identity() {
    local socket_path="$1"
    local identity=''

    if identity="$(stat -c '%d:%i' "$socket_path" 2>/dev/null)"; then
        printf '%s' "$identity"
        return 0
    fi
    if identity="$(stat -f '%d:%i' "$socket_path" 2>/dev/null)"; then
        printf '%s' "$identity"
        return 0
    fi
    return 1
}

systemd_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    printf '"%s"' "$value"
}

safe_remove_unit_file() {
    local unit_file="$1"
    local expected_name="$2"

    [ -n "$unit_file" ] || return 0
    [ "${unit_file##*/}" = "$expected_name" ] || return 1
    rm -f -- "$unit_file"
}

systemd_unit_is_inactive() {
    local unit="$1"
    local active_state=''

    active_state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
    case "$active_state" in
        inactive|failed|unknown) return 0 ;;
        *) return 1 ;;
    esac
}

systemd_unit_is_absent() {
    local unit="$1"
    local enabled_state=''

    enabled_state="$(systemctl --user is-enabled "$unit" 2>/dev/null || true)"
    [ "$enabled_state" = 'not-found' ]
}

systemd_teardown_is_complete() {
    local timer_unit="$1"
    local service_unit="$2"
    local service_file="$3"
    local timer_file="$4"
    local stop_service="${5:-1}"

    [ ! -e "$service_file" ] && [ ! -e "$timer_file" ] || return 1
    systemctl --user daemon-reload >/dev/null 2>&1 || return 1
    systemd_unit_is_inactive "$timer_unit" || return 1
    systemd_unit_is_absent "$timer_unit" || return 1
    systemd_unit_is_absent "$service_unit" || return 1
    if [ "$stop_service" -eq 1 ]; then
        systemd_unit_is_inactive "$service_unit" || return 1
    fi
    return 0
}

cleanup_systemd_units() {
    local timer_unit="$1"
    local service_unit="$2"
    local service_file="$3"
    local timer_file="$4"
    local stop_service="${5:-1}"
    local cleanup_status=0

    [ -n "$timer_unit" ] || return 0
    [[ "$timer_unit" =~ ^tmux-lagput-[A-Za-z0-9._-]+\.timer$ ]] || return 1
    [[ "$service_unit" =~ ^tmux-lagput-[A-Za-z0-9._-]+\.service$ ]] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    if ! systemctl --user disable --now "$timer_unit" >/dev/null 2>&1; then
        systemd_teardown_is_complete \
            "$timer_unit" \
            "$service_unit" \
            "$service_file" \
            "$timer_file" \
            "$stop_service" || return 1
        return 0
    fi
    if [ "$stop_service" -eq 1 ] && [ -n "$service_unit" ]; then
        if ! systemctl --user stop "$service_unit" >/dev/null 2>&1; then
            systemd_unit_is_inactive "$service_unit" || return 1
        fi
    fi
    safe_remove_unit_file "$service_file" "$service_unit" || cleanup_status=1
    safe_remove_unit_file "$timer_file" "$timer_unit" || cleanup_status=1
    systemctl --user daemon-reload >/dev/null 2>&1 || cleanup_status=1
    return "$cleanup_status"
}

install_systemd_job() {
    local state_dir="$1"
    local job_id="$2"
    local job_dir="$3"
    local worker_token="$4"
    local run_at
    local unit_base="tmux-lagput-$job_id"
    local service_unit="$unit_base.service"
    local timer_unit="$unit_base.timer"
    local user_unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local service_file="$user_unit_dir/$service_unit"
    local timer_file="$user_unit_dir/$timer_unit"
    local service_temp="$service_file.tmp.$$"
    local timer_temp="$timer_file.tmp.$$"

    if [ "$(uname -s 2>/dev/null || true)" != 'Linux' ] || ! command -v systemctl >/dev/null 2>&1; then
        return 1
    fi
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        return 1
    fi
    case "$state_dir$SCRIPT_PATH$user_unit_dir" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac

    run_at="$(read_field "$job_dir/run-at")"
    mkdir -p "$user_unit_dir"

    {
        printf '[Unit]\nDescription=Send delayed tmux input (%s)\n\n' "$job_id"
        printf '[Service]\nType=oneshot\nExecStart=%s --run-systemd %s %s %s\n' \
            "$(systemd_quote "$SCRIPT_PATH")" \
            "$(systemd_quote "$state_dir")" \
            "$(systemd_quote "$job_id")" \
            "$(systemd_quote "$worker_token")"
    } > "$service_temp" || return 1

    {
        printf '[Unit]\nDescription=Timer for delayed tmux input (%s)\n\n' "$job_id"
        printf '[Timer]\nOnCalendar=@%s\nPersistent=true\nAccuracySec=1s\nUnit=%s\n\n' "$run_at" "$service_unit"
        printf '[Install]\nWantedBy=timers.target\n'
    } > "$timer_temp" || {
        rm -f -- "$service_temp"
        return 1
    }

    if ! mv "$service_temp" "$service_file" || ! mv "$timer_temp" "$timer_file"; then
        rm -f -- "$service_temp" "$timer_temp" "$service_file" "$timer_file"
        return 1
    fi
    if ! write_field "$job_dir" 'backend' 'systemd' || \
        ! write_field "$job_dir" 'timer-unit' "$timer_unit" || \
        ! write_field "$job_dir" 'service-unit' "$service_unit" || \
        ! write_field "$job_dir" 'unit-dir' "$user_unit_dir" || \
        ! write_field "$job_dir" 'service-file' "$service_file" || \
        ! write_field "$job_dir" 'timer-file' "$timer_file"; then
        cleanup_systemd_units "$timer_unit" "$service_unit" "$service_file" "$timer_file" 1 || true
        return 1
    fi

    if systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable --now "$timer_unit" >/dev/null 2>&1; then
        return 0
    fi

    cleanup_systemd_units "$timer_unit" "$service_unit" "$service_file" "$timer_file" 1 || return 2
    return 1
}

launch_background_job() {
    local state_dir="$1"
    local job_id="$2"
    local job_dir="$3"
    local worker_token="$4"
    local launcher_pid
    local worker_pid=''
    local attempts=50

    write_field "$job_dir" 'backend' 'background' || return 1

    if command -v setsid >/dev/null 2>&1; then
        nohup setsid "$SCRIPT_PATH" --run-staged "$state_dir" "$job_id" "$worker_token" </dev/null >/dev/null 2>&1 &
    else
        nohup "$SCRIPT_PATH" --run-staged "$state_dir" "$job_id" "$worker_token" </dev/null >/dev/null 2>&1 &
    fi
    launcher_pid=$!

    while [ "$attempts" -gt 0 ]; do
        if [ -f "$job_dir/worker-ready" ]; then
            worker_pid="$(read_field "$job_dir/worker-pid")"
            if [[ "$worker_pid" =~ ^[0-9]+$ ]] && kill -0 "$worker_pid" 2>/dev/null; then
                return 0
            fi
        fi
        attempts=$((attempts - 1))
        sleep 0.05
    done

    if ! stop_background_worker "$state_dir" "$job_id" "$job_dir"; then
        return 2
    fi
    kill -TERM "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
    return 1
}

stop_background_worker() {
    local state_dir="$1"
    local job_id="$2"
    local job_dir="$3"
    local worker_pid
    local worker_command
    local worker_token
    local expected_command="$SCRIPT_PATH --run-staged $state_dir $job_id"
    local attempts

    worker_pid="$(read_field "$job_dir/worker-pid")"
    worker_token="$(read_field "$job_dir/worker-token")"
    if [ -n "$worker_token" ]; then
        expected_command="$expected_command $worker_token"
    fi
    [[ "$worker_pid" =~ ^[0-9]+$ ]] || return 0
    process_is_running "$worker_pid" || return 0
    worker_command="$(ps -p "$worker_pid" -o args= 2>/dev/null || true)"
    case "$worker_command" in
        *"$expected_command"*) ;;
        *) return 1 ;;
    esac
    kill -TERM "$worker_pid" 2>/dev/null || {
        process_is_running "$worker_pid" && return 1
        return 0
    }

    attempts=50
    while [ "$attempts" -gt 0 ]; do
        process_is_running "$worker_pid" || return 0
        attempts=$((attempts - 1))
        sleep 0.05
    done
    return 1
}

create_job() {
    local target=''
    local display_target=''
    local text=''
    local key=''
    local delay=''
    local use_systemd=0
    local state_dir
    local created_at
    local run_at
    local tmux_binary
    local tmux_environment="${TMUX:-}"
    local tmux_socket=''
    local tmux_socket_identity=''
    local job_id=''
    local job_dir=''
    local worker_token=''
    local backend=''
    local systemd_status=0
    local launch_status=0
    local teardown_status=0
    local attempt=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target|--display-target|--text|--key|--delay)
                [ "$#" -ge 2 ] || usage
                case "$1" in
                    --target) target="$2" ;;
                    --display-target) display_target="$2" ;;
                    --text) text="$2" ;;
                    --key) key="$2" ;;
                    --delay) delay="$2" ;;
                esac
                shift 2
                ;;
            --use-systemd)
                use_systemd=1
                shift
                ;;
            *) usage ;;
        esac
    done

    if [ -z "$target" ] || [ -z "$display_target" ] || [ -z "$text" ]; then
        printf 'Target, display target, and text are required.\n' >&2
        exit 1
    fi
    if [[ ! "$delay" =~ ^[0-9]+$ ]] || [ "$delay" -le 0 ]; then
        printf 'Delay must be a positive integer number of seconds.\n' >&2
        exit 1
    fi
    case "$target$display_target$text$key" in
        *$'\n'*|*$'\r'*)
            printf 'Job fields must be single-line values.\n' >&2
            exit 1
            ;;
    esac

    tmux_binary="$(command -v tmux 2>/dev/null || true)"
    if [ -z "$tmux_binary" ]; then
        printf 'tmux was not found in PATH.\n' >&2
        exit 1
    fi
    if [ -n "$tmux_environment" ]; then
        tmux_socket="${tmux_environment%%,*}"
        tmux_socket_identity="$(socket_identity "$tmux_socket" 2>/dev/null || true)"
    fi

    state_dir="$(resolve_state_dir)"
    if ! ensure_state_layout "$state_dir" || ! acquire_state_lock "$state_dir"; then
        printf 'Could not lock the delayed-job state directory.\n' >&2
        exit 1
    fi
    trap release_state_lock EXIT
    trap 'release_state_lock; exit 1' HUP INT TERM
    if [ -f "$state_dir/disabled" ]; then
        printf 'Scheduling is disabled after cleanup; reload the plugin to enable it.\n' >&2
        exit 1
    fi
    created_at="$(date +%s)"
    run_at=$((created_at + delay))

    while [ "$attempt" -lt 100 ]; do
        job_id="${created_at}-$$-${RANDOM:-0}"
        job_dir="$state_dir/staging/$job_id"
        if [ ! -e "$state_dir/jobs/$job_id" ] && \
            [ ! -e "$state_dir/running/$job_id" ] && \
            [ ! -e "$state_dir/finishing/$job_id" ] && \
            [ ! -e "$state_dir/abandoned/$job_id" ] && \
            mkdir "$job_dir" 2>/dev/null; then
            break
        fi
        job_id=''
        attempt=$((attempt + 1))
    done
    if [ -z "$job_id" ]; then
        printf 'Could not allocate a unique job ID.\n' >&2
        exit 1
    fi

    worker_token="${job_id}-${RANDOM:-0}"
    if ! write_field "$job_dir" 'target' "$target" || \
        ! write_field "$job_dir" 'display-target' "$display_target" || \
        ! write_field "$job_dir" 'text' "$text" || \
        ! write_field "$job_dir" 'key' "$key" || \
        ! write_field "$job_dir" 'created-at' "$created_at" || \
        ! write_field "$job_dir" 'run-at' "$run_at" || \
        ! write_field "$job_dir" 'tmux-binary' "$tmux_binary" || \
        ! write_field "$job_dir" 'tmux-environment' "$tmux_environment" || \
        ! write_field "$job_dir" 'tmux-socket' "$tmux_socket" || \
        ! write_field "$job_dir" 'tmux-socket-identity' "$tmux_socket_identity" || \
        ! write_field "$job_dir" 'worker-token' "$worker_token"; then
        rm -rf -- "$job_dir"
        printf 'Could not persist the delayed job.\n' >&2
        exit 1
    fi

    if [ "$use_systemd" -eq 1 ]; then
        install_systemd_job "$state_dir" "$job_id" "$job_dir" "$worker_token"
        systemd_status=$?
        case "$systemd_status" in
            0) backend='systemd' ;;
            1)
                rm -f -- \
                    "$job_dir/backend" \
                    "$job_dir/timer-unit" \
                    "$job_dir/service-unit" \
                    "$job_dir/unit-dir" \
                    "$job_dir/service-file" \
                    "$job_dir/timer-file"
                ;;
            *)
                printf 'Could not safely arm the systemd timer.\n' >&2
                exit 1
                ;;
        esac
    fi
    if [ -z "$backend" ]; then
        launch_background_job "$state_dir" "$job_id" "$job_dir" "$worker_token"
        launch_status=$?
        if [ "$launch_status" -ne 0 ]; then
            if [ "$launch_status" -eq 1 ]; then
                rm -rf -- "$job_dir"
            fi
            printf 'Could not start the detached scheduling worker.\n' >&2
            exit 1
        fi
        backend='background'
    fi

    if ! write_field "$job_dir" 'ready' '1' || ! mv "$job_dir" "$state_dir/jobs/$job_id"; then
        teardown_status=0
        if [ "$backend" = 'background' ]; then
            stop_background_worker "$state_dir" "$job_id" "$job_dir" || teardown_status=1
        else
            cleanup_systemd_units \
                "$(read_field "$job_dir/timer-unit")" \
                "$(read_field "$job_dir/service-unit")" \
                "$(read_field "$job_dir/service-file")" \
                "$(read_field "$job_dir/timer-file")" \
                1 || teardown_status=1
        fi
        if [ "$teardown_status" -eq 0 ]; then
            rm -rf -- "$job_dir"
        fi
        printf 'Could not publish the delayed job.\n' >&2
        exit 1
    fi

    release_state_lock
    trap - EXIT HUP INT TERM
    printf '%s\n' "$job_id"
}

finish_running_job() {
    local state_dir="$1"
    local job_id="$2"
    local status="$3"
    local display_target="$4"
    local detail="$5"
    local running_dir="$state_dir/running/$job_id"
    local finishing_dir="$state_dir/finishing/$job_id"

    if ! write_field "$running_dir" 'terminal-status' "$status" || \
        ! write_field "$running_dir" 'terminal-target' "$display_target" || \
        ! write_field "$running_dir" 'terminal-detail' "$detail" || \
        ! mv "$running_dir" "$finishing_dir" 2>/dev/null; then
        return 1
    fi
    complete_transitional_job "$state_dir" "$job_id" "$finishing_dir" 0 0
}

run_job_now() {
    local state_dir="$1"
    local job_id="$2"
    local pending_dir="$state_dir/jobs/$job_id"
    local running_dir="$state_dir/running/$job_id"
    local target
    local display_target
    local text
    local key
    local tmux_binary
    local tmux_environment
    local tmux_socket
    local expected_socket_identity
    local current_socket_identity
    local actual_target

    ensure_state_layout "$state_dir" || exit 1
    valid_job_id "$job_id" || exit 1
    acquire_state_lock "$state_dir" || exit 1
    trap release_state_lock EXIT
    trap 'release_state_lock; exit 1' HUP INT TERM
    if [ -f "$state_dir/disabled" ] || [ ! -f "$pending_dir/ready" ]; then
        release_state_lock
        trap - EXIT HUP INT TERM
        exit 0
    fi
    if ! write_field "$pending_dir" 'claimed-at' "$(date +%s)"; then
        release_state_lock
        exit 1
    fi
    if ! mv "$pending_dir" "$running_dir" 2>/dev/null; then
        release_state_lock
        trap - EXIT HUP INT TERM
        exit 0
    fi
    release_state_lock
    trap - EXIT HUP INT TERM

    target="$(read_field "$running_dir/target")"
    display_target="$(read_field "$running_dir/display-target")"
    text="$(read_field "$running_dir/text")"
    key="$(read_field "$running_dir/key")"
    tmux_binary="$(read_field "$running_dir/tmux-binary")"
    tmux_environment="$(read_field "$running_dir/tmux-environment")"
    tmux_socket="$(read_field "$running_dir/tmux-socket")"
    expected_socket_identity="$(read_field "$running_dir/tmux-socket-identity")"

    if [ -n "$expected_socket_identity" ]; then
        current_socket_identity="$(socket_identity "$tmux_socket" 2>/dev/null || true)"
        if [ "$current_socket_identity" != "$expected_socket_identity" ]; then
            finish_running_job "$state_dir" "$job_id" 'failed' "$display_target" 'captured tmux server no longer exists'
            exit 1
        fi
    fi
    if [ -n "$tmux_environment" ]; then
        export TMUX="$tmux_environment"
    fi

    actual_target=''
    if [ -x "$tmux_binary" ]; then
        actual_target="$("$tmux_binary" display-message -p -t "$target" '#{pane_id}' 2>/dev/null || true)"
    fi
    if [ "$actual_target" != "$target" ]; then
        finish_running_job "$state_dir" "$job_id" 'failed' "$display_target" 'captured target pane no longer exists'
        exit 1
    fi

    if ! "$tmux_binary" send-keys -t "$target" -l -- "$text"; then
        finish_running_job "$state_dir" "$job_id" 'failed' "$display_target" 'sending literal text failed'
        exit 1
    fi
    if [ -n "$key" ] && ! "$tmux_binary" send-keys -t "$target" -- "$key"; then
        finish_running_job "$state_dir" "$job_id" 'failed' "$display_target" 'sending the trailing key failed'
        exit 1
    fi

    finish_running_job "$state_dir" "$job_id" 'sent' "$display_target" 'delayed input delivered'
}

run_job_after_delay() {
    local state_dir="$1"
    local job_id="$2"
    local pending_dir="$state_dir/jobs/$job_id"
    local run_at
    local now
    local remaining
    local sleep_pid=''

    if [ ! -d "$pending_dir" ]; then
        exit 0
    fi
    run_at="$(read_field "$pending_dir/run-at")"
    [[ "$run_at" =~ ^[0-9]+$ ]] || exit 1
    now="$(date +%s)"
    remaining=$((run_at - now))
    if [ "$remaining" -gt 0 ]; then
        sleep "$remaining" &
        sleep_pid=$!
        trap 'kill "$sleep_pid" 2>/dev/null || true; wait "$sleep_pid" 2>/dev/null || true; exit 0' TERM INT
        wait "$sleep_pid" 2>/dev/null || exit 0
        trap - TERM INT
    fi
    run_job_now "$state_dir" "$job_id"
}

run_staged_worker() {
    local state_dir="$1"
    local job_id="$2"
    local worker_token="$3"
    local staging_dir="$state_dir/staging/$job_id"
    local pending_dir="$state_dir/jobs/$job_id"
    local attempts=200

    ensure_state_layout "$state_dir" || exit 1
    valid_job_id "$job_id" || exit 1
    if [ ! -d "$staging_dir" ] || [ "$(read_field "$staging_dir/worker-token")" != "$worker_token" ]; then
        exit 1
    fi
    if ! write_field "$staging_dir" 'worker-pid' "$$" || \
        ! write_field "$staging_dir" 'worker-ready' '1'; then
        exit 1
    fi

    while [ "$attempts" -gt 0 ]; do
        if [ -f "$pending_dir/ready" ] && \
            [ "$(read_field "$pending_dir/worker-token")" = "$worker_token" ]; then
            run_job_after_delay "$state_dir" "$job_id"
            exit $?
        fi
        if [ ! -d "$staging_dir" ] && [ ! -d "$pending_dir" ]; then
            exit 0
        fi
        attempts=$((attempts - 1))
        sleep 0.05
    done
    exit 1
}

run_systemd_worker() {
    local state_dir="$1"
    local job_id="$2"
    local worker_token="$3"
    local pending_dir="$state_dir/jobs/$job_id"
    local attempts=200

    ensure_state_layout "$state_dir" || exit 1
    valid_job_id "$job_id" || exit 1
    while [ "$attempts" -gt 0 ]; do
        if [ -f "$pending_dir/ready" ] && \
            [ "$(read_field "$pending_dir/worker-token")" = "$worker_token" ]; then
            run_job_now "$state_dir" "$job_id"
            exit $?
        fi
        if [ ! -d "$state_dir/staging/$job_id" ] && [ ! -d "$pending_dir" ]; then
            exit 0
        fi
        attempts=$((attempts - 1))
        sleep 0.05
    done
    exit 1
}

cancel_job() {
    local job_id="${1:-}"
    local state_dir
    local pending_dir
    local cancelled_dir
    local display_target
    local acquired_here=0

    if [ -z "$job_id" ] || ! valid_job_id "$job_id"; then
        usage
    fi

    state_dir="$(resolve_state_dir)"
    ensure_state_layout "$state_dir" || return 1
    if [ -z "$STATE_LOCK_DIR" ]; then
        acquire_state_lock "$state_dir" || return 1
        acquired_here=1
    fi
    pending_dir="$state_dir/jobs/$job_id"
    cancelled_dir="$state_dir/cancelled/$job_id"
    if ! mv "$pending_dir" "$cancelled_dir" 2>/dev/null; then
        [ "$acquired_here" -eq 0 ] || release_state_lock
        printf 'Job is no longer pending: %s\n' "$job_id" >&2
        return 1
    fi

    display_target="$(read_field "$cancelled_dir/display-target")"
    if ! write_field "$cancelled_dir" 'terminal-status' 'cancelled' || \
        ! write_field "$cancelled_dir" 'terminal-target' "$display_target" || \
        ! write_field "$cancelled_dir" 'terminal-detail' 'cancelled by user' || \
        ! complete_transitional_job "$state_dir" "$job_id" "$cancelled_dir" 1 1; then
        [ "$acquired_here" -eq 0 ] || release_state_lock
        printf 'Could not safely cancel %s; metadata was retained for cleanup.\n' "$job_id" >&2
        return 1
    fi

    [ "$acquired_here" -eq 0 ] || release_state_lock
    printf 'Cancelled %s\n' "$job_id"
}

file_mtime() {
    local path="$1"
    local modified_at=''

    if modified_at="$(stat -c '%Y' "$path" 2>/dev/null)"; then
        printf '%s' "$modified_at"
        return 0
    fi
    if modified_at="$(stat -f '%m' "$path" 2>/dev/null)"; then
        printf '%s' "$modified_at"
        return 0
    fi
    return 1
}

cleanup_job_backend() {
    local state_dir="$1"
    local job_id="$2"
    local job_dir="$3"
    local stop_worker="${4:-1}"
    local stop_service="${5:-1}"
    local backend
    local timer_unit
    local service_unit
    local service_file
    local timer_file
    local unit_dir
    local expected_timer="tmux-lagput-$job_id.timer"
    local expected_service="tmux-lagput-$job_id.service"

    backend="$(read_field "$job_dir/backend")"
    if [ "$backend" = 'background' ] && [ "$stop_worker" -eq 1 ]; then
        stop_background_worker "$state_dir" "$job_id" "$job_dir" || return 1
    fi
    timer_unit="$(read_field "$job_dir/timer-unit")"
    service_unit="$(read_field "$job_dir/service-unit")"
    service_file="$(read_field "$job_dir/service-file")"
    timer_file="$(read_field "$job_dir/timer-file")"
    unit_dir="$(read_field "$job_dir/unit-dir")"
    if [ "$backend" = 'systemd' ] || [ -n "$timer_unit" ]; then
        [ "$timer_unit" = "$expected_timer" ] || return 1
        [ "$service_unit" = "$expected_service" ] || return 1
        case "$unit_dir$service_file$timer_file" in
            *$'\n'*|*$'\r'*) return 1 ;;
        esac
        [ "$service_file" = "$unit_dir/$expected_service" ] || return 1
        [ "$timer_file" = "$unit_dir/$expected_timer" ] || return 1
        cleanup_systemd_units \
            "$expected_timer" \
            "$expected_service" \
            "$service_file" \
            "$timer_file" \
            "$stop_service" || return 1
    fi
    return 0
}

complete_transitional_job() {
    local state_dir="$1"
    local job_id="$2"
    local job_dir="$3"
    local stop_worker="${4:-1}"
    local stop_service="${5:-1}"
    local default_status="${6:-}"
    local default_detail="${7:-}"
    local status
    local target
    local detail

    status="$(read_field "$job_dir/terminal-status")"
    target="$(read_field "$job_dir/terminal-target")"
    detail="$(read_field "$job_dir/terminal-detail")"
    [ -n "$status" ] || status="$default_status"
    [ -n "$target" ] || target="$(read_field "$job_dir/display-target")"
    [ -n "$detail" ] || detail="$default_detail"
    cleanup_job_backend "$state_dir" "$job_id" "$job_dir" "$stop_worker" "$stop_service" || return 1
    [ -n "$status" ] && [ -n "$detail" ] || return 1
    append_history "$state_dir" "$job_id" "$status" "$target" "$detail" || return 1
    rm -rf -- "$job_dir"
}

reconcile_running_jobs() {
    local mode="${1:-}"
    local threshold="${2:-}"
    local state_dir
    local running_dir
    local abandoned_dir
    local job_id
    local claimed_at
    local now
    local reconcile_status=0
    local acquired_here=0

    case "$mode" in
        --all) ;;
        --older-than)
            [[ "$threshold" =~ ^[0-9]+$ ]] || usage
            ;;
        *) usage ;;
    esac

    state_dir="$(resolve_state_dir)"
    ensure_state_layout "$state_dir" || return 1
    if [ -z "$STATE_LOCK_DIR" ]; then
        acquire_state_lock "$state_dir" || return 1
        acquired_here=1
    fi
    now="$(date +%s)"
    shopt -s nullglob
    for running_dir in "$state_dir"/running/*; do
        [ -d "$running_dir" ] || continue
        job_id="${running_dir##*/}"
        valid_job_id "$job_id" || continue
        claimed_at="$(read_field "$running_dir/claimed-at")"
        if [[ ! "$claimed_at" =~ ^[0-9]+$ ]]; then
            claimed_at="$(file_mtime "$running_dir" 2>/dev/null || true)"
        fi
        if [[ ! "$claimed_at" =~ ^[0-9]+$ ]]; then
            reconcile_status=1
            continue
        fi
        if [ "$mode" != '--all' ] && [ "$((now - claimed_at))" -lt "$threshold" ]; then
            continue
        fi

        abandoned_dir="$state_dir/abandoned/$job_id"
        if ! mv "$running_dir" "$abandoned_dir" 2>/dev/null; then
            continue
        fi
        if ! write_field "$abandoned_dir" 'terminal-status' 'failed' || \
            ! write_field "$abandoned_dir" 'terminal-target' "$(read_field "$abandoned_dir/display-target")" || \
            ! write_field "$abandoned_dir" 'terminal-detail' 'delivery outcome is unknown' || \
            ! complete_transitional_job "$state_dir" "$job_id" "$abandoned_dir" 1 1; then
            reconcile_status=1
            continue
        fi
    done
    shopt -u nullglob
    if [ "$mode" = '--all' ]; then
        cleanup_staging_jobs "$state_dir" --all || reconcile_status=1
    else
        cleanup_staging_jobs "$state_dir" --older-than "$threshold" || reconcile_status=1
    fi
    [ "$acquired_here" -eq 0 ] || release_state_lock
    return "$reconcile_status"
}

cleanup_staging_jobs() {
    local state_dir="$1"
    local mode="${2:---all}"
    local threshold="${3:-0}"
    local staging_dir
    local abandoned_dir
    local job_id
    local created_at
    local now
    local terminal_status='cancelled'
    local terminal_detail='cancelled during cleanup'
    local cleanup_status=0

    now="$(date +%s)"
    if [ "$mode" = '--older-than' ]; then
        terminal_status='failed'
        terminal_detail='scheduling did not complete'
    fi
    shopt -s nullglob
    for staging_dir in "$state_dir"/staging/*; do
        [ -d "$staging_dir" ] || continue
        job_id="${staging_dir##*/}"
        valid_job_id "$job_id" || continue
        created_at="$(read_field "$staging_dir/created-at")"
        if [[ ! "$created_at" =~ ^[0-9]+$ ]]; then
            created_at="$(file_mtime "$staging_dir" 2>/dev/null || true)"
        fi
        if [ "$mode" = '--older-than' ] && \
            { [[ ! "$created_at" =~ ^[0-9]+$ ]] || [ "$((now - created_at))" -lt "$threshold" ]; }; then
            continue
        fi
        abandoned_dir="$state_dir/abandoned/$job_id"
        if ! mv "$staging_dir" "$abandoned_dir" 2>/dev/null; then
            cleanup_status=1
            continue
        fi
        if ! write_field "$abandoned_dir" 'terminal-status' "$terminal_status" || \
            ! write_field "$abandoned_dir" 'terminal-target' "$(read_field "$abandoned_dir/display-target")" || \
            ! write_field "$abandoned_dir" 'terminal-detail' "$terminal_detail" || \
            ! complete_transitional_job "$state_dir" "$job_id" "$abandoned_dir" 1 1; then
            cleanup_status=1
            continue
        fi
    done
    shopt -u nullglob
    return "$cleanup_status"
}

recover_transitional_jobs() {
    local state_dir="$1"
    local transition="$2"
    local job_dir
    local job_id
    local recovery_status=0

    shopt -s nullglob
    for job_dir in "$state_dir/$transition"/*; do
        [ -d "$job_dir" ] || continue
        job_id="${job_dir##*/}"
        valid_job_id "$job_id" || continue
        complete_transitional_job \
            "$state_dir" \
            "$job_id" \
            "$job_dir" \
            1 \
            1 \
            'failed' \
            'delivery outcome is unknown' || recovery_status=1
    done
    shopt -u nullglob
    return "$recovery_status"
}

state_jobs_are_empty() {
    local state_dir="$1"
    local transition
    local job_dir

    for transition in jobs running staging cancelled finishing abandoned; do
        shopt -s nullglob
        for job_dir in "$state_dir/$transition"/*; do
            shopt -u nullglob
            return 1
        done
        shopt -u nullglob
    done
    return 0
}

cleanup_all_jobs() {
    local state_dir
    local pending_dir
    local job_id
    local cleanup_status=0

    state_dir="$(resolve_state_dir)"
    ensure_state_layout "$state_dir" || return 1
    acquire_state_lock "$state_dir" || return 1
    trap release_state_lock EXIT
    trap 'release_state_lock; exit 1' HUP INT TERM
    write_field "$state_dir" 'disabled' '1' || cleanup_status=1
    shopt -s nullglob
    for pending_dir in "$state_dir"/jobs/*; do
        [ -d "$pending_dir" ] || continue
        job_id="${pending_dir##*/}"
        valid_job_id "$job_id" || continue
        cancel_job "$job_id" >/dev/null || cleanup_status=1
    done
    shopt -u nullglob
    reconcile_running_jobs --all || cleanup_status=1
    recover_transitional_jobs "$state_dir" cancelled || cleanup_status=1
    recover_transitional_jobs "$state_dir" finishing || cleanup_status=1
    recover_transitional_jobs "$state_dir" abandoned || cleanup_status=1
    state_jobs_are_empty "$state_dir" || cleanup_status=1
    release_state_lock
    trap - EXIT HUP INT TERM
    return "$cleanup_status"
}

enable_scheduling() {
    local state_dir

    state_dir="$(resolve_state_dir)"
    [ -f "$state_dir/disabled" ] || return 0
    ensure_state_layout "$state_dir" || return 1
    acquire_state_lock "$state_dir" || return 1
    rm -f -- "$state_dir/disabled"
    release_state_lock
}

command_name="${1:-}"
case "$command_name" in
    schedule)
        shift
        create_job "$@"
        ;;
    cancel)
        shift
        cancel_job "$@"
        ;;
    reconcile)
        shift
        reconcile_running_jobs "$@"
        ;;
    cleanup)
        [ "$#" -eq 1 ] || usage
        cleanup_all_jobs
        ;;
    enable)
        [ "$#" -eq 1 ] || usage
        enable_scheduling
        ;;
    --run-staged)
        [ "$#" -eq 4 ] || usage
        run_staged_worker "$2" "$3" "$4"
        ;;
    --run-systemd)
        [ "$#" -eq 4 ] || usage
        run_systemd_worker "$2" "$3" "$4"
        ;;
    *)
        usage
        ;;
esac
