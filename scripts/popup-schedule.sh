#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
PARSER="$SCRIPT_DIR/parse-duration.sh"
SCHEDULER="$SCRIPT_DIR/schedule-job.sh"
INPUT_VALUE=''

use_gum() {
    [ "${SEND_DELAYED_FORCE_PLAIN:-0}" != '1' ] && command -v gum >/dev/null 2>&1 && [ -t 0 ]
}

read_plain_value() {
    local label="$1"
    local default_value="$2"
    local input=''
    local character=''
    local read_status=0

    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$label" "$default_value"
    else
        printf '%s: ' "$label"
    fi

    if [ ! -t 0 ]; then
        IFS= read -r input || read_status=$?
        if [ "$read_status" -ne 0 ] && [ -z "$input" ]; then
            return 1
        fi
        if [[ "$input" == $'\e'* ]]; then
            return 1
        fi
    else
        while true; do
            character=''
            IFS= read -r -s -n 1 character || read_status=$?
            if [ "$read_status" -ne 0 ]; then
                printf '\n'
                return 1
            fi
            case "$character" in
                '')
                    printf '\n'
                    break
                    ;;
                $'\e'|$'\003')
                    printf '\n'
                    return 1
                    ;;
                $'\177'|$'\b')
                    if [ -n "$input" ]; then
                        input="${input%?}"
                        printf '\b \b'
                    fi
                    ;;
                *)
                    input="$input$character"
                    printf '%s' "$character"
                    ;;
            esac
        done
    fi

    if [ -z "$input" ] && [ -n "$default_value" ]; then
        input="$default_value"
    fi
    INPUT_VALUE="$input"
}

read_value() {
    local label="$1"
    local default_value="$2"
    local gum_value=''

    if use_gum; then
        if [ -n "$default_value" ]; then
            gum_value="$(gum input --prompt "$label: " --value "$default_value")" || return 1
        else
            gum_value="$(gum input --prompt "$label: ")" || return 1
        fi
        INPUT_VALUE="$gum_value"
    else
        read_plain_value "$label" "$default_value"
    fi
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

open_popup() {
    local pane_id="${1:-}"
    local display_target

    if [ -z "$pane_id" ]; then
        printf 'No triggering pane was supplied.\n' >&2
        exit 1
    fi
    display_target="$(tmux display-message -p -t "$pane_id" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
    if [ -z "$display_target" ]; then
        printf 'The triggering pane no longer exists.\n' >&2
        exit 1
    fi

    # The popup's shell expands this variable from the environment set above.
    # shellcheck disable=SC2016
    tmux display-popup -E -w 64 -h 18 \
        -e "TMUX_SEND_DELAYED_PANE_ID=$pane_id" \
        -e "TMUX_SEND_DELAYED_DISPLAY_TARGET=$display_target" \
        -e "TMUX_SEND_DELAYED_SCRIPT=$SCRIPT_PATH" \
        'exec "$TMUX_SEND_DELAYED_SCRIPT" --form'
}

render_form() {
    local pane_id="${TMUX_SEND_DELAYED_PANE_ID:-}"
    local display_target="${TMUX_SEND_DELAYED_DISPLAY_TARGET:-}"
    local text=''
    local duration=''
    local seconds=''
    local key='Enter'
    local key_lower=''
    local state_dir
    local use_systemd
    local job_id
    local -a schedule_arguments

    if [ -z "$pane_id" ] || [ -z "$display_target" ]; then
        printf 'Captured pane information is missing.\n' >&2
        exit 1
    fi

    printf 'Schedule delayed tmux input\nTarget: %s (%s)\nPress Esc at any field to cancel.\n\n' "$display_target" "$pane_id"

    while [ -z "$text" ]; do
        if ! read_value 'Input text' ''; then
            exit 0
        fi
        text="$INPUT_VALUE"
        if [ -z "$text" ]; then
            printf 'Text cannot be empty.\n'
        fi
    done

    while true; do
        if ! read_value 'Delay (for example 5h, 30m, 90s, 1d2h)' ''; then
            exit 0
        fi
        duration="$INPUT_VALUE"
        if seconds="$("$PARSER" "$duration" 2>&1)"; then
            break
        fi
        printf '%s\n' "$seconds"
    done

    if ! read_value 'Key after text (use none to omit)' 'Enter'; then
        exit 0
    fi
    key="$INPUT_VALUE"
    key_lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    if [ "$key_lower" = 'none' ]; then
        key=''
    fi

    state_dir="$(resolve_state_dir)"
    use_systemd="$(tmux show-option -gqv '@send-delayed-use-systemd' 2>/dev/null || true)"
    schedule_arguments=(
        schedule
        --target "$pane_id"
        --display-target "$display_target"
        --text "$text"
        --key "$key"
        --delay "$seconds"
    )
    case "$use_systemd" in
        1|on|yes|true) schedule_arguments+=(--use-systemd) ;;
    esac

    if ! job_id="$(TMUX_SEND_DELAYED_STATE_DIR="$state_dir" "$SCHEDULER" "${schedule_arguments[@]}" 2>&1)"; then
        printf 'Could not schedule the job:\n%s\n' "$job_id" >&2
        exit 1
    fi
    printf 'Scheduled %s for %s.\n' "$job_id" "$display_target"
}

case "${1:-}" in
    --open) open_popup "${2:-}" ;;
    --form) render_form ;;
    *) printf 'Usage: %s --open PANE_ID | --form\n' "$0" >&2; exit 2 ;;
esac
