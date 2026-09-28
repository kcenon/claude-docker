#!/usr/bin/env bash
# Verify entrypoint GitHub login comparison and per-account Git identity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/tui/internal/config" "$WORK/bin" "$WORK/home"
cp -r "$PROJECT_ROOT/scripts" "$WORK/root/scripts"
cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$WORK/root/tui/internal/config/"

cat > "$WORK/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
case "$1 $2" in
    'auth setup-git') exit 0 ;;
    'api user') printf '%s\n' "${MOCK_GH_LOGIN:?}"; exit 0 ;;
esac
exit 1
MOCK_GH

cat > "$WORK/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_GIT_LOG"
if [[ "$*" == 'config --global user.name' ]]; then
    printf '%s\n' 'stale-name'
elif [[ "$*" == 'config --global user.email' ]]; then
    printf '%s\n' 'stale@example.test'
fi
exit 0
MOCK_GIT
chmod +x "$WORK/bin/gh" "$WORK/bin/git"

run_entrypoint() {
    local login="$1" expected="$2" output="$3" git_log="$4"
    env PATH="$WORK/bin:$PATH" HOME="$WORK/home" \
        CLAUDE_DOCKER_ROOT="$WORK/root" AGENT_RUNTIME=gemini \
        GEMINI_CLI_HOME="$WORK/home" GH_AUTH_MODE=per-account \
        GH_TOKEN=fixture-token-value GH_USER="$expected" MOCK_GH_LOGIN="$login" \
        GIT_USER_NAME='Fixture Account' GIT_USER_EMAIL='fixture@example.test' \
        MOCK_GIT_LOG="$git_log" \
        bash "$WORK/root/scripts/entrypoint.sh" true >"$output" 2>&1
}

echo '== matching login =='
run_entrypoint 'Fixture-User' 'fixture-user' "$WORK/match.out" "$WORK/match.git"
if grep -q 'authenticated as Fixture-User' "$WORK/match.out"; then
    pass 'entrypoint reports the actual authenticated login'
else
    fail 'entrypoint reports the actual authenticated login'
fi
if grep -Fxq 'config --global user.name Fixture Account' "$WORK/match.git" &&
   grep -Fxq 'config --global user.email fixture@example.test' "$WORK/match.git"; then
    pass 'per-account Git identity replaces stale persistent values'
else
    fail 'per-account Git identity replaces stale persistent values'
fi

echo '== mismatch =='
run_entrypoint 'actual-user' 'expected-user' "$WORK/mismatch.out" "$WORK/mismatch.git"
if grep -q 'GitHub login mismatch' "$WORK/mismatch.out" &&
   grep -q 'actual: actual-user' "$WORK/mismatch.out" &&
   grep -q 'expected: expected-user' "$WORK/mismatch.out"; then
    pass 'entrypoint renders actual and expected login on mismatch'
else
    fail 'entrypoint renders actual and expected login on mismatch'
fi
if grep -q 'fixture-token-value' "$WORK/match.out" "$WORK/mismatch.out"; then
    fail 'entrypoint never prints token values'
else
    pass 'entrypoint never prints token values'
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
