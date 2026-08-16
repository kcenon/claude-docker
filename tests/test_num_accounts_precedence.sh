#!/usr/bin/env bash
# test_num_accounts_precedence.sh -- Pin every shell-side NUM_ACCOUNTS reader to
# one precedence: environment, then .env, then the default of 2.
#
# Four readers resolve this value independently, in two languages and two
# layers. Until #317 the two generators consulted the environment and the two
# CLI wrappers did not, so exporting NUM_ACCOUNTS=5 and regenerating wrote five
# services while `claude-docker` kept enumerating two -- commands that iterate
# accounts silently skipped services that existed.
#
# The test asserts each reader against an expected value rather than only
# against the other three. Agreement alone is satisfied by four readers that are
# wrong together, and the whole point of the fixture set is the one row where
# they used to disagree.
#
# Scope: precedence plus unusable-value handling. The two layers differ there by
# design: generators abort before writing files, while CLI wrappers warn and
# fall back to the default because they enumerate services for display. Both
# languages must make the same choice within a layer, including at the shared
# upper bound of 702.
#
# The TUI is a fifth reader and is deliberately not covered. Env.NumAccounts()
# in tui/internal/config/env.go reads .env alone because Env is the document the
# TUI edits and writes back, and it treats the value as a floor rather than an
# exact count -- discoverStateDirs raises it to cover state directories found on
# disk. See the README's Compose Overrides section.
#
# Both generators write compose files into the project root they derive from
# their own location, so every reader runs against a throwaway sandbox holding
# only the files it reads. The repository checkout is never written to; the
# committed compose files are digest-checked at the end to prove it.
#
# Run:  bash tests/test_num_accounts_precedence.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

# pwsh carries two of the four readers, so a run without it compares nothing
# worth comparing. Locally that is a skip; in CI it is a failure, because the
# bash-tests matrix runs on a runner that ships pwsh and a silent skip there
# would look identical to a pass.
if ! command -v pwsh >/dev/null 2>&1; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "FAIL: pwsh unavailable in CI (was preinstalled on ubuntu-latest)" >&2
        exit 1
    fi
    echo "NOTE: pwsh not installed locally; skipping NUM_ACCOUNTS precedence" >&2
    echo "== Summary: SKIPPED (pwsh unavailable) =="
    exit 0
fi

# The guarded PowerShell generator is Windows-only, while this Linux CI test
# still needs to exercise its configuration logic. The dedicated platform
# guard test uses the real OS value; generator probes below change it only in
# their child process, avoiding a production bypass switch.
PWSH_GENERATOR_COMMAND="\$PSVersionTable.OS = 'Microsoft Windows'; & \$env:CLAUDE_DOCKER_PWSH_ENTRYPOINT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# name | .env value ('-' for no file) | environment ('-' for unset) | CLI expected | generator expected
#
# Row 4 is the precedence discriminator where the two sources disagree. The
# remaining rows pin normalization and the policy for unusable values.
SCENARIOS=(
    "neither|-|-|2|2"
    "dotenv-only|3|-|3|3"
    "env-only|-|5|5|5"
    "env-wins|3|5|5|5"
    "leading-zero|-|008|8|8"
    "non-numeric|-|abc|2|reject"
    "whitespace|-|   |2|reject"
    "over-limit|-|703|2|reject"
    "overflow|-|99999999999999999999|2|reject"
)

# Stage a sandbox holding only what a reader reads: the scripts tree, the
# runtime registry (resolved relative to the project root), and VERSION (the
# generators' IMAGE_TAG fallback).
make_sandbox() {
    local dir="$WORK/$1"
    mkdir -p "$dir/tui/internal/config"
    cp -r "$PROJECT_ROOT/scripts" "$dir/scripts"
    cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$dir/tui/internal/config/"
    if [[ -f "$PROJECT_ROOT/VERSION" ]]; then
        cp "$PROJECT_ROOT/VERSION" "$dir/"
    fi
    if [[ "$2" != "-" ]]; then
        printf 'NUM_ACCOUNTS=%s\n' "$2" > "$dir/.env"
    fi
    printf '%s' "$dir"
}

# Run a command with NUM_ACCOUNTS either exported or removed, and with
# AGENT_RUNTIME always removed so the host environment cannot change which
# service prefix the readers enumerate.
run_with_env() {
    local envval="$1"
    shift
    if [[ "$envval" == "-" ]]; then
        env -u NUM_ACCOUNTS -u AGENT_RUNTIME "$@"
    else
        env -u AGENT_RUNTIME "NUM_ACCOUNTS=$envval" "$@"
    fi
}

