#!/usr/bin/env bash

set -u

duration="${1:-}"
duration="$(printf '%s' "$duration" | tr '[:upper:]' '[:lower:]')"

if [ -z "$duration" ]; then
    printf 'Duration is required (for example: 90s, 30m, or 1d2h).\n' >&2
    exit 1
fi

remaining="$duration"
total_seconds=0

while [ -n "$remaining" ]; do
    if [[ ! "$remaining" =~ ^([0-9]+)([dhms])(.*)$ ]]; then
        printf 'Invalid duration: %s\n' "$1" >&2
        exit 1
    fi

    amount=$((10#${BASH_REMATCH[1]}))
    unit="${BASH_REMATCH[2]}"
    remaining="${BASH_REMATCH[3]}"

    case "$unit" in
        d) multiplier=86400 ;;
        h) multiplier=3600 ;;
        m) multiplier=60 ;;
        s) multiplier=1 ;;
    esac

    total_seconds=$((total_seconds + amount * multiplier))
done

if [ "$total_seconds" -le 0 ]; then
    printf 'Duration must be greater than zero.\n' >&2
    exit 1
fi

printf '%s\n' "$total_seconds"
