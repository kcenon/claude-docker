#!/usr/bin/env bash
# test_runtime_buildarg_binary.sh - per-runtime values come from the registry,
# not from a hand-typed constant (issue #356, rows 3 and 4).
#
# Run:  bash tests/test_runtime_buildarg_binary.sh
# Exits non-zero on any failure.
#
# Row 4 is the one with a consequence. The installer's version prompt is
# unconditional, so it runs for a codex or gemini install too -- and both
# installers wrote the answer as CLAUDE_CODE_VERSION regardless. The chosen
# runtime's own pin (CODEX_CLI_VERSION, GEMINI_CLI_VERSION) was therefore never
# set, and the number was passed to `docker compose build` under the Claude
# arg, where Dockerfile feeds it to the Claude installer.
#
# Row 3 is asymptomatic today: claude-docker.ps1's update path exec'd the
# registry *key* inside the container where the bash wrapper exec's the
# `binary` field. Those are the same string for all three registered runtimes,
# so this asserts the accessor exists and answers from the registry rather than
# trying to observe a difference that does not exist yet.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../scripts/lib/runtime.sh
. "$PROJECT_ROOT/scripts/lib/runtime.sh"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL + 1)); }

RUNTIMES=(claude codex gemini)

# ---------------------------------------------------------------------------
echo "=== the registry answers for every runtime ==="
# ---------------------------------------------------------------------------

declare -a EXPECT_BUILD_ARG=("CLAUDE_CODE_VERSION" "CODEX_CLI_VERSION" "GEMINI_CLI_VERSION")

i=0
for rt in "${RUNTIMES[@]}"; do
    got=$(runtime_field "$rt" buildArg)
    want="${EXPECT_BUILD_ARG[$i]}"
    if [ "$got" = "$want" ]; then
        pass "$rt buildArg -> $got"
    else
        fail "$rt buildArg" "got '$got', want '$want'"
    fi
    i=$((i + 1))
done

# ---------------------------------------------------------------------------
echo ""
echo "=== neither installer hardcodes a runtime's build arg ==="
# ---------------------------------------------------------------------------
#
# Comments may name CLAUDE_CODE_VERSION -- explaining the default runtime's
# variable is not the same as writing it into every install. Code may not.

for f in "$PROJECT_ROOT/scripts/install.sh" "$PROJECT_ROOT/scripts/install.ps1"; do
    name=$(basename "$f")
    hits=$(grep -nE '(CLAUDE_CODE_VERSION|CODEX_CLI_VERSION|GEMINI_CLI_VERSION)' "$f" \
        | grep -vE '^[0-9]+: *#' || true)
    if [ -z "$hits" ]; then
        pass "$name resolves the build arg from the registry"
    else
        fail "$name spells a runtime build arg in code" "$hits"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== the generator emits the selected runtime's build arg ==="
# ---------------------------------------------------------------------------
#
# End to end through the real generator: the compose file a codex install
# builds from must carry CODEX_CLI_VERSION and must not carry the Claude one.

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

i=0
for rt in "${RUNTIMES[@]}"; do
    dir="$WORK/$rt"
    mkdir -p "$dir/tui/internal/config"
    cp -r "$PROJECT_ROOT/scripts" "$dir/scripts"
    cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$dir/tui/internal/config/"
    [ -f "$PROJECT_ROOT/VERSION" ] && cp "$PROJECT_ROOT/VERSION" "$dir/"
    printf 'AGENT_RUNTIME=%s\nNUM_ACCOUNTS=1\n' "$rt" > "$dir/.env"

    if ! (cd "$dir" && bash scripts/generate-compose.sh >/dev/null 2>&1); then
        fail "$rt generator run" "generate-compose.sh exited non-zero"
        i=$((i + 1))
        continue
    fi

    want="${EXPECT_BUILD_ARG[$i]}"
    if grep -q "$want" "$dir/docker-compose.yml"; then
        pass "$rt compose carries $want"
    else
        fail "$rt compose is missing $want" "$(grep -n 'args:' -A3 "$dir/docker-compose.yml" | head -6)"
    fi

    # A non-claude runtime must not also carry the Claude arg.
    if [ "$rt" != "claude" ] && grep -q 'CLAUDE_CODE_VERSION' "$dir/docker-compose.yml"; then
        fail "$rt compose also carries CLAUDE_CODE_VERSION" "the wrong runtime would be pinned"
    elif [ "$rt" != "claude" ]; then
        pass "$rt compose does not carry CLAUDE_CODE_VERSION"
    fi
    i=$((i + 1))
done

# ---------------------------------------------------------------------------
echo ""
echo "=== the container binary comes from the registry, in both languages ==="
# ---------------------------------------------------------------------------

for rt in "${RUNTIMES[@]}"; do
    bash_binary=$(runtime_field "$rt" binary)
    if [ -n "$bash_binary" ]; then
        pass "$rt binary -> $bash_binary (bash)"
    else
        fail "$rt binary (bash)" "empty"
    fi
done

if command -v pwsh >/dev/null 2>&1; then
    for rt in "${RUNTIMES[@]}"; do
        dir="$WORK/$rt"
        pwsh_binary=$(pwsh -NoProfile -Command "
            Import-Module '$dir/scripts/ClaudeDocker.psm1' -Force
            Get-AgentBinary -ProjectRoot '$dir'
        " 2>/dev/null | tr -d '\r')
        bash_binary=$(runtime_field "$rt" binary)
        if [ "$pwsh_binary" = "$bash_binary" ]; then
            pass "$rt binary agrees across languages -> $bash_binary"
        else
            fail "$rt binary disagrees" "bash '$bash_binary' vs pwsh '$pwsh_binary'"
        fi
    done
else
    echo "  NOTE: pwsh unavailable; the cross-language half is skipped" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "  ERROR: pwsh is preinstalled on the CI runner; a skip here hides a failure" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== the Go fallback prefix comes from the registry ==="
# ---------------------------------------------------------------------------

if grep -qn 'prefix := config.RuntimeClaude' "$PROJECT_ROOT/tui/internal/docker/client.go"; then
    fail "client.go still uses the RuntimeClaude constant as a service prefix" \
        "it is a registry value spelled by hand"
else
    pass "client.go does not use RuntimeClaude as a prefix"
fi

if grep -q 'config.DefaultServicePrefix()' "$PROJECT_ROOT/tui/internal/docker/client.go"; then
    pass "client.go resolves its fallback prefix through the registry"
else
    fail "client.go has no registry lookup for the fallback prefix" "expected DefaultServicePrefix()"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$PASS" -eq 0 ]; then
    echo "  ERROR: no assertions ran" >&2
    exit 1
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
