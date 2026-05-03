#!/usr/bin/env bash
# test_parse_env_equivalence.sh -- Verify bash and pwsh parsers produce
# identical output for the same input (cross-language equivalence).
#
# The bash implementation lives in scripts/lib/parse_env.sh
# (parse_env_value) and the PowerShell implementation lives in
# scripts/ClaudeDocker.psm1 (Get-EnvValue). Both parse the same .env
# files, but their functional equivalence has not been asserted by any
# test until now. This harness invokes both for every (fixture, key)
# pair in tests/env_fixtures/ and asserts byte equality so any future
# drift between the two parsers fails CI loudly.
#
# Run:  bash tests/test_parse_env_equivalence.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/env_fixtures"

# shellcheck source=../scripts/lib/parse_env.sh
. "$PROJECT_ROOT/scripts/lib/parse_env.sh"

# Skip cleanly if pwsh is unavailable (local-dev convenience), but fail
# in CI -- pwsh is preinstalled on ubuntu-latest runners and the whole
# point of this harness is to compare the two implementations.
if ! command -v pwsh >/dev/null 2>&1; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "FAIL: pwsh unavailable in CI environment (was preinstalled on ubuntu-latest)" >&2
        exit 1
    fi
    echo "SKIP: pwsh not installed locally; CI will exercise the real path" >&2
    exit 0
fi

PSM1_PATH="$PROJECT_ROOT/scripts/ClaudeDocker.psm1"

PASS=0
FAIL=0

# assert_equiv FIXTURE KEY
# Run both parsers on (FIXTURE, KEY) and compare their output as strings.
# Both implementations return empty / $null for missing keys, so we
# normalize $null -> '' on the pwsh side to match bash's empty-string
# convention.
assert_equiv() {
    local fixture="$1" key="$2"
    local bash_val pwsh_val
    bash_val=$(parse_env_value "$fixture" "$key")
    pwsh_val=$(pwsh -NoProfile -Command "
        Import-Module '$PSM1_PATH' -Force
        \$v = Get-EnvValue -Path '$fixture' -Key '$key'
        if (\$null -eq \$v) { '' } else { \$v }
    ")

    if [[ "$bash_val" == "$pwsh_val" ]]; then
        printf '  PASS  %s : %s\n' "$(basename "$fixture")" "$key"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s : %s\n        bash: %q\n        pwsh: %q\n' \
            "$(basename "$fixture")" "$key" "$bash_val" "$pwsh_val"
        FAIL=$((FAIL + 1))
    fi
}

# enumerate_keys FIXTURE
# Print one key per line for the given fixture by reading lines that
# look like "KEY=...". Skips comments and blank lines. Used to build
# the (fixture, key) pair list dynamically rather than maintaining a
# hand-edited mirror of every fixture's keys.
enumerate_keys() {
    local fixture="$1"
    awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            eq_idx = index($0, "=")
            if (eq_idx == 0) { next }
            key = substr($0, 1, eq_idx - 1)
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key == "") { next }
            print key
        }
    ' "$fixture" | awk '!seen[$0]++'
}

run_fixture() {
    local fixture="$1"
    echo "== $(basename "$fixture") =="
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        assert_equiv "$fixture" "$key"
    done < <(enumerate_keys "$fixture")
}

run_fixture "$FIXTURES/minimal.env"
run_fixture "$FIXTURES/edge-cases.env"
run_fixture "$FIXTURES/with-special-chars.env"
run_fixture "$FIXTURES/tier-b.env"
run_fixture "$FIXTURES/n5.env"
run_fixture "$FIXTURES/n30.env"
run_fixture "$FIXTURES/duplicate-keys.env"

# Missing-key behavior is part of the contract: bash returns empty,
# pwsh returns $null (which we normalize to ''). Pin it.
echo "== missing-key behavior =="
assert_equiv "$FIXTURES/minimal.env" "NOPE"
assert_equiv "$FIXTURES/edge-cases.env" "DOES_NOT_EXIST"

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
