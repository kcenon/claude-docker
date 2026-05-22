#!/usr/bin/env bash
# bootstrap-gemini.sh — Gemini-runtime bootstrap module.
#
# Library file meant to be `source`d by scripts/entrypoint.sh. The shebang
# doubles as a shellcheck shell directive (SC2148). Exposes a single entry
# point, runtime_bootstrap, which the dispatcher calls after sourcing this
# file via the registry's bootstrapModule field (issues #269, #272).
#
# Gemini is the validating third runtime (issue #272). Unlike bootstrap-
# claude.sh, no jq transform is applied: Gemini's settings.json has no
# sandbox flag or PowerShell-hook concept, so host config is plain-linked.
# Unlike bootstrap-codex.sh there is no hooks/ tree to copy with CRLF
# normalization.
#
# Depends on: scripts/lib/bootstrap-common.sh (sourced by entrypoint.sh).

if [[ -n "${_CLAUDE_DOCKER_BOOTSTRAP_GEMINI_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_BOOTSTRAP_GEMINI_SH_SOURCED=1

# --- Gemini config -------------------------------------------------------------
# Gemini CLI resolves its config directory as <home>/.gemini, where <home> is
# GEMINI_CLI_HOME when set, otherwise the OS home directory. The compose
# generator emits GEMINI_CLI_HOME=<configDirEnvValue>, the parent of the
# config directory (issue #280 decoupled this value from containerConfigMount).
# With GEMINI_CLI_HOME=/home/node the effective config directory is
# /home/node/.gemini — exactly the per-account state-volume mount
# (containerConfigMount), so credentials and history persist there directly
# with no nested .gemini/.gemini path. oauth_creds.json, google_accounts.json,
# sessions, and logs are left in that writable state directory; only
# non-secret host config (settings.json, GEMINI.md, commands/, extensions/)
# is linked in.

# runtime_bootstrap
# Gemini-runtime entry point. Prepares the Gemini config directory:
# plain-links non-secret host config (settings.json, GEMINI.md, commands/,
# extensions/). GEMINI_ACCOUNT_DIR and GEMINI_SOURCE are resolved here from
# the Gemini-specific environment variables.
runtime_bootstrap() {
    # Gemini computes its config dir as <home>/.gemini. GEMINI_CLI_HOME, when
    # set by the generated compose file, overrides <home>; the generator emits
    # /home/node, so the config dir resolves to /home/node/.gemini. Fall back
    # to /home/node so the path matches the container's default OS home.
    local GEMINI_HOME_ROOT="${GEMINI_CLI_HOME:-/home/node}"
    local GEMINI_ACCOUNT_DIR="$GEMINI_HOME_ROOT/.gemini"
    local GEMINI_SOURCE="${GEMINI_CONFIG_SOURCE:-/home/node/.gemini-host}"
    mkdir -p "$GEMINI_ACCOUNT_DIR" /home/node/.agents/skills 2>/dev/null || true
    chmod 700 "$GEMINI_ACCOUNT_DIR" 2>/dev/null || true

    if [ -d "$GEMINI_SOURCE" ]; then
        local FORCE_GEMINI_LINK="${GEMINI_CONFIG_SOURCE:+true}"

        if [ -f "$GEMINI_SOURCE/settings.json" ]; then
            bootstrap_link_item "$GEMINI_SOURCE/settings.json" "$GEMINI_ACCOUNT_DIR/settings.json" "$FORCE_GEMINI_LINK"
        fi

        if [ -f "$GEMINI_SOURCE/GEMINI.md" ]; then
            bootstrap_link_item "$GEMINI_SOURCE/GEMINI.md" "$GEMINI_ACCOUNT_DIR/GEMINI.md" "$FORCE_GEMINI_LINK"
        fi

        if [ -d "$GEMINI_SOURCE/commands" ]; then
            bootstrap_link_item "$GEMINI_SOURCE/commands" "$GEMINI_ACCOUNT_DIR/commands" "$FORCE_GEMINI_LINK"
        fi

        if [ -d "$GEMINI_SOURCE/extensions" ]; then
            bootstrap_link_item "$GEMINI_SOURCE/extensions" "$GEMINI_ACCOUNT_DIR/extensions" "$FORCE_GEMINI_LINK"
        fi
    fi
}
