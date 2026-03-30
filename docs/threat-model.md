# Threat Model — claude-docker

STRIDE-based threat analysis for the claude-docker system.

## Scope

This document covers threats to the following system boundaries:

1. **Host filesystem** — `.env`, `~/.claude-state/`, archive directory
2. **Container runtime** — Docker image, writable layers, bind mounts
3. **Orchestration network** — `orchestration-internal` bridge, Redis, worker HTTP API
4. **Authentication credentials** — OAuth tokens (Path A), API keys (Path B), `WORKER_AUTH_TOKEN`, `REDIS_PASSWORD`

Out of scope: threats to Anthropic's upstream servers, the host OS itself, or
network infrastructure outside the Docker host.

---

## System Architecture (Threat Surface View)

```
                         Host boundary
  ┌──────────────────────────────────────────────────────────────────┐
  │  ~/.env (mode 0600)         ~/.claude-state/account-*/           │
  │  WORKER_AUTH_TOKEN          .credentials.json (mode 0600)        │
  │  REDIS_PASSWORD             ANTHROPIC_API_KEY                    │
  │  CLAUDE_API_KEY_*                                                 │
  │                                                                   │
  │  ┌───────────────── orchestration-internal (internal: true) ──┐  │
  │  │                                                             │  │
  │  │  ┌──────────┐   HTTP POST /task   ┌──────────────────────┐ │  │
  │  │  │ manager  │ ──(Bearer token)──> │ worker-1/2/3         │ │  │
  │  │  │          │                     │ POST /task (port 9000)│ │  │
  │  │  │          │ <──────────────────  │ GET /health          │ │  │
  │  │  └─────┬────┘                     └──────────┬───────────┘ │  │
  │  │        │  redis://:PASS@redis:6379            │             │  │
  │  │        └──────────────────────────────────────┘             │  │
  │  │                          │                                  │  │
  │  │                   ┌──────┴──────┐                          │  │
  │  │                   │    Redis    │  requirepass REDIS_PASSWORD│  │
  │  │                   │  (port 6379)│                          │  │
  │  │                   └─────────────┘                          │  │
  │  └─────────────────────────────────────────────────────────────┘  │
  │                                                                   │
  │  claude-a / claude-b (base compose — external network access)     │
  └──────────────────────────────────────────────────────────────────┘
```

**Trust zones:**

| Zone | Trust Level | Description |
|------|-------------|-------------|
| Host OS / user | Full trust | Operator-controlled environment |
| `orchestration-internal` network | Constrained trust | Internal-only; no outbound access |
| Worker containers | Low trust | Run LLM-generated tool calls; treated as untrusted code |
| Base containers (`claude-a/b`) | Medium trust | Interactive sessions; user-supervised |
| Anthropic API | External | Outbound only; token auth via Bearer header |

---

## STRIDE Threat Table

### T-01 — Worker Token Spoofing

| Field | Value |
|-------|-------|
| **ID** | T-01 |
| **STRIDE** | Spoofing |
| **Component** | Worker HTTP API (`POST /task`) |
| **Threat** | An attacker with access to the internal Docker network sends a forged task request to a worker by impersonating the manager |
| **Attack vector** | Requires access to the `orchestration-internal` network (container escape or compromised container) |
| **Impact** | Worker executes arbitrary prompts; findings poisoned; LLM tool calls execute arbitrary code on the worker |
| **Existing controls** | `WORKER_AUTH_TOKEN` Bearer authentication (SRS-8.2.17); `crypto.timingSafeEqual` prevents timing oracle attacks; `orchestration-internal` network with `internal: true` limits who can reach port 9000 |
| **Residual risk** | If a container on the internal network is compromised, it can read the `WORKER_AUTH_TOKEN` env var and forge requests |
| **Recommendation** | Rotate `WORKER_AUTH_TOKEN` after any suspected container compromise; see [key-rotation.md](key-rotation.md) |

---

### T-02 — Redis Password Bypass

