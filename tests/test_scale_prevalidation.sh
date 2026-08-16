#!/usr/bin/env bash
# test_scale_prevalidation.sh - `scale N` validates before it mutates
# (issue #355).
#
# Run:  bash tests/test_scale_prevalidation.sh
# Exits non-zero on any failure.
#
# Both wrappers wrote NUM_ACCOUNTS first and ran the generator afterwards. The
# generator is deliberately fail-closed -- it validates the isolation mode for
# every account before its first write, so a failure "cannot leave a partially
# regenerated set behind" -- but the caller had already moved.
#
# On a worktree install holding only PROJECT_DIR_A and PROJECT_DIR_B,
# `scale 4` wrote NUM_ACCOUNTS=4, created account-c and account-d, and then
# died on "PROJECT_DIR_C is required when ISOLATION_MODE=worktree". What
# remained was .env saying 4 and the compose files saying 2.
#
# Nothing downstream catches that split, which is what makes it worth a test:
# `up` resolves the mode with the default account count of 1, so it passes and
# starts two containers, while get_service_names, the TUI and the help text
# all read NUM_ACCOUNTS and report four.
#
# The subject is the pre-validation, so docker is stubbed and never reached.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# A sandbox project root: scripts plus the registry, and its own .env.
SANDBOX="$WORK/repo"
mkdir -p "$SANDBOX/tui/internal/config"
cp -r "$PROJECT_ROOT/scripts" "$SANDBOX/scripts"
cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$SANDBOX/tui/internal/config/"
cp "$PROJECT_ROOT/VERSION" "$SANDBOX/"

# docker is stubbed so nothing can reach a daemon; the pre-validation must
# reject before anything would call it anyway.
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/docker"
chmod +x "$WORK/bin/docker"

# A worktree install with paths for two accounts only -- the exact shape the
# defect needs.
write_env() {
    cat > "$SANDBOX/.env" <<EOF
HOME=$WORK/home
PROJECT_DIR=$WORK/project
NUM_ACCOUNTS=2
AGENT_RUNTIME=claude
ISOLATION_MODE=worktree
PROJECT_DIR_A=$WORK/project-a
PROJECT_DIR_B=$WORK/project-b
EOF
}
mkdir -p "$WORK/home" "$WORK/project" "$WORK/project-a" "$WORK/project-b"
write_env

num_accounts() {
    grep '^NUM_ACCOUNTS=' "$SANDBOX/.env" | tail -1 | cut -d= -f2-
}

run_scale() {
    local n="$1"
    ( cd "$SANDBOX" && PATH="$WORK/bin:$PATH" HOME="$WORK/home" \
        bash "$SANDBOX/scripts/claude-docker" scale "$n" ) \
        >"$WORK/scale-$n.log" 2>&1
    echo "$?"
}

echo "== A scale the isolation contract rejects changes nothing =="

# Account C has no PROJECT_DIR_C, so worktree mode cannot support 4.
status="$(run_scale 4)"
assert_eq "scale 4 exits non-zero" "1" "$status"
assert_eq "NUM_ACCOUNTS is unchanged" "2" "$(num_accounts)"

# The state directories are created after the .env write in the original
# order, so their absence is a second, independent witness that the caller
# stopped before mutating anything.
for letter in c d; do
    if [[ -d "$WORK/home/.claude-state/account-$letter" ]]; then
        assert_eq "no account-$letter state directory was created" "absent" "present"
    else
        assert_eq "no account-$letter state directory was created" "absent" "absent"
    fi
done

# The message has to name the missing variable, or the user cannot act on it.
if grep -q 'PROJECT_DIR_C is required' "$WORK/scale-4.log"; then
    assert_eq "the rejection names the missing variable" "named" "named"
else
    assert_eq "the rejection names the missing variable" "named" "not named"
    sed 's/^/        /' "$WORK/scale-4.log"
fi

echo "== A scale the contract accepts still works =="

# Down to one account: worktree mode only needs PROJECT_DIR_A, so this is
# allowed and must not be blocked by the new check.
status="$(run_scale 1)"
assert_eq "scale 1 exits 0" "0" "$status"
assert_eq "NUM_ACCOUNTS became 1" "1" "$(num_accounts)"

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
