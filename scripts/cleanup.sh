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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$PROJECT_ROOT"

REPO_DIR=""
CONFIRM="ask"
RUN_BACKUPS=0
BACKUP_AGE_DAYS=7
expect_age_days=0
for arg in "$@"; do
    if [ "$expect_age_days" = "1" ]; then
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
        find "$PROJECT_ROOT" -maxdepth 1 \
            \( -name ".env.backup.*" -o -name ".env.bak" \) \
            -mtime +"${BACKUP_AGE_DAYS}" \
            -print -delete 2>/dev/null || true
        echo "  Stale backups removed."
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
    for wt in $(git worktree list --porcelain | grep "^worktree " | awk '{print $2}'); do
        if [ "$wt" != "$(pwd)" ]; then
            echo "  Removing worktree: $wt"
            git worktree remove "$wt" --force 2>/dev/null || true
        fi
    done
fi

echo "=== Removing state directories ==="
if [ "$CONFIRM" = "ask" ]; then
    if [ -t 0 ]; then
        read -p "Remove ~/.claude-state/*? (y/N) " confirm
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
    rm -rf "${HOME}/.claude-state"
    echo "  State directories removed."
else
    echo "  Skipped."
fi

echo "=== Cleanup complete ==="
