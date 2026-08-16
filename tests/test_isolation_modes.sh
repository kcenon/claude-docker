#!/usr/bin/env bash
# test_isolation_modes.sh -- ISOLATION_MODE contract, worktree mount
# regression, and isolated stack coverage (issue #335, stages 1 to 4).
#
# Three things are under test and they fail in different ways:
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
# 3. The isolated stack. An isolated account must see its own clone and nothing
#    shared: no /project, no host config tree, no shared gh config, no sibling
#    workspace. The quiet failure here is the inverse of the worktree one --
#    !override replaces the whole volume list, so a mount the base contributed
#    can go missing without any error, which is why the surviving mounts are
#    asserted too.
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

OUTPUTS=(
    docker-compose.yml
    docker-compose.worktree.yml
    docker-compose.isolated.yml
    docker-compose.linux.yml
)

# Placeholder host paths. Nothing is created on disk: `docker compose config`
# resolves the model without touching the sources it names.
PLACEHOLDER_HOME="/tmp/claude-docker-isolation-home"
PLACEHOLDER_PROJECT="/tmp/claude-docker-isolation-project"
PLACEHOLDER_WT_A="/tmp/claude-docker-isolation-wt-a"
PLACEHOLDER_WT_B="/tmp/claude-docker-isolation-wt-b"
PLACEHOLDER_ISO_A="/tmp/claude-docker-isolation-clone-a"
PLACEHOLDER_ISO_B="/tmp/claude-docker-isolation-clone-b"

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
    env -u ISOLATION_MODE -u NUM_ACCOUNTS -u PROJECT_DIR_A -u ISOLATED_WORKSPACE_A \
        -u ISOLATED_NETWORK_MODE "$@" \
        bash "$dir/scripts/generate-compose.sh" >"$dir/.gen.log" 2>&1 || rc=$?
    return "$rc"
}

