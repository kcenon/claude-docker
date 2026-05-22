#!/usr/bin/env bash
# bootstrap-common.sh — Shared runtime-bootstrap helpers.
#
# Library file meant to be `source`d by scripts/entrypoint.sh and the
# per-runtime modules (bootstrap-claude.sh, bootstrap-codex.sh). The shebang
# doubles as a shellcheck shell directive (SC2148).
#
# These helpers consolidate the copy/symlink logic that the claude and codex
# entrypoint blocks each carried independently before issue #269. The
# behavior is identical to the former inline implementations:
#
#   bootstrap_copy_dir SRC DST
#       Copy a directory tree, stripping Windows CRLF line endings from .sh
#       files and granting them the executable bit; other files copied as-is.
#       Generalizes the former copy_codex_dir.
#
#   bootstrap_link_item SRC DST FORCE
#       Symlink SRC -> DST. When FORCE is "true", or DST is absent, or DST is
#       not already a symlink, (re)create the link. A pre-existing non-symlink
#       DST is backed up to "<DST>.stale.<epoch>" first. Generalizes the
#       former link_codex_item.
#
#   bootstrap_crlf_normalize DIR
#       In-place strip CRLF from every .sh file under DIR. Best-effort:
#       errors suppressed (read-only mounts, missing dirs).

if [[ -n "${_CLAUDE_DOCKER_BOOTSTRAP_COMMON_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_BOOTSTRAP_COMMON_SH_SOURCED=1

# bootstrap_copy_dir SRC DST
# Copy SRC into DST. .sh files are CRLF-normalized and made executable;
# all other files are copied verbatim. DST is removed and recreated so the
# copy is a clean mirror.
bootstrap_copy_dir() {
    local src="$1"
    local dst="$2"
    rm -rf "$dst" 2>/dev/null
    mkdir -p "$dst"
    (cd "$src" && find . -type f 2>/dev/null) | while IFS= read -r rel; do
        mkdir -p "$dst/$(dirname "$rel")" 2>/dev/null
        case "$rel" in
            *.sh)
                sed 's/\r$//' "$src/$rel" > "$dst/$rel"
                chmod +x "$dst/$rel" 2>/dev/null || true
                ;;
            *)
                cp "$src/$rel" "$dst/$rel"
                ;;
        esac
    done
}

# bootstrap_link_item SRC DST FORCE
# Symlink SRC -> DST when FORCE is "true", DST is absent, or DST is not a
# symlink. A pre-existing plain file/dir at DST is backed up before linking.
bootstrap_link_item() {
    local src="$1"
    local dst="$2"
    local force="$3"
    if [ "$force" = "true" ] || [ ! -e "$dst" ] || [ ! -L "$dst" ]; then
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            local backup
            backup="${dst}.stale.$(date +%s)"
            mv "$dst" "$backup"
            echo "[entrypoint] backed up stale $(basename "$dst") to $backup"
        fi
        ln -sfn "$src" "$dst"
    fi
}

# bootstrap_crlf_normalize DIR
# Strip Windows CRLF line endings in-place from every .sh file under DIR.
# Best-effort: failures (read-only mount, missing directory) are suppressed.
bootstrap_crlf_normalize() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    find "$dir" -name "*.sh" -exec sed -i 's/\r$//' {} + 2>/dev/null
}
