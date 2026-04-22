#!/usr/bin/env bash
# Cleanup containers, worktrees, and state.
#
# Usage:
#   scripts/cleanup.sh [REPO_DIR] [--yes|-y | --no|-n]
#
# Without --yes or --no, state-directory removal is prompted interactively
# when stdin is a TTY and aborted (non-zero exit) otherwise, so CI or piped
# invocations never hang waiting for an answer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

REPO_DIR=""
CONFIRM="ask"
for arg in "$@"; do
    case "$arg" in
        --yes|-y) CONFIRM="yes" ;;
        --no|-n)  CONFIRM="no"  ;;
        -*)
            echo "Unknown option: $arg" >&2
            echo "Usage: scripts/cleanup.sh [REPO_DIR] [--yes|-y | --no|-n]" >&2
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
