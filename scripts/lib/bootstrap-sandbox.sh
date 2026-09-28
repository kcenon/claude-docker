#!/usr/bin/env bash
# Requested inner sandboxing is a separate gate from hook transformation.
# No dependency check here changes the outer Docker security profile.
runtime_writable_check() {
    [[ "${ISOLATION_MODE:-shared}" == isolated ]] || return 0
    local path probe state
    state="$(runtime_field "$AGENT_RUNTIME" containerConfigMount)" || return 1
    for path in "$PWD" "$PWD/node_modules" "$state" /tmp /home/node/.config /home/node/.cache /home/node/.npm /home/node/.agents; do
        if ! probe="$(mktemp "$path/.claude-docker-write.XXXXXX" 2>/dev/null)"; then
            echo "[entrypoint] ERROR: required account path is not writable: $path. Check bind ownership or initialize a fresh dependency volume with claude-docker up." >&2
            return 1
        fi
        rm -f "$probe" || return 1
    done
}

runtime_sandbox_check() {
    [[ "${ISOLATION_MODE:-shared}" == isolated ]] || return 0
    [[ "${AGENT_RUNTIME:-claude}" == claude ]] || return 0
    local account="${CLAUDE_CONFIG_DIR:-/home/node/.claude}" file requested=false
    local settings=("$account/settings.json" "$PWD/.claude/settings.json" "$PWD/.claude/settings.local.json" /etc/claude-code/managed-settings.json)
    for file in /etc/claude-code/managed-settings.d/*.json; do
        [[ -f "$file" ]] && settings+=("$file")
    done
    for file in "${settings[@]}"; do
        [[ -f "$file" ]] || continue
        if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
            echo '[entrypoint] ERROR: isolated sandbox policy cannot be read; repair the account/project settings JSON.' >&2
            return 1
        fi
        if jq -e '.sandbox.enabled == true' "$file" >/dev/null 2>&1; then requested=true; fi
    done
    [[ "$requested" == true ]] || return 0
    for file in "${settings[@]}"; do
        [[ -f "$file" ]] || continue
        if jq -e '.sandbox.enableWeakerNestedSandbox == true or .sandbox.enableWeakerNetworkIsolation == true or .sandbox.filesystem.disabled == true or .sandbox.enabled == false or .sandbox.failIfUnavailable == false or .sandbox.allowUnsandboxedCommands == true' "$file" >/dev/null 2>&1; then
            echo '[entrypoint] ERROR: requested isolated sandbox conflicts with a weaker/disabled sandbox setting; remove the conflict.' >&2
            return 1
        fi
    done
    local dependency version major minor patch
    for dependency in bwrap socat timeout claude; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            echo "[entrypoint] ERROR: requested sandbox needs $dependency; rebuild the image with sandbox dependencies." >&2
            return 1
        fi
    done
    if ! timeout 5 socat -u STDIN STDOUT </dev/null >/dev/null 2>&1; then
        echo '[entrypoint] ERROR: requested sandbox cannot execute socat; rebuild the image dependencies.' >&2
        return 1
    fi
    if ! version="$(timeout 10 claude --version 2>/dev/null)"; then
        echo '[entrypoint] ERROR: cannot execute Claude to verify sandbox support; rebuild or repair the installed runtime.' >&2
        return 1
    fi
    # failIfUnavailable was introduced in 2.1.83, per the upstream changelog:
    # https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#2183
    if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        echo '[entrypoint] ERROR: cannot verify Claude sandbox version; install Claude >=2.1.83.' >&2
        return 1
    fi
    major=$((10#${BASH_REMATCH[1]})); minor=$((10#${BASH_REMATCH[2]})); patch=$((10#${BASH_REMATCH[3]}))
    if (( major < 2 || (major == 2 && minor < 1) || (major == 2 && minor == 1 && patch < 83) )); then
        echo '[entrypoint] ERROR: requested sandbox needs Claude >=2.1.83 (sandbox.failIfUnavailable).' >&2
        return 1
    fi
    # Exercise namespace creation, a read-only root, fresh proc and an actual
    # child under this container's UID/capabilities/seccomp/AppArmor policy.
    # No weaker nested-proc fallback: unsupported hosts must refuse startup.
    if ! timeout 10 bwrap --die-with-parent --unshare-user --unshare-pid --unshare-net \
        --ro-bind / / --proc /proc --dev /dev /bin/true >/dev/null 2>&1; then
        echo '[entrypoint] ERROR: requested sandbox cannot execute under the current kernel/container policy. This combination is unsupported; retain the outer restrictions and use a supported host/runtime.' >&2
        return 1
    fi
    # CLI scope/project settings cannot silently opt back out: conflicts above
    # are refused. Preserve every supplied policy entry and add only the two
    # hard-failure controls. The account directory is already private/writable.
    local temp
    temp="$(mktemp "$account/.sandbox-settings.XXXXXX")" || return 1
    if [[ -f "$account/settings.json" ]]; then file="$account/settings.json"; else file=/dev/null; fi
    if ! jq -s '(.[0] // {}) | .sandbox.enabled = true | .sandbox.failIfUnavailable = true | .sandbox.allowUnsandboxedCommands = false' "$file" > "$temp"; then
        rm -f "$temp"
        return 1
    fi
    chmod 600 "$temp"
    mv "$temp" "$account/settings.json" || return 1
    echo '[entrypoint] Requested sandbox: capability probe passed; runtime fallback disabled.'
}
