#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SCHEDULER="$SCRIPT_DIR/schedule-job.sh"
INPUT_VALUE=''
JOB_IDS=()
JOB_RUN_AT=()
JOB_ROWS=()
JOB_DISPLAY_ROWS=()
SELECTED_ACTION=''
SELECTED_INDEX=''

use_fzf() {
    [ "${SEND_DELAYED_FORCE_PLAIN:-0}" != '1' ] || return 1
    command -v fzf >/dev/null 2>&1 || return 1
    [ "${SEND_DELAYED_FORCE_FZF:-0}" = '1' ] || [ -t 0 ]
}

use_gum() {
    [ "${SEND_DELAYED_FORCE_PLAIN:-0}" != '1' ] || return 1
    command -v gum >/dev/null 2>&1 || return 1
    [ "${SEND_DELAYED_FORCE_GUM:-0}" = '1' ] || [ -t 0 ]
}

read_plain_value() {
    local label="$1"
    local input=''
    local read_status=0

    printf '%s: ' "$label"
    if [ ! -t 0 ]; then
        IFS= read -r input || read_status=$?
        if [ "$read_status" -ne 0 ] && [ -z "$input" ]; then
            return 1
        fi
        if [[ "$input" == $'\e'* ]]; then
            return 1
        fi
    else
        local character=''
        while true; do
            character=''
            IFS= read -r -s -n 1 character || read_status=$?
            if [ "$read_status" -ne 0 ]; then
                printf '\n'
                return 1
            fi
            case "$character" in
                '') printf '\n'; break ;;
                $'\e'|$'\003') printf '\n'; return 1 ;;
                $'\177'|$'\b')
                    if [ -n "$input" ]; then
                        input="${input%?}"
                        printf '\b \b'
                    fi
                    ;;
                *) input="$input$character"; printf '%s' "$character" ;;
            esac
        done
    fi
    INPUT_VALUE="$input"
}

read_field() {
    local field_path="$1"
    local value=''
    if [ -f "$field_path" ]; then
        IFS= read -r value < "$field_path" || true
    fi
    printf '%s' "$value"
}

valid_job_id() {
    case "$1" in
        .|..) return 1 ;;
    esac
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

sanitize_display() {
    printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' ' '
}

resolve_state_dir() {
    local state_dir="${TMUX_SEND_DELAYED_STATE_DIR:-}"
    if [ -z "$state_dir" ]; then
        state_dir="$(tmux show-option -gqv '@send-delayed-state-dir' 2>/dev/null || true)"
    fi
    if [ -z "$state_dir" ]; then
        state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-lagput"
    fi
    printf '%s\n' "$state_dir"
}

tmux_option() {
    local option_name="$1"
    local default_value="$2"
    local value

    value="$(tmux show-option -gqv "$option_name" 2>/dev/null || true)"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$default_value"
    fi
}

format_remaining() {
    local seconds="$1"
    local days
    local hours
    local minutes
    local result=''

    if [ "$seconds" -le 0 ]; then
        printf 'due now'
        return
    fi
    days=$((seconds / 86400))
    hours=$(((seconds % 86400) / 3600))
    minutes=$(((seconds % 3600) / 60))
    seconds=$((seconds % 60))
    [ "$days" -gt 0 ] && result="${result}${days}d"
    [ "$hours" -gt 0 ] && result="${result}${hours}h"
    [ "$minutes" -gt 0 ] && result="${result}${minutes}m"
    if [ "$seconds" -gt 0 ] || [ -z "$result" ]; then
        result="${result}${seconds}s"
    fi
    printf '%s' "$result"
}

format_epoch() {
    local epoch="$1"
    local formatted

    if formatted="$(LC_ALL=C date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"; then
        printf '%s' "$formatted"
        return
    fi
    if formatted="$(LC_ALL=C date -r "$epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"; then
        printf '%s' "$formatted"
        return
    fi
    printf '@%s' "$epoch"
}

