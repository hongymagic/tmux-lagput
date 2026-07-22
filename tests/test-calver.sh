#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALVER="$ROOT_DIR/scripts/calver.sh"
RELEASE="$ROOT_DIR/scripts/release.sh"
PASSED=0
FAILED=0
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tmux-lagput-calver-test.XXXXXX")"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}/tmux-lagput-calver-test."*) rm -rf -- "$TEST_ROOT" ;;
    esac
}

trap cleanup EXIT

pass() {
    PASSED=$((PASSED + 1))
    printf 'ok %d - %s\n' "$((PASSED + FAILED))" "$1"
}

fail() {
    FAILED=$((FAILED + 1))
    printf 'not ok %d - %s\n' "$((PASSED + FAILED))" "$1" >&2
    if [ "$#" -gt 1 ]; then
        printf '  %s\n' "$2" >&2
    fi
}

assert_output() {
    local description="$1"
    local expected="$2"
    shift 2

    local actual
    if ! actual="$("$@" 2>/dev/null)"; then
        fail "$description" 'command failed'
        return
    fi

    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description" "expected '$expected', got '$actual'"
    fi
}

assert_succeeds() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description" 'command failed'
    fi
}

assert_fails() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        fail "$description" 'command unexpectedly succeeded'
    else
        pass "$description"
    fi
}

assert_equal() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local description="$1"
    local actual="$2"
    local expected="$3"

    case "$actual" in
        *"$expected"*) pass "$description" ;;
        *) fail "$description" "'$expected' not found in output" ;;
    esac
}

write_fake_utc_date() {
    local fake_bin="$1"
    mkdir -p -- "$fake_bin"
    # Keep the parameter expansions literal for the generated date fixture.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [ "${1:-}" != "-u" ]; then' \
        '    printf "date must be requested in UTC\\n" >&2' \
        '    exit 64' \
        'fi' \
        'case "${2:-}" in' \
        '    +%Y.%m%d) printf "2026.0722\\n" ;;' \
        '    +%Y) printf "2026\\n" ;;' \
        '    +%m%d) printf "0722\\n" ;;' \
        '    *) printf "unexpected date format: %s\\n" "${2:-}" >&2; exit 64 ;;' \
        'esac' > "$fake_bin/date"
    chmod +x "$fake_bin/date"
}

run_release_dry_in_repo() {
    local repository="$1"
    local fake_bin="$2"

    (
        cd "$repository" || exit 1
        env PATH="$fake_bin:$PATH" "$RELEASE" --dry-run
    )
}

printf 'TAP version 13\n'

FAKE_BIN="$TEST_ROOT/fake-bin"
write_fake_utc_date "$FAKE_BIN"

assert_output \
    'prints the current UTC date as YYYY.MMDD' \
    '2026.0722' \
    env PATH="$FAKE_BIN:$PATH" "$CALVER" today

assert_output \
    'starts the first release of a UTC date at patch zero' \
    'v2026.0722.0' \
    "$CALVER" next '2026.0722'

assert_output \
    'increments the highest patch from the same date' \
    'v2026.0722.3' \
    "$CALVER" next '2026.0722' \
        'v2026.0722.0' 'v2026.0721.99' 'v2026.0722.2' 'v2026.0722.1'

assert_output \
    'orders multi-digit patches numerically' \
    'v2026.0722.10' \
    "$CALVER" latest 'v2026.0722.9' 'v2026.0722.10'

assert_output \
    'orders releases by year and date before patch' \
    'v2026.0101.0' \
    "$CALVER" latest \
        'v2025.1231.99' 'v2026.0101.0' 'v2025.0101.100'

assert_output \
    'orders releases by date before patch within a year' \
    'v2026.0715.0' \
    "$CALVER" latest \
        'v2026.0101.99' 'v2026.0715.0' 'v2026.0630.100'

assert_output \
    'ignores invalid and prerelease tags when finding the latest release' \
    'v2026.0722.1' \
    "$CALVER" latest \
        'not-a-tag' 'v2026.0722.1-next.abc1234' 'v1.2.999' \
        'v2026.0722.0' 'v2026.0722.1'

assert_succeeds \
    'accepts a stable vYYYY.MMDD.PATCH tag' \
    "$CALVER" validate-tag 'v2026.0722.0'
assert_fails \
    'rejects a CalVer value without the v tag prefix' \
    "$CALVER" validate-tag '2026.0722.0'
assert_fails \
    'rejects a prerelease tag as a stable release' \
    "$CALVER" validate-tag 'v2026.0722.0-next.abc1234'
assert_fails \
    'rejects a tag with an impossible calendar date' \
    "$CALVER" validate-tag 'v2026.0230.0'