| Field | Value |
|-------|-------|
| **ID** | T-02 |
| **STRIDE** | Spoofing / Elevation of privilege |
| **Component** | Redis (`redis:6379`) |
| **Threat** | An attacker reads or writes Redis keys directly, bypassing the manager, by connecting to Redis without a password or with a stolen `REDIS_PASSWORD` |
| **Attack vector** | Container on `orchestration-internal` network; or a process that reads the env vars of any orchestration container |
| **Impact** | Arbitrary read/write of `context:shared`, `findings:*`, `result:*`, `worker:*` keys; can poison findings, replay old results, or delete session data |
| **Existing controls** | Redis `--requirepass` enforced (SRS-8.1.10); `REDIS_PASSWORD` auto-generated as 64-char hex by `install.sh`; `orchestration-internal` network prevents host-side direct access |
| **Residual risk** | All containers on the internal network share the same `REDIS_PASSWORD`; a compromised worker can access Redis directly |
| **Recommendation** | Keep `REDIS_PASSWORD` ≥ 32 bytes random; rotate after compromise; consider Redis ACLs for per-client permission scoping in a future hardening pass |

---

### T-03 — Credential File Exposure on Host

| Field | Value |
|-------|-------|
| **ID** | T-03 |
| **STRIDE** | Information disclosure |
| **Component** | `~/.claude-state/account-*/`, `.env` |
| **Threat** | Another local user or process reads OAuth tokens (`.credentials.json`) or API keys from `.env` / state directories |
| **Attack vector** | Local privilege escalation; misconfigured file permissions; shared host accounts |
| **Impact** | Account takeover; unauthorized Anthropic API usage; billing abuse |
| **Existing controls** | `install.sh` sets `chmod 600` on `.env` and all `.credentials.json` files; state directories set to `chmod 700` (SRS-8.1.8 implied) |
| **Residual risk** | Root processes bypass file permissions; if the host is shared, credentials remain accessible to root |
| **Recommendation** | Run on a dedicated single-user host or VM; do not share the host user account; rotate API keys on compromise |

---

### T-04 — `.env` Committed to Version Control

| Field | Value |
|-------|-------|
| **ID** | T-04 |
| **STRIDE** | Information disclosure |
| **Component** | `.env`, `WORKER_AUTH_TOKEN`, `REDIS_PASSWORD`, `CLAUDE_API_KEY_*` |
| **Threat** | `.env` containing secrets is accidentally committed to a public or shared repository |
| **Attack vector** | Operator error; missing or misconfigured `.gitignore` |
| **Impact** | All secrets exposed publicly; immediate credential compromise |
| **Existing controls** | `.gitignore` includes `.env`; `.env.example` ships with placeholder values and no real secrets; secret fields are commented out (no accidental copy-paste values) |
| **Residual risk** | A developer who manually adds `.env` with `git add -f` bypasses `.gitignore` |
| **Recommendation** | Pre-commit hook to scan for `sk-ant-` and `WORKER_AUTH_TOKEN=` patterns; periodic `git log --diff-filter=A -- .env` audits |

---

### T-05 — Prompt Injection via Findings

| Field | Value |
|-------|-------|
| **ID** | T-05 |
| **STRIDE** | Tampering / Elevation of privilege |
| **Component** | Redis `findings:all`, `context:shared`; worker prompt enrichment |
| **Threat** | Malicious content in the analyzed codebase is written to `findings:all` by one worker; a subsequent worker reads it as part of its enriched prompt and executes injected instructions |
| **Attack vector** | Adversarial code in the project under analysis; attacker-controlled source files |
| **Impact** | Worker executes injected LLM instructions; findings poisoned; potential tool call abuse (file writes, shell commands) |
| **Existing controls** | Workers mount source `:ro` (read-only); findings are stored as raw strings without server-side execution; no dynamic eval of findings content |
| **Residual risk** | LLM prompt injection is inherently difficult to prevent; a sufficiently crafted comment or string in source code could influence worker behavior |
| **Recommendation** | Document this risk for operators; do not run orchestration against untrusted repositories; future: sanitize findings before re-injecting into subsequent prompts |

---

### T-06 — Task Result Tampering

| Field | Value |
|-------|-------|
| **ID** | T-06 |
| **STRIDE** | Tampering |
| **Component** | Redis `result:{taskId}` keys |
| **Threat** | An attacker with Redis access overwrites task results after they are written, causing the manager to act on falsified analysis |
| **Attack vector** | Requires Redis access (T-02 precondition) |
| **Impact** | Manager makes decisions based on falsified findings; security issues hidden or fabricated |
| **Existing controls** | `result:{taskId}` keys have a 1-hour TTL and are written once by the worker; manager reads results immediately after dispatch |
| **Residual risk** | No integrity check (HMAC or signature) on Redis values; if Redis is compromised, all stored data is untrusted |
| **Recommendation** | If integrity is required, add HMAC signatures to result payloads in a future hardening pass |

