# SVP: Software Verification Plan — claude-docker

**Status**: Active | **Version**: 1.0.0 | **Date**: 2026-03-30

**References**: [SRS](software-requirements-specification.md), [SDS](software-design-specification.md), [PRD](product-requirements-document.md), [threat-model.md](threat-model.md)

**Audience**: Developers verifying implementation correctness before each phase release.

---

## 1. Purpose and Scope

This plan specifies how each SRS requirement is verified. It expands the test
procedures in SRS §10.2 into executable verification steps, adds pass/fail
criteria, and groups procedures by phase and category.

**Scope**: Phases 1–6 (Phases 7+ deferred to future SVP revision).

**Out of scope**: Load testing, performance benchmarking beyond startup time,
long-running soak tests, and user acceptance testing.

---

## 2. Verification Approach

| Technique | When Used |
|-----------|-----------|
| **Static inspection** | Dockerfile, compose files, `.env.example` structure |
| **CLI verification** | `docker inspect`, `docker compose exec`, `redis-cli` |
| **Behavioral test** | Feature flags, auth flows, network isolation |
| **Script execution** | `scripts/test-orchestration.sh`, `scripts/setup-worktrees.sh` |
| **Negative test** | Confirm blocked/rejected operations (firewall, auth, read-only mounts) |

---

## 3. Environment Prerequisites

Before running any verification procedure:

```bash
# Build the base image
docker compose build

# Confirm Docker Compose V2 is installed
docker compose version   # must show v2.x (space-separated subcommand)

# Set required environment variables
cp .env.example .env
# Edit .env: set PROJECT_DIR, CLAUDE_API_KEY_A (Path B), or run auth (Path A)
```

For Phase 5+ orchestration procedures, also run:

```bash
# Install.sh generates WORKER_AUTH_TOKEN and REDIS_PASSWORD automatically
bash scripts/install.sh   # or set manually in .env
```

---

## 4. Verification Procedures by Phase

### 4.1 Phase 1 — Base Image (SRS §5.1)

| ID | SRS Spec | Procedure | Pass Criteria |
|----|----------|-----------|---------------|
| VP-1.1 | SRS-5.1.1 | `docker inspect claude-code-base:latest \| jq '.[0].Config.Image'` | Returns `node:20-slim` (Debian, not Alpine) |
| VP-1.2 | SRS-5.1.2 | `docker compose exec claude-a claude --version` | Exits 0; output contains version string |
| VP-1.3 | SRS-5.1.3 | `docker compose exec claude-a npm list -g \| grep @anthropic-ai/claude-code` | Package listed globally |
| VP-1.4 | SRS-5.1.4 | `docker compose exec claude-a git --version && gh --version` | Both exit 0 |
| VP-1.5 | SRS-5.1.5 | `docker compose exec claude-a node -e "console.log(v8.getHeapStatistics().heap_size_limit)"` | Value >= 4294967296 (4 GB) |
| VP-1.6 | SRS-5.1.6 | `docker inspect claude-code-base:latest \| jq '.[0].Config.WorkingDir'` | Returns `/workspace`, not `/` |
| VP-1.7 | SRS-5.1.7 | `docker compose exec claude-a node --version` | Version >= 20.0.0 |
| VP-1.8 | SRS-5.1.8 | `docker history claude-code-base:latest` | No `apt-get` cache layer > 1 MB; no `node_modules` in image layers |
| VP-1.9 | SRS-5.1.9 | Build image; `docker save \| tar -t \| grep -E '\.git\|node_modules'` | No matches |
| VP-1.10 | SRS-5.1.10 | `docker images claude-code-base --format '{{.Size}}'` | Size < 1 GB |
| VP-1.11 | SRS-5.1.11 | `docker compose exec manager redis-cli --version` | Exits 0 (Phase 5+ only) |
| VP-1.12 | SRS-5.1.12 | `docker compose exec worker-1 node -e "require('redis')"` | Exits 0 (Phase 5+ only) |
| VP-1.13 | SRS-5.1.13 | `docker compose exec worker-1 node -e "console.log(require.resolve('redis'))"` | Exits 0; path contains `node_modules` |

### 4.2 Phase 2 — Container Orchestration (SRS §5.2, §5.3, §6.1–6.3)

