#!/usr/bin/env bash
# Verify repeated host bootstrap and failed copies without a Docker daemon.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/lib/bootstrap-common.sh
. "$PROJECT_ROOT/scripts/lib/bootstrap-common.sh"
# shellcheck source=../scripts/lib/bootstrap-claude.sh
. "$PROJECT_ROOT/scripts/lib/bootstrap-claude.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then
        printf '  PASS  %s\n' "$1"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

export CLAUDE_DOCKER_HOST_CONFIG_ROOT="$WORK/host"
export CLAUDE_CONFIG_DIR="$WORK/account"
unset CLAUDE_CONFIG_SOURCE
SOURCE="$CLAUDE_DOCKER_HOST_CONFIG_ROOT/.claude-host"
mkdir -p "$SOURCE/hooks" "$SOURCE/scripts" "$CLAUDE_CONFIG_DIR"
printf 'echo old\r\n' > "$SOURCE/hooks/guard.sh"
printf 'obsolete\n' > "$SOURCE/hooks/obsolete.sh"
printf 'echo status-old\r\n' > "$SOURCE/scripts/status.sh"
printf 'placeholder-account-state\n' > "$CLAUDE_CONFIG_DIR/.credentials.json"
runtime_bootstrap > "$WORK/first.log" 2>&1
check 'first boot copies and normalizes the hook' 'echo old' "$(cat "$CLAUDE_CONFIG_DIR/hooks/guard.sh")"

printf 'echo new\r\n' > "$SOURCE/hooks/guard.sh"
printf 'echo status-new\r\n' > "$SOURCE/scripts/status.sh"
rm "$SOURCE/hooks/obsolete.sh"
runtime_bootstrap > "$WORK/second.log" 2>&1
check 'next boot refreshes hooks' 'echo new' "$(cat "$CLAUDE_CONFIG_DIR/hooks/guard.sh")"
check 'next boot refreshes scripts' 'echo status-new' "$(cat "$CLAUDE_CONFIG_DIR/scripts/status.sh")"
check 'deleted host hooks disappear from the mirror' no "$([[ -e "$CLAUDE_CONFIG_DIR/hooks/obsolete.sh" ]] && echo yes || echo no)"
check 'account credentials survive refresh' placeholder-account-state "$(cat "$CLAUDE_CONFIG_DIR/.credentials.json")"

# A refresh failure must preserve the last complete mirror and block startup.
sed() { return 1; }
runtime_bootstrap > "$WORK/failed-refresh.log" 2>&1
unset -f sed
check 'failed refresh preserves the complete previous hook' 'echo new' \
    "$(cat "$CLAUDE_CONFIG_DIR/hooks/guard.sh" 2>/dev/null)"
check 'failed refresh records a blocking degradation' yes \
    "$([[ -n "$CLAUDE_DOCKER_DEGRADATIONS_BLOCKING" ]] && echo yes || echo no)"

CLAUDE_DOCKER_DEGRADATIONS_BLOCKING=''
export CLAUDE_CONFIG_DIR="$WORK/new-account"
sed() { return 1; }
runtime_bootstrap > "$WORK/failed-first.log" 2>&1
unset -f sed
check 'failed first boot leaves no empty hook in the account' no \
    "$([[ -e "$CLAUDE_CONFIG_DIR/hooks/guard.sh" ]] && echo yes || echo no)"
check 'failed first boot records a blocking degradation' yes \
    "$([[ -n "$CLAUDE_DOCKER_DEGRADATIONS_BLOCKING" ]] && echo yes || echo no)"
check 'failed first boot never reports copy success' no \
    "$(if grep -q 'copied and CRLF-normalized' "$WORK/failed-first.log"; then echo yes; else echo no; fi)"

mkdir -p "$WORK/legacy-hooks"
printf 'legacy-guard\n' > "$WORK/legacy-hooks/guard.sh"
ln -s "$WORK/legacy-hooks" "$CLAUDE_CONFIG_DIR/hooks"
sed() { return 1; }
runtime_bootstrap > "$WORK/failed-link-refresh.log" 2>&1
unset -f sed
check 'failed fallback refresh retains the previous hook link' "$WORK/legacy-hooks" \
    "$(readlink "$CLAUDE_CONFIG_DIR/hooks" 2>/dev/null)"
check 'failed fallback refresh retains the previous hook content' legacy-guard \
    "$(cat "$CLAUDE_CONFIG_DIR/hooks/guard.sh" 2>/dev/null)"

# Missing/unreadable input cannot replace a valid destination with an empty dir.
mkdir -p "$WORK/retained"
printf 'keep\n' > "$WORK/retained/guard.sh"
status=0
bootstrap_copy_dir "$WORK/no-such-source" "$WORK/retained" > "$WORK/missing.log" 2>&1 || status=$?
check 'missing copy source reports failure' 1 "$status"
check 'missing copy source retains the destination' keep "$(cat "$WORK/retained/guard.sh" 2>/dev/null)"

printf 'Summary: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
