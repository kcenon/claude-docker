#!/usr/bin/env bash
# test_parse_env.sh — Unit tests for scripts/lib/parse_env.sh.
#
# Run:  bash tests/test_parse_env.sh
# Exits non-zero on any failure; prints a summary at the end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/env_fixtures"

# shellcheck source=../scripts/lib/parse_env.sh
. "$PROJECT_ROOT/scripts/lib/parse_env.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected: %q\n        actual:   %q\n' \
            "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "== parse_env_value: minimal.env =="
assert_eq "NUM_ACCOUNTS" "2" "$(parse_env_value "$FIXTURES/minimal.env" NUM_ACCOUNTS)"
assert_eq "IMAGE_TAG"    "latest" "$(parse_env_value "$FIXTURES/minimal.env" IMAGE_TAG)"
assert_eq "missing key"  "" "$(parse_env_value "$FIXTURES/minimal.env" NOPE)"

echo "== parse_env_value: edge-cases.env =="
assert_eq "basic int"         "3" "$(parse_env_value "$FIXTURES/edge-cases.env" NUM_ACCOUNTS)"
assert_eq "value with space"  "/home/user/my project" \
    "$(parse_env_value "$FIXTURES/edge-cases.env" PROJECT_DIR)"
assert_eq "inline comment strip" "gho_abc123" \
    "$(parse_env_value "$FIXTURES/edge-cases.env" GH_TOKEN)"
assert_eq "double-quoted unwrap" "hello world" \
    "$(parse_env_value "$FIXTURES/edge-cases.env" QUOTED_DOUBLE)"
assert_eq "single-quoted unwrap" "single quoted" \
    "$(parse_env_value "$FIXTURES/edge-cases.env" QUOTED_SINGLE)"
assert_eq "empty value" "" "$(parse_env_value "$FIXTURES/edge-cases.env" EMPTY)"
assert_eq "equals in value" "foo=bar=baz" \
    "$(parse_env_value "$FIXTURES/edge-cases.env" EQUALS_IN_VALUE)"
assert_eq "hash inside quotes is literal" "value#not-a-comment" \
    "$(parse_env_value "$FIXTURES/edge-cases.env" HASH_IN_QUOTES)"
assert_eq "trailing-space line" "keep-me" \
    "$(parse_env_value "$FIXTURES/edge-cases.env" TRAILING_SPACE)"

echo "== parse_env_value: duplicate keys — last wins =="
assert_eq "NUM_ACCOUNTS last wins" "5" \
    "$(parse_env_value "$FIXTURES/duplicate-keys.env" NUM_ACCOUNTS)"

echo "== parse_env_value: CRLF tolerance =="
CRLF_FILE="$(mktemp)"
# Generate an intentionally CRLF-terminated file so the test works on LF hosts.
printf 'A=one\r\nB=two\r\n' > "$CRLF_FILE"
assert_eq "CRLF A" "one" "$(parse_env_value "$CRLF_FILE" A)"
assert_eq "CRLF B" "two" "$(parse_env_value "$CRLF_FILE" B)"
rm -f "$CRLF_FILE"

echo "== load_env_file: default mode (no overwrite) =="
unset LF_TEST_KEY 2>/dev/null || true
LF_FIXTURE="$(mktemp)"
printf 'LF_TEST_KEY=from-file\n' > "$LF_FIXTURE"
LF_TEST_KEY=from-env
load_env_file "$LF_FIXTURE"
assert_eq "env wins over .env in default mode" "from-env" "$LF_TEST_KEY"
unset LF_TEST_KEY
load_env_file "$LF_FIXTURE"
assert_eq "loads when env var unset" "from-file" "$LF_TEST_KEY"
rm -f "$LF_FIXTURE"

echo "== load_env_file: -a mode (force overwrite) =="
FORCE_FIXTURE="$(mktemp)"
printf 'FORCE_KEY=from-file\n' > "$FORCE_FIXTURE"
FORCE_KEY=from-env
load_env_file "$FORCE_FIXTURE" -a
assert_eq "force mode overwrites env" "from-file" "$FORCE_KEY"
rm -f "$FORCE_FIXTURE"

echo "== set_env_value: update existing, insert missing =="
SET_FIXTURE="$(mktemp)"
cp "$FIXTURES/minimal.env" "$SET_FIXTURE"
set_env_value "$SET_FIXTURE" NUM_ACCOUNTS 7
assert_eq "updated value" "7" "$(parse_env_value "$SET_FIXTURE" NUM_ACCOUNTS)"
set_env_value "$SET_FIXTURE" NEW_KEY "value with spaces"
assert_eq "insert round-trip" "value with spaces" \
    "$(parse_env_value "$SET_FIXTURE" NEW_KEY)"
set_env_value "$SET_FIXTURE" HASH_KEY "val#1"
assert_eq "hash value round-trip" "val#1" \
    "$(parse_env_value "$SET_FIXTURE" HASH_KEY)"
rm -f "$SET_FIXTURE"

echo "== set_env_value: the bytes it writes =="

# Reading back through parse_env_value hid two things at once, because the
# parser's behaviour was substituted for the file's contents (#354, item 8).
# These assertions look at the file.

BYTES_FIXTURE="$(mktemp)"
printf 'A=1\n' > "$BYTES_FIXTURE"

# 1. No blank line is inserted before an appended key. `$(tail -c1 file)`
#    strips the trailing newline, so the "does it end in a newline" check was
#    always true and .env grew a gap per key.
set_env_value "$BYTES_FIXTURE" B 2
set_env_value "$BYTES_FIXTURE" C 3
assert_eq "appending does not insert blank lines" \
    "A=1|B=2|C=3" "$(tr '\n' '|' < "$BYTES_FIXTURE" | sed 's/|$//')"

# 2. A file that genuinely lacks a trailing newline still gets one, so the
#    fix above did not trade one bug for the other.
NONL_FIXTURE="$(mktemp)"
printf 'A=1' > "$NONL_FIXTURE"
set_env_value "$NONL_FIXTURE" B 2
assert_eq "a missing trailing newline is still added" \
    "A=1|B=2" "$(tr '\n' '|' < "$NONL_FIXTURE" | sed 's/|$//')"
rm -f "$NONL_FIXTURE"

# 3. The quoting and escaping, asserted as written rather than as parsed.
set_env_value "$BYTES_FIXTURE" QUOTED 'say "hi" now'
assert_eq "an embedded quote is escaped inside the wrapper" \
    'QUOTED="say \"hi\" now"' "$(grep '^QUOTED=' "$BYTES_FIXTURE")"

# 4. And the read side, stated as it is rather than as the docstring used to
#    claim. parse_env_value strips the wrapper but does not unescape, so this
#    round-trip is lossy. Read-EnvFile and the Go LoadEnv agree with it.
#    Pinned so that making it lossless -- a change to all three readers,
#    tracked in #356 -- shows up here instead of passing silently.
assert_eq "the read-back value keeps the backslashes (known, see #356)" \
    'say \"hi\" now' "$(parse_env_value "$BYTES_FIXTURE" QUOTED)"

rm -f "$BYTES_FIXTURE"

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
if (( FAIL > 0 )); then
    exit 1
fi
