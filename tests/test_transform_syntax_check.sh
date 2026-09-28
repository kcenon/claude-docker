#!/usr/bin/env bash
# test_transform_syntax_check.sh — Validate the post-transform bash -n -c
# gate added by issue #180.
#
# The gate moved from scripts/entrypoint.sh into
# scripts/lib/bootstrap-claude.sh in #269. This test did not move with it,
# because it never referenced it: it carried its own copy of the jq filter and
# the `bash -n -c` loop and ran the copy. Deleting the block from the real file
# left the test green (issue #354, item 2).
#
# The fingerprint was visible the whole time -- SCRIPT_DIR was computed here
# and never used, which is what a test that once intended to read the source
# looks like. Extending shellcheck over tests/ is what surfaced it.
#
# Now the jq filter is read out of the real file and the presence of the gate
# is asserted, so deleting either fails here.
#
# Run: bash tests/test_transform_syntax_check.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP="$PROJECT_ROOT/scripts/lib/bootstrap-claude.sh"

PASS=0
FAIL=0

check_case() {
    local label="$1" expect="$2" cmd="$3"  # expect: ok | bad
    local actual="ok"
    if ! bash -n -c "$cmd" 2>/dev/null; then
        actual="bad"
    fi
    if [[ "$actual" == "$expect" ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected=%s actual=%s)\n        cmd: %q\n' \
            "$label" "$expect" "$actual" "$cmd"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local label="$1" cond="$2"
    if [[ "$cond" == "yes" ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$label"
        FAIL=$((FAIL + 1))
    fi
}

echo "== The gate exists in the file that runs it =="

if [[ ! -r "$BOOTSTRAP" ]]; then
    printf '  FAIL  %s is readable\n' "$BOOTSTRAP"
    FAIL=$((FAIL + 1))
fi

# The two halves of the gate. Either one deleted means transformed hook
# commands stop being checked, and the user finds out when a hook misfires
# instead of at container start.
assert_true "bootstrap-claude.sh still runs bash -n -c on each command" \
    "$(grep -q 'bash -n -c "\$_cmd"' "$BOOTSTRAP" && echo yes || echo no)"
assert_true "bootstrap-claude.sh still warns on a failed check" \
    "$(grep -q 'failed bash syntax check' "$BOOTSTRAP" && echo yes || echo no)"

# The extractor filter is read from the real file rather than restated here,
# so a change to it flows into the integration case below instead of leaving
# the test asserting a filter nobody runs.
JQ_FILTER="$(sed -n 's/.*< <(jq -r '"'"'\(.*\)'"'"' "\$CONTAINER_SETTINGS".*/\1/p' "$BOOTSTRAP" | head -n 1)"
assert_true "the extractor filter was recovered from bootstrap-claude.sh" \
    "$([[ -n "$JQ_FILTER" ]] && echo yes || echo no)"
if [[ -n "$JQ_FILTER" ]]; then
    printf '        filter: %s\n' "$JQ_FILTER"
fi

echo "== Runnable commands (the syntax check must accept) =="
check_case "trivial shell call"        ok  'echo hello'
check_case "pipe + redirect"           ok  'cat README.md | head -5 > /tmp/out'
check_case "transformed pwsh -File"    ok  '/home/node/.claude/hooks/foo.sh arg1'
check_case "transformed pwsh -Command" ok  '/usr/local/bin/git status && echo ok'

echo "== Broken commands (the syntax check must reject) =="
# Unbalanced quote: classic pwsh -Command "...; " rewrite gone wrong.
check_case "unbalanced double quote"   bad 'echo "no closing quote'
# Dangling && left by gsub("; "; " && ") when the trailing segment is empty.
check_case "dangling &&"               bad 'echo one && '
# Broken if/fi from a multi-line pwsh script fragment.
check_case "unterminated if block"     bad 'if [ -z "$x" ]; then echo empty'

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
if (( FAIL > 0 )); then
    exit 1
fi

# Integration sanity: build a fake container settings.json and ensure the
# extractor yields the three broken commands plus no spurious entries.
# Skipped when jq is unavailable locally — the entrypoint always has jq in
# the container image, and the loop logic itself is already covered above.
if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP  extractor integration (jq not installed locally)"
    exit 0
fi

TMP=$(mktemp)
cat >"$TMP" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"command": "echo good"},
      {"command": "echo \"bad"},
      {"nested": {"command": "if [ -z $x ]; then"}}
    ]
  },
  "statusLine": {
    "command": "echo line && "
  }
}
JSON

broken_count=0
while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    if ! bash -n -c "$cmd" 2>/dev/null; then
        broken_count=$((broken_count + 1))
    fi
done < <(jq -r "$JQ_FILTER" "$TMP")
rm -f "$TMP"

if [[ "$broken_count" -eq 3 ]]; then
    echo "  PASS  extractor + syntax check detects 3 broken commands in fixture"
    exit 0
else
    echo "  FAIL  extractor reported $broken_count broken commands (expected 3)"
    exit 1
fi
