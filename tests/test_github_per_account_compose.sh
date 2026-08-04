#!/usr/bin/env bash
# Verify per-account GitHub compose isolation with placeholder credentials only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$SCRIPT_DIR/env_fixtures/github-per-account.env"
PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_sandbox() {
    local name="$1"
    local dir="$WORK/$name"
    mkdir -p "$dir/tui/internal/config"
    cp -r "$PROJECT_ROOT/scripts" "$dir/scripts"
    cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$dir/tui/internal/config/"
    cp "$PROJECT_ROOT/VERSION" "$dir/"
    printf '%s' "$dir"
}

echo '== isolated services =='
isolated="$(make_sandbox isolated)"
cp "$FIXTURE" "$isolated/.env"
bash "$isolated/scripts/generate-compose.sh" >/dev/null

if grep -q '/home/node/.config/gh' "$isolated/docker-compose.yml"; then
    fail 'per-account compose omits shared gh config mount'
else
    pass 'per-account compose omits shared gh config mount'
fi

if ! command -v docker >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        fail 'docker and jq are required for resolved compose assertions in CI'
    else
        echo '  NOTE  resolved compose assertions skipped (docker or jq unavailable)'
    fi
else
    (
        cd "$isolated"
        docker compose config --format json > resolved.json
    )
    if jq -e '
        .services["claude-a"].environment.GH_TOKEN == "fixture-token-a" and
        .services["claude-b"].environment.GH_TOKEN == "fixture-token-b" and
        .services["claude-a"].environment.GH_USER == "fixture-user-a" and
        .services["claude-b"].environment.GH_USER == "fixture-user-b" and
        (.services["claude-a"].environment | has("GH_TOKEN_A") | not) and
        (.services["claude-a"].environment | has("GH_TOKEN_B") | not) and
        (.services["claude-b"].environment | has("GH_TOKEN_A") | not) and
        (.services["claude-b"].environment | has("GH_TOKEN_B") | not)
    ' "$isolated/resolved.json" >/dev/null; then
        pass 'each service receives only its matching standard GH_TOKEN'
    else
        fail 'each service receives only its matching standard GH_TOKEN'
    fi

    if jq -e '
        .services["claude-a"].environment.GIT_USER_NAME == "Fixture Account A" and
        .services["claude-a"].environment.GIT_USER_EMAIL == "account-a@example.test" and
        .services["claude-b"].environment.GIT_USER_NAME == "Shared Fixture" and
        .services["claude-b"].environment.GIT_USER_EMAIL == "shared@example.test"
    ' "$isolated/resolved.json" >/dev/null; then
        pass 'per-account Git identity overrides fall back to shared identity'
    else
        fail 'per-account Git identity overrides fall back to shared identity'
    fi
fi

echo '== fail-closed validation =='
missing="$(make_sandbox missing)"
grep -v '^GH_TOKEN_B=' "$FIXTURE" > "$missing/.env"
printf '%s\n' 'GH_TOKEN=global-must-not-fallback' >> "$missing/.env"
if bash "$missing/scripts/generate-compose.sh" >"$missing/stdout" 2>"$missing/stderr"; then
    fail 'missing GH_TOKEN_B is rejected even when global GH_TOKEN exists'
elif grep -q 'GH_TOKEN_B' "$missing/stderr" &&
     ! grep -q 'fixture-token\|global-must-not-fallback' "$missing/stdout" "$missing/stderr"; then
    pass 'missing GH_TOKEN_B is named without exposing any token value'
else
    fail 'missing mapping diagnostic is scoped and secret-free'
fi

echo '== suffix range =='
range="$(make_sandbox range)"
{
    printf '%s\n' 'NUM_ACCOUNTS=702' 'HOME=/tmp/claude-test' \
        'PROJECT_DIR=/tmp/claude-test/project' 'GH_AUTH_MODE=per-account'
    # shellcheck source=../scripts/lib/index.sh
    . "$PROJECT_ROOT/scripts/lib/index.sh"
    for i in $(seq 1 702); do
        upper="$(index_to_upper "$i")"
        printf 'GH_USER_%s=fixture-user-%s\n' "$upper" "$upper"
        printf 'GH_TOKEN_%s=fixture-token-%s\n' "$upper" "$upper"
    done
} > "$range/.env"
bash "$range/scripts/generate-compose.sh" >/dev/null
if grep -Fq '  claude-zz:' "$range/docker-compose.yml" &&
   grep -Fq '      - GH_TOKEN=${GH_TOKEN_ZZ}' "$range/docker-compose.yml"; then
    pass 'per-account mapping reaches the supported ZZ suffix'
else
    fail 'per-account mapping reaches the supported ZZ suffix'
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
