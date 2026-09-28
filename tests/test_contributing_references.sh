#!/usr/bin/env bash
# test_contributing_references.sh - every path CONTRIBUTING.md names exists
# (issue #356, child 1).
#
# Run:  bash tests/test_contributing_references.sh
# Exits non-zero on any failure.
#
# CONTRIBUTING.md's argument is that a rule with copies and no check drifts.
# The document is itself such a copy: it lists the equivalence tests, the four
# implementation layers and the registry path, and a rename anywhere in the
# tree leaves it quietly naming something that is gone.
#
# Only referential integrity is checked -- that each path resolves. Whether
# the prose describes the file correctly is a review question, not a
# machine-checkable one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOC="$PROJECT_ROOT/CONTRIBUTING.md"
TEMPLATE="$PROJECT_ROOT/.github/pull_request_template.md"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

for required in "$DOC" "$TEMPLATE"; do
    if [ -f "$required" ]; then
        pass "$(basename "$required") exists"
    else
        fail "$(basename "$required") is missing"
    fi
done

if [ ! -f "$DOC" ]; then
    echo "  ERROR: cannot continue without CONTRIBUTING.md" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== every backticked repository path resolves ==="
# ---------------------------------------------------------------------------
#
# Backticked tokens that look like paths into this repository: they contain a
# slash and start with a known top-level directory or a tracked filename.
# Anything with a glob is expanded and required to match at least once, since
# `scripts/lib/*.sh` naming an empty set is the same failure as a dead path.

paths=$(grep -oE '`(scripts|tests|tui|docs|\.github)/[A-Za-z0-9_./*-]+`' "$DOC" \
    | tr -d '`' | sort -u)

count=$(printf '%s\n' "$paths" | grep -c '/')
if [ "$count" -lt 8 ]; then
    echo "  ERROR: found only $count paths; the check would be vacuous" >&2
    exit 1
fi
echo "  (checking $count referenced paths)"

for p in $paths; do
    case "$p" in
        *'*'*)
            # A glob: at least one match required.
            # shellcheck disable=SC2086 # reason: deliberate glob expansion
            matches=$(cd "$PROJECT_ROOT" && ls -d $p 2>/dev/null | wc -l | tr -d ' ')
            if [ "${matches:-0}" -gt 0 ]; then
                pass "$p matches $matches file(s)"
            else
                fail "$p matches nothing"
            fi
            ;;
        *)
            if [ -e "$PROJECT_ROOT/$p" ]; then
                pass "$p exists"
            else
                fail "$p does not exist"
            fi
            ;;
    esac
done

# ---------------------------------------------------------------------------
echo ""
echo "=== the PR template carries the parity checkbox ==="
# ---------------------------------------------------------------------------

# A heading, not a mention. The template's own intro comment points at the
# rule as well, so matching the phrase anywhere in the file would keep passing
# after the section itself had been deleted.
if grep -qiE '^#{1,4} .*cross-language parity' "$TEMPLATE"; then
    pass "template has a cross-language parity section"
else
    fail "template has no cross-language parity heading"
fi

if grep -q 'runtimes.json' "$TEMPLATE"; then
    pass "template points at the runtime registry"
else
    fail "template does not mention runtimes.json"
fi

if [ "$(grep -c '^- \[ \]' "$TEMPLATE")" -ge 5 ]; then
    pass "template has the expected checkboxes"
else
    fail "template is missing checkboxes"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
