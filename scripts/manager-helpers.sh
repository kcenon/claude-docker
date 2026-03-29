#!/usr/bin/env bash
# SRS-8.3.1–5: Manager helper functions for orchestration
# Source this file inside manager container: source /scripts/manager-helpers.sh
set -euo pipefail

# SRS-8.3.6: Verify Redis connectivity before any Redis operation
_require_redis() {
    _redis_cmd PING > /dev/null 2>&1 || { echo "Error: Redis unreachable" >&2; return 1; }
}

# Structured audit logging for security-sensitive operations
# Appends timestamped JSON entries to ${ARCHIVE_DIR}/audit.log
# Args: $1 = event type, $2..N = key=value pairs
# Sensitive values (tokens, passwords) are never logged.
log_audit() {
    [[ "${AUDIT_LOG:-true}" != "true" ]] && return 0

    local event="${1:?Usage: log_audit <event> [key=value ...]}"
    shift
    local archive_dir="${ARCHIVE_DIR:-/archive}"
    local audit_file="${archive_dir}/audit.log"

    local entry
    entry=$(jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg event "$event" \
        --arg host "$(hostname 2>/dev/null || echo 'unknown')" \
        '{timestamp: $ts, event: $event, host: $host}')

    for pair in "$@"; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        entry=$(jq -nc --argjson base "$entry" --arg k "$key" --arg v "$val" \
            '$base + {($k): $v}')
    done

    mkdir -p "$archive_dir"
    echo "$entry" >> "$audit_file"
}

# Helper: run redis-cli with optional password authentication (SRS-8.6.2)
# Constructs REDIS_URL at runtime from REDIS_HOST/REDIS_PORT/REDIS_PASSWORD
_redis_cmd() {
    local _host="${REDIS_HOST:-redis}"
    local _port="${REDIS_PORT:-6379}"
    local _url="redis://${_host}:${_port}"
    if [[ -n "${REDIS_PASSWORD:-}" ]]; then
        redis-cli -u "$_url" -a "$REDIS_PASSWORD" --no-auth-warning "$@"
    else
        redis-cli -u "$_url" "$@"
    fi
}

# SRS-8.3.1: Dispatch a task to a specific worker
# Args: $1 = worker name, $2 = prompt text, $3 = timeout (default 300s)
dispatch_task() {
    local worker="${1:?Usage: dispatch_task <worker> <prompt> [timeout]}"
    local prompt="${2:?Usage: dispatch_task <worker> <prompt> [timeout]}"
    local timeout="${3:-300}"
    local task_id
    task_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "task-$(date +%s)")"

    local auth_header=()
    if [[ -n "${WORKER_AUTH_TOKEN:-}" ]]; then
        auth_header=(-H "Authorization: Bearer ${WORKER_AUTH_TOKEN}")
    fi

    local prompt_hash
    prompt_hash="$(printf '%s' "$prompt" | sha256sum 2>/dev/null | cut -c1-16 || echo 'n/a')"

    log_audit "task_dispatch" \
        "taskId=${task_id}" \
        "worker=${worker}" \
        "timeout=${timeout}" \
        "promptLength=${#prompt}" \
        "promptHash=${prompt_hash}"

    # Use -w to capture HTTP status, -o to capture body
    local tmp_body
    tmp_body=$(mktemp)
    local http_status
    http_status=$(curl -s --connect-timeout 10 --max-time "$((timeout + 30))" \
        -o "$tmp_body" -w "%{http_code}" \
        -X POST "http://${worker}:9000/task" \
        -H "Content-Type: application/json" \
        "${auth_header[@]}" \
        -d "$(jq -nc --arg id "$task_id" --arg p "$prompt" --arg t "$timeout" \
            '{taskId: $id, prompt: $p, timeout: ($t | tonumber)}')")

    local body
    body=$(cat "$tmp_body")
    rm -f "$tmp_body"

    # Output body for callers that need it
    echo "$body"

    # Return non-zero for client/server errors so retry activates
    [[ "$http_status" =~ ^[45] ]] && return 1
    return 0
}

