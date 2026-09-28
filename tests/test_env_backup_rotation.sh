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

# env_backup_timestamp_for UTC_DIGITS
# A backup suffix in whatever format the installer writes today, but for a
# fixed instant instead of now. Built by taking a real stamp and swapping its
# trailing fourteen digits, so the fixtures below keep exercising the shipped
# format rather than a copy of it that can go stale.
env_backup_timestamp_for() {
    local fixed="$1" real
    real=$(env_backup_timestamp)
    if [ "${#real}" -lt 14 ]; then
        echo "  ERROR: env_backup_timestamp returned '$real', too short to rewrite" >&2
        exit 1
    fi
    printf '%s%s\n' "${real:0:${#real}-14}" "$fixed"
}

# ---------------------------------------------------------------------------
echo "=== the two installers produce the same timestamp shape ==="
# ---------------------------------------------------------------------------

bash_ts=$(env_backup_timestamp)
if [[ "$bash_ts" =~ ^utc[0-9]{14}$ ]]; then
    pass "install.sh timestamp is utc + 14 digits ($bash_ts)"
else
    fail "install.sh timestamp shape" "got '$bash_ts', want utc + 14 digits"
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

    if [[ "$pwsh_ts" =~ ^utc[0-9]{14}$ ]]; then
        pass "install.ps1 timestamp is utc + 14 digits ($pwsh_ts)"
    else
        fail "install.ps1 timestamp shape" "got '$pwsh_ts', want utc + 14 digits"
    fi

    # Bracket the PowerShell stamp between two bash stamps taken around it. If
    # both are UTC the middle one cannot fall outside the window; if either is
    # local time it lands hours away and the window rejects it.
    #
    # This used to compare the first ten characters -- yyyymmddhh, agreement to
    # the HOUR, not to the minute as its comment claimed -- and it broke
    # whenever the two calls straddled an hour boundary. Bracketing is exact
    # and has no boundary to straddle. Lexicographic comparison stands in for
    # chronological because both stamps are the same fixed-width format.
    bash_ts_after=$(env_backup_timestamp)
    if [[ ! "$pwsh_ts" < "$bash_ts" ]] && [[ ! "$pwsh_ts" > "$bash_ts_after" ]]; then
        pass "the pwsh stamp falls inside the bash-measured window (both UTC)"
    else
        fail "the pwsh stamp falls outside the window bash measured around it" \
            "bash '$bash_ts' .. '$bash_ts_after' does not contain pwsh '$pwsh_ts' -- one of them is not UTC"
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
echo "=== rotation survives the local-time PowerShell legacy format ==="
# ---------------------------------------------------------------------------
#
# The epoch case above is only half the migration, and the easy half. Before
# the unification install.ps1 stamped `Get-Date -Format yyyyMMddHHmmss` --
# fourteen digits of LOCAL time -- so its legacy backups are the same width as
# the fourteen-digit UTC stamps, and a name sort compares them digit for digit
# with nothing to tell them apart.
#
# East of UTC that ordering is inverted: a legacy local stamp is offset hours
# AHEAD of a UTC stamp minted at the same instant, so on a UTC+9 host every
# legacy backup written in the last nine hours outranks a brand-new one and
# rotation discards the file the installer just created.
#
# The fixture is fixed rather than derived from the current clock, so the case
# holds regardless of the timezone this test runs in.

dir_local="$WORK/localmix"
mkdir -p "$dir_local"
: > "$dir_local/.env"

# Three legacy PowerShell backups from a UTC+9 host: local 01:00, 02:00 and
# 03:00 on 2026-08-17, which are 16:00, 17:00 and 18:00 UTC on 2026-08-16.
for ts in 20260817010000 20260817020000 20260817030000; do
    : > "$dir_local/.env.backup.$ts"
done
# One backup minted by today's code at 19:00 UTC on 2026-08-16 -- an hour after
# all three above, so it is unambiguously the newest of the four.
newest_ts="$(env_backup_timestamp_for 20260816190000)"
: > "$dir_local/.env.backup.$newest_ts"

staged=$(cd "$dir_local" && ls -1 .env.backup.* 2>/dev/null | wc -l | tr -d ' ')
if [ "$staged" != "4" ]; then
    fail "the migration fixture did not stage" "expected 4 backups, found $staged"
else
    rotate_env_backups "$dir_local/.env" 3
    if [ -f "$dir_local/.env.backup.$newest_ts" ]; then
        pass "the newest backup survives alongside legacy local-time stamps"
    else
        left=$(cd "$dir_local" && ls -1 .env.backup.* 2>/dev/null | tr '\n' ' ')
        fail "rotation discarded the backup that was just created" \
            ".env.backup.$newest_ts is gone; left: $left"
    fi
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

# The two checks above are absence checks, and an absence check passes for the
# wrong reason as soon as the call is restructured -- rename the helper, spell
# the format differently, and both go green while the behaviour is gone. Pair
# them with the positive statement: each installer must actually emit the
# prefixed UTC form. The shapes asserted at the top of this file come from
# calling the functions; these two confirm the sources still say so.
bash_fn=$(sed -n '/^env_backup_timestamp()/,/^}/p' "$PROJECT_ROOT/scripts/install.sh")
if printf '%s' "$bash_fn" | grep -qF "printf 'utc%s" &&
   printf '%s' "$bash_fn" | grep -qF 'date -u +%Y%m%d%H%M%S'; then
    pass "install.sh builds the prefixed UTC stamp"
else
    fail "install.sh no longer builds the prefixed UTC stamp" \
        "env_backup_timestamp must emit utc + date -u +%Y%m%d%H%M%S"
fi

pwsh_fn=$(sed -n '/^function Get-EnvBackupTimestamp/,/^}/p' "$PROJECT_ROOT/scripts/install.ps1")
if printf '%s' "$pwsh_fn" | grep -qF "return 'utc' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')"; then
    pass "install.ps1 builds the prefixed UTC stamp"
else
    fail "install.ps1 no longer builds the prefixed UTC stamp" \
        "Get-EnvBackupTimestamp must emit 'utc' + UtcNow yyyyMMddHHmmss"
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
