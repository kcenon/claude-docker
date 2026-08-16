#!/usr/bin/env bash
# test_workflow_contracts.sh - properties the release workflow has to keep
# (issue #352).
#
# Run:  bash tests/test_workflow_contracts.sh
# Exits non-zero on any failure.
#
# workflow_dispatch on release-tui.yml published binaries built from the
# dispatch branch while naming the release after inputs.tag, so the tag no
# longer identified the code it shipped. Two halves of one file disagreed: the
# publish step read `inputs.tag || github.ref_name` while the build step read
# `${GITHUB_REF_NAME:-inputs.tag}` -- and GITHUB_REF_NAME is always set in
# Actions, so the input never won there. The build checkout had no `ref:` at
# all.
#
# A workflow cannot be unit-tested without dispatching it, and dispatching a
# release is not something a test can do. These assertions are therefore about
# the file: the shapes whose absence caused the defect. They are grep-based
# rather than YAML-parsed so the suite keeps its zero external dependencies;
# each pattern is anchored tightly enough that a reformat is more likely to
# fail loudly than to pass wrongly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOWS="$PROJECT_ROOT/.github/workflows"
RELEASE="$WORKFLOWS/release-tui.yml"
CI="$WORKFLOWS/ci.yml"

PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# assert_matches LABEL FILE PATTERN
assert_matches() {
    local label="$1" file="$2" pattern="$3"
    if grep -qE "$pattern" "$file"; then
        pass "$label"
    else
        fail "$label" "no line in $(basename "$file") matches: $pattern"
    fi
}

# assert_absent LABEL FILE PATTERN
# Whole-line YAML comments are excluded from the result. The comments that
# record why a shape was removed have to name it, and a guard that fires on
# its own explanation teaches the next person to delete the explanation. Only
# lines whose first non-blank character is # are dropped, so a value carrying
# a trailing comment is still checked.
assert_absent() {
    local label="$1" file="$2" pattern="$3"
    local hit
    hit=$(grep -nE "$pattern" "$file" | grep -vE '^[0-9]+: *#' | head -n 3)
    if [[ -z "$hit" ]]; then
        pass "$label"
    else
        fail "$label" "$(printf '%s' "$hit" | tr '\n' ' ')"
    fi
}

for f in "$RELEASE" "$CI"; do
    if [[ ! -r "$f" ]]; then
        fail "workflow exists" "$f"
        echo "== Summary: PASS=$PASS FAIL=$FAIL =="
        exit 1
    fi
done

echo "== release-tui.yml builds the tag it names =="

# The line whose absence let a release ship code from a branch.
assert_matches 'the build checkout pins a ref' "$RELEASE" \
    '^ +ref: \$\{\{ needs\.resolve-tag\.outputs\.tag \}\}'

# The stamp and the tree must come from the same value.
assert_matches 'the version stamp uses the resolved tag' "$RELEASE" \
    '^ +TAG: \$\{\{ needs\.resolve-tag\.outputs\.tag \}\}'
assert_matches 'the release is named with the resolved tag' "$RELEASE" \
    '^ +tag_name: \$\{\{ needs\.resolve-tag\.outputs\.tag \}\}'

# The reversed precedence that made the input unreachable.
assert_absent 'no ${GITHUB_REF_NAME:-...} fallback remains' "$RELEASE" \
    'GITHUB_REF_NAME:-'

echo "== the tag input is validated before anything is built =="

assert_matches 'the tag is matched against a version pattern' "$RELEASE" \
    '\^v\[0-9\]\[0-9A-Za-z\.-\]\*\$'
assert_matches 'the tag is verified to exist' "$RELEASE" \
    'git rev-parse --verify'
assert_matches 'build waits on the resolver' "$RELEASE" \
    '^ +needs: resolve-tag$'

echo "== inputs.tag never reaches a run: body =="

# Interpolating an input into a script is the injection shape even when the
# dispatcher already has write access. Every use must go through step env:.
# The one legitimate occurrence is the env: assignment itself, and the two
# workflow-level expressions (concurrency group, publish precedence), none of
# which is inside a run body -- so the check is that no `run` line carries it.
inline=$(grep -nE '\$\{\{ *inputs\.tag *\}\}' "$RELEASE" \
         | grep -vE 'INPUT_TAG:|concurrency|group:' | head -n 5)
