#!/usr/bin/env bash
# test_account_index_equivalence.sh - the bash and PowerShell account-index
# helpers agree (issue #356, rows 1 and 2).
#
# Run:  bash tests/test_account_index_equivalence.sh
# Exits non-zero on any failure.
#
# scripts/lib/index.sh has declared itself the shared definition of these
# rules since it was written, and scripts/lib/index.ps1 has called itself its
# mirror. Nothing compared them. The mirror shipped two of the three functions
# index.sh declares shared, so the 1..702 bound was re-spelled in four other
# PowerShell files -- and ClaudeDocker.psm1 carried a third letter
# implementation, ConvertTo-AccountLetter, that guarded only the lower bound.
#
# What is compared here is behavior on the same inputs, not the presence of a
# literal in a source file. A grep for `702` passes for a constant that is
# never applied; these run both implementations and diff the answers.
#
# The Go reader is not included: config.IndexToLetter is covered by the Go
# suite, and its out-of-range contract deliberately differs (see the
# out-of-range note below).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/index.sh
. "$PROJECT_ROOT/scripts/lib/index.sh"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; echo "        bash: $2"; echo "        pwsh: $3"; FAIL=$((FAIL + 1)); }

if ! command -v pwsh >/dev/null 2>&1; then
    echo "SKIP: pwsh not available; this suite compares two implementations" >&2
    exit 0
fi

INDEX_PS1="$PROJECT_ROOT/scripts/lib/index.ps1"

# One pwsh process for the whole comparison. Starting one per case turned a
# two-second suite into a two-minute one.
run_pwsh() {
    pwsh -NoProfile -Command "
        . '$INDEX_PS1'
        $1
    " 2>/dev/null | tr -d '\r'
}

# ---------------------------------------------------------------------------
echo "=== the bound is one value ==="
# ---------------------------------------------------------------------------

bash_max=$(max_account_count)
pwsh_max=$(run_pwsh 'Get-MaxAccountCount')
if [ "$bash_max" = "$pwsh_max" ]; then
    pass "max_account_count == Get-MaxAccountCount ($bash_max)"
else
    fail "the two languages disagree on the bound" "$bash_max" "$pwsh_max"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== normalize_account_count == Get-NormalizedAccountCount ==="
# ---------------------------------------------------------------------------
#
# Leading zeros are the interesting half: the bash regex is
# ^0*([0-9]{1,3})$ followed by a 10#-prefixed range test, so "008" is 8 while
# "0000" is 0 and rejected, and four significant digits never match at all.
#
# The last two cases are why the PowerShell side mirrors that regex instead of
# casting. `^[0-9]+$` plus [int] agrees with bash on every other value here --
# but a digit string too large for Int32 makes the cast *throw*, where bash
# returns a plain rejection. A pasted number should be refused, not crash the
# installer, and a mutation swapping the regex for a cast is invisible without
# them.
COUNT_CASES=(1 2 26 27 702 703 0 -1 1000 008 007 0000 0702 00702 0000008 abc "" " " 1.5 "2 " +3 999 2600 "07" "1 2" 99999999999 12345678901234567890)

