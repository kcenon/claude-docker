#!/usr/bin/env bash
# test_bash32_portability.sh - the shell scripts run under bash 3.2
# (issues #348, #350).
#
# Run:  bash tests/test_bash32_portability.sh
# Exits non-zero on any failure.
#
# macOS ships bash 3.2 as /bin/bash and every host-side entry point is
# `#!/usr/bin/env bash`, so a bash 4+ construct is not a style question there:
# it is `bad substitution` and an exited shell. agent_runtime used
# `${runtime,,}`, and it is the single gate in front of every runtime-derived
# value, so `up`, `attach` and `ps` all failed on a stock macOS.
#
# Two things are asserted, and the second is the durable one:
#
#   1. The behaviour that expansion provided -- case normalization -- still
#      happens. A fix that dropped it would look correct and quietly break
#      AGENT_RUNTIME=Codex.
#   2. No bash 4+ construct has come back. The repository knew about this
#      constraint before the defect shipped, but the knowledge lived in one
#      comment in one test script. A grep that fails CI is knowledge the next
#      change cannot walk past.
#
# This runs on Linux as well as macOS. The inventory guard is what keeps a
# bash 4 idiom from landing between macOS runs, and it costs nothing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' \
            "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "== Running under bash ${BASH_VERSION%%(*} =="

# --- 1. Case normalization survives ------------------------------------------

echo "== agent_runtime normalizes case =="

export PROJECT_ROOT
# shellcheck source=../scripts/lib/parse_env.sh
. "$PROJECT_ROOT/scripts/lib/parse_env.sh"
# shellcheck source=../scripts/lib/runtime.sh
. "$PROJECT_ROOT/scripts/lib/runtime.sh"

# The registry keys are lowercase, so a mixed-case value has to be folded
# before it is looked up. Each of these would fail validation unfolded.
for spelling in Codex CODEX cOdEx; do
    actual="$(AGENT_RUNTIME="$spelling" agent_runtime 2>&1)"
    assert_eq "AGENT_RUNTIME=$spelling resolves to codex" "codex" "$actual"
done

assert_eq "an already-lowercase value is unchanged" "gemini" \
    "$(AGENT_RUNTIME=gemini agent_runtime 2>&1)"
assert_eq "an unset value defaults to claude" "claude" \
    "$(AGENT_RUNTIME='' agent_runtime 2>&1)"

# Folding must not turn an unknown runtime into a known one, or a typo would
# silently select the wrong agent.
if AGENT_RUNTIME=Bogus agent_runtime >/dev/null 2>&1; then
    fail "an unknown runtime is still rejected after folding"
else
    pass "an unknown runtime is still rejected after folding"
fi

# --- 2. No bash 4+ construct has come back ------------------------------------

echo "== no bash 4+ construct in the shell sources =="

# Each entry is "description<TAB>extended-regex". Kept as a list rather than
# one alternation so a hit names which construct was found.
#
# ${!arr[@]} is deliberately absent: indexed-array key expansion is bash 3.0
# and is used throughout.
check_construct() {
    local label="$1" pattern="$2"
    local hits
    # Whole-line comments are dropped from the results. The comments that
    # record why a construct was removed have to name the construct, and a
    # guard that fires on its own explanation teaches the next person to
    # delete the explanation. Only lines that *begin* with # are dropped, so a
    # code line carrying a trailing comment is still scanned: the filter can
    # miss prose, never code.
    hits=$(find "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/tests" \
                -type f \( -name '*.sh' -o -name 'claude-docker' \) \
                ! -name 'test_bash32_portability.sh' \
                -exec grep -nE "$pattern" {} + 2>/dev/null \
           | grep -vE ':[0-9]+:[[:space:]]*#')
    if [ -z "$hits" ]; then
        pass "no $label"
    else
        printf '  FAIL  %s found:\n' "$label"
        printf '%s\n' "$hits" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}

# Case-modifying parameter expansion, bash 4.0.
check_construct 'case-modifying expansion (${v,,} / ${v^^})' \
    '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^|,|\^)\}'
# Parameter transformation, bash 4.4.
check_construct 'parameter transformation (${v@U})' \
    '\$\{[A-Za-z_][A-Za-z0-9_]*@[UuLQEPAKak]\}'
# Associative arrays, bash 4.0.
check_construct 'associative array declaration' \
    '(declare|local|typeset)[[:space:]]+(-[A-Za-z]*A[A-Za-z]*)[[:space:]]'
# Reading a stream into an array, bash 4.0.
check_construct 'mapfile / readarray' '\b(mapfile|readarray)\b'
# Namerefs, bash 4.3.
check_construct 'nameref declaration' \
    '(declare|local|typeset)[[:space:]]+(-[A-Za-z]*n[A-Za-z]*)[[:space:]]'
# Append-both-streams redirect, bash 4.0.
check_construct 'the &>> redirect' '&>>'
# case fallthrough operators, bash 4.0.
check_construct 'case fallthrough (;& / ;;&)' ';;?&'
# coprocesses, bash 4.0.
check_construct 'coproc' '^[[:space:]]*coproc[[:space:]]'
# Waiting for any one job, bash 4.3.
check_construct 'wait -n' '\bwait[[:space:]]+-n\b'
# printf time formatting, bash 4.2.
check_construct "printf '%(...)T'" "printf[^\\n]*%\\("

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