---

### T-07 — Worker DoS via Task Flooding

| Field | Value |
|-------|-------|
| **ID** | T-07 |
| **STRIDE** | Denial of service |
| **Component** | Worker HTTP API (`POST /task`) |
| **Threat** | An attacker sends a high volume of task requests to a worker, exhausting memory or blocking legitimate tasks |
| **Attack vector** | Requires Bearer token (T-01 precondition) or unauthenticated access if `WORKER_AUTH_TOKEN` is unset |
| **Impact** | Worker becomes unresponsive; orchestration pipeline stalls; host RAM exhausted by concurrent `claude -p` processes |
| **Existing controls** | Workers process one task at a time (sequential); concurrent requests queue or are rejected; circuit breaker on Redis connection failures; container memory limit (2-4 GB) |
| **Residual risk** | No explicit per-IP or per-token rate limiting on `POST /task` |
| **Recommendation** | `WORKER_AUTH_TOKEN` must always be set in production; consider adding a rate limiter or task queue depth limit |

---

### T-08 — Audit Log Repudiation

| Field | Value |
|-------|-------|
| **ID** | T-08 |
| **STRIDE** | Repudiation |
| **Component** | Worker structured audit log (`logEvent`) |
| **Threat** | An attacker with container exec access clears or alters container stdout logs, removing evidence of unauthorized task execution |
| **Attack vector** | `docker compose exec` or container escape with write access to the container's log stream |
| **Impact** | Forensic record of task execution lost; cannot determine what prompts were sent or when |
| **Existing controls** | `logEvent` writes structured JSON to stdout; Docker captures stdout as container logs (`docker compose logs`); logs include `timestamp`, `worker`, `taskId`, `event` fields; token/password values are explicitly excluded |
| **Residual risk** | Container logs are ephemeral by default; if the container is removed, logs are lost unless forwarded to a persistent log collector |
| **Recommendation** | Forward container logs to a persistent sink (e.g., `docker compose logs > file`, fluentd, or a log aggregator) for forensic retention |

---

### T-09 — Docker Socket Exposure

| Field | Value |
|-------|-------|
| **ID** | T-09 |
| **STRIDE** | Elevation of privilege |
| **Component** | Docker daemon socket (`/var/run/docker.sock`) |
| **Threat** | A container mounts `/var/run/docker.sock` and uses it to escape to the host with full Docker daemon access |
| **Attack vector** | Misconfigured compose file; developer convenience mount |
| **Impact** | Full host compromise; ability to start privileged containers, read host filesystem, pivot to other hosts |
| **Existing controls** | No compose service mounts `/var/run/docker.sock`; explicitly documented in architecture.md as prohibited |
| **Residual risk** | Operator override (manually adding the mount) would not be detected automatically |
| **Recommendation** | If adopting a CI/CD pipeline, use Docker-in-Docker (dind) with a sidecar pattern rather than socket mounting |

---

### T-10 — OAuth Token Extraction from Keychain (macOS)

| Field | Value |
|-------|-------|
| **ID** | T-10 |
| **STRIDE** | Information disclosure |
| **Component** | macOS Keychain; `scripts/claude-docker auth` |
| **Threat** | A malicious process on the macOS host reads the Claude Code OAuth token from Keychain using the same `security find-generic-password` command |
| **Attack vector** | Any process running as the same macOS user; Keychain access control misconfiguration |
| **Impact** | OAuth token stolen; can be injected into other state directories or used directly with Anthropic services |
| **Existing controls** | macOS Keychain prompts the user for permission on first access from a new application; token is written to `~/.claude-state/account-*/` with `chmod 600` |
| **Residual risk** | Once the user approves a Keychain access, subsequent reads are silent; any approved process can re-read the token |
| **Recommendation** | Periodically audit Keychain access list (`Keychain Access.app > Access Control`); rotate tokens on suspected compromise |

---

## Threat Priority Matrix

