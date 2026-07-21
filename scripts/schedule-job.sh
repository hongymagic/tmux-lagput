#!/usr/bin/env bash

set -u

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

usage() {
    printf '%s\n' \
        'Usage:' \
        '  schedule-job.sh schedule --target PANE_ID --display-target TARGET --text TEXT --key KEY --delay SECONDS [--use-systemd]' \
        '  schedule-job.sh cancel JOB_ID' >&2
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
    mkdir -p "$state_dir/jobs" "$state_dir/running" "$state_dir/cancelled"
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

cleanup_systemd_units() {
    local timer_unit="$1"
    local service_file="$2"
    local timer_file="$3"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now "$timer_unit" >/dev/null 2>&1 || true
    fi
    if [ -n "$service_file" ]; then
        rm -f -- "$service_file"
    fi
    if [ -n "$timer_file" ]; then
        rm -f -- "$timer_file"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
}

install_systemd_job() {
    local state_dir="$1"
    local job_id="$2"
    local job_dir="$state_dir/jobs/$job_id"
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

    run_at="$(read_field "$job_dir/run-at")"
    mkdir -p "$user_unit_dir"

    {
        printf '[Unit]\nDescription=Send delayed tmux input (%s)\n\n' "$job_id"
        printf '[Service]\nType=oneshot\nExecStart=%s --run-now %s %s\n' \
            "$(systemd_quote "$SCRIPT_PATH")" \
            "$(systemd_quote "$state_dir")" \
            "$(systemd_quote "$job_id")"
    } > "$service_temp"

    {
        printf '[Unit]\nDescription=Timer for delayed tmux input (%s)\n\n' "$job_id"
        printf '[Timer]\nOnCalendar=@%s\nPersistent=true\nAccuracySec=1s\nUnit=%s\n\n' "$run_at" "$service_unit"
        printf '[Install]\nWantedBy=timers.target\n'
    } > "$timer_temp"

    mv "$service_temp" "$service_file"
    mv "$timer_temp" "$timer_file"
    write_field "$job_dir" 'backend' 'systemd'
    write_field "$job_dir" 'timer-unit' "$timer_unit"
    write_field "$job_dir" 'service-file' "$service_file"
    write_field "$job_dir" 'timer-file' "$timer_file"

    if systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable --now "$timer_unit" >/dev/null 2>&1; then
        return 0
    fi

    cleanup_systemd_units "$timer_unit" "$service_file" "$timer_file"
    return 1
}

launch_background_job() {
    local state_dir="$1"
    local job_id="$2"
    local worker_pid

    if command -v setsid >/dev/null 2>&1; then
        nohup setsid "$SCRIPT_PATH" --run "$state_dir" "$job_id" </dev/null >/dev/null 2>&1 &
    else
        nohup "$SCRIPT_PATH" --run "$state_dir" "$job_id" </dev/null >/dev/null 2>&1 &
    fi
    worker_pid=$!
    write_field "$state_dir/jobs/$job_id" 'backend' 'background'
    write_field "$state_dir/jobs/$job_id" 'worker-pid' "$worker_pid"
}

stop_background_worker() {
    local state_dir="$1"
    local job_id="$2"
    local job_dir="$3"
    local worker_pid
    local worker_command
    local expected_command="$SCRIPT_PATH --run $state_dir $job_id"

    worker_pid="$(read_field "$job_dir/worker-pid")"
    [[ "$worker_pid" =~ ^[0-9]+$ ]] || return 0
    worker_command="$(ps -p "$worker_pid" -o args= 2>/dev/null || true)"
    case "$worker_command" in
        *"$expected_command"*) kill -TERM "$worker_pid" 2>/dev/null || true ;;
    esac
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
    ensure_state_layout "$state_dir"
    created_at="$(date +%s)"
    run_at=$((created_at + delay))

    while [ "$attempt" -lt 100 ]; do
        job_id="${created_at}-$$-${RANDOM:-0}"
        job_dir="$state_dir/jobs/$job_id"
        if mkdir "$job_dir" 2>/dev/null; then
            break
        fi
        job_id=''
        attempt=$((attempt + 1))
    done
    if [ -z "$job_id" ]; then
        printf 'Could not allocate a unique job ID.\n' >&2
        exit 1
    fi

    write_field "$job_dir" 'target' "$target"
    write_field "$job_dir" 'display-target' "$display_target"
    write_field "$job_dir" 'text' "$text"
    write_field "$job_dir" 'key' "$key"
    write_field "$job_dir" 'created-at' "$created_at"
    write_field "$job_dir" 'run-at' "$run_at"
    write_field "$job_dir" 'tmux-binary' "$tmux_binary"
    write_field "$job_dir" 'tmux-environment' "$tmux_environment"
    write_field "$job_dir" 'tmux-socket' "$tmux_socket"
    write_field "$job_dir" 'tmux-socket-identity' "$tmux_socket_identity"

    if [ "$use_systemd" -eq 1 ] && install_systemd_job "$state_dir" "$job_id"; then
        :
    else
        launch_background_job "$state_dir" "$job_id"
    fi

    printf '%s\n' "$job_id"
}

