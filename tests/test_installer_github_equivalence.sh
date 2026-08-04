#!/usr/bin/env bash
# Compare the GitHub portion of Bash and PowerShell installer-generated .env
# files in per-account mode. Uses placeholder values only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if ! command -v pwsh >/dev/null 2>&1; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo 'FAIL: pwsh unavailable in CI' >&2
        exit 1
    fi
    echo '== Summary: SKIPPED (pwsh unavailable) =='
    exit 0
fi

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

bash_dir="$(make_sandbox bash)"
pwsh_dir="$(make_sandbox pwsh)"

# The sourced installer consumes these dynamically scoped values.
# shellcheck disable=SC2034
(
    export CLAUDE_DOCKER_INSTALL_LIBRARY_ONLY=1
    export HOME="$WORK/bash-home"
    # shellcheck source=../scripts/install.sh
    . "$bash_dir/scripts/install.sh"
    PLATFORM=linux
    AUTH_PATH=A
    TIER=A
    SOURCE_DIR="$WORK/project"
    CLAUDE_VERSION=""
    RUNTIME=claude
    NUM_ACCOUNTS=2
    GH_AUTH_MODE=per-account
    GH_USERS=(fixture-user-a fixture-user-b)
    GH_TOKENS=(fixture-token-a fixture-token-b)
    generate_env
) >"$bash_dir/install.log" 2>&1

PWSH_COMMAND='& {
    $PSVersionTable.OS = "Microsoft Windows"
    $env:CLAUDE_DOCKER_INSTALL_LIBRARY_ONLY = "1"
    . $env:CLAUDE_DOCKER_INSTALL_ENTRYPOINT
    $Script:AuthPath = "A"
    $Script:Tier = "A"
    $Script:SourceDir = $env:CLAUDE_DOCKER_TEST_PROJECT
    $Script:ClaudeVersion = ""
    $Script:Runtime = "claude"
    $Script:NumAccounts = 2
    $Script:GhAuthMode = "per-account"
    $Script:GhUsers = @("fixture-user-a", "fixture-user-b")
    $Script:GhTokens = @("fixture-token-a", "fixture-token-b")
    New-EnvFile
}'
CLAUDE_DOCKER_INSTALL_ENTRYPOINT="$pwsh_dir/scripts/install.ps1" \
CLAUDE_DOCKER_TEST_PROJECT="$WORK/project" \
USERPROFILE="$WORK/pwsh-home" APPDATA="$WORK/pwsh-appdata" \
pwsh -NoProfile -Command "$PWSH_COMMAND" >"$pwsh_dir/install.log" 2>&1

# shellcheck source=../scripts/lib/parse_env.sh
. "$PROJECT_ROOT/scripts/lib/parse_env.sh"

keys=(GH_AUTH_MODE GH_USER_A GH_TOKEN_A GH_USER_B GH_TOKEN_B)
for key in "${keys[@]}"; do
    bash_value="$(parse_env_value "$bash_dir/.env" "$key")"
    pwsh_value="$(parse_env_value "$pwsh_dir/.env" "$key")"
    if [[ -n "$bash_value" && "$bash_value" == "$pwsh_value" ]]; then
        pass "$key is equivalent"
    else
        fail "$key is equivalent"
    fi
done

if [[ -z "$(parse_env_value "$bash_dir/.env" GH_TOKEN)" &&
      -z "$(parse_env_value "$pwsh_dir/.env" GH_TOKEN)" &&
      -z "$(parse_env_value "$bash_dir/.env" GH_CONFIG_DIR)" &&
      -z "$(parse_env_value "$pwsh_dir/.env" GH_CONFIG_DIR)" ]]; then
    pass 'both installers omit shared GitHub credentials in per-account mode'
else
    fail 'both installers omit shared GitHub credentials in per-account mode'
fi

if grep -q 'fixture-token-a\|fixture-token-b' "$bash_dir/install.log" "$pwsh_dir/install.log"; then
    fail 'installer output never includes token values'
else
    pass 'installer output never includes token values'
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
