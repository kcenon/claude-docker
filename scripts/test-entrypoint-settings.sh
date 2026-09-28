#!/bin/bash
# test-entrypoint-settings.sh
# Integration test for the entrypoint settings.json transformation.
# Tests that both macOS and Windows host settings are correctly converted
# to container-compatible settings.
#
# Usage: ./scripts/test-entrypoint-settings.sh [path-to-claude-config]
# Default: assumes ../claude-config/ relative to this script's parent dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Resolution order:
#   1. Explicit positional argument (developer override).
#   2. The in-repo fixture under tests/entrypoint_fixtures/global.
#   3. ../claude-config/global relative to the repo, if the fixture is gone.
#
# The fixture used to be selected only when $GITHUB_ACTIONS was set, so a
# developer with a claude-config checkout alongside this repo ran the suite
# against *their own configuration* while CI ran it against the fixture. The
# two asserted different inputs, and only one of them was reviewable -- which
# is why this file could carry an assertion anchored to the wrong deny list
# and still pass locally (#354, item 7).
#
# The fixture is the default now. Pass a path as $1 to check a real config.
if [ -n "${1:-}" ]; then
    CLAUDE_CONFIG="$1"
elif [ -d "$PROJECT_ROOT/tests/entrypoint_fixtures/global" ]; then
    CLAUDE_CONFIG="$PROJECT_ROOT/tests/entrypoint_fixtures/global"