# Dispatch a task with retry and exponential backoff
# Args: $1 = worker name, $2 = prompt text, $3 = timeout (default 300s), $4 = max retries (default 2)
dispatch_task_with_retry() {
    local worker="${1:?Usage: dispatch_task_with_retry <worker> <prompt> [timeout] [retries]}"
    local prompt="${2:?}"
    local timeout="${3:-300}"
    local max_retries="${4:-2}"
    local delay=2

    local attempt=0
    while true; do
        if dispatch_task "$worker" "$prompt" "$timeout"; then
            return 0
        fi
        attempt=$((attempt + 1))
        if (( attempt > max_retries )); then
            echo "dispatch_task_with_retry: $worker failed after $((max_retries + 1)) attempts" >&2
            return 1
        fi
        echo "  Retry $attempt/$max_retries for $worker in ${delay}s..." >&2
        sleep "$delay"
        delay=$((delay * 2))
    done
}

# SRS-8.3.2: Dispatch same prompt to all workers in parallel
# Args: $1 = prompt text
dispatch_parallel() {
    local prompt="$1"
    local count="${WORKER_COUNT:-3}"
    local pids=() tmpfiles=()

    # Ensure temp files are cleaned up on error or exit
    _dp_cleanup() { for f in "${tmpfiles[@]}"; do rm -f "$f"; done; }
    trap _dp_cleanup EXIT ERR

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

    trap - EXIT ERR
    return "$failures"
}

# SRS-8.3.3: Retrieve all findings from Redis
get_findings() {
    local category="${1:-all}"
    _require_redis || return 1
    _redis_cmd LRANGE "findings:${category}" 0 -1
}

# SRS-8.3.7: Clear findings before new session
clear_findings() {
    _require_redis || return 1
    _redis_cmd DEL findings:all > /dev/null
    echo "Findings cleared."
}

# SRS-8.3.4: Get status of all workers
get_worker_status() {
    _require_redis || return 1
    local count="${WORKER_COUNT:-3}"
    for i in $(seq 1 "$count"); do
        echo "worker-$i: $(_redis_cmd GET "worker:worker-$i:status")"
    done
}

