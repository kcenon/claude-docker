#!/usr/bin/env bash
# test_bootstrap_helpers.sh - container bootstrap helpers (issue #357).
#
# Run:  bash tests/test_bootstrap_helpers.sh
# Exits non-zero on any failure.
#
# Subjects: scripts/lib/bootstrap-common.sh (bootstrap_copy_dir,
# bootstrap_link_item, bootstrap_crlf_normalize, the degradation channel),
# the codex hooks block in scripts/lib/bootstrap-codex.sh, the account
# directory hardening in scripts/lib/bootstrap-claude.sh, and the pre-exec
# gate in scripts/entrypoint.sh.
#
# The settings.json *transform* is not covered here -- that is
# scripts/test-entrypoint-settings.sh, which already sources
# generate_container_settings directly.
#
# Linux only, and registered only in the Linux CI job: this is the code that
# runs inside the container, the image is Debian, and the CRLF sweep depends
# on GNU `sed -i --follow-symlinks`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Only bootstrap-common.sh is sourced here. bootstrap-claude.sh and
# bootstrap-codex.sh both define runtime_bootstrap, so each is sourced inside
# its own subshell below.
# shellcheck source=../scripts/lib/bootstrap-common.sh
. "$PROJECT_ROOT/scripts/lib/bootstrap-common.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $label"
        echo "        expected: $expected"
        echo "        actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local label="$1" cond="$2"
    if [[ "$cond" == "yes" ]]; then
        echo "  PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $label"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $label"
        echo "        wanted substring: $needle"
        echo "        in:               $haystack"
        FAIL=$((FAIL + 1))
    fi
}

mode_of() { stat -c '%a' "$1" 2>/dev/null; }

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
echo "=== bootstrap_copy_dir: mode, symlinks, failure propagation ==="
# ---------------------------------------------------------------------------

SRC="$WORK/src"
mkdir -p "$SRC/lib"
printf 'echo owner-only\r\n' > "$SRC/private.sh";  chmod 600 "$SRC/private.sh"
printf 'echo plain\r\n'      > "$SRC/plain.sh";    chmod 644 "$SRC/plain.sh"
printf 'echo runnable\r\n'   > "$SRC/run.sh";      chmod 755 "$SRC/run.sh"
printf '{"a":1}\n'           > "$SRC/data.json";   chmod 640 "$SRC/data.json"
printf 'echo shared\n'       > "$SRC/lib/shared.sh"
ln -s lib/shared.sh "$SRC/link.sh"

DST="$WORK/dst"
bootstrap_copy_dir "$SRC" "$DST" >/dev/null
rc=$?
assert_eq "copy of a clean tree returns 0" "0" "$rc"

# The .sh branch used to create the destination by redirection -- 0666 & ~umask
# -- and then blanket `chmod +x`. A 0600 source arrived 0755.
assert_eq "0600 .sh source stays owner-only" "600" "$(mode_of "$DST/private.sh")"
assert_eq "0644 .sh source stays 0644"       "644" "$(mode_of "$DST/plain.sh")"
assert_eq "0755 .sh source stays 0755"       "755" "$(mode_of "$DST/run.sh")"
assert_eq "non-.sh keeps its mode"           "640" "$(mode_of "$DST/data.json")"

# CRLF stripping is the reason the .sh branch exists at all; preserving mode
# must not have cost it.
assert_true "CRLF is stripped from copied .sh" \
    "$([[ "$(tr -d '\n' < "$DST/plain.sh" | od -c | grep -c '\\r')" == "0" ]] && echo yes || echo no)"

# `find . -type f` excluded symlinks entirely, so a config tree distributed
# via symlinks lost those entries with no diagnostic.
assert_true "symlinked entry is reproduced as a symlink" \
    "$([[ -L "$DST/link.sh" ]] && echo yes || echo no)"
assert_eq "the reproduced symlink keeps its target" \
    "lib/shared.sh" "$(readlink "$DST/link.sh" 2>/dev/null)"
assert_true "nested regular file is copied" \
    "$([[ -f "$DST/lib/shared.sh" ]] && echo yes || echo no)"

