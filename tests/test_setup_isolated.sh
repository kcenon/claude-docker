#!/usr/bin/env bash
# test_setup_isolated.sh - scripts/setup-isolated.sh (issue #354, item 5).
#
# Run:  bash tests/test_setup_isolated.sh
# Exits non-zero on any failure.
#
# Nothing executed this script. It creates the workspaces that make
# ISOLATION_MODE=isolated an isolation mode at all, and its two load-bearing
# details had zero coverage:
#
#   * `git clone --no-hardlinks`. Cloning a local path hardlinks the object
#     store by default, which would leave every account sharing objects --
#     exactly the property that disqualifies worktree mode as a security
#     boundary. Drop the flag and isolated mode silently becomes worktree mode
#     with extra steps, and every YAML-level assertion in the suite still
#     passes.
#   * The credential strip in repoint_origin. The clone's origin points at the
#     source path, which the container cannot see, so it is repointed at the
#     source's own upstream -- and a token embedded in that URL would be
#     copied into N clones.
#
# Everything here runs on local repositories in a temp directory; no network,
# no docker, no container.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP="$PROJECT_ROOT/scripts/setup-isolated.sh"

PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' \
            "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GIT_ID=(-c user.email=t@e -c user.name=t)

make_source_repo() {
    local dir="$1" origin="${2:-}"
    mkdir -p "$dir"
    git -C "$dir" init -q
    printf 'tracked\n' > "$dir/tracked.txt"
    git -C "$dir" add tracked.txt
    git -C "$dir" "${GIT_ID[@]}" commit -q -m init
    # An untracked secret, to confirm the clone does not carry it.
    printf 'CLAUDE_API_KEY_A=placeholder-not-a-key\n' > "$dir/untracked-secret.txt"
    if [[ -n "$origin" ]]; then
        git -C "$dir" remote add origin "$origin"
    fi
}

echo "== A non-git source is refused =="

mkdir -p "$WORK/not-a-repo"
out="$(bash "$SETUP" "$WORK/not-a-repo" 2 2>&1)"; status=$?
assert_eq "exits non-zero" "1" "$status"
case "$out" in
    *"is not a git repository"*) pass "the message says why" ;;
    *) fail "the message says why" "$out" ;;
esac

echo "== An out-of-range account count is refused =="

make_source_repo "$WORK/range" "https://example.invalid/o/r.git"
out="$(bash "$SETUP" "$WORK/range" 703 2>&1)"; status=$?
assert_eq "exits non-zero for 703" "1" "$status"
case "$out" in
    *"between 1 and 702"*) pass "the message names the range" ;;
    *) fail "the message names the range" "$out" ;;
esac

echo "== Clones are independent, not hardlinked =="

SRC="$WORK/proj"
make_source_repo "$SRC" "https://example.invalid/owner/repo.git"
bash "$SETUP" "$SRC" 2 >"$WORK/setup.log" 2>&1
setup_status=$?
assert_eq "setup-isolated.sh exits 0" "0" "$setup_status"
if [[ "$setup_status" -ne 0 ]]; then
    sed 's/^/        /' "$WORK/setup.log"
fi

for letter in a b; do
    target="$SRC-isolated-$letter"
    if [[ -d "$target/.git" ]]; then
        pass "clone $letter exists"
    else
        fail "clone $letter exists" "$target"
        continue
    fi

    # The property that separates isolated from worktree: no shared object
    # store. `git worktree` leaves one; an alternates file would reintroduce
    # it through the back door.
    if [[ -e "$target/.git/objects/info/alternates" ]]; then
        fail "clone $letter has no alternates file" \
            "$(cat "$target/.git/objects/info/alternates")"
    else
        pass "clone $letter has no alternates file"
    fi
done

# --no-hardlinks, asserted by link count rather than by reading the flag out
# of the source. A hardlinked object has st_nlink > 1; an independent copy
# has exactly 1. This is the assertion that fails if someone drops the flag.
shared=0
while IFS= read -r obj; do
    links="$(stat -c '%h' "$obj" 2>/dev/null || echo 1)"
    [[ "$links" -gt 1 ]] && shared=$((shared + 1))
done < <(find "$SRC-isolated-a/.git/objects" -type f 2>/dev/null)
assert_eq "no object in clone a is hardlinked to another file" "0" "$shared"

# An untracked file is not part of the repository, so a clone must not carry
# it. That is what keeps a stray .env out of N workspaces.
if [[ -e "$SRC-isolated-a/untracked-secret.txt" ]]; then
    fail "the untracked file did not travel into the clone" "it did"
else
    pass "the untracked file did not travel into the clone"
fi

echo "== origin is repointed at the source's upstream =="

assert_eq "clone a points at the upstream, not the local path" \
    "https://example.invalid/owner/repo.git" \
    "$(git -C "$SRC-isolated-a" remote get-url origin)"

echo "== Credentials embedded in the origin URL are stripped =="

CRED="$WORK/cred"
make_source_repo "$CRED" "https://user:placeholder-token@example.invalid/owner/repo.git"
bash "$SETUP" "$CRED" 1 >"$WORK/cred.log" 2>&1
cred_origin="$(git -C "$CRED-isolated-a" remote get-url origin)"
assert_eq "the userinfo is gone" \
    "https://example.invalid/owner/repo.git" "$cred_origin"
case "$cred_origin" in
    *placeholder-token*) fail "the token is not in the clone's origin" "$cred_origin" ;;
    *) pass "the token is not in the clone's origin" ;;
esac

# An SSH URL puts the *user* in the same position, and it is not a secret --
# stripping it would break authentication.
SSHSRC="$WORK/sshsrc"
make_source_repo "$SSHSRC" "ssh://git@example.invalid/owner/repo.git"
bash "$SETUP" "$SSHSRC" 1 >"$WORK/ssh.log" 2>&1
assert_eq "an ssh:// user survives" \
    "ssh://git@example.invalid/owner/repo.git" \
    "$(git -C "$SSHSRC-isolated-a" remote get-url origin)"

SCPSRC="$WORK/scpsrc"
make_source_repo "$SCPSRC" "git@example.invalid:owner/repo.git"
bash "$SETUP" "$SCPSRC" 1 >"$WORK/scp.log" 2>&1
assert_eq "an scp-style user survives" \
    "git@example.invalid:owner/repo.git" \
    "$(git -C "$SCPSRC-isolated-a" remote get-url origin)"

echo "== A source with no origin is handled, not aborted =="

NOORIGIN="$WORK/noorigin"
make_source_repo "$NOORIGIN"
bash "$SETUP" "$NOORIGIN" 1 >"$WORK/noorigin.log" 2>&1
assert_eq "exits 0 without an origin remote" "0" "$?"
case "$(cat "$WORK/noorigin.log")" in
    *"no origin remote"*) pass "the note explains the local-path origin" ;;
    *) fail "the note explains the local-path origin" "$(cat "$WORK/noorigin.log")" ;;
esac

echo "== Re-running leaves existing clones alone =="

# Idempotency matters because a re-run must not discard whatever an account
# has been working on.
printf 'work in progress\n' > "$SRC-isolated-a/wip.txt"
bash "$SETUP" "$SRC" 2 >"$WORK/rerun.log" 2>&1
assert_eq "the re-run exits 0" "0" "$?"
if [[ -f "$SRC-isolated-a/wip.txt" ]]; then
    pass "uncommitted work in an existing clone survives"
else
    fail "uncommitted work in an existing clone survives" "wip.txt was destroyed"
fi
case "$(cat "$WORK/rerun.log")" in
    *"already a clone, left unchanged"*) pass "the re-run says it skipped" ;;
    *) fail "the re-run says it skipped" "$(cat "$WORK/rerun.log")" ;;
esac

echo "== A non-git path in the way is refused, not deleted =="

BLOCKED="$WORK/blocked"
make_source_repo "$BLOCKED"
mkdir -p "$BLOCKED-isolated-a"
printf 'do not delete me\n' > "$BLOCKED-isolated-a/precious.txt"
out="$(bash "$SETUP" "$BLOCKED" 1 2>&1)"; status=$?
assert_eq "exits non-zero" "1" "$status"
if [[ -f "$BLOCKED-isolated-a/precious.txt" ]]; then
    pass "the pre-existing directory is left untouched"
else
    fail "the pre-existing directory is left untouched" "precious.txt is gone"
fi
case "$out" in
    *"never deletes host paths"*) pass "the message says it will not delete" ;;
    *) fail "the message says it will not delete" "$out" ;;
esac

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