# compose_files DIR -- print the compose files build_compose_cmd selects for
# the configuration staged in DIR, one per line. Runs in a subshell so the
# sourced libraries cannot leak into this test's own shell state.
#
# The sourcing list mirrors what scripts/claude-docker sources, in its order.
# index.sh is not decoration: isolation.sh derives per-account variable names
# through index_to_upper, so omitting it makes every mode that needs a
# per-account path fail as if the overlay were missing. Section 6 asserts the
# real entry points keep this set complete.
compose_files() {
    local dir="$1"
    (
        set -euo pipefail
        PROJECT_ROOT="$dir"
        export PROJECT_ROOT
        # shellcheck source=/dev/null
        . "$dir/scripts/lib/parse_env.sh"
        # shellcheck source=/dev/null
        . "$dir/scripts/lib/index.sh"
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

# The isolated mode selects its own overlay. Its per-account clone paths have
# to be configured for the mode to be usable at all, so the sandbox names them.
dir="$(make_sandbox resolve-explicit-isolated)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=isolated" \
    "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A" "ISOLATED_WORKSPACE_B=$PLACEHOLDER_ISO_B"
if compose_files "$dir" | grep -q 'docker-compose.isolated.yml'; then
    pass "explicit isolated: isolated overlay selected"
else
    fail "explicit isolated: isolated overlay missing"
fi

# There is deliberately no inference from ISOLATED_WORKSPACE_A, unlike the
# legacy PROJECT_DIR_A one above. Nothing predates that key, so setting it
# without declaring the mode is a mistake to report rather than a layout to
# honor -- and inferring a stronger boundary than was asked for is its own
# surprise.
dir="$(make_sandbox resolve-no-isolated-inference)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A"
if compose_files "$dir" | grep -q 'docker-compose.isolated.yml'; then
    fail "no inference: ISOLATED_WORKSPACE_A alone selected the isolated overlay"
else
    pass "no inference: ISOLATED_WORKSPACE_A alone stays on shared"
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

# isolated without per-account clone paths cannot be honored, and the failure
# has to name the variable and the script that produces it. Bare sandbox: the
# next case asserts on what the generator wrote.
dir="$(make_bare_sandbox reject-isolated-no-paths)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=isolated"
if run_generator "$dir"; then
    fail "isolated without paths: generator succeeded"
elif grep -q 'ISOLATED_WORKSPACE_A is required when ISOLATION_MODE=isolated' "$dir/.gen.log" \
    && grep -q 'setup-isolated.sh' "$dir/.gen.log"; then
    pass "isolated without paths: generator names the variable and the setup script"
else
    fail "isolated without paths: diagnostic did not name the variable and the script"
    sed 's/^/        /' "$dir/.gen.log"
fi

if [[ -f "$dir/docker-compose.yml" ]]; then
    fail "isolated without paths: partial output was written"
else
    pass "isolated without paths: no compose file was written"
fi

# An unknown network policy must not degrade to bridge. This one matters more
# than a typo usually does: a rejected value that quietly became `bridge` would
# attach every account to a network while the user believed they had asked for
# an offline profile, and nothing downstream would look wrong.
dir="$(make_sandbox reject-unknown-network)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATED_NETWORK_MODE=bogus"
if run_generator "$dir"; then
    fail "unknown network mode: generator succeeded"
elif grep -q 'ISOLATED_NETWORK_MODE must be bridge or none' "$dir/.gen.log"; then
    pass "unknown network mode: generator refused with a naming diagnostic"
else
    fail "unknown network mode: generator failed without naming the accepted values"
    sed 's/^/        /' "$dir/.gen.log"
fi

# A configured isolated mode whose overlay has not been generated must refuse
# rather than compose the base alone: that would put every account back on the
# shared /project mount, which is exactly what the mode is chosen to deny.
dir="$(make_bare_sandbox reject-isolated-missing-overlay)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=isolated" \
    "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A" "ISOLATED_WORKSPACE_B=$PLACEHOLDER_ISO_B"
if compose_files "$dir" >/dev/null 2>&1; then
    fail "isolated with no overlay: compose builder fell back to the base stack"
else
    pass "isolated with no overlay: compose builder refuses to assemble a command"
fi

# The unused-path warning is symmetric: clone paths left behind after a move
# back to worktree are inert and the user should be told.
dir="$(make_bare_sandbox warn-inert-clone-paths)"
write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
    "ISOLATION_MODE=shared" "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A"
if run_generator "$dir" && grep -q 'ISOLATED_WORKSPACE_A is configured' "$dir/.gen.log"; then
    pass "shared: generator warns the configured clone paths are ignored"
else
    fail "shared: generator silently ignored the configured clone paths"
    sed 's/^/        /' "$dir/.gen.log"
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

# --- 4. Resolved isolated mounts and container hardening ----------------------

echo "== resolved isolated mounts and hardening =="

if compose_assert_requires; then
    dir="$(make_sandbox resolved-isolated)"
    write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
        "ISOLATION_MODE=isolated" \
        "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A" "ISOLATED_WORKSPACE_B=$PLACEHOLDER_ISO_B"
    if ! run_generator "$dir"; then
        fail "isolated: generator failed for a valid isolated configuration"
        sed 's/^/        /' "$dir/.gen.log"
    else
        iso_files=(docker-compose.yml docker-compose.isolated.yml)
        targets="$(resolved_mount_targets "$dir" claude-a "${iso_files[@]}")"
        sources="$(resolved_mount_sources "$dir" claude-a "${iso_files[@]}")"

        # Same defect class as the worktree one: the shared source must not
        # survive the container-target merge.
        if grep -qx '/project' <<<"$targets"; then
            fail "isolated: shared /project mount survived into the isolated service"
            printf '%s\n' "$targets" | sed 's/^/        target: /'
        else
            pass "isolated: no inherited /project mount"
        fi

        if grep -qx "$PLACEHOLDER_ISO_A" <<<"$sources"; then
            pass "isolated: the account's own clone is mounted"
        else
            fail "isolated: the account's clone is missing"
        fi

        if grep -qx "$PLACEHOLDER_ISO_B" <<<"$sources"; then
            fail "isolated: account A mounts account B's clone"
        else
            pass "isolated: no sibling clone mount"
        fi

        # The shared host-home surfaces are what stage 3 removes. Each of these
        # resolves to the same host path for every account, so their presence
        # would mean the accounts still share configuration.
        for forbidden in /home/node/.claude-host /home/node/.config/gh; do
            if grep -qx "$forbidden" <<<"$targets"; then
                fail "isolated: shared host mount $forbidden is still present"
            else
                pass "isolated: $forbidden is absent"
            fi
        done

        # Per-account runtime state stays on purpose. It lives under $HOME but
        # is not a shared surface, and the TUI finds accounts by scanning it on
        # the host, so dropping it would blank the dashboard.
        if grep -qx '/home/node/.claude' <<<"$targets"; then
            pass "isolated: per-account runtime state survived the override"
        else
            fail "isolated: per-account runtime state was dropped by the override"
        fi

        # The machine-readable manifest answers the one question no
        # single-service assertion can: is any host path writable from two
        # accounts at once. This is what catches two accounts pointed at the
        # same clone, the obvious .env copy-paste mistake.
        dupes="$(duplicate_writable_sources "$dir" "${iso_files[@]}")"
        if [[ -z "$dupes" ]]; then
            pass "isolated: no host path is writable from more than one account"
        else
            fail "isolated: host paths writable from several accounts"
            printf '%s\n' "$dupes" | sed 's/^/        shared: /'
        fi

        # Control for the check above. Shared mode binds one PROJECT_DIR into
        # every account, so it MUST be reported as a duplicate -- without this,
        # a detector that returned nothing for any input would pass.
        dup_control="$(make_sandbox dup-control-shared)"
        write_env "$dup_control" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT"
        if run_generator "$dup_control"; then
            if duplicate_writable_sources "$dup_control" docker-compose.yml \
                | grep -qx "$PLACEHOLDER_PROJECT"; then
                pass "control: the duplicate detector reports shared mode's common mount"
            else
                fail "control: the duplicate detector missed shared mode's common mount"
            fi
        else
            fail "control: generator failed for a plain shared configuration"
            sed 's/^/        /' "$dup_control/.gen.log"
        fi

        # --- Container hardening --------------------------------------------
        # Asserted on the resolved model rather than the overlay, for the same
        # reason the mounts are: the base stack contributes fields of its own,
        # and only the merged project shows which value actually wins.
        hardening="$(resolved_service_hardening "$dir" claude-a "${iso_files[@]}")"

        for expected in 'read_only=true' 'init=true' 'cap_drop=["ALL"]' \
                        'security_opt=["no-new-privileges:true"]'; do
            if grep -qxF "$expected" <<<"$hardening"; then
                pass "isolated: $expected"
            else
                fail "isolated: expected $expected"
                printf '%s\n' "$hardening" | sed 's/^/        /'
            fi
        done

        # The profile must not run as root. It pins the host user's uid/gid
        # rather than the image's `node` account, because the per-account state
        # directory is a host bind mount and a fixed uid 1000 would make it
        # unwritable wherever the host user is not uid 1000. Either identity
        # satisfies the requirement this asserts, which is that uid 0 is not it.
        user_field="$(grep -m1 '^user=' <<<"$hardening" | cut -d= -f2-)"
        case "$user_field" in
            '') fail "isolated: no effective user is declared" ;;
            0|0:*|root|root:*) fail "isolated: service runs as root ($user_field)" ;;
            *) pass "isolated: effective user is non-root ($user_field)" ;;
        esac

        pids_field="$(grep -m1 '^pids=' <<<"$hardening" | cut -d= -f2-)"
        if [[ "$pids_field" =~ ^[0-9]+$ ]] && [[ "$pids_field" -gt 0 ]]; then
            pass "isolated: PID limit is bounded ($pids_field)"
        else
            fail "isolated: PID limit is not a positive integer ($pids_field)"
        fi

        # $HOME sits on the read-only root filesystem, so the global git config
        # has to be redirected into something writable. Without it the
        # entrypoint's `gh auth setup-git` fails silently -- the container still
        # starts and still prints an authenticated banner, but git push has no
        # credential helper. Requiring the path to be inside a declared mount is
        # what makes this a real check rather than a spelling test.
        git_cfg="$(grep -m1 '^git_config_global=' <<<"$hardening" | cut -d= -f2-)"
        if [[ -z "$git_cfg" ]]; then
            fail "isolated: GIT_CONFIG_GLOBAL is unset; \$HOME/.gitconfig is read-only"
        elif grep -qxF "${git_cfg%/*}" <<<"$targets"; then
            pass "isolated: GIT_CONFIG_GLOBAL is inside a writable mount ($git_cfg)"
        else
            fail "isolated: GIT_CONFIG_GLOBAL ($git_cfg) is not inside any mount"
        fi

        # Under a read-only root every image-layer path the entrypoint or the
        # toolchain writes to needs a tmpfs. A missing one can fail silently:
        # ccstatusline falls back to a hardcoded layout when its XDG directory
        # is unwritable, so the container looks healthy and the user just loses
        # their configuration.
        tmpfs_mounts="$(resolved_service_tmpfs "$dir" claude-a "${iso_files[@]}" | cut -d: -f1)"
        for required in /tmp /home/node/.config /home/node/.cache \
                        /home/node/.npm /home/node/.agents; do
            if grep -qxF "$required" <<<"$tmpfs_mounts"; then
                pass "isolated: $required is writable under a read-only root"
            else
                fail "isolated: $required has no tmpfs under a read-only root"
            fi
        done

        # The agent CLI is installed into /home/node/.local and is on PATH, so a
        # tmpfs there would hide the binary. Its absence from the list is
        # load-bearing, not an oversight.
        if grep -qxF /home/node/.local <<<"$tmpfs_mounts"; then
            fail "isolated: /home/node/.local is masked by a tmpfs; the agent CLI would disappear"
        else
            pass "isolated: /home/node/.local is not masked by a tmpfs"
        fi
    fi