# The loop ran in a pipe subshell, so a sed or cp failure could not propagate.
# Shadowing the builtin lookup is deterministic regardless of privileges --
# chmod 000 on the source proves nothing when the suite runs as root.
sed() { return 1; }
out=$(bootstrap_copy_dir "$SRC" "$WORK/dst-sedfail" 2>&1)
rc=$?
unset -f sed
assert_eq "a sed failure makes the copy return non-zero" "1" "$rc"
assert_contains "the failing entry is named" "$out" "could not normalize"

cp() { return 1; }
out=$(bootstrap_copy_dir "$SRC" "$WORK/dst-cpfail" 2>&1)
rc=$?
unset -f cp
assert_eq "a cp failure makes the copy return non-zero" "1" "$rc"
assert_contains "the failing entry is named" "$out" "could not copy"

# ---------------------------------------------------------------------------
echo ""
echo "=== bootstrap_link_item: repointing and stale backup ==="
# ---------------------------------------------------------------------------

LINKS="$WORK/links"
mkdir -p "$LINKS" "$WORK/source-a" "$WORK/source-b"

bootstrap_link_item "$WORK/source-a" "$LINKS/hooks" "" >/dev/null
assert_eq "absent target is linked" "$WORK/source-a" "$(readlink "$LINKS/hooks")"

# The defect: with CLAUDE_CONFIG_SOURCE removed from .env, FORCE goes empty.
# The link exists and is a symlink, so every condition at the old :62 was
# false and the block was skipped -- while settings.json kept being
# regenerated from the host original. Half the configuration from each source,
# with no log line, and self-healing only if the old target had also vanished.
out=$(bootstrap_link_item "$WORK/source-b" "$LINKS/hooks" "" 2>&1)
assert_eq "a link pointing elsewhere is repointed even with FORCE empty" \
    "$WORK/source-b" "$(readlink "$LINKS/hooks")"
assert_contains "the repoint names the old target" "$out" "$WORK/source-a"
assert_contains "the repoint names the new target" "$out" "$WORK/source-b"

out=$(bootstrap_link_item "$WORK/source-b" "$LINKS/hooks" "" 2>&1)
assert_eq "an already-correct link logs nothing" "" "$out"

# settings.json now routes through this helper, so a file hand-edited inside
# the container is preserved rather than overwritten by a bare `ln -sf`.
printf '{"edited":true}\n' > "$LINKS/settings.json"
out=$(bootstrap_link_item "$WORK/source-b/settings.container.json" "$LINKS/settings.json" "true" 2>&1)
assert_true "a pre-existing regular file is preserved as .stale.<epoch>" \
    "$(compgen -G "$LINKS/settings.json.stale.*" >/dev/null && echo yes || echo no)"
assert_contains "the backup is logged" "$out" "backed up stale settings.json"
assert_true "the target is a symlink afterwards" \
    "$([[ -L "$LINKS/settings.json" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo ""
echo "=== bootstrap_crlf_normalize: bounds, symlinks, count ==="
# ---------------------------------------------------------------------------

CRLF="$WORK/crlf"
mkdir -p "$CRLF/a/b/c/d" "$CRLF/dir.sh"
printf 'echo top\r\n'   > "$CRLF/top.sh"
printf 'echo deep4\r\n' > "$CRLF/a/b/c/at-depth-4.sh"
printf 'echo deep5\r\n' > "$CRLF/a/b/c/d/at-depth-5.sh"
printf 'echo real\r\n'  > "$CRLF/real.sh"
ln -s real.sh "$CRLF/linked.sh"

out=$(bootstrap_crlf_normalize "$CRLF" 2>&1)

has_cr() { grep -qU $'\r' "$1" && echo yes || echo no; }

assert_eq "a file at depth 4 is normalized"       "no"  "$(has_cr "$CRLF/a/b/c/at-depth-4.sh")"
assert_eq "a file past the depth bound is left"   "yes" "$(has_cr "$CRLF/a/b/c/d/at-depth-5.sh")"
assert_eq "the top-level file is normalized"      "no"  "$(has_cr "$CRLF/top.sh")"

# GNU `sed -i` without --follow-symlinks replaces the symlink with a regular
# file, silently un-sharing a hook that every account container reads.
assert_true "a symlinked .sh is still a symlink after the sweep" \
    "$([[ -L "$CRLF/linked.sh" ]] && echo yes || echo no)"