# SRS-8.3.5: Set shared context for all workers
# Args: $1 = field name, $2 = value
set_shared_context() {
    _require_redis || return 1
    local field="$1" value="$2"
    _redis_cmd HSET context:shared "$field" "$value"
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
    session_id="$(date -u +%Y%m%dT%H%M%SZ)_$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    local session_dir="$ARCHIVE_DIR/sessions/$session_id"
    mkdir -p "$session_dir"
    chmod 700 "$ARCHIVE_DIR" "$ARCHIVE_DIR/sessions" "$session_dir" 2>/dev/null || true

    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # --- Helper: Redis HGETALL → JSON object -----------------------------------
    _hgetall_json() {
        _redis_cmd HGETALL "$1" \
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
    all_findings="$(_redis_cmd LRANGE findings:all 0 -1 \
        | jq -Rn '[inputs | select(length > 0)]')"

    local by_category="{}"
    local cat_keys
    cat_keys="$(_redis_cmd KEYS 'findings:*' | grep -v '^findings:all$' || true)"
    if [[ -n "$cat_keys" ]]; then
        by_category="$(echo "$cat_keys" | while IFS= read -r key; do
            cat_name="${key#findings:}"
            items="$(_redis_cmd LRANGE "$key" 0 -1 \
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
    result_keys="$(_redis_cmd KEYS 'result:*' || true)"

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

    # --- 6. Size-based pruning: enforce MAX_ARCHIVE_SIZE_MB -------------------
    local max_size_mb="${MAX_ARCHIVE_SIZE_MB:-500}"
    local archive_size_mb
    archive_size_mb="$(du -sm "$ARCHIVE_DIR" 2>/dev/null | awk '{print $1}')"
    archive_size_mb="${archive_size_mb:-0}"

    while (( archive_size_mb > max_size_mb )); do
        local oldest_id
        oldest_id="$(jq -r '.sessions[0].id // empty' "$index_file")"
        [[ -z "$oldest_id" ]] && break

        # Don't prune the session we just saved
        [[ "$oldest_id" == "$session_id" ]] && break

        rm -rf "$ARCHIVE_DIR/sessions/$oldest_id"
        jq '.sessions |= .[1:]' "$index_file" > "${index_file}.tmp" \
            && mv "${index_file}.tmp" "$index_file"

        log_audit "session_prune" \
            "prunedSessionId=${oldest_id}" \
            "reason=archive_size_exceeded" \
            "limitMB=${max_size_mb}"

        archive_size_mb="$(du -sm "$ARCHIVE_DIR" 2>/dev/null | awk '{print $1}')"
        archive_size_mb="${archive_size_mb:-0}"
    done

    log_audit "session_save" \
        "sessionId=${session_id}" \
        "findings=${total_count}" \
        "tasks=${total_tasks}"

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
                _redis_cmd HSET context:shared "$key" "$val" > /dev/null
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
                _redis_cmd RPUSH findings:all "$finding" > /dev/null
            done
            # Restore per-category
            jq -r '.byCategory | keys[]' "${session_dir}/findings.json" 2>/dev/null | while IFS= read -r cat; do
                jq -r --arg c "$cat" '.byCategory[$c][]' "${session_dir}/findings.json" | while IFS= read -r f; do
                    _redis_cmd RPUSH "findings:${cat}" "$f" > /dev/null
                done
            done
            echo "  Restored findings: ${count} total"
        fi
    fi

    log_audit "session_restore" "sessionId=${session_id}"

    echo "Session restored: ${session_id}"
    echo "  Workers will see prior findings on their next task."
}

# SRS-8.5.5: List all archived sessions from index.json
# File-only — no Redis operations needed.
list_sessions() {
    local archive_dir="${ARCHIVE_DIR:-/archive}"
    local index_file="$archive_dir/index.json"

    if [ ! -f "$index_file" ]; then
        echo "No sessions archived yet."
        return 0
    fi

    local count
    count="$(jq '.sessions | length' "$index_file")"
    if [ "$count" -eq 0 ]; then
        echo "No sessions archived yet."
        return 0
    fi

    echo "Archived sessions ($count):"
    echo ""
    printf "  %-28s %-22s %8s %5s  %s\n" "SESSION ID" "ENDED" "FINDINGS" "TASKS" "CATEGORIES"
    printf "  %-28s %-22s %8s %5s  %s\n" "----------------------------" "----------------------" "--------" "-----" "----------"

    jq -r '.sessions[] | [
        .id,
        .endedAt,
        (.findingsCount | tostring),
        (.taskCount | tostring),
        (.categoryCounts | keys | join(", "))
    ] | @tsv' "$index_file" | while IFS=$'\t' read -r sid ended findings tasks cats; do
        printf "  %-28s %-22s %8s %5s  %s\n" "$sid" "$ended" "$findings" "$tasks" "$cats"
    done

    echo ""
    echo "Usage:"
    echo "  restore_session <ID>    Restore session findings into Redis"
    echo "  show_session <ID>       Show session details"
}

