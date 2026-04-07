#!/bin/bash
# Entrypoint: symlink host claude-config into the account state directory.
# Host config is mounted read-only at /home/node/.claude-host/
# Account state is at /home/node/.claude/ (writable)

HOST_CONFIG="/home/node/.claude-host"
ACCOUNT_DIR="/home/node/.claude"

if [ -d "$HOST_CONFIG" ]; then
    # Symlink shared config dirs (skip if already exists)
    for item in hooks skills commands scripts ccstatusline; do
        if [ -d "$HOST_CONFIG/$item" ] && [ ! -e "$ACCOUNT_DIR/$item" ]; then
            ln -sf "$HOST_CONFIG/$item" "$ACCOUNT_DIR/$item"
        fi
    done

    # settings.json: always force-link (Claude Code overwrites it at runtime)
    if [ -f "$HOST_CONFIG/settings.json" ]; then
        ln -sf "$HOST_CONFIG/settings.json" "$ACCOUNT_DIR/settings.json"
    fi

    # Symlink other shared config files (replace empty files too)
    for item in CLAUDE.md commit-settings.md .claudeignore; do
        if [ -f "$HOST_CONFIG/$item" ]; then
            if [ ! -e "$ACCOUNT_DIR/$item" ] || [ ! -s "$ACCOUNT_DIR/$item" ]; then
                ln -sf "$HOST_CONFIG/$item" "$ACCOUNT_DIR/$item"
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
        elif [ -f "$HOST_CONFIG/ccstatusline/settings.json" ]; then
            ln -sf "$HOST_CONFIG/ccstatusline/settings.json" "$XDG_CCSL/settings.json"
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
