#!/usr/bin/env bash
# Cleanup containers, worktrees, and state.
#
# Usage:
#   scripts/cleanup.sh [REPO_DIR] [--yes|-y | --no|-n] [--backups|-b] [--backup-age-days N]
#
# Without --yes or --no, state-directory removal is prompted interactively
# when stdin is a TTY and aborted (non-zero exit) otherwise, so CI or piped
# invocations never hang waiting for an answer.
#
# When --backups is given, .env.backup.* and .env.bak files older than
# --backup-age-days (default 7) are deleted from PROJECT_ROOT. Set
# PROJECT_ROOT_OVERRIDE to redirect the script root for tests.
set -euo pipefail

# Platform guard: same rationale as install.sh - refuse to run on native
# Windows shells (Git Bash, MSYS, Cygwin). The state directories removed below
# are addressed by MSYS-flavored paths that do not match what the PowerShell
# installer created, so a run that appeared to succeed would leave the real
# state in place. Placed ahead of the runtime-registry read for the same reason
# as generate-compose.sh: on Windows that read misreports every registered
# runtime as unknown (#306).
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: cleanup.sh is not supported on native Windows shells." >&2
        echo "Use: pwsh -ExecutionPolicy Bypass -File scripts\\cleanup.ps1" >&2
        exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$PROJECT_ROOT"

# runtime.sh resolves per-runtime state-directory names from the registry so
# state cleanup covers every registered runtime, not just Claude (see #273).
# shellcheck source=lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# worktrees.sh decides which worktrees this installer owns, shared with
# remove.sh so the two cannot disagree. It reads .env through parse_env.sh.
# shellcheck source=lib/parse_env.sh
. "$SCRIPT_DIR/lib/parse_env.sh"
# shellcheck source=lib/worktrees.sh
. "$SCRIPT_DIR/lib/worktrees.sh"

REPO_DIR=""
CONFIRM="ask"
RUN_BACKUPS=0
BACKUP_AGE_DAYS=7
expect_age_days=0
for arg in "$@"; do
    if [ "$expect_age_days" = "1" ]; then
        # Validate before assigning. Unchecked, this branch swallowed whatever
        # token followed the flag: `--backups --backup-age-days --yes` set the
        # age to "--yes" and left CONFIRM unset, so the prompt read "older than
        # --yes days?" and the find that followed failed silently.
        case "$arg" in
            ''|*[!0-9]*)
                echo "Invalid --backup-age-days value: $arg (expected a non-negative integer)" >&2
                exit 2
                ;;
        esac
        if [ "$arg" -gt 3650 ]; then
            echo "Invalid --backup-age-days value: $arg (maximum 3650)" >&2
            exit 2
        fi
        BACKUP_AGE_DAYS="$arg"
        expect_age_days=0
        continue
    fi
    case "$arg" in
        --yes|-y) CONFIRM="yes" ;;
        --no|-n)  CONFIRM="no"  ;;
        --backups|-b) RUN_BACKUPS=1 ;;
        --backup-age-days) expect_age_days=1 ;;
        -*)
            echo "Unknown option: $arg" >&2
            echo "Usage: scripts/cleanup.sh [REPO_DIR] [--yes|-y | --no|-n] [--backups|-b] [--backup-age-days N]" >&2
            exit 2
            ;;
        *)
            if [ -z "$REPO_DIR" ]; then
                REPO_DIR="$arg"
            else
                echo "Unexpected extra argument: $arg" >&2
                exit 2
            fi
            ;;
    esac
done

if [ "$expect_age_days" = "1" ]; then
    echo "Missing value for --backup-age-days" >&2
    exit 2
fi