| ID | SRS Spec | Procedure | Pass Criteria |
|----|----------|-----------|---------------|
| VP-2.1 | SRS-5.2.1 | `docker compose config` | Validates without error; defines `claude-a` and `claude-b` services |
| VP-2.2 | SRS-5.2.4–5 | `docker compose exec claude-a ls /workspace /home/node/.claude` | Both paths exist and are distinct per container |
| VP-2.3 | SRS-5.2.6 | `docker volume ls \| grep node_modules` | `node_modules_a` and `node_modules_b` both listed |
| VP-2.4 | SRS-5.2.7 | `docker compose exec claude-a env \| grep CLAUDE_CONFIG_DIR` | Unique path per container |
| VP-2.5 | SRS-5.3.1 (Path A) | macOS: run `scripts/claude-docker auth`; Linux/WSL2: `claude auth login` inside container | `claude auth status` returns success inside container |
| VP-2.6 | SRS-5.3.2 (Path B) | Set `CLAUDE_API_KEY_A` in `.env`; `docker compose up -d`; `docker compose exec claude-a claude auth status` | Shows API key authentication |
| VP-2.7 | SRS-5.3.3 | Set both `CLAUDE_API_KEY_A` and OAuth credentials; verify API key takes precedence | `claude auth status` shows API key mode |
| VP-2.8 | SRS-4.5 | `cat .env.example \| grep -E 'CLAUDE_API_KEY\|REDIS_PASSWORD\|WORKER_AUTH_TOKEN'` | All values are placeholders (no real secrets) |
| VP-2.9 | SRS-4.5 | `cat .gitignore \| grep '\.env$'` | `.env` present in gitignore |
| VP-2.10 | SRS-6.1.1 (Linux) | `docker compose -f docker-compose.yml -f docker-compose.linux.yml config` | Validates without error; `user:` field present |
| VP-2.11 | SRS-6.2.1 (macOS) | Docker Desktop settings: File Sharing backend | VirtioFS selected |
| VP-2.12 | SRS-6.3.1–2 (Windows) | `echo $WSL_DISTRO_NAME` inside WSL2 terminal | Non-empty; `.env` PROJECT_DIR starts with `/home/` |

### 4.3 Phase 3 — Source Sharing (SRS §5.4)

| ID | SRS Spec | Procedure | Pass Criteria |
|----|----------|-----------|---------------|
| VP-3.1 | SRS-5.4.1 (Tier A) | Create `$PROJECT_DIR/test.txt`; `docker compose exec claude-a cat /workspace/test.txt` | File content visible in container |
| VP-3.2 | SRS-5.4.1 (Tier A) | Same file visible in both containers | Identical content in `claude-a` and `claude-b` |
| VP-3.3 | SRS-5.4.2 (Tier B) | Run `scripts/setup-worktrees.sh`; start Tier B compose; verify each container `/workspace` shows different branch | `git branch` output differs per container |
| VP-3.4 | SRS-5.4.3 | `docker volume ls \| grep node_modules` | Named volumes (not bind mounts) for `node_modules` |

### 4.4 Phase 4 — Hardening (SRS §7.2, §7.3)

| ID | SRS Spec | Procedure | Pass Criteria |
|----|----------|-----------|---------------|
| VP-4.1 | SRS-7.3 (firewall) | `docker compose -f docker-compose.yml -f docker-compose.firewall.yml up -d`; `docker compose exec claude-a curl -s --max-time 5 https://example.com` | Connection refused or timeout (blocked) |
| VP-4.2 | SRS-7.3 (firewall default) | Inspect `scripts/install.sh`; grep for `FIREWALL` default value | Default is `"yes"` (opt-out model) |
| VP-4.3 | SRS-4.4 (read-only) | Start container with `:ro` on project volume; `docker compose exec claude-a touch /workspace/canary.txt` | Command fails with "Read-only file system" |
| VP-4.4 | SRS-5.5 (cleanup) | Run `scripts/cleanup.sh`; verify worktree directories removed | No stale worktrees remain under `$PROJECT_DIR` |
| VP-4.5 | SRS-2.3 (state dir permissions) | `stat ~/.claude-state/account-a` | Mode `0700` (owner read/write/execute only) |
| VP-4.6 | SRS-7.3 (credential perms) | `stat ~/.claude-state/account-a/.credentials.json` | Mode `0600` |

