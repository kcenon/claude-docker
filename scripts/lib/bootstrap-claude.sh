#!/usr/bin/env bash
# bootstrap-claude.sh — Claude-runtime bootstrap module.
#
# Library file meant to be `source`d by scripts/entrypoint.sh. The shebang
# doubles as a shellcheck shell directive (SC2148). Exposes a single entry
# point, runtime_bootstrap, which the dispatcher calls after sourcing this
# file via the registry's bootstrapModule field (issue #269).
#
# This is the former claude block of entrypoint.sh, relocated verbatim. The
# settings.json jq transform behavior is preserved exactly; the duplicated
# copy/symlink logic now calls the bootstrap-common.sh helpers.
#
# Depends on: scripts/lib/bootstrap-common.sh (sourced by entrypoint.sh).

if [[ -n "${_CLAUDE_DOCKER_BOOTSTRAP_CLAUDE_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_BOOTSTRAP_CLAUDE_SH_SOURCED=1

# --- Settings transformation ---------------------------------------------------
# Generate a container-local settings.json from the host settings.
# The host settings may be macOS (.sh hooks) or Windows (.ps1/pwsh hooks).
# The container always runs Linux, so we:
#   1. Disable sandbox (container itself is the isolation boundary)
#   2. Strip glob-based permission deny rules (sensitive-file-guard.sh handles this)
#   3. Rewrite PowerShell hook commands to bash equivalents
#   4. Fix statusLine command if it uses PowerShell
#
# The jq pipeline is idempotent: macOS settings pass through with only
# sandbox/permissions changes; Windows settings get full hook rewriting.
#
# See the "Container-side settings transformation" section in README.md
# for user-facing documentation of two behaviors baked in here:
#   - step 1 (`sandbox.enabled = false`) assumes default Docker isolation
#     and is unsafe under --privileged / docker-in-docker / docker-on-sock.
#   - step 4's pwsh-to-bash rewrite is best-effort and has known silent
#     failure modes (heredocs, $env:VAR, quoted paths with spaces).
generate_container_settings() {
    local src="$1"
    local dst="$2"

    jq '
        # 1. Disable sandbox (container IS the isolation boundary)
        .sandbox.enabled = false

        # 2. Strip glob-based permission deny rules
        #    (sensitive-file-guard.sh hook provides equivalent protection)
        | if .permissions.deny then
            .permissions.deny = [.permissions.deny[] | select(test("[*]") | not)]
          else . end

        # 3. Fix statusLine BEFORE walk() to prevent Join-Path pattern mangling
        | if .statusLine.command? and (.statusLine.command | test("pwsh")) then
            .statusLine.command = "~/.claude/scripts/statusline-command.sh"
          else . end

        # 4. Rewrite PowerShell hook commands to bash equivalents
        | walk(
            if type == "object" and .command? and (.command | type == "string") and (.command | test("pwsh"))
            then .command = (.command
                | gsub("pwsh(\\.exe)?\\s+-NoProfile\\s+(-ExecutionPolicy\\s+\\S+\\s+)?-File\\s+"; "")
                | gsub("pwsh(\\.exe)?\\s+-NoProfile\\s+(-ExecutionPolicy\\s+\\S+\\s+)?-Command\\s+\"?"; "")
                | gsub("\"$"; "")
                | gsub("& "; "")
                | gsub("; "; " && ")
                | gsub("\\.ps1"; ".sh")
            )
            else . end
        )
    ' "$src" > "${dst}.tmp" && mv "${dst}.tmp" "$dst"
}

# runtime_bootstrap
# Claude-runtime entry point. Prepares the per-account Claude state directory:
# symlinks/copies host config into it and generates a container-optimized
# settings.json. CONFIG_SOURCE and ACCOUNT_DIR are resolved here from the
# Claude-specific environment variables.
runtime_bootstrap() {
    # Claude config source: CLAUDE_CONFIG_SOURCE overrides the default host
    # config path. Set CLAUDE_CONFIG_SOURCE to a path inside the project (e.g.,
    # /project/claude-config/global) so config changes are reflected immediately
    # without running bootstrap on the host.
    local CONFIG_SOURCE="${CLAUDE_CONFIG_SOURCE:-/home/node/.claude-host}"
    local ACCOUNT_DIR="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"

    if [ ! -d "$CONFIG_SOURCE" ]; then
        return 0
    fi

    # Fix Windows CRLF line endings in shell scripts (bind mounts from Windows
    # hosts may have \r\n even with .gitattributes if the repo lacks one).
    if [ -n "$CLAUDE_CONFIG_SOURCE" ]; then
        bootstrap_crlf_normalize "$CONFIG_SOURCE"
    fi

    # When CLAUDE_CONFIG_SOURCE is explicitly set, force-relink everything
    # so config changes are picked up on container restart.
    local FORCE_LINK="${CLAUDE_CONFIG_SOURCE:+true}"
    local item target

    # --- Executable dirs: copy with CRLF normalization -------------------------
    # hooks/ and scripts/ contain shell scripts that may have Windows CRLF line
    # endings from a Windows host. The default host mount is read-only, so we
    # cannot sed -i in place. Instead, copy .sh files to the writable account
    # dir, stripping CRLF during the copy. Non-.sh files (json, psm1) are
    # copied as-is for completeness (hooks/lib/, hooks/known-issues.json).
    for item in hooks scripts; do
        if [ -d "$CONFIG_SOURCE/$item" ]; then
            target="$ACCOUNT_DIR/$item"
            if [ "$FORCE_LINK" = "true" ] || [ ! -e "$target" ] || [ ! -L "$target" ]; then
                if [ -z "$CLAUDE_CONFIG_SOURCE" ]; then
                    # Read-only mount: copy + CRLF normalize
                    bootstrap_copy_dir "$CONFIG_SOURCE/$item" "$target"
                    echo "[entrypoint] $item: copied and CRLF-normalized from read-only mount"
                else
                    # Writable CLAUDE_CONFIG_SOURCE: symlink as before
                    bootstrap_link_item "$CONFIG_SOURCE/$item" "$target" "$FORCE_LINK"
                fi
            fi
        fi
    done

    # --- Non-executable dirs: symlink (no CRLF concern) ----------------------
    for item in skills commands ccstatusline; do
        if [ -d "$CONFIG_SOURCE/$item" ]; then
            target="$ACCOUNT_DIR/$item"
            bootstrap_link_item "$CONFIG_SOURCE/$item" "$target" "$FORCE_LINK"
        fi
    done

    # settings.json: generate a container-optimized copy.
    #
    # The host settings.json may be macOS (bash hooks, Seatbelt sandbox) or
    # Windows (PowerShell hooks, no Linux sandbox). The container always runs
    # Linux, so we apply a comprehensive transformation:
    #   - Disable sandbox (container itself is the isolation boundary)
    #   - Strip glob-based permission deny rules (hook provides protection)
    #   - Rewrite PowerShell hook commands to bash equivalents
    #   - Fix statusLine command if it uses PowerShell
    #
    # The host file is never modified (read-only mount). The generated
    # settings.container.json is symlinked as settings.json in the writable
    # account state directory.
    if [ -f "$CONFIG_SOURCE/settings.json" ]; then
        local CONTAINER_SETTINGS="$ACCOUNT_DIR/settings.container.json"
        if command -v jq >/dev/null 2>&1; then
            if generate_container_settings "$CONFIG_SOURCE/settings.json" "$CONTAINER_SETTINGS"; then
                # Validate the generated JSON
                if jq empty "$CONTAINER_SETTINGS" 2>/dev/null; then
                    ln -sf "$CONTAINER_SETTINGS" "$ACCOUNT_DIR/settings.json"
                    # Log transformation summary
                    local pwsh_count
                    pwsh_count=$(jq -r '[.. | objects | .command? // empty | select(test("pwsh"))] | length' "$CONFIG_SOURCE/settings.json" 2>/dev/null || echo 0)
                    if [ "$pwsh_count" -gt 0 ]; then
                        echo "[entrypoint] settings.json: rewrote $pwsh_count PowerShell hook(s) to bash"
                    fi
                    echo "[entrypoint] settings.json: container-optimized (sandbox=off, glob deny rules stripped)"

                    # Post-transform syntax check: `bash -n -c` every .command
                    # string in the generated file. The rewriter in
                    # generate_container_settings() is best-effort (see
                    # README "Container-side settings transformation"); the
                    # check catches silent failures so the user learns about
                    # them at container start rather than when a hook misfires.
                    local syntax_failures=0
                    local _cmd
                    while IFS= read -r _cmd; do
                        [ -z "$_cmd" ] && continue
                        if ! bash -n -c "$_cmd" 2>/dev/null; then
                            echo "[entrypoint] WARNING: transformed hook command failed bash syntax check: $_cmd" >&2
                            syntax_failures=$((syntax_failures + 1))
                        fi
                    done < <(jq -r '.. | objects | .command? // empty | select(type == "string")' "$CONTAINER_SETTINGS" 2>/dev/null)
                    if [ "$syntax_failures" -gt 0 ]; then
                        echo "[entrypoint] WARNING: $syntax_failures hook command(s) failed syntax check — those hooks will not fire. Set CLAUDE_CONFIG_SOURCE to a Linux-native config tree to bypass the pwsh rewriter." >&2
                    fi
                else
                    echo "[entrypoint] ERROR: generated settings.container.json is invalid JSON, using raw host settings"
                    ln -sf "$CONFIG_SOURCE/settings.json" "$ACCOUNT_DIR/settings.json"
                fi
            else
                echo "[entrypoint] ERROR: settings transformation failed, using raw host settings"
                ln -sf "$CONFIG_SOURCE/settings.json" "$ACCOUNT_DIR/settings.json"
            fi
        else
            # Fallback: raw symlink (jq is always present in our image, this
            # branch only runs on accidentally stripped-down base images).
            echo "[entrypoint] WARNING: jq not found, using raw host settings (warnings expected)"
            ln -sf "$CONFIG_SOURCE/settings.json" "$ACCOUNT_DIR/settings.json"
        fi
    fi

    # Ensure logs directory exists (hooks write to ~/.claude/logs/)
    mkdir -p "$ACCOUNT_DIR/logs" 2>/dev/null

    # Ensure session-env exists so the Claude Code harness can write per-turn
    # environment snapshots on the first session. The harness creates
    # subdirectories under session-env/ each turn; if the parent directory is
    # missing or not writable, every Bash tool call fails before the hook
    # chain even runs. Pre-creating it with 700 (owner rwx) matches the
    # harness's own default and is a no-op when the directory already exists.
    mkdir -p "$ACCOUNT_DIR/session-env" 2>/dev/null
    chmod 700 "$ACCOUNT_DIR/session-env" 2>/dev/null || true

    # Warn about hook scripts referenced in settings but missing on disk
    if [ -f "$ACCOUNT_DIR/settings.json" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.. | objects | .command? // empty' "$ACCOUNT_DIR/settings.json" 2>/dev/null \
            | grep -oE '(~|/)[^ ]+\.sh' | sort -u | while IFS= read -r script; do
            resolved="${script/#\~/$HOME}"
            if [ ! -f "$resolved" ]; then
                echo "[entrypoint] WARNING: hook references missing script: $script"
            fi
        done
    fi

    # Symlink other shared config files.
    #
    # `.full-suite-active` is the probe file written by claude-config's
    # full-install path (issue #423 contract). Plugin and global hooks read
    # it from $HOME/.claude/.full-suite-active to gate on whether the host
    # ran the full installer or only the lite/plugin install. Without
    # forwarding, container-side hooks would treat every host as lite.
    # See claude-config docs/CLAUDE_DOCKER_CONTRACT.md for the contract.
    for item in CLAUDE.md commit-settings.md .claudeignore .full-suite-active; do
        if [ -f "$CONFIG_SOURCE/$item" ]; then
            if [ "$FORCE_LINK" = "true" ] || [ ! -e "$ACCOUNT_DIR/$item" ] || [ ! -s "$ACCOUNT_DIR/$item" ]; then
                ln -sf "$CONFIG_SOURCE/$item" "$ACCOUNT_DIR/$item"
            fi
        fi
    done

    # Symlink ccstatusline config to XDG path (~/.config/ccstatusline/).
    #
    # ccstatusline resolves its settings path from os.homedir() + ".config/
    # ccstatusline/settings.json"; it does not honor XDG_CONFIG_HOME or any
    # override env. If the file is absent it attempts to *write* a default
    # there — when that write fails (EACCES), ccstatusline silently falls
    # back to a hardcoded single-line layout and the user's multi-line
    # config in $CONFIG_SOURCE/ccstatusline/ is never applied.
    #
    # Two things must hold for this block to succeed:
    #   1. $XDG_CCSL must be writable by the current UID. Dockerfile handles
    #      this with `chmod -R a+rwX /home/node/.config` — if you see the
    #      "could not create XDG symlink" warning below, that chmod was lost
    #      (e.g. stale base image) or overridden by a volume mount.
    #   2. A source settings.json must exist. $ACCOUNT_DIR points to the
    #      bind-mounted account state; $CONFIG_SOURCE points to the read-only
    #      host config mount (or CLAUDE_CONFIG_SOURCE override).
    local XDG_CCSL="/home/node/.config/ccstatusline"
    mkdir -p "$XDG_CCSL" 2>/dev/null || true
    if [ -d "$XDG_CCSL" ]; then
        # Pick the source, preferring account state (host-synced via earlier
        # symlink) over raw config source.
        local ccsl_src=""
        if [ -f "$ACCOUNT_DIR/ccstatusline/settings.json" ]; then
            ccsl_src="$ACCOUNT_DIR/ccstatusline/settings.json"
        elif [ -f "$CONFIG_SOURCE/ccstatusline/settings.json" ]; then
            ccsl_src="$CONFIG_SOURCE/ccstatusline/settings.json"
        fi

        if [ -n "$ccsl_src" ]; then
            # Replace any stale symlink or pre-existing file so a new
            # ACCOUNT_DIR / CONFIG_SOURCE binding is picked up on restart.
            # `ln -sf` without this would leave a broken symlink dangling
            # when the previous target has moved.
            local current_target=""
            if [ -L "$XDG_CCSL/settings.json" ]; then
                current_target=$(readlink "$XDG_CCSL/settings.json" 2>/dev/null || true)
            fi
            if [ "$current_target" != "$ccsl_src" ]; then
                rm -f "$XDG_CCSL/settings.json" 2>/dev/null || true
                if ln -s "$ccsl_src" "$XDG_CCSL/settings.json" 2>/dev/null; then
                    echo "[entrypoint] ccstatusline: linked XDG settings.json -> $ccsl_src"
                else
                    # Most common cause: $XDG_CCSL owned by a different UID
                    # (Dockerfile chown'd to node:node but container runs
                    # as host UID). Warn loudly so the user sees the single-
                    # line fallback is a config plumbing issue, not a
                    # ccstatusline bug.
                    local xdg_owner
                    xdg_owner=$(stat -c '%u:%g' "$XDG_CCSL" 2>/dev/null || echo "?")
                    echo "[entrypoint] WARNING: could not create XDG symlink at $XDG_CCSL/settings.json" >&2
                    echo "[entrypoint]   $XDG_CCSL owned by $xdg_owner, running as $(id -u):$(id -g)" >&2
                    echo "[entrypoint]   ccstatusline will show its hardcoded default layout" >&2
                    echo "[entrypoint]   Fix: rebuild base image so Dockerfile's chmod -R a+rwX takes effect" >&2
                fi
            fi
        fi
    fi
}