if [ "$RUN_BACKUPS" = "1" ]; then
    echo "=== Removing stale .env backup files (>${BACKUP_AGE_DAYS} days) ==="
    BACKUP_CONFIRM="$CONFIRM"
    if [ "$BACKUP_CONFIRM" = "ask" ]; then
        if [ -t 0 ]; then
            read -p "Remove stale .env.backup.* and .env.bak files older than ${BACKUP_AGE_DAYS} days? (y/N) " confirm
            case "$confirm" in
                y|Y|yes|YES) BACKUP_CONFIRM="yes" ;;
                *)           BACKUP_CONFIRM="no"  ;;
            esac
        else
            echo "  Error: stdin is not a TTY. Pass --yes to remove backups non-interactively," >&2
            echo "         or --no to skip backup removal in automation." >&2
            exit 1
        fi
    fi
    if [ "$BACKUP_CONFIRM" = "yes" ]; then
        # Branch on find's status. `|| true` plus an unconditional success
        # message reported a sweep that never ran as a sweep that succeeded.
        if find "$PROJECT_ROOT" -maxdepth 1 \
                \( -name ".env.backup.*" -o -name ".env.bak" \) \
                -mtime +"${BACKUP_AGE_DAYS}" \
                -print -delete 2>/dev/null; then
            echo "  Stale backups removed."
        else
            echo "  Error: find failed while sweeping backups; nothing was reported as removed." >&2
            exit 1
        fi
    else
        echo "  Skipped."
    fi
fi

echo "=== Stopping containers ==="
docker compose down --remove-orphans 2>/dev/null || true

echo "=== Removing named volumes ==="
docker compose down -v 2>/dev/null || true

echo "=== Removing worktrees (if Tier B) ==="
if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR"
    # The loop this replaces read the porcelain output through
    # `awk '{print $2}'`, which truncates a path at its first space, and then
    # word-split the unquoted substitution again. `git worktree remove` failed
    # on the resulting non-existent path, `|| true` swallowed it, and the run
    # printed "Removing worktree: /Users/me/My" as though it had succeeded --
    # while the real worktree survived to collide with the next install.
    #
    # Ownership is checked for the same reason as in remove.sh: a worktree the
    # user added themselves is not this tool's to delete.
    while IFS= read -r wt; do
        if ! worktree_is_owned "$wt" "$REPO_DIR" "$PROJECT_ROOT/.env"; then
            echo "  Keeping worktree not created by claude-docker: $wt"
            continue
        fi
        echo "  Removing worktree: $wt"
        if ! git worktree remove "$wt" --force 2>/dev/null; then
            echo "  Warning: git declined to remove $wt - left in place." >&2
        fi
    done < <(worktree_selectable_paths "$(pwd)")
    cd "$PROJECT_ROOT"
fi

echo "=== Removing state directories ==="
if [ "$CONFIRM" = "ask" ]; then
    if [ -t 0 ]; then
        read -p "Remove every runtime's state directory (~/.*-state)? (y/N) " confirm
        case "$confirm" in
            y|Y|yes|YES) CONFIRM="yes" ;;
            *)           CONFIRM="no"  ;;
        esac
    else
        echo "  Error: stdin is not a TTY. Pass --yes to remove state non-interactively," >&2
        echo "         or --no to skip state removal in automation." >&2
        exit 1
    fi
fi

if [ "$CONFIRM" = "yes" ]; then
    # Remove every registered runtime's state directory, not just Claude's,
    # so a codex/gemini install is fully cleaned up (see #273).
    runtimes_seen=0
    while IFS= read -r runtime; do
        [ -z "$runtime" ] && continue
        runtimes_seen=$((runtimes_seen + 1))
        state_dir="$(runtime_field "$runtime" "stateDir")"
        [ -z "$state_dir" ] && continue
        if [ -d "${HOME}/${state_dir}" ]; then
            rm -rf "${HOME:?}/${state_dir}"
            echo "  Removed: ~/${state_dir}"
        fi
    done < <(runtime_list)

    # runtime_list returns nothing and exits 0 when the registry is
    # unreadable, so this loop could iterate zero times and the line below
    # would still announce a completed removal. Reporting "removed" having
    # examined no runtime at all is how state survives a cleanup silently.
    if [ "$runtimes_seen" -eq 0 ]; then
        echo "  Error: no runtimes found in the registry; no state directory was examined." >&2
        echo "         Expected ${PROJECT_ROOT}/tui/internal/config/runtimes.json." >&2
        exit 1
    fi
    echo "  State directories removed."
else
    echo "  Skipped."
fi

echo "=== Cleanup complete ==="
