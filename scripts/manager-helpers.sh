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

# SRS-8.5.1–8: Save current session to cold archive
# Dumps context, findings, and task results from Redis into timestamped
# session directory under $ARCHIVE_DIR/sessions/. Read-only on Redis (SRS-8.5.14).
# TODO: accept optional start_ts argument for duration calculation
save_session() {
    _require_redis || return 1
    ARCHIVE_DIR="${ARCHIVE_DIR:-/archive}"

    # --- Session ID & directory ------------------------------------------------
    local session_id
    session_id="$(date -u +%Y%m%dT%H%M%SZ)_$(head -c4 /dev/urandom | xxd -p)"
    local session_dir="$ARCHIVE_DIR/sessions/$session_id"
    mkdir -p "$session_dir"

    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --- Helper: Redis HGETALL → JSON object -----------------------------------
    _hgetall_json() {
        redis-cli -u "$REDIS_URL" HGETALL "$1" \
            | jq -Rn '[inputs | select(length > 0)] | if length == 0 then {} else [range(0;length;2) as $i | {(.[  $i]): .[$i+1]}] | add end'
    }

    # --- 1. context.json (SDS 5.6.2) ------------------------------------------
    local context_fields
    context_fields="$(_hgetall_json "context:shared")"
    jq -n \
        --arg version "1.0.0" \
        --arg capturedAt "$now" \
        --argjson fields "$context_fields" \
        '{version: $version, capturedAt: $capturedAt, fields: $fields}' \
        > "$session_dir/context.json"

    # --- 2. findings.json (SDS 5.6.2) -----------------------------------------
    local all_findings
    all_findings="$(redis-cli -u "$REDIS_URL" LRANGE findings:all 0 -1 \
        | jq -Rn '[inputs | select(length > 0)]')"

    local by_category="{}"
    local cat_keys
    cat_keys="$(redis-cli -u "$REDIS_URL" KEYS 'findings:*' | grep -v '^findings:all$' || true)"
    if [[ -n "$cat_keys" ]]; then
        by_category="$(echo "$cat_keys" | while IFS= read -r key; do
            cat_name="${key#findings:}"
            items="$(redis-cli -u "$REDIS_URL" LRANGE "$key" 0 -1 \
                | jq -Rn '[inputs | select(length > 0)]')"
            jq -n --arg k "$cat_name" --argjson v "$items" '{($k): $v}'
        done | jq -s 'add // {}')"
    fi

    local total_count
    total_count="$(echo "$all_findings" | jq 'length')"
    jq -n \
        --arg version "1.0.0" \
        --arg capturedAt "$now" \
        --argjson totalCount "$total_count" \
        --argjson all "$all_findings" \
        --argjson byCategory "$by_category" \
        '{version: $version, capturedAt: $capturedAt, totalCount: $totalCount, all: $all, byCategory: $byCategory}' \
        > "$session_dir/findings.json"

    # --- 3. session.json (SDS 5.6.2) ------------------------------------------
    local result_keys
    result_keys="$(redis-cli -u "$REDIS_URL" KEYS 'result:*' || true)"

    local tasks_json="[]"
    local completed=0 failed=0 total_tasks=0
    local findings_by_cat="{}"

    if [[ -n "$result_keys" ]]; then
        tasks_json="$(echo "$result_keys" | while IFS= read -r rkey; do
            rdata="$(_hgetall_json "$rkey")"
            findings_count="$(echo "$rdata" | jq '(.findings // "[]") | fromjson | length')"
            duration_ms="$(echo "$rdata" | jq -r '.durationMs // "0"')"
            jq -n \
                --argjson d "$rdata" \
                --argjson fc "$findings_count" \
                --argjson dm "$duration_ms" \
                '{taskId: $d.taskId, worker: $d.worker, status: $d.status, summary: $d.summary, findingsCount: $fc, durationMs: $dm, completedAt: $d.completedAt}'
        done | jq -s '.')"

        total_tasks="$(echo "$tasks_json" | jq 'length')"
        completed="$(echo "$tasks_json" | jq '[.[] | select(.status == "done")] | length')"
        failed="$(echo "$tasks_json" | jq '[.[] | select(.status == "error")] | length')"
        findings_by_cat="$(echo "$by_category" | jq 'to_entries | map({(.key): (.value | length)}) | add // {}')"
    fi

    jq -n \
        --arg version "1.0.0" \
        --arg id "$session_id" \
        --arg startedAt "$now" \
        --arg endedAt "$now" \
        --argjson durationSeconds 0 \
        --arg projectDir "/workspace" \
        --argjson workerCount "${WORKER_COUNT:-3}" \
        --argjson tasks "$tasks_json" \
        --argjson totalFindings "$total_count" \
        --argjson findingsByCategory "$findings_by_cat" \
        --argjson totalTasks "$total_tasks" \
        --argjson completedTasks "$completed" \
        --argjson failedTasks "$failed" \
        '{version: $version, id: $id, startedAt: $startedAt, endedAt: $endedAt,
          durationSeconds: $durationSeconds, projectDir: $projectDir, workerCount: $workerCount,
          tasks: $tasks,
          metrics: {totalFindings: $totalFindings, findingsByCategory: $findingsByCategory,
                    totalTasks: $totalTasks, completedTasks: $completedTasks, failedTasks: $failedTasks}}' \
        > "$session_dir/session.json"

    # --- 4. Update index.json (SRS-8.5.8) -------------------------------------
    local index_file="$ARCHIVE_DIR/index.json"
    local context_field_names
    context_field_names="$(echo "$context_fields" | jq '[keys[]]')"
    local cat_counts
    cat_counts="$(echo "$by_category" | jq 'to_entries | map({(.key): (.value | length)}) | add // {}')"

    local new_entry
    new_entry="$(jq -n \
        --arg id "$session_id" \
        --arg endedAt "$now" \
        --argjson findingsCount "$total_count" \
        --argjson categoryCounts "$cat_counts" \
        --argjson taskCount "$total_tasks" \
        --argjson contextFields "$context_field_names" \
        '{id: $id, endedAt: $endedAt, findingsCount: $findingsCount, categoryCounts: $categoryCounts, taskCount: $taskCount, contextFields: $contextFields}')"

    if [[ -f "$index_file" ]]; then
        local updated
        updated="$(jq --argjson entry "$new_entry" \
            '.sessions += [$entry]' "$index_file")"
        echo "$updated" > "${index_file}.tmp" && mv "${index_file}.tmp" "$index_file"
    else
        jq -n \
            --arg version "1.0.0" \
            --argjson maxSessions 50 \
            --argjson entry "$new_entry" \
            '{version: $version, maxSessions: $maxSessions, sessions: [$entry]}' \
            > "$index_file"
    fi

    # --- 5. Auto-prune oldest sessions if > 50 (SRS-8.5.8) --------------------
    local session_count
    session_count="$(jq '.sessions | length' "$index_file")"
    if (( session_count > 50 )); then
        local prune_ids
        prune_ids="$(jq -r ".sessions[:$((session_count - 50))][] | .id" "$index_file")"
        echo "$prune_ids" | while IFS= read -r old_id; do
            rm -rf "$ARCHIVE_DIR/sessions/$old_id"
        done
        jq ".sessions |= .[-50:]" "$index_file" > "${index_file}.tmp" \
            && mv "${index_file}.tmp" "$index_file"
    fi

    echo "Session saved: $session_id ($session_dir)"
}

