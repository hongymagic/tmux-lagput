#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
PARSER="$SCRIPT_DIR/parse-duration.sh"
SCHEDULER="$SCRIPT_DIR/schedule-job.sh"
INPUT_VALUE=''

use_gum() {
    [ "${SEND_LATER_FORCE_PLAIN:-0}" != '1' ] || return 1
    command -v gum >/dev/null 2>&1 || return 1
    [ "${SEND_LATER_FORCE_GUM:-0}" = '1' ] || [ -t 0 ]
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
    local state_dir="${TMUX_SEND_LATER_STATE_DIR:-}"
    if [ -z "$state_dir" ]; then
        state_dir="$(tmux show-option -gqv '@send-later-state-dir' 2>/dev/null || true)"
    fi
    if [ -z "$state_dir" ]; then
        state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-send-later"
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

clear_popup() {
    if [ -t 1 ]; then
        printf '\033[2J\033[H'
    fi
}

confirm_schedule() {
    local choice

    if use_gum; then
        choice="$(gum choose --header 'Review send' 'Schedule' 'Edit')" || return 2
        case "$choice" in
            Schedule) return 0 ;;
            Edit) return 1 ;;
            *) return 2 ;;
        esac
    fi

    while true; do
        if ! read_plain_value 'Schedule this send? (Y/n)' ''; then
            return 2
        fi
        case "$INPUT_VALUE" in
            ''|y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) printf 'Enter y or n.\n' ;;
        esac
    done
}

show_success_message() {
    local client_name="$1"
    local duration="$2"
    local display_target="$3"
    local message
    local -a message_arguments

    message="Scheduled in $duration -> $display_target"
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
    local display_target
    local popup_width
    local popup_height
    local border_lines
    local -a display_arguments
    local -a popup_arguments

    if [ -z "$pane_id" ]; then
        printf 'No triggering pane was supplied.\n' >&2
        exit 1
    fi
    display_arguments=(display-message -p -t "$pane_id")
    if [ -n "$client_name" ]; then
        display_arguments+=(-c "$client_name")
    fi
    display_arguments+=('#{session_name}:#{window_index}.#{pane_index}')
    display_target="$(tmux "${display_arguments[@]}" 2>/dev/null || true)"
    if [ -z "$display_target" ]; then
        printf 'The triggering pane no longer exists.\n' >&2
        exit 1
    fi

    popup_width="$(tmux_option '@send-later-popup-width' '70%')"
    popup_height="$(tmux_option '@send-later-popup-height' '16')"
    border_lines="$(tmux_option '@send-later-popup-border-lines' 'rounded')"
    popup_arguments=(display-popup -EE -t "$pane_id")
    if [ -n "$client_name" ]; then
        popup_arguments+=(-c "$client_name")
    fi
    popup_arguments+=(-T 'Schedule send for later' -w "$popup_width" -h "$popup_height")
    case "$border_lines" in
        default) ;;
        *) popup_arguments+=(-b "$border_lines") ;;
    esac

    # The popup's shell expands this variable from the environment set above.
    # shellcheck disable=SC2016
    tmux "${popup_arguments[@]}" \
        -e "TMUX_SEND_LATER_PANE_ID=$pane_id" \
        -e "TMUX_SEND_LATER_CLIENT_NAME=$client_name" \
        -e "TMUX_SEND_LATER_DISPLAY_TARGET=$display_target" \
        -e "TMUX_SEND_LATER_SCRIPT=$SCRIPT_PATH" \
        'exec "$TMUX_SEND_LATER_SCRIPT" --form'
}

render_form() {
    local pane_id="${TMUX_SEND_LATER_PANE_ID:-}"
    local display_target="${TMUX_SEND_LATER_DISPLAY_TARGET:-}"
    local client_name="${TMUX_SEND_LATER_CLIENT_NAME:-}"
    local text=''
    local duration=''
    local seconds=''
    local key='Enter'
    local key_lower=''
    local state_dir
    local use_systemd
    local job_id
    local review_status
    local display_key
    local -a schedule_arguments

    if [ -z "$pane_id" ] || [ -z "$display_target" ]; then
        printf 'Captured pane information is missing.\n' >&2
        exit 1
    fi

    while true; do
        clear_popup
        printf 'Target  %s (%s)\n\n' "$display_target" "$pane_id"
        printf 'Enter accepts each field. Esc cancels.\n\n'

        while true; do
            if ! read_value 'Text' "$text"; then
                exit 0
            fi
            text="$INPUT_VALUE"
            if [ -n "$text" ]; then
                break
            fi
            printf 'Text cannot be empty.\n'
        done

        while true; do
            if ! read_value 'Delay (e.g. 30m or 1d2h)' "$duration"; then
                exit 0
            fi
            duration="$INPUT_VALUE"
            if seconds="$("$PARSER" "$duration" 2>&1)"; then
                break
            fi
            printf '%s\n' "$seconds"
        done

        display_key="$key"
        [ -n "$display_key" ] || display_key='none'
        if ! read_value 'Key after text (use none to omit)' "$display_key"; then
            exit 0
        fi
        key="$INPUT_VALUE"
        key_lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
        if [ "$key_lower" = 'none' ]; then
            key=''
        fi

        display_key="$key"
        [ -n "$display_key" ] || display_key='(none)'
        clear_popup
        printf 'Review send\n\n'
        printf '  Target    %s (%s)\n' "$display_target" "$pane_id"
        printf '  Text      %s\n' "$text"
        printf '  Delay     %s\n' "$duration"
        printf '  Then key  %s\n\n' "$display_key"

        confirm_schedule
        review_status=$?
        case "$review_status" in
            0) break ;;
            1) continue ;;
            2) exit 0 ;;
        esac
    done

    state_dir="$(resolve_state_dir)"
    use_systemd="$(tmux show-option -gqv '@send-later-use-systemd' 2>/dev/null || true)"
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

    while true; do
        if job_id="$(TMUX_SEND_LATER_STATE_DIR="$state_dir" "$SCHEDULER" "${schedule_arguments[@]}" 2>&1)"; then
            show_success_message "$client_name" "$duration" "$display_target"
            return 0
        fi

        printf 'Could not schedule the job:\n%s\n' "$job_id" >&2
        if [ ! -t 0 ]; then
            return 1
        fi
        if ! read_plain_value 'Press Enter to retry or Esc to close' ''; then
            return 0
        fi
    done
}

case "${1:-}" in
    --open) open_popup "${2:-}" "${3:-}" ;;
    --form) render_form ;;
    *) printf 'Usage: %s --open PANE_ID [CLIENT_NAME] | --form\n' "$0" >&2; exit 2 ;;
esac
