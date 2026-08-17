#!/usr/bin/env bash
# setup-isolated.sh — Create independent per-account clones for ISOLATION_MODE=isolated.
#
# Usage:
#   setup-isolated.sh <repo-dir> [account-count]
#
# account-count defaults to 2, matching the compose generator's NUM_ACCOUNTS
# default. Set it to the same value you configured there.
#
# This is the isolated-mode counterpart to setup-worktrees.sh, and the
# difference between them is the whole point of the two modes. `git worktree`
# gives each account its own working tree but ONE shared object store and
# administrative directory, so an account can still read every branch and
# rewrite refs the others depend on. This script produces fully independent
# clones instead: no hard links, no alternates, nothing shared.
set -euo pipefail

# Platform guard: refuse to run on native Windows shells (Git Bash, MSYS,
# Cygwin), for the same reason setup-worktrees.sh does. The paths printed for
# .env would be MSYS-flavored /c/... paths, which compose volume mounts cannot
# resolve, leaving the isolated workspaces unusable.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: setup-isolated.sh is not supported on native Windows shells." >&2
        echo "Use: pwsh -ExecutionPolicy Bypass -File scripts\\setup-isolated.ps1" >&2
        exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/index.sh
. "$SCRIPT_DIR/lib/index.sh"

REPO_DIR="${1:?Usage: setup-isolated.sh <repo-dir> [account-count]}"
RAW_COUNT="${2:-2}"

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "Error: $REPO_DIR is not a git repository" >&2
    exit 1
fi

if ! COUNT=$(normalize_account_count "$RAW_COUNT"); then
    echo "Error: account count must be an integer between 1 and $(max_account_count) (got: $RAW_COUNT)" >&2
    exit 1
fi

REPO_DIR="${REPO_DIR%/}"

# repoint_origin TARGET
# `git clone <local-path>` sets origin to that path. An isolated container never
# sees it — the shared source is precisely what this mode hides — so an origin
# left pointing there makes fetch and push fail from inside the container.
# Repoint at the source repository's own upstream, and strip any credential
# embedded in it rather than copying a token into N clones.
repoint_origin() {
    local target="$1" upstream

    upstream="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
        echo "     note: $REPO_DIR has no origin remote; the clone keeps a local-path origin" >&2
        return 0
    fi

    # Only http(s) URLs carrying userinfo are rewritten. `ssh://git@host/path`
    # and `git@host:path` put the SSH user — not a secret — in that position,
    # and stripping it would break authentication.
    if [[ "$upstream" =~ ^(https?://)[^/@]*@(.*)$ ]]; then
        upstream="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        echo "     note: removed credentials embedded in the origin URL" >&2
    fi

    git -C "$target" remote set-url origin "$upstream"
}

echo "Creating $COUNT independent clone(s)..."

for i in $(seq 1 "$COUNT"); do
    letter=$(index_to_letter "$i")
    upper=$(index_to_upper "$i")
    target="${REPO_DIR}-isolated-${letter}"

    if [ -d "$target/.git" ]; then
        # Idempotent: an existing clone is left exactly as it is. Re-cloning
        # would discard whatever that account has been working on.
        echo "  ${upper}: $target (already a clone, left unchanged)"
        continue
    fi

    if [ -e "$target" ]; then
        echo "Error: $target exists but is not a git repository." >&2
        echo "       Move or remove it yourself; this script never deletes host paths." >&2
        exit 1
    fi

    # --no-hardlinks is the flag that makes this independent. Cloning a local
    # path hardlinks the object store by default, which would leave every
    # account sharing objects — the property that disqualifies worktree mode as
    # a security boundary. Untracked files (.env, credentials) are never
    # cloned, so nothing secret travels from the source tree.
    git clone --no-hardlinks "$REPO_DIR" "$target"
    repoint_origin "$target"

    echo "  ${upper}: $target (independent clone)"
done

echo ""
echo "Add to .env:"
echo "  ISOLATION_MODE=isolated"
for i in $(seq 1 "$COUNT"); do
    upper=$(index_to_upper "$i")
    letter=$(index_to_letter "$i")
    echo "  ISOLATED_WORKSPACE_${upper}=${REPO_DIR}-isolated-${letter}"
done
echo ""
echo "Then regenerate compose: scripts/generate-compose.sh"