else
    echo "  SKIP  resolved-compose assertions (docker or jq unavailable)"
fi

# --- 5. Resolved isolated credentials and networks ----------------------------

echo "== resolved isolated credentials and networks =="

if compose_assert_requires; then
    dir="$(make_sandbox resolved-scoping)"
    write_env "$dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
        "ISOLATION_MODE=isolated" \
        "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A" "ISOLATED_WORKSPACE_B=$PLACEHOLDER_ISO_B"
    if ! run_generator "$dir"; then
        fail "scoping: generator failed for a valid isolated configuration"
        sed 's/^/        /' "$dir/.gen.log"
    else
        iso_files=(docker-compose.yml docker-compose.isolated.yml)
        env_keys="$(resolved_service_env_keys "$dir" claude-a "${iso_files[@]}")"

        # The shared GH_TOKEN names one GitHub account. Handing the same value
        # to every isolated service would leave the boundary decorative on the
        # one surface carrying write access to remote repositories. This is
        # asserted on the resolved model because the overlay cannot be read for
        # it: the base stack declares the variable, and only the merged project
        # shows whether the override actually removed it.
        if grep -qx 'GH_TOKEN' <<<"$env_keys"; then
            fail "isolated: the shared GH_TOKEN survived into the isolated service"
            printf '%s\n' "$env_keys" | sed 's/^/        key: /'
        else
            pass "isolated: no shared GitHub token"
        fi

        # The override replaces the whole environment list, so it can fail in
        # the other direction too: a variable left out here is simply gone, and
        # a container missing HOME or CLAUDE_CONFIG_DIR starts and then behaves
        # strangely rather than failing outright.
        for required in TERM HOME AGENT_RUNTIME CLAUDE_CONFIG_DIR NODE_OPTIONS \
                        GIT_USER_NAME GIT_USER_EMAIL GIT_CONFIG_GLOBAL; do
            if grep -qx "$required" <<<"$env_keys"; then
                pass "isolated: $required survived the environment override"
            else
                fail "isolated: $required was dropped by the environment override"
            fi
        done

        # Control. Without it, a generator that emitted an empty environment
        # list for every mode would satisfy the assertion above.
        cred_control="$(make_sandbox cred-control-shared)"
        write_env "$cred_control" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT"
        if run_generator "$cred_control"; then
            if resolved_service_env_keys "$cred_control" claude-a docker-compose.yml \
                | grep -qx 'GH_TOKEN'; then
                pass "control: shared mode does receive the shared GitHub token"
            else
                fail "control: shared mode lost GH_TOKEN, so the isolated check proves nothing"
            fi
        else
            fail "control: generator failed for a plain shared configuration"
            sed 's/^/        /' "$cred_control/.gen.log"
        fi

        # Per-account auth is the other half of the contract: an isolated
        # service may hold its OWN credential. Presence alone would not
        # distinguish that from both accounts being handed the same token, so
        # the values are compared -- inside the helper, which reports only
        # whether they differ and never prints either one.
        pa_dir="$(make_sandbox scoping-per-account)"
        write_env "$pa_dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
            "ISOLATION_MODE=isolated" \
            "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A" "ISOLATED_WORKSPACE_B=$PLACEHOLDER_ISO_B" \
            "GH_AUTH_MODE=per-account" \
            "GH_USER_A=placeholder-user-a" "GH_TOKEN_A=placeholder-token-a" \
            "GH_USER_B=placeholder-user-b" "GH_TOKEN_B=placeholder-token-b"
        if run_generator "$pa_dir"; then
            if resolved_service_env_keys "$pa_dir" claude-a "${iso_files[@]}" \
                | grep -qx 'GH_TOKEN'; then
                pass "isolated + per-account: the account keeps its own token"
            else
                fail "isolated + per-account: the account's own token was dropped"
            fi

            case "$(resolved_env_distinct "$pa_dir" GH_TOKEN claude-a claude-b "${iso_files[@]}")" in
                distinct)  pass "isolated + per-account: the two accounts hold different tokens" ;;
                identical) fail "isolated + per-account: both accounts hold the same token" ;;
                *)         fail "isolated + per-account: GH_TOKEN is missing from a service" ;;
            esac
        else
            fail "isolated + per-account: generator failed"
            sed 's/^/        /' "$pa_dir/.gen.log"
        fi

        # --- Networks --------------------------------------------------------
        # The base stack declares no networks, so every service lands on the
        # project-wide implicit bridge and siblings reach each other by service
        # name. That is the lateral path this replaces.
        net_a="$(resolved_service_networks "$dir" claude-a "${iso_files[@]}")"
        net_b="$(resolved_service_networks "$dir" claude-b "${iso_files[@]}")"

        if [[ -z "$(comm -12 <(sort <<<"$net_a") <(sort <<<"$net_b"))" ]]; then
            pass "isolated: the two accounts share no network"
        else
            fail "isolated: the two accounts share a network"
            printf '%s\n' "$net_a" | sed 's/^/        a: /'
            printf '%s\n' "$net_b" | sed 's/^/        b: /'
        fi

        # Attached, not detached. A bridge per account is what keeps outbound
        # model-API and git access working; a profile that dropped the
        # attachment entirely would also pass the disjointness check above
        # while breaking every ordinary workload.
        if grep -q '^network=' <<<"$net_a"; then
            pass "isolated: the account is attached to a network under the default policy"
        else
            fail "isolated: the account has no network; outbound API and git access would fail"
        fi

        # Control. Shared mode puts every service on the implicit default
        # bridge, so it MUST be reported as sharing -- without this, a helper
        # that returned nothing for any input would pass the check above.
        if [[ -n "$(comm -12 \
            <(resolved_service_networks "$cred_control" claude-a docker-compose.yml | sort) \
            <(resolved_service_networks "$cred_control" claude-b docker-compose.yml | sort))" ]]; then
            pass "control: shared mode's accounts do share a network"
        else
            fail "control: shared mode reported no shared network, so the isolated check proves nothing"
        fi

        # The offline policy is a different YAML key, not a different value of
        # the same one, so it is generated rather than interpolated and needs
        # its own resolved-model case.
        off_dir="$(make_sandbox scoping-offline)"
        write_env "$off_dir" "HOME=$PLACEHOLDER_HOME" "PROJECT_DIR=$PLACEHOLDER_PROJECT" \
            "ISOLATION_MODE=isolated" "ISOLATED_NETWORK_MODE=none" \
            "ISOLATED_WORKSPACE_A=$PLACEHOLDER_ISO_A" "ISOLATED_WORKSPACE_B=$PLACEHOLDER_ISO_B"
        if run_generator "$off_dir"; then
            if resolved_service_networks "$off_dir" claude-a "${iso_files[@]}" \
                | grep -qx 'network_mode=none'; then
                pass "isolated + none: the account is detached from every network"
            else
                fail "isolated + none: the offline policy did not reach the resolved model"
            fi
        else
            fail "isolated + none: generator failed"
            sed 's/^/        /' "$off_dir/.gen.log"
        fi
    fi
