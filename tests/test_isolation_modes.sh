#!/usr/bin/env bash
# test_isolation_modes.sh -- ISOLATION_MODE contract and worktree mount
# regression coverage (issue #335, stages 1 and 2).
#
# Two things are under test and they fail in different ways:
#
# 1. The configuration contract. Which mode a set of accounts runs under used
#    to be inferred from an unrelated variable, so a user could neither state
#    an intent nor be told it was not honored. Every case below pins one edge
#    of the resolution order, and the invalid ones assert a non-zero exit --
#    degrading to a weaker boundary than the one requested is the failure the
#    contract exists to prevent.
#
# 2. The worktree mount fix. docker-compose.worktree.yml named only the
#    per-account worktree and looked correct in source form, but Compose
#    merges volumes by container target and /project-<letter> is a different
#    target from the base /project, so the shared read-write source mount
#    survived into every resolved worktree service. Those assertions therefore
#    run against `docker compose config` output, never against the YAML.
#
# Every generator runs inside a throwaway sandbox holding only the files it
# reads. Running one in the repository would overwrite the committed compose
# files, so the committed set is digested before and after as an observable
# guard -- the same protocol test_compose_generator_equivalence.sh uses.
#
# Fixtures are generated here rather than added to tests/env_fixtures/ because
# these cases exist to exercise mode resolution, not the CI compose matrix.
# All values are placeholders; no test writes or prints a credential.
#
# Run:  bash tests/test_isolation_modes.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/compose_assert.sh
. "$SCRIPT_DIR/lib/compose_assert.sh"

OUTPUTS=(docker-compose.yml docker-compose.worktree.yml docker-compose.linux.yml)

# Placeholder host paths. Nothing is created on disk: `docker compose config`
# resolves the model without touching the sources it names.
PLACEHOLDER_HOME="/tmp/claude-docker-isolation-home"
PLACEHOLDER_PROJECT="/tmp/claude-docker-isolation-project"
PLACEHOLDER_WT_A="/tmp/claude-docker-isolation-wt-a"
PLACEHOLDER_WT_B="/tmp/claude-docker-isolation-wt-b"

PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# The bash generator refuses to run on native Windows shells, so this test is
# a Linux/macOS/WSL one. Say so rather than reporting failures the caller has
# no way to act on.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "NOTE: generate-compose.sh does not run on native Windows shells; use WSL." >&2
        echo "== Summary: SKIPPED (native Windows shell) =="
        exit 0 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

compose_digest() {
    local f
    for f in "${OUTPUTS[@]}"; do
        if [[ -f "$PROJECT_ROOT/$f" ]]; then
            cksum <"$PROJECT_ROOT/$f"
        else
            echo "absent $f"
        fi
    done
}
DIGEST_BEFORE="$(compose_digest)"

# make_bare_sandbox NAME -- project root holding only what a generator reads,
# with no compose files present. scripts/ is copied wholesale rather than
# enumerated so the sandbox stays correct when a new lib module is added.
make_bare_sandbox() {
    local dir="$WORK/$1"
    mkdir -p "$dir/tui/internal/config"
    cp -r "$PROJECT_ROOT/scripts" "$dir/scripts"
    cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$dir/tui/internal/config/"
    [[ -f "$PROJECT_ROOT/VERSION" ]] && cp "$PROJECT_ROOT/VERSION" "$dir/"
    printf '%s' "$dir"
}

# make_sandbox NAME -- make_bare_sandbox plus one default generator run.
#
# The seed matters because the compose builder now refuses a worktree
# configuration whose overlay file is absent. Without it every
# overlay-selection case below would fail on the missing file and never reach
# the mode logic it exists to test. Cases that assert on what the generator
# does or does not write use make_bare_sandbox instead, so a seeded file
# cannot be mistaken for generator output.
make_sandbox() {
    local dir
    dir="$(make_bare_sandbox "$1")"
    (cd "$dir" && bash scripts/generate-compose.sh >/dev/null 2>&1)
    printf '%s' "$dir"
}

