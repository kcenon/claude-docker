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

# The fields every runtime entry carries, derived from the registry rather
# than restated here (see #268 / #267).
#
# This used to be a hand-maintained array of 23 names. It happened to match
# the registry, but nothing made it: a field added to runtimes.json got no
# three-way drift check and nothing announced the gap (#354, item 4). Deriving
# it means a new key is covered the moment it is added.
#
# jq when available, an awk fallback otherwise, mirroring how runtime_field
# itself reads the file -- a host without jq must still get the real field
# list, not a shorter one.
registry_fields() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '[.runtimes[] | keys[]] | unique | .[]' "$REGISTRY"
        return
    fi
    # Keys are two levels deep: .runtimes.<name>.<field>. Depth is tracked by
    # brace counting so a nested object cannot contribute its own keys.
    awk '
        /\{/ { depth++ }
        depth == 3 && match($0, /^[[:space:]]*"[A-Za-z0-9_]+"[[:space:]]*:/) {
            key = $0
            sub(/^[[:space:]]*"/, "", key)
            sub(/"[[:space:]]*:.*$/, "", key)
            if (!(key in seen)) { seen[key] = 1; print key }
        }
        /\}/ { depth-- }
    ' "$REGISTRY" | sort -u
}

FIELDS=()
while IFS= read -r _field; do
    [[ -n "$_field" ]] && FIELDS+=("$_field")
done < <(registry_fields)

if [[ "${#FIELDS[@]}" -eq 0 ]]; then
    echo "FAIL: no fields derived from $REGISTRY" >&2
    exit 1
fi
echo "Derived ${#FIELDS[@]} field(s) from the registry."

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
# FIELDS_WITH_A_VALUE records which derived fields were ever seen non-empty.
# Three readers agreeing is not, on its own, evidence: a field that does not
# exist agrees three ways and counted as PASS (#354, item 4).
#
#     runtime_field claude bogusField      -> ''
#     _runtime_field_awk ... bogusField    -> ''
#     equal = YES  -> PASS
#
# Requiring a value per runtime would be wrong -- extraEnv and extraRunArgs are
# legitimately empty for some runtimes, and the key still exists. The anchor is
# therefore per *field*: every field the registry declares must be populated by
# at least one runtime, checked after the loop. A field nobody populates is
# either dead or misspelled, and either way the three-way comparison over it
# proves nothing.
FIELDS_WITH_A_VALUE=""

assert_field() {
    local runtime="$1" field="$2"
    local jq_val awk_val pwsh_val
    jq_val=$(runtime_field "$runtime" "$field")
    awk_val=$(_runtime_field_awk "$REGISTRY" "$runtime" "$field")

    if [[ -n "$jq_val" ]]; then
        case "$FIELDS_WITH_A_VALUE" in
            *" $field "*) : ;;
            *) FIELDS_WITH_A_VALUE="$FIELDS_WITH_A_VALUE $field " ;;
        esac
    fi

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

# The anchor. Without it, three readers returning '' for a field that does not
# exist is indistinguishable from three readers agreeing on a real one.
echo "== every declared field is populated somewhere =="

# Known-unpopulated fields, each with the reason it is allowed to be. An
# unexplained entry here would be the same disease this test exists to treat,
# so the finding is stated rather than waived.
#
#   extraEnv -- empty for claude, codex and gemini. Its only reader is the Go
#   struct field ExtraEnv in tui/internal/config/runtime.go:38, and nothing
#   reads that. So it is declared, mapped, never populated and never
#   consumed. Removing it is a registry schema change across three readers
#   and belongs with the SSOT work in #356, not in a test change.
UNPOPULATED_ALLOWED=" extraEnv "

for field in "${FIELDS[@]}"; do
    case "$FIELDS_WITH_A_VALUE" in
        *" $field "*)
            PASS=$((PASS + 1))
            continue
            ;;
    esac
    case "$UNPOPULATED_ALLOWED" in
        *" $field "*)
            printf '  NOTE  %s is declared but empty for every runtime (known, see #356)\n' "$field"
            ;;
        *)
            printf '  FAIL  %s is declared in the registry but empty for every runtime\n' "$field"
            FAIL=$((FAIL + 1))
            ;;
    esac
done
printf '  PASS  %d field(s) checked for population\n' "${#FIELDS[@]}"

# And the negative case the derivation exists to make possible: a name that is
# not in the registry must not be in the derived list. All three readers
# return '' for it, so agreement cannot tell them apart -- only the list can.
echo "== a field the registry does not declare is not tested =="
case " ${FIELDS[*]} " in
    *" bogusField "*)
        printf '  FAIL  bogusField appears in the derived field list\n'
        FAIL=$((FAIL + 1))
        ;;
    *)
        printf '  PASS  bogusField is absent from the derived field list\n'
        PASS=$((PASS + 1))
        ;;
esac
bogus_jq=$(runtime_field claude bogusField)
if [[ -z "$bogus_jq" ]]; then
    printf '  PASS  a nonexistent field reads as empty (which is why the list is derived)\n'
    PASS=$((PASS + 1))
else
    printf '  FAIL  a nonexistent field returned %q\n' "$bogus_jq"
    FAIL=$((FAIL + 1))
fi

echo
printf '== Summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
