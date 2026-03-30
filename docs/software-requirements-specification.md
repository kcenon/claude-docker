# SRS: Dual Claude Code Container Architecture

**Status**: Active | **Version**: 1.1.0 | **Date**: 2026-03-30

**References**: [product-requirements-document.md](product-requirements-document.md) (PRD), [architecture.md](architecture.md), [cross-platform.md](cross-platform.md)

**Audience**: Developers implementing or maintaining this system.

---

## 1. Introduction

### 1.1 Purpose

This SRS specifies the technical requirements for a Docker-based system
that runs N Claude Code instances simultaneously on a single host with
isolated account state and shared source code. A developer should be able
to implement the Dockerfile, compose file, and scripts using only this
document.

### 1.2 Scope

The system consists of: one Docker image, N containers, host-side state
directories, and orchestration via Docker Compose. It supports Linux,
macOS, and Windows (WSL2), three authentication paths (host-side Keychain
extraction on macOS, container-internal OAuth on Linux/WSL2, and Console
API key), and two source-sharing tiers (shared bind mount and git worktree).

### 1.3 Definitions

| Term | Definition |
|------|-----------|
| Path A | Subscription OAuth authentication (Pro/Max/Team): host-side Keychain extraction on macOS, container-internal OAuth on Linux/WSL2 |
| Path B | `ANTHROPIC_API_KEY` environment variable for Console accounts |
| Tier A | Both containers share a single bind-mounted project directory |
| Tier B | Each container mounts a separate git worktree from the same repository |
| State directory | Host directory (`~/.claude-state/account-X/`) containing per-account credentials, settings, and history |

### 1.4 Conventions

- **SRS-n.n**: Specification identifier (e.g., SRS-6.1). Maps to PRD FR-n in the verification matrix.
- **SHALL**: Mandatory requirement. **SHOULD**: Recommended. **MAY**: Optional.

---

## 2. System Overview

```
Host (Linux / macOS / Windows+WSL2)
+-- ~/.claude-state/
|   +-- account-a/              State directory A (bind mount)
|   +-- account-b/              State directory B (bind mount)
|   +-- account-N/              Extensible to N accounts
+-- ~/work/project/             Source code (Tier A: shared, Tier B: worktrees)
+-- Docker
    +-- claude-code-base:latest  Single shared image (~800 MB)
    +-- claude-a                 Container A  ─┐
    +-- claude-b                 Container B  ─┤ Same image, different state
    +-- claude-N                 Container N  ─┘
```

**System boundary**: This system manages container lifecycle, account
isolation, and source sharing. It does NOT manage Claude Code's internal
behavior, Anthropic API availability, or project-specific build toolchains.

---

## 3. External Interface Requirements

### 3.1 User Interface

The system exposes no GUI. All interaction is through:

| Interface | Tool | Purpose |
|-----------|------|---------|
| Container shell | `docker compose exec claude-a bash` | Enter container interactively |
| Claude Code REPL | `claude` (inside container) | AI-assisted coding |
| Container auth | `claude auth login` (inside container) | Path A: OAuth login |
| Orchestration | `docker compose up/down/restart` | Lifecycle management |

### 3.2 Software Interfaces

| Dependency | Version | Required By | Purpose |
|-----------|---------|------------|---------|
| Docker Engine | 24.0+ | Host | Container runtime |
| Docker Compose | V2 (plugin) | Host | Multi-container orchestration |
| Node.js | 20 LTS | Image | Claude Code runtime |
| npm | (bundled with Node 20) | Image | Claude Code installation |
| Claude Code | Pinned via `CLAUDE_CODE_VERSION` build arg | Image | AI coding agent |
| git | Latest | Image + Host | Version control, worktree support |
| gh (GitHub CLI) | Latest | Image | GitHub integration |

### 3.3 Communication Interfaces

| Direction | Target | Protocol | Port | Purpose |
|-----------|--------|----------|------|---------|
| Container → Internet | api.anthropic.com | HTTPS | 443 | Claude API + token refresh |
| Container → Internet | registry.npmjs.org | HTTPS | 443 | Package installation |
| Container → Internet | github.com | HTTPS/SSH | 443/22 | Git operations |
| Host → Container | N/A | docker exec | N/A | Shell access |
| Manager → Worker | `http://worker-N:9000/task` | HTTP POST | 9000 | Task dispatch with prompt and timeout |
| Worker ↔ Redis | `redis://redis:6379` | TCP | 6379 | Shared context read/write, findings, status |
| Manager → Redis | `redis://redis:6379` | TCP | 6379 | Context initialization, findings aggregation |

No inbound ports are exposed from containers to the host.

---

## 4. Data Specifications

### 4.1 Environment Variable Contracts

Variables marked **compose** are set in `docker-compose.yml`.
Variables marked **`.env`** are set in the `.env` file.

