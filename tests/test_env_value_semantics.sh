#!/usr/bin/env bash
# test_env_value_semantics.sh - bash and PowerShell read the same .env value
# the same way (issue #356, rows 5, 6 and 7).
#
# Run:  bash tests/test_env_value_semantics.sh
# Exits non-zero on any failure.
#
# Three keys where the two languages disagreed on what a value *means*, rather
# than on where to find it. Each is compared by running both implementations
# over the same input, because the interesting cases are the ones neither
# author considered: a leading zero, a capital letter, a quoted space.
#
#   row 5  CONTAINER_NODE_HEAP_MB  bash read 008 as octal and aborted on a
#          shell-internal error; pwsh cast it and got 8. 007 produced
#          --max-old-space-size=007 on one platform and =7 on the other, so
#          the same .env yielded byte-different compose files -- exactly what
#          test_compose_generator_equivalence.sh exists to prevent.
#
#   row 6  GH_AUTH_MODE            bash compared verbatim, pwsh lowercased
#          first, so GH_AUTH_MODE=Per-Account worked on Windows and exited 1
#          on Linux. Resolved by lowercasing on both, matching the treatment
#          ISOLATION_MODE already had on both sides.
#
#   row 7  ISOLATION_MODE          pwsh used IsNullOrWhiteSpace, so a quoted
#          " " read as unset and fell through to shared -- the weakest
#          boundary -- while bash rejected it. Resolved by treating whitespace
#          as a value on both, so it is reported rather than absorbed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; echo "        bash: $2"; echo "        pwsh: $3"; FAIL=$((FAIL + 1)); }

if ! command -v pwsh >/dev/null 2>&1; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "FAIL: pwsh unavailable in CI (it is preinstalled on ubuntu-latest)" >&2
        exit 1
    fi
    echo "NOTE: pwsh not installed locally; this suite compares two implementations" >&2
    echo "== Summary: SKIPPED (pwsh unavailable) =="
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../scripts/lib/parse_env.sh
. "$PROJECT_ROOT/scripts/lib/parse_env.sh"
# shellcheck source=../scripts/lib/resources.sh
. "$PROJECT_ROOT/scripts/lib/resources.sh"
# shellcheck source=../scripts/lib/index.sh
. "$PROJECT_ROOT/scripts/lib/index.sh"
# shellcheck source=../scripts/lib/isolation.sh
. "$PROJECT_ROOT/scripts/lib/isolation.sh"

PSM1="$PROJECT_ROOT/scripts/ClaudeDocker.psm1"

# ---------------------------------------------------------------------------
echo "=== row 5: CONTAINER_NODE_HEAP_MB is parsed base 10 on both sides ==="
# ---------------------------------------------------------------------------
#
# 008 is the discriminator: it is a valid decimal and an invalid octal, so a
# shell without 10# does not merely disagree -- it dies inside an arithmetic
# expansion before reaching its own diagnostic.

HEAP_CASES=(1 8 007 008 09 0700 3072 0 000 abc "" "3072 ")

