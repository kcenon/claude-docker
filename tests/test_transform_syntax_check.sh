#!/usr/bin/env bash
# test_transform_syntax_check.sh — Validate the post-transform bash -n -c
# gate added to scripts/entrypoint.sh by issue #180.
#
# The test fabricates a mock container settings file containing a mix of
# runnable and deliberately broken .command entries, then runs the same
# `jq ... | bash -n -c` loop the entrypoint uses. Passes when every
# broken entry is detected and every runnable entry is accepted.
#
# Run: bash tests/test_transform_syntax_check.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
done < <(jq -r '.. | objects | .command? // empty | select(type == "string")' "$TMP")
rm -f "$TMP"

if [[ "$broken_count" -eq 3 ]]; then
    echo "  PASS  extractor + syntax check detects 3 broken commands in fixture"
    exit 0
else
    echo "  FAIL  extractor reported $broken_count broken commands (expected 3)"
    exit 1
fi
