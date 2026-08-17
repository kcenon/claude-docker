#!/usr/bin/env bash
# test_parse_env_equivalence.sh -- Verify the three .env parsers produce
# identical output for the same input (cross-language equivalence).
#
# The implementations are scripts/lib/parse_env.sh (parse_env_value),
# scripts/ClaudeDocker.psm1 (Get-EnvValue), and tui/internal/config
# (LoadEnv, reached through cmd/envprobe). This harness invokes all three
# for every (fixture, key) pair in tests/env_fixtures/ and asserts byte
# equality so any future drift fails CI loudly.
#
# Go joined in #356, row 9. Until then it was the odd one out on four
# reachable inputs: it did not strip inline comments at all, so
# `NUM_ACCOUNTS=4  # four` made Atoi fail and the TUI silently used the
# default of 2 while both generators read 4; and strings.Trim(val, "\"'")
# is a cutset trim rather than a paired-quote strip, so `"unclosed` lost
# its lone leading quote. Nothing compared the two, because this harness
# only knew about the shells.
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

# The Go reader lives in an internal/ package, which no external module may
# import, so it is reached through tui/cmd/envprobe. Built once here rather
# than `go run` per assertion: there are several hundred (fixture, key) pairs.
if ! command -v go >/dev/null 2>&1; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "FAIL: go unavailable in CI environment (it is preinstalled on ubuntu-latest)" >&2
        exit 1
    fi
    echo "SKIP: go not installed locally; CI will exercise the real path" >&2
    exit 0
fi

GO_PROBE="$(mktemp -d)/envprobe"
trap 'rm -rf "$(dirname "$GO_PROBE")"' EXIT
if ! (cd "$PROJECT_ROOT/tui" && go build -o "$GO_PROBE" ./cmd/envprobe) 2>/dev/null; then
    echo "FAIL: could not build tui/cmd/envprobe" >&2
    exit 1
fi

PASS=0
FAIL=0

# assert_equiv FIXTURE KEY
# Run both parsers on (FIXTURE, KEY) and compare their output as strings.
# Both implementations return empty / $null for missing keys, so we
# normalize $null -> '' on the pwsh side to match bash's empty-string
# convention.
assert_equiv() {
    local fixture="$1" key="$2"
    local bash_val pwsh_val go_val
    bash_val=$(parse_env_value "$fixture" "$key")
    pwsh_val=$(pwsh -NoProfile -Command "
        Import-Module '$PSM1_PATH' -Force
        \$v = Get-EnvValue -Path '$fixture' -Key '$key'
        if (\$null -eq \$v) { '' } else { \$v }
    ")
    go_val=$("$GO_PROBE" "$fixture" "$key")

    if [[ "$bash_val" == "$pwsh_val" && "$pwsh_val" == "$go_val" ]]; then
        printf '  PASS  %s : %s\n' "$(basename "$fixture")" "$key"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s : %s\n        bash: %q\n        pwsh: %q\n        go:   %q\n' \
            "$(basename "$fixture")" "$key" "$bash_val" "$pwsh_val" "$go_val"
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

# The lines the three readers actually disagreed on, written at runtime.
#
# None of them is in a checked-in fixture: edge-cases.env's HASH_IN_QUOTES uses
# a `#` with no space before it, which no implementation treats as a comment,
# so the fixtures could not tell the readers apart. These can, and did --
# every one of them is a case where Go answered differently from the shells,
# or where all three agreed on the wrong answer (#356, row 9).
SYNTH_DIR="$(mktemp -d)"
trap 'rm -rf "$(dirname "$GO_PROBE")" "$SYNTH_DIR"' EXIT
SYNTH="$SYNTH_DIR/synthetic.env"
cat > "$SYNTH" <<'SYNTH_EOF'
PLAIN=bar
COMMENT_AFTER_VALUE=bar  # note
HASH_NO_SPACE=bar# note
HASH_INSIDE_QUOTES="a # b"
QUOTED_SPACE="a b"
SINGLE_QUOTED='a b'
LEADING_SPACE= bar
QUOTED_THEN_COMMENT="bar"  # note
INNER_QUOTE=a"b
UNCLOSED_QUOTE="unclosed
EMBEDDED_QUOTES=say "hi" now
HASH_FIRST=#nospace
TRAILING_HASH="abc #"
SYNTH_EOF

echo "== synthetic edge cases =="
while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    assert_equiv "$SYNTH" "$key"
done < <(enumerate_keys "$SYNTH")

# Agreement is not enough on its own: three readers can be wrong together, and
# two of them were. Before #356, bash and pwsh both returned `"a` for
# HASH_INSIDE_QUOTES -- consistent, and not the value in the file. These pin
# what each value must actually be.
assert_value() {
    local key="$1" want="$2" got
    got=$(parse_env_value "$SYNTH" "$key")
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  value  %s\n' "$key"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  value  %s\n        want: %q\n        got:  %q\n' "$key" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

echo "== synthetic edge cases: absolute values =="
assert_value PLAIN                'bar'
assert_value COMMENT_AFTER_VALUE  'bar'
assert_value HASH_NO_SPACE        'bar# note'
assert_value HASH_INSIDE_QUOTES   'a # b'
assert_value QUOTED_SPACE         'a b'
assert_value SINGLE_QUOTED        'a b'
assert_value LEADING_SPACE        ' bar'
assert_value QUOTED_THEN_COMMENT  'bar'
assert_value INNER_QUOTE          'a"b'
assert_value UNCLOSED_QUOTE       '"unclosed'
assert_value EMBEDDED_QUOTES      'say "hi" now'
assert_value HASH_FIRST           '#nospace'
assert_value TRAILING_HASH        'abc #'

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