# write_env DIR LINE...  -- stage a placeholder .env in a sandbox.
write_env() {
    local dir="$1"
    shift
    printf '%s\n' "$@" >"$dir/.env"
}

# run_generator DIR [ASSIGNMENTS...] -- run the bash generator in DIR with the
# caller's ISOLATION_MODE and NUM_ACCOUNTS cleared first, so a value left in
# the developer's shell cannot change what a case means. Output lands in
# DIR/.gen.log; the exit status is returned.
run_generator() {
    local dir="$1"
    shift
    local rc=0
    # shellcheck disable=SC2086  # deliberate word-split of the assignment list
    env -u ISOLATION_MODE -u NUM_ACCOUNTS -u PROJECT_DIR_A "$@" \
        bash "$dir/scripts/generate-compose.sh" >"$dir/.gen.log" 2>&1 || rc=$?
    return "$rc"
}

# compose_files DIR -- print the compose files build_compose_cmd selects for
# the configuration staged in DIR, one per line. Runs in a subshell so the
# sourced libraries cannot leak into this test's own shell state.
compose_files() {
    local dir="$1"
    (
        set -euo pipefail
        PROJECT_ROOT="$dir"
        export PROJECT_ROOT
        # shellcheck source=/dev/null
        . "$dir/scripts/lib/parse_env.sh"
        # shellcheck source=/dev/null
        . "$dir/scripts/lib/isolation.sh"
        # shellcheck source=/dev/null
        . "$dir/scripts/lib/build-compose-cmd.sh"
        # `|| exit 1` for the same reason scripts/claude-docker uses it: every
        # call below sits in an `if`, which suppresses set -e for this whole
        # subshell, so a bare `build_compose_cmd` would keep going and the
        # printf would overwrite the refusal with a zero exit status.
        build_compose_cmd || exit 1
        printf '%s\n' "${COMPOSE_CMD[@]}"
    )
}

# --- 1. Mode resolution -------------------------------------------------------

echo "== mode resolution =="

# A .env with no ISOLATION_MODE and no worktree paths is the pre-#335 default
# install: shared, no overlay.
dir="$(make_sandbox resolve-default)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT"
if compose_files "$dir" | grep -q 'docker-compose.worktree.yml'; then
    fail "default: worktree overlay selected without any worktree configuration"
else
    pass "default: shared, base compose only"
fi

# Legacy inference. Installations predating the key configured Tier B by
# setting PROJECT_DIR_A alone, and the overlay used to key off exactly that.
# Losing this would silently move every existing Tier B user onto the shared
# mount, which is the AC most easily broken by adding an explicit key.
dir="$(make_sandbox resolve-legacy)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "PROJECT_DIR_A=$PLACEHOLDER_WT_A" "PROJECT_DIR_B=$PLACEHOLDER_WT_B"
if compose_files "$dir" | grep -q 'docker-compose.worktree.yml'; then
    pass "legacy: PROJECT_DIR_A alone still selects the worktree overlay"
else
    fail "legacy: PROJECT_DIR_A no longer selects the worktree overlay"
fi

# An explicit mode outranks the inference in both directions.
dir="$(make_sandbox resolve-explicit-worktree)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=worktree" \
    "PROJECT_DIR_A=$PLACEHOLDER_WT_A" "PROJECT_DIR_B=$PLACEHOLDER_WT_B"
if compose_files "$dir" | grep -q 'docker-compose.worktree.yml'; then
    pass "explicit worktree: overlay selected"
else
    fail "explicit worktree: overlay missing"
fi

dir="$(make_sandbox resolve-explicit-shared)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=shared" \
    "PROJECT_DIR_A=$PLACEHOLDER_WT_A" "PROJECT_DIR_B=$PLACEHOLDER_WT_B"
