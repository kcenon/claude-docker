#!/usr/bin/env bash
# test_cleanup_backups.sh — Verifies scripts/cleanup.sh --backups flag.
#
# Run:  bash tests/test_cleanup_backups.sh
# Exits non-zero on any failure; prints a summary at the end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLEANUP="$PROJECT_ROOT/scripts/cleanup.sh"

PASS=0
FAIL=0

assert_missing() {
    local label="$1" path="$2"
    if [ ! -e "$path" ]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected missing: %s\n' "$label" "$path"
        FAIL=$((FAIL + 1))
    fi
}

assert_present() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected present: %s\n' "$label" "$path"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected: %q\n        actual:   %q\n' \
            "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

TMPDIR_FAKE_ROOT="$(mktemp -d)"
cleanup_tmp() {
    rm -rf "$TMPDIR_FAKE_ROOT"
}
trap cleanup_tmp EXIT

# Build the fake project root.
ENV_FILE="$TMPDIR_FAKE_ROOT/.env"
ENV_EXAMPLE="$TMPDIR_FAKE_ROOT/.env.example"
OLD_BACKUP="$TMPDIR_FAKE_ROOT/.env.backup.1234567890"
RECENT_BACKUP="$TMPDIR_FAKE_ROOT/.env.backup.9999999999"
OLD_BAK="$TMPDIR_FAKE_ROOT/.env.bak"
# 7.5 days old, tested against --backup-age-days 7. `find -mtime +7` truncates
# the age to whole days, so this reports 7 and is kept. The PowerShell port
# used to compare against an exact now-minus-7d instant and delete it: same
# flag, same value, opposite outcome. Test-FileAgeExceedsDays is pinned to the
# same verdict in tests/test_cleanup_gate.ps1.
HALF_DAY_BACKUP="$TMPDIR_FAKE_ROOT/.env.backup.7500000000"

printf 'KEY=value\n' > "$ENV_FILE"
printf 'KEY=example\n' > "$ENV_EXAMPLE"
printf 'KEY=old\n' > "$OLD_BACKUP"
printf 'KEY=fresh\n' > "$RECENT_BACKUP"
printf 'KEY=oldbak\n' > "$OLD_BAK"
printf 'KEY=sevenandahalf\n' > "$HALF_DAY_BACKUP"

# Mark old files 30 days in the past, leave fresh backup at current mtime.
# Use `touch -d` (GNU/BSD-portable form).
touch -d "30 days ago" "$OLD_BACKUP" "$OLD_BAK"
touch -d "180 hours ago" "$HALF_DAY_BACKUP"

echo "== Pre-check: fixture layout =="
assert_present ".env exists"               "$ENV_FILE"
assert_present ".env.example exists"       "$ENV_EXAMPLE"
assert_present "old .env.backup.* exists"  "$OLD_BACKUP"
assert_present "fresh .env.backup.* exists" "$RECENT_BACKUP"
assert_present ".env.bak exists"           "$OLD_BAK"
assert_present "7.5-day backup exists"     "$HALF_DAY_BACKUP"

echo "== Argument validation =="
# The flag used to consume whatever token followed it, so
# `--backups --backup-age-days --yes` set the age to "--yes" and left CONFIRM
# unset. Off a TTY that exited 1 for the wrong reason; on a TTY it prompted
# "older than --yes days?" and then ran a find that could not succeed.
run_cleanup_expect_status() {
    local label="$1" want="$2"; shift 2
    local home status=0
    home="$(mktemp -d)"
    HOME="$home" PROJECT_ROOT_OVERRIDE="$TMPDIR_FAKE_ROOT" \
        bash "$CLEANUP" "$@" >/dev/null 2>&1 </dev/null || status=$?
    rm -rf "$home"
    assert_eq "$label" "$want" "$status"
}

run_cleanup_expect_status "a flag as the age value exits 2" 2 \
    --backups --backup-age-days --yes
run_cleanup_expect_status "a non-integer age exits 2" 2 \
    --backups --backup-age-days seven --yes
run_cleanup_expect_status "a negative age exits 2" 2 \
    --backups --backup-age-days -5 --yes
