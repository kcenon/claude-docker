#!/usr/bin/env bash
# bootstrap-codex.sh — Codex-runtime bootstrap module.
#
# Library file meant to be `source`d by scripts/entrypoint.sh. The shebang
# doubles as a shellcheck shell directive (SC2148). Exposes a single entry
# point, runtime_bootstrap, which the dispatcher calls after sourcing this
# file via the registry's bootstrapModule field (issue #269).
#
# This is the former codex block of entrypoint.sh, relocated verbatim. The
# former copy_codex_dir / link_codex_item helpers are generalized into
# bootstrap-common.sh as bootstrap_copy_dir / bootstrap_link_item.
#
# Depends on: scripts/lib/bootstrap-common.sh (sourced by entrypoint.sh).

if [[ -n "${_CLAUDE_DOCKER_BOOTSTRAP_CODEX_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_BOOTSTRAP_CODEX_SH_SOURCED=1

# --- Codex config --------------------------------------------------------------
# Codex stores mutable auth/session state under CODEX_HOME. Host-managed
# configuration is mounted separately at /home/node/.codex-host and only
# non-secret config is linked or copied into CODEX_HOME. auth.json, sessions,
# caches, and logs are intentionally left in the writable per-account state
# directory.

# runtime_bootstrap
# Codex-runtime entry point. Prepares CODEX_HOME: links non-secret host
# config (config.toml, AGENTS.md, rules/) and copies the hooks/ tree with
# CRLF normalization. CODEX_ACCOUNT_DIR and CODEX_SOURCE are resolved here
# from the Codex-specific environment variables.
runtime_bootstrap() {
    local CODEX_ACCOUNT_DIR="${CODEX_HOME:-/home/node/.codex}"
    local CODEX_SOURCE="${CODEX_CONFIG_SOURCE:-$(bootstrap_host_config_default codex)}"
    mkdir -p "$CODEX_ACCOUNT_DIR" /home/node/.agents/skills 2>/dev/null || true
    chmod 700 "$CODEX_ACCOUNT_DIR" 2>/dev/null || true

    if [ -d "$CODEX_SOURCE" ]; then
        local FORCE_CODEX_LINK="${CODEX_CONFIG_SOURCE:+true}"
        local target

        if [ -f "$CODEX_SOURCE/config.toml" ]; then
            bootstrap_link_item "$CODEX_SOURCE/config.toml" "$CODEX_ACCOUNT_DIR/config.toml" "$FORCE_CODEX_LINK"
        elif [ -f "$CODEX_SOURCE/config.codex-config.toml" ]; then
            bootstrap_link_item "$CODEX_SOURCE/config.codex-config.toml" "$CODEX_ACCOUNT_DIR/config.toml" "$FORCE_CODEX_LINK"
        fi

        if [ -f "$CODEX_SOURCE/AGENTS.md" ]; then
            bootstrap_link_item "$CODEX_SOURCE/AGENTS.md" "$CODEX_ACCOUNT_DIR/AGENTS.md" "$FORCE_CODEX_LINK"
        fi

        if [ -d "$CODEX_SOURCE/hooks" ]; then
            # One copy per boot, no backup branch.
            #
            # This used to guard on `[ ! -L "$target" ]` and back the target up
            # to hooks.stale.<epoch> first. But bootstrap_copy_dir makes the
            # target a *directory*, never a symlink, so the guard was true
            # again on the very next boot and the backup branch re-entered --
            # leaking one hooks.stale.* directory per container restart,
            # forever, onto the bind-mounted host state directory (#357,
            # item 1).
            #
            # bootstrap_copy_dir already begins with `rm -rf "$dst"`, so the
            # copy is a clean mirror on its own. bootstrap-claude.sh calls it
            # in the same situation with no backup branch and does not leak;
            # this is now the same shape.
            target="$CODEX_ACCOUNT_DIR/hooks"
            if ! bootstrap_copy_dir "$CODEX_SOURCE/hooks" "$target"; then
                echo "[entrypoint] WARNING: codex hooks copy reported errors" >&2
            else
                echo "[entrypoint] codex hooks: copied and CRLF-normalized"
            fi
        fi

        if [ -d "$CODEX_SOURCE/rules" ]; then
            bootstrap_link_item "$CODEX_SOURCE/rules" "$CODEX_ACCOUNT_DIR/rules" "$FORCE_CODEX_LINK"
        fi
    fi
}
