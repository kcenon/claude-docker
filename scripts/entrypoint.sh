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

    # Symlink shared config files (replace empty files too)
    for item in CLAUDE.md commit-settings.md settings.json; do
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
if command -v gh >/dev/null 2>&1 && [ -f /home/node/.config/gh/hosts.yml ]; then
    gh auth setup-git 2>/dev/null || true
fi

exec "$@"
