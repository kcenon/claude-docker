#!/usr/bin/env bash
# setup-isolated.sh — Create independent per-account clones for ISOLATION_MODE=isolated.
#
# Usage:
#   setup-isolated.sh [--dry-run] <repo-dir> [account-count]
# Requires Python 3.9+. Preview prints paths/networks/budgets without writes.
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

# Used by the sourced host_policy function.
# shellcheck disable=SC2034
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
dry_run=false
args=()
for arg in "$@"; do
    if [[ "$arg" == --dry-run ]]; then dry_run=true; else args+=("$arg"); fi
done
policy_args=(setup --source "${args[0]:?Usage: setup-isolated.sh [--dry-run] <repo-dir> [account-count]}" --count "${args[1]:-2}")
if [[ "$dry_run" == true ]]; then policy_args+=(--dry-run); fi
host_policy "${policy_args[@]}"
