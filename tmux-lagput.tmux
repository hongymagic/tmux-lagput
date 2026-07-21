#!/usr/bin/env bash

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

shell_quote() {
    local value="$1"
    value="${value//\'/\'\\\'\'}"
    printf "'%s'" "$value"
}

schedule_key="$(tmux_option '@send-delayed-key' 'T')"
list_key="$(tmux_option '@send-delayed-list-key' 'C-t')"
schedule_command="$(shell_quote "$CURRENT_DIR/scripts/popup-schedule.sh") --open '#{pane_id}'"
list_command="$(shell_quote "$CURRENT_DIR/scripts/popup-list.sh") --open '#{pane_id}'"

tmux bind-key "$schedule_key" run-shell "$schedule_command"
tmux bind-key "$list_key" run-shell "$list_command"