### 4.5 Phase 5 — Orchestration (SRS §8.1–8.4)

| ID | SRS Spec | Procedure | Pass Criteria |
|----|----------|-----------|---------------|
| VP-5.1 | SRS-8.1.1 | `docker compose -f docker-compose.yml -f docker-compose.orchestration.yml ps` | `redis`, `manager`, `worker-1`, `worker-2`, `worker-3` all running |
| VP-5.2 | SRS-8.1.2–3 | `docker compose exec manager redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping` | Returns `PONG` |
| VP-5.3 | SRS-8.1.10 (Redis auth) | `docker compose exec manager redis-cli -u redis://redis:6379 PING` (no password) | Returns `NOAUTH` error |
| VP-5.4 | SRS-8.1.11 (internal network) | `docker network inspect orchestration-internal \| jq '.[0].Internal'` | Returns `true` |
| VP-5.5 | SRS-8.1.11 (host isolation) | From host: `curl -s --max-time 3 http://localhost:6379` | Connection refused |
| VP-5.6 | SRS-8.2.1–2 | `curl -s -X POST http://worker-1:9000/task -H "Authorization: Bearer $WORKER_AUTH_TOKEN" -H "Content-Type: application/json" -d '{"taskId":"t1","prompt":"hello"}'` | HTTP 200; body contains `status` field |
| VP-5.7 | SRS-8.2.17 (auth rejection) | `curl -s -o /dev/null -w "%{http_code}" -X POST http://worker-1:9000/task -H "Content-Type: application/json" -d '{}'` | Returns `401` |
| VP-5.8 | SRS-8.2.18 (startup warning) | Start worker with `WORKER_AUTH_TOKEN` unset; inspect startup logs | Warning message present in worker logs |
| VP-5.9 | SRS-8.2.8–9 | After task dispatch: `docker compose exec manager redis-cli -a "$REDIS_PASSWORD" GET worker:worker-1:status` | Returns `busy` or `idle` |
| VP-5.10 | SRS-8.2.12–14 | Send prompt without JSON block; check `result:{taskId}` hash | `status` field equals `partial` |
| VP-5.11 | SRS-8.2.15–16 | Restart Redis while worker is idle; wait 10s; check worker logs | Worker reconnects; heartbeat resumes |
| VP-5.12 | SRS-8.3.1–2 | `source /scripts/manager-helpers.sh && dispatch_task "worker-1" "test prompt" 30` | Exits 0; findings readable from Redis |
| VP-5.13 | SRS-8.3.3–4 | `get_findings && get_worker_status` | Both exit 0; `get_worker_status` output includes all 3 workers |
| VP-5.14 | SRS-8.3.6–7 | Stop Redis; call `get_worker_status` | Exits non-zero with error message (not silent crash) |
| VP-5.15 | SRS-8.4.1–5 | `bash scripts/test-orchestration.sh` | Exits 0; all checks pass |
| VP-5.16 | SRS-8.1.9 | `docker compose -f docker-compose.yml -f docker-compose.orchestration.yml config` | Validates without error |

### 4.6 Phase 6 — Production Hardening (SRS §8.1.10–11, §8.2.17–18, §8.3.5–7, §8.5)

| ID | SRS Spec | Procedure | Pass Criteria |
|----|----------|-----------|---------------|
| VP-6.1 | SRS-8.1.10 (Redis password) | `grep REDIS_PASSWORD scripts/install.sh` | `openssl rand -hex 32` pattern present |
| VP-6.2 | SRS-8.1.10 (Redis config) | `docker compose exec redis redis-cli CONFIG GET requirepass` | Non-empty password value |
| VP-6.3 | SRS-8.2.17 (timing-safe) | `grep timingSafeEqual scripts/worker-server.js` | `crypto.timingSafeEqual` present in auth middleware |
| VP-6.4 | SRS-8.3.5 (shell arithmetic) | `grep -n 'counter++' scripts/manager-helpers.sh` | No matches (only `$((counter + 1))` pattern allowed) |
| VP-6.5 | SRS-8.5.1–3 | Run `save_session`; `ls ~/.claude-state/analysis-archive/sessions/` | At least one session directory with `session.json`, `context.json`, `findings.json` |
| VP-6.6 | SRS-8.5.4 | `restore_session latest`; `redis-cli HGETALL context:shared` | Keys match archived context |
| VP-6.7 | SRS-8.5.8 | Save 52 sessions programmatically; `wc -l ~/.claude-state/analysis-archive/index.json` | At most 50 entries |
| VP-6.8 | SRS-8.5.10 | Start orchestration without `ARCHIVE_DIR` mount; run `dispatch_task` | Exits 0; no archive-related errors |
| VP-6.9 | SRS-8.5.14 | Run `save_session`; `redis-cli DBSIZE` before and after | Key count identical (read-only operation) |

