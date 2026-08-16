#!/usr/bin/env bash
# test_install_tier_b.sh - the Tier B installer-to-generator seam (issue #347).
#
# Run:  bash tests/test_install_tier_b.sh
# Exits non-zero on any failure.
#
# generate_env wrote ISOLATION_MODE=worktree with empty PROJECT_DIR_*
# placeholders and then called the compose generator from inside the same
# function, 72 lines later. require_supported_isolation_mode refuses that by
# design -- it does not distinguish empty from unset -- so under
# `set -euo pipefail` a Tier B install died before create_state_dirs.
#
# Nothing in tests/ covered this seam. The one test that calls generate_env at
# all (test_installer_github_equivalence.sh) sets TIER=A, which never emits the
# placeholders, so CI stayed green while every Tier B install aborted.
#
# The generator and setup-worktrees are stubbed. What is under test is the
# ordering and the account count the installer drives them with, not what they
# then do; the generator's refusal itself is pinned by
# tests/test_isolation_modes.sh and must keep passing unchanged.
#
# NUM_ACCOUNTS is 4 rather than 2 so the second defect is covered too: the
# worktree step prompted for exactly two branches and wrote back exactly
# PROJECT_DIR_A and PROJECT_DIR_B regardless of the count.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' \
            "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_ROOT="$WORK/root"        # stands in for PROJECT_ROOT; receives .env
FAKE_SCRIPTS="$WORK/scripts"  # stands in for SCRIPT_DIR; holds the stubs
SOURCE_REPO="$WORK/myapp"     # the user's project repository
mkdir -p "$FAKE_ROOT" "$FAKE_SCRIPTS" "$SOURCE_REPO"

git -C "$SOURCE_REPO" init -q
git -C "$SOURCE_REPO" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init

# The generator stub records its argv and, more importantly, a snapshot of the
# .env exactly as it stood when it was invoked. That snapshot is the subject:
# the defect is not that the generator misbehaves, it is what the installer
# hands it.
cat > "$FAKE_SCRIPTS/generate-compose.sh" <<'STUB'
#!/usr/bin/env bash
echo "invoked" >> "$GEN_LOG"
cp "$SNAPSHOT_SOURCE" "$SNAPSHOT_DEST"
STUB

# The worktree stub records the argv it was handed, which is how "all N
# branches in one invocation" is observed.
cat > "$FAKE_SCRIPTS/setup-worktrees.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$#" > "$WT_ARGC"
printf '%s\n' "$@" > "$WT_ARGV"
STUB

chmod +x "$FAKE_SCRIPTS/generate-compose.sh" "$FAKE_SCRIPTS/setup-worktrees.sh"

status=0
(
    export CLAUDE_DOCKER_INSTALL_LIBRARY_ONLY=1
    export HOME="$WORK/home"
    mkdir -p "$HOME"
    export GEN_LOG="$WORK/gen.log"
    export SNAPSHOT_SOURCE="$FAKE_ROOT/.env"
    export SNAPSHOT_DEST="$WORK/env-at-generation"
    export WT_ARGC="$WORK/wt.argc"
    export WT_ARGV="$WORK/wt.argv"

    # shellcheck source=../scripts/install.sh
    . "$REPO_ROOT/scripts/install.sh"

    # Redirect the installer at the sandbox. SCRIPT_DIR is what selects the
    # stubs; PROJECT_ROOT is where .env lands.
    SCRIPT_DIR="$FAKE_SCRIPTS"
    PROJECT_ROOT="$FAKE_ROOT"

    # shellcheck disable=SC2034
    PLATFORM=linux
    # shellcheck disable=SC2034
    TIER=B
    # shellcheck disable=SC2034
    AUTH_PATH=A
    # shellcheck disable=SC2034
    NUM_ACCOUNTS=4
    # shellcheck disable=SC2034
    SOURCE_DIR="$SOURCE_REPO"
    # shellcheck disable=SC2034
    RUNTIME=claude

    # The real prompt reads from /dev/tty, which a test run does not have.
    # Returning the default is what an operator pressing enter would do.
    prompt_input() { printf '%s' "${2:-}"; }

    generate_env
    setup_worktrees
    generate_compose_files
) > "$WORK/out.log" 2>&1 || status=$?

echo "== A Tier B install reaches the generator =="

assert_eq "the install steps complete" "0" "$status"
if [[ "$status" -ne 0 ]]; then
    echo "  --- captured output ---"
    sed 's/^/  /' "$WORK/out.log"
fi

gen_runs=0
[[ -f "$WORK/gen.log" ]] && gen_runs=$(grep -c invoked "$WORK/gen.log")
assert_eq "the generator ran exactly once" "1" "$gen_runs"

echo "== What .env declared at the moment the generator ran =="

snapshot="$WORK/env-at-generation"
if [[ ! -f "$snapshot" ]]; then
    assert_eq "a snapshot was taken" "taken" "missing"
else
    mode=$(grep '^ISOLATION_MODE=' "$snapshot" | tail -1 | cut -d= -f2-)
    assert_eq "the declared mode is worktree" "worktree" "$mode"

    # The contract: worktree may only be declared once every path it requires
    # is populated. An empty value is what the generator refuses.
    empty=$(grep -cE '^(PROJECT_DIR|ISOLATED_WORKSPACE)_[A-Z]+=$' "$snapshot" || true)
    assert_eq "no per-account path is empty" "0" "$empty"

    for letter in A B C D; do
        value=$(grep "^PROJECT_DIR_${letter}=" "$snapshot" | tail -1 | cut -d= -f2-)
        assert_eq "PROJECT_DIR_${letter} is populated" \
            "$SOURCE_REPO-$(printf '%s' "$letter" | tr '[:upper:]' '[:lower:]')" "$value"
    done
fi

echo "== All accounts reach setup-worktrees in one invocation =="

if [[ -f "$WORK/wt.argc" ]]; then
    # repo dir plus four branch names.
    assert_eq "setup-worktrees.sh got 5 arguments" "5" "$(cat "$WORK/wt.argc")"
    assert_eq "the branches are the four defaults" \
        "worktree-a worktree-b worktree-c worktree-d" \
        "$(tail -n +2 "$WORK/wt.argv" | tr '\n' ' ' | sed 's/ $//')"
else
    assert_eq "setup-worktrees.sh was invoked" "invoked" "not invoked"
fi

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