finish_running_job() {
    local state_dir="$1"
    local job_id="$2"
    local running_dir="$state_dir/running/$job_id"
    local timer_unit
    local service_file
    local timer_file

    timer_unit="$(read_field "$running_dir/timer-unit")"
    service_file="$(read_field "$running_dir/service-file")"
    timer_file="$(read_field "$running_dir/timer-file")"
    rm -rf -- "$running_dir"

    if [ -n "$timer_unit" ]; then
        cleanup_systemd_units "$timer_unit" "$service_file" "$timer_file"
    fi
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

    ensure_state_layout "$state_dir"
    if ! mv "$pending_dir" "$running_dir" 2>/dev/null; then
        exit 0
    fi

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
            append_history "$state_dir" "$job_id" 'failed' "$display_target" 'captured tmux server no longer exists'
            finish_running_job "$state_dir" "$job_id"
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
        append_history "$state_dir" "$job_id" 'failed' "$display_target" 'captured target pane no longer exists'
        finish_running_job "$state_dir" "$job_id"
        exit 1
    fi

    if ! "$tmux_binary" send-keys -t "$target" -l -- "$text"; then
        append_history "$state_dir" "$job_id" 'failed' "$display_target" 'sending literal text failed'
        finish_running_job "$state_dir" "$job_id"
        exit 1
    fi
    if [ -n "$key" ] && ! "$tmux_binary" send-keys -t "$target" "$key"; then
        append_history "$state_dir" "$job_id" 'failed' "$display_target" 'sending the trailing key failed'
        finish_running_job "$state_dir" "$job_id"
        exit 1
    fi

    append_history "$state_dir" "$job_id" 'sent' "$display_target" 'delayed input delivered'
    finish_running_job "$state_dir" "$job_id"
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

cancel_job() {
    local job_id="${1:-}"
    local state_dir
    local pending_dir
    local cancelled_dir
    local display_target
    local backend
    local timer_unit
    local service_file
    local timer_file

    if [ -z "$job_id" ] || ! valid_job_id "$job_id"; then
        usage
    fi

    state_dir="$(resolve_state_dir)"
    ensure_state_layout "$state_dir"
    pending_dir="$state_dir/jobs/$job_id"
    cancelled_dir="$state_dir/cancelled/$job_id"
    if ! mv "$pending_dir" "$cancelled_dir" 2>/dev/null; then
        printf 'Job is no longer pending: %s\n' "$job_id" >&2
        exit 1
    fi

    display_target="$(read_field "$cancelled_dir/display-target")"
    backend="$(read_field "$cancelled_dir/backend")"
    if [ "$backend" = 'background' ]; then
        stop_background_worker "$state_dir" "$job_id" "$cancelled_dir"
    fi
    timer_unit="$(read_field "$cancelled_dir/timer-unit")"
    service_file="$(read_field "$cancelled_dir/service-file")"
    timer_file="$(read_field "$cancelled_dir/timer-file")"
    if [ -n "$timer_unit" ]; then
        cleanup_systemd_units "$timer_unit" "$service_file" "$timer_file"
    fi

    append_history "$state_dir" "$job_id" 'cancelled' "$display_target" 'cancelled by user'
    rm -rf -- "$cancelled_dir"
    printf 'Cancelled %s\n' "$job_id"
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
    --run)
        [ "$#" -eq 3 ] || usage
        run_job_after_delay "$2" "$3"
        ;;
    --run-now)
        [ "$#" -eq 3 ] || usage
        run_job_now "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