if [[ -z "$inline" ]]; then
    pass 'inputs.tag appears only in env: and the concurrency group'
else
    fail 'inputs.tag appears only in env: and the concurrency group' \
        "$(printf '%s' "$inline" | tr '\n' ' ')"
fi

echo "== the write token is scoped to the job that writes =="

# The workflow-level default, read from the line immediately after the
# top-level `permissions:` key rather than from anywhere in the file -- a
# `contents: read` nested under some job would otherwise satisfy a loose grep.
default_perm=$(grep -A1 -E '^permissions:$' "$RELEASE" | tail -n 1)
if [[ "$default_perm" =~ ^[[:space:]]+contents:[[:space:]]read$ ]]; then
    pass 'release-tui.yml defaults to contents: read'
else
    fail 'release-tui.yml defaults to contents: read' "got: $default_perm"
fi

# contents: write must appear exactly once, and under the release job.
write_count=$(grep -cE '^ +contents: write$' "$RELEASE")
if [[ "$write_count" -eq 1 ]]; then
    pass 'contents: write is declared exactly once'
else
    fail 'contents: write is declared exactly once' "found $write_count"
fi

echo "== the workflow serializes on the tag =="

assert_matches 'release-tui.yml declares a concurrency group' "$RELEASE" \
    '^ +group: release-tui-'

echo "== every test file is registered in a CI matrix =="

# The two matrices are hand-maintained lists with nothing checking that they
# cover the suite. A test file added and not registered is a file that runs
# nowhere, and looks exactly like one that passes (#354, item 12).
#
# scripts/test-*.sh are entry points rather than tests/ members, so they are
# listed explicitly here too -- test-concurrent-git.sh was registered nowhere,
# which is why a defect that made it abort on its first container start went
# unnoticed.
# "Registered" means some job runs it, not that it sits in a matrix:
# test_github_account_selection.ps1 is invoked by a `run:` line in the
# windows-latest job, which counts.
#
# Comment lines are excluded. ci.yml's own prose names several test files --
# the macOS job explains which ones it leaves out and why -- and a comment
# mentioning a test is the opposite of that test being run.
#
# The comment-stripped file is materialized once and matched with a case glob
# rather than piped into `grep -q`. Under `set -o pipefail`, grep -q exits on
# its first match, the upstream grep dies of SIGPIPE (141), and the pipeline
# status is that 141 -- so every lookup reported "not found".
CI_CODE="$(grep -vE '^[[:space:]]*#' "$CI")"
is_registered() {
    case "$CI_CODE" in
        *"$1"*) return 0 ;;
    esac
    return 1
}

unregistered=()
while IFS= read -r f; do
    rel="tests/$(basename "$f")"
    is_registered "$rel" || unregistered+=("$rel")
done < <(find "$PROJECT_ROOT/tests" -maxdepth 1 \( -name '*.sh' -o -name '*.ps1' \) -type f | sort)

if [[ ${#unregistered[@]} -eq 0 ]]; then
    pass 'every tests/*.sh and tests/*.ps1 appears in a ci.yml matrix'
else
    fail 'every tests/*.sh and tests/*.ps1 appears in a ci.yml matrix' \
        "${unregistered[*]}"
fi

# And the reverse: a matrix entry naming a file that no longer exists would
# fail the job with "No such file", but only when that entry runs -- which is
# after every other job has already spent its time.
missing=()
while IFS= read -r rel; do
    [[ -f "$PROJECT_ROOT/$rel" ]] || missing+=("$rel")
done < <(grep -oE '^ +- (tests|scripts)/[A-Za-z0-9_.-]+\.(sh|ps1)$' "$CI" | sed 's/^ *- //' | sort -u)

if [[ ${#missing[@]} -eq 0 ]]; then
    pass 'every matrix entry names a file that exists'
else
    fail 'every matrix entry names a file that exists' "${missing[*]}"
fi

echo "== ci.yml declares a read-only token =="

assert_matches 'ci.yml declares workflow-level permissions' "$CI" \
    '^permissions:$'
assert_matches 'ci.yml grants only contents: read' "$CI" \
    '^ +contents: read$'
assert_absent 'ci.yml grants no write scope' "$CI" \
    '^ +[a-z-]+: write$'

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
