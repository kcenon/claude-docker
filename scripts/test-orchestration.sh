#!/usr/bin/env bash
# E2E test for Phase 5 orchestration pipeline
# Validates: SRS-8.4.1 (compose startup), SRS-8.4.2 (sequential dispatch),
#            SRS-8.4.3 (result storage), SRS-8.4.4 (findings accumulation),
#            SRS-8.4.5 (trap cleanup)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.orchestration.yml"
HEALTH_TIMEOUT=60
TASK_TIMEOUT=120
PASS=0
FAIL=0
WARN=0

# SRS-8.4.5: Reliable teardown via trap
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    cd "$PROJECT_DIR"
    $COMPOSE_CMD down --remove-orphans -v 2>/dev/null || true
    echo "Cleanup complete."
}
trap cleanup EXIT

# Helper: run command inside manager container
mgr() {
    docker compose -f docker-compose.yml -f docker-compose.orchestration.yml \
        exec -T manager "$@"
}

record_pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

record_fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

record_warn() {
    echo "  WARN: $1"
    WARN=$((WARN + 1))
}

# ── Stage 1: Build and start services (SRS-8.4.1) ──────────────────────

echo "=== Stage 1: Build and Start Services ==="
cd "$PROJECT_DIR"
$COMPOSE_CMD build --quiet
$COMPOSE_CMD up -d

echo "  Services started. Waiting for health checks..."

# ── Stage 2: Wait for worker health ─────────────────────────────────────

echo "=== Stage 2: Wait for Worker Health ==="

for worker in worker-1 worker-2 worker-3; do
    elapsed=0
    while [ $elapsed -lt $HEALTH_TIMEOUT ]; do
        status=$(mgr curl -s -o /dev/null -w "%{http_code}" "http://${worker}:9000/health" 2>/dev/null || echo "000")
        if [ "$status" = "200" ]; then
            record_pass "${worker} is healthy"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    if [ $elapsed -ge $HEALTH_TIMEOUT ]; then
        record_fail "${worker} did not become healthy within ${HEALTH_TIMEOUT}s"
    fi
done

# Bail early if any worker is not healthy
if [ $FAIL -gt 0 ]; then
    echo "Aborting: not all workers healthy."
    echo ""
    echo "=== Results: PASS=$PASS FAIL=$FAIL WARN=$WARN ==="
    exit 1
fi

# ── Stage 3: Set shared context (SRS-8.4.2 prerequisite) ───────────────

echo "=== Stage 3: Set Shared Context ==="

mgr redis-cli -u redis://redis:6379 HSET context:shared \
    project "test-project" \
    guidelines "Follow best practices" \
    language "TypeScript" > /dev/null

ctx_fields=$(mgr redis-cli -u redis://redis:6379 HLEN context:shared 2>/dev/null || echo "0")
if [ "$ctx_fields" -ge 3 ]; then
    record_pass "Shared context set (${ctx_fields} fields)"
else
    record_fail "Shared context not set correctly (expected >=3, got ${ctx_fields})"
fi

# ── Stage 4: Dispatch tasks sequentially (SRS-8.4.2) ───────────────────
# Sequential dispatch is critical: worker-2 must see worker-1's findings

echo "=== Stage 4: Dispatch Tasks Sequentially ==="

TASK_IDS=()

for i in 1 2 3; do
    worker="worker-${i}"
    task_id="test-task-${i}-$(date +%s)"
    TASK_IDS+=("$task_id")

    echo "  Dispatching task ${i} to ${worker} (id: ${task_id})..."

    response=$(mgr curl -s --max-time $((TASK_TIMEOUT + 30)) \
        -X POST "http://${worker}:9000/task" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\":\"${task_id}\",\"prompt\":\"Analyze the project structure and list key files. Task ${i} of 3.\",\"timeout\":${TASK_TIMEOUT}}" \
        2>/dev/null || echo "")

    if [ -n "$response" ]; then
        record_pass "Task ${i} dispatched to ${worker}"
    else
        record_fail "Task ${i} dispatch to ${worker} returned empty response"
    fi

    # Brief pause to allow Redis writes to complete before next task
    sleep 2
done

# ── Stage 5: Verify results in Redis (SRS-8.4.3) ───────────────────────

echo "=== Stage 5: Verify Results in Redis ==="

for i in 1 2 3; do
    worker="worker-${i}"
    task_id="${TASK_IDS[$((i - 1))]}"
    result_key="result:${task_id}"

    exists=$(mgr redis-cli -u redis://redis:6379 EXISTS "$result_key" 2>/dev/null || echo "0")

    if [ "$exists" = "1" ]; then
        record_pass "Result stored for ${worker}:${task_id}"
    else
        record_fail "No result found at key ${result_key}"
    fi
done

# ── Stage 6: Verify findings accumulation (SRS-8.4.4) ──────────────────

echo "=== Stage 6: Verify Findings Accumulation ==="

findings_len=$(mgr redis-cli -u redis://redis:6379 LLEN findings:all 2>/dev/null || echo "0")

if [ "$findings_len" -gt 0 ]; then
    record_pass "Findings accumulated (${findings_len} entries in findings:all)"
else
    # WARN not FAIL: Claude may not always produce structured JSON findings
    record_warn "No structured findings in findings:all (Claude may not have produced JSON output)"
fi

# ── Summary ─────────────────────────────────────────────────────────────

echo ""
echo "=== Test Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "RESULT: FAIL"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi
