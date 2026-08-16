#!/usr/bin/env bash
# test_worktree_ownership.sh - which worktrees the removal steps may delete
# (issue #344).
#
# Run:  bash tests/test_worktree_ownership.sh
# Exits non-zero on any failure.
#
# remove.sh and cleanup.sh took "not the current directory" as the whole test,
# so a worktree the user added themselves was removed with --force and then
# rm -rf. cleanup.sh additionally read the porcelain output through
# `awk '{print $2}'`, truncating any path containing a space and then
# reporting the truncated path as removed.
#
# The subject is scripts/lib/worktrees.sh, which both scripts now route
# through, exercised against real `git worktree add` output rather than a
# fixture -- the space-truncation defect only exists in how git's real output
# is parsed. What is deliberately not covered here is the surrounding scripts:
# running remove.sh end to end needs docker, a populated .env and a HOME to
# clobber. The decision under test is the partition, and that is what runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/parse_env.sh
. "$PROJECT_ROOT/scripts/lib/parse_env.sh"
# shellcheck source=../scripts/lib/worktrees.sh
. "$PROJECT_ROOT/scripts/lib/worktrees.sh"

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

assert_dir_exists() {
    local label="$1" dir="$2"
    if [[ -d "$dir" ]]; then
        echo "  PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $label ($dir is gone)"
        FAIL=$((FAIL + 1))
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Fixture ------------------------------------------------------------------
# A project repository with three linked worktrees:
#   proj-a          installer-named ({project}-<letter>), and in .env
#   proj-clone      installer-created, recorded only as ISOLATED_WORKSPACE_A
#   my hotfix       user-added, path contains a space
#
# The space is in a *user* worktree on purpose: a parser that truncates at the
# first space would produce "$WORK/my" for it, which matches nothing, so the
# entry would be silently misclassified rather than obviously wrong.

PROJECT="$WORK/proj"
USER_WT="$WORK/my hotfix"
CLONE_WT="$WORK/proj-clone"

mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
git -C "$PROJECT" worktree add -q -b wt-a "$PROJECT-a"
git -C "$PROJECT" worktree add -q -b clone "$CLONE_WT"
git -C "$PROJECT" worktree add -q -b hotfix "$USER_WT"

ENV_FILE="$WORK/.env"
cat > "$ENV_FILE" <<EOF
PROJECT_DIR=$PROJECT
PROJECT_DIR_A=$PROJECT-a
ISOLATED_WORKSPACE_A=$CLONE_WT
EOF

# --- worktree_list_paths ------------------------------------------------------

echo "== worktree_list_paths =="

cd "$PROJECT"
listed_count=$(worktree_list_paths | wc -l | tr -d ' ')
assert_eq "reports every worktree (main + 3 linked)" "4" "$listed_count"

# The regression the awk parser caused: the path is emitted whole.
assert_eq "a path containing a space survives intact" \
    "$USER_WT" \
    "$(worktree_list_paths | grep 'hotfix')"

assert_eq "the main working tree is listed first" \
    "$PROJECT" \
    "$(worktree_list_paths | head -n 1)"

# --- worktree_selectable_paths ------------------------------------------------

echo "== worktree_selectable_paths =="

selectable=$(worktree_selectable_paths "$(pwd)")
assert_eq "the main tree is not selectable from itself" "" \
    "$(printf '%s\n' "$selectable" | grep -x -F "$PROJECT" || true)"
assert_eq "the three linked worktrees are selectable" "3" \
    "$(printf '%s\n' "$selectable" | grep -c . )"

# Standing in a linked worktree is the case where the caller's own path does
# not identify the repository at risk; the ordering guard is what covers it.
cd "$USER_WT"
from_linked=$(worktree_selectable_paths "$(pwd)")
assert_eq "the main tree is not selectable from a linked worktree" "" \
    "$(printf '%s\n' "$from_linked" | grep -x -F "$PROJECT" || true)"
assert_eq "the caller's own worktree excludes itself" "" \
    "$(printf '%s\n' "$from_linked" | grep -x -F "$USER_WT" || true)"
cd "$PROJECT"

# --- worktree_is_owned --------------------------------------------------------

echo "== worktree_is_owned =="

owned_or_not() {
    if worktree_is_owned "$1" "$PROJECT" "$ENV_FILE"; then echo "owned"; else echo "foreign"; fi
}

assert_eq "the {project}-<letter> worktree is ours" "owned"   "$(owned_or_not "$PROJECT-a")"
assert_eq "an ISOLATED_WORKSPACE path is ours"      "owned"   "$(owned_or_not "$CLONE_WT")"
assert_eq "a user-added worktree is not ours"       "foreign" "$(owned_or_not "$USER_WT")"

# A trailing slash is a spelling, not a different directory.
assert_eq "a trailing slash still matches" "owned" "$(owned_or_not "$PROJECT-a/")"

# remove.sh deletes .env in a later step than the worktrees, and installs
# predating the keys never had them, so the naming pattern has to stand alone.
if worktree_is_owned "$PROJECT-a" "$PROJECT" ""; then
    assert_eq "the naming pattern works without .env" "owned" "owned"
else
    assert_eq "the naming pattern works without .env" "owned" "foreign"
fi
if worktree_is_owned "$CLONE_WT" "$PROJECT" ""; then
    assert_eq "a clone path is not guessable without .env" "foreign" "owned"
else
    assert_eq "a clone path is not guessable without .env" "foreign" "foreign"
fi

# The suffix must be a letter run. "proj-2" and "proj-a-b" are not names this
# installer produces, and treating them as ours would widen the delete set.
assert_eq "a numeric suffix is not the naming pattern" "foreign" "$(owned_or_not "$PROJECT-2")"
assert_eq "a nested suffix is not the naming pattern"  "foreign" "$(owned_or_not "$PROJECT-a/sub")"

# The pattern must cover exactly what index_to_letter can emit and no more.
# normalize_account_count caps the count at 702 and index 702 is "zz", so two
# characters is the ceiling. A looser [a-z]+ claims "<project>-clone" and
# "<project>-hotfix" -- the user-created siblings this check exists to spare.
assert_eq "two letters (the generator's ceiling) are ours" "owned" \
    "$(owned_or_not "$PROJECT-zz")"
assert_eq "three letters exceed the generator's range" "foreign" \
    "$(owned_or_not "$PROJECT-abc")"
assert_eq "a word suffix is not the naming pattern" "foreign" \
    "$(owned_or_not "$PROJECT-hotfix")"

# --- The removal step, run over the partition ---------------------------------

echo "== removal over the partition =="

# Exactly what remove.sh now does, minus the prompt: partition, then remove
# only the owned side.
targets=()
skipped=()
while IFS= read -r wt; do
    [[ -d "$wt" ]] || continue
    if worktree_is_owned "$wt" "$PROJECT" "$ENV_FILE"; then
        targets+=("$wt")
    else
        skipped+=("$wt")
    fi
done < <(worktree_selectable_paths "$(pwd)")

assert_eq "two worktrees are targeted" "2" "${#targets[@]}"
assert_eq "one worktree is skipped"    "1" "${#skipped[@]}"
assert_eq "the skipped one is the user's" "$USER_WT" "${skipped[0]}"

for wt in "${targets[@]}"; do
    git worktree remove "$wt" --force 2>/dev/null || true
done

assert_dir_exists "the user's worktree survives"      "$USER_WT"
assert_dir_exists "the main repository survives"      "$PROJECT"
assert_dir_exists "the main repository keeps its .git" "$PROJECT/.git"
assert_eq "the installer worktree is gone" "absent" \
    "$([[ -d "$PROJECT-a" ]] && echo present || echo absent)"
assert_eq "the clone worktree is gone" "absent" \
    "$([[ -d "$CLONE_WT" ]] && echo present || echo absent)"

# --- Summary ------------------------------------------------------------------

echo ""
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