else
    CLAUDE_CONFIG="$(cd "$SCRIPT_DIR/../.." && pwd)/claude-config/global"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC}: $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_zero() {
    local desc="$1" actual="$2"
    if [ "$actual" = "0" ]; then
        echo -e "  ${GREEN}PASS${NC}: $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $desc (got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_nonzero() {
    local desc="$1" actual="$2"
    if [ "$actual" != "0" ] && [ -n "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC}: $desc (got $actual)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $desc (expected nonzero)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Load transformation function from the claude bootstrap module ---
# generate_container_settings moved out of entrypoint.sh into the per-runtime
# bootstrap module scripts/lib/bootstrap-claude.sh (issue #269). Source only
# the function definition, not the full module logic.
eval "$(sed -n '/^generate_container_settings()/,/^}/p' "$SCRIPT_DIR/lib/bootstrap-claude.sh")"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to run these tests"
    exit 1
fi

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ============================================================================
echo "=== Test Suite 1: macOS settings (settings.json) ==="
# ============================================================================

MACOS_SETTINGS="$CLAUDE_CONFIG/settings.json"
if [ ! -f "$MACOS_SETTINGS" ]; then
    echo "SKIP: $MACOS_SETTINGS not found"
else
    OUT="$TMPDIR_TEST/macos-container.json"
    generate_container_settings "$MACOS_SETTINGS" "$OUT"

    # sandbox disabled
    val=$(jq -r '.sandbox.enabled' "$OUT")
    assert_eq "sandbox.enabled = false" "false" "$val"

    # The deny-rule filter, asserted against the set that must survive rather
    # than by re-applying the filter's own predicate.
    #
    # This used to count `select(test("[*]"))` survivors and require zero --
    # the same expression generate_container_settings uses to remove them, so
    # the assertion could not disagree with the implementation. A filter whose
    # regex matched nothing at all would satisfy it (#354, item 7).
    #
    # The fixture's deny list is:
    #   Read(./.env*)            file-tool glob -> removed
    #   Read(./secrets/**)       file-tool glob -> removed
    #   Read(./.aws/credentials) plain          -> kept
    #   Bash(rm -rf /)           plain          -> kept
    #
    # This fixture carries no asterisk-bearing Bash or WebFetch rule, so it
    # cannot tell the narrowed filter from the old catch-all one. Suite 4 does.
    expected_deny='["Read(./.aws/credentials)","Bash(rm -rf /)"]'
    actual_deny=$(jq -c '.permissions.deny' "$OUT")
    assert_eq "permissions.deny keeps exactly the non-glob rules" \
        "$expected_deny" "$actual_deny"

    # no pwsh anywhere
    pwsh_count=$(jq '[.. | strings | select(test("pwsh"))] | length' "$OUT")
    assert_zero "no pwsh references" "$pwsh_count"

    # all hook commands end in .sh
    non_sh=$(jq '[.. | objects | .command? // empty | select(test("\\.(ps1|exe)$"))] | length' "$OUT")
    assert_zero "all hook commands use .sh" "$non_sh"

    # statusLine uses .sh
    sl=$(jq -r '.statusLine.command' "$OUT")
    # shellcheck disable=SC2088 # reason: literal ~/.claude string compared against JSON value; no tilde expansion desired
    assert_eq "statusLine uses .sh script" "~/.claude/scripts/statusline-command.sh" "$sl"

    # conflict-guard.sh present (macOS-only hook)
    cg=$(jq '[.. | objects | .command? // empty | select(test("conflict-guard"))] | length' "$OUT")
    assert_nonzero "conflict-guard.sh present (macOS)" "$cg"

    # valid JSON
    if jq empty "$OUT" 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: output is valid JSON"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: output is not valid JSON"
        FAIL=$((FAIL + 1))
    fi
fi

# ============================================================================
echo ""
echo "=== Test Suite 2: Windows settings (settings.windows.json) ==="
# ============================================================================

WIN_SETTINGS="$CLAUDE_CONFIG/settings.windows.json"
if [ ! -f "$WIN_SETTINGS" ]; then
    echo "SKIP: $WIN_SETTINGS not found"
else
    OUT="$TMPDIR_TEST/windows-container.json"
    generate_container_settings "$WIN_SETTINGS" "$OUT"

    # sandbox disabled
    val=$(jq -r '.sandbox.enabled' "$OUT")
    assert_eq "sandbox.enabled = false" "false" "$val"

    # Same deny list as the macOS fixture, asserted the same way. The old form
    # counted every surviving rule containing `*` and required zero, which
    # states the pre-#357 contract; the contract now is that only *file-tool*
    # globs go.
    expected_deny='["Read(./.aws/credentials)","Bash(rm -rf /)"]'
    actual_deny=$(jq -c '.permissions.deny' "$OUT")
    assert_eq "permissions.deny keeps exactly the non-glob rules" \
        "$expected_deny" "$actual_deny"

    # no pwsh anywhere
    pwsh_count=$(jq '[.. | strings | select(test("pwsh"))] | length' "$OUT")
    assert_zero "no pwsh references" "$pwsh_count"

    # all hook commands end in .sh
    non_sh=$(jq '[.. | objects | .command? // empty | select(test("\\.(ps1|exe)$"))] | length' "$OUT")
    assert_zero "all hook commands use .sh" "$non_sh"

    # statusLine uses .sh
    sl=$(jq -r '.statusLine.command' "$OUT")
    # shellcheck disable=SC2088 # reason: literal ~/.claude string compared against JSON value; no tilde expansion desired
    assert_eq "statusLine uses .sh script" "~/.claude/scripts/statusline-command.sh" "$sl"

    # conflict-guard absent (excluded in Windows source)
    cg=$(jq '[.. | objects | .command? // empty | select(test("conflict-guard"))] | length' "$OUT")
    assert_zero "conflict-guard absent (Windows)" "$cg"

    # SessionEnd compound command correctly converted.
    #
    # The separator stays `; `. This assertion previously expected ` && `,
    # pinning `gsub("; "; " && ")` as correct -- but that turns two sequential
    # statements into exit-code-dependent ones, so cleanup stopped running
    # whenever session-logger failed (#357, item 3a). The pwsh source separates
    # these with `;`, and `;` is what bash spells the same thing.
    se=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$OUT")
    # shellcheck disable=SC2088 # reason: literal ~/.claude strings compared against JSON value; no tilde expansion desired
    assert_eq "SessionEnd compound command stays sequential" "~/.claude/hooks/session-logger.sh end; ~/.claude/hooks/cleanup.sh" "$se"

    # valid JSON
    if jq empty "$OUT" 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC}: output is valid JSON"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: output is not valid JSON"
        FAIL=$((FAIL + 1))
    fi
fi

# ============================================================================
echo ""
echo "=== Test Suite 3: Idempotency ==="
# ============================================================================

if [ -f "$MACOS_SETTINGS" ]; then
    OUT1="$TMPDIR_TEST/idem-pass1.json"
    OUT2="$TMPDIR_TEST/idem-pass2.json"
    generate_container_settings "$MACOS_SETTINGS" "$OUT1"
    generate_container_settings "$OUT1" "$OUT2"

    if diff -q "$OUT1" "$OUT2" >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC}: transformation is idempotent"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: transformation is NOT idempotent"
        diff "$OUT1" "$OUT2" | head -20
        FAIL=$((FAIL + 1))
    fi
fi

# ============================================================================
echo ""
echo "=== Test Suite 4: transform semantics (synthetic inputs) ==="
# ============================================================================
# The two fixtures cannot distinguish the #357 fixes from the behavior they
# replace: neither carries a pwsh `&&` chain, a Linux-native command that
# merely mentions pwsh, or an asterisk-bearing Bash/WebFetch deny rule. These
# inputs are the ones quoted in the issue.