else
    echo "  SKIP  resolved-compose assertions (docker or jq unavailable)"
fi

# --- 6. Entry-point library wiring --------------------------------------------

echo "== entry-point library wiring =="

# build-compose-cmd.sh calls into the isolation contract, so every entry point
# sourcing it must source isolation.sh first. Omitting it is not a syntax
# error: it fails at run time with "command not found", which is how
# scripts/install.sh shipped broken after stage 1 -- nothing exercised its
# library set, so shellcheck and every other test stayed green.
#
# Each entry point's own `. "$SCRIPT_DIR/lib/*.sh"` lines are executed in the
# order it lists them and the contract functions are then looked up, so a
# wrong order is caught as well as an omission.
# Read into the array with a while loop rather than `mapfile`: mapfile is
# bash 4+, and this suite now also runs on macOS, which ships bash 3.2.
wiring_entries=()
while IFS= read -r wiring_entry; do
    [[ -n "$wiring_entry" ]] && wiring_entries+=("$wiring_entry")
done < <(
    find "$PROJECT_ROOT/scripts" -maxdepth 1 -type f \
        -exec grep -lE '^\. "\$SCRIPT_DIR/lib/build-compose-cmd\.sh"$' {} + | sort
)

if [[ "${#wiring_entries[@]}" -eq 0 ]]; then
    fail "wiring: no entry point matched the build-compose-cmd sourcing pattern"
fi

for entry in "${wiring_entries[@]}"; do
    name="$(basename "$entry")"
    grep -E '^\. "\$SCRIPT_DIR/lib/[a-z_-]+\.sh"$' "$entry" >"$WORK/$name.srcs"
    if (
        set -uo pipefail
        SCRIPT_DIR="$PROJECT_ROOT/scripts"
        export PROJECT_ROOT
        # shellcheck source=/dev/null
        . "$WORK/$name.srcs"
        declare -F require_supported_isolation_mode >/dev/null &&
            declare -F build_compose_cmd >/dev/null
    ) >/dev/null 2>&1; then
        pass "$name: the isolation contract resolves from its library set"
    else
        fail "$name: build_compose_cmd would abort -- isolation.sh is not sourced"
    fi
done

# --- 7. Committed files untouched ---------------------------------------------

echo "== committed compose files =="
if [[ "$(compose_digest)" == "$DIGEST_BEFORE" ]]; then
    pass "untouched by this run"
else
    fail "a generator ran outside its sandbox and rewrote them"
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
