#!/usr/bin/env bash
# test_compose_generator_equivalence.sh -- Verify scripts/generate-compose.sh
# and scripts/generate-compose.ps1 emit identical compose files for the same
# input.
#
# #243 aligned the two generators once; nothing kept them aligned. The
# `Compose files are current` job added by #305 regenerates with the *bash*
# generator only, so PowerShell-side drift leaves CI green and only Windows
# users regenerate to something different. This test closes that gap the way
# test_parse_env_equivalence.sh and test_runtime_registry_equivalence.sh
# already guard their cross-language readers of a shared input.
#
# The fixture axis matters as much as the runtime axis. Configuration reaches a
# generator two ways -- through `.env` and through the caller's environment --
# and the four `.env` fixtures below agreed byte-for-byte even while the
# environment path did not (#315). A `.env`-only fixture set would therefore
# have passed on day one and missed that defect entirely, which is why
# `env-override` is here.
#
# Both generators write into their own project root, so every run gets a
# throwaway sandbox holding only the files a generator reads. Running them in
# the repository would overwrite the committed compose files -- the trap
# tests/test_windows_platform_guard.sh had to avoid.
#
# Line endings are normalized before comparison. On Windows the PowerShell
# generator's StringBuilder appends [Environment]::NewLine (CRLF) while bash
# emits LF; that is a property of the host running the test rather than drift
# between the generators, and the axis under test here is content.
#
# Run:  bash tests/test_compose_generator_equivalence.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FIXTURE_DIR="$PROJECT_ROOT/tests/env_fixtures"
OUTPUTS=(docker-compose.yml docker-compose.worktree.yml docker-compose.linux.yml)

# name | .env fixture basename ('-' for no .env) | environment assignments
#
# minimal/codex/gemini cover the runtime-conditional branches (the claude
# baseline with its CLAUDE_NORMALIZE_CRLF line, the codex mountsAgentsSkills
# extra volume, and gemini's configDirEnvValue decoupled from
# containerConfigMount). n5 covers multi-account letter enumeration and n30 its
# two-letter regime -- scripts/lib/index.ps1 says it "mirrors" index.sh, so the
# Excel-style enumeration added by #178 is two independent implementations and
# n5 alone would only ever compare single letters. env-override covers the
# environment path that #315 fixed.
FIXTURES=(
    "minimal|minimal.env|"
    "codex|codex.env|"
    "gemini|gemini.env|"
    "github-per-account|github-per-account.env|"
    "n5|n5.env|"
    "n30|n30.env|"
    "env-override|-|NUM_ACCOUNTS=5 IMAGE_TAG=probe-tag"
)

PASS=0
FAIL=0

# pwsh is preinstalled on ubuntu-latest runners; require it in CI. Unlike
# test_runtime_registry_equivalence.sh there is no bash-only leg worth running
# on its own here -- without pwsh there is nothing to compare -- so a dev host
# without PowerShell skips the whole test rather than reporting a hollow pass.
if ! command -v pwsh >/dev/null 2>&1; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "FAIL: pwsh unavailable in CI (was preinstalled on ubuntu-latest)" >&2
        exit 1
    fi
    echo "NOTE: pwsh not installed locally; skipping generator equivalence" >&2
    echo "== Summary: SKIPPED (pwsh unavailable) =="
    exit 0
fi

# The PowerShell entry point correctly refuses on this Linux runner. Its guard
# is exercised against the real OS by test_powershell_platform_guard.ps1; this
# content-parity test needs to reach the generator body, so its child process
# presents a Windows OS value only for that invocation. There is no production
# bypass flag for callers to inherit or enable accidentally.
PWSH_GENERATOR_COMMAND="\$PSVersionTable.OS = 'Microsoft Windows'; & \$env:CLAUDE_DOCKER_PWSH_ENTRYPOINT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Digest of the committed compose files, sampled before and after the run. The
# sandbox already makes it structurally impossible to touch them; this makes
# that observable, so a future edit that reintroduces an in-repo generator run
# fails here instead of silently rewriting the working tree.
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

# make_sandbox NAME -- create a project root containing only what a generator
# reads and echo its path. scripts/ is copied wholesale rather than enumerated
# so the sandbox stays correct when a new lib module is added.
make_sandbox() {
    local dir="$WORK/$1"
    mkdir -p "$dir/tui/internal/config"
    cp -r "$PROJECT_ROOT/scripts" "$dir/scripts"
    cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$dir/tui/internal/config/"
    if [[ -f "$PROJECT_ROOT/VERSION" ]]; then
        cp "$PROJECT_ROOT/VERSION" "$dir/"
    fi
    printf '%s' "$dir"
}