| ID | Threat | Likelihood | Impact | Priority |
|----|--------|-----------|--------|----------|
| T-05 | Prompt injection via findings | High | High | **Critical** |
| T-04 | `.env` committed to VCS | Medium | High | **High** |
| T-03 | Credential file exposure on host | Medium | High | **High** |
| T-01 | Worker token spoofing | Low | High | **Medium** |
| T-02 | Redis password bypass | Low | High | **Medium** |
| T-07 | Worker DoS via task flooding | Medium | Medium | **Medium** |
| T-06 | Task result tampering | Low | Medium | **Low** |
| T-08 | Audit log repudiation | Low | Medium | **Low** |
| T-09 | Docker socket exposure | Very low | Critical | **Low** (mitigated by design) |
| T-10 | OAuth token extraction (macOS) | Low | High | **Low** (platform control) |

---

## Control Summary

| Control | Threats Mitigated | Implementation | PR |
|---------|-------------------|----------------|----|
| Bearer token auth (`WORKER_AUTH_TOKEN`) | T-01, T-07 | `scripts/worker-server.js`, `validateAuth()` | #97 |
| Timing-safe token comparison | T-01 | `crypto.timingSafeEqual` | #97 |
| Redis `--requirepass` | T-02 | `docker-compose.orchestration.yml` | #97 |
| `orchestration-internal` network (`internal: true`) | T-01, T-02, T-07 | `docker-compose.orchestration.yml` | #97 |
| Auto-generated 64-char hex secrets | T-01, T-02 | `scripts/install.sh` | #97 |
| Redis `maxmemory` + `allkeys-lru` eviction | T-07 | `docker-compose.orchestration.yml` | #98 |
| Redis AOF persistence | T-06 (partial) | `docker-compose.orchestration.yml` | #98 |
| `chmod 600/.env`, `chmod 600/.credentials.json` | T-03 | `scripts/install.sh` | #99 |
| Structured audit log (no secret fields) | T-08 | `logEvent()` in `worker-server.js` | #99 |
| `.env` in `.gitignore` + placeholder `.env.example` | T-04 | `.gitignore`, `.env.example` | #99 |
| Outbound firewall enabled by default | T-09 (depth) | `docker-compose.firewall.yml`, `scripts/install.sh` | #100 |
| Cold storage archive size limit (500 MB default, `MAX_ARCHIVE_SIZE_MB`) | T-03 (surface area) | `scripts/manager-helpers.sh` | #100 |
| Input validation on `POST /task` body | T-07 | `scripts/worker-server.js` | #101 |
| Circuit breaker on Redis connection | T-07 | `scripts/worker-server.js` | #101 |
| Workers mount source `:ro` | T-05 | `docker-compose.orchestration.yml` | #97 |
| No `/var/run/docker.sock` mount | T-09 | Architecture constraint | — |
| Startup warnings for missing secrets | T-01, T-02 | `scripts/worker-server.js`, `scripts/install.sh` | #102 |

---

## Out-of-Scope Items (Future Work)

| Item | Rationale |
|------|-----------|
| HMAC integrity on Redis values (T-06) | Requires key management infrastructure not yet present |
| Per-token rate limiting on `/task` (T-07) | Out of scope for current phase |
| Redis ACLs per client (T-02) | Adds operational complexity; deferred to production hardening |
| Prompt sanitization before re-injection (T-05) | Requires LLM-aware sanitization logic |
| Persistent log forwarding (T-08) | Operator-managed; outside tool scope |

---

## References

- [architecture.md — Security Considerations](architecture.md#security-considerations)
- [key-rotation.md — Key Rotation Procedure](key-rotation.md)
- [SRS-8.1.10, SRS-8.1.11, SRS-8.2.17, SRS-8.2.18](software-requirements-specification.md)
- PR #97 — Worker HTTP API and Redis authentication (`WORKER_AUTH_TOKEN`, `REDIS_PASSWORD`, `orchestration-internal` network)
- PR #98 — Redis memory limits, eviction policy, and AOF persistence
- PR #99 — Credential storage hardening and structured audit logging
- PR #100 — Firewall enabled by default, cold storage archive limits
- PR #101 — Retry logic, circuit breaker, input validation on worker API
- PR #102 — Startup warnings for missing secrets, dynamic scaling
- [Microsoft STRIDE Threat Modeling](https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats)
