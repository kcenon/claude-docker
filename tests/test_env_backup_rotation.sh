#!/usr/bin/env bash
# test_env_backup_rotation.sh - both installers name .env backups the same way,
# so name-sort rotation keeps the newest three (issue #356, row 8).
#
# Run:  bash tests/test_env_backup_rotation.sh
# Exits non-zero on any failure.
#
# install.sh wrote a 10-digit `date +%s` epoch and install.ps1 wrote a 14-digit
# yyyyMMddHHmmss, and both rotate by name sort. Lexicographically a 14-digit
# "2026..." is above every 10-digit epoch, so a project root that had seen both
# installers kept the three newest *PowerShell* backups and discarded newer
# bash ones -- silently, since rotation prints nothing about what it removed.
#
# Note what changed and what did not. rotate_env_backups is untouched -- the
# defect was never in the sorting, it was in the two names being sorted. So the
# mixed-format case below is a regression guard rather than a red-first
# demonstration: it passes against the old code too, because it stages files
# directly instead of running an installer.
#
# The assertion that does fail against the old code is "a newly minted stamp
# sorts above a legacy epoch", which is the migration property the choice of
# format rests on, and the only thing a new backup's *name* can be judged by
# without driving an interactive installer.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The two functions under test are defined inside install.sh, which runs an
# installer when sourced. Extract them, the way scripts/test-entrypoint-settings.sh
# lifts generate_container_settings.
BACKUP_SRC=$(sed -n '/^env_backup_timestamp()/,/^}/p;/^rotate_env_backups()/,/^}/p' \
    "$PROJECT_ROOT/scripts/install.sh")
if [ -z "$BACKUP_SRC" ]; then
    echo "  ERROR: could not extract the backup helpers from scripts/install.sh" >&2
    exit 1
fi
eval "$BACKUP_SRC"

# ---------------------------------------------------------------------------
echo "=== the two installers produce the same timestamp shape ==="
# ---------------------------------------------------------------------------

bash_ts=$(env_backup_timestamp)
if [[ "$bash_ts" =~ ^[0-9]{14}$ ]]; then
    pass "install.sh timestamp is 14 digits ($bash_ts)"
else
    fail "install.sh timestamp shape" "got '$bash_ts', want 14 digits"
fi

if command -v pwsh >/dev/null 2>&1; then
    pwsh_ts=$(pwsh -NoProfile -Command "
        Import-Module '$PROJECT_ROOT/scripts/ClaudeDocker.psm1' -Force -ErrorAction SilentlyContinue
        \$src = Get-Content '$PROJECT_ROOT/scripts/install.ps1' -Raw
        \$m = [regex]::Match(\$src, '(?ms)^function Get-EnvBackupTimestamp \{.*?\n\}')
        if (-not \$m.Success) { 'NOTFOUND'; exit }
        Invoke-Expression \$m.Value
        Get-EnvBackupTimestamp
    " 2>/dev/null | tr -d '\r' | tail -1)

    if [[ "$pwsh_ts" =~ ^[0-9]{14}$ ]]; then
        pass "install.ps1 timestamp is 14 digits ($pwsh_ts)"
    else
        fail "install.ps1 timestamp shape" "got '$pwsh_ts', want 14 digits"
    fi

    # Same second or adjacent: both are UTC now, so they must not differ by an
    # hour, which is what a local-vs-UTC mismatch would look like.
    if [ "${bash_ts:0:10}" = "${pwsh_ts:0:10}" ]; then
        pass "both timestamps agree to the minute (both UTC)"
    else
        fail "the two timestamps disagree beyond seconds" \
            "bash '$bash_ts' vs pwsh '$pwsh_ts' -- one of them is not UTC"
    fi
elif [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "  ERROR: pwsh is preinstalled on the CI runner; a skip here hides a failure" >&2
    exit 1
else
    echo "  NOTE: pwsh unavailable; the cross-language half is skipped" >&2
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== rotation keeps the newest three, mixed formats included ==="
# ---------------------------------------------------------------------------
#
# Six backups: three in the legacy 10-digit epoch format and three in the
# unified 14-digit one, with the epoch ones genuinely older. Name-sort
# rotation must keep the three 14-digit files.

dir="$WORK/mixed"
mkdir -p "$dir"
: > "$dir/.env"

# Epoch values for 2024-01-01, -02, -03 -- older than any 2026 timestamp.
for ts in 1704067200 1704153600 1704240000; do
    : > "$dir/.env.backup.$ts"
done
for ts in 20260101000000 20260102000000 20260103000000; do
    : > "$dir/.env.backup.$ts"
done

# The migration property, and the one assertion here that the old code fails:
# a stamp minted now must sort above a legacy epoch, so an upgrade rotates the
# old ones out first. With the epoch format the new stamp sorted *below* every
# 14-digit PowerShell backup already on disk, and was discarded first instead.
legacy_epoch="1704067200"          # 2024-01-01, older than anything new
if [ "$(printf '%s\n%s\n' "$legacy_epoch" "$bash_ts" | sort | tail -1)" = "$bash_ts" ]; then
    pass "a new timestamp sorts above a legacy epoch backup"
else
    fail "a new timestamp sorts below a legacy epoch backup" \
        "new '$bash_ts' vs legacy '$legacy_epoch' -- rotation would discard the new one first"
fi

rotate_env_backups "$dir/.env" 3

remaining=$(cd "$dir" && ls -1 .env.backup.* 2>/dev/null | sort | tr '\n' ' ')
want=".env.backup.20260101000000 .env.backup.20260102000000 .env.backup.20260103000000 "
if [ "$remaining" = "$want" ]; then
    pass "the three newest survive and the legacy epoch ones are removed"
else
    fail "mixed-format rotation kept the wrong set" "got: $remaining"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== rotation is a no-op below the keep count ==="
# ---------------------------------------------------------------------------
#
# Without this, "keeps the newest three" is satisfied by a rotation that
# deletes everything down to three, including when there are fewer.

dir2="$WORK/few"
mkdir -p "$dir2"
: > "$dir2/.env"
for ts in 20260101000000 20260102000000; do
    : > "$dir2/.env.backup.$ts"
done

rotate_env_backups "$dir2/.env" 3

count=$(cd "$dir2" && ls -1 .env.backup.* 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" = "2" ]; then
    pass "two backups are left alone"
else
    fail "rotation removed backups below the keep count" "left $count of 2"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== neither installer writes the legacy epoch format ==="
# ---------------------------------------------------------------------------

if grep -nE 'backup\.\$\(date \+%s\)' "$PROJECT_ROOT/scripts/install.sh" >/dev/null 2>&1; then
    fail "install.sh still names backups with an epoch" "date +%s"
else
    pass "install.sh does not use the epoch format"
fi

if grep -nE "Get-Date -Format 'yyyyMMddHHmmss'" "$PROJECT_ROOT/scripts/install.ps1" >/dev/null 2>&1; then
    fail "install.ps1 still stamps in local time" "Get-Date instead of UtcNow"
else
    pass "install.ps1 stamps through the shared helper"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$PASS" -eq 0 ]; then
    echo "  ERROR: no assertions ran" >&2
    exit 1
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
