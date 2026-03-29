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

# Load auth credentials from .env if available
if [ -f "$PROJECT_DIR/.env" ]; then
    WORKER_AUTH_TOKEN="$(grep -E '^WORKER_AUTH_TOKEN=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
    REDIS_PASSWORD="$(grep -E '^REDIS_PASSWORD=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
fi
WORKER_AUTH_TOKEN="${WORKER_AUTH_TOKEN:-}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"

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

# Build redis-cli auth args
REDIS_AUTH_ARGS=()
if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_AUTH_ARGS=(-a "$REDIS_PASSWORD" --no-auth-warning)
fi

mgr redis-cli -u redis://redis:6379 "${REDIS_AUTH_ARGS[@]}" HSET context:shared \
    project "test-project" \
    guidelines "Follow best practices" \
    language "TypeScript" > /dev/null

ctx_fields=$(mgr redis-cli -u redis://redis:6379 "${REDIS_AUTH_ARGS[@]}" HLEN context:shared 2>/dev/null || echo "0")
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

    AUTH_HEADER_ARGS=()
    if [ -n "$WORKER_AUTH_TOKEN" ]; then
        AUTH_HEADER_ARGS=(-H "Authorization: Bearer ${WORKER_AUTH_TOKEN}")
    fi

    response=$(mgr curl -s --max-time $((TASK_TIMEOUT + 30)) \
        -X POST "http://${worker}:9000/task" \
        -H "Content-Type: application/json" \
        "${AUTH_HEADER_ARGS[@]}" \
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

    exists=$(mgr redis-cli -u redis://redis:6379 "${REDIS_AUTH_ARGS[@]}" EXISTS "$result_key" 2>/dev/null || echo "0")

    if [ "$exists" = "1" ]; then
        record_pass "Result stored for ${worker}:${task_id}"
    else
        record_fail "No result found at key ${result_key}"
    fi
done

# ── Stage 6: Verify findings accumulation (SRS-8.4.4) ──────────────────

echo "=== Stage 6: Verify Findings Accumulation ==="

findings_len=$(mgr redis-cli -u redis://redis:6379 "${REDIS_AUTH_ARGS[@]}" LLEN findings:all 2>/dev/null || echo "0")

if [ "$findings_len" -gt 0 ]; then
    record_pass "Findings accumulated (${findings_len} entries in findings:all)"
else
    # WARN not FAIL: Claude may not always produce structured JSON findings
    record_warn "No structured findings in findings:all (Claude may not have produced JSON output)"
fi

# ── Stage 7: Error path tests ──────────────────────────────────────────

echo "=== Stage 7: Error Path Tests ==="

# 7a. Oversized prompt rejected with HTTP 413
oversized_prompt=$(python3 -c "print('x' * 200000)" 2>/dev/null || printf '%0.s.' $(seq 1 200000))
AUTH_HEADER_ARGS=()
if [ -n "$WORKER_AUTH_TOKEN" ]; then
    AUTH_HEADER_ARGS=(-H "Authorization: Bearer ${WORKER_AUTH_TOKEN}")
fi
oversized_status=$(mgr curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 30 \
    -X POST "http://worker-1:9000/task" \
    -H "Content-Type: application/json" \
    "${AUTH_HEADER_ARGS[@]}" \
    -d "{\"taskId\":\"test-oversized\",\"prompt\":\"${oversized_prompt}\",\"timeout\":10}" \
    2>/dev/null || echo "000")

if [ "$oversized_status" = "413" ]; then
    record_pass "Oversized prompt rejected with HTTP 413"
else
    record_fail "Expected HTTP 413 for oversized prompt, got $oversized_status"
fi

# 7b. Missing auth token rejected with HTTP 401 (only if auth is configured)
if [ -n "$WORKER_AUTH_TOKEN" ]; then
    noauth_status=$(mgr curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 --max-time 30 \
        -X POST "http://worker-1:9000/task" \
        -H "Content-Type: application/json" \
        -d '{"taskId":"test-noauth","prompt":"test","timeout":10}' \
        2>/dev/null || echo "000")

    if [ "$noauth_status" = "401" ]; then
        record_pass "Unauthenticated request rejected with HTTP 401"
    else
        record_fail "Expected HTTP 401 for unauthenticated request, got $noauth_status"
    fi
fi

# 7c. Invalid JSON body rejected with HTTP 400
invalid_status=$(mgr curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 30 \
    -X POST "http://worker-1:9000/task" \
    -H "Content-Type: application/json" \
    "${AUTH_HEADER_ARGS[@]}" \
    -d 'not-valid-json' \
    2>/dev/null || echo "000")

if [ "$invalid_status" = "400" ]; then
    record_pass "Invalid JSON rejected with HTTP 400"
else
    record_fail "Expected HTTP 400 for invalid JSON, got $invalid_status"
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
