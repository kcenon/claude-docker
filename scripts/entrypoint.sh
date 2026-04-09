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

    # Symlink shared config dirs
    for item in hooks skills commands scripts ccstatusline; do
        if [ -d "$CONFIG_SOURCE/$item" ]; then
            if [ "$FORCE_LINK" = "true" ] || [ ! -e "$ACCOUNT_DIR/$item" ]; then
                ln -sfn "$CONFIG_SOURCE/$item" "$ACCOUNT_DIR/$item"
            fi
        fi
    done

    # settings.json: always force-link (Claude Code overwrites it at runtime)
    if [ -f "$CONFIG_SOURCE/settings.json" ]; then
        ln -sf "$CONFIG_SOURCE/settings.json" "$ACCOUNT_DIR/settings.json"
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

# --- Git credential helper (gh) -------------------------------------------------
# Wire gh as git credential helper so git push/pull uses the mounted gh token
if command -v gh >/dev/null 2>&1; then
    if [ -n "${GH_TOKEN:-}" ]; then
        # GH_TOKEN env var takes precedence — no hosts.yml needed
        gh auth setup-git 2>/dev/null || true
        echo "[entrypoint] GitHub auth: using GH_TOKEN environment variable"
    elif [ -f /home/node/.config/gh/hosts.yml ]; then
        gh auth setup-git 2>/dev/null || true
        # Validate token (macOS Keychain tokens are NOT in hosts.yml)
        if ! gh auth status >/dev/null 2>&1; then
            echo "[entrypoint] WARNING: GitHub token is invalid or missing."
            echo "  On macOS, gh stores tokens in Keychain (not in hosts.yml)."
            echo "  The read-only bind mount cannot access Keychain tokens."
            echo ""
            echo "  Fix: run on the host:"
            echo "    gh auth login && scripts/claude-docker gh-auth"
        fi
    fi
fi

exec "$@"