# Count generated services. Every service carries exactly one `image:` line.
count_services() {
    grep -c '^    image: claude-code-base:' "$1/docker-compose.yml" 2>/dev/null || echo 0
}

# --- The four readers ---------------------------------------------------------
# Each returns the account count it resolved, or the empty string if the probe
# itself failed. Probing through the real entrypoints keeps the resolution
# path honest: nothing here reimplements the precedence it is checking.

# `help` prints "SERVICES (N configured)" from get_num_accounts and needs no
# Docker daemon.
read_bash_cli() {
    local dir="$1" envval="$2" out
    out=$(run_with_env "$envval" bash "$dir/scripts/claude-docker" help 2>/dev/null)
    printf '%s' "$out" | sed -n 's/.*SERVICES (\([0-9][0-9]*\) configured).*/\1/p' | head -n1
}

read_pwsh_cli() {
    local dir="$1" envval="$2"
    run_with_env "$envval" pwsh -NoProfile -Command \
        "Import-Module '$dir/scripts/ClaudeDocker.psm1' -Force; (Get-NumAccounts -ProjectRoot '$dir' -WarningAction SilentlyContinue)" \
        2>/dev/null | tr -d '\r' | head -n1
}

read_bash_gen() {
    local dir="$1" envval="$2"
    run_with_env "$envval" bash "$dir/scripts/generate-compose.sh" >/dev/null 2>&1 || return 0
    count_services "$dir"
}

read_pwsh_gen() {
    local dir="$1" envval="$2"
    run_with_env "$envval" env \
        "CLAUDE_DOCKER_PWSH_ENTRYPOINT=$dir/scripts/generate-compose.ps1" \
        pwsh -NoProfile -Command "$PWSH_GENERATOR_COMMAND" >/dev/null 2>&1 || return 0
    count_services "$dir"
}

# Digest the committed compose files so the closing assertion can prove no
# reader wrote into the checkout.
# Every file the generators write. A new generated stack must be added here,
# or this test's closing "no reader wrote into the checkout" assertion cannot
# see it being clobbered. docker-compose.isolated.yml was missing until #353.
OUTPUTS=(
    docker-compose.yml
    docker-compose.worktree.yml
    docker-compose.isolated.yml
    docker-compose.linux.yml
)
compose_digest() {
    local f
    for f in "${OUTPUTS[@]}"; do
        if [[ -f "$PROJECT_ROOT/$f" ]]; then
            cksum <"$PROJECT_ROOT/$f"
        else
            echo "absent $f"
        fi
    done
}
DIGEST_BEFORE="$(compose_digest)"

check() {
    local scenario="$1" reader="$2" got="$3" want="$4"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS  %-12s %-10s -> %s\n' "$scenario" "$reader" "$got"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %-12s %-10s -> %s (expected %s)\n' \
            "$scenario" "$reader" "${got:-<probe failed>}" "$want"
        FAIL=$((FAIL + 1))
    fi
}

check_contains() {
    local scenario="$1" reader="$2" got="$3" want="$4"
    if [[ "$got" == *"$want"* ]]; then
        printf '  PASS  %-12s %-10s contains expected diagnostic\n' "$scenario" "$reader"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %-12s %-10s missing: %s\n' "$scenario" "$reader" "$want"
        FAIL=$((FAIL + 1))
    fi
}

echo "== NUM_ACCOUNTS precedence: environment > .env > 2 =="

for row in "${SCENARIOS[@]}"; do
    IFS='|' read -r name dotenv envval cli_want gen_want <<<"$row"
    [[ "$gen_want" == "reject" ]] && gen_want=""

    printf '\n-- %s (.env=%s, environment=%s)\n' "$name" "$dotenv" "$envval"

    # The CLI readers write nothing, so they share one sandbox. Each generator
    # gets its own, because both write the same three filenames.
    cli_dir=$(make_sandbox "${name}-cli" "$dotenv")
    check "$name" "bash-cli"  "$(read_bash_cli "$cli_dir" "$envval")"  "$cli_want"
    check "$name" "pwsh-cli"  "$(read_pwsh_cli "$cli_dir" "$envval")"  "$cli_want"

    bgen_dir=$(make_sandbox "${name}-gen-bash" "$dotenv")
    check "$name" "bash-gen"  "$(read_bash_gen "$bgen_dir" "$envval")"  "$gen_want"

    pgen_dir=$(make_sandbox "${name}-gen-pwsh" "$dotenv")
    check "$name" "pwsh-gen"  "$(read_pwsh_gen "$pgen_dir" "$envval")"  "$gen_want"
done

