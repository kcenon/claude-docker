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
# Scope: precedence, with values every reader accepts. Invalid-value handling is
# deliberately outside it, because the two layers differ there by design -- the
# generators abort (they write files) while the CLI wrappers fall back to the
# default (they enumerate services for display). The generators also differ from
# each other on that axis, which is filed separately.
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# name | .env NUM_ACCOUNTS ('-' for no .env file) | environment ('-' for unset) | expected
#
# Row 4 is the discriminating one: it is the only row where the two sources
# disagree, so it is the only row the pre-#317 CLI wrappers failed. Rows 1-3
# passed before this change and still do, which is what keeps a regression in
# the default or the .env path visible instead of being masked.
SCENARIOS=(
    "neither|-|-|2"
    "dotenv-only|3|-|3"
    "env-only|-|5|5"
    "env-wins|3|5|5"
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
        "Import-Module '$dir/scripts/ClaudeDocker.psm1' -Force; (Get-NumAccounts -ProjectRoot '$dir')" \
        2>/dev/null | tr -d '\r' | head -n1
}

read_bash_gen() {
    local dir="$1" envval="$2"
    run_with_env "$envval" bash "$dir/scripts/generate-compose.sh" >/dev/null 2>&1 || return 0
    count_services "$dir"
}

read_pwsh_gen() {
    local dir="$1" envval="$2"
    run_with_env "$envval" pwsh -NoProfile -File "$dir/scripts/generate-compose.ps1" >/dev/null 2>&1 || return 0
    count_services "$dir"
}

# Digest the committed compose files so the closing assertion can prove no
# reader wrote into the checkout.
OUTPUTS=(docker-compose.yml docker-compose.worktree.yml docker-compose.linux.yml)
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

echo "== NUM_ACCOUNTS precedence: environment > .env > 2 =="

for row in "${SCENARIOS[@]}"; do
    IFS='|' read -r name dotenv envval want <<<"$row"

    printf '\n-- %s (.env=%s, environment=%s, expected %s)\n' \
        "$name" "$dotenv" "$envval" "$want"

    # The CLI readers write nothing, so they share one sandbox. Each generator
    # gets its own, because both write the same three filenames.
    cli_dir=$(make_sandbox "${name}-cli" "$dotenv")
    check "$name" "bash-cli"  "$(read_bash_cli "$cli_dir" "$envval")"  "$want"
    check "$name" "pwsh-cli"  "$(read_pwsh_cli "$cli_dir" "$envval")"  "$want"

    bgen_dir=$(make_sandbox "${name}-gen-bash" "$dotenv")
    check "$name" "bash-gen"  "$(read_bash_gen "$bgen_dir" "$envval")"  "$want"

    pgen_dir=$(make_sandbox "${name}-gen-pwsh" "$dotenv")
    check "$name" "pwsh-gen"  "$(read_pwsh_gen "$pgen_dir" "$envval")"  "$want"
done

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