# Build one script that prints every answer, so pwsh starts once.
#
# $r is reset and the call is wrapped, because a throw is a distinct outcome
# from a rejection and has to be reported as one. Without the reset, a
# throwing call leaves $r holding the *previous* case's value and the line
# still prints -- so a validator that crashes on a large number reads as
# whatever the case before it returned. That is how the first version of this
# suite passed a mutation that replaced the regex with an [int] cast.
ps_script=''
for v in "${COUNT_CASES[@]}"; do
    escaped=${v//\'/\'\'}
    ps_script+="\$r = \$null
try { \$r = Get-NormalizedAccountCount -Value '$escaped' } catch { \$r = 'THROW' }
if (\$null -eq \$r) { 'REJECT' } else { \$r }
"
done
mapfile_out=$(run_pwsh "$ps_script")

i=0
while IFS= read -r pwsh_answer; do
    v="${COUNT_CASES[$i]}"
    if bash_answer=$(normalize_account_count "$v" 2>/dev/null); then :; else bash_answer="REJECT"; fi
    if [ "$bash_answer" = "$pwsh_answer" ]; then
        pass "normalize [$v] -> $bash_answer"
    else
        fail "normalize [$v]" "$bash_answer" "$pwsh_answer"
    fi
    i=$((i + 1))
done <<< "$mapfile_out"

if [ "$i" -ne "${#COUNT_CASES[@]}" ]; then
    echo "  ERROR: compared $i of ${#COUNT_CASES[@]} cases; pwsh output was truncated" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== index_to_letter / index_to_upper == Get-AccountLetter / Upper ==="
# ---------------------------------------------------------------------------
#
# Boundaries of each letter regime plus the two ends: 26/27 is the
# single-to-double transition, 52 closes the "a" row, 702 is "zz".

LETTER_CASES=(1 2 25 26 27 28 52 53 78 260 676 677 701 702)

ps_script=''
for n in "${LETTER_CASES[@]}"; do
    ps_script+="\"\$(Get-AccountLetter -Index $n) \$(Get-AccountLetterUpper -Index $n)\"
"
done
letters_out=$(run_pwsh "$ps_script")

i=0
while IFS= read -r line; do
    n="${LETTER_CASES[$i]}"
    pwsh_lower="${line%% *}"
    pwsh_upper="${line##* }"
    bash_lower=$(index_to_letter "$n")
    bash_upper=$(index_to_upper "$n")
    if [ "$bash_lower" = "$pwsh_lower" ] && [ "$bash_upper" = "$pwsh_upper" ]; then
        pass "index $n -> $bash_lower / $bash_upper"
    else
        fail "index $n" "$bash_lower / $bash_upper" "$pwsh_lower / $pwsh_upper"
    fi
    i=$((i + 1))
done <<< "$letters_out"

if [ "$i" -ne "${#LETTER_CASES[@]}" ]; then
    echo "  ERROR: compared $i of ${#LETTER_CASES[@]} cases; pwsh output was truncated" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== ConvertTo-AccountLetter is gone ==="
# ---------------------------------------------------------------------------
#
# It was a third implementation of the same conversion, differing from
# Get-AccountLetter in exactly one respect: it guarded only the lower bound,
# so index 703 returned "aaa" through the module and threw through the
# library. Removed in #356; this keeps it from coming back.

if grep -rn 'function ConvertTo-AccountLetter' "$PROJECT_ROOT/scripts" >/dev/null 2>&1; then
    fail "ConvertTo-AccountLetter is defined again" "n/a" "found in scripts/"
else
    pass "no second letter implementation in scripts/"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== the 1..702 rule is spelled once per language ==="
# ---------------------------------------------------------------------------
#
# Comments may name the number -- explaining a bound is not re-implementing
# it. Code may not: that is what put the literal in four PowerShell files.
# A line is treated as code unless it is entirely a comment.

ps_files=$(find "$PROJECT_ROOT/scripts" -name '*.ps1' -o -name '*.psm1' | sort)
offenders=""
for f in $ps_files; do
    case "$f" in
        */lib/index.ps1) continue ;;  # the one definition
    esac
    hits=$(grep -nE '(^|[^0-9])702([^0-9]|$)' "$f" | grep -vE '^[0-9]+: *#' || true)
    if [ -n "$hits" ]; then
        offenders="${offenders}${f}:
${hits}
"
    fi
done

if [ -z "$offenders" ]; then
    pass "no PowerShell file outside lib/index.ps1 spells the bound in code"
else
    echo "  FAIL  the bound is re-spelled outside lib/index.ps1:"
    printf '%s' "$offenders" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$PASS" -eq 0 ]; then
    echo "  ERROR: no assertions ran" >&2
    exit 1
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