RELEASE_REPO="$TEST_ROOT/release-repo"
REMOTE_REPO="$TEST_ROOT/release-origin.git"
mkdir -p -- "$RELEASE_REPO"
git init -q --bare "$REMOTE_REPO"
git -C "$RELEASE_REPO" init -q -b main
git -C "$RELEASE_REPO" config user.name 'CalVer Test'
git -C "$RELEASE_REPO" config user.email 'calver-test@example.invalid'
printf 'release fixture\n' > "$RELEASE_REPO/fixture.txt"
git -C "$RELEASE_REPO" add fixture.txt
git -C "$RELEASE_REPO" commit -q -m 'Initial fixture'
git -C "$RELEASE_REPO" tag 'v2025.1231.99'
git -C "$RELEASE_REPO" tag 'v2026.0722.0'
git -C "$RELEASE_REPO" tag 'v2026.0722.1'
git -C "$RELEASE_REPO" remote add origin "$REMOTE_REPO"
git -C "$RELEASE_REPO" push -q -u origin main --tags

BEFORE_HEAD="$(git -C "$RELEASE_REPO" rev-parse HEAD)"
BEFORE_REFS="$(git -C "$RELEASE_REPO" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort)"
BEFORE_STATUS="$(git -C "$RELEASE_REPO" status --porcelain=v1 --untracked-files=all)"
RELEASE_OUTPUT=''
if RELEASE_OUTPUT="$(cd "$RELEASE_REPO" && env PATH="$FAKE_BIN:$PATH" "$RELEASE" --dry-run 2>&1)"; then
    pass 'release dry-run succeeds'
else
    fail 'release dry-run succeeds' "command failed: $RELEASE_OUTPUT"
fi
assert_contains \
    'release dry-run reports the next same-day CalVer tag' \
    "$RELEASE_OUTPUT" \
    'v2026.0722.2'
assert_contains \
    'release dry-run states that no tag was created' \
    "$RELEASE_OUTPUT" \
    'no tag created'

AFTER_HEAD="$(git -C "$RELEASE_REPO" rev-parse HEAD)"
AFTER_REFS="$(git -C "$RELEASE_REPO" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort)"
AFTER_STATUS="$(git -C "$RELEASE_REPO" status --porcelain=v1 --untracked-files=all)"
assert_equal 'release dry-run does not move HEAD' "$BEFORE_HEAD" "$AFTER_HEAD"
assert_equal 'release dry-run does not create or update refs' "$BEFORE_REFS" "$AFTER_REFS"
assert_equal 'release dry-run does not change the worktree' "$BEFORE_STATUS" "$AFTER_STATUS"

FIRST_RELEASE_REPO="$TEST_ROOT/first-release-repo"
FIRST_RELEASE_REMOTE="$TEST_ROOT/first-release-origin.git"
mkdir -p -- "$FIRST_RELEASE_REPO"
git init -q --bare "$FIRST_RELEASE_REMOTE"
git -C "$FIRST_RELEASE_REPO" init -q -b main
git -C "$FIRST_RELEASE_REPO" config user.name 'CalVer Test'
git -C "$FIRST_RELEASE_REPO" config user.email 'calver-test@example.invalid'
printf 'first release fixture\n' > "$FIRST_RELEASE_REPO/fixture.txt"
git -C "$FIRST_RELEASE_REPO" add fixture.txt
git -C "$FIRST_RELEASE_REPO" commit -q -m 'Initial fixture'
git -C "$FIRST_RELEASE_REPO" remote add origin "$FIRST_RELEASE_REMOTE"
git -C "$FIRST_RELEASE_REPO" push -q -u origin main
assert_output \
    'release dry-run supports a repository with no existing tags' \
    'Would create annotated tag v2026.0722.0 at '"$(git -C "$FIRST_RELEASE_REPO" rev-parse --short HEAD)"'; no tag created.' \
    run_release_dry_in_repo "$FIRST_RELEASE_REPO" "$FAKE_BIN"

git -C "$FIRST_RELEASE_REPO" switch -q -c feature
printf 'feature fixture\n' >> "$FIRST_RELEASE_REPO/fixture.txt"
git -C "$FIRST_RELEASE_REPO" commit -q -am 'Feature fixture'
assert_fails \
    'release helper refuses to tag a non-main commit' \
    run_release_dry_in_repo "$FIRST_RELEASE_REPO" "$FAKE_BIN"

TAG_FAILURE_OUTPUT=''
if TAG_FAILURE_OUTPUT="$(cd "$RELEASE_REPO" && env \
    PATH="$FAKE_BIN:$PATH" \
    GIT_COMMITTER_NAME='' \
    GIT_COMMITTER_EMAIL='' \
    "$RELEASE" 2>&1)"; then
    fail 'release helper propagates an annotated-tag failure'
else
    pass 'release helper propagates an annotated-tag failure'
fi
case "$TAG_FAILURE_OUTPUT" in
    *'Created '*) fail 'release helper never reports success after a tag failure' ;;
    *) pass 'release helper never reports success after a tag failure' ;;
esac

printf '1..%d\n' "$((PASSED + FAILED))"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