load_jobs() {
    local state_dir="$1"
    local job_dir
    local job_id
    local run_at
    local insert_at
    local index

    JOB_IDS=()
    JOB_RUN_AT=()
    shopt -s nullglob
    for job_dir in "$state_dir"/jobs/*; do
        [ -d "$job_dir" ] || continue
        job_id="${job_dir##*/}"
        valid_job_id "$job_id" || continue
        run_at="$(read_field "$job_dir/run-at")"
        [[ "$run_at" =~ ^[0-9]+$ ]] || continue

        insert_at=${#JOB_IDS[@]}
        index=0
        while [ "$index" -lt "${#JOB_RUN_AT[@]}" ]; do
            if [ "$run_at" -lt "${JOB_RUN_AT[$index]}" ]; then
                insert_at=$index
                break
            fi
            index=$((index + 1))
        done
        JOB_IDS=("${JOB_IDS[@]:0:$insert_at}" "$job_id" "${JOB_IDS[@]:$insert_at}")
        JOB_RUN_AT=("${JOB_RUN_AT[@]:0:$insert_at}" "$run_at" "${JOB_RUN_AT[@]:$insert_at}")
    done
    shopt -u nullglob
}

build_rows() {
    local state_dir="$1"
    local now
    local index
    local job_dir
    local target
    local text
    local display_text
    local remaining

    JOB_ROWS=()
    JOB_DISPLAY_ROWS=()
    now="$(date +%s)"
    index=0
    while [ "$index" -lt "${#JOB_IDS[@]}" ]; do
        job_dir="$state_dir/jobs/${JOB_IDS[$index]}"
        target="$(sanitize_display "$(read_field "$job_dir/display-target")")"
        text="$(sanitize_display "$(read_field "$job_dir/text")")"
        display_text="$text"
        if [ "${#display_text}" -gt 42 ]; then
            display_text="${display_text:0:39}..."
        fi
        remaining="$(format_remaining "$((JOB_RUN_AT[index] - now))")"
        JOB_ROWS+=("${JOB_IDS[$index]}"$'\t'"$remaining"$'\t'"$target"$'\t'"$text")
        JOB_DISPLAY_ROWS+=("$((index + 1))) $target | $display_text | $remaining")
        index=$((index + 1))
    done
}

render_job_details() {
    local state_dir="$1"
    local job_id="$2"
    local job_dir
    local target
    local pane
    local text
    local key
    local backend
    local backend_detail
    local worker_pid
    local timer_unit
    local created_at
    local run_at
    local remaining
    local now

    valid_job_id "$job_id" || return 1
    job_dir="$state_dir/jobs/$job_id"
    [ -d "$job_dir" ] || return 1

    target="$(sanitize_display "$(read_field "$job_dir/display-target")")"
    pane="$(sanitize_display "$(read_field "$job_dir/target")")"
    text="$(sanitize_display "$(read_field "$job_dir/text")")"
    key="$(sanitize_display "$(read_field "$job_dir/key")")"
    backend="$(sanitize_display "$(read_field "$job_dir/backend")")"
    created_at="$(read_field "$job_dir/created-at")"
    run_at="$(read_field "$job_dir/run-at")"
    [ -n "$key" ] || key='(none)'

    backend_detail="$backend"
    case "$backend" in
        background)
            worker_pid="$(sanitize_display "$(read_field "$job_dir/worker-pid")")"
            [ -z "$worker_pid" ] || backend_detail="$backend (PID $worker_pid)"
            ;;
        systemd)
            timer_unit="$(sanitize_display "$(read_field "$job_dir/timer-unit")")"
            [ -z "$timer_unit" ] || backend_detail="$backend ($timer_unit)"
            ;;
    esac

    now="$(date +%s)"
    if [[ "$run_at" =~ ^[0-9]+$ ]]; then
        remaining="$(format_remaining "$((run_at - now))")"
    else
        remaining='unknown'
    fi

    printf 'Pending send\n\n'
    printf '%-11s %s\n' 'Target' "$target"
    printf '%-11s %s\n' 'Pane' "$pane"
    if [[ "$run_at" =~ ^[0-9]+$ ]]; then
        printf '%-11s %s\n' 'Runs' "$(format_epoch "$run_at")"
    else
        printf '%-11s %s\n' 'Runs' 'unknown'
    fi
    printf '%-11s %s\n' 'Remaining' "$remaining"
    printf '%-11s %s\n' 'Text' "$text"
    printf '%-11s %s\n' 'Then key' "$key"
    printf '%-11s %s\n' 'Backend' "$backend_detail"
    if [[ "$created_at" =~ ^[0-9]+$ ]]; then
        printf '%-11s %s\n' 'Created' "$(format_epoch "$created_at")"
    else
        printf '%-11s %s\n' 'Created' 'unknown'
    fi
    printf '%-11s %s\n' 'Job ID' "$job_id"
}