if compose_files "$dir" 2>/dev/null | grep -q 'docker-compose.worktree.yml'; then
    fail "explicit shared: overlay selected despite an explicit shared mode"
else
    pass "explicit shared: overlay not selected, explicit mode outranks inference"
fi

# The inert worktree paths in that last case are a surprise worth reporting.
# The warning belongs where a user is making a decision -- regenerating compose
# or reading `config` -- not on every internal call that rebuilds the compose
# command, which several subcommands do more than once per invocation.
if run_generator "$dir" && grep -q 'PROJECT_DIR_A is configured' "$dir/.gen.log"; then
    pass "explicit shared: generator warns the configured worktree paths are ignored"
else
    fail "explicit shared: generator silently ignored the configured worktree paths"
    sed 's/^/        /' "$dir/.gen.log"
fi

# Environment outranks .env, matching every other key (#317).
dir="$(make_sandbox resolve-env-precedence)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=shared" \
    "PROJECT_DIR_A=$PLACEHOLDER_WT_A" "PROJECT_DIR_B=$PLACEHOLDER_WT_B"
if (export ISOLATION_MODE=worktree; compose_files "$dir") | grep -q 'docker-compose.worktree.yml'; then
    pass "precedence: environment ISOLATION_MODE outranks .env"
else
    fail "precedence: environment ISOLATION_MODE did not reach the compose builder"
fi

# --- 2. Rejected configurations -----------------------------------------------

echo "== rejected configurations =="

# An unknown mode must not degrade to shared.
dir="$(make_sandbox reject-unknown)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=bogus"
if run_generator "$dir"; then
    fail "unknown mode: generator succeeded"
elif grep -q 'ISOLATION_MODE must be shared, worktree or isolated' "$dir/.gen.log"; then
    pass "unknown mode: generator refused with a naming diagnostic"
else
    fail "unknown mode: generator failed without naming the accepted values"
    sed 's/^/        /' "$dir/.gen.log"
fi

# `isolated` is a known name this build cannot start. Accepting it and running
# a shared workspace would hand an account the access the mode asks to deny,
# so the contract validates the value and the generator still refuses it.
dir="$(make_sandbox reject-isolated)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=isolated"
if run_generator "$dir"; then
    fail "isolated: generator produced a stack for an unimplemented mode"
elif grep -q 'not implemented yet' "$dir/.gen.log"; then
    pass "isolated: generator refused and said the stack is not implemented"
else
    fail "isolated: generator failed without explaining why"
    sed 's/^/        /' "$dir/.gen.log"
fi

# The same value must be refused by the compose builder, not only the
# generator: a user with already-generated files would otherwise start
# containers on the shared mount.
dir="$(make_sandbox reject-isolated-runtime)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=isolated"
if compose_files "$dir" >/dev/null 2>&1; then
    fail "isolated: compose builder fell back instead of refusing"
else
    pass "isolated: compose builder refuses to assemble a command"
fi

# worktree without per-account paths cannot be honored. Bare sandbox: the
# next case asserts on what the generator wrote, and a seeded compose file
# would read as generator output.
dir="$(make_bare_sandbox reject-worktree-no-paths)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=worktree"
if run_generator "$dir"; then
    fail "worktree without paths: generator succeeded"
elif grep -q 'PROJECT_DIR_A is required when ISOLATION_MODE=worktree' "$dir/.gen.log"; then
    pass "worktree without paths: generator names the missing variable"
else
    fail "worktree without paths: generator failed without naming the variable"
    sed 's/^/        /' "$dir/.gen.log"
fi

# A rejected configuration must not leave output behind. The generator
# validates before opening its first file for exactly this reason.
if [[ -f "$dir/docker-compose.yml" ]]; then
    fail "worktree without paths: partial output was written"
else
    pass "worktree without paths: no compose file was written"
fi

# --- 3. Resolved worktree mounts ----------------------------------------------