# stage_and_run SANDBOX ENVFILE ASSIGNS LANG
# NUM_ACCOUNTS and IMAGE_TAG are unset for every run before ASSIGNS is applied,
# so a value left in the developer's shell cannot silently change what a
# fixture means.
stage_and_run() {
    local dir="$1" envfile="$2" assigns="$3" lang="$4"
    if [[ "$envfile" != "-" ]]; then
        cp "$FIXTURE_DIR/$envfile" "$dir/.env"
    fi
    local rc=0
    if [[ "$lang" == "bash" ]]; then
        # shellcheck disable=SC2086  # assigns is a deliberate word-split list
        env -u NUM_ACCOUNTS -u IMAGE_TAG $assigns \
            bash "$dir/scripts/generate-compose.sh" >"$dir/.gen.log" 2>&1 || rc=$?
    else
        # shellcheck disable=SC2086  # assigns is a deliberate word-split list
        env -u NUM_ACCOUNTS -u IMAGE_TAG $assigns \
            CLAUDE_DOCKER_PWSH_ENTRYPOINT="$dir/scripts/generate-compose.ps1" \
            pwsh -NoProfile -Command "$PWSH_GENERATOR_COMMAND" >"$dir/.gen.log" 2>&1 || rc=$?
    fi
    return "$rc"
}

for entry in "${FIXTURES[@]}"; do
    IFS='|' read -r name envfile assigns <<<"$entry"
    echo "== $name =="

    bash_dir="$(make_sandbox "$name-bash")"
    pwsh_dir="$(make_sandbox "$name-pwsh")"

    brc=0; stage_and_run "$bash_dir" "$envfile" "$assigns" bash || brc=$?
    prc=0; stage_and_run "$pwsh_dir" "$envfile" "$assigns" pwsh || prc=$?

    if [[ "$brc" -ne 0 || "$prc" -ne 0 ]]; then
        printf '  FAIL  %s: generator exited non-zero (bash=%d pwsh=%d)\n' "$name" "$brc" "$prc"
        sed 's/^/        /' "$bash_dir/.gen.log" "$pwsh_dir/.gen.log" || true
        FAIL=$((FAIL + 1))
        continue
    fi

    # Equivalence alone cannot catch a regression that makes *both* generators
    # ignore an input: two identically-wrong outputs still match. env-override
    # exists precisely because that path was broken (#315), so anchor it. If the
    # environment stopped reaching either generator this fixture would otherwise
    # keep passing while covering nothing.
    if [[ "$name" == "env-override" ]]; then
        services=$(grep -c '^    image: claude-code-base:' "$bash_dir/docker-compose.yml" || true)
        if [[ "$services" -eq 5 ]] && grep -q 'IMAGE_TAG:-probe-tag' "$bash_dir/docker-compose.yml"; then
            printf '  PASS  %s: environment NUM_ACCOUNTS and IMAGE_TAG reached the output\n' "$name"
            PASS=$((PASS + 1))
        else
            printf '  FAIL  %s: environment values did not reach the output (services=%s)\n' \
                "$name" "$services"
            grep -m1 'image: claude-code-base:' "$bash_dir/docker-compose.yml" | sed 's/^/        /' || true
            FAIL=$((FAIL + 1))
        fi
    fi

    for out in "${OUTPUTS[@]}"; do
        if [[ ! -f "$bash_dir/$out" || ! -f "$pwsh_dir/$out" ]]; then
            printf '  FAIL  %s/%s: not produced (bash=%s pwsh=%s)\n' "$name" "$out" \
                "$([[ -f "$bash_dir/$out" ]] && echo yes || echo no)" \
                "$([[ -f "$pwsh_dir/$out" ]] && echo yes || echo no)"
            FAIL=$((FAIL + 1))
            continue
        fi
        tr -d '\r' <"$bash_dir/$out" >"$WORK/lhs"
        tr -d '\r' <"$pwsh_dir/$out" >"$WORK/rhs"
        if diff -u --label "bash/$out" --label "pwsh/$out" "$WORK/lhs" "$WORK/rhs" >"$WORK/delta"; then
            printf '  PASS  %s/%s\n' "$name" "$out"
            PASS=$((PASS + 1))
        else
            printf '  FAIL  %s/%s\n' "$name" "$out"
            sed 's/^/        /' "$WORK/delta"
            FAIL=$((FAIL + 1))
        fi
    done
done

echo "== committed compose files =="
if [[ "$(compose_digest)" == "$DIGEST_BEFORE" ]]; then
    echo "  PASS  untouched by this run"
    PASS=$((PASS + 1))
else
    echo "  FAIL  a generator ran outside its sandbox and rewrote them"
    FAIL=$((FAIL + 1))
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