| Variable | Source | Required | Default | Format | Description |
|----------|--------|----------|---------|--------|-------------|
| `PROJECT_DIR` | .env | Yes | — | Absolute path | Host path to project source |
| `PROJECT_DIR_{A,B,N}` | .env | Tier B only | — | Absolute path | Per-container worktree path |
| `CLAUDE_API_KEY_{A,B,N}` | .env | Path B only | — | `sk-ant-[a-zA-Z0-9_-]+` | Console API key per account |
| `CLAUDE_CONFIG_DIR` | compose | Yes | — | `/home/node/.claude` | Container config path (fixed) |
| `ANTHROPIC_API_KEY` | compose | No | `""` (via `:-`) | `sk-ant-...` or empty | Resolved from `CLAUDE_API_KEY_X` |
| `NODE_OPTIONS` | compose | Yes | — | `--max-old-space-size=4096` | Heap limit (fixed) |
| `HOME` | compose | Linux only | — | `/home/node` | Container home for tools |
| `UID` | .env | Linux only | `$(id -u)` | Integer | Host user ID |
| `GID` | .env | Linux only | `$(id -g)` | Integer | Host group ID |
| `CLAUDE_CODE_VERSION` | Dockerfile ARG | No | latest | Semver | Build-time version pin |
| `REDIS_URL` | compose | Phase 5 only | `redis://redis:6379` | URL | Redis connection URL (SRS-8.1.7) |
| `WORKER_NAME` | compose | Phase 5 only | `worker-1` | String | Worker identifier for Redis keys and logging (SRS-8.1.7) |
| `WORKER_PORT` | compose | Phase 5 only | `9000` | Integer | HTTP server listen port (SRS-8.1.7) |
| `ROLE` | compose | Phase 5 only | — | `manager` or `worker` | Container role designation (SRS-8.1.7) |
| `WORKER_COUNT` | compose | Phase 5 only | `3` | Integer | Number of worker containers (SRS-8.3.2) |

### 4.2 Credential File Schema

**File**: `$CLAUDE_CONFIG_DIR/.credentials.json`
**Permissions**: `0600` (owner read/write only)
**Created by**: `claude auth login` inside container (Path A)

```json
{
  "claudeAiOauth": {
    "accessToken":  "<string>  JWT access token, prefix sk-ant-oat01-",
    "refreshToken": "<string>  Refresh token, prefix sk-ant-ort01-",
    "expiresAt":    "<integer> Unix timestamp (seconds) when accessToken expires",
    "scopes":       ["user:inference", "user:profile"]
  }
}
```

**Lifecycle**: `accessToken` expires at `expiresAt`. Claude Code uses
`refreshToken` to silently obtain a new `accessToken` if the container
has network access to `api.anthropic.com`. Full re-auth inside the
container is needed only upon password change or account revocation.

### 4.3 State Directory Layout

Each account's state directory (`~/.claude-state/account-X/`) is
bind-mounted to `/home/node/.claude` inside the container.

```
~/.claude-state/account-X/
+-- .credentials.json       OAuth tokens (Path A; absent for Path B)
+-- settings.json            Global user settings
+-- settings.local.json      Machine-local settings
+-- CLAUDE.md                User-level persistent memory
+-- history.jsonl            Interaction history
+-- statsig/                 Feature flags
+-- projects/                Per-project session transcripts
+-- plans/                   Plan mode documents
+-- todos/                   Task lists
+-- commands/                Custom slash commands
+-- skills/                  Custom skills
+-- debug/                   Debug logs
+-- ide/                     IDE integration locks
+-- keybindings.json         Keyboard shortcuts
```

### 4.4 Volume Mount Matrix

| Mount | Host Path | Container Path | Type | Mode | SELinux |
|-------|-----------|---------------|------|------|---------|
| Source (Tier A) | `${PROJECT_DIR}` | `/workspace` | bind | rw | `:z` |
| Source (Tier B) | `${PROJECT_DIR_X}` | `/workspace` | bind | rw | `:z` |
| Source (read-only) | `${PROJECT_DIR}` | `/workspace` | bind | ro | `:z` |
| Account state | `${HOME}/.claude-state/account-X` | `/home/node/.claude` | bind | rw | `:Z` |
| Dependencies | `node_modules_X` | `/workspace/node_modules` | named | rw | N/A |
| Redis data | `redis-data` | `/data` (Redis) | named | rw | N/A |
| Scripts (read-only) | `./scripts` | `/scripts` (orchestration) | bind | ro | N/A |

- SELinux flags apply only to RHEL/CentOS/Fedora. Other platforms omit them.
- Named volumes are Docker-managed; no host path.

### 4.5 `.env` File Format

```bash
# Required for all configurations
PROJECT_DIR=/absolute/path/to/project

# Path B only (Console API keys)
CLAUDE_API_KEY_A=sk-ant-...
CLAUDE_API_KEY_B=sk-ant-...

# Tier B only (per-container worktree paths)
PROJECT_DIR_A=/absolute/path/to/worktree-a
PROJECT_DIR_B=/absolute/path/to/worktree-b

# Linux only (UID/GID matching)
UID=1000
GID=1000
```

The `.env` file SHALL be listed in `.gitignore`. A `.env.example`
SHALL be provided with placeholder values and no real credentials.

---

## 5. Functional Specifications

### SRS-5.1 Image Build (Dockerfile)