transform() {
    local json="$1" in out
    in="$TMPDIR_TEST/syn-in.json"
    out="$TMPDIR_TEST/syn-out.json"
    printf '%s\n' "$json" > "$in"
    generate_container_settings "$in" "$out"
    cat "$out"
}

# (3b) An `&&` chain must survive as `&&`. Unanchored `gsub("& "; "")`
# collapsed it to `A.sh &B.sh`, which backgrounds A -- so A returns 0 at once
# and a PreToolUse guard hook's block never reaches the harness. `A &B` is
# valid bash, so the entrypoint's `bash -n -c` check accepted it.
out=$(transform '{"hooks":{"PreToolUse":[{"command":"pwsh -NoProfile -Command \"& ~/.claude/hooks/guard.ps1 && & ~/.claude/hooks/second.ps1\""}]}}')
val=$(printf '%s' "$out" | jq -r '.hooks.PreToolUse[0].command')
# shellcheck disable=SC2088 # reason: literal ~/.claude strings compared against JSON value; no tilde expansion desired
assert_eq "pwsh && chain stays a && chain" \
    "~/.claude/hooks/guard.sh && ~/.claude/hooks/second.sh" "$val"

# (3a) A `; ` chain must stay sequential.
out=$(transform '{"hooks":{"SessionEnd":[{"command":"pwsh -NoProfile -Command \"& ~/.claude/hooks/a.ps1 end; & ~/.claude/hooks/b.ps1\""}]}}')
val=$(printf '%s' "$out" | jq -r '.hooks.SessionEnd[0].command')
# shellcheck disable=SC2088 # reason: literal ~/.claude strings compared against JSON value; no tilde expansion desired
assert_eq "pwsh ; chain stays sequential" \
    "~/.claude/hooks/a.sh end; ~/.claude/hooks/b.sh" "$val"

# (3c) A Linux-native command that merely contains the substring "pwsh" must
# pass through the walk untouched. The predicate is anchored now.
out=$(transform '{"hooks":{"PreToolUse":[{"command":"echo \"not pwsh here\"; run.ps1"}]}}')
val=$(printf '%s' "$out" | jq -r '.hooks.PreToolUse[0].command')
assert_eq "non-pwsh command containing 'pwsh' is untouched" \
    'echo "not pwsh here"; run.ps1' "$val"

# (4) Only file-tool glob rules are stripped. Bash and WebFetch deny rules
# survive: sensitive-file-guard.sh, the compensating control the README names,
# covers the file tools only, and WebFetch had nothing behind it at all.
out=$(transform '{"permissions":{"deny":["Read(./.env)","Read(./secrets/**)","Edit(./dist/**)","Write(//**/id_rsa)","Glob(./vendor/**)","Grep(./node_modules/**)","Bash(curl *)","Bash(sudo:*)","WebFetch(domain:*)","Bash(rm:*)"]}}')
val=$(printf '%s' "$out" | jq -c '.permissions.deny')
assert_eq "deny filter strips file-tool globs and keeps the rest" \
    '["Read(./.env)","Bash(curl *)","Bash(sudo:*)","WebFetch(domain:*)","Bash(rm:*)"]' "$val"

# ============================================================================
echo ""
echo "=== Results ==="
echo -e "  ${GREEN}Passed${NC}: $PASS"
echo -e "  ${RED}Failed${NC}: $FAIL"

# Zero assertions is a failure, not a pass. Both suites here SKIP when the
# fixture tree is absent, and this script used to exit 0 having asserted
# nothing:
#
#   $ bash scripts/test-entrypoint-settings.sh /nonexistent/config
#   SKIP: .../settings.json not found
#     Passed: 0
#     Failed: 0
#   EXIT=0
#
# generate_container_settings -- the pwsh-to-bash hook rewrite, the sandbox
# disable, the deny-rule stripping -- has no other test. Move the fixtures and
# all of it disappears silently. A missing jq is already fail-closed here; a
# missing fixture was not.
if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
    echo -e "  ${RED}ERROR${NC}: no assertions ran. CLAUDE_CONFIG resolved to '${CLAUDE_CONFIG}'," >&2
    echo "         and neither settings.json nor settings.windows.json was found there." >&2
    echo "         Pass a config directory as \$1, or run from a checkout that has" >&2
    echo "         tests/entrypoint_fixtures/global." >&2
    exit 1
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