echo "== resolved worktree mounts =="

if compose_assert_requires; then
    dir="$(make_sandbox resolved-worktree)"
    write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
        "ISOLATION_MODE=worktree" \
        "PROJECT_DIR_A=$PLACEHOLDER_WT_A" "PROJECT_DIR_B=$PLACEHOLDER_WT_B"
    if ! run_generator "$dir"; then
        fail "resolved: generator failed for a valid worktree configuration"
        sed 's/^/        /' "$dir/.gen.log"
    else
        targets="$(resolved_mount_targets "$dir" claude-a \
            docker-compose.yml docker-compose.worktree.yml)"
        sources="$(resolved_mount_sources "$dir" claude-a \
            docker-compose.yml docker-compose.worktree.yml)"

        # The defect itself: the inherited shared working-tree mount.
        if grep -qx '/project' <<<"$targets"; then
            fail "resolved: shared /project mount survived into the worktree service"
            printf '%s\n' "$targets" | sed 's/^/        target: /'
        else
            pass "resolved: no inherited /project mount"
        fi

        if grep -qx "$PLACEHOLDER_PROJECT" <<<"$sources"; then
            fail "resolved: shared PROJECT_DIR is still a mount source"
        else
            pass "resolved: shared PROJECT_DIR is not mounted"
        fi

        if grep -qx "$PLACEHOLDER_WT_A" <<<"$sources"; then
            pass "resolved: the account's own worktree is mounted"
        else
            fail "resolved: the account's worktree is missing"
        fi

        # Sibling isolation at the mount level. Worktrees share git metadata,
        # so this is a wrong-tree guard rather than a security claim -- see
        # docs/ISOLATION.md.
        if grep -qx "$PLACEHOLDER_WT_B" <<<"$sources"; then
            fail "resolved: account A mounts account B's worktree"
        else
            pass "resolved: no sibling worktree mount"
        fi

        # The dependency volume followed the project to its new target rather
        # than being left bound under both.
        if grep -qx '/project/node_modules' <<<"$targets"; then
            fail "resolved: node_modules still bound under the shared project path"
        else
            pass "resolved: no leftover /project/node_modules bind"
        fi
        if grep -qx '/project-a/node_modules' <<<"$targets"; then
            pass "resolved: node_modules bound under the worktree path"
        else
            fail "resolved: node_modules missing from the worktree path"
        fi

        # !override replaces the whole list, so mounts the base contributes
        # have to be re-emitted. Their absence would break the runtime rather
        # than weaken isolation, which makes it the quiet failure mode of the
        # fix and worth pinning.
        for required in /home/node/.claude /home/node/.claude-host; do
            if grep -qx "$required" <<<"$targets"; then
                pass "resolved: $required survived the override"
            else
                fail "resolved: $required was dropped by the override"
            fi
        done

        # Control: the shared stack still mounts the shared source. Without
        # this, a change that emptied every volume list would pass everything
        # above.
        shared_dir="$(make_sandbox resolved-shared)"
        write_env "$shared_dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT"
        if run_generator "$shared_dir"; then
            shared_targets="$(resolved_mount_targets "$shared_dir" claude-a docker-compose.yml)"
            if grep -qx '/project' <<<"$shared_targets"; then
                pass "control: shared mode still mounts the project at /project"
            else
                fail "control: shared mode lost its project mount"
            fi
        else
            fail "control: generator failed for a plain shared configuration"
            sed 's/^/        /' "$shared_dir/.gen.log"
        fi
    fi
else
    echo "  SKIP  resolved-compose assertions (docker or jq unavailable)"
fi

# --- 4. Committed files untouched ---------------------------------------------

echo "== committed compose files =="
if [[ "$(compose_digest)" == "$DIGEST_BEFORE" ]]; then
    pass "untouched by this run"
else
    fail "a generator ran outside its sandbox and rewrote them"
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