---

## 5. Security Verification Checklist

These checks apply to all PRs touching auth, credentials, or network configuration.

| # | Check | How to Verify |
|---|-------|---------------|
| S-1 | Auth tokens do not appear in logs | `docker compose logs worker-1 \| grep -i "Bearer\|auth_token"` → no matches |
| S-2 | Secrets not in source | `git log --all -S 'WORKER_AUTH_TOKEN=' -- .env` → no commits with real value |
| S-3 | `.env.example` has placeholders only | `grep -E 'sk-ant-\|[0-9a-f]{64}' .env.example` → no matches |
| S-4 | Error responses do not leak internals | POST invalid JSON to `/task`; inspect 4xx body → no stack traces or internal paths |
| S-5 | Internal network truly internal | `docker run --rm --network orchestration-internal alpine curl redis:6379` from outside orchestration → connection refused |
| S-6 | Credential file permissions | `stat ~/.claude-state/*/credentials.json` → mode `0600` for all |

---

## 6. Regression Test Baseline

After each PR merge, confirm these baseline checks still pass:

```bash
# 1. Image builds
docker compose build --no-cache

# 2. Containers start
docker compose up -d && sleep 10 && docker compose ps

# 3. Orchestration E2E (Phase 5+)
docker compose -f docker-compose.yml -f docker-compose.orchestration.yml up -d
bash scripts/test-orchestration.sh
docker compose down -v
```

All three steps must exit 0 before the merge is considered stable.

---

## 7. Traceability to SRS §10.2

| SRS §10.2 Row | SVP Procedure |
|---------------|---------------|
| FR-1 | VP-1.1 |
| FR-2 | VP-1.2, VP-1.3 |
| FR-3 | VP-1.4, VP-1.5 |
| FR-4 | VP-1.6 |
| FR-5 | VP-1.9 |
| FR-6 | VP-2.2, VP-2.4 |
| FR-7 (Path A) | VP-2.5 |
| FR-8 (Path B) | VP-2.6 |
| FR-9 | VP-2.8, VP-2.9 |
| FR-10 | VP-3.1, VP-3.2 |
| FR-11 | VP-3.3 |
| FR-12 | VP-2.3, VP-3.4 |
| FR-13 | VP-3.3 |
| FR-14 | VP-4.1 |
| FR-15 | VP-4.3 |
| FR-16 | VP-4.5 (via `docker stats`) |
| FR-17 | VP-4.4 |
| FR-18 | VP-5.1, VP-5.2 |
| FR-19 | VP-5.6 |
| FR-20 | VP-5.12 (findings accumulation implicit) |
| FR-21 | VP-5.12, VP-5.13 |
| FR-22 | VP-5.16 |
| FR-23 | VP-5.9 |
| FR-24 | VP-5.15 |
| — (Redis tooling) | VP-1.11, VP-1.12 |
| — (JSON findings) | VP-5.10 |
| — (error recovery) | VP-5.11 |
| — (Bearer auth) | VP-5.7, VP-5.8 |
| — (Redis password) | VP-5.3 |
| — (internal network) | VP-5.4, VP-5.5 |
| — (manager resilience) | VP-5.14 |
| FR-25 | VP-6.5 |
| FR-26 | VP-6.6 |
| FR-27 | VP-6.5 (listing implicit) |
| FR-28 | VP-6.7 |
| FR-29 | VP-6.8 |
| — (NODE_PATH) | VP-1.13 |

---

## 8. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0.0 | 2026-03-30 | docs-team | Initial document: extracted from SRS §10.2; expanded to VP-1 through VP-6; added security checklist and regression baseline |
