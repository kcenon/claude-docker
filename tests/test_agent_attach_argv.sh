#!/usr/bin/env bash
# test_agent_attach_argv.sh -- Verify the argv `claude-docker <runtime>` hands
# to `docker compose exec` is resolved entirely from the runtime registry.
#
# This is the keyless, daemon-free half of Epic #267 AC3 #2 ("`claude-docker
# gemini` attaches"), tracked by #289. The live half -- that the resolved
# service/binary actually execute inside a running container -- is covered by
# the `Gemini up/down smoke` CI job; what cannot be observed there is *which*
# service and argv the wrapper picked, because an interactive attach needs a
# TTY and a real credential. This test observes exactly that, with no Docker
# daemon and no API key.
#
# Method: put a stub `docker` earlier on PATH that records its argv and exits
# 0, then run the real `scripts/claude-docker` end to end. Nothing is faked
# inside the wrapper -- registry lookup, subcommand dispatch, service
# defaulting and flag translation all run for real; only the final process
# execution is intercepted.
#
# Only the tokens *after* `exec` are asserted. The preceding `-f` overlay list
# varies by host (docker-compose.linux.yml on Linux) and by .env
# (docker-compose.worktree.yml when PROJECT_DIR_A is set), and is the concern
# of build_compose_cmd, not of attach resolution. This mirrors how the Go
# side asserts the same boundary (tui/internal/docker/docker_test.go).
#
# AGENT_RUNTIME is passed in the environment, which agent_runtime() honors
# ahead of .env (scripts/lib/runtime.sh), so the repository's own .env is
# read but never written and the test leaves no trace.
#
# Run:  bash tests/test_agent_attach_argv.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_ROOT/scripts/claude-docker"

PASS=0
FAIL=0

TMP_DIR="$(mktemp -d)"
cleanup_tmp() {
    rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

STUB_DIR="$TMP_DIR/bin"
CAPTURE="$TMP_DIR/argv.txt"
mkdir -p "$STUB_DIR"

# Stub docker: record argv one token per line, succeed silently. One token per
# line keeps tokens containing spaces intact, which a flat string would lose.
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DOCKER_STUB_CAPTURE"
exit 0
STUB
chmod +x "$STUB_DIR/docker"

# attach_argv RUNTIME SUBCOMMAND [args...]
# Run the real CLI with the docker stub in front, then echo the captured
# tokens that follow `exec` (service name first), one per line.
attach_argv() {
    local runtime="$1"
    shift

    : > "$CAPTURE"
    AGENT_RUNTIME="$runtime" \
    DOCKER_STUB_CAPTURE="$CAPTURE" \
    PATH="$STUB_DIR:$PATH" \
        bash "$CLI" "$@" >/dev/null 2>&1

    local token seen_exec=0
    while IFS= read -r token; do
        if [[ "$seen_exec" -eq 1 ]]; then
            printf '%s\n' "$token"
        elif [[ "$token" == "exec" ]]; then
            seen_exec=1
        fi
    done < "$CAPTURE"
}

# assert_attach LABEL EXPECTED_NEWLINE_SEPARATED RUNTIME SUBCOMMAND [args...]
assert_attach() {
    local label="$1" expected="$2"
    shift 2

    local actual
    actual="$(attach_argv "$@")"

    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' \
            "$label" \
            "$(printf '%s' "$expected" | tr '\n' ' ')" \
            "$(printf '%s' "$actual" | tr '\n' ' ')"
        FAIL=$((FAIL + 1))
    fi
}

if [[ ! -x "$CLI" ]] && [[ ! -r "$CLI" ]]; then
    echo "FAIL: CLI not found at $CLI" >&2
    exit 1
fi

echo "== Gemini attach resolution (AC3 #2, keyless) =="

# Default service is the registry servicePrefix + '-a'; the binary is the
# registry `binary`. Neither is hardcoded in cmd_agent.
assert_attach "gemini -> exec gemini-a gemini" \
    "$(printf 'gemini-a\ngemini')" \
    gemini gemini

# --yolo is gemini's registry skipPermissionsFlag; it must survive to argv
# rather than being swallowed as a service name.
assert_attach "gemini --yolo -> appends registry skip flag" \
    "$(printf 'gemini-a\ngemini\n--yolo')" \
    gemini gemini --yolo

# The universal alias must be translated into the runtime's own flag, not
# passed through verbatim (gemini CLI has no --dangerously-skip-permissions).
assert_attach "gemini --dangerously-skip-permissions -> translated to --yolo" \
    "$(printf 'gemini-a\ngemini\n--yolo')" \
    gemini gemini --dangerously-skip-permissions

# An explicit service overrides the default while keeping the same binary.
assert_attach "gemini gemini-b -> exec gemini-b gemini" \
    "$(printf 'gemini-b\ngemini')" \
    gemini gemini gemini-b

# Service and flag together, in either order relative to each other.
assert_attach "gemini gemini-b --yolo -> both honored" \
    "$(printf 'gemini-b\ngemini\n--yolo')" \
    gemini gemini gemini-b --yolo

echo "== Regression baseline: claude and codex are unchanged =="

# The registry generalization must not have altered the two pre-existing
# runtimes; these assertions pin the behavior cmd_claude/cmd_codex had before
# they collapsed into cmd_agent (#270).
assert_attach "claude -> exec claude-a claude" \
    "$(printf 'claude-a\nclaude')" \
    claude claude

assert_attach "claude --dangerously-skip-permissions -> claude's own flag" \
    "$(printf 'claude-a\nclaude\n--dangerously-skip-permissions')" \
    claude claude --dangerously-skip-permissions

# codex carries a non-empty registry extraRunArgs, so its argv is not a plain
# [binary] -- it proves the argv builder splices extra args between the binary
# and the skip flag.
assert_attach "codex -> binary plus registry extraRunArgs" \
    "$(printf 'codex-a\ncodex\n-c\ncli_auth_credentials_store="file"')" \
    codex codex

assert_attach "codex --dangerously-bypass-approvals-and-sandbox -> extras then flag" \
    "$(printf 'codex-a\ncodex\n-c\ncli_auth_credentials_store="file"\n--dangerously-bypass-approvals-and-sandbox')" \
    codex codex --dangerously-bypass-approvals-and-sandbox

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
if (( FAIL > 0 )); then
    exit 1
fi
