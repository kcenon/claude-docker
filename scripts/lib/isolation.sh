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
#   isolated  Each account gets an independent clone with its own git
#             metadata, its own runtime state and dependency cache, and no
#             shared host configuration. Clones come from
#             scripts/setup-isolated.sh; see docs/ISOLATION.md.
#
# ISOLATED_NETWORK_MODE names the network policy the isolated mode applies. It
# is a separate axis from ISOLATION_MODE because it constrains reachability
# rather than the workspace, and only the isolated mode reads it.
#
#   bridge    Each account is attached to its own ordinary bridge network.
#             Outbound agent/API/git access keeps working; sibling service
#             discovery and direct lateral connections do not.
#   none      Each account is detached from every network, for workloads that
#             need no external access. Egress allowlisting is a separate
#             proxy/firewall concern and is not what this provides.
#
# Public functions:
#   isolation_mode_is_known MODE       # 0 when MODE is one of the three names
#   isolation_mode_summary MODE        # one-line trust-boundary description
#   isolation_mode_account_var MODE N  # per-account path variable, if any
#   resolve_isolation_mode             # environment -> .env -> inference -> shared
#   require_supported_isolation_mode   # resolve, then check per-account inputs
#   warn_unused_workspace_paths MODE   # flag per-account paths MODE ignores
#   isolated_network_mode_is_known M   # 0 when M is bridge or none
#   isolated_network_mode_summary M    # one-line reachability description
#   resolve_isolated_network_mode      # environment -> .env -> bridge
#
# Requires: scripts/lib/parse_env.sh and scripts/lib/index.sh sourced before
# this file.

# Guard against double-sourcing.
if [[ -n "${_CLAUDE_DOCKER_ISOLATION_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_ISOLATION_SH_SOURCED=1

# Backward-compatible default for installations that never set the key.
ISOLATION_MODE_DEFAULT="shared"

# bridge, not none: an isolated agent still has to reach the model API and its
# git remote, so detaching by default would break every ordinary workload while
# looking like a stricter setting.
ISOLATED_NETWORK_MODE_DEFAULT="bridge"

# isolation_mode_is_known MODE
# Return 0 when MODE is one of the three contract names.
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
            printf '%s' "each account gets an independent clone with its own git metadata and state; no shared project mount and no shared host configuration"
            ;;
        *)
            return 1
            ;;
    esac
}

# isolation_mode_account_var MODE UPPER
# Print the name of the per-account workspace variable MODE reads for the
# account identified by UPPER (A, B, ... ZZ), or nothing when MODE needs none.
# One table so validation, warnings and the generators cannot disagree about
# which variable belongs to which mode.
isolation_mode_account_var() {
    case "${1:-}" in
        worktree) printf 'PROJECT_DIR_%s' "${2:-}" ;;
        isolated) printf 'ISOLATED_WORKSPACE_%s' "${2:-}" ;;
        *) return 0 ;;
    esac
}

# _isolation_setup_hint MODE
# Print the one-line "run this to create them" hint for MODE's workspaces.
_isolation_setup_hint() {
    case "${1:-}" in
        worktree)
            printf '%s' "Create the worktrees with scripts/setup-worktrees.sh, which prints the paths to add."
            ;;
        isolated)
            printf '%s' "Create the clones with scripts/setup-isolated.sh, which prints the paths to add."
            ;;
        *) return 0 ;;
    esac
}

# _isolation_lookup VAR
# Print VAR using the environment-then-.env order every other key follows.
# Internal, and the .env leg is load-bearing: the compose generators reach this
# file after load_env_file has exported .env into the environment, but
# scripts/claude-docker does not export it, so a value that exists only on disk
# must still be found.
_isolation_lookup() {
    local var="${1:-}"
    [[ -n "$var" ]] || return 0

    if [[ -n "${!var:-}" ]]; then
        printf '%s' "${!var}"
        return 0
    fi
    [[ -n "${PROJECT_ROOT:-}" ]] || return 0
    parse_env_value "${PROJECT_ROOT}/.env" "$var"
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
# There is deliberately no inference from ISOLATED_WORKSPACE_A: nothing predates
# that key, so an installation configuring it without declaring the mode has
# made a mistake worth reporting rather than a legacy layout worth honoring.
#
# An unrecognized value fails instead of degrading to shared: silently running
# a weaker boundary than the one that was asked for is the failure this
# contract exists to prevent.
resolve_isolation_mode() {
    local mode="${ISOLATION_MODE:-}"

    if [[ -z "$mode" && -n "${PROJECT_ROOT:-}" ]]; then
        mode=$(parse_env_value "${PROJECT_ROOT}/.env" "ISOLATION_MODE")
    fi

    if [[ -z "$mode" && -n "$(_isolation_lookup PROJECT_DIR_A)" ]]; then
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

# isolated_network_mode_is_known MODE
# Return 0 when MODE is one of the two network policy names.
isolated_network_mode_is_known() {
    case "${1:-}" in
        bridge|none) return 0 ;;
        *) return 1 ;;
    esac
}

