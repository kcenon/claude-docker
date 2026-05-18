#!/usr/bin/env bash
# runtime.sh — Shared agent-runtime helpers for bash callers.
#
# Runtime selection is opt-in via AGENT_RUNTIME=codex. The default remains
# Claude so existing generated compose files and wrapper commands keep their
# historical behavior.

if [[ -n "${_CLAUDE_DOCKER_RUNTIME_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_RUNTIME_SH_SOURCED=1

agent_runtime() {
    local runtime="${AGENT_RUNTIME:-}"
    if [[ -z "$runtime" && -n "${PROJECT_ROOT:-}" ]]; then
        runtime=$(parse_env_value "${PROJECT_ROOT}/.env" "AGENT_RUNTIME")
    fi
    runtime="${runtime:-claude}"
    runtime="${runtime,,}"
    case "$runtime" in
        claude|codex) printf '%s' "$runtime" ;;
        *)
            echo "Error: AGENT_RUNTIME must be 'claude' or 'codex' (got: $runtime)" >&2
            return 1
            ;;
    esac
}

agent_service_prefix() {
    agent_runtime
}

agent_state_root() {
    case "$(agent_runtime)" in
        codex) printf '%s/.codex-state' "$HOME" ;;
        *)     printf '%s/.claude-state' "$HOME" ;;
    esac
}

agent_binary() {
    agent_runtime
}

agent_skip_permissions_flag() {
    case "$(agent_runtime)" in
        codex) printf '%s' "--dangerously-bypass-approvals-and-sandbox" ;;
        *)     printf '%s' "--dangerously-skip-permissions" ;;
    esac
}