# SRS-8.5.4, SRS-8.5.13: Restore a saved session from cold archive into Redis
# Loads context and findings back into Redis. Does NOT clear existing data —
# run clear_findings first if a clean restore is needed.
# Args: $1 = session ID or "latest"
restore_session() {
    _require_redis || return 1
    local session_id="${1:?Usage: restore_session <session-id|latest>}"
    local archive_dir="${ARCHIVE_DIR:-/archive}"

    # Resolve "latest" alias (SRS-8.5.13)
    if [ "$session_id" = "latest" ]; then
        [ ! -f "$archive_dir/index.json" ] && { echo "Error: No sessions found (index.json missing)" >&2; return 1; }
        session_id="$(jq -r '.sessions[-1].id // empty' "$archive_dir/index.json")"
        [ -z "$session_id" ] && { echo "Error: No sessions in archive" >&2; return 1; }
    fi

    local session_dir="${archive_dir}/sessions/${session_id}"
    [ ! -d "$session_dir" ] && { echo "Error: Session not found: $session_id" >&2; return 1; }

    # Restore context:shared from context.json
    if [ -f "${session_dir}/context.json" ]; then
        local field_count
        field_count="$(jq '.fields | length' "${session_dir}/context.json")"
        if [ "$field_count" -gt 0 ]; then
            jq -c '.fields | to_entries[]' "${session_dir}/context.json" | while IFS= read -r entry; do
                key="$(echo "$entry" | jq -r '.key')"
                val="$(echo "$entry" | jq -r '.value')"
                redis-cli -u "$REDIS_URL" HSET context:shared "$key" "$val" > /dev/null
            done
            echo "  Restored context:shared (${field_count} fields)"
        fi
    fi

    # Restore findings:all and per-category findings from findings.json
    if [ -f "${session_dir}/findings.json" ]; then
        local count
        count=$(jq '.totalCount' "${session_dir}/findings.json")
        if [ "$count" -gt 0 ]; then
            jq -r '.all[]' "${session_dir}/findings.json" | while IFS= read -r finding; do
                redis-cli -u "$REDIS_URL" RPUSH findings:all "$finding" > /dev/null
            done
            # Restore per-category
            jq -r '.byCategory | keys[]' "${session_dir}/findings.json" 2>/dev/null | while IFS= read -r cat; do
                jq -r --arg c "$cat" '.byCategory[$c][]' "${session_dir}/findings.json" | while IFS= read -r f; do
                    redis-cli -u "$REDIS_URL" RPUSH "findings:${cat}" "$f" > /dev/null
                done
            done
            echo "  Restored findings: ${count} total"
        fi
    fi

    echo "Session restored: ${session_id}"
    echo "  Workers will see prior findings on their next task."
}