# isolated_network_mode_summary MODE
# Print a one-line description of the reachability MODE provides, for the same
# reason isolation_mode_summary exists: the policy should be stated rather than
# read out of a generated compose file.
isolated_network_mode_summary() {
    case "${1:-}" in
        bridge)
            printf '%s' "each account is on its own bridge network; outbound access works, sibling discovery and direct connections do not"
            ;;
        none)
            printf '%s' "each account is detached from every network; no outbound agent, API or git access"
            ;;
        *)
            return 1
            ;;
    esac
}

# resolve_isolated_network_mode
# Print the configured network policy: environment, then .env, then the default.
#
# There is no inference leg and no per-account variant. Unlike ISOLATION_MODE
# this key predates nothing, so an unset value means "never configured" rather
# than "configured the old way".
#
# An unrecognized value fails rather than falling back to the default, matching
# resolve_isolation_mode: ISOLATED_NETWORK_MODE=non silently attaching every
# account to a network is the failure this contract exists to prevent, and it
# is worse here than a typo elsewhere because nothing downstream looks wrong.
resolve_isolated_network_mode() {
    local mode
    mode="$(_isolation_lookup ISOLATED_NETWORK_MODE)"
    mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    mode="${mode:-$ISOLATED_NETWORK_MODE_DEFAULT}"

    if ! isolated_network_mode_is_known "$mode"; then
        echo "Error: ISOLATED_NETWORK_MODE must be bridge or none (got: $mode)" >&2
        return 1
    fi

    printf '%s' "$mode"
}

# require_supported_isolation_mode [ACCOUNT_COUNT]
# resolve_isolation_mode, then verify the per-account workspace paths the
# resolved mode consumes are actually configured. Callers that create files or
# start containers use this; callers that only display configuration use
# resolve_isolation_mode.
#
# ACCOUNT_COUNT defaults to 1. Overlay selection only needs to know the mode is
# usable at all, and account A is the one every installation has; the compose
# generators pass NUM_ACCOUNTS so a path missing for account C is caught before
# the first output file is opened.
#
# A mode whose paths are unset would otherwise reach Compose as an empty bind
# source, which fails later and less legibly than it does here.
require_supported_isolation_mode() {
    local count="${1:-1}"
    local mode
    mode=$(resolve_isolation_mode) || return 1

    local i upper var
    for (( i = 1; i <= count; i++ )); do
        upper="$(index_to_upper "$i")"
        var="$(isolation_mode_account_var "$mode" "$upper")"
        # shared consumes no per-account path; nothing to check for any account.
        [[ -n "$var" ]] || break

        if [[ -z "$(_isolation_lookup "$var")" ]]; then
            echo "Error: $var is required when ISOLATION_MODE=$mode" >&2
            echo "       $(_isolation_setup_hint "$mode")" >&2
            return 1
        fi
    done

    printf '%s' "$mode"
}

# warn_unused_workspace_paths MODE
# Warn about per-account workspace paths that are configured but that MODE does
# not consume. Both families are checked, because both can be present at once:
# a user who tried isolated, went back to worktree, and left the clone paths in
# .env should be told the clones are now inert. Always returns 0 — this reports
# a surprise, it does not decide anything.
warn_unused_workspace_paths() {
    local mode="${1:-}"

    if [[ "$mode" != "worktree" && -n "$(_isolation_lookup PROJECT_DIR_A)" ]]; then
        echo "Warning: PROJECT_DIR_A is configured, but ISOLATION_MODE=$mode ignores per-account worktree paths." >&2
        if [[ "$mode" == "shared" ]]; then
            echo "         Every account uses PROJECT_DIR. Set ISOLATION_MODE=worktree to mount the worktrees." >&2
        else
            echo "         Set ISOLATION_MODE=worktree to mount the worktrees." >&2
        fi
    fi

    if [[ "$mode" != "isolated" && -n "$(_isolation_lookup ISOLATED_WORKSPACE_A)" ]]; then
        echo "Warning: ISOLATED_WORKSPACE_A is configured, but ISOLATION_MODE=$mode ignores per-account clone paths." >&2
        echo "         Set ISOLATION_MODE=isolated to mount the independent clones." >&2
    fi

    return 0
}
