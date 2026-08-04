#!/usr/bin/env bash
# Verify targeted gh-auth uses the named stored account and updates only the
# selected mapping. All credentials are non-secret placeholders.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_sandbox() {
    local name="$1"
    local dir="$WORK/$name"
    mkdir -p "$dir/tui/internal/config" "$dir/bin"
    cp -r "$PROJECT_ROOT/scripts" "$dir/scripts"
    cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$dir/tui/internal/config/"
    cp "$PROJECT_ROOT"/docker-compose*.yml "$dir/"
    cp "$PROJECT_ROOT/VERSION" "$dir/"
    cp "$SCRIPT_DIR/env_fixtures/github-per-account.env" "$dir/.env"

    cat > "$dir/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_MOCK_LOG"
if [[ "$1 $2" == "auth status" ]]; then
    exit 0
fi
if [[ "$1 $2" == "auth token" ]]; then
    user=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--user" ]]; then user="$2"; break; fi
        shift
    done
    case "$user" in
        replacement-user-b) printf '%s\n' 'mock-value-b' ;;
        fixture-user-a) printf '%s\n' 'mock-value-a' ;;
        fixture-user-b) printf '%s\n' 'mock-value-b' ;;
        *) exit 1 ;;
    esac
    exit 0
fi
exit 1
MOCK_GH

    cat > "$dir/bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_MOCK_LOG"
if [[ "${1:-}" == "exec" ]]; then
    case "${2:-}" in
        cid-a) printf '%s\n' 'fixture-user-a' ;;
        cid-b) printf '%s\n' 'replacement-user-b' ;;
        *) exit 1 ;;
    esac
    exit 0
fi
case " $* " in
    *" ps -q claude-a "*) printf '%s\n' 'cid-a' ;;
    *" ps -q claude-b "*) printf '%s\n' 'cid-b' ;;
    *" ps -q "*) printf '%s\n' 'cid-a' ;;
esac
exit 0
MOCK_DOCKER
    chmod +x "$dir/bin/gh" "$dir/bin/docker" "$dir/scripts/claude-docker"
    printf '%s' "$dir"
}

assert_case() {
    local language="$1" dir="$2"
    # shellcheck source=../scripts/lib/parse_env.sh
    . "$PROJECT_ROOT/scripts/lib/parse_env.sh"

    if [[ "$(parse_env_value "$dir/.env" GH_USER_B)" == "replacement-user-b" &&
          "$(parse_env_value "$dir/.env" GH_TOKEN_B)" == "mock-value-b" &&
          "$(parse_env_value "$dir/.env" GH_TOKEN_A)" == "fixture-token-a" ]]; then
        pass "$language updates only the selected account mapping"
    else
        fail "$language updates only the selected account mapping"
    fi

    if grep -Fxq 'auth token --hostname github.com --user replacement-user-b' "$dir/gh.log" &&
       ! grep -q 'auth switch' "$dir/gh.log"; then
        pass "$language selects the named host account without switching"
    else
        fail "$language selects the named host account without switching"
    fi

    if grep -q 'up .*--force-recreate.*claude-b' "$dir/docker.log" &&
       ! grep 'up .*--force-recreate' "$dir/docker.log" | grep -q 'claude-a'; then
        pass "$language recreates only the selected running service"
    else
        fail "$language recreates only the selected running service"
    fi

    if grep -q 'mock-value-b' "$dir/command.out"; then
        fail "$language never prints the imported token value"
    else
        pass "$language never prints the imported token value"
    fi
}

assert_all_case() {
    local language="$1" dir="$2"
    if grep -Fxq 'auth token --hostname github.com --user fixture-user-a' "$dir/gh.log" &&
       grep -Fxq 'auth token --hostname github.com --user fixture-user-b' "$dir/gh.log" &&
       ! grep -Fxq 'auth token' "$dir/gh.log" &&
       ! grep -q 'auth switch' "$dir/gh.log"; then
        pass "$language --all selects every configured login explicitly"
    else
        fail "$language --all selects every configured login explicitly"
    fi
    if grep -q 'up .*--force-recreate.*claude-a.*claude-b' "$dir/docker.log"; then
        pass "$language --all recreates all affected running services"
    else
        fail "$language --all recreates all affected running services"
    fi
    if grep -q 'mock-value-a\|mock-value-b' "$dir/command.out"; then
        fail "$language --all keeps token values out of output"
    else
        pass "$language --all keeps token values out of output"
    fi
}