# SRS-8.5.6: Show detailed information for a specific archived session
# File-only — no Redis operations needed.
# Args: $1 = session ID (required)
show_session() {
    local session_id="${1:?Usage: show_session <session-id>}"
    local archive_dir="${ARCHIVE_DIR:-/archive}"
    local session_dir="$archive_dir/sessions/$session_id"

    [ ! -d "$session_dir" ] && { echo "Error: Session not found: $session_id" >&2; return 1; }

    # --- Metadata ---
    echo "--- Metadata ---"
    if [ -f "$session_dir/session.json" ]; then
        jq -r '"  ID:             " + .id,
               "  Started:        " + .startedAt,
               "  Ended:          " + .endedAt,
               "  Duration:       " + (.durationSeconds | tostring) + "s",
               "  Workers:        " + (.workerCount | tostring),
               "  Total tasks:    " + (.metrics.totalTasks | tostring),
               "  Completed:      " + (.metrics.completedTasks | tostring),
               "  Failed:         " + (.metrics.failedTasks | tostring),
               "  Total findings: " + (.metrics.totalFindings | tostring)' \
            "$session_dir/session.json"
    else
        echo "  (session.json missing)"
    fi

    # --- Findings by Category ---
    echo ""
    echo "--- Findings by Category ---"
    if [ -f "$session_dir/session.json" ]; then
        local cat_json
        cat_json="$(jq '.metrics.findingsByCategory // {}' "$session_dir/session.json")"
        if [ "$cat_json" = "{}" ]; then
            echo "  (none)"
        else
            echo "$cat_json" | jq -r 'to_entries[] | "  " + .key + ": " + (.value | tostring)'
        fi
    fi

    # --- Tasks ---
    echo ""
    echo "--- Tasks ---"
    if [ -f "$session_dir/session.json" ]; then
        local task_count
        task_count="$(jq '.tasks | length' "$session_dir/session.json")"
        if [ "$task_count" -eq 0 ]; then
            echo "  (no tasks)"
        else
            jq -r '.tasks[] | "  [" + (.status // "unknown") + "] " + (.taskId // "?") + " -- " + (.worker // "?") + " -- " + (.summary // "(no summary)") + " (" + (.findingsCount | tostring) + " findings)"' \
                "$session_dir/session.json"
        fi
    fi

    # --- Shared Context ---
    echo ""
    echo "--- Shared Context ---"
    if [ -f "$session_dir/context.json" ]; then
        local field_count
        field_count="$(jq '.fields | length' "$session_dir/context.json")"
        if [ "$field_count" -eq 0 ]; then
            echo "  (none)"
        else
            jq -r '.fields | to_entries[] | "  " + .key + ": " + .value' "$session_dir/context.json"
        fi
    else
        echo "  (context.json missing)"
    fi

    # --- Findings Preview (first 10) ---
    echo ""
    echo "--- Findings Preview (first 10) ---"
    if [ -f "$session_dir/findings.json" ]; then
        local total
        total="$(jq '.totalCount' "$session_dir/findings.json")"
        if [ "$total" -eq 0 ]; then
            echo "  (no findings)"
        else
            jq -r '.all[:10][] | if (. | type) == "string" then "  " + .
                else "  [" + (.severity // "info") + "] [" + (.category // "general") + "] " + (.summary // .)
                end' "$session_dir/findings.json"
            if [ "$total" -gt 10 ]; then
                echo "  ... and $((total - 10)) more"
            fi
        fi
    else
        echo "  (findings.json missing)"
    fi
}

# SRS-8.7.2: Run multi-persona analysis across all workers
# Loads personas from /scripts/personas.json, wraps the user prompt with each
# persona's instructions, dispatches in parallel, collects results, prints a
# categorized summary, and auto-saves the session.
# Args: $1 = user prompt, $2 = timeout per worker (default 300s)
run_analysis() {
    local prompt="${1:?Usage: run_analysis <prompt> [timeout]}"
    local timeout="${2:-300}"
    local personas_file="/scripts/personas.json"
    SECONDS=0

    # --- Validate prerequisites ------------------------------------------------
    _require_redis || return 1
    if [ ! -f "$personas_file" ]; then
        echo "Error: Personas file not found: $personas_file" >&2
        return 1
    fi

    local persona_count
    persona_count="$(jq '.personas | length' "$personas_file")"
    if [ "$persona_count" -eq 0 ]; then
        echo "Error: No personas defined in $personas_file" >&2
        return 1
    fi

    echo "=== Analysis started ($persona_count personas, timeout: ${timeout}s) ==="
    echo ""

    # --- Clear previous findings for clean run ---------------------------------
    clear_findings > /dev/null 2>&1

    # --- Circuit breaker: track unhealthy workers within this analysis ---------
    declare -A _unhealthy_workers

    # --- Dispatch each persona in parallel -------------------------------------
    local pids=() tmpfiles=() workers=() names=() categories=() icons=()

    # Ensure temp files are cleaned up on error or exit
    _ra_cleanup() { for f in "${tmpfiles[@]}"; do rm -f "$f"; done; }
    trap _ra_cleanup EXIT ERR

    while IFS= read -r entry; do
        local key name role worker icon category
        key="$(echo "$entry" | jq -r '.key')"
        name="$(echo "$entry" | jq -r '.value.name')"
        role="$(echo "$entry" | jq -r '.value.role')"
        worker="$(echo "$entry" | jq -r '.value.worker')"
        icon="$(echo "$entry" | jq -r '.value.icon')"
        category="$(echo "$entry" | jq -r '.value.category')"

        # Wrap user prompt with persona instructions
        local wrapped_prompt
        wrapped_prompt="Analyze the following from your perspective as ${role}: ${prompt}. Respond with JSON: {\"summary\":\"...\",\"findings\":[{\"category\":\"${category}\",\"summary\":\"...\"}],\"status\":\"done\"}"

        local tmp
        tmp=$(mktemp)
        tmpfiles+=("$tmp")
        workers+=("$worker")
        names+=("$name")
        categories+=("$category")
        icons+=("$icon")

        # Circuit breaker: skip workers marked unhealthy in this session
        if [[ -n "${_unhealthy_workers[$worker]:-}" ]]; then
            echo "  [$icon] SKIPPED $worker ($name) — marked unhealthy" >&2
            echo '{"status":"error","error":"circuit_breaker_open"}' > "$tmp"
            pids+=("") # placeholder
            continue
        fi

        echo "  [$icon] Dispatching to $worker ($name — $role)..."
        dispatch_task_with_retry "$worker" "$wrapped_prompt" "$timeout" 2 > "$tmp" 2>&1 &
        pids+=($!)
    done < <(jq -c '.personas | to_entries[]' "$personas_file")

    echo ""

    # --- Wait for all workers --------------------------------------------------
    local failures=0
    local i=0
    for pid in "${pids[@]}"; do
        if [[ -z "$pid" ]]; then
            # Circuit-breaker skipped worker
            failures=$((failures + 1))
        elif wait "$pid" 2>/dev/null; then
            :
        else
            failures=$((failures + 1))
            _unhealthy_workers["${workers[$i]}"]="1"
            echo "  Warning: ${names[$i]} (${workers[$i]}) failed — marked unhealthy" >&2
        fi
        i=$((i + 1))
    done

    trap - EXIT ERR

    # --- Get total findings count from Redis -----------------------------------
    local total_findings
    total_findings="$(_redis_cmd LLEN findings:all 2>/dev/null || echo "0")"

    local elapsed="$SECONDS"

    # --- Print categorized summary ---------------------------------------------
    echo "=== Analysis Complete ($total_findings findings, ${elapsed}s) ==="
    echo ""

    i=0
    for tmp in "${tmpfiles[@]}"; do
        local result_json status
        result_json="$(cat "$tmp")"
        rm -f "$tmp"

        status="$(echo "$result_json" | jq -r '.status // "unknown"' 2>/dev/null || echo "error")"

        # Get category findings count from Redis
        local cat_findings_count
        cat_findings_count="$(_redis_cmd LLEN "findings:${categories[$i]}" 2>/dev/null || echo "0")"

        echo "${categories[$i]} ($cat_findings_count):"

        if [ "$status" = "done" ] || [ "$status" = "partial" ]; then
            local findings_count
            findings_count="$(echo "$result_json" | jq '.findings | length' 2>/dev/null || echo "0")"
            if [ "$findings_count" -gt 0 ]; then
                echo "$result_json" | jq -r '.findings[] | "  - " + (.summary // "no description")' 2>/dev/null || true
            else
                echo "  (no findings)"
            fi
        elif [ "$status" = "error" ]; then
            local error_msg
            error_msg="$(echo "$result_json" | jq -r '.error // "unknown error"' 2>/dev/null || echo "unknown error")"
            echo "  Error: $error_msg"
        else
            echo "  (no response)"
        fi

        i=$((i + 1))
    done

    # --- Auto-save session -----------------------------------------------------
    echo ""
    save_session
}
