#!/usr/bin/env bash
# Setup git worktrees for Tier B (supports N accounts)
#
# Usage:
#   setup-worktrees.sh <repo-dir> [branch-1] [branch-2] ... [branch-N]
#
# If no branch names are provided, defaults to worktree-a and worktree-b.
set -euo pipefail

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

# Convert 1-based index to Excel-style lowercase letters:
#   1→a, 26→z, 27→aa, 52→az, 702→zz.
index_to_letter() {
    local n="$1"
    local out=""
    local rem
    while (( n > 0 )); do
        rem=$(( (n - 1) % 26 ))
        out=$(printf "\\$(printf '%03o' $((97 + rem)))")$out
        n=$(( (n - 1) / 26 ))
    done
    printf '%s' "$out"
}

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
