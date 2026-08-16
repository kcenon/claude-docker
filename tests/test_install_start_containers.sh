#!/usr/bin/env bash
# test_install_start_containers.sh - start_containers on a native Linux host
# (issue #346).
#
# Run:  bash tests/test_install_start_containers.sh
# Exits non-zero on any failure.
#
# start_containers assigned to UID, which bash maintains as a readonly special
# variable. Under `set -euo pipefail` that aborted install.sh between
# build_compose_cmd and `docker compose up -d` -- after the image, the state
# directories, the TUI, authentication and the worktrees had all been set up.
# The user got "UID: readonly variable" and no containers.
#
# detect_platform returns wsl2 when /proc/version mentions microsoft, so macOS
# and WSL2 never reached the block. Native Linux is the only platform that did,
# and there it failed for every tier and every auth path -- which is also why
# no existing test caught it: PLATFORM is set explicitly here rather than
# detected.
#
# docker is stubbed. This test must never reach a daemon: the compose command
# it builds points at the working tree it runs from.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' \
            "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        missing: %s\n        in:      %s\n' \
            "$label" "$needle" "$haystack"
        FAIL=$((FAIL + 1))
    fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== No assignment to the readonly UID remains =="

# The .env emission writes UID as text inside an echo, so it does not match
# this pattern; a bare assignment at the start of a line does.
uid_assignments=$(grep -cE '^[[:space:]]*(export )?(UID|GID)=' "$PROJECT_ROOT/scripts/install.sh" || true)
assert_eq "install.sh assigns neither UID nor GID directly" "0" "$uid_assignments"

echo "== start_containers reaches docker compose up -d =="

mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
exit 0
STUB
chmod +x "$WORK/bin/docker"

status=0
(
    export CLAUDE_DOCKER_INSTALL_LIBRARY_ONLY=1
    export PATH="$WORK/bin:$PATH"
    export DOCKER_LOG="$WORK/docker.log"
    export HOME="$WORK/home"
    mkdir -p "$HOME"

    # shellcheck source=../scripts/install.sh
    . "$PROJECT_ROOT/scripts/install.sh"

    # The value detect_platform would return on a native Linux host. Set
    # explicitly because the runner may be WSL2, where the block never ran and
    # the defect is invisible.
    # shellcheck disable=SC2034
    PLATFORM=linux

    start_containers

    # Recorded from inside the subshell: build_compose_cmd is what must have
    # exported these, since nothing else does any more.
    printf 'UID=%s\n' "${UID:-unset}" > "$WORK/ids"
    printf 'GID=%s\n' "${GID:-unset}" >> "$WORK/ids"
    export -p | grep -E '^(declare -x |export )GID' > "$WORK/gid-export" || true
    printf '%s\n' "${COMPOSE_CMD[*]}" > "$WORK/compose-cmd"
) > "$WORK/out.log" 2>&1 || status=$?

assert_eq "start_containers exits 0 under set -euo pipefail" "0" "$status"

if [[ "$status" -ne 0 ]]; then
    echo "  --- captured output ---"
    sed 's/^/  /' "$WORK/out.log"
fi

if [[ -f "$WORK/docker.log" ]]; then
    assert_contains "docker was invoked with 'up -d'" "up -d" "$(cat "$WORK/docker.log")"
else
    assert_eq "docker was invoked" "invoked" "not invoked"
fi

echo "== build_compose_cmd still supplies UID/GID for the linux overlay =="

if [[ -f "$WORK/ids" ]]; then
    ids="$(cat "$WORK/ids")"
    assert_eq "UID matches id -u" "UID=$(id -u)" "$(printf '%s\n' "$ids" | grep '^UID=')"
    assert_eq "GID matches id -g" "GID=$(id -g)" "$(printf '%s\n' "$ids" | grep '^GID=')"
else
    assert_eq "ids were recorded" "recorded" "missing"
fi

# GID is not a bash special variable, so a child process seeing it proves the
# export happened rather than the value merely existing.
if [[ -s "$WORK/gid-export" ]]; then
    assert_eq "GID is exported" "exported" "exported"
else
    assert_eq "GID is exported" "exported" "not exported"
fi

if [[ -f "$WORK/compose-cmd" ]]; then
    assert_contains "the linux overlay is selected" "docker-compose.linux.yml" \
        "$(cat "$WORK/compose-cmd")"
fi

echo
echo "== Summary: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
