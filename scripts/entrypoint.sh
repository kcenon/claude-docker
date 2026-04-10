#!/bin/bash
# Entrypoint: symlink host claude-config into the account state directory.
# Host config is mounted read-only at /home/node/.claude-host/
# Account state is at /home/node/.claude/ (writable)

# Config source: CLAUDE_CONFIG_SOURCE overrides the default host config path.
# Set CLAUDE_CONFIG_SOURCE to a path inside the project (e.g., /project/claude-config/global)
# so that config changes are reflected immediately without running bootstrap on the host.
CONFIG_SOURCE="${CLAUDE_CONFIG_SOURCE:-/home/node/.claude-host}"
ACCOUNT_DIR="/home/node/.claude"

if [ -d "$CONFIG_SOURCE" ]; then
    # Fix Windows CRLF line endings in shell scripts (bind mounts from Windows
    # hosts may have \r\n even with .gitattributes if the repo lacks one).
    if [ -n "$CLAUDE_CONFIG_SOURCE" ]; then
        find "$CONFIG_SOURCE" -name "*.sh" -exec sed -i 's/\r$//' {} + 2>/dev/null
    fi

    # When CLAUDE_CONFIG_SOURCE is explicitly set, force-relink everything
    # so config changes are picked up on container restart.
    FORCE_LINK="${CLAUDE_CONFIG_SOURCE:+true}"

    # Symlink shared config dirs.
    # Re-link when: forced, missing, or present as a stale physical copy
    # (not a symlink). A stale physical copy is backed up before relinking,
    # so no work is lost if the user customised it.
    for item in hooks skills commands scripts ccstatusline; do
        if [ -d "$CONFIG_SOURCE/$item" ]; then
            target="$ACCOUNT_DIR/$item"
            if [ "$FORCE_LINK" = "true" ] || [ ! -e "$target" ] || [ ! -L "$target" ]; then
                if [ -e "$target" ] && [ ! -L "$target" ]; then
                    backup="${target}.stale.$(date +%s)"
                    mv "$target" "$backup"
                    echo "[entrypoint] $item: backed up stale copy to $backup"
                fi
                ln -sfn "$CONFIG_SOURCE/$item" "$target"
            fi
        fi
    done

    # settings.json: generate a container-local copy with sandbox disabled.
    #
    # Why: the host settings.json sets sandbox.enabled=true with glob-based
    # deny rules (Read(**/.env), etc.). On Linux that triggers:
    #   - a "Sandbox disabled: bubblewrap/socat not installed" warning, and
    #   - a "Glob patterns in sandbox permission rules not supported" warning.
    # Neither issue exists inside the container: the container itself is the
    # isolation boundary, and the PreToolUse sensitive-file-guard.sh hook
    # applies the same glob-based protection at the application layer
    # independently of the OS sandbox.
    #
    # Strategy: jq-merge sandbox.enabled=false into a local copy and symlink
    # settings.json to that copy. The host file is never modified, so macOS
    # Seatbelt-based protection on the host remains intact.
    if [ -f "$CONFIG_SOURCE/settings.json" ]; then
        CONTAINER_SETTINGS="$ACCOUNT_DIR/settings.container.json"
        if command -v jq >/dev/null 2>&1; then
            jq '.sandbox.enabled = false' "$CONFIG_SOURCE/settings.json" \
                > "$CONTAINER_SETTINGS.tmp" \
                && mv "$CONTAINER_SETTINGS.tmp" "$CONTAINER_SETTINGS"
            ln -sf "$CONTAINER_SETTINGS" "$ACCOUNT_DIR/settings.json"
        else
            # Fallback: raw symlink (jq is always present in our image, this
            # branch only runs on accidentally stripped-down base images).
            ln -sf "$CONFIG_SOURCE/settings.json" "$ACCOUNT_DIR/settings.json"
        fi
    fi

    # Symlink other shared config files
    for item in CLAUDE.md commit-settings.md .claudeignore; do
        if [ -f "$CONFIG_SOURCE/$item" ]; then
            if [ "$FORCE_LINK" = "true" ] || [ ! -e "$ACCOUNT_DIR/$item" ] || [ ! -s "$ACCOUNT_DIR/$item" ]; then
                ln -sf "$CONFIG_SOURCE/$item" "$ACCOUNT_DIR/$item"
            fi
        fi
    done

    # Symlink ccstatusline config to XDG path (~/.config/ccstatusline/)
    # ccstatusline reads from ~/.config/ccstatusline/settings.json, not ~/.claude/ccstatusline/
    XDG_CCSL="/home/node/.config/ccstatusline"
    mkdir -p "$XDG_CCSL" 2>/dev/null
    if [ -d "$XDG_CCSL" ] && [ ! -e "$XDG_CCSL/settings.json" ]; then
        if [ -f "$ACCOUNT_DIR/ccstatusline/settings.json" ]; then
            ln -sf "$ACCOUNT_DIR/ccstatusline/settings.json" "$XDG_CCSL/settings.json"
        elif [ -f "$CONFIG_SOURCE/ccstatusline/settings.json" ]; then
            ln -sf "$CONFIG_SOURCE/ccstatusline/settings.json" "$XDG_CCSL/settings.json"
        fi
    fi
fi

# --- Git identity ----------------------------------------------------------------
# Set git user from environment variables (if not already configured)
if [ -n "${GIT_USER_NAME:-}" ] && [ -z "$(git config --global user.name 2>/dev/null)" ]; then
    git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ] && [ -z "$(git config --global user.email 2>/dev/null)" ]; then
    git config --global user.email "$GIT_USER_EMAIL"
fi

# --- Bind-mounted project script CRLF normalization ---------------------------
# Windows hosts (or editors with CRLF defaults) may introduce \r\n into shell
# scripts bind-mounted under /project, even when .gitattributes enforces LF.
# Strip CR characters in-place so bash does not trip over '\r: command not found'
# when executing project-local scripts inside the container.
# Best-effort: bounded depth to avoid scanning huge monorepos, errors suppressed
# so the entrypoint never fails on read-only mounts or missing directories.
if [ -d /project ]; then
    sh_count=$(find /project -maxdepth 3 -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "${sh_count:-0}" -gt 0 ]; then
        find /project -maxdepth 3 -name '*.sh' -type f \
            -exec sed -i 's/\r$//' {} + 2>/dev/null || true
        echo "[entrypoint] CRLF normalized in ${sh_count} shell script(s) under /project"
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
        # Validate token (macOS Keychain / Windows Credential Manager tokens
        # are NOT in hosts.yml — only the host config structure is present)
        if ! gh auth status >/dev/null 2>&1; then
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
