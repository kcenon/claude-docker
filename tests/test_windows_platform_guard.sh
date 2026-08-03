#!/usr/bin/env bash
# test_windows_platform_guard.sh — Verifies the native-Windows platform guard
# on every bash entry point that has a PowerShell counterpart.
#
# The guard cannot be observed by simply running on Windows: CI runners are
# Linux, so `uname -s` never reports a Git Bash kernel. Instead `uname` is
# shadowed on PATH by a stub that reports one. A `jq` stub sits beside it and
# appends to a marker file whenever it is called, which is what turns "the
# refusal happens before any runtime-registry read" (#306 acceptance criterion
# 2) into something observable: the guard has to fire first, so the marker must
# stay empty.
#
# Run:  bash tests/test_windows_platform_guard.sh
# Exits non-zero on any failure; prints a summary at the end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() {
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf '  FAIL  %s\n        %s\n' "$1" "$2"
    FAIL=$((FAIL + 1))
}

# Entry points that must carry the guard, paired with the PowerShell script
# their message has to name. An explicit list rather than a glob over
# scripts/*.sh, so that adding a bash entry point forces a deliberate decision
# to include or exclude it — the drift this list prevents is exactly how #306
# happened, #146 having guarded only the first two.
#
# Deliberately absent:
#   scripts/entrypoint.sh                runs only inside the container
#   scripts/test-entrypoint-settings.sh  no .ps1 counterpart to redirect to
GUARDED=(
    "scripts/install.sh|install.ps1"
    "scripts/claude-docker|claude-docker.ps1"
    "scripts/generate-compose.sh|generate-compose.ps1"
    "scripts/cleanup.sh|cleanup.ps1"
    "scripts/remove.sh|remove.ps1"
    "scripts/setup-worktrees.sh|setup-worktrees.ps1"
    "scripts/test-concurrent-git.sh|test-concurrent-git.ps1"
)

STUB_ROOT="$(mktemp -d)"
trap 'rm -rf "$STUB_ROOT"' EXIT

STUB_DIR="$STUB_ROOT/bin"
JQ_MARKER="$STUB_ROOT/jq-was-called"
mkdir -p "$STUB_DIR"

# Resolve the real uname now, while PATH is still clean, so the stub can
# delegate anything that is not `-s` without recursing into itself.
REAL_UNAME="$(command -v uname)"

cat > "$STUB_DIR/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then
    printf 'MINGW64_NT-10.0-26200\n'
    exit 0
fi
exec "$REAL_UNAME" "\$@"
EOF

# Records the call and fails, so a guard that let execution through would both
# leave evidence and not silently succeed against the real registry.
cat > "$STUB_DIR/jq" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$JQ_MARKER"
exit 1
EOF

chmod +x "$STUB_DIR/uname" "$STUB_DIR/jq"

check_guard() {
    local rel="$1" counterpart="$2"
    local script="$PROJECT_ROOT/$rel"
    local output rc=0

    if [ ! -f "$script" ]; then
        fail "$rel exists" "no such file"
        return
    fi

    : > "$JQ_MARKER"

    # stdin is closed so that a missing guard cannot stall on an interactive
    # prompt; stderr is folded in because the guard writes its message there.
    output="$(PATH="$STUB_DIR:$PATH" bash "$script" </dev/null 2>&1)" || rc=$?

    if [ "$rc" -eq 1 ]; then
        pass "$rel refuses with exit 1"
    else
        fail "$rel refuses with exit 1" "actual exit status: $rc"
    fi

    case "$output" in
        *"is not supported on native Windows shells"*)
            pass "$rel says why it refused" ;;
        *)
            fail "$rel says why it refused" "output was: ${output:-<empty>}" ;;
    esac

    case "$output" in
        *"$counterpart"*)
            pass "$rel points at $counterpart" ;;
        *)
            fail "$rel points at $counterpart" "output did not name it: ${output:-<empty>}" ;;
    esac

    if [ -s "$JQ_MARKER" ]; then
        fail "$rel refuses before any registry read" \
            "jq was invoked: $(tr '\n' ';' < "$JQ_MARKER")"
    else
        pass "$rel refuses before any registry read"
    fi
}

echo "=== Native-Windows platform guard ==="
for entry in "${GUARDED[@]}"; do
    check_guard "${entry%%|*}" "${entry##*|}"
done

# The guard must be conditional, not unconditional: on a supported platform the
# same scripts have to get past it. generate-compose.sh proves that cheaply,
# being non-interactive and needing no daemon.
#
# Skipped when this test is itself running on a native Windows shell, where the
# guard is supposed to fire and asserting the opposite would be wrong. CI runs
# on Linux, so the assertion is always made where it is meaningful.
echo
echo "=== Supported platform is unaffected ==="
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        printf '  SKIP  running on a native Windows shell, where the guard is correct to fire\n'
        printf '\nPassed: %d  Failed: %d\n' "$PASS" "$FAIL"
        [ "$FAIL" -eq 0 ]
        exit
        ;;
esac

# generate-compose.sh writes compose files into whatever it resolves as the
# project root, so it runs against a throwaway copy holding only the files it
# reads. Without that, merely running this test would rewrite the committed
# compose files from the caller's .env.
SANDBOX="$STUB_ROOT/project"
mkdir -p "$SANDBOX/scripts/lib" "$SANDBOX/tui/internal/config"
cp "$PROJECT_ROOT/scripts/generate-compose.sh" "$SANDBOX/scripts/"
cp "$PROJECT_ROOT"/scripts/lib/*.sh "$SANDBOX/scripts/lib/"
cp "$PROJECT_ROOT/tui/internal/config/runtimes.json" "$SANDBOX/tui/internal/config/"
if [ -f "$PROJECT_ROOT/VERSION" ]; then
    cp "$PROJECT_ROOT/VERSION" "$SANDBOX/"
fi

: > "$JQ_MARKER"
gen_rc=0
gen_out="$(bash "$SANDBOX/scripts/generate-compose.sh" </dev/null 2>&1)" || gen_rc=$?
if [ "$gen_rc" -eq 0 ]; then
    pass "generate-compose.sh still runs on this platform"
else
    fail "generate-compose.sh still runs on this platform" \
        "exit $gen_rc: ${gen_out:-<empty>}"
fi

case "$gen_out" in
    *"not supported on native Windows shells"*)
        fail "guard stays silent on a supported platform" "it fired anyway" ;;
    *)
        pass "guard stays silent on a supported platform" ;;
esac

echo
printf 'Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