echo ""
echo "== non-numeric diagnostics come from each reader =="
expected="NUM_ACCOUNTS must be an integer between 1 and 702 (got: abc)"
diag_cli_dir=$(make_sandbox "diagnostic-cli" "-")
bash_cli_out=$(run_with_env abc bash "$diag_cli_dir/scripts/claude-docker" help 2>&1)
pwsh_cli_out=$(run_with_env abc pwsh -NoProfile -Command \
    "Import-Module '$diag_cli_dir/scripts/ClaudeDocker.psm1' -Force; Get-NumAccounts -ProjectRoot '$diag_cli_dir' | Out-Null" 2>&1)
check_contains "diagnostic" "bash-warn" "$bash_cli_out" "$expected"
check_contains "diagnostic" "pwsh-warn" "$pwsh_cli_out" "$expected"

diag_bgen_dir=$(make_sandbox "diagnostic-gen-bash" "-")
diag_pgen_dir=$(make_sandbox "diagnostic-gen-pwsh" "-")
bash_gen_out=$(run_with_env abc bash "$diag_bgen_dir/scripts/generate-compose.sh" 2>&1)
bash_gen_status=$?
pwsh_gen_out=$(run_with_env abc env \
    "CLAUDE_DOCKER_PWSH_ENTRYPOINT=$diag_pgen_dir/scripts/generate-compose.ps1" \
    pwsh -NoProfile -Command "$PWSH_GENERATOR_COMMAND" 2>&1)
pwsh_gen_status=$?
check "diagnostic" "bash-exit" "$bash_gen_status" "1"
check "diagnostic" "pwsh-exit" "$pwsh_gen_status" "1"
check_contains "diagnostic" "bash-error" "$bash_gen_out" "$expected"
check_contains "diagnostic" "pwsh-error" "$pwsh_gen_out" "$expected"
check "diagnostic" "gen-files" "$([[ -e "$diag_bgen_dir/docker-compose.yml" || -e "$diag_pgen_dir/docker-compose.yml" ]] && echo 1 || echo 0)" "0"

echo ""
echo "== scale range: 1..702 with double-letter state directories =="

scale_dir=$(make_sandbox "scale-bash" "26")
mkdir -p "$scale_dir/bin" "$scale_dir/home"
printf '#!/usr/bin/env bash\nexit 0\n' > "$scale_dir/bin/docker"
chmod +x "$scale_dir/bin/docker"
scale_out=$(env -u NUM_ACCOUNTS -u AGENT_RUNTIME HOME="$scale_dir/home" \
    PATH="$scale_dir/bin:$PATH" bash "$scale_dir/scripts/claude-docker" scale 27 2>&1)
scale_status=$?
check "scale-27" "bash-exit" "$scale_status" "0"
check "scale-27" "bash-aa-dir" "$([[ -d "$scale_dir/home/.claude-state/account-aa" ]] && echo 1 || echo 0)" "1"

max_dir=$(make_sandbox "scale-max" "-")
bash_max_out=$(run_with_env "-" bash "$max_dir/scripts/claude-docker" scale 702 2>&1)
check_contains "scale-702" "bash" "$bash_max_out" ".env not found"
bash_over_out=$(run_with_env "-" bash "$max_dir/scripts/claude-docker" scale 703 2>&1)
check_contains "scale-703" "bash" "$bash_over_out" "between 1 and 702"

pwsh_letter=$(pwsh -NoProfile -Command \
    "Import-Module '$max_dir/scripts/ClaudeDocker.psm1' -Force; ConvertTo-AccountLetter -Index 27" \
    2>/dev/null | tr -d '\r')
check "scale-27" "pwsh-letter" "$pwsh_letter" "aa"

bash_help=$(run_with_env "-" bash "$max_dir/scripts/claude-docker" help 2>&1)
check_contains "scale-help" "bash" "$bash_help" "Set number of accounts (1-702)"
pwsh_source=$(tr -d '\r' < "$max_dir/scripts/claude-docker.ps1")
check_contains "scale-help" "pwsh" "$pwsh_source" "Set number of accounts (1-702)"
pwsh_scale=$(sed -n '/^function Invoke-Scale {/,/^}/p' "$max_dir/scripts/claude-docker.ps1")
check_contains "scale-702" "pwsh" "$pwsh_scale" '$newCount -gt 702'

printf '\n-- checkout untouched\n'
if [[ "$(compose_digest)" == "$DIGEST_BEFORE" ]]; then
    echo "  PASS  committed compose files unchanged"
    PASS=$((PASS + 1))
else
    echo "  FAIL  a reader wrote into the repository checkout"
    FAIL=$((FAIL + 1))
fi

printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
