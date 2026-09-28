#!/usr/bin/env bash
# E2E test: Tier B concurrent git safety
# Verifies that N containers can commit to separate worktrees simultaneously
# without conflicts or corruption.
#
# Usage:
#   NUM_TEST_ACCOUNTS=3 scripts/test-concurrent-git.sh
set -euo pipefail

# Platform guard: refuse to run on native Windows shells (Git Bash, MSYS,
# Cygwin). This harness drives the worktree compose override directly, where
# MSYS path conversion exercises paths the PowerShell setup never produces and
# makes a passing result misleading.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: test-concurrent-git.sh is not supported on native Windows shells." >&2
        echo "Use: pwsh -ExecutionPolicy Bypass -File scripts\\test-concurrent-git.ps1" >&2
        exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT, not PROJECT_DIR. This used to be PROJECT_DIR, and the export
# further down sets PROJECT_DIR to the *compose volume source* -- one name for
# two things. Every `docker compose -f "$PROJECT_DIR/docker-compose.yml"`
# after that point resolved to the temporary test repo, which has no compose
# file, so under `set -euo pipefail` this script could not run past its first
# container start (#354, item 13).
#
# It stays unregistered in CI on purpose. This is a concurrency stress tool:
# it builds the image, creates N worktrees and starts N containers, which is
# the cost of gemini-up-smoke multiplied by the account count. Running it per
# PR buys little that isolated-up-smoke and the compose suites do not already
# cover. What was wrong was that being unregistered *hid a defect*; the defect
# is fixed, and tests/test_workflow_contracts.sh enforces registration for
# tests/ so nothing lands there unrun.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
REPO_DIR="$TEMP_DIR/test-repo"
NUM_TEST_ACCOUNTS="${NUM_TEST_ACCOUNTS:-2}"

# shellcheck source=lib/index.sh
. "$SCRIPT_DIR/lib/index.sh"

# Uppercase a single-letter string. Portable replacement for bash 4+ ${var^^}
# (macOS ships bash 3.2 which does not support the ^^ expansion).
to_upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# Cleanup on exit
cleanup() {
    echo "=== Cleaning up ==="
    docker compose -f "$REPO_ROOT/docker-compose.yml" \
        -f "$REPO_ROOT/docker-compose.worktree.yml" \
        down --remove-orphans 2>/dev/null || true
    rm -rf "$TEMP_DIR"
    echo "Done."
}
trap cleanup EXIT

echo "=== Setting up test repository ($NUM_TEST_ACCOUNTS accounts) ==="
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"
git init
git config user.email "test@example.com"
git config user.name "Test User"
echo "initial" > README.md
git add README.md
git commit -m "Initial commit"

echo "=== Creating worktrees ==="
BRANCHES=()
for i in $(seq 1 "$NUM_TEST_ACCOUNTS"); do
    BRANCHES+=("test-branch-$(index_to_letter "$i")")
done
"$SCRIPT_DIR/setup-worktrees.sh" "$REPO_DIR" "${BRANCHES[@]}"

echo "=== Building image ==="
NUM_ACCOUNTS="$NUM_TEST_ACCOUNTS" "$SCRIPT_DIR/generate-compose.sh"
docker compose -f "$REPO_ROOT/docker-compose.yml" build

echo "=== Starting containers with worktree override ==="
# Set env vars for docker compose
export PROJECT_DIR="$REPO_DIR"
for i in $(seq 1 "$NUM_TEST_ACCOUNTS"); do
    letter=$(index_to_letter "$i")
    upper=$(to_upper "$letter")
    export "PROJECT_DIR_${upper}=${REPO_DIR}-${letter}"
done

docker compose -f "$REPO_ROOT/docker-compose.yml" \
    -f "$REPO_ROOT/docker-compose.worktree.yml" \
    up -d

echo "=== Running parallel commits ==="
PIDS=()
for i in $(seq 1 "$NUM_TEST_ACCOUNTS"); do
    letter=$(index_to_letter "$i")
    upper=$(to_upper "$letter")
    svc="claude-${letter}"

    docker compose -f "$REPO_ROOT/docker-compose.yml" \
        -f "$REPO_ROOT/docker-compose.worktree.yml" \
        exec -T "$svc" bash -c "
            git config user.email '${letter}@test.com'
            git config user.name 'Agent ${upper}'
            for j in \$(seq 1 5); do
                echo 'commit-${letter}-\$j' > 'file-${letter}-\$j.txt'
                git add 'file-${letter}-\$j.txt'
                git commit -m 'Agent ${upper}: commit \$j'
            done
        " &
    PIDS+=($!)
done

# Wait for all to complete
FAIL=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAIL=1
done

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: One or more containers failed during parallel commits"
    exit 1
fi

echo "=== Verifying results ==="

for i in $(seq 1 "$NUM_TEST_ACCOUNTS"); do
    letter=$(index_to_letter "$i")
    upper=$(to_upper "$letter")
    worktree="${REPO_DIR}-${letter}"

    # Check worktree has 5 commits from its agent
    count=$(cd "$worktree" && git log --oneline --author="Agent ${upper}" | wc -l | tr -d ' ')
    if [ "$count" -ne 5 ]; then
        echo "FAIL: Expected 5 commits from Agent ${upper}, got $count"
        exit 1
    fi

    # Check no cross-contamination from other agents
    for j in $(seq 1 "$NUM_TEST_ACCOUNTS"); do
        if [ "$j" -eq "$i" ]; then continue; fi
        other_upper=$(to_upper "$(index_to_letter "$j")")
        cross=$(cd "$worktree" && git log --oneline --author="Agent ${other_upper}" | wc -l | tr -d ' ')
        if [ "$cross" -ne 0 ]; then
            echo "FAIL: Cross-contamination from Agent ${other_upper} in worktree-${letter}"
            exit 1
        fi
    done
done

# Check git repo integrity
cd "$REPO_DIR"
if ! git fsck --no-dangling > /dev/null 2>&1; then
    echo "FAIL: Git repository integrity check failed"
    exit 1
fi

echo ""
echo "=== ALL TESTS PASSED ==="
for i in $(seq 1 "$NUM_TEST_ACCOUNTS"); do
    letter=$(index_to_letter "$i")
    upper=$(to_upper "$letter")
    echo "  Worktree ${upper}: 5 commits from Agent ${upper} (no cross-contamination)"
done
echo "  Repository integrity: OK"
