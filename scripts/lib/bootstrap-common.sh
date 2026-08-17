#!/usr/bin/env bash
# bootstrap-common.sh — Shared runtime-bootstrap helpers.
#
# Library file meant to be `source`d by scripts/entrypoint.sh and the
# per-runtime modules (bootstrap-claude.sh, bootstrap-codex.sh). The shebang
# doubles as a shellcheck shell directive (SC2148).
#
# These helpers consolidate the copy/symlink logic that the claude and codex
# entrypoint blocks each carried independently before issue #269. They were a
# verbatim relocation then; issue #357 is the first change to their behavior.
#
#   bootstrap_copy_dir SRC DST
#       Copy a directory tree, stripping Windows CRLF line endings from .sh
#       files and preserving each entry's source mode; symlinks are reproduced
#       as symlinks. Non-zero when any entry fails. Generalizes the former
#       copy_codex_dir.
#
#   bootstrap_link_item SRC DST FORCE
#       Symlink SRC -> DST. When FORCE is "true", or DST is absent, or DST is
#       not already a symlink, or DST is a symlink pointing somewhere other
#       than SRC, (re)create the link. A pre-existing non-symlink DST is backed
#       up to "<DST>.stale.<epoch>" first. Generalizes the former
#       link_codex_item.
#
#   bootstrap_crlf_normalize DIR
#       In-place strip CRLF from every .sh file under DIR, bounded in depth and
#       following symlinks rather than replacing them. Best-effort: errors
#       suppressed (read-only mounts, missing dirs).
#
#   bootstrap_degradation blocking|advisory MESSAGE
#       Record a security-relevant degradation for the pre-exec gate in
#       entrypoint.sh.

if [[ -n "${_CLAUDE_DOCKER_BOOTSTRAP_COMMON_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_CLAUDE_DOCKER_BOOTSTRAP_COMMON_SH_SOURCED=1

# Security-relevant degradations that applied during bootstrap, newline
# separated, in two tiers (#357, item 8).
#
# Before this, each degradation printed one warning and fell through to
# `exec "$@"`. The transform always applies `sandbox.enabled = false` and the
# deny stripping successfully -- only the compensating hook rewrite can fail --
# so "sandbox off, deny rules stripped, and the guard hook does not fire" could
# hold behind a single line that had already scrolled off screen.
#
# BLOCKING holds the ones the transform observed directly: it ran, and it can
# say what failed. entrypoint.sh refuses to exec on these unless
# CLAUDE_ALLOW_DEGRADED_SETTINGS=1.
#
# ADVISORY holds the ones inferred by heuristic -- today, hook scripts found by
# grepping `(~|/)[^ ]+\.sh` out of free-form command strings. A `.sh` token that
# was never meant to be a path on this filesystem reads as a missing hook, and
# turning that into a refusal would trade a stray warning line for a container
# that will not start. These are printed with the others and do not block.
#
# Not exported: entrypoint.sh sources the modules into its own shell.
CLAUDE_DOCKER_DEGRADATIONS_BLOCKING=""
CLAUDE_DOCKER_DEGRADATIONS_ADVISORY=""

# bootstrap_degradation blocking|advisory MESSAGE
# Append one degradation. Callers still print their own warning at the point
# of failure; this is the copy that survives to the gate.
bootstrap_degradation() {
    local tier="$1" message="$2"
    case "$tier" in
        blocking)
            if [ -n "$CLAUDE_DOCKER_DEGRADATIONS_BLOCKING" ]; then
                CLAUDE_DOCKER_DEGRADATIONS_BLOCKING="$CLAUDE_DOCKER_DEGRADATIONS_BLOCKING
$message"
            else
                CLAUDE_DOCKER_DEGRADATIONS_BLOCKING="$message"
            fi
            ;;
        advisory)
            if [ -n "$CLAUDE_DOCKER_DEGRADATIONS_ADVISORY" ]; then
                CLAUDE_DOCKER_DEGRADATIONS_ADVISORY="$CLAUDE_DOCKER_DEGRADATIONS_ADVISORY
$message"
            else
                CLAUDE_DOCKER_DEGRADATIONS_ADVISORY="$message"
            fi
            ;;
        *)
            echo "[entrypoint] ERROR: bootstrap_degradation called with unknown tier '$tier'" >&2
            return 1
            ;;
    esac
}

# bootstrap_copy_dir SRC DST
# Copy SRC into DST. .sh files are CRLF-normalized; other files are copied
# verbatim. Symlinks are reproduced as symlinks. Source mode bits are
# preserved. DST is removed and recreated so the copy is a clean mirror.
#
# Returns non-zero if any entry fails to copy.
#
# Three defects this replaces (#357, item 5):
#
#   * The .sh branch created the destination by redirection, so it started at
#     0666 & ~umask and then got a blanket `chmod +x`. A script the host
#     deliberately left non-executable, or owner-only at 0600, arrived as
#     0755. The mode is now taken from the source.
#   * `find . -type f` excludes symlinks, so a config tree distributed via
#     symlinks silently lost those entries. A missing hooks/lib/* left no
#     signal at all.
#   * The `while` ran in a pipe subshell, so a sed or cp failure could not
#     propagate. The loop reads from a process substitution now, and the
#     first failure is reported and returned.
bootstrap_copy_dir() {
    local src="$1"
    local dst="$2"
    local rel failures=0

    rm -rf "$dst" 2>/dev/null
    mkdir -p "$dst" || return 1

    while IFS= read -r rel; do
        mkdir -p "$dst/$(dirname "$rel")" 2>/dev/null

        if [ -L "$src/$rel" ]; then
            # Reproduce the link rather than dereferencing it. Copying the
            # target would turn one shared file into N copies that then drift.
            local target
            target="$(readlink "$src/$rel")"
            if ! ln -sfn "$target" "$dst/$rel"; then
                echo "[entrypoint] ERROR: could not recreate symlink $rel" >&2
                failures=$((failures + 1))
            fi
            continue
        fi

        case "$rel" in
            *.sh)
                if ! sed 's/\r$//' "$src/$rel" > "$dst/$rel"; then
                    echo "[entrypoint] ERROR: could not normalize $rel" >&2
                    failures=$((failures + 1))
                    continue
                fi
                # The source's mode, not a blanket 0755. `stat -c` is GNU and
                # `stat -f` is BSD; trying both keeps this correct on a macOS
                # developer host as well as in the Debian image. chmod
                # --reference would have been shorter but is GNU-only, and its
                # natural fallback is the `chmod +x` this replaces.
                local mode
                mode="$(stat -c '%a' "$src/$rel" 2>/dev/null || stat -f '%Lp' "$src/$rel" 2>/dev/null)"
                if [ -n "$mode" ]; then
                    chmod "$mode" "$dst/$rel" 2>/dev/null || true
                fi
                ;;
            *)
                # -p keeps mode and timestamps.
                if ! cp -p "$src/$rel" "$dst/$rel"; then
                    echo "[entrypoint] ERROR: could not copy $rel" >&2
                    failures=$((failures + 1))
                fi
                ;;
        esac
    done < <(cd "$src" && find . \( -type f -o -type l \) 2>/dev/null)

    if [ "$failures" -gt 0 ]; then
        echo "[entrypoint] ERROR: $failures entr(y|ies) failed copying $src -> $dst" >&2
        return 1
    fi
    return 0
}

# bootstrap_link_item SRC DST FORCE
# Symlink SRC -> DST when FORCE is "true", DST is absent, DST is not a
# symlink, or DST is a symlink pointing somewhere other than SRC. A
# pre-existing plain file/dir at DST is backed up before linking.
#
# The "points somewhere else" case is new (#357, item 2). Without it, once
# hooks/scripts/skills/commands/CLAUDE.md pointed into a CLAUDE_CONFIG_SOURCE
# path, *removing* that variable left them there: FORCE goes empty, the link
# still exists and is still a symlink, so every condition was false and the
# block was skipped. Meanwhile settings.json is regenerated unconditionally
# from the host original, so the configuration ended up half from one source
# and half from the other, with no log line. It self-healed only if the old
# target had also disappeared, which is why the symptom was intermittent.
#
# bootstrap-claude.sh's ccstatusline block already did the readlink-compare;
# the pattern is absorbed here so every linked item gets it.
bootstrap_link_item() {
    local src="$1"
    local dst="$2"
    local force="$3"
    local current=""

    if [ -L "$dst" ]; then
        current="$(readlink "$dst")"
    fi

    if [ "$force" = "true" ] || [ ! -e "$dst" ] || [ ! -L "$dst" ] || [ "$current" != "$src" ]; then
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            local backup
            backup="${dst}.stale.$(date +%s)"
            mv "$dst" "$backup"
            echo "[entrypoint] backed up stale $(basename "$dst") to $backup"
        fi
        if [ -n "$current" ] && [ "$current" != "$src" ]; then
            echo "[entrypoint] repointing $(basename "$dst"): $current -> $src"
        fi
        ln -sfn "$src" "$dst"
    fi
}

# bootstrap_crlf_normalize DIR
# Strip Windows CRLF line endings in-place from every .sh file under DIR.
# Best-effort: failures (read-only mount, missing directory) are suppressed.
#
# entrypoint.sh's own opt-in CRLF block already had the bounds this one was
# missing, and its comment explains why they matter -- editor change
# detection, `git status` pollution, racing host writes. This rewrites files
# under CLAUDE_CONFIG_SOURCE, which is a host path shared by every account
# container, so claude-a and claude-b run it concurrently over the same files
# (#357, item 7):
#
#   -maxdepth 4        an unbounded sweep can walk into a nested checkout
#   -type f            without it, a directory named *.sh is handed to sed
#   --follow-symlinks  GNU sed -i replaces a symlink with a regular file
#                      otherwise, silently breaking a shared hook
#
# The count is printed because an in-place rewrite of host files with no
# output is the kind of thing a user discovers through `git status`.
bootstrap_crlf_normalize() {
    local dir="$1"
    [ -d "$dir" ] || return 0

    local count
    count="$(find "$dir" -maxdepth 4 -type f -name "*.sh" 2>/dev/null | wc -l)"
    [ "$count" -eq 0 ] && return 0

    find "$dir" -maxdepth 4 -type f -name "*.sh" \
        -exec sed -i --follow-symlinks 's/\r$//' {} + 2>/dev/null

    echo "[entrypoint] CRLF-normalized $count .sh file(s) under $dir (in place)"
}
