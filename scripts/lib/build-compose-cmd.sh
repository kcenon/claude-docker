#!/usr/bin/env bash
# build-compose-cmd.sh — Shared compose-overlay logic for bash callers.
#
# Source this file, then call `build_compose_cmd`. The function populates
# the global COMPOSE_CMD array with `docker compose -f ...` based on:
#   1. Always: docker-compose.yml
#   2. Linux + docker-compose.linux.yml exists: add linux overlay,
#      export UID/GID
#   3. .env declares PROJECT_DIR_A AND docker-compose.worktree.yml exists:
#      add worktree overlay
#
# Inputs: PROJECT_ROOT must be set in the caller's environment.
# Output: COMPOSE_CMD array (caller can invoke as "${COMPOSE_CMD[@]}" up -d)
#
# Requires: scripts/lib/parse_env.sh sourced before this file.

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
#   3. docker-compose.worktree.yml is added when .env declares PROJECT_DIR_A
#      and the worktree compose file exists.
build_compose_cmd() {
    COMPOSE_CMD=(docker compose -f "${PROJECT_ROOT}/docker-compose.yml")

    # Linux override: auto-detect platform via uname.
    if [[ "$(uname -s)" == "Linux" ]] && [[ -f "${PROJECT_ROOT}/docker-compose.linux.yml" ]]; then
        COMPOSE_CMD+=(-f "${PROJECT_ROOT}/docker-compose.linux.yml")
        # Export UID/GID for the linux override file.
        export UID GID
        UID=$(id -u)
        GID=$(id -g)
    fi

    # Worktree override: drive selection from .env state, not caller-local vars.
    if [[ -f "${PROJECT_ROOT}/.env" ]]; then
        local pdir_a
        pdir_a=$(parse_env_value "${PROJECT_ROOT}/.env" "PROJECT_DIR_A")
        if [[ -n "$pdir_a" ]] && [[ -f "${PROJECT_ROOT}/docker-compose.worktree.yml" ]]; then
            COMPOSE_CMD+=(-f "${PROJECT_ROOT}/docker-compose.worktree.yml")
        fi
    fi

    COMPOSE_CMD_INITIALIZED=1
}
