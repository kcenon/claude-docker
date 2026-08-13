#!/usr/bin/env bash
# isolation.sh — Shared ISOLATION_MODE contract for bash callers.
#
# Library file meant to be `source`d, but the shebang serves as an
# unambiguous shell directive for tooling (shellcheck SC2148).
#
# ISOLATION_MODE names the workspace trust boundary a set of accounts runs
# under. Before it existed, the boundary was inferred from the presence of an
# unrelated variable (PROJECT_DIR_A) and from which compose file a caller
# happened to pass, so a user could not state an intent and could not be told
# when it was not honored. This file is the single place every bash consumer
# resolves and validates that intent.
#
#   shared    Every account bind-mounts the same PROJECT_DIR read-write.
#             Appropriate only when all accounts are mutually trusted.
#   worktree  Each account sees only its own git worktree. Common git
#             metadata is still shared, so this is a concurrency tier and
#             NOT an adversarial sandbox.
#   isolated  Account-exclusive workspace, runtime state, configuration and
#             network. Accepted by this contract but NOT IMPLEMENTED yet;
#             see docs/ISOLATION.md.
#
# Public functions:
#   isolation_mode_is_known MODE      # 0 when MODE is one of the three names
#   isolation_mode_summary MODE       # one-line trust-boundary description
#   resolve_isolation_mode            # environment -> .env -> inference -> shared
#   require_supported_isolation_mode  # resolve, then reject unimplemented modes
#   warn_unused_worktree_paths MODE   # flag PROJECT_DIR_A that MODE ignores
#
# Requires: scripts/lib/parse_env.sh sourced before this file.

# Guard against double-sourcing.
if [[ -n "${_CLAUDE_DOCKER_ISOLATION_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_ISOLATION_SH_SOURCED=1

# Backward-compatible default for installations that never set the key.
ISOLATION_MODE_DEFAULT="shared"

# isolation_mode_is_known MODE
# Return 0 when MODE is one of the three contract names. Knowing a name is
# separate from being able to run it: `isolated` is known here and rejected by
# require_supported_isolation_mode, so documentation and status output can
# describe a mode this build cannot start.
isolation_mode_is_known() {
    case "${1:-}" in
        shared|worktree|isolated) return 0 ;;
        *) return 1 ;;
    esac
}

# isolation_mode_summary MODE
# Print a one-line description of the trust boundary MODE provides. Used by
# `config` and by startup output so the active boundary is stated rather than
# inferred from a compose file name.
isolation_mode_summary() {
    case "${1:-}" in
        shared)
            printf '%s' "all accounts share one read-write project mount; appropriate only for mutually trusted accounts"
            ;;
        worktree)
            printf '%s' "each account mounts only its own worktree; git metadata stays shared, so this is a concurrency tier, not a security boundary"
            ;;
        isolated)
            printf '%s' "account-exclusive workspace, state, configuration and network (not implemented yet)"
            ;;
        *)
            return 1
            ;;
    esac
}

# _isolation_worktree_root_a
# Print PROJECT_DIR_A using the environment-then-.env order every other key
# follows. Internal: both the legacy inference and the unused-path warning need
# it, and the compose generators reach this file after load_env_file has
# exported .env into the environment rather than leaving it only on disk.
_isolation_worktree_root_a() {
    if [[ -n "${PROJECT_DIR_A:-}" ]]; then
        printf '%s' "$PROJECT_DIR_A"
        return 0
    fi
    [[ -n "${PROJECT_ROOT:-}" ]] || return 0
    parse_env_value "${PROJECT_ROOT}/.env" "PROJECT_DIR_A"
}

# resolve_isolation_mode
# Print the configured mode. Resolution order:
#   1. ISOLATION_MODE already in the caller's environment.
#   2. ISOLATION_MODE in .env.
#   3. Legacy inference: a configured PROJECT_DIR_A resolves to worktree.
#      Installations predating this key configured Tier B exactly that way, and
#      build_compose_cmd keyed the worktree overlay off the same variable, so
#      inferring here is what keeps their behavior unchanged.
#   4. ISOLATION_MODE_DEFAULT.
#
# An unrecognized value fails instead of degrading to shared: silently running
# a weaker boundary than the one that was asked for is the failure this
# contract exists to prevent.
resolve_isolation_mode() {
    local mode="${ISOLATION_MODE:-}"

    if [[ -z "$mode" && -n "${PROJECT_ROOT:-}" ]]; then
        mode=$(parse_env_value "${PROJECT_ROOT}/.env" "ISOLATION_MODE")
    fi

    if [[ -z "$mode" && -n "$(_isolation_worktree_root_a)" ]]; then
        mode="worktree"
    fi

    mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    mode="${mode:-$ISOLATION_MODE_DEFAULT}"

    if ! isolation_mode_is_known "$mode"; then
        echo "Error: ISOLATION_MODE must be shared, worktree or isolated (got: $mode)" >&2
        return 1
    fi

    printf '%s' "$mode"
}

# require_supported_isolation_mode
# resolve_isolation_mode, then refuse the modes this build cannot start.
# Callers that create files or containers use this; callers that only display
# configuration use resolve_isolation_mode.
require_supported_isolation_mode() {
    local mode
    mode=$(resolve_isolation_mode) || return 1

    if [[ "$mode" == "isolated" ]]; then
        echo "Error: ISOLATION_MODE=isolated is a valid setting, but the isolated stack is not implemented yet." >&2
        echo "       Falling back to a shared workspace would hand an account the very access the mode asks to deny," >&2
        echo "       so this fails instead. Use shared or worktree; see docs/ISOLATION.md for the delivery order." >&2
        return 1
    fi

    printf '%s' "$mode"
}

# warn_unused_worktree_paths MODE
# Warn when PROJECT_DIR_A is configured but MODE does not consume it. Reaching
# this means an explicit ISOLATION_MODE outranked the legacy inference, so the
# per-account paths are inert and the account is on the shared mount. Always
# returns 0 — this reports a surprise, it does not decide anything.
warn_unused_worktree_paths() {
    local mode="${1:-}"
    [[ "$mode" == "worktree" ]] && return 0

    if [[ -n "$(_isolation_worktree_root_a)" ]]; then
        echo "Warning: PROJECT_DIR_A is configured, but ISOLATION_MODE=$mode ignores per-account worktree paths." >&2
        echo "         Every account uses PROJECT_DIR. Set ISOLATION_MODE=worktree to mount the worktrees." >&2
    fi
    return 0
}