assert_eq "the symlink's target was normalized through it" "no" "$(has_cr "$CRLF/real.sh")"

# A directory named *.sh was handed to sed by the unrestricted find.
assert_true "a directory named *.sh survives" \
    "$([[ -d "$CRLF/dir.sh" ]] && echo yes || echo no)"

# An in-place rewrite of host files that prints nothing is discovered through
# `git status`, which is not a diagnostic.
assert_contains "a count line is printed" "$out" "CRLF-normalized"

# ---------------------------------------------------------------------------
echo ""
echo "=== bootstrap-codex.sh: hooks copy does not leak per restart ==="
# ---------------------------------------------------------------------------

(
    # shellcheck source=../scripts/lib/bootstrap-codex.sh
    . "$PROJECT_ROOT/scripts/lib/bootstrap-codex.sh"

    CODEX_SRC="$WORK/codex-src"
    mkdir -p "$CODEX_SRC/hooks"
    printf 'echo hook\n' > "$CODEX_SRC/hooks/one.sh"
    printf 'config\n'    > "$CODEX_SRC/config.toml"

    export CODEX_HOME="$WORK/codex-home"
    export CODEX_CONFIG_SOURCE="$CODEX_SRC"

    # Three boots. The guard was `[ ! -L "$target" ]`, but bootstrap_copy_dir
    # makes the target a directory, so it was true again every time and the
    # backup branch re-entered -- one hooks.stale.<epoch> per restart, forever,
    # on the bind-mounted host state directory.
    runtime_bootstrap >/dev/null 2>&1
    runtime_bootstrap >/dev/null 2>&1
    runtime_bootstrap >/dev/null 2>&1

    stale=$(find "$CODEX_HOME" -maxdepth 1 -name 'hooks.stale.*' | wc -l)
    echo "$stale" > "$WORK/codex-stale-count"
    [[ -f "$CODEX_HOME/hooks/one.sh" ]] && echo yes > "$WORK/codex-hooks-present" || echo no > "$WORK/codex-hooks-present"
)

assert_eq "three boots leave zero hooks.stale.* directories" "0" "$(cat "$WORK/codex-stale-count")"
assert_eq "three boots leave the hooks copy in place" "yes" "$(cat "$WORK/codex-hooks-present")"

# ---------------------------------------------------------------------------
echo ""
echo "=== bootstrap-claude.sh: unsetting CLAUDE_CONFIG_SOURCE drops old links ==="
# ---------------------------------------------------------------------------
#
# The acceptance scenario verbatim: set CLAUDE_CONFIG_SOURCE, boot, unset it,
# boot again. Nothing under the account directory may still point into the old
# source.
#
# The second boot falls back to the read-only host mount, whose path only
# exists inside the image -- which is why this case did not exist before. The
# harness stages a stand-in through CLAUDE_DOCKER_HOST_CONFIG_ROOT, the same
# path root the three bootstrap modules now share.
#
# Both call sites are covered because they failed for the same reason and were
# fixed separately: the hooks/scripts loop (copy branch) and the CLAUDE.md
# group (link branch).

