#!/usr/bin/env bash

set -u

usage() {
    printf '%s\n' \
        'Usage:' \
        '  calver.sh today' \
        '  calver.sh validate-tag TAG' \
        '  calver.sh latest [TAG ...]' \
        '  calver.sh next YYYY.MMDD [TAG ...]' >&2
    exit 2
}

valid_calendar_date() {
    local year="$1"
    local month="$2"
    local day="$3"
    local year_number
    local month_number
    local day_number
    local days_in_month

    year_number=$((10#$year))
    month_number=$((10#$month))
    day_number=$((10#$day))
    [ "$year_number" -gt 0 ] || return 1
    [ "$month_number" -ge 1 ] && [ "$month_number" -le 12 ] || return 1

    case "$month_number" in
        1|3|5|7|8|10|12) days_in_month=31 ;;
        4|6|9|11) days_in_month=30 ;;
        2)
            days_in_month=28
            if [ "$((year_number % 400))" -eq 0 ] || \
                { [ "$((year_number % 4))" -eq 0 ] && [ "$((year_number % 100))" -ne 0 ]; }; then
                days_in_month=29
            fi
            ;;
    esac
    [ "$day_number" -ge 1 ] && [ "$day_number" -le "$days_in_month" ]
}

parse_tag() {
    local tag="$1"

    if [[ ! "$tag" =~ ^v([0-9]{4})\.([0-9]{2})([0-9]{2})\.([0-9]+)$ ]]; then
        return 1
    fi
    valid_calendar_date "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

tag_is_newer() {
    local candidate="$1"
    local current="$2"
    local candidate_year
    local candidate_date
    local candidate_patch
    local current_year
    local current_date
    local current_patch

    [[ "$candidate" =~ ^v([0-9]{4})\.([0-9]{4})\.([0-9]+)$ ]]
    candidate_year=$((10#${BASH_REMATCH[1]}))
    candidate_date=$((10#${BASH_REMATCH[2]}))
    candidate_patch=$((10#${BASH_REMATCH[3]}))
    [[ "$current" =~ ^v([0-9]{4})\.([0-9]{4})\.([0-9]+)$ ]]
    current_year=$((10#${BASH_REMATCH[1]}))
    current_date=$((10#${BASH_REMATCH[2]}))
    current_patch=$((10#${BASH_REMATCH[3]}))

    [ "$candidate_year" -gt "$current_year" ] || \
        { [ "$candidate_year" -eq "$current_year" ] && [ "$candidate_date" -gt "$current_date" ]; } || \
        { [ "$candidate_year" -eq "$current_year" ] && [ "$candidate_date" -eq "$current_date" ] && [ "$candidate_patch" -gt "$current_patch" ]; }
}

latest_tag() {
    local tag
    local latest=''

    for tag in "$@"; do
        parse_tag "$tag" || continue
        if [ -z "$latest" ] || tag_is_newer "$tag" "$latest"; then
            latest="$tag"
        fi
    done
    [ -n "$latest" ] || return 1
    printf '%s\n' "$latest"
}

next_tag() {
    local release_date="$1"
    shift
    local tag
    local highest_patch=-1
    local patch

    if [[ ! "$release_date" =~ ^([0-9]{4})\.([0-9]{2})([0-9]{2})$ ]] || \
        ! valid_calendar_date "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; then
        printf 'Release date must be a valid YYYY.MMDD date.\n' >&2
        return 1
    fi

    for tag in "$@"; do
        parse_tag "$tag" || continue
        case "$tag" in
            "v$release_date."*)
                patch=$((10#${tag##*.}))
                if [ "$patch" -gt "$highest_patch" ]; then
                    highest_patch="$patch"
                fi
                ;;
        esac
    done
    printf 'v%s.%d\n' "$release_date" "$((highest_patch + 1))"
}

case "${1:-}" in
    today)
        [ "$#" -eq 1 ] || usage
        date -u '+%Y.%m%d'
        ;;
    validate-tag)
        [ "$#" -eq 2 ] || usage
        parse_tag "$2"
        ;;
    latest)
        shift
        latest_tag "$@"
        ;;
    next)
        [ "$#" -ge 2 ] || usage
        release_date="$2"
        shift 2
        next_tag "$release_date" "$@"
        ;;
    *) usage ;;
esac