shell_quote() {
    local value="$1"
    value="${value//\'/\'\\\'\'}"
    printf "'%s'" "$value"
}

find_job_index() {
    local job_id="$1"
    local index=0

    SELECTED_INDEX=''
    while [ "$index" -lt "${#JOB_IDS[@]}" ]; do
        if [ "${JOB_IDS[$index]}" = "$job_id" ]; then
            SELECTED_INDEX="$((index + 1))"
            return 0
        fi
        index=$((index + 1))
    done
    return 1
}

select_with_fzf() {
    local preview_command
    local selection
    local action
    local selected_row
    local job_id
    local selector_status

    preview_command="$(shell_quote "$SCRIPT_PATH") --preview-job {1}"
    selection="$(printf '%s\n' "${JOB_ROWS[@]}" | FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' fzf \
        --delimiter=$'\t' \
        --with-nth=2.. \
        --nth=2.. \
        --layout=reverse \
        --info=inline \
        --no-multi \
        --prompt='Pending > ' \
        --header=$'Remaining | Target | Text\nEnter/Ctrl-X cancel | Ctrl-R refresh | Esc close' \
        --expect=enter,ctrl-x,ctrl-r \
        --preview "$preview_command" \
        --preview-window='down,45%,wrap')"
    selector_status=$?
    [ "$selector_status" -eq 0 ] || return "$selector_status"

    if [ "$selection" = 'ctrl-r' ]; then
        SELECTED_ACTION='refresh'
        SELECTED_INDEX=''
        return 0
    fi
    if [[ "$selection" == *$'\n'* ]]; then
        action="${selection%%$'\n'*}"
        selected_row="${selection#*$'\n'}"
    else
        action='enter'
        selected_row="$selection"
    fi
    job_id="${selected_row%%$'\t'*}"
    valid_job_id "$job_id" || return 1
    find_job_index "$job_id" || return 1
    case "$action" in
        ctrl-r) SELECTED_ACTION='refresh' ;;
        ctrl-x) SELECTED_ACTION='cancel' ;;
        enter|'') SELECTED_ACTION='cancel' ;;
        *) return 1 ;;
    esac
}

select_with_gum() {
    local selection
    local selected_index

    selection="$(printf '%s\n' "${JOB_DISPLAY_ROWS[@]}" | gum filter \
        --limit 1 \
        --header 'Target | Text | Remaining' \
        --placeholder 'Search pending jobs...')" || return 1
    selected_index="${selection%%)*}"
    if [[ ! "$selected_index" =~ ^[0-9]+$ ]] || [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt "${#JOB_IDS[@]}" ]; then
        return 1
    fi
    SELECTED_INDEX="$selected_index"
    SELECTED_ACTION='cancel'
}

select_plain() {
    local row

    printf 'Target | Text | Remaining\n'
    for row in "${JOB_DISPLAY_ROWS[@]}"; do
        printf '%s\n' "$row"
    done
    printf '\n'

    while true; do
        if ! read_plain_value 'Job number to review (r refreshes, q/Esc closes)'; then
            return 1
        fi
        case "$INPUT_VALUE" in
            r|R|'') SELECTED_ACTION='refresh'; SELECTED_INDEX=''; return 0 ;;
            q|Q) return 1 ;;
        esac
        if [[ "$INPUT_VALUE" =~ ^[0-9]+$ ]] && [ "$INPUT_VALUE" -ge 1 ] && [ "$INPUT_VALUE" -le "${#JOB_IDS[@]}" ]; then
            SELECTED_INDEX="$INPUT_VALUE"
            SELECTED_ACTION='cancel'
            return 0
        fi
        printf 'Choose a listed job number.\n'
    done
}