assert_update_case() {
    local language="$1" dir="$2"
    if grep -Fxq 'auth token --hostname github.com --user fixture-user-a' "$dir/gh.log" &&
       grep -Fxq 'auth token --hostname github.com --user fixture-user-b' "$dir/gh.log" &&
       ! grep -Fxq 'auth token' "$dir/gh.log"; then
        pass "$language update refreshes every configured per-account mapping"
    else
        fail "$language update refreshes every configured per-account mapping"
    fi
    if grep -q 'mock-value-a\|mock-value-b' "$dir/command.out"; then
        fail "$language update keeps token values out of output"
    else
        pass "$language update keeps token values out of output"
    fi
}

echo '== Bash =='
bash_dir="$(make_sandbox bash)"
GH_MOCK_LOG="$bash_dir/gh.log" DOCKER_MOCK_LOG="$bash_dir/docker.log" \
    PATH="$bash_dir/bin:$PATH" \
    bash "$bash_dir/scripts/claude-docker" gh-auth b --user replacement-user-b \
    >"$bash_dir/command.out" 2>&1
assert_case Bash "$bash_dir"
if [[ "$(stat -c '%a' "$bash_dir/.env")" == "600" ]]; then
    pass 'Bash retains restrictive .env permissions'
else
    fail 'Bash retains restrictive .env permissions'
fi

bash_all_dir="$(make_sandbox bash-all)"
GH_MOCK_LOG="$bash_all_dir/gh.log" DOCKER_MOCK_LOG="$bash_all_dir/docker.log" \
    PATH="$bash_all_dir/bin:$PATH" \
    bash "$bash_all_dir/scripts/claude-docker" gh-auth --all \
    >"$bash_all_dir/command.out" 2>&1
assert_all_case Bash "$bash_all_dir"

bash_update_dir="$(make_sandbox bash-update)"
GH_MOCK_LOG="$bash_update_dir/gh.log" DOCKER_MOCK_LOG="$bash_update_dir/docker.log" \
    PATH="$bash_update_dir/bin:$PATH" \
    bash "$bash_update_dir/scripts/claude-docker" update \
    >"$bash_update_dir/command.out" 2>&1
assert_update_case Bash "$bash_update_dir"

echo '== PowerShell =='
if ! command -v pwsh >/dev/null 2>&1; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        fail 'pwsh is required for PowerShell account-selection coverage in CI'
    else
        echo '  NOTE  PowerShell case skipped (pwsh unavailable)'
    fi
else
    pwsh_dir="$(make_sandbox pwsh)"
    GH_MOCK_LOG="$pwsh_dir/gh.log" DOCKER_MOCK_LOG="$pwsh_dir/docker.log" \
        PATH="$pwsh_dir/bin:$PATH" CLAUDE_DOCKER_PWSH_ENTRYPOINT="$pwsh_dir/scripts/claude-docker.ps1" \
        pwsh -NoProfile -Command \
        '$PSVersionTable.OS = "Microsoft Windows"; & $env:CLAUDE_DOCKER_PWSH_ENTRYPOINT gh-auth b --user replacement-user-b' \
        >"$pwsh_dir/command.out" 2>&1
    assert_case PowerShell "$pwsh_dir"

    pwsh_all_dir="$(make_sandbox pwsh-all)"
    GH_MOCK_LOG="$pwsh_all_dir/gh.log" DOCKER_MOCK_LOG="$pwsh_all_dir/docker.log" \
        PATH="$pwsh_all_dir/bin:$PATH" CLAUDE_DOCKER_PWSH_ENTRYPOINT="$pwsh_all_dir/scripts/claude-docker.ps1" \
        pwsh -NoProfile -Command \
        '$PSVersionTable.OS = "Microsoft Windows"; & $env:CLAUDE_DOCKER_PWSH_ENTRYPOINT gh-auth --all' \
        >"$pwsh_all_dir/command.out" 2>&1
    assert_all_case PowerShell "$pwsh_all_dir"

    pwsh_update_dir="$(make_sandbox pwsh-update)"
    GH_MOCK_LOG="$pwsh_update_dir/gh.log" DOCKER_MOCK_LOG="$pwsh_update_dir/docker.log" \
        PATH="$pwsh_update_dir/bin:$PATH" CLAUDE_DOCKER_PWSH_ENTRYPOINT="$pwsh_update_dir/scripts/claude-docker.ps1" \
        pwsh -NoProfile -Command \
        '$PSVersionTable.OS = "Microsoft Windows"; & $env:CLAUDE_DOCKER_PWSH_ENTRYPOINT update' \
        >"$pwsh_update_dir/command.out" 2>&1
    assert_update_case PowerShell "$pwsh_update_dir"
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
