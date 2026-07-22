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

binding_enabled() {
    case "$1" in
        none|off) return 1 ;;
        *) return 0 ;;
    esac
}

schedule_key="$(tmux_option '@send-later-key' 'T')"
list_key="$(tmux_option '@send-later-list-key' 'C-t')"
schedule_command="$(shell_quote "$CURRENT_DIR/scripts/popup-schedule.sh") --open '#{pane_id}' '#{client_name}'"
list_command="$(shell_quote "$CURRENT_DIR/scripts/popup-list.sh") --open '#{pane_id}' '#{client_name}'"

TMUX_SEND_LATER_STATE_DIR="${TMUX_SEND_LATER_STATE_DIR:-}" \
    "$CURRENT_DIR/scripts/schedule-job.sh" enable >/dev/null 2>&1 || true

if binding_enabled "$schedule_key"; then
    tmux bind-key -N 'Schedule pane input for later' "$schedule_key" run-shell -b "$schedule_command"
fi
if binding_enabled "$list_key"; then
    tmux bind-key -N 'Manage pending pane input' "$list_key" run-shell -b "$list_command"
fi