confirm_cancellation() {
    if use_gum; then
        gum confirm 'Cancel this pending send?'
        return $?
    fi
    if ! read_plain_value 'Cancel this job? (y/N)'; then
        return 1
    fi
    case "$INPUT_VALUE" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

clear_popup() {
    if [ -t 1 ]; then
        printf '\033[2J\033[H'
    fi
}

show_status_message() {
    local message="$1"
    local client_name="${TMUX_SEND_DELAYED_CLIENT_NAME:-}"
    local -a message_arguments

    message="${message//#/##}"
    message_arguments=(display-message)
    if [ -n "$client_name" ]; then
        message_arguments+=(-c "$client_name")
    fi
    message_arguments+=(-d 3000 "$message")
    tmux "${message_arguments[@]}" >/dev/null 2>&1 || true
}

open_popup() {
    local pane_id="${1:-}"
    local client_name="${2:-}"
    local popup_width
    local popup_height
    local border_lines
    local -a popup_arguments

    if [ -z "$pane_id" ]; then
        printf 'No triggering pane was supplied.\n' >&2
        exit 1
    fi
    popup_width="$(tmux_option '@send-delayed-list-popup-width' '80%')"
    popup_height="$(tmux_option '@send-delayed-list-popup-height' '70%')"
    border_lines="$(tmux_option '@send-delayed-popup-border-lines' 'rounded')"
    popup_arguments=(display-popup -EE -t "$pane_id")
    if [ -n "$client_name" ]; then
        popup_arguments+=(-c "$client_name")
    fi
    popup_arguments+=(-T 'Pending delayed sends' -w "$popup_width" -h "$popup_height")
    case "$border_lines" in
        default) ;;
        *) popup_arguments+=(-b "$border_lines") ;;
    esac

    # The popup's shell expands this variable from the environment set above.
    # shellcheck disable=SC2016
    tmux "${popup_arguments[@]}" \
        -e "TMUX_SEND_DELAYED_CLIENT_NAME=$client_name" \
        -e "TMUX_SEND_DELAYED_LIST_SCRIPT=$SCRIPT_PATH" \
        'exec "$TMUX_SEND_DELAYED_LIST_SCRIPT" --form'
}

render_list() {
    local state_dir
    local selected_job
    local selected_target
    local selector_status

    state_dir="$(resolve_state_dir)"
    export TMUX_SEND_DELAYED_STATE_DIR="$state_dir"
    while true; do
        load_jobs "$state_dir"
        build_rows "$state_dir"
        clear_popup
        printf 'Pending delayed tmux sends\n\n'

        if [ "${#JOB_IDS[@]}" -eq 0 ]; then
            printf 'No pending jobs.\n'
            if ! read_plain_value 'Press Enter to refresh or q/Esc to close'; then
                exit 0
            fi
            case "$INPUT_VALUE" in
                q|Q) exit 0 ;;
            esac
            continue
        fi

        SELECTED_ACTION=''
        SELECTED_INDEX=''
        if use_fzf; then
            select_with_fzf
            selector_status=$?
            case "$selector_status" in
                0) ;;
                1|130) exit 0 ;;
                *)
                    clear_popup
                    if use_gum; then
                        select_with_gum || exit 0
                    else
                        select_plain || exit 0
                    fi
                    ;;
            esac
        elif use_gum; then
            select_with_gum || exit 0
        else
            select_plain || exit 0
        fi

        if [ "$SELECTED_ACTION" = 'refresh' ]; then
            continue
        fi
        if [[ ! "$SELECTED_INDEX" =~ ^[0-9]+$ ]] || [ "$SELECTED_INDEX" -lt 1 ] || [ "$SELECTED_INDEX" -gt "${#JOB_IDS[@]}" ]; then
            continue
        fi
        selected_job="${JOB_IDS[$((SELECTED_INDEX - 1))]}"
        selected_target="$(sanitize_display "$(read_field "$state_dir/jobs/$selected_job/display-target")")"

        clear_popup
        if ! render_job_details "$state_dir" "$selected_job"; then
            show_status_message 'Selected delayed send is no longer pending'
            printf 'The job is no longer pending.\n'
            continue
        fi
        printf '\n'
        confirm_cancellation || continue

        if ! TMUX_SEND_DELAYED_STATE_DIR="$state_dir" "$SCHEDULER" cancel "$selected_job"; then
            show_status_message "Could not cancel delayed send -> $selected_target"
            printf 'The job was already running or cancelled.\n'
        else
            show_status_message "Cancelled delayed send -> $selected_target"
        fi
        printf '\n'
    done
}

case "${1:-}" in
    --open) open_popup "${2:-}" "${3:-}" ;;
    --form) render_list ;;
    --preview-job) render_job_details "$(resolve_state_dir)" "${2:-}" ;;
    *) printf 'Usage: %s --open PANE_ID [CLIENT_NAME] | --form | --preview-job JOB_ID\n' "$0" >&2; exit 2 ;;
esac
