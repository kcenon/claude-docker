#!/usr/bin/env bash
# build-compose-cmd.sh — Shared compose-overlay logic for bash callers.
#
# Source this file, then call `build_compose_cmd`. The function populates
# the global COMPOSE_CMD array with `docker compose -f ...` based on:
#   1. Always: docker-compose.yml
#   2. Linux + docker-compose.linux.yml exists: add linux overlay,
#      export UID/GID
#   3. The resolved ISOLATION_MODE is worktree: add the worktree overlay
#
# Inputs: PROJECT_ROOT must be set in the caller's environment.
# Output: COMPOSE_CMD array (caller can invoke as "${COMPOSE_CMD[@]}" up -d)
# Returns non-zero when the configured mode is unusable; callers run under
# `set -e` and abort rather than start containers on a weaker boundary.
#
# Requires: scripts/lib/parse_env.sh and scripts/lib/isolation.sh sourced
# before this file.

# Guard against double-sourcing.
if [[ -n "${_CLAUDE_DOCKER_BUILD_COMPOSE_CMD_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_BUILD_COMPOSE_CMD_SH_SOURCED=1

# build_compose_cmd
# Populate the global COMPOSE_CMD array with the full `docker compose -f ...`
# invocation. Array form preserves quoting of paths containing whitespace.
#
# Overlay selection logic (canonical):
#   1. Base docker-compose.yml is always included.
#   2. docker-compose.linux.yml is added on Linux hosts when the file exists;
#      UID/GID are exported for the Linux override to consume.
#   3. docker-compose.worktree.yml is added when the resolved ISOLATION_MODE
#      is worktree.
build_compose_cmd() {
    COMPOSE_CMD=(docker compose -f "${PROJECT_ROOT}/docker-compose.yml")

    # Linux override: auto-detect platform via uname.
    if [[ "$(uname -s)" == "Linux" ]] && [[ -f "${PROJECT_ROOT}/docker-compose.linux.yml" ]]; then
        COMPOSE_CMD+=(-f "${PROJECT_ROOT}/docker-compose.linux.yml")
        # Export UID/GID for the linux override file. Bash already maintains
        # UID as a readonly special variable holding the current user's id, so
        # assigning to it aborts under `set -e` ("UID: readonly variable").
        # Reuse the existing values and only fall back to `id` when unset
        # (e.g. a shell that does not provide them); the result is identical
        # since UID/GID already equal `id -u`/`id -g`.
        : "${UID:=$(id -u)}"
        : "${GID:=$(id -g)}"
        export UID GID
    fi

    # Worktree override: driven by the resolved isolation mode. Selection used
    # to key off PROJECT_DIR_A directly; resolve_isolation_mode still infers
    # worktree from that variable when ISOLATION_MODE is unset, so Tier B
    # installations predating the key keep the same overlay while an explicit
    # mode now outranks the inference.
    local mode
    mode=$(require_supported_isolation_mode) || return 1
    if [[ "$mode" == "worktree" ]]; then
        # A missing overlay would silently leave every account on the shared
        # /project mount — the exact fall back this mode is chosen to avoid.
        if [[ ! -f "${PROJECT_ROOT}/docker-compose.worktree.yml" ]]; then
            echo "Error: ISOLATION_MODE=worktree but docker-compose.worktree.yml is missing." >&2
            echo "       Regenerate it with scripts/generate-compose.sh before starting containers." >&2
            return 1
        fi
        COMPOSE_CMD+=(-f "${PROJECT_ROOT}/docker-compose.worktree.yml")
    fi

    # COMPOSE_CMD_INITIALIZED is consumed by callers (scripts/claude-docker
    # ensure_compose_cmd) — it lets idempotent wrappers skip rebuilding the
    # array on subsequent invocations from the same shell. Not used inside
    # this lib, so silence shellcheck's local-only scan.
    # shellcheck disable=SC2034
    COMPOSE_CMD_INITIALIZED=1
}
