#!/usr/bin/env bash
# SRS-8.3.1–5: Manager helper functions for orchestration
# Source this file inside manager container: source /scripts/manager-helpers.sh
set -euo pipefail

# SRS-8.3.6: Verify Redis connectivity before any Redis operation
_require_redis() {
    redis-cli -u "$REDIS_URL" PING > /dev/null 2>&1 || { echo "Error: Redis unreachable" >&2; return 1; }
}

# SRS-8.3.1: Dispatch a task to a specific worker
# Args: $1 = worker name, $2 = prompt text, $3 = timeout (default 300s)
dispatch_task() {
    local worker="${1:?Usage: dispatch_task <worker> <prompt> [timeout]}"
    local prompt="${2:?Usage: dispatch_task <worker> <prompt> [timeout]}"
    local timeout="${3:-300}"
    local task_id
    task_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "task-$(date +%s)")"

    curl -s --max-time "$((timeout + 30))" \
        -X POST "http://${worker}:9000/task" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg taskId "$task_id" \
            --arg prompt "$prompt" \
            --argjson timeout "$timeout" \
            '{taskId: $taskId, prompt: $prompt, timeout: $timeout}'
        )"
}

# SRS-8.3.2: Dispatch same prompt to all workers in parallel
# Args: $1 = prompt text
dispatch_parallel() {
    local prompt="$1"
    local count="${WORKER_COUNT:-3}"
    local pids=() tmpfiles=()
    for i in $(seq 1 "$count"); do
        local tmp
        tmp=$(mktemp)
        tmpfiles+=("$tmp")
        dispatch_task "worker-$i" "$prompt" > "$tmp" 2>&1 &
        pids+=($!)
    done
    local failures=0
    for pid in "${pids[@]}"; do
        wait "$pid" || ((failures++))
    done
    for tmp in "${tmpfiles[@]}"; do cat "$tmp"; rm -f "$tmp"; done
    return "$failures"
}

# SRS-8.3.3: Retrieve all findings from Redis
get_findings() {
    local category="${1:-all}"
    _require_redis || return 1
    redis-cli -u "$REDIS_URL" LRANGE "findings:${category}" 0 -1
}

# SRS-8.3.7: Clear findings before new session
clear_findings() {
    _require_redis || return 1
    redis-cli -u "$REDIS_URL" DEL findings:all > /dev/null
    echo "Findings cleared."
}

# SRS-8.3.4: Get status of all workers
get_worker_status() {
    _require_redis || return 1
    local count="${WORKER_COUNT:-3}"
    for i in $(seq 1 "$count"); do
        echo "worker-$i: $(redis-cli -u "$REDIS_URL" GET "worker:worker-$i:status")"
    done
}

# SRS-8.3.5: Set shared context for all workers
# Args: $1 = field name, $2 = value
set_shared_context() {
    _require_redis || return 1
    local field="$1" value="$2"
    redis-cli -u "$REDIS_URL" HSET context:shared "$field" "$value"
}