(
    # shellcheck source=../scripts/lib/bootstrap-claude.sh
    . "$PROJECT_ROOT/scripts/lib/bootstrap-claude.sh"

    OLD_SRC="$WORK/relink-old"
    HOST_ROOT="$WORK/relink-hostroot"
    HOST_SRC="$HOST_ROOT/.claude-host"
    ACCOUNT="$WORK/relink-account"

    for src in "$OLD_SRC" "$HOST_SRC"; do
        mkdir -p "$src/hooks" "$src/scripts" "$src/skills"
        printf 'echo hook\n'   > "$src/hooks/one.sh"
        printf 'echo script\n' > "$src/scripts/two.sh"
        printf 'guidance\n'    > "$src/CLAUDE.md"
        printf 'settings\n'    > "$src/commit-settings.md"
        printf 'ignored\n'     > "$src/.claudeignore"
    done

    export CLAUDE_CONFIG_DIR="$ACCOUNT"
    export CLAUDE_DOCKER_HOST_CONFIG_ROOT="$HOST_ROOT"

    # Boot 1: an explicit source. Everything becomes a symlink into it.
    export CLAUDE_CONFIG_SOURCE="$OLD_SRC"
    runtime_bootstrap >/dev/null 2>&1

    # Boot 2: the operator removed CLAUDE_CONFIG_SOURCE from .env.
    unset CLAUDE_CONFIG_SOURCE
    runtime_bootstrap >/dev/null 2>&1

    # Count anything still resolving into the old source, by target rather than
    # by name, so a link added later is covered without editing this list.
    stale=0
    for entry in "$ACCOUNT"/* "$ACCOUNT"/.[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        if [ -L "$entry" ] && case "$(readlink "$entry")" in "$OLD_SRC"*) true ;; *) false ;; esac; then
            stale=$((stale + 1))
            printf '        still points at the old source: %s -> %s\n' \
                "$(basename "$entry")" "$(readlink "$entry")" >&2
        fi
    done
    echo "$stale" > "$WORK/relink-stale-count"

    # The counterpart: the account must actually have the content, not just be
    # free of stale links. A run that deleted everything would score zero above.
    [ -f "$ACCOUNT/hooks/one.sh" ] && echo yes > "$WORK/relink-hooks" || echo no > "$WORK/relink-hooks"
    [ -e "$ACCOUNT/CLAUDE.md" ]    && echo yes > "$WORK/relink-md"    || echo no > "$WORK/relink-md"
)

assert_eq "no link points into the old source after unsetting it" \
    "0" "$(cat "$WORK/relink-stale-count")"
assert_eq "hooks are present from the fallback mount" "yes" "$(cat "$WORK/relink-hooks")"
assert_eq "CLAUDE.md is present from the fallback mount" "yes" "$(cat "$WORK/relink-md")"

# ---------------------------------------------------------------------------
echo ""
echo "=== bootstrap-claude.sh: account state directory is 0700 ==="
# ---------------------------------------------------------------------------

(
    # shellcheck source=../scripts/lib/bootstrap-claude.sh
    . "$PROJECT_ROOT/scripts/lib/bootstrap-claude.sh"

    export CLAUDE_CONFIG_DIR="$WORK/claude-home"
    # Absent source: runtime_bootstrap returns right after the hardening, so
    # this isolates the chmod from everything downstream.
    export CLAUDE_CONFIG_SOURCE="$WORK/no-such-config"

    mkdir -p "$CLAUDE_CONFIG_DIR"
    chmod 755 "$CLAUDE_CONFIG_DIR"
    runtime_bootstrap >/dev/null 2>&1
    stat -c '%a' "$CLAUDE_CONFIG_DIR" > "$WORK/claude-home-mode"
)

# The directory holds the OAuth .credentials.json. codex and gemini both
# hardened theirs; claude was the one that did not, and Docker Desktop
# typically exposes Windows bind mounts as 0777 inside the container.
assert_eq "claude hardens its account directory to 0700" "700" "$(cat "$WORK/claude-home-mode")"

# ---------------------------------------------------------------------------
echo ""
echo "=== entrypoint.sh: degraded settings do not reach exec ==="
# ---------------------------------------------------------------------------

# A host settings.json whose hook survives the transform but is not valid
# bash: the trailing pipe has nothing after it, so `bash -n -c` rejects it.
# The transform itself succeeds, which is the point -- sandbox.enabled=false
# and the deny stripping are applied first and cannot fail.
#
# The same hook also names a script that is not on disk, so this trips two
# independent degradations and the gate has to list both.
DEGRADED="$WORK/degraded-config"
mkdir -p "$DEGRADED"
cat > "$DEGRADED/settings.json" <<'JSON'
{
  "permissions": { "deny": ["Read(./secrets/**)"] },
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "pwsh -NoProfile -Command \"& ~/.claude/hooks/guard.ps1 |\"" } ] }
    ]
  }
}
JSON

run_entrypoint() {
    env -u GH_TOKEN -u GITHUB_TOKEN -u GIT_USER_NAME -u GIT_USER_EMAIL \
        HOME="$WORK/fake-home" \
        CLAUDE_DOCKER_ROOT="$PROJECT_ROOT" \
        AGENT_RUNTIME=claude \
        CLAUDE_CONFIG_DIR="$1" \
        CLAUDE_CONFIG_SOURCE="$DEGRADED" \
        "${@:2}" \
        bash "$PROJECT_ROOT/scripts/entrypoint.sh" echo __EXECED__ 2>&1
}

mkdir -p "$WORK/fake-home"

out=$(run_entrypoint "$WORK/gate-refuse")
rc=$?
assert_eq "a failing syntax check stops the entrypoint" "1" "$rc"
assert_true "exec is not reached" \
    "$([[ "$out" != *__EXECED__* ]] && echo yes || echo no)"
assert_contains "the refusal names the syntax-check degradation" "$out" "failed the bash syntax check"
assert_contains "the refusal names the missing-hook degradation" "$out" "are missing on disk"
assert_contains "the refusal states what was applied anyway" "$out" "sandbox.enabled=false"
assert_contains "the refusal names the opt-out" "$out" "CLAUDE_ALLOW_DEGRADED_SETTINGS=1"

out=$(run_entrypoint "$WORK/gate-allow" CLAUDE_ALLOW_DEGRADED_SETTINGS=1)
rc=$?
assert_eq "the opt-out lets the entrypoint through" "0" "$rc"
assert_true "exec is reached under the opt-out" \
    "$([[ "$out" == *__EXECED__* ]] && echo yes || echo no)"
assert_contains "the opt-out still lists the degradation" "$out" "failed the bash syntax check"

# Advisory tier: a Linux-native hook that names a script which is not on disk.
# The transform observed nothing wrong -- the "missing" verdict comes from
# grepping a path-shaped token out of a free-form command string, so it warns
# and starts rather than refusing on a heuristic.
ADVISORY="$WORK/advisory-config"
mkdir -p "$ADVISORY"
cat > "$ADVISORY/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/not-there.sh" } ] }
    ]
  }
}
JSON
out=$(env -u GH_TOKEN -u GITHUB_TOKEN -u GIT_USER_NAME -u GIT_USER_EMAIL \
    HOME="$WORK/fake-home" \
    CLAUDE_DOCKER_ROOT="$PROJECT_ROOT" \
    AGENT_RUNTIME=claude \
    CLAUDE_CONFIG_DIR="$WORK/gate-advisory" \
    CLAUDE_CONFIG_SOURCE="$ADVISORY" \
    bash "$PROJECT_ROOT/scripts/entrypoint.sh" echo __EXECED__ 2>&1)
rc=$?
assert_eq "an advisory-only degradation does not block" "0" "$rc"
assert_true "exec is reached with only an advisory degradation" \
    "$([[ "$out" == *__EXECED__* ]] && echo yes || echo no)"
assert_contains "the advisory is still reported" "$out" "are missing on disk"
assert_true "an advisory alone is not a refusal" \
    "$([[ "$out" != *"refusing to start"* ]] && echo yes || echo no)"

# A clean config must not trip the gate -- otherwise the refusal is useless.
CLEAN="$WORK/clean-config"
mkdir -p "$CLEAN"
printf '{"permissions":{"deny":["Read(./secrets/**)"]}}\n' > "$CLEAN/settings.json"
out=$(env -u GH_TOKEN -u GITHUB_TOKEN -u GIT_USER_NAME -u GIT_USER_EMAIL \
    HOME="$WORK/fake-home" \
    CLAUDE_DOCKER_ROOT="$PROJECT_ROOT" \
    AGENT_RUNTIME=claude \
    CLAUDE_CONFIG_DIR="$WORK/gate-clean" \
    CLAUDE_CONFIG_SOURCE="$CLEAN" \
    bash "$PROJECT_ROOT/scripts/entrypoint.sh" echo __EXECED__ 2>&1)
rc=$?
assert_eq "a clean config reaches exec" "0" "$rc"
assert_true "a clean config is not called degraded" \
    "$([[ "$out" != *"refusing to start"* ]] && echo yes || echo no)"
assert_contains "the removed deny rule is named in the log" "$out" "removed deny rule: Read(./secrets/**)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ "$PASS" -eq 0 ]]; then
    echo "  ERROR: no assertions ran" >&2
    exit 1
fi

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
