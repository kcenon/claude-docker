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

printf 'KEY=value\n' > "$ENV_FILE"
printf 'KEY=example\n' > "$ENV_EXAMPLE"
printf 'KEY=old\n' > "$OLD_BACKUP"
printf 'KEY=fresh\n' > "$RECENT_BACKUP"
printf 'KEY=oldbak\n' > "$OLD_BAK"

# Mark old files 30 days in the past, leave fresh backup at current mtime.
# Use `touch -d` (GNU/BSD-portable form).
touch -d "30 days ago" "$OLD_BACKUP" "$OLD_BAK"

echo "== Pre-check: fixture layout =="
assert_present ".env exists"               "$ENV_FILE"
assert_present ".env.example exists"       "$ENV_EXAMPLE"
assert_present "old .env.backup.* exists"  "$OLD_BACKUP"
assert_present "fresh .env.backup.* exists" "$RECENT_BACKUP"
assert_present ".env.bak exists"           "$OLD_BAK"

echo "== Running: cleanup.sh --backups --yes --backup-age-days 7 =="
# --yes accepts both backup deletion and state-directory removal without
# prompting. HOME is redirected to a sandboxed temp dir so the real
# ~/.claude-state is never touched by the test. PROJECT_ROOT_OVERRIDE
# redirects the script to the temp fixture root.
# docker compose calls error harmlessly to /dev/null inside cleanup.sh.
FAKE_HOME="$(mktemp -d)"
HOME="$FAKE_HOME" PROJECT_ROOT_OVERRIDE="$TMPDIR_FAKE_ROOT" \
    bash "$CLEANUP" --backups --yes --backup-age-days 7 >/dev/null 2>&1 || true
rm -rf "$FAKE_HOME"

echo "== Post-conditions =="
assert_missing "old .env.backup.* deleted" "$OLD_BACKUP"
assert_missing "old .env.bak deleted"      "$OLD_BAK"
assert_present "fresh .env.backup.* kept"  "$RECENT_BACKUP"
assert_present ".env preserved"            "$ENV_FILE"
assert_present ".env.example preserved"    "$ENV_EXAMPLE"

# Content sanity check on preserved files.
assert_eq ".env content unchanged"         "KEY=value"   "$(cat "$ENV_FILE")"
assert_eq ".env.example content unchanged" "KEY=example" "$(cat "$ENV_EXAMPLE")"
assert_eq "fresh backup content unchanged" "KEY=fresh"   "$(cat "$RECENT_BACKUP")"

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
if (( FAIL > 0 )); then
    exit 1
fi