| Spec | Requirement |
|------|-------------|
| SRS-5.1.1 | Base image SHALL be `node:20-slim` (Debian-based, glibc). Alpine is NOT supported. |
| SRS-5.1.2 | Claude Code SHALL be installed via `npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}`. |
| SRS-5.1.3 | `CLAUDE_CODE_VERSION` SHALL be a build arg with no default (latest if unset). |
| SRS-5.1.4 | Dev tools SHALL be installed: `git`, `gh`, `fzf`, `jq`. |
| SRS-5.1.5 | `NODE_OPTIONS` SHALL be set to `--max-old-space-size=4096` in the image. |
| SRS-5.1.6 | `WORKDIR` SHALL NOT be `/`. It SHALL be `/workspace` or another non-root path. |
| SRS-5.1.7 | The image SHALL run as non-root user `node` by default. |
| SRS-5.1.8 | Package manager caches SHALL be cleaned: `apt-get` lists and `npm cache`. |
| SRS-5.1.9 | A `.dockerignore` SHALL exclude: `.git`, `node_modules`, `dist`, `build`, `.env`, `.claude/`. |
| SRS-5.1.10 | Final image size SHALL be under 1 GB. |
| SRS-5.1.11 | *(Phase 5)* Dockerfile SHALL install `redis-tools` package via apt-get for `redis-cli` availability. Not required until Phase 5 orchestration is implemented. |
| SRS-5.1.12 | *(Phase 5)* Dockerfile SHALL install `redis` npm package (v4.6+) globally for worker-server.js. Not required until Phase 5 orchestration is implemented. |
| SRS-5.1.13 | Dockerfile SHALL set `NODE_PATH=/usr/local/lib/node_modules` so that globally installed npm packages (e.g., `redis`) are resolvable by `require()` in scripts. |

### SRS-5.2 Container Orchestration (docker-compose.yml)

| Spec | Requirement |
|------|-------------|
| SRS-5.2.1 | Each service SHALL set `image: claude-code-base:latest`. |
| SRS-5.2.2 | Each service SHALL set `working_dir: /workspace`. |
| SRS-5.2.3 | Each service SHALL set `stdin_open: true` and `tty: true`. |
| SRS-5.2.4 | Each service SHALL mount the project directory to `/workspace` (bind mount). |
| SRS-5.2.5 | Each service SHALL mount its own state directory to `/home/node/.claude` (bind mount). |
| SRS-5.2.6 | Each service SHALL mount a dedicated named volume for `node_modules` at `/workspace/node_modules`. |
| SRS-5.2.7 | Each service SHALL set `CLAUDE_CONFIG_DIR=/home/node/.claude`. |
| SRS-5.2.8 | Each service SHALL set `NODE_OPTIONS=--max-old-space-size=4096`. |
| SRS-5.2.9 | Each service SHALL include `ANTHROPIC_API_KEY=${CLAUDE_API_KEY_X:-}` with `:-` default syntax. |
| SRS-5.2.10 | Named volumes SHALL be declared in a top-level `volumes:` section. |
| SRS-5.2.11 | Compose file SHALL NOT include `cap_add` by default. Firewall capability is opt-in (Phase 4). |

### SRS-5.3 Authentication Subsystem

**SRS-5.3.1 (Path A — Subscription OAuth)**:

**SRS-5.3.1a (macOS — Host-side Keychain Extraction)**:
Container-internal OAuth fails on macOS Docker (GitHub #34917). The primary
macOS method is host-side Keychain extraction.
1. User SHALL create state directories on the host (`~/.claude-state/account-X/`).
2. Container SHALL bind-mount the state directory to `/home/node/.claude`.
3. User SHALL run `scripts/claude-docker auth` on the host.
4. `get_keychain_credentials()` SHALL extract OAuth tokens from the macOS Keychain
   (service: `claude.ai`, account: `oauth_credentials`).
5. `inject_credentials()` SHALL write `.credentials.json` into the bind-mounted
   state directory with mode `0600`.
6. Credentials SHALL persist across container restarts via the host bind mount.
7. Token refresh SHALL occur automatically via `refreshToken` inside the container.
8. On token expiry beyond refresh, user SHALL re-run `scripts/claude-docker auth`.

**SRS-5.3.1b (Linux/WSL2 — Container-internal OAuth)**:
1. User SHALL create state directories on the host (`~/.claude-state/account-X/`).
2. Container SHALL bind-mount the state directory to `/home/node/.claude`.
3. On first `claude` launch inside the container, Claude Code SHALL initiate OAuth flow.
4. Browser SHALL open on the host for OAuth completion (container forwards the URL).
5. `.credentials.json` SHALL be created in the bind-mounted state directory.
6. Credentials SHALL persist across container restarts via the host bind mount.
7. Token refresh SHALL occur automatically via `refreshToken`.
8. On token expiry beyond refresh, user SHALL re-run `claude auth login` inside the container.

**SRS-5.3.2 (Path B — Console API Key)**:
1. User SHALL obtain API keys from `console.anthropic.com`.
2. Keys SHALL be stored in `.env` as `CLAUDE_API_KEY_X=sk-ant-...`.
3. Docker Compose SHALL expand variables into `ANTHROPIC_API_KEY` environment.
4. Claude Code SHALL use the API key with precedence over OAuth credentials.
5. On key rotation, user SHALL update `.env` and restart containers.

**SRS-5.3.3 (Precedence)**:
When both Path A credentials and Path B key are present, Claude Code's
internal precedence applies: `ANTHROPIC_API_KEY` (Path B) takes priority
over OAuth (Path A). The `:-` default syntax ensures an empty API key
variable does NOT override valid OAuth credentials.

### SRS-5.4 Source Sharing

**SRS-5.4.1 (Tier A — Shared Source)**:
- All containers SHALL bind-mount the same `${PROJECT_DIR}`.
- Concurrent write conflicts (including `.git/index.lock`) are accepted risks.

**SRS-5.4.2 (Tier B — Git Worktree)**:
- Each container SHALL bind-mount a separate worktree path (`${PROJECT_DIR_X}`).
- Worktrees SHALL be created from the same repository: `git worktree add <path> <branch>`.
- Git object database SHALL be shared (not duplicated).
- Same branch SHALL NOT be checked out in multiple worktrees simultaneously.

**SRS-5.4.3 (Dependencies)**:
- `node_modules` SHALL be stored in per-container named volumes.
- After first `docker compose up`, user SHALL run `docker compose exec <service> npm install`.

### SRS-5.5 Scaling

- Adding an Nth instance SHALL require: (a) a new compose service block
  (copy of existing, renamed), (b) a new state directory on host,
  (c) a new named volume for `node_modules`, (d) authentication for
  the new account (Path A or B).
- Each additional instance SHALL consume ~4 GB RAM and ~20-70 MB disk.
- No dynamic scaling mechanism SHALL be implemented. Scaling is manual
  compose editing.

---

## 6. Platform Adaptation

Platform-specific requirements are conditional. The base compose file
is identical; only `.env` values and optional compose overrides differ.

### 6.1 Linux

| Spec | Requirement |
|------|-------------|
| SRS-6.1.1 | Compose SHALL include `user: "${UID}:${GID}"` for each service. |
| SRS-6.1.2 | Compose SHALL set `HOME=/home/node` in each service's environment. |
| SRS-6.1.3 | `.env` SHALL include `UID` and `GID` values matching the host user. |
| SRS-6.1.4 | On SELinux-enforcing systems (RHEL/CentOS/Fedora), project volumes SHALL use `:z` and state volumes SHALL use `:Z`. |
| SRS-6.1.5 | On AppArmor systems (Debian/Ubuntu), no volume flags are needed. |

### 6.2 macOS

| Spec | Requirement |
|------|-------------|
| SRS-6.2.1 | Docker Desktop SHALL use VirtioFS file sharing (default since 4.6+). |
| SRS-6.2.2 | `node_modules` SHALL be in named volumes (avoids VM boundary overhead). |
| SRS-6.2.3 | No `user:` or `HOME=` override is needed (Docker Desktop VM handles permissions). |
| SRS-6.2.4 | Docker Desktop SHALL be allocated at least 8 GB RAM and 4 CPU cores. |

### 6.3 Windows

| Spec | Requirement |
|------|-------------|
| SRS-6.3.1 | `PROJECT_DIR` in `.env` SHALL point to a WSL2 filesystem path (`/home/...`), NOT an NTFS path (`/mnt/c/...`). |
| SRS-6.3.2 | All Docker commands SHALL be run from a WSL2 terminal (bash/zsh), NOT PowerShell, CMD, or Git Bash. |
| SRS-6.3.3 | `.wslconfig` SHALL allocate at least 12 GB memory, 4 processors, and 4 GB swap. |
| SRS-6.3.4 | The repository SHALL include a `.gitattributes` file with `* text=auto eol=lf`. |
| SRS-6.3.5 | `networkingMode=mirrored` SHALL NOT be used in `.wslconfig` (breaks Docker Desktop). |
| SRS-6.3.6 | No `user:` or `HOME=` override is needed (WSL2 VM handles permissions). |

---

## 7. Non-Functional Requirements

### 7.1 Performance

| Metric | Target |
|--------|--------|
| Container startup | All containers reach Claude Code prompt within 30 seconds of `docker compose up` |
| Bind mount speed (Linux) | ~1.0x native (baseline) |
| Bind mount speed (macOS, VirtioFS) | >= 0.3x native |
| Bind mount speed (Windows, WSL2 fs) | >= 0.9x native |
| Image build time | Under 10 minutes on a 50 Mbps connection |

### 7.2 Resource Budget

| Resource | Per Container | Formula for N containers |
|----------|--------------|------------------------|
| RAM (heap) | 4 GB | N x 4 GB |
| Disk (writable layer) | 10-50 MB | N x 10-50 MB |
| Disk (state directory) | 5-20 MB | N x 5-20 MB |
| Disk (shared image) | ~800 MB | ~800 MB (constant) |
| CPU | 1-2 cores | N x 1-2 cores |

**Phase 5 orchestration resource budget** (manager + 3 workers + Redis):

| Resource | Amount | Notes |
|----------|--------|-------|
| Docker RAM | ~17 GB | 4 containers x 4 GB + Redis 256 MB |
| Host RAM (Linux) | ~20 GB | Docker + host overhead |
| Host RAM (macOS/Windows) | ~24 GB | Docker Desktop VM overhead |
| CPU cores | 8+ recommended | 4 containers x 2 cores |
| Anthropic accounts | 4 | 1 manager + 3 workers (separate auth each) |

### 7.3 Security

| Constraint | Specification |
|-----------|---------------|
| No credentials in VCS | `.env` SHALL be in `.gitignore`. `.env.example` SHALL contain placeholders only. |
| No Docker socket mount | Compose SHALL NOT mount `/var/run/docker.sock`. |
| State directory permissions | Host state directories SHALL be mode `0700`. |
| Credential file permissions | `.credentials.json` SHALL be mode `0600`. |
| Firewall (optional) | If enabled, only DNS (53), SSH (22), npm registry, GitHub, and `api.anthropic.com` SHALL be permitted outbound. Requires `cap_add: [NET_ADMIN, NET_RAW]`. |

### 7.4 Reliability

| Scenario | Expected Behavior |
|----------|------------------|
| Container restart | OAuth credentials persist via host bind mount. No re-auth needed. |
| Host reboot | Same as container restart. State directories survive on host filesystem. |
| Token expiry (within refresh window) | Claude Code auto-refreshes silently. No user action needed. |
| Token expiry (beyond refresh) | Claude Code prompts error. User re-runs `claude auth login` inside the container. |
| API key rotation (Path B) | User updates `.env`, runs `docker compose restart`. |
| Network loss | Claude Code shows connection error. Resumes on reconnect. |

---

## 8. Orchestration Specifications

### 8.1 Orchestration Compose (`docker-compose.orchestration.yml`)

| Spec | Priority | Requirement |
|------|----------|-------------|
| SRS-8.1.1 | SHALL | Orchestration overlay SHALL define `redis`, `manager`, `worker-1`, `worker-2`, `worker-3` services |
| SRS-8.1.2 | SHALL | Redis service SHALL use `redis:7-alpine` image with 256 MB memory limit |
| SRS-8.1.3 | SHALL | Redis service SHALL persist data via RDB snapshot to named volume `redis-data` |
| SRS-8.1.4 | SHALL | Manager service SHALL use `claude-code-base:latest` with `sleep infinity` command |
| SRS-8.1.5 | SHALL | Worker services SHALL run `node /scripts/worker-server.js` as entry command |
| SRS-8.1.6 | SHALL | All services SHALL communicate via Docker Compose default bridge network using service name DNS |
| SRS-8.1.7 | SHALL | Each service SHALL receive `REDIS_URL`, `WORKER_NAME`, `WORKER_PORT`, and `ROLE` environment variables |
| SRS-8.1.8 | SHALL | Each worker and manager SHALL mount its own dedicated account state directory |
| SRS-8.1.9 | SHALL | The overlay SHALL NOT modify the base `docker-compose.yml` services |
| SRS-8.1.10 | SHALL | Redis service SHALL require password authentication via `--requirepass ${REDIS_PASSWORD}`. All clients (manager, workers) SHALL connect using `redis://:${REDIS_PASSWORD}@redis:6379` |
| SRS-8.1.11 | SHALL | All orchestration services (redis, manager, worker-1~3) SHALL be attached exclusively to an `orchestration-internal` Docker bridge network with `internal: true`, isolating orchestration traffic from the base compose network |

### 8.2 Worker Server (`scripts/worker-server.js`)

| Spec | Priority | Requirement |
|------|----------|-------------|
| SRS-8.2.1 | SHALL | Worker server SHALL expose HTTP POST `/task` endpoint on configurable port (default 9000) |
| SRS-8.2.2 | SHALL | Worker server SHALL accept JSON body `{taskId, prompt, timeout}` |
| SRS-8.2.3 | SHALL | Before executing `claude -p`, worker SHALL read `context:shared` hash from Redis |
| SRS-8.2.4 | SHALL | Before executing `claude -p`, worker SHALL read `findings:all` list from Redis |
| SRS-8.2.5 | SHALL | Worker SHALL execute `claude -p` with configurable timeout via `child_process.spawn` (async, stdin pipe). Async execution ensures heartbeat and health check remain responsive during long-running tasks. |
| SRS-8.2.6 | SHALL | Worker SHALL parse structured JSON findings block from Claude output |
| SRS-8.2.7 | SHALL | Worker SHALL write `result:{taskId}` hash and RPUSH findings to Redis |
| SRS-8.2.8 | SHALL | Worker SHALL maintain `worker:{name}:status` key with TTL 60s |
| SRS-8.2.9 | SHALL | Worker SHALL maintain `worker:{name}:heartbeat` key with TTL 30s |
| SRS-8.2.10 | SHALL | Worker SHALL respond with JSON `{status, taskId, output, findings}` |
| SRS-8.2.11 | SHALL | Worker server SHALL use the `redis` npm package for Redis communication |
| SRS-8.2.12 | SHALL | Worker SHALL expect findings in JSON format: `{"findings": [{"category": "string", "summary": "string", "severity": "high|medium|low", "details": "string"}]}` |
| SRS-8.2.13 | SHALL | If JSON findings block is missing or malformed, worker SHALL return empty findings array and status "partial" |
| SRS-8.2.14 | SHALL | Worker SHALL extract findings from the last markdown code fence tagged `json` in Claude output |
| SRS-8.2.15 | SHALL | Worker SHALL retry Redis connection up to 3 times with 2-second intervals on connection failure |
| SRS-8.2.16 | SHALL | Result keys (`result:{taskId}`) SHALL have TTL of 3600 seconds (1 hour) |
| SRS-8.2.17 | SHALL | Worker HTTP POST `/task` endpoint SHALL require a Bearer token matching `WORKER_AUTH_TOKEN`. Requests without a valid token SHALL be rejected with HTTP 401. Token comparison SHALL use `crypto.timingSafeEqual` to prevent timing attacks |
| SRS-8.2.18 | SHOULD | If `WORKER_AUTH_TOKEN` is unset at startup, worker SHALL log a warning and allow unauthenticated requests for backward compatibility |

### 8.3 Manager Helpers (`scripts/manager-helpers.sh`)

| Spec | Priority | Requirement |
|------|----------|-------------|
| SRS-8.3.1 | SHALL | Manager helpers SHALL provide `dispatch_task` function sending HTTP POST via `curl` |
| SRS-8.3.2 | SHALL | Manager helpers SHALL provide `dispatch_parallel` function sending to all workers concurrently |
| SRS-8.3.3 | SHALL | Manager helpers SHALL provide `get_findings` function reading findings from Redis via `redis-cli` |
| SRS-8.3.4 | SHALL | Manager helpers SHALL provide `get_worker_status` function checking all worker statuses |
| SRS-8.3.5 | SHALL | All helper functions SHALL use `set -euo pipefail` and return proper exit codes |
| SRS-8.3.6 | SHALL | Manager helpers SHALL verify Redis connectivity before dispatching tasks |
| SRS-8.3.7 | SHALL | Manager SHALL clear `findings:all` list before starting a new analysis session |

### 8.4 Orchestration Testing (`scripts/test-orchestration.sh`)

| Spec | Priority | Requirement |
|------|----------|-------------|
| SRS-8.4.1 | SHALL | E2E test SHALL start Redis, manager, and 3 workers via compose overlay |
| SRS-8.4.2 | SHALL | E2E test SHALL dispatch 3 distinct tasks to 3 workers sequentially |
| SRS-8.4.3 | SHALL | E2E test SHALL verify results stored in Redis `result:{taskId}` hashes |
| SRS-8.4.4 | SHALL | E2E test SHALL verify findings accumulation (later workers see earlier findings) |
| SRS-8.4.5 | SHALL | E2E test SHALL use `trap cleanup EXIT` for reliable teardown |

### 8.5 Cold Memory Layer (`scripts/manager-helpers.sh` additions)

| Spec | Priority | Requirement |
|------|----------|-------------|
| SRS-8.5.1 | SHALL | Manager service SHALL mount `${HOME}/.claude-state/analysis-archive` to `/archive` as a read-write bind mount |
| SRS-8.5.2 | SHALL | Manager helpers SHALL use `ARCHIVE_DIR` environment variable (default: `/archive`) for archive path |
| SRS-8.5.3 | SHALL | `save_session` function SHALL dump `context:shared`, `findings:all`, `findings:{category}`, and `result:{taskId}` hashes from Redis to JSON files in `$ARCHIVE_DIR/sessions/<id>/` |
| SRS-8.5.4 | SHALL | `restore_session` function SHALL load a previous session's context and findings from archive JSON files into Redis |
| SRS-8.5.5 | SHALL | `list_sessions` function SHALL display all archived sessions from `$ARCHIVE_DIR/index.json` with timestamps, finding counts, and task counts |
| SRS-8.5.6 | SHALL | `show_session` function SHALL display full metadata, context, and findings preview for a specified session |
| SRS-8.5.7 | SHOULD | Worker server SHOULD record `startedAt` and `durationMs` fields in `result:{taskId}` hashes for session metrics |
| SRS-8.5.8 | SHALL | Archive SHALL be bounded to a maximum of 50 sessions; oldest sessions SHALL be pruned automatically on save |
| SRS-8.5.9 | SHALL | Each session archive SHALL be self-contained: `session.json`, `context.json`, and `findings.json` readable without Redis |
| SRS-8.5.10 | SHALL | Cold memory layer SHALL be opt-in: orchestration works identically if `/archive` is not mounted |
| SRS-8.5.11 | SHALL | Only the manager container SHALL write to the archive; workers SHALL NOT have archive mount |
| SRS-8.5.12 | SHALL | Archive files SHALL be valid JSON parseable by `jq` |
| SRS-8.5.13 | SHALL | `restore_session` SHALL accept `latest` as a session ID alias to restore the most recent session |
| SRS-8.5.14 | SHALL | `save_session` SHALL NOT modify Redis state (read-only Redis operations during save) |
| SRS-8.5.15 | SHALL | The archive directory SHALL persist across `docker compose down -v` because it is a host bind mount, not a Docker named volume |

### 8.6 Orchestration UX (Phase 7)

| Spec | Priority | Requirement |
|------|----------|-------------|
| SRS-8.6.1 | SHALL | `personas.json` SHALL define worker personas with fields: `name` (string), `role` (string), `worker` (string, e.g., `worker-1`), `icon` (string, emoji), `system` (string, system prompt), `category` (string, e.g., `security`, `quality`, `performance`) |
| SRS-8.6.2 | SHALL | `WORKER_PERSONA` environment variable SHALL be injected into each worker's prompt context by `buildEnrichedPrompt()` during dispatch. The persona system prompt SHALL be prepended to the user-provided prompt. |
| SRS-8.6.3 | SHALL | `run_analysis()` SHALL dispatch tasks to all workers in parallel with persona wrapping. Each worker receives its persona's system prompt concatenated with the user prompt and accumulated shared context. |
| SRS-8.6.4 | SHALL | `scripts/claude-docker analyze "<prompt>"` CLI subcommand SHALL invoke `run_analysis` inside the manager container, print a categorized summary grouped by persona category, and save the session to cold storage. |
| SRS-8.6.5 | SHOULD | Manager `CLAUDE.md` SHALL define trigger keywords (`analyze`, `audit`, `review`, `inspect`, `scan`, `security check`, `code quality`, `performance review`, `production readiness`, `health check`) that auto-invoke `run_analysis` when detected in user input. |

### 8.7 Usage Tracking (Phase 7)

| Spec | Priority | Requirement |
|------|----------|-------------|
| SRS-8.7.1 | SHALL | `scripts/claude-docker usage` subcommand SHALL aggregate token usage data from all container state directories and the host Claude config directory |
| SRS-8.7.2 | SHALL | Usage aggregation SHALL use `ccusage` tool with symlink merge to unify per-account usage data into a single report |
| SRS-8.7.3 | SHOULD | Usage report SHALL include per-account breakdown and total across all accounts (container + host) |

### 8.8 Known Issues and Errata

| ID | Description | Affected Spec | Fix |
|----|-------------|---------------|-----|
| ERRATA-1 | `xxd` is not available in `node:20-slim`; scripts using `xxd` for hex encoding SHALL use `od` instead (`od -An -tx1`) | SRS-8.3 | Replace `xxd` calls with `od -An -tx1` in manager-helpers.sh |
| ERRATA-2 | `NODE_PATH=/usr/local/lib/node_modules` is required for globally installed npm packages to be resolvable by `require()` in worker-server.js | SRS-5.1.12 | Added SRS-5.1.13 |
| ERRATA-3 | `((counter++))` returns exit code 1 when counter is 0 under `set -e`, causing script termination | SRS-8.3.5 | Use `counter=$((counter + 1))` instead of `((counter++))` in shell scripts |

---

## 9. Constraints and Assumptions

### 9.1 Technology Constraints

- Alpine Linux base images are NOT supported (musl incompatible with Claude Code).
- Interactive CLI commands (`vim`, `git rebase -i`) are NOT supported inside Claude Code's shell tool (GitHub #26353).
- Docker-in-Docker is NOT used. Containers do not manage other containers.
- `docker compose` V2 (Go binary, space-separated) is required. Legacy `docker-compose` V1 (Python, hyphenated) is not tested.

### 9.2 Assumptions

- Host has internet access for initial image build and Claude API communication.
- For Path A, the host has a browser for OAuth login.
- For Tier B, branches `branch-a` and `branch-b` exist or will be created.
- Host user has Docker permissions (member of `docker` group on Linux, or Docker Desktop installed on macOS/Windows).

---

## 10. Verification and Traceability

### 10.1 Upstream Traceability (SRS → PRD)

Each SRS functional section traces back to PRD Goals and Functional Requirements.

| SRS Section | Specs | PRD FR | PRD Goal | Phase |
|-------------|-------|--------|----------|-------|
| 5.1 Image Build | SRS-5.1.1–10, 5.1.13 | FR-1–5 | G1, G5 | 1 |
| 5.1 Image Build (Phase 5 additions) | SRS-5.1.11–12 | — | G9 | 5 |
| 5.2 Container Orchestration | SRS-5.2.1–11 | FR-6, FR-9, FR-10, FR-12 | G2, G3, G5 | 2, 3 |
| 5.3 Authentication | SRS-5.3.1a–b, 5.3.2–3 | FR-7, FR-8 | G2, G7 | 2 |
| 5.4 Source Sharing | SRS-5.4.1–3 | FR-10–13 | G3, G4 | 3 |
| 5.5 Scaling | SRS-5.5 | — | G8 | 2, 3 |
| 6.1 Linux Adaptation | SRS-6.1.1–5 | — | G6 | 2 |
| 6.2 macOS Adaptation | SRS-6.2.1–4 | — | G6 | 2 |
| 6.3 Windows Adaptation | SRS-6.3.1–6 | — | G6 | 2 |
| 7.3 Security | SRS-7.3 | FR-14 | G5 | 4 |
| 8.1–8.4 Orchestration | SRS-8.1.1–9, SRS-8.2.1–16, SRS-8.3.1–7, SRS-8.4.1–5 | FR-18–24 | G9, G10 | 5 |
| 8.5 Cold Memory | SRS-8.5.1–15 | FR-25–29 | G10 | 6 |
| 8.6 Orchestration UX | SRS-8.6.1–5 | FR-30–32 | G9 | 7 |
| 8.7 Usage Tracking | SRS-8.7.1–3 | FR-33 | — | 7 |

### 10.2 Downstream Verification (PRD FR → SRS → Test)

Each PRD Functional Requirement (FR) maps to an SRS specification and
a test procedure.

| PRD FR | SRS Spec | Test Procedure |
|--------|----------|----------------|
| FR-1 (node:20-slim base) | SRS-5.1.1 | `docker inspect` image; verify base is `debian` not `alpine` |
| FR-2 (Claude Code install) | SRS-5.1.2, 5.1.3 | `docker compose exec claude-a claude --version` returns valid version |
| FR-3 (dev tools + NODE_OPTIONS) | SRS-5.1.4, 5.1.5 | `docker compose exec claude-a git --version && gh --version && node -e "console.log(v8.getHeapStatistics().heap_size_limit)"` |
| FR-4 (WORKDIR not /) | SRS-5.1.6 | `docker inspect` image; verify `WorkingDir` is not `/` |
| FR-5 (.dockerignore) | SRS-5.1.9 | Build image; verify `.git` and `node_modules` not in image layers |
| FR-6 (separate CLAUDE_CONFIG_DIR) | SRS-5.2.5, 5.2.7 | Create distinct files in each state dir on host; verify visibility in respective containers only |
| FR-7 (Path A OAuth) | SRS-5.3.1a–b | macOS: run `scripts/claude-docker auth`; verify `.credentials.json` created in state dir; verify `claude auth status` succeeds inside container. Linux/WSL2: run `claude auth login` inside container; complete OAuth in host browser; verify `claude auth status` succeeds inside container. |
| FR-8 (Path B API key) | SRS-5.3.2 | Set `CLAUDE_API_KEY_A` in `.env`; start container; verify `claude auth status` shows API key auth |
| FR-9 (.env.example) | SRS-4.5 | Verify `.env.example` exists with placeholder values; verify `.env` in `.gitignore` |
| FR-10 (Tier A bind mount) | SRS-5.4.1 | Create test file on host in `PROJECT_DIR`; verify visible in both containers at `/workspace/` |
| FR-11 (Tier B worktrees) | SRS-5.4.2 | Create worktrees; set `PROJECT_DIR_A`/`_B` in `.env`; verify each container sees its own branch |
| FR-12 (node_modules volumes) | SRS-5.2.6 | `docker volume ls`; verify `node_modules_a` and `node_modules_b` exist as separate volumes |
| FR-13 (worktree script) | SRS-5.4.2 | Run `scripts/setup-worktrees.sh`; verify worktrees created with correct branches |
| FR-14 (firewall) | SRS-7.3 | Add `cap_add` and run firewall script; verify `curl` to non-whitelisted host is blocked |
| FR-15 (read-only mount) | SRS-4.4 | Start container with `:ro` on project volume; verify write operations fail inside container |
| FR-16 (resource limits) | SRS-7.2 | Add `deploy.resources` to compose; verify `docker stats` shows enforced limits |
| FR-17 (cleanup script) | SRS-5.5 | Run `scripts/cleanup.sh`; verify worktrees removed and state directories cleaned |
| FR-18 (Redis service) | SRS-8.1.2–3 | Redis service starts with healthcheck; `redis-cli ping` returns PONG |
| FR-19 (worker task endpoint) | SRS-8.2.1–6 | POST to worker-N:9000/task returns JSON with status and findings |
| FR-20 (findings accumulation) | SRS-8.2.3–4, 8.2.7 | Worker-2 prompt contains Worker-1's findings from Redis |
| FR-21 (manager dispatch) | SRS-8.3.1–2 | `dispatch_task` and `dispatch_parallel` return worker responses |
| FR-22 (overlay compatibility) | SRS-8.1.9 | `docker compose -f ... -f docker-compose.orchestration.yml config` validates |
| FR-23 (worker status) | SRS-8.2.8–9 | `redis-cli GET worker:worker-1:status` returns current status |
| FR-24 (E2E test) | SRS-8.4.1–5 | `test-orchestration.sh` exits with code 0 |
| — (Redis tooling, Phase 5) | SRS-5.1.11–12 | `docker compose exec manager redis-cli --version` and `node -e "require('redis')"` both succeed |
| — (JSON findings schema) | SRS-8.2.12–14 | Worker returns structured findings for well-formed prompt; returns empty findings for prompt without JSON block |
| — (error recovery) | SRS-8.2.15–16 | Worker reconnects after Redis restart; result keys expire after 1 hour |
| — (manager resilience) | SRS-8.3.6–7 | `get_worker_status` fails gracefully if Redis unreachable; `findings:all` empty after session reset |
| FR-25 (session save) | SRS-8.5.3 | Run analysis session, call `save_session`; verify 3 JSON files created in archive with `jq . < session.json` |
| FR-26 (session restore) | SRS-8.5.4, 8.5.13 | Call `restore_session latest`; verify `redis-cli HGETALL context:shared` matches archived context |
| FR-27 (session listing) | SRS-8.5.5 | Save 3 sessions; call `list_sessions`; verify all 3 appear with correct counts |
| FR-28 (session pruning) | SRS-8.5.8 | Save 52 sessions; verify only 50 remain in index and on disk |
| FR-29 (backward compat) | SRS-8.5.10 | Start orchestration without archive mount; verify all existing functions work |
| FR-30 (worker personas) | SRS-8.6.1–2 | Verify `personas.json` is valid JSON with required fields; verify `WORKER_PERSONA` present in worker prompt context |
| FR-31 (CLI analyze) | SRS-8.6.3–4 | Run `scripts/claude-docker analyze "test prompt"`; verify 3 workers dispatched; verify categorized summary output |
| FR-32 (manager auto-orchestration) | SRS-8.6.5 | Send "analyze this project" to manager; verify `run_analysis` invoked automatically |
| FR-33 (usage tracking) | SRS-8.7.1–3 | Run `scripts/claude-docker usage`; verify output includes per-account and total token data |
| — (NODE_PATH) | SRS-5.1.13 | `docker compose exec worker-1 node -e "console.log(require.resolve('redis'))"` succeeds |

---

## 11. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.1.0 | 2026-03-30 | Phase 6 additions: SRS-8.1.10–11 (Redis auth, internal network), SRS-8.2.17–18 (Bearer token auth), SRS-8.5 (cold memory layer, extended to 15 specs); §4.1 env var table updated (WORKER_AUTH_TOKEN, REDIS_PASSWORD, WORKER_PERSONA); §8.3.5 normative shell arithmetic constraint; §8.8 errata resolved and folded into normative text; §7.1/§7.2 SSOT references to cross-platform.md and architecture.md |
| 1.0.0 | 2026-03-27 | Initial document covering Phases 1–5 |
