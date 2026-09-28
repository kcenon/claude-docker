#!/usr/bin/env bash
# Setup git worktrees for Tier B (supports N accounts)
#
# Usage:
#   setup-worktrees.sh <repo-dir> [branch-1] [branch-2] ... [branch-N]
#
# If no branch names are provided, defaults to worktree-a and worktree-b.
set -euo pipefail

# Platform guard: refuse to run on native Windows shells (Git Bash, MSYS,
# Cygwin). `git worktree add` receives MSYS-flavored /c/... paths there, which
# compose volume mounts cannot resolve, leaving Tier B worktrees unusable.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: setup-worktrees.sh is not supported on native Windows shells." >&2
        echo "Use: pwsh -ExecutionPolicy Bypass -File scripts\\setup-worktrees.ps1" >&2
        exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/index.sh
. "$SCRIPT_DIR/lib/index.sh"

REPO_DIR="${1:?Usage: setup-worktrees.sh <repo-dir> [branch...]}"; shift

# Default branches if none provided
if [[ $# -eq 0 ]]; then
    set -- "worktree-a" "worktree-b"
fi

BRANCHES=("$@")

# Validate
if [ ! -d "$REPO_DIR/.git" ]; then
    echo "Error: $REPO_DIR is not a git repository" >&2
    exit 1
fi

# index_to_letter provided by scripts/lib/index.sh.

cd "$REPO_DIR"

echo "Creating ${#BRANCHES[@]} worktree(s)..."

for i in "${!BRANCHES[@]}"; do
    idx=$((i + 1))
    branch="${BRANCHES[$i]}"
    letter=$(index_to_letter "$idx")
    worktree="${REPO_DIR%/}-${letter}"

    git branch "$branch" 2>/dev/null || true
    git worktree add "$worktree" "$branch"
    echo "  $(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]'): $worktree (branch: $branch)"
done

echo ""
echo "Add to .env:"
for i in "${!BRANCHES[@]}"; do
    idx=$((i + 1))
    letter=$(index_to_letter "$idx")
    upper=$(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]')
    echo "  PROJECT_DIR_${upper}=${REPO_DIR%/}-${letter}"
done
