#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALVER="$SCRIPT_DIR/calver.sh"
DRY_RUN=0

usage() {
    printf 'Usage: release.sh [--dry-run]\n' >&2
    exit 2
}

case "${1:-}" in
    '') ;;
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
esac
[ "$#" -le 1 ] || usage

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'release.sh must run inside a Git repository.\n' >&2
    exit 1
}
cd "$repository_root" || exit 1

if [ -n "$(git status --porcelain=v1 --untracked-files=all)" ]; then
    printf 'The worktree must be clean before creating a release tag.\n' >&2
    exit 1
fi

current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ "$current_branch" != 'main' ]; then
    printf 'Release tags must be created from the main branch.\n' >&2
    exit 1
fi
if ! origin_main="$(git rev-parse --verify refs/remotes/origin/main 2>/dev/null)"; then
    printf 'The origin/main tracking reference is required. Fetch it before releasing.\n' >&2
    exit 1
fi
if [ "$(git rev-parse HEAD)" != "$origin_main" ]; then
    printf 'Local main must exactly match origin/main before releasing.\n' >&2
    exit 1
fi

release_date="$("$CALVER" today)"
set --
while IFS= read -r tag; do
    [ -n "$tag" ] && set -- "$@" "$tag"
done < <(git tag --list)
next_tag="$("$CALVER" next "$release_date" "$@")"

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Would create annotated tag %s at %s; no tag created.\n' \
        "$next_tag" \
        "$(git rev-parse --short HEAD)"
    exit 0
fi

if ! git tag -a "$next_tag" -m "$next_tag"; then
    printf 'Could not create %s.\n' "$next_tag" >&2
    exit 1
fi
printf 'Created %s. Push it with: git push origin %s\n' "$next_tag" "$next_tag"
