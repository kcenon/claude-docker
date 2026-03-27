#!/usr/bin/env bash
# E2E test: Tier B concurrent git safety
# Verifies that two containers can commit to separate worktrees simultaneously
# without conflicts or corruption.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
REPO_DIR="$TEMP_DIR/test-repo"

# Cleanup on exit
cleanup() {
    echo "=== Cleaning up ==="
    docker compose -f "$PROJECT_DIR/docker-compose.yml" \
        -f "$PROJECT_DIR/docker-compose.worktree.yml" \
        down --remove-orphans 2>/dev/null || true
    rm -rf "$TEMP_DIR"
    echo "Done."
}
trap cleanup EXIT

echo "=== Setting up test repository ==="
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"
git init
git config user.email "test@example.com"
git config user.name "Test User"
echo "initial" > README.md
git add README.md
git commit -m "Initial commit"

echo "=== Creating worktrees ==="
"$SCRIPT_DIR/setup-worktrees.sh" "$REPO_DIR" test-branch-a test-branch-b

WORKTREE_A="${REPO_DIR}-a"
WORKTREE_B="${REPO_DIR}-b"

echo "=== Building image ==="
docker compose -f "$PROJECT_DIR/docker-compose.yml" build

echo "=== Starting containers with worktree override ==="
PROJECT_DIR_A="$WORKTREE_A" \
PROJECT_DIR_B="$WORKTREE_B" \
    docker compose -f "$PROJECT_DIR/docker-compose.yml" \
        -f "$PROJECT_DIR/docker-compose.worktree.yml" \
        up -d

echo "=== Running parallel commits ==="
# Each container creates and commits a file in its own worktree
docker compose -f "$PROJECT_DIR/docker-compose.yml" \
    -f "$PROJECT_DIR/docker-compose.worktree.yml" \
    exec -T claude-a bash -c '
        cd /workspace
        git config user.email "a@test.com"
        git config user.name "Agent A"
        for i in $(seq 1 5); do
            echo "commit-a-$i" > "file-a-$i.txt"
            git add "file-a-$i.txt"
            git commit -m "Agent A: commit $i"
        done
    ' &
PID_A=$!

docker compose -f "$PROJECT_DIR/docker-compose.yml" \
    -f "$PROJECT_DIR/docker-compose.worktree.yml" \
    exec -T claude-b bash -c '
        cd /workspace
        git config user.email "b@test.com"
        git config user.name "Agent B"
        for i in $(seq 1 5); do
            echo "commit-b-$i" > "file-b-$i.txt"
            git add "file-b-$i.txt"
            git commit -m "Agent B: commit $i"
        done
    ' &
PID_B=$!

# Wait for both to complete
FAIL=0
wait "$PID_A" || FAIL=1
wait "$PID_B" || FAIL=1

if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: One or both containers failed during parallel commits"
    exit 1
fi

echo "=== Verifying results ==="

# Check worktree A has 5 commits from Agent A
COUNT_A=$(cd "$WORKTREE_A" && git log --oneline --author="Agent A" | wc -l | tr -d ' ')
if [ "$COUNT_A" -ne 5 ]; then
    echo "FAIL: Expected 5 commits from Agent A, got $COUNT_A"
    exit 1
fi

# Check worktree B has 5 commits from Agent B
COUNT_B=$(cd "$WORKTREE_B" && git log --oneline --author="Agent B" | wc -l | tr -d ' ')
if [ "$COUNT_B" -ne 5 ]; then
    echo "FAIL: Expected 5 commits from Agent B, got $COUNT_B"
    exit 1
fi

# Check no cross-contamination
CROSS_A=$(cd "$WORKTREE_A" && git log --oneline --author="Agent B" | wc -l | tr -d ' ')
CROSS_B=$(cd "$WORKTREE_B" && git log --oneline --author="Agent A" | wc -l | tr -d ' ')
if [ "$CROSS_A" -ne 0 ] || [ "$CROSS_B" -ne 0 ]; then
    echo "FAIL: Cross-contamination detected between worktrees"
    exit 1
fi

# Check git repo integrity
cd "$REPO_DIR"
git fsck --no-dangling > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "FAIL: Git repository integrity check failed"
    exit 1
fi

echo ""
echo "=== ALL TESTS PASSED ==="
echo "  Worktree A: $COUNT_A commits from Agent A (no cross-contamination)"
echo "  Worktree B: $COUNT_B commits from Agent B (no cross-contamination)"
echo "  Repository integrity: OK"