ps_script=''
for v in "${HEAP_CASES[@]}"; do
    escaped=${v//\'/\'\'}
    ps_script+="try { Resolve-NodeHeapMib -MemLimit 4G -ConfiguredHeapMb '$escaped' } catch { 'REJECT' }
"
done
heap_out=$(pwsh -NoProfile -Command "
    Import-Module '$PSM1' -Force
    $ps_script
" 2>/dev/null | tr -d '\r')

i=0
while IFS= read -r pwsh_answer; do
    v="${HEAP_CASES[$i]}"
    if bash_answer=$(resolve_node_heap_mib 4G "$v" 2>/dev/null); then :; else bash_answer="REJECT"; fi
    if [ "$bash_answer" = "$pwsh_answer" ]; then
        pass "heap [$v] -> $bash_answer"
    else
        fail "heap [$v]" "$bash_answer" "$pwsh_answer"
    fi
    i=$((i + 1))
done <<< "$heap_out"

if [ "$i" -ne "${#HEAP_CASES[@]}" ]; then
    echo "  ERROR: compared $i of ${#HEAP_CASES[@]} heap cases; pwsh output was truncated" >&2
    exit 1
fi

# The compose files themselves, since byte-identical output is the contract
# test_compose_generator_equivalence.sh enforces and 007 broke it.
for v in 007 008; do
    dir="$WORK/heap-$v"
    mkdir -p "$dir/tui/internal/config"
    cp -r "$PROJECT_ROOT/scripts" "$dir/scripts"
    cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$dir/tui/internal/config/"
    [ -f "$PROJECT_ROOT/VERSION" ] && cp "$PROJECT_ROOT/VERSION" "$dir/"
    printf 'NUM_ACCOUNTS=1\nCONTAINER_NODE_HEAP_MB=%s\n' "$v" > "$dir/.env"

    if (cd "$dir" && bash scripts/generate-compose.sh >/dev/null 2>&1); then
        emitted=$(grep -o 'max-old-space-size=[0-9]*' "$dir/docker-compose.yml" | head -1)
        want="max-old-space-size=$((10#$v))"
        if [ "$emitted" = "$want" ]; then
            pass "compose for CONTAINER_NODE_HEAP_MB=$v emits $emitted"
        else
            fail "compose for CONTAINER_NODE_HEAP_MB=$v" "$emitted" "expected $want"
        fi
    else
        fail "generator for CONTAINER_NODE_HEAP_MB=$v" "exited non-zero" "expected success"
    fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== row 6: GH_AUTH_MODE casing agrees ==="
# ---------------------------------------------------------------------------

GH_CASES=(shared per-account Shared Per-Account PER-ACCOUNT SHARED bogus "")

ps_script=''
for v in "${GH_CASES[@]}"; do
    escaped=${v//\'/\'\'}
    ps_script+="\$m = '$escaped'
if ([string]::IsNullOrEmpty(\$m)) { \$m = 'shared' }
\$m = \$m.ToLowerInvariant()
if (\$m -in @('shared','per-account')) { \$m } else { 'REJECT' }
"
done
gh_out=$(pwsh -NoProfile -Command "$ps_script" 2>/dev/null | tr -d '\r')

# get_gh_auth_mode is defined inside scripts/claude-docker, which runs a
# dispatch at the end -- sourcing the file would execute it. The function
# definition is extracted instead, the same way
# scripts/test-entrypoint-settings.sh lifts generate_container_settings.
#
# This matters: restating the lowercase-and-compare here would only prove the
# test agrees with itself, which is the shape of check this issue is about.
gh_dir="$WORK/gh"
mkdir -p "$gh_dir/tui/internal/config"
cp -r "$PROJECT_ROOT/scripts" "$gh_dir/scripts"
cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$gh_dir/tui/internal/config/"
[ -f "$PROJECT_ROOT/VERSION" ] && cp "$PROJECT_ROOT/VERSION" "$gh_dir/"

GH_READER_SRC=$(sed -n '/^get_gh_auth_mode()/,/^}/p' "$PROJECT_ROOT/scripts/claude-docker")
if [ -z "$GH_READER_SRC" ]; then
    echo "  ERROR: could not extract get_gh_auth_mode from scripts/claude-docker" >&2
    exit 1
fi

read_bash_gh_mode() {
    ( PROJECT_ROOT="$gh_dir"
      # log_error is the only thing the extracted function needs from its file.
      log_error() { :; }
      # shellcheck source=/dev/null
      . "$gh_dir/scripts/lib/parse_env.sh"
      eval "$GH_READER_SRC"
      # shellcheck disable=SC2034 # reason: read by the eval'd get_gh_auth_mode
      GH_AUTH_MODE="$1"
      get_gh_auth_mode 2>/dev/null || printf 'REJECT' )
}

i=0
while IFS= read -r pwsh_answer; do
    v="${GH_CASES[$i]}"
    bash_answer=$(read_bash_gh_mode "$v")
    if [ "$bash_answer" = "$pwsh_answer" ]; then
        pass "GH_AUTH_MODE [$v] -> $bash_answer"
    else
        fail "GH_AUTH_MODE [$v]" "$bash_answer" "$pwsh_answer"
    fi
    i=$((i + 1))
done <<< "$gh_out"

if [ "$i" -ne "${#GH_CASES[@]}" ]; then
    echo "  ERROR: compared $i of ${#GH_CASES[@]} GH_AUTH_MODE cases" >&2
    exit 1
fi

# End to end: the generator must accept the capitalized form on both sides.
gh_e2e="$WORK/gh-e2e"
mkdir -p "$gh_e2e/tui/internal/config"
cp -r "$PROJECT_ROOT/scripts" "$gh_e2e/scripts"
cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$gh_e2e/tui/internal/config/"
[ -f "$PROJECT_ROOT/VERSION" ] && cp "$PROJECT_ROOT/VERSION" "$gh_e2e/"
printf 'NUM_ACCOUNTS=1\nGH_AUTH_MODE=Per-Account\nGH_USER_A=someone\nGH_TOKEN_A=tok\n' > "$gh_e2e/.env"

if (cd "$gh_e2e" && bash scripts/generate-compose.sh >/dev/null 2>&1); then
    pass "generate-compose.sh accepts GH_AUTH_MODE=Per-Account"
else
    fail "generate-compose.sh rejects GH_AUTH_MODE=Per-Account" "exit non-zero" "pwsh accepts it"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== row 7: a whitespace ISOLATION_MODE is a value, not 'unset' ==="
# ---------------------------------------------------------------------------
#
# The failure this prevents is asymmetric: falling through to shared is not
# merely different from erroring, it is the weakest boundary chosen silently.

iso_dir="$WORK/iso"
mkdir -p "$iso_dir/tui/internal/config"
cp -r "$PROJECT_ROOT/scripts" "$iso_dir/scripts"
cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$iso_dir/tui/internal/config/"
printf 'ISOLATION_MODE="   "\n' > "$iso_dir/.env"

bash_iso=$( ( PROJECT_ROOT="$iso_dir"
              # shellcheck source=/dev/null
              . "$iso_dir/scripts/lib/parse_env.sh"
              # shellcheck source=/dev/null
              . "$iso_dir/scripts/lib/isolation.sh"
              unset ISOLATION_MODE
              resolve_isolation_mode 2>/dev/null || printf 'REJECT' ) )

pwsh_iso=$(pwsh -NoProfile -Command "
    Import-Module '$PSM1' -Force
    \$env:ISOLATION_MODE = \$null
    try { Get-IsolationMode -ProjectRoot '$iso_dir' } catch { 'REJECT' }
" 2>/dev/null | tr -d '\r' | tail -1)

if [ "$bash_iso" = "REJECT" ] && [ "$pwsh_iso" = "REJECT" ]; then
    pass "whitespace ISOLATION_MODE is refused by both"
elif [ "$bash_iso" = "$pwsh_iso" ]; then
    fail "whitespace ISOLATION_MODE agreed but was not refused" "$bash_iso" "$pwsh_iso"
else
    fail "whitespace ISOLATION_MODE" "$bash_iso" "$pwsh_iso"
fi

# The negative: an unset mode must still resolve to shared on both, or the
# check above is satisfied by refusing everything.
printf 'NUM_ACCOUNTS=1\n' > "$iso_dir/.env"
bash_unset=$( ( PROJECT_ROOT="$iso_dir"
                # shellcheck source=/dev/null
                . "$iso_dir/scripts/lib/parse_env.sh"
                # shellcheck source=/dev/null
                . "$iso_dir/scripts/lib/isolation.sh"
                unset ISOLATION_MODE
                resolve_isolation_mode 2>/dev/null || printf 'REJECT' ) )
pwsh_unset=$(pwsh -NoProfile -Command "
    Import-Module '$PSM1' -Force
    \$env:ISOLATION_MODE = \$null
    try { Get-IsolationMode -ProjectRoot '$iso_dir' } catch { 'REJECT' }
" 2>/dev/null | tr -d '\r' | tail -1)

if [ "$bash_unset" = "shared" ] && [ "$pwsh_unset" = "shared" ]; then
    pass "an unset ISOLATION_MODE still resolves to shared on both"
else
    fail "unset ISOLATION_MODE" "$bash_unset" "$pwsh_unset"
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