run_cleanup_expect_status "an out-of-range age exits 2" 2 \
    --backups --backup-age-days 4000 --yes

# Validation must run before anything is deleted, not after.
assert_present "old backup survives a rejected age value" "$OLD_BACKUP"
assert_present ".env survives a rejected age value"       "$ENV_FILE"

echo "== Running: cleanup.sh --backups --yes --backup-age-days 7 =="
# --yes accepts both backup deletion and state-directory removal without
# prompting. HOME is redirected to a sandboxed temp dir so the real
# ~/.claude-state is never touched by the test. PROJECT_ROOT_OVERRIDE
# redirects the script to the temp fixture root.
# docker compose calls error harmlessly to /dev/null inside cleanup.sh.
FAKE_HOME="$(mktemp -d)"

# FAKE_HOME used to be an empty mktemp -d, so cleanup.sh's
# `[ -d "${HOME}/${state_dir}" ]` was false for every runtime and the
# destructive branch this run is supposed to exercise was never entered
# (#354, item 3). The whole state-removal half of the script was uncovered.
#
# The directories come from the registry rather than a hardcoded list, so a
# runtime added to runtimes.json is covered here the moment it is added --
# and a broken runtime_list / runtime_field(stateDir) link fails instead of
# quietly shrinking the set.
# The fixture root needs the registry. cleanup.sh resolves state-directory
# names through it, and PROJECT_ROOT_OVERRIDE points the script at a bare
# temp directory -- so runtime_list returned nothing, the removal loop
# iterated zero times, and the script still printed "State directories
# removed." Populating the fixture is what makes this run reach the code.
mkdir -p "$TMPDIR_FAKE_ROOT/tui/internal/config"
cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" \
   "$TMPDIR_FAKE_ROOT/tui/internal/config/runtimes.json"

# shellcheck source=../scripts/lib/runtime.sh
. "$PROJECT_ROOT/scripts/lib/runtime.sh"

STATE_DIRS=()
while IFS= read -r rt; do
    [ -z "$rt" ] && continue
    sd="$(runtime_field "$rt" "stateDir")"
    [ -z "$sd" ] && continue
    mkdir -p "$FAKE_HOME/$sd/account-a"
    printf 'placeholder\n' > "$FAKE_HOME/$sd/account-a/marker"
    STATE_DIRS+=("$sd")
done < <(runtime_list)

if [ "${#STATE_DIRS[@]}" -eq 0 ]; then
    printf '  FAIL  no runtime state directories were derived from the registry\n'
    FAIL=$((FAIL + 1))
fi

cleanup_status=0
HOME="$FAKE_HOME" PROJECT_ROOT_OVERRIDE="$TMPDIR_FAKE_ROOT" \
    bash "$CLEANUP" --backups --yes --backup-age-days 7 >/dev/null 2>&1 || cleanup_status=$?

echo "== State directories =="
# The exit code was discarded with `|| true`, so cleanup.sh could fail
# outright and every assertion below would still describe a clean run.
assert_eq "cleanup.sh exits 0" "0" "$cleanup_status"
for sd in "${STATE_DIRS[@]}"; do
    assert_missing "state dir $sd removed" "$FAKE_HOME/$sd"
done

rm -rf "$FAKE_HOME"

echo "== Post-conditions =="
assert_missing "old .env.backup.* deleted" "$OLD_BACKUP"
assert_missing "old .env.bak deleted"      "$OLD_BAK"
assert_present "fresh .env.backup.* kept"  "$RECENT_BACKUP"
assert_present ".env preserved"            "$ENV_FILE"
assert_present ".env.example preserved"    "$ENV_EXAMPLE"
# The whole-day truncation, asserted against real find(1) rather than assumed.
assert_present "7.5-day backup kept at --backup-age-days 7" "$HALF_DAY_BACKUP"

# Content sanity check on preserved files.
assert_eq ".env content unchanged"         "KEY=value"   "$(cat "$ENV_FILE")"
assert_eq ".env.example content unchanged" "KEY=example" "$(cat "$ENV_EXAMPLE")"
assert_eq "fresh backup content unchanged" "KEY=fresh"   "$(cat "$RECENT_BACKUP")"

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
if (( FAIL > 0 )); then
    exit 1
fi
