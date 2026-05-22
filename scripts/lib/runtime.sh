#!/usr/bin/env bash
# runtime.sh — Shared agent-runtime helpers for bash callers.
#
# Runtime selection is opt-in via AGENT_RUNTIME=codex. The default remains
# Claude so existing generated compose files and wrapper commands keep their
# historical behavior.
#
# Runtime-specific values are resolved from the JSON registry at
# tui/internal/config/runtimes.json — the cross-language single source of
# truth (see #267). The registry lives under tui/ so Go's go:embed can reach
# it; this file finds it relative to PROJECT_ROOT. Reads use `jq` when it is
# available (guaranteed inside the container image) and an `awk` state-machine
# fallback otherwise (the host is not guaranteed to have `jq`).

if [[ -n "${_CLAUDE_DOCKER_RUNTIME_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_RUNTIME_SH_SOURCED=1

# _runtime_registry_path
# Print the path to runtimes.json. Resolves relative to PROJECT_ROOT when set,
# otherwise relative to this library file's own location.
_runtime_registry_path() {
    if [[ -n "${PROJECT_ROOT:-}" ]]; then
        printf '%s/tui/internal/config/runtimes.json' "$PROJECT_ROOT"
        return 0
    fi
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s/../../tui/internal/config/runtimes.json' "$self_dir"
}

# _runtime_field_awk FILE RUNTIME FIELD
# awk fallback reader for the flat per-runtime registry schema. Walks the
# JSON line by line, tracking which runtime object is currently open, and
# prints the value of FIELD inside RUNTIME's object. The registry schema is
# intentionally flat (one depth per runtime) so this reader stays simple.
# Prints nothing if the (runtime, field) pair is absent.
_runtime_field_awk() {
    local file="$1" runtime="$2" field="$3"
    [[ -r "$file" ]] || return 0
    awk -v runtime="$runtime" -v field="$field" '
        BEGIN { in_runtimes = 0; cur = "" }
        # Track entry into the top-level "runtimes" object.
        /"runtimes"[[:space:]]*:[[:space:]]*\{/ { in_runtimes = 1; next }
        in_runtimes == 0 { next }
        {
            line = $0
            # A runtime object opens with  "<name>": {
            if (cur == "" && match(line, /"[^"]+"[[:space:]]*:[[:space:]]*\{/)) {
                name = line
                sub(/^[[:space:]]*"/, "", name)
                sub(/"[[:space:]]*:.*$/, "", name)
                if (name == runtime) { cur = name }
                next
            }
            if (cur != "") {
                # A closing brace ends the current runtime object.
                if (match(line, /^[[:space:]]*\}/)) { cur = ""; next }
                # Match  "field": <value>
                pat = "\"" field "\"[[:space:]]*:[[:space:]]*"
                if (match(line, pat)) {
                    val = substr(line, RSTART + RLENGTH)
                    # Drop a trailing comma.
                    sub(/,[[:space:]]*$/, "", val)
                    sub(/[[:space:]]+$/, "", val)
                    # Unquote string values; leave booleans/numbers as-is.
                    if (match(val, /^".*"$/)) {
                        val = substr(val, 2, length(val) - 2)
                        # Unescape the JSON escapes the registry actually uses.
                        gsub(/\\"/, "\"", val)
                        gsub(/\\\\/, "\\", val)
                    }
                    print val
                    exit 0
                }
            }
        }
    ' "$file"
}

# runtime_field RUNTIME FIELD
# Print the value of FIELD for RUNTIME from the registry. Uses `jq` when
# available, the awk fallback otherwise. Prints nothing if absent. Exit
# status is always 0 so callers can capture via command substitution.
#
# An absent key is distinguished from a present boolean `false` explicitly:
# `// empty` would treat `false` as missing, so the awk fallback (which
# prints `false`) and the jq path would disagree. The `if` form keeps both
# readers byte-identical for every field, including booleans.
runtime_field() {
    local runtime="$1" field="$2"
    local file
    file="$(_runtime_registry_path)"
    [[ -r "$file" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg r "$runtime" --arg f "$field" \
            'if (.runtimes[$r][$f]) == null then empty else .runtimes[$r][$f] end' \
            "$file" 2>/dev/null
        return 0
    fi
    _runtime_field_awk "$file" "$runtime" "$field"
}

# runtime_list
# Print one registered runtime name per line. Uses `jq` when available,
# the awk fallback otherwise.
runtime_list() {
    local file
    file="$(_runtime_registry_path)"
    [[ -r "$file" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '.runtimes | keys[]' "$file" 2>/dev/null
        return 0
    fi
    awk '
        BEGIN { in_runtimes = 0; cur = "" }
        /"runtimes"[[:space:]]*:[[:space:]]*\{/ { in_runtimes = 1; next }
        in_runtimes == 0 { next }
        {
            if (cur == "" && match($0, /"[^"]+"[[:space:]]*:[[:space:]]*\{/)) {
                name = $0
                sub(/^[[:space:]]*"/, "", name)
                sub(/"[[:space:]]*:.*$/, "", name)
                print name
                cur = name
                next
            }
            if (cur != "" && match($0, /^[[:space:]]*\}/)) { cur = "" }
        }
    ' "$file"
}

agent_runtime() {
    local runtime="${AGENT_RUNTIME:-}"
    if [[ -z "$runtime" && -n "${PROJECT_ROOT:-}" ]]; then
        runtime=$(parse_env_value "${PROJECT_ROOT}/.env" "AGENT_RUNTIME")
    fi
    runtime="${runtime:-claude}"
    runtime="${runtime,,}"
    # Validate against the registry rather than a hardcoded allowlist.
    local known
    while IFS= read -r known; do
        if [[ "$known" == "$runtime" ]]; then
            printf '%s' "$runtime"
            return 0
        fi
    done < <(runtime_list)
    echo "Error: AGENT_RUNTIME is not a known runtime (got: $runtime)" >&2
    return 1
}

agent_service_prefix() {
    local runtime
    runtime="$(agent_runtime)" || return 1
    runtime_field "$runtime" "servicePrefix"
}

agent_state_root() {
    local runtime dir
    runtime="$(agent_runtime)" || return 1
    dir="$(runtime_field "$runtime" "stateDir")"
    printf '%s/%s' "$HOME" "$dir"
}

agent_binary() {
    local runtime
    runtime="$(agent_runtime)" || return 1
    runtime_field "$runtime" "binary"
}

agent_skip_permissions_flag() {
    local runtime
    runtime="$(agent_runtime)" || return 1
    runtime_field "$runtime" "skipPermissionsFlag"
}
