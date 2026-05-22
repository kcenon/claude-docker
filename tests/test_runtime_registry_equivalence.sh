#!/usr/bin/env bash
# test_runtime_registry_equivalence.sh -- Verify the three runtime-registry
# readers produce byte-identical output for every (runtime, field) pair.
#
# The registry tui/internal/config/runtimes.json is the cross-language
# single source of truth (see #267). It is read three ways:
#
#   1. bash runtime_field()      -- jq when available (the path CI exercises,
#                                   since ubuntu-latest ships jq).
#   2. bash _runtime_field_awk() -- the awk state-machine fallback used on
#                                   hosts without jq.
#   3. pwsh Get-RuntimeField     -- the PowerShell ConvertFrom-Json reader.
#
# All three must agree exactly; any drift between them fails CI loudly.
# This is the test that makes the registry an actual SSOT rather than three
# parsers that happen to agree today.
#
# Run:  bash tests/test_runtime_registry_equivalence.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PROJECT_ROOT

REGISTRY="$PROJECT_ROOT/tui/internal/config/runtimes.json"

# shellcheck source=../scripts/lib/parse_env.sh
. "$PROJECT_ROOT/scripts/lib/parse_env.sh"
# shellcheck source=../scripts/lib/runtime.sh
. "$PROJECT_ROOT/scripts/lib/runtime.sh"

if [[ ! -r "$REGISTRY" ]]; then
    echo "FAIL: runtime registry not found at $REGISTRY" >&2
    exit 1
fi

# The set of fields every runtime entry carries (see #268 / #267).
FIELDS=(
    binary servicePrefix stateDir containerHome hostConfigMount
    containerConfigMount configDirEnv configDirEnvValue configSourceEnv
    apiKeyVarPrefix sdkApiKeyVar buildArg installMethod skipPermissionsFlag
    configFormat bootstrapModule extraEnv extraRunArgs supportsUsage
    mountsAgentsSkills credentialFiles oauthCredentialFile
)

PASS=0
FAIL=0

# pwsh_runtime_field RUNTIME FIELD
# Invoke pwsh Get-RuntimeField and normalize the result to the convention
# the bash readers use:
#   - $null            -> ''     (absent value; matches bash empty string)
#   - [bool] $true/$false -> 'true'/'false'  (ConvertFrom-Json yields a
#     [bool]; its default ToString() is "True"/"False", but jq -r and the
#     awk fallback both emit lowercase JSON literals)
# String values pass through unchanged. This normalization is the pwsh
# analogue of the $null -> '' step in test_parse_env_equivalence.sh.
pwsh_runtime_field() {
    local runtime="$1" field="$2"
    pwsh -NoProfile -Command "
        Import-Module '$PROJECT_ROOT/scripts/ClaudeDocker.psm1' -Force
        \$v = Get-RuntimeField -ProjectRoot '$PROJECT_ROOT' -Runtime '$runtime' -Field '$field'
        if (\$null -eq \$v) { '' }
        elseif (\$v -is [bool]) { \$v.ToString().ToLowerInvariant() }
        else { \$v }
    "
}

# assert_field RUNTIME FIELD
# Read (RUNTIME, FIELD) via the jq path, the awk fallback, and -- when pwsh
# is available -- the PowerShell reader, and assert all readers agree.
assert_field() {
    local runtime="$1" field="$2"
    local jq_val awk_val pwsh_val
    jq_val=$(runtime_field "$runtime" "$field")
    awk_val=$(_runtime_field_awk "$REGISTRY" "$runtime" "$field")

    local ok=1
    if [[ "$jq_val" != "$awk_val" ]]; then
        ok=0
    fi
    if [[ "$HAVE_PWSH" -eq 1 ]]; then
        pwsh_val=$(pwsh_runtime_field "$runtime" "$field")
        if [[ "$jq_val" != "$pwsh_val" ]]; then
            ok=0
        fi
    fi

    if [[ "$ok" -eq 1 ]]; then
        printf '  PASS  %s.%s = %q\n' "$runtime" "$field" "$jq_val"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        if [[ "$HAVE_PWSH" -eq 1 ]]; then
            printf '  FAIL  %s.%s\n        jq:   %q\n        awk:  %q\n        pwsh: %q\n' \
                "$runtime" "$field" "$jq_val" "$awk_val" "${pwsh_val-}"
        else
            printf '  FAIL  %s.%s\n        jq:   %q\n        awk:  %q\n' \
                "$runtime" "$field" "$jq_val" "$awk_val"
        fi
    fi
}

# pwsh is preinstalled on ubuntu-latest runners; require it in CI but skip
# the pwsh leg locally so the test still exercises jq-vs-awk on dev hosts.
HAVE_PWSH=0
if command -v pwsh >/dev/null 2>&1; then
    HAVE_PWSH=1
elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "FAIL: pwsh unavailable in CI (was preinstalled on ubuntu-latest)" >&2
    exit 1
else
    echo "NOTE: pwsh not installed locally; comparing jq vs awk only" >&2
fi

# Likewise, jq is guaranteed inside the container image and on CI runners.
# Locally its absence just means runtime_field() already used the awk path,
# which still makes the jq-vs-awk assertion meaningful (it compares awk to
# awk -- harmless) but we surface a note for transparency.
if ! command -v jq >/dev/null 2>&1; then
    echo "NOTE: jq not installed; runtime_field() uses the awk fallback" >&2
fi

# Compare every (runtime, field) pair across all known runtimes.
while IFS= read -r runtime; do
    [[ -z "$runtime" ]] && continue
    echo "== $runtime =="
    for field in "${FIELDS[@]}"; do
        assert_field "$runtime" "$field"
    done
done < <(runtime_list)

# runtime_list itself must agree between bash and pwsh.
echo "== runtime_list =="
bash_list=$(runtime_list | sort | tr '\n' ' ')
if [[ "$HAVE_PWSH" -eq 1 ]]; then
    pwsh_list=$(pwsh -NoProfile -Command "
        Import-Module '$PROJECT_ROOT/scripts/ClaudeDocker.psm1' -Force
        (Get-RuntimeList -ProjectRoot '$PROJECT_ROOT' | Sort-Object) -join ' '
    ")
    pwsh_list="${pwsh_list% } "
    if [[ "$bash_list" == "$pwsh_list" ]]; then
        printf '  PASS  runtime_list = %s\n' "$bash_list"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  runtime_list\n        bash: %q\n        pwsh: %q\n' \
            "$bash_list" "$pwsh_list"
        FAIL=$((FAIL + 1))
    fi
else
    printf '  PASS  runtime_list (bash only) = %s\n' "$bash_list"
    PASS=$((PASS + 1))
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
