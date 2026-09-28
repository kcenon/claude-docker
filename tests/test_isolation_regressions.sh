#!/usr/bin/env bash
# Four independently reproduced #335 defects; no daemon or real credentials.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
passed=0 failed=0
check() {
    if "$@"; then passed=$((passed + 1)); else
        printf 'FAIL: %s\n' "$*"; failed=$((failed + 1))
    fi
}
. "$ROOT/scripts/lib/bootstrap-claude.sh"
printf '%s\n' '{"sandbox":{"enabled":true},"permissions":{"deny":["Read(**/.env)","Bash(rm)"]}}' > "$WORK/settings.json"
ISOLATION_MODE=isolated generate_container_settings "$WORK/settings.json" "$WORK/output.json"
check jq -e '.sandbox.enabled == true and .permissions.deny == ["Read(**/.env)","Bash(rm)"]' "$WORK/output.json"

mkdir -p "$WORK/repo/tui/internal/config"
cp -R "$ROOT/scripts" "$WORK/repo/"
cp "$ROOT/tui/internal/config/runtimes.json" "$WORK/repo/tui/internal/config/"
cp "$ROOT/VERSION" "$WORK/repo/"
printf '%s\n' 'NUM_ACCOUNTS=2' 'ISOLATION_MODE=shared' 'GH_AUTH_MODE=per-account' > "$WORK/repo/.env"
cp "$WORK/repo/.env" "$WORK/old.env"
chmod 600 "$WORK/repo/.env"
bash "$WORK/repo/scripts/claude-docker" scale 1 > "$WORK/scale.log" 2>&1
check test "$?" -ne 0
check cmp -s "$WORK/repo/.env" "$WORK/old.env"

printf '%s\n' 'NUM_ACCOUNTS=2' 'ISOLATION_MODE=isolated' 'ISOLATED_WORKSPACE_A=/tmp/placeholder-same' 'ISOLATED_WORKSPACE_B=/tmp/placeholder-same' > "$WORK/repo/.env"
bash "$WORK/repo/scripts/generate-compose.sh" > "$WORK/generate.log" 2>&1
check test "$?" -ne 0
check test ! -e "$WORK/repo/docker-compose.yml"

git init -q "$WORK/seed"
printf 'fixture\n' > "$WORK/seed/tracked"
git -C "$WORK/seed" add tracked
git -C "$WORK/seed" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
git clone -q --shared "$WORK/seed" "$WORK/borrower"
bash "$ROOT/scripts/setup-isolated.sh" "$WORK/borrower" 1 > "$WORK/setup.log" 2>&1
check test "$?" -eq 0
check test ! -e "$WORK/borrower-isolated-a/.git/objects/info/alternates"
printf 'isolation regressions: passed=%s failed=%s\n' "$passed" "$failed"
[[ "$passed" -gt 0 && "$failed" -eq 0 ]]
