#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SCHEDULER="$SCRIPT_DIR/schedule-job.sh"
INPUT_VALUE=''
JOB_IDS=()
JOB_RUN_AT=()
JOB_ROWS=()

use_gum() {
    [ "${SEND_DELAYED_FORCE_PLAIN:-0}" != '1' ] && command -v gum >/dev/null 2>&1 && [ -t 0 ]
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
    local remaining

    JOB_ROWS=()
    now="$(date +%s)"
    index=0
    while [ "$index" -lt "${#JOB_IDS[@]}" ]; do
        job_dir="$state_dir/jobs/${JOB_IDS[$index]}"
        target="$(read_field "$job_dir/display-target")"
        text="$(read_field "$job_dir/text")"
        text="${text//$'\t'/ }"
        if [ "${#text}" -gt 34 ]; then
            text="${text:0:31}..."
        fi
        remaining="$(format_remaining "$((JOB_RUN_AT[index] - now))")"
        JOB_ROWS+=("$((index + 1))) $target | $text | $remaining")
        index=$((index + 1))
    done
}

open_popup() {
    local pane_id="${1:-}"
    if [ -z "$pane_id" ]; then
        printf 'No triggering pane was supplied.\n' >&2
        exit 1
    fi
    # The popup's shell expands this variable from the environment set above.
    # shellcheck disable=SC2016
    tmux display-popup -E -w 76 -h 22 \
        -e "TMUX_SEND_DELAYED_LIST_SCRIPT=$SCRIPT_PATH" \
        'exec "$TMUX_SEND_DELAYED_LIST_SCRIPT" --form'
}

render_list() {
    local state_dir
    local selection
    local selected_index
    local selected_job
    local confirmation
    local row

    state_dir="$(resolve_state_dir)"
    while true; do
        load_jobs "$state_dir"
        build_rows "$state_dir"
        printf 'Pending delayed tmux sends\n\n'

        if [ "${#JOB_IDS[@]}" -eq 0 ]; then
            printf 'No pending jobs.\n'
            if ! read_plain_value 'Press Enter to refresh or Esc to close'; then
                exit 0
            fi
            continue
        fi

        if use_gum; then
            selection="$(gum choose --header 'Target | Text | Remaining' "${JOB_ROWS[@]}")" || exit 0
            selected_index="${selection%%)*}"
        else
            printf 'Target | Text | Remaining\n'
            for row in "${JOB_ROWS[@]}"; do
                printf '%s\n' "$row"
            done
            printf '\n'
            if ! read_plain_value 'Job number to cancel (Enter refreshes, Esc closes)'; then
                exit 0
            fi
            selected_index="$INPUT_VALUE"
            [ -n "$selected_index" ] || continue
        fi

        if [[ ! "$selected_index" =~ ^[0-9]+$ ]] || [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt "${#JOB_IDS[@]}" ]; then
            printf 'Choose a listed job number.\n\n'
            continue
        fi
        selected_job="${JOB_IDS[$((selected_index - 1))]}"

        if use_gum; then
            gum confirm "Cancel ${JOB_ROWS[$((selected_index - 1))]}?" || continue
        else
            if ! read_plain_value 'Cancel this job? (y/N)'; then
                exit 0
            fi
            confirmation="$INPUT_VALUE"
            case "$confirmation" in
                y|Y|yes|YES) ;;
                *) continue ;;
            esac
        fi

        if ! TMUX_SEND_DELAYED_STATE_DIR="$state_dir" "$SCHEDULER" cancel "$selected_job"; then
            printf 'The job was already running or cancelled.\n'
        fi
        printf '\n'
    done
}

case "${1:-}" in
    --open) open_popup "${2:-}" ;;
    --form) render_list ;;
    *) printf 'Usage: %s --open PANE_ID | --form\n' "$0" >&2; exit 2 ;;
esac
