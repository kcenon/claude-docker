#!/bin/bash
# Entrypoint: prepare per-account agent state before running the requested
# command. Claude remains the default runtime; Codex is selected by setting
# AGENT_RUNTIME=codex in the generated compose file.
#
# This is a thin dispatcher (issue #269): it validates the runtime against
# the registry, sources the matching per-runtime bootstrap module via the
# registry's `bootstrapModule` field, runs the runtime-agnostic common
# steps, and finally execs the requested command. All runtime-specific
# logic lives in scripts/lib/bootstrap-<runtime>.sh.

# --- Library resolution ----------------------------------------------------------
# The shared libraries (runtime.sh, bootstrap-common.sh) and the per-runtime
# bootstrap modules are copied into the image alongside the runtime registry,
# preserving the repo's scripts/lib + tui/internal/config layout so runtime.sh
# resolves runtimes.json via PROJECT_ROOT. On a developer host this file runs
# from scripts/ and the layout is the repo itself.
if [ -n "${CLAUDE_DOCKER_ROOT:-}" ] && [ -d "$CLAUDE_DOCKER_ROOT" ]; then
    PROJECT_ROOT="$CLAUDE_DOCKER_ROOT"
elif [ -d /usr/local/share/claude-docker ]; then
    PROJECT_ROOT="/usr/local/share/claude-docker"
else
    PROJECT_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fi
export PROJECT_ROOT
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# parse_env.sh first: runtime.sh's agent_runtime falls back to parsing
# AGENT_RUNTIME from $PROJECT_ROOT/.env (via parse_env_value) when the env
# var is unset, which is the claude-default case (compose only injects
# AGENT_RUNTIME for codex). Source order mirrors scripts/generate-compose.sh.
# shellcheck source=scripts/lib/parse_env.sh
. "$LIB_DIR/parse_env.sh"
# shellcheck source=scripts/lib/runtime.sh
. "$LIB_DIR/runtime.sh"
# shellcheck source=scripts/lib/bootstrap-common.sh
. "$LIB_DIR/bootstrap-common.sh"

# --- Runtime validation ----------------------------------------------------------
# agent_runtime validates AGENT_RUNTIME against the registry (runtime_list)
# and prints the normalized runtime name; on an unknown value it writes its
# own diagnostic to stderr and returns non-zero, so just propagate the exit.
if ! AGENT_RUNTIME="$(agent_runtime)"; then
    exit 1
fi
export AGENT_RUNTIME

# --- Per-runtime bootstrap -------------------------------------------------------
# Dispatch via the registry's bootstrapModule field rather than a hardcoded
# block. Each module defines a runtime_bootstrap function.
BOOTSTRAP_MODULE="$(runtime_field "$AGENT_RUNTIME" "bootstrapModule")"
if [ -z "$BOOTSTRAP_MODULE" ] || [ ! -f "$LIB_DIR/$BOOTSTRAP_MODULE" ]; then
    echo "[entrypoint] ERROR: bootstrap module for runtime '$AGENT_RUNTIME' not found ($BOOTSTRAP_MODULE)" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$LIB_DIR/$BOOTSTRAP_MODULE"
runtime_bootstrap

# --- Git identity ----------------------------------------------------------------
# Set git user from environment variables (if not already configured)
if [ -n "${GIT_USER_NAME:-}" ] && [ -z "$(git config --global user.name 2>/dev/null)" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ] && [ -z "$(git config --global user.email 2>/dev/null)" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# --- Bind-mounted project script CRLF normalization (opt-in) -----------------
# /project is a bind mount from the host. Rewriting files here mutates host
# files, which can trigger editor "file changed" dialogs, show up as
# unexpected diffs in `git status`, or race with concurrent host writes.
# The sweep therefore runs only when the user explicitly opts in via
# CLAUDE_NORMALIZE_CRLF=1 in .env (typical case: Windows hosts with
# CRLF-default editors and no enforcing .gitattributes in the project repo).
# Best-effort: bounded depth to avoid scanning huge monorepos, errors
# suppressed so the entrypoint never fails on read-only mounts or missing
# directories.
if [ -d /project ] && [ "${CLAUDE_NORMALIZE_CRLF:-0}" = "1" ]; then
    sh_count=$(find /project -maxdepth 3 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "${sh_count:-0}" -gt 0 ]; then
        find /project -maxdepth 3 -name '*.sh' -type f \
            -exec sed -i 's/\r$//' {} + 2>/dev/null || true
        echo "[entrypoint] CRLF normalized in ${sh_count} shell script(s) under /project (opt-in)"
    fi
fi

# --- Git credential helper (gh) -------------------------------------------------
# Wire gh as git credential helper so git push/pull uses the mounted gh token
if command -v gh >/dev/null 2>&1; then
    if [ -n "${GH_TOKEN:-}" ]; then
        # GH_TOKEN env var takes precedence — no hosts.yml needed
        gh auth setup-git 2>/dev/null || true
        echo "[entrypoint] GitHub auth: using GH_TOKEN environment variable"
    elif [ -f /home/node/.config/gh/hosts.yml ]; then
        gh auth setup-git 2>/dev/null || true
        # Validate the credential gh actually uses for API calls. `gh api user`
        # is checked instead of `gh auth status` because the latter also
        # evaluates the unusable mounted `default` account and exits non-zero.
        # macOS Keychain / Windows Credential Manager tokens are NOT in
        # hosts.yml — only the host config structure is present.
        if ! gh api user --jq .login >/dev/null 2>&1; then
            echo "[entrypoint] WARNING: GitHub token is invalid or missing."
            echo "  On macOS/Windows, gh stores tokens in OS credential stores"
            echo "  (Keychain / Credential Manager), not in hosts.yml."
            echo "  The read-only bind mount cannot access these tokens."
            echo ""
            echo "  Fix: run on the host:"
            echo "    scripts/claude-docker gh-auth"
        fi
    else
        echo "[entrypoint] WARNING: No GitHub credentials found."
        echo "  git push/pull and gh commands will fail without authentication."
        echo ""
        echo "  Fix: run on the host:"
        echo "    scripts/claude-docker gh-auth"
        echo "  Or re-run the installer to auto-detect from gh CLI."
    fi
fi

exec "$@"
