# SDS: Dual Claude Code Container Architecture

**Status**: Draft | **Version**: 1.0.0 | **Date**: 2026-03-27

**References**: [SRS](software-requirements-specification.md), [PRD](product-requirements-document.md), [Architecture](architecture.md)

**Purpose**: Detailed design for all deliverable files. A developer copies
these contents into actual files and adjusts paths for their environment.
Each design choice is annotated with the SRS specification it satisfies.

---

## 1. Design Overview

### 1.1 Component Interaction

```
.env ──────────────────────> docker-compose.yml
                               |
                               +-- claude-a (container)
                               |     +-- /workspace       <── bind mount ── ${PROJECT_DIR}
                               |     +-- /home/node/.claude <── bind mount ── ~/.claude-state/account-a
                               |     +-- /workspace/node_modules <── named vol ── node_modules_a
                               |
                               +-- claude-b (container)
                                     +-- /workspace       <── bind mount ── ${PROJECT_DIR}
                                     +-- /home/node/.claude <── bind mount ── ~/.claude-state/account-b
                                     +-- /workspace/node_modules <── named vol ── node_modules_b

Dockerfile ──(build)──> claude-code-base:latest ──(used by)──> docker-compose.yml
```

### 1.2 File Dependency Graph

```
Dockerfile                    (Phase 1) ── no dependencies
.dockerignore                 (Phase 1) ── no dependencies
docker-compose.yml            (Phase 2) ── depends on: Dockerfile (image), .env (variables)
docker-compose.linux.yml      (Phase 2) ── depends on: docker-compose.yml (base)
.env.example                  (Phase 2) ── no dependencies
.gitignore                    (Phase 2) ── no dependencies
.gitattributes                (Phase 2) ── no dependencies (Windows teams)
docker-compose.worktree.yml   (Phase 3) ── depends on: docker-compose.yml (base)
setup-worktrees.sh            (Phase 3) ── depends on: git, project repo
docker-compose.firewall.yml   (Phase 4) ── depends on: docker-compose.yml (base)
cleanup.sh                    (Phase 4) ── depends on: docker, git
docker-compose.orchestration.yml  (Phase 5) ── depends on: docker-compose.yml, Dockerfile, worker-server.js, manager-helpers.sh
scripts/worker-server.js          (Phase 5) ── depends on: redis npm (SRS-5.1.12), claude CLI, redis service
scripts/manager-helpers.sh        (Phase 5) ── depends on: curl, jq, redis-tools (SRS-5.1.11)
scripts/test-orchestration.sh     (Phase 5) ── depends on: docker compose, all Phase 5 files
```

### 1.3 Design Principles

1. **Annotated**: Every design choice references an SRS spec (`# SRS-x.x.x`)
2. **Copy-ready**: File contents are complete — copy, adjust paths, run
3. **Override-based**: Platform differences use compose override files, not conditionals
4. **Fail-safe defaults**: Empty API key (`:-`) falls through to OAuth; missing UID defaults to image user

---

## 2. Dockerfile Design

Complete Dockerfile with rationale annotations.

```dockerfile
# SRS-5.1.1: Base MUST be node:20-slim (Debian/glibc, NOT Alpine)
FROM node:20-slim

# SRS-5.1.3: Version pinning via build arg
ARG CLAUDE_CODE_VERSION
# Why: Omitting default means "latest" when --build-arg is not passed.
# Pinning: docker build --build-arg CLAUDE_CODE_VERSION=1.2.3 .

# SRS-5.1.6: WORKDIR must NOT be / (causes full filesystem scan on install)
WORKDIR /workspace

# SRS-5.1.4: Dev tools — single layer, cache cleaned
# SRS-5.1.8: apt cache removed in same RUN to avoid layer bloat
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       curl \
       jq \
       fzf \
       zsh \
       sudo \
       redis-tools \                                        # Phase 5 addition (SRS-5.1.11)
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (gh) — separate layer for cache efficiency
# Why: gh releases change independently from apt packages
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# SRS-5.1.2: Install Claude Code globally
# SRS-5.1.8: npm cache cleaned in same RUN
RUN npm install -g @anthropic-ai/claude-code${CLAUDE_CODE_VERSION:+@$CLAUDE_CODE_VERSION} \
    && npm cache clean --force

# SRS-5.1.12: Redis client for worker-server.js orchestration
# Phase 5 addition — omit this RUN until Phase 5 implementation begins.
# The current Dockerfile intentionally excludes this line (Phase 1–4 only).
RUN npm install -g redis \
    && npm cache clean --force

# SRS-5.1.5: Memory heap limit
# NODE_PATH: Allow require() to find globally installed npm packages (e.g. redis)
ENV NODE_OPTIONS=--max-old-space-size=4096 \
    NODE_PATH=/usr/local/lib/node_modules

# SRS-5.1.7: Run as non-root user
# Why: node user (UID 1000) comes pre-created in node:20-slim
USER node

# Default command keeps container alive for docker compose exec
CMD ["sleep", "infinity"]
```

**Layer ordering rationale**:
- apt packages first (rarely change) → stable cache
- gh install second (changes occasionally)
- Claude Code last (changes most frequently on version bumps)
- This ordering maximizes Docker layer cache hits during rebuilds.

**Image size budget** (SRS-5.1.10: under 1 GB):

| Layer | Estimated Size |
|-------|---------------|
| Debian slim base | ~80 MB |
| Node.js 20 | ~300 MB |
| apt dev tools | ~100 MB |
| gh CLI | ~20 MB |
| Claude Code + npm | ~300 MB |
| **Total** | **~800 MB** |

---

## 3. Compose Design

### 3.1 Base Compose — Tier A (Shared Source)

```yaml
# docker-compose.yml
# SRS-5.2.1~11: Container orchestration specifications

services:
  claude-a:
    build:
      context: .
      args:
        CLAUDE_CODE_VERSION: ${CLAUDE_CODE_VERSION:-}
    image: claude-code-base:latest                          # SRS-5.2.1
    working_dir: /workspace                                 # SRS-5.2.2
    stdin_open: true                                        # SRS-5.2.3
    tty: true                                               # SRS-5.2.3
    volumes:
      - ${PROJECT_DIR}:/workspace                           # SRS-5.2.4
      - ${HOME}/.claude-state/account-a:/home/node/.claude  # SRS-5.2.5
      - node_modules_a:/workspace/node_modules              # SRS-5.2.6
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude                # SRS-5.2.7
      - NODE_OPTIONS=--max-old-space-size=4096              # SRS-5.2.8
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_A:-}             # SRS-5.2.9
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
        reservations:
          cpus: "1"
          memory: 2G
    command: ["sleep", "infinity"]

  claude-b:
    image: claude-code-base:latest
    depends_on:
      - claude-a
    working_dir: /workspace
    stdin_open: true
    tty: true
    volumes:
      - ${PROJECT_DIR}:/workspace
      - ${HOME}/.claude-state/account-b:/home/node/.claude
      - node_modules_b:/workspace/node_modules
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - NODE_OPTIONS=--max-old-space-size=4096
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_B:-}
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
        reservations:
          cpus: "1"
          memory: 2G
    command: ["sleep", "infinity"]

volumes:                                                    # SRS-5.2.10
  node_modules_a:
  node_modules_b:

# SRS-5.2.11: No cap_add by default (firewall is Phase 4 opt-in)
```

### 3.2 Linux Override — docker-compose.linux.yml

```yaml
# docker-compose.linux.yml
# Usage: docker compose -f docker-compose.yml -f docker-compose.linux.yml up

services:
  claude-a:
    user: "${UID}:${GID}"           # SRS-6.1.1
    environment:
      - HOME=/home/node             # SRS-6.1.2

  claude-b:
    user: "${UID}:${GID}"
    environment:
      - HOME=/home/node
```

**Why override file**: Keeps the base compose platform-neutral.
Linux users add `-f docker-compose.linux.yml`. macOS/Windows use base only.

### 3.3 Tier B Override — docker-compose.worktree.yml

```yaml
# docker-compose.worktree.yml
# Usage: docker compose -f docker-compose.yml -f docker-compose.worktree.yml up

services:
  claude-a:
    volumes:
      - ${PROJECT_DIR_A}:/workspace   # Replaces shared PROJECT_DIR

  claude-b:
    volumes:
      - ${PROJECT_DIR_B}:/workspace
```

**Volume merge behavior**: Docker Compose v2 appends override volumes to the
base list. The base `${PROJECT_DIR}:/workspace` and the override
`${PROJECT_DIR_A}:/workspace` both target `/workspace`; Docker uses the last
mount listed, so the override wins. However, `PROJECT_DIR` must still be
defined in `.env` even for Tier B — otherwise Compose fails during variable
interpolation of the base file. Set it to the main repository path (e.g.,
`PROJECT_DIR=/home/user/project`).

### 3.4 Firewall Override — docker-compose.firewall.yml (Phase 4)

```yaml
# docker-compose.firewall.yml
# Phase 4 opt-in: Grants network capabilities for container-level firewall rules
# Usage: append -f docker-compose.firewall.yml to any compose combination

services:
  claude-a:
    cap_add:
      - NET_ADMIN
      - NET_RAW

  claude-b:
    cap_add:
      - NET_ADMIN
      - NET_RAW
```

**Current scope**: This overlay grants the Linux capabilities required to
run iptables inside the container. The project includes `scripts/init-firewall.sh`,
an outbound firewall script
(modeled after the [official Claude Code DevContainer firewall script](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh))
that restricts egress to whitelisted services (DNS, SSH, npm, GitHub, Anthropic API).
Run it inside the container after startup:

```bash
docker compose exec claude-a sudo bash /workspace/scripts/init-firewall.sh
```

Use `--dry-run` to preview rules without applying them. Without running the
script, the capabilities alone have no security effect and marginally increase
the container's attack surface.

### 3.5 Compose Combination Matrix

| Scenario | Command |
|----------|---------|
| macOS/Windows + Tier A | `docker compose up` |
| macOS/Windows + Tier B | `docker compose -f docker-compose.yml -f docker-compose.worktree.yml up` |
| Linux + Tier A | `docker compose -f docker-compose.yml -f docker-compose.linux.yml up` |
| Linux + Tier B | `docker compose -f docker-compose.yml -f docker-compose.linux.yml -f docker-compose.worktree.yml up` |
| Any + Firewall | Append `-f docker-compose.firewall.yml` |
| Orchestration (macOS/Windows) | `docker compose -f docker-compose.yml -f docker-compose.orchestration.yml up -d` |
| Orchestration (Linux) | `docker compose -f docker-compose.yml -f docker-compose.linux.yml -f docker-compose.orchestration.yml up -d` |
| Orchestration + Firewall | Append both `-f docker-compose.orchestration.yml -f docker-compose.firewall.yml` |

### 3.6 Orchestration Override — docker-compose.orchestration.yml (Phase 5)

Manager-worker pattern with Redis shared context. Opt-in via `-f docker-compose.orchestration.yml`.

```yaml
# docker-compose.orchestration.yml
# Phase 5+: Manager-Worker orchestration with Redis shared context
# Usage: docker compose -f docker-compose.yml -f docker-compose.orchestration.yml up -d
# SRS-8.1.1~11

services:
  redis:
    image: redis:7-alpine                                       # SRS-8.1.2
    command: ["redis-server", "--save", "60", "1", "--loglevel", "notice", "--requirepass", "${REDIS_PASSWORD}"]  # SRS-8.1.10
    volumes:
      - redis-data:/data                                        # SRS-8.1.3
    networks:
      - orchestration-internal                                  # SRS-8.1.11
    deploy:
      resources:
        limits:
          memory: 256M
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "--no-auth-warning", "ping"]  # SRS-8.1.10
      interval: 10s
      timeout: 3s
      retries: 3

  manager:
    image: claude-code-base:latest                              # SRS-8.1.4
    depends_on:
      redis:
        condition: service_healthy
    working_dir: /workspace
    stdin_open: true
    tty: true
    volumes:
      - ${PROJECT_DIR}:/workspace
      - ${HOME}/.claude-state/account-manager:/home/node/.claude # SRS-8.1.8
      - node_modules_manager:/workspace/node_modules
      - ./scripts:/scripts:ro                                   # SRS-8.1.5
    networks:
      - orchestration-internal                                  # SRS-8.1.11
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - NODE_OPTIONS=--max-old-space-size=4096
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_MANAGER:-}
      - REDIS_URL=redis://:${REDIS_PASSWORD:-}@redis:6379       # SRS-8.1.7, SRS-8.1.10
      - WORKER_AUTH_TOKEN=${WORKER_AUTH_TOKEN:-}                 # SRS-8.2.17
      - REDIS_PASSWORD=${REDIS_PASSWORD:-}                      # SRS-8.1.10
      - ROLE=manager
      - WORKER_COUNT=${WORKER_COUNT:-3}
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
        reservations:
          cpus: "1"
          memory: 2G
    command: ["sleep", "infinity"]

  worker-1:
    image: claude-code-base:latest
    depends_on:
      redis:
        condition: service_healthy
    working_dir: /workspace
    volumes:
      - ${PROJECT_DIR}:/workspace:ro                            # Workers read-only
      - ${HOME}/.claude-state/account-w1:/home/node/.claude     # SRS-8.1.8
      - ./scripts:/scripts:ro                                   # SRS-8.1.5
    networks:
      - orchestration-internal                                  # SRS-8.1.11
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - NODE_OPTIONS=--max-old-space-size=4096
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_1:-}
      - REDIS_URL=redis://:${REDIS_PASSWORD:-}@redis:6379       # SRS-8.1.7, SRS-8.1.10
      - WORKER_AUTH_TOKEN=${WORKER_AUTH_TOKEN:-}                 # SRS-8.2.17
      - WORKER_NAME=worker-1                                    # SRS-8.1.7
      - WORKER_PORT=9000                                        # SRS-8.1.7
      - ROLE=worker
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
        reservations:
          cpus: "1"
          memory: 2G
    command: ["node", "/scripts/worker-server.js"]              # SRS-8.1.5

  worker-2:
    image: claude-code-base:latest
    depends_on:
      redis:
        condition: service_healthy
    working_dir: /workspace
    volumes:
      - ${PROJECT_DIR}:/workspace:ro
      - ${HOME}/.claude-state/account-w2:/home/node/.claude
      - ./scripts:/scripts:ro                                   # SRS-8.1.5
    networks:
      - orchestration-internal                                  # SRS-8.1.11
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - NODE_OPTIONS=--max-old-space-size=4096
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_2:-}
      - REDIS_URL=redis://:${REDIS_PASSWORD:-}@redis:6379       # SRS-8.1.7, SRS-8.1.10
      - WORKER_AUTH_TOKEN=${WORKER_AUTH_TOKEN:-}                 # SRS-8.2.17
      - WORKER_NAME=worker-2                                    # SRS-8.1.7
      - WORKER_PORT=9000                                        # SRS-8.1.7
      - ROLE=worker
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
        reservations:
          cpus: "1"
          memory: 2G
    command: ["node", "/scripts/worker-server.js"]

  worker-3:
    image: claude-code-base:latest
    depends_on:
      redis:
        condition: service_healthy
    working_dir: /workspace
    volumes:
      - ${PROJECT_DIR}:/workspace:ro
      - ${HOME}/.claude-state/account-w3:/home/node/.claude
      - ./scripts:/scripts:ro                                   # SRS-8.1.5
    networks:
      - orchestration-internal                                  # SRS-8.1.11
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - NODE_OPTIONS=--max-old-space-size=4096
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_3:-}
      - REDIS_URL=redis://:${REDIS_PASSWORD:-}@redis:6379       # SRS-8.1.7, SRS-8.1.10
      - WORKER_AUTH_TOKEN=${WORKER_AUTH_TOKEN:-}                 # SRS-8.2.17
      - WORKER_NAME=worker-3                                    # SRS-8.1.7
      - WORKER_PORT=9000                                        # SRS-8.1.7
      - ROLE=worker
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
        reservations:
          cpus: "1"
          memory: 2G
    command: ["node", "/scripts/worker-server.js"]

networks:
  orchestration-internal:
    driver: bridge
    internal: true                                               # SRS-8.1.11

volumes:
  redis-data:
  node_modules_manager:
  node_modules_w1:
  node_modules_w2:
  node_modules_w3:
```

**Design decisions:**
- Workers mount source as `:ro` — analysis only, no code modification
- Scripts bind-mounted at `/scripts:ro` — no image rebuild for script changes
- **Relative paths**: `./scripts` is relative to the compose file location; `docker compose` must be run from the project root directory where `docker-compose.orchestration.yml` resides
- Redis healthcheck ensures workers don't start before Redis is ready
- Each worker has its own account state and node_modules volume
- No port exposure to host — all communication via `orchestration-internal` bridge network (SRS-8.1.11)
- `orchestration-internal` has `internal: true` — containers on this network cannot initiate outbound connections, isolating Redis and worker-to-worker traffic from external networks
- `WORKER_AUTH_TOKEN` and `REDIS_PASSWORD` are auto-generated by `install.sh` using `openssl rand -hex 32` and written to `.env`; the manager passes `WORKER_AUTH_TOKEN` in an `Authorization: Bearer` header on every `POST /task` request (SRS-8.2.17)
- Each worker service includes a `WORKER_PERSONA` env var containing the full persona system prompt (Sentinel for worker-1, Reviewer for worker-2, Profiler for worker-3). This is read by `worker-server.js` and prepended as a `[Role]` section in `buildEnrichedPrompt()`

---

## 4. Configuration Files

### 4.1 .env.example

```bash
# ==== Required ====
PROJECT_DIR=/path/to/your/project

# ==== Path B only (Console API keys) ====
# Uncomment and fill for Console accounts. Leave commented for subscription (Path A).
# CLAUDE_API_KEY_A=sk-ant-...
# CLAUDE_API_KEY_B=sk-ant-...

# ==== Tier B only (git worktree paths) ====
# PROJECT_DIR_A=/path/to/worktree-a
# PROJECT_DIR_B=/path/to/worktree-b

# ==== Linux only ====
# UID=1000
# GID=1000

# ==== Phase 5: Orchestration (optional) ====
# API keys for manager and workers (Path B only)
# CLAUDE_API_KEY_MANAGER=sk-ant-...
# CLAUDE_API_KEY_1=sk-ant-...
# CLAUDE_API_KEY_2=sk-ant-...
# CLAUDE_API_KEY_3=sk-ant-...
# Number of workers (default: 3)
# WORKER_COUNT=3
```

### 4.2 .dockerignore

```
.git
node_modules
dist
build
*.log
.env
.env.*
.claude/
.claude-state/
```

### 4.3 .gitignore

```
.env
.env.*
!.env.example
.claude-state/
```

### 4.4 .gitattributes (SRS-6.3.4)

```gitattributes
* text=auto eol=lf
*.sh text eol=lf
*.bash text eol=lf
Dockerfile text eol=lf
docker-compose*.yml text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
*.json text eol=lf
```

---

## 5. Script Designs

### 5.1 scripts/setup-worktrees.sh

```bash
#!/usr/bin/env bash
# Setup git worktrees for Tier B (SRS-5.4.2)
set -euo pipefail

REPO_DIR="${1:?Usage: setup-worktrees.sh <repo-dir> [branch-a] [branch-b]}"
BRANCH_A="${2:-worktree-a}"
BRANCH_B="${3:-worktree-b}"
WORKTREE_A="${REPO_DIR%/}-a"
WORKTREE_B="${REPO_DIR%/}-b"

# Validate
if [ ! -d "$REPO_DIR/.git" ]; then
    echo "Error: $REPO_DIR is not a git repository" >&2
    exit 1
fi

# Create branches if they don't exist (based on current HEAD)
cd "$REPO_DIR"
git branch "$BRANCH_A" 2>/dev/null || true
git branch "$BRANCH_B" 2>/dev/null || true

# Create worktrees
git worktree add "$WORKTREE_A" "$BRANCH_A"
git worktree add "$WORKTREE_B" "$BRANCH_B"

echo "Worktrees created:"
echo "  A: $WORKTREE_A (branch: $BRANCH_A)"
echo "  B: $WORKTREE_B (branch: $BRANCH_B)"
echo ""
echo "Add to .env:"
echo "  PROJECT_DIR_A=$WORKTREE_A"
echo "  PROJECT_DIR_B=$WORKTREE_B"
```

### 5.2 scripts/cleanup.sh

```bash
#!/usr/bin/env bash
# Cleanup containers, worktrees, and state (SRS-5.5, FR-17)
set -euo pipefail

echo "=== Stopping containers ==="
docker compose down --remove-orphans 2>/dev/null || true

echo "=== Removing named volumes ==="
docker compose down -v 2>/dev/null || true

echo "=== Removing worktrees (if Tier B) ==="
REPO_DIR="${1:-}"
if [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR"
    for wt in $(git worktree list --porcelain | grep "^worktree " | awk '{print $2}'); do
        if [ "$wt" != "$(pwd)" ]; then
            echo "  Removing worktree: $wt"
            git worktree remove "$wt" --force 2>/dev/null || true
        fi
    done
fi

echo "=== Removing state directories ==="
read -p "Remove ~/.claude-state/*? (y/N) " confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    rm -rf "${HOME}/.claude-state"
    echo "  State directories removed."
else
    echo "  Skipped."
fi

echo "=== Cleanup complete ==="
```

### 5.3 scripts/worker-server.js (Phase 5)

Worker HTTP server with Redis shared context integration (SRS-8.2.1–16).
Receives task prompts from the manager container, enriches them with shared
context and prior findings from Redis, executes `claude -p` via async stdin
pipe, parses structured JSON findings from the output, and writes results back
to Redis for downstream consumers.

```javascript
#!/usr/bin/env node
'use strict';

// --- Dependencies -----------------------------------------------------------
const http = require('http');
const { spawn } = require('child_process');                  // SRS-8.2.5
const { createClient } = require('redis');                   // SRS-8.2.11

// --- Configuration ----------------------------------------------------------
const WORKER_PORT = parseInt(process.env.WORKER_PORT, 10) || 9000; // SRS-8.2.1
const REDIS_URL   = process.env.REDIS_URL || 'redis://redis:6379';
const WORKER_NAME = process.env.WORKER_NAME || `worker-${process.pid}`;
const WORKER_PERSONA = process.env.WORKER_PERSONA || '';      // SRS-8.7.1
const MAX_BUFFER  = 10 * 1024 * 1024;                       // 10 MB
const REDIS_RETRY_LIMIT    = 3;                              // SRS-8.2.15
const REDIS_RETRY_DELAY_MS = 2000;

// --- Redis connection -------------------------------------------------------
let redis = null;

/**
 * Connect to Redis with retry logic.
 * Retries up to REDIS_RETRY_LIMIT times with REDIS_RETRY_DELAY_MS intervals.
 * @returns {Promise<import('redis').RedisClientType>}
 */
async function connectRedis() {                              // SRS-8.2.15
  for (let attempt = 1; attempt <= REDIS_RETRY_LIMIT; attempt++) {
    try {
      const client = createClient({ url: REDIS_URL });
      client.on('error', (err) => console.error(`[redis] ${err.message}`));
      await client.connect();
      console.log(`[redis] Connected to ${REDIS_URL} (attempt ${attempt})`);
      return client;
    } catch (err) {
      console.error(`[redis] Attempt ${attempt}/${REDIS_RETRY_LIMIT} failed: ${err.message}`);
      if (attempt < REDIS_RETRY_LIMIT) {
        await new Promise((r) => setTimeout(r, REDIS_RETRY_DELAY_MS));
      }
    }
  }
  throw new Error(`Failed to connect to Redis after ${REDIS_RETRY_LIMIT} attempts`);
}

// --- Shared context helpers -------------------------------------------------

/**
 * Read project-level shared context from Redis.
 * @returns {Promise<Record<string, string>>}
 */
async function readSharedContext() {                          // SRS-8.2.3
  const ctx = await redis.hGetAll('context:shared');
  return ctx || {};
}

/**
 * Read accumulated findings from all previous workers.
 * @returns {Promise<string[]>}
 */
async function readPriorFindings() {                         // SRS-8.2.4
  const findings = await redis.lRange('findings:all', 0, -1);
  return findings || [];
}

// --- Prompt builder ---------------------------------------------------------

/**
 * Build an enriched prompt combining shared context, prior findings, and the
 * task-specific prompt. The structured template ensures Claude receives full
 * project awareness before executing the task.
 *
 * @param {Record<string, string>} context - Shared context key-value pairs
 * @param {string[]} priorFindings         - Prior findings from other workers
 * @param {string} taskPrompt              - Task-specific prompt from manager
 * @returns {string}
 */
function buildEnrichedPrompt(context, priorFindings, taskPrompt) {
  const sections = [];

  // [Role] section — injected from WORKER_PERSONA env var (SRS-8.7.1)
  if (WORKER_PERSONA) {
    sections.push('[Role]');
    sections.push(WORKER_PERSONA);
    sections.push('');
  }

  // [Project Context] section
  const ctxEntries = Object.entries(context);
  if (ctxEntries.length > 0) {
    sections.push('[Project Context]');
    for (const [key, value] of ctxEntries) {
      sections.push(`${key}: ${value}`);
    }
    sections.push('');
  }

  // [Prior Findings] section
  if (priorFindings.length > 0) {
    sections.push('[Prior Findings]');
    for (const finding of priorFindings) {
      sections.push(`- ${finding}`);
    }
    sections.push('');
  }

  // [Your Task] section
  sections.push('[Your Task]');
  sections.push(taskPrompt);
  sections.push('');

  // [Output Format] section
  sections.push('[Output Format]');
  sections.push(
    'Respond with a JSON code block containing: ' +
    '{ "summary": "...", "findings": [...], "status": "done"|"error" }'
  );

  return sections.join('\n');
}

// --- Claude execution -------------------------------------------------------

/**
 * Execute `claude -p` via async spawn with stdin pipe. Using stdin pipe
 * instead of shell argument interpolation prevents command injection.
 * Async execution ensures the Node.js event loop remains free for heartbeats
 * and health checks during long-running Claude tasks.
 *
 * @param {string} enrichedPrompt - Full prompt to send via stdin
 * @param {number} timeoutMs      - Execution timeout in milliseconds
 * @returns {Promise<{ stdout: string, stderr: string, status: number|null, timedOut: boolean }>}
 */
function executeClaude(enrichedPrompt, timeoutMs) {          // SRS-8.2.5
  return new Promise((resolve) => {
    const chunks = [];
    const errChunks = [];
    let timedOut = false;

    const child = spawn('claude', ['-p'], {
      cwd: '/workspace',
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    child.stdout.on('data', (data) => chunks.push(data));
    child.stderr.on('data', (data) => errChunks.push(data));

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
    }, timeoutMs);

    child.on('close', (code) => {
      clearTimeout(timer);
      const stdout = Buffer.concat(chunks).toString('utf-8').slice(0, MAX_BUFFER);
      const stderr = Buffer.concat(errChunks).toString('utf-8').slice(0, MAX_BUFFER);
      resolve({ stdout, stderr, status: code, timedOut });
    });

    // Write prompt to stdin and close
    child.stdin.write(enrichedPrompt);
    child.stdin.end();
  });
}

// --- Output parser ----------------------------------------------------------

/**
 * Parse structured JSON findings from Claude's raw output.
 * Looks for the last ```json ... ``` code fence. If no JSON block is found,
 * returns empty findings with status "partial" (SRS-8.2.13).
 *
 * @param {string} rawOutput - Raw stdout from claude -p
 * @returns {{ summary: string, findings: any[], status: string }}
 */
function parseFindings(rawOutput) {                          // SRS-8.2.6, SRS-8.2.13
  // Find the last ```json ... ``` block
  const jsonBlockRegex = /```json\s*([\s\S]*?)```/g;
  let lastMatch = null;
  let match;
  while ((match = jsonBlockRegex.exec(rawOutput)) !== null) {
    lastMatch = match;
  }

  if (!lastMatch) {
    // No JSON block found — return partial result (SRS-8.2.13)
    return {
      summary: rawOutput.slice(0, 500),
      findings: [],
      status: 'partial',
    };
  }

  try {
    const parsed = JSON.parse(lastMatch[1].trim());
    return {
      summary: parsed.summary || '',
      findings: Array.isArray(parsed.findings) ? parsed.findings : [],
      status: parsed.status || 'done',
    };
  } catch {
    return {
      summary: rawOutput.slice(0, 500),
      findings: [],
      status: 'partial',
    };
  }
}

// --- Redis result writer ----------------------------------------------------

/**
 * Write task results back to Redis:
 *  - SET result:{taskId} as a hash with TTL 3600s (SRS-8.2.16)
 *  - RPUSH each finding to findings:{category} and findings:all (SRS-8.2.7)
 *
 * @param {string} taskId
 * @param {object} result - Parsed result from parseFindings()
 * @param {string} rawOutput
 */
async function writeResults(taskId, result, rawOutput) {     // SRS-8.2.7, SRS-8.2.16
  const resultKey = `result:${taskId}`;
  const resultData = {
    taskId,
    status: result.status,
    summary: result.summary,
    findings: JSON.stringify(result.findings),
    rawOutput: rawOutput.slice(0, 50000),                    // cap stored output
    completedAt: new Date().toISOString(),
    worker: WORKER_NAME,
  };

  // Write result hash with TTL 3600s (SRS-8.2.16)
  await redis.hSet(resultKey, resultData);
  await redis.expire(resultKey, 3600);

  // Accumulate findings (SRS-8.2.7)
  for (const finding of result.findings) {
    const findingStr = typeof finding === 'string' ? finding : JSON.stringify(finding);
    const category = (typeof finding === 'object' && finding.category) || 'general';
    await redis.rPush(`findings:${category}`, findingStr);
    await redis.rPush('findings:all', findingStr);
  }
}

// --- Worker heartbeat -------------------------------------------------------

let heartbeatInterval = null;

/**
 * Maintain worker status and heartbeat keys in Redis.
 *  - worker:{name}:status  — TTL 60s (SRS-8.2.8)
 *  - worker:{name}:heartbeat — TTL 30s (SRS-8.2.9)
 */
function startHeartbeat() {                                  // SRS-8.2.8, SRS-8.2.9
  const statusKey    = `worker:${WORKER_NAME}:status`;
  const heartbeatKey = `worker:${WORKER_NAME}:heartbeat`;

  const beat = async () => {
    try {
      await redis.set(statusKey, JSON.stringify({
        state: 'idle',
        lastTask: null,
        timestamp: new Date().toISOString(),
      }), { EX: 60 });                                      // TTL 60s
      await redis.set(heartbeatKey, Date.now().toString(), { EX: 30 }); // TTL 30s
    } catch (err) {
      console.error(`[heartbeat] ${err.message}`);
    }
  };

  beat();                                                    // initial beat
  heartbeatInterval = setInterval(beat, 15000);              // every 15s
}

/**
 * Update worker status to reflect an active task.
 * @param {string} taskId
 */
async function setWorkerBusy(taskId) {
  try {
    const statusKey = `worker:${WORKER_NAME}:status`;
    await redis.set(statusKey, JSON.stringify({
      state: 'busy',
      lastTask: taskId,
      timestamp: new Date().toISOString(),
    }), { EX: 60 });
  } catch (err) {
    console.error(`[status] ${err.message}`);
  }
}

// --- HTTP server ------------------------------------------------------------

/**
 * POST /task handler — orchestrates the full pipeline:
 *   read context → build prompt → execute claude → parse → write results
 *
 * Accepts JSON body: { taskId: string, prompt: string, timeout?: number }
 */
async function handleTask(req, res) {                        // SRS-8.2.1, SRS-8.2.2
  // Parse request body
  let body = '';
  for await (const chunk of req) body += chunk;

  let taskId, prompt, timeout;
  try {
    const parsed = JSON.parse(body);
    taskId  = parsed.taskId;
    prompt  = parsed.prompt;
    timeout = parsed.timeout || 300;                         // default 300s
  } catch {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Invalid JSON body' }));
    return;
  }

  if (!taskId || !prompt) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Missing taskId or prompt' }));
    return;
  }

  console.log(`[task] ${taskId} — starting (timeout: ${timeout}s)`);
  await setWorkerBusy(taskId);

  try {
    // Step 1: Read shared context from Redis (SRS-8.2.3, SRS-8.2.4)
    const [context, priorFindings] = await Promise.all([
      readSharedContext(),
      readPriorFindings(),
    ]);

    // Step 2: Build enriched prompt
    const enrichedPrompt = buildEnrichedPrompt(context, priorFindings, prompt);

    // Step 3: Execute claude -p via async stdin pipe (SRS-8.2.5)
    const timeoutMs = timeout * 1000;
    const claudeResult = await executeClaude(enrichedPrompt, timeoutMs);

    if (claudeResult.timedOut) {
      console.error(`[task] ${taskId} — timed out after ${timeout}s`);
      const errorResult = { summary: 'Task timed out', findings: [], status: 'error' };
      await writeResults(taskId, errorResult, '');
      res.writeHead(504, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'error', taskId, error: 'timeout' }));
      return;
    }

    // Step 4: Parse findings from output (SRS-8.2.6, SRS-8.2.13)
    const result = parseFindings(claudeResult.stdout);

    // Step 5: Write results to Redis (SRS-8.2.7, SRS-8.2.16)
    await writeResults(taskId, result, claudeResult.stdout);

    // Step 6: Respond to manager (SRS-8.2.10)
    console.log(`[task] ${taskId} — completed (status: ${result.status})`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: result.status,
      taskId,
      output: claudeResult.stdout.slice(0, 10000),
      findings: result.findings,
    }));

  } catch (err) {
    console.error(`[task] ${taskId} — error: ${err.message}`);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'error', taskId, error: err.message }));
  }
}

/**
 * GET /health handler — simple health check endpoint.
 */
function handleHealth(req, res) {
  const healthy = redis !== null && redis.isOpen;
  res.writeHead(healthy ? 200 : 503, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    status: healthy ? 'ok' : 'unhealthy',
    worker: WORKER_NAME,
    redis: healthy ? 'connected' : 'disconnected',
  }));
}

/**
 * HTTP request router.
 */
const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/task') {
    handleTask(req, res);
  } else if (req.method === 'GET' && req.url === '/health') {
    handleHealth(req, res);
  } else {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found' }));
  }
});

// --- Startup ----------------------------------------------------------------

async function main() {
  try {
    redis = await connectRedis();                            // SRS-8.2.15
    startHeartbeat();                                        // SRS-8.2.8, SRS-8.2.9

    server.listen(WORKER_PORT, () => {
      console.log(`[worker] ${WORKER_NAME} listening on :${WORKER_PORT}`);
    });
  } catch (err) {
    console.error(`[fatal] ${err.message}`);
    process.exit(1);
  }
}

// --- Graceful shutdown ------------------------------------------------------

function shutdown(signal) {
  console.log(`[worker] Received ${signal}, shutting down...`);
  clearInterval(heartbeatInterval);

  server.close(async () => {
    if (redis && redis.isOpen) {
      // Clear status keys before disconnecting
      try {
        await redis.del(`worker:${WORKER_NAME}:status`);
        await redis.del(`worker:${WORKER_NAME}:heartbeat`);
      } catch { /* ignore during shutdown */ }
      await redis.quit();
    }
    console.log('[worker] Shutdown complete.');
    process.exit(0);
  });

  // Force exit if graceful shutdown takes too long
  setTimeout(() => process.exit(1), 5000);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

main();
```

**Design decisions:**

- **Async `spawn` with stdin pipe** — prevents command injection by writing the prompt to stdin (never interpolated into a shell command). Async execution keeps the event loop free so heartbeats (15s interval) and `/health` requests continue to work during long-running Claude tasks. A synchronous `spawnSync` would block the event loop for the full task duration, causing heartbeat TTL (30s) to expire and health checks to time out. (SRS-8.2.5)
- **Last ``` \`\`\`json\`\`\` ``` fence extraction** — Claude may produce conversational text before/after the JSON block; taking the last fence is the most reliable heuristic for structured output (SRS-8.2.6, SRS-8.2.14)
- **Partial status on parse failure** — if no JSON block is found, returns `status: "partial"` with empty findings rather than failing the entire task, allowing the manager to decide on retry strategy (SRS-8.2.13)
- **Result hash TTL 3600s** — prevents unbounded Redis memory growth while keeping results available for the manager's aggregation window (SRS-8.2.16)
- **Dual findings lists** — findings are pushed to both `findings:{category}` and `findings:all` so workers can read the global list while the manager can query by category (SRS-8.2.7)
- **15-second heartbeat interval** — ensures `worker:{name}:heartbeat` (TTL 30s) never expires during normal operation; the manager can detect dead workers within 30s (SRS-8.2.8, SRS-8.2.9)
- **Redis retry with fixed intervals** — 3 retries at 2s intervals balances fast startup with resilience to transient connection issues during container orchestration (SRS-8.2.15)
- **Graceful shutdown** — cleans up Redis status keys and closes the HTTP server on SIGTERM/SIGINT, with a 5s forced-exit safety net
- **10 MB maxBuffer** — accommodates large Claude outputs without risking OOM on the worker container

### 5.4 scripts/manager-helpers.sh (Phase 5)

Bash helper functions sourced by the manager to dispatch tasks and query state.
Reference: SRS-8.3.1~5, SRS-8.7.2.
12 functions total.

```bash
#!/usr/bin/env bash
# SRS-8.3.1–5: Manager helper functions for orchestration
# Source this file inside manager container: source /scripts/manager-helpers.sh
set -euo pipefail

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
# Args: $1 = prompt text (or unique prompts via stdin, one per line)
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
    for pid in "${pids[@]}"; do wait "$pid"; done
    for tmp in "${tmpfiles[@]}"; do cat "$tmp"; rm -f "$tmp"; done
}

# SRS-8.3.3: Retrieve all findings from Redis
get_findings() {
    local category="${1:-all}"
    redis-cli -u "$REDIS_URL" PING > /dev/null 2>&1 || { echo "Error: Redis unreachable" >&2; return 1; }
    redis-cli -u "$REDIS_URL" LRANGE "findings:${category}" 0 -1
}

# SRS-8.3.7: Clear findings before new session
clear_findings() {
    redis-cli -u "$REDIS_URL" DEL findings:all > /dev/null
    echo "Findings cleared."
}

# SRS-8.3.4: Get status of all workers
get_worker_status() {
    local count="${WORKER_COUNT:-3}"
    for i in $(seq 1 "$count"); do
        echo "worker-$i: $(redis-cli -u "$REDIS_URL" GET "worker:worker-$i:status")"
    done
}

# SRS-8.3.5: Set shared context for all workers
# Args: $1 = field name, $2 = value
set_shared_context() {
    local field="$1" value="$2"
    redis-cli -u "$REDIS_URL" HSET context:shared "$field" "$value"
}
```

### 5.5 scripts/test-orchestration.sh

E2E test validating the full Phase 5 orchestration pipeline (SRS-8.4.1–5).

```bash
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

    result=$(mgr redis-cli -u redis://redis:6379 GET "$result_key" 2>/dev/null || echo "")

    if [ -n "$result" ] && [ "$result" != "(nil)" ]; then
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
```

**Test stages:**

1. **Build and start services** — `docker compose up -d` with orchestration overlay (SRS-8.4.1)
2. **Wait for worker health** — Poll `GET /health` on each worker with timeout
3. **Set shared context** — Write project metadata to `context:shared` hash in Redis
4. **Dispatch tasks sequentially** — Send 3 distinct tasks to 3 workers one at a time; sequential ordering ensures worker-2 sees worker-1's findings (SRS-8.4.2)
5. **Verify results in Redis** — Check `result:<worker>:<taskId>` keys exist (SRS-8.4.3)
6. **Verify findings accumulation** — Check `findings:all` list length > 0; WARN (not FAIL) if empty since Claude may not produce structured JSON (SRS-8.4.4)
7. **Cleanup** — `trap cleanup EXIT` runs `docker compose down --remove-orphans -v` (SRS-8.4.5)

### 5.6 Cold Memory Layer Design (Phase 6)

File-based persistent archive for cross-session findings accumulation, context
auto-restore, and worker performance metrics. SRS-8.5.1–15.

#### 5.6.1 Archive Directory Structure

Host path: `~/.claude-state/analysis-archive/` (bind-mounted to `/archive` in manager).

```
~/.claude-state/analysis-archive/
├── sessions/
│   ├── 20260328T143000Z_a1b2c3d4/
│   │   ├── session.json          # Session metadata + task metrics
│   │   ├── context.json          # Snapshot of context:shared hash
│   │   └── findings.json         # findings:all + per-category findings
│   └── ...
└── index.json                    # Lightweight session index for fast listing
```

Directory naming: `<ISO8601-compact>_<8-char-hex-id>`. Timestamp prefix enables
chronological `ls` sorting. Max 50 sessions; oldest auto-pruned on save (SRS-8.5.8).

#### 5.6.2 JSON Schemas

**session.json**:
```json
{
  "version": "1.0.0",
  "id": "<session-id>",
  "startedAt": "<ISO8601>",
  "endedAt": "<ISO8601>",
  "durationSeconds": 0,
  "projectDir": "/workspace",
  "workerCount": 3,
  "tasks": [
    {
      "taskId": "<uuid>",
      "worker": "worker-1",
      "status": "done|partial|error",
      "summary": "<text>",
      "findingsCount": 0,
      "durationMs": 0,
      "completedAt": "<ISO8601>"
    }
  ],
  "metrics": {
    "totalFindings": 0,
    "findingsByCategory": { "<category>": 0 },
    "totalTasks": 0,
    "completedTasks": 0,
    "failedTasks": 0
  }
}
```

**context.json**:
```json
{
  "version": "1.0.0",
  "capturedAt": "<ISO8601>",
  "fields": { "<key>": "<value>" }
}
```

**findings.json**:
```json
{
  "version": "1.0.0",
  "capturedAt": "<ISO8601>",
  "totalCount": 0,
  "all": ["<finding-json-string>", "..."],
  "byCategory": { "<category>": ["<finding-json-string>"] }
}
```

**index.json** (top-level):
```json
{
  "version": "1.0.0",
  "maxSessions": 50,
  "sessions": [
    {
      "id": "<session-id>",
      "endedAt": "<ISO8601>",
      "findingsCount": 0,
      "categoryCounts": {},
      "taskCount": 0,
      "contextFields": ["<key>"]
    }
  ]
}
```

#### 5.6.3 Manager Helper Functions (additions to manager-helpers.sh)

| Function | SRS | Args | Redis Ops | File Ops |
|----------|-----|------|-----------|----------|
| `save_session` | 8.5.3 | `[start_ts]` | HGETALL context:shared, LRANGE findings:all, KEYS findings:*, KEYS result:*, HGETALL result:* | Write 3 JSON files + update index.json |
| `restore_session` | 8.5.4 | `<id\|latest>` | HSET context:shared, RPUSH findings:all, RPUSH findings:{cat} | Read context.json + findings.json |
| `list_sessions` | 8.5.5 | none | none | Read index.json |
| `show_session` | 8.5.6 | `<id>` | none | Read session.json + context.json + findings.json |
| `run_analysis` | 8.7.2 | `<prompt> [timeout]` | clear_findings, LLEN findings:all, LLEN findings:{cat} | Read personas.json; auto-calls save_session |

All functions use `ARCHIVE_DIR` env var (default `/archive`) and `_require_redis`
guard for Redis-dependent operations. `save_session` is Redis-read-only (SRS-8.5.14).

**`run_analysis`** (SRS-8.7.2): Loads worker personas from `/scripts/personas.json`,
wraps the user prompt with each persona's role instructions, dispatches all workers
in parallel, collects results, prints a categorized summary (security, quality,
performance), and auto-saves the session via `save_session`.

**Implementation note**: `save_session` generates session IDs using `od` instead of
`xxd` for session hex generation (`head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n'`),
since `xxd` is not available in the `node:20-slim` base image.

#### 5.6.4 Docker Compose Change

One bind mount added to manager service in `docker-compose.orchestration.yml`:

```yaml
volumes:
  - ${HOME}/.claude-state/analysis-archive:/archive          # SRS-8.5.1
environment:
  - ARCHIVE_DIR=/archive                                     # SRS-8.5.2
```

Workers do NOT mount `/archive` — they access archived data via Redis after
`restore_session` loads it (SRS-8.5.11).

#### 5.6.5 Worker Server Timing Hook (optional)

`writeResults()` in `worker-server.js` gains two optional fields: `startedAt`
(ISO8601 timestamp) and `durationMs` (wall-clock milliseconds). These are
recorded by `handleTask()` before Claude execution and passed through. The
change is backward-compatible: existing callers without timing args omit the
fields silently (SRS-8.5.7).

#### 5.6.6 Design Decisions

| Decision | Rationale |
|----------|-----------|
| **JSON files** (not SQLite) | jq is already installed; no new dependencies; human-readable |
| **Manager-only writes** | Avoids concurrent write races from multiple workers |
| **Redis read-only on save** | Hot path completely untouched; no risk of disrupting active analysis |
| **50-session cap** | ~100KB/session × 50 = ~5MB max; prevents unbounded growth |
| **Opt-in** | `/archive` not mounted → functions error clearly; existing flow unaffected |
| **index.json** | Fast listing without scanning session directories |
| **Host bind mount** | Survives `docker compose down -v` (named volumes are deleted) |

### 5.7 scripts/claude-docker (CLI Wrapper)

Unified host-side CLI wrapper that auto-detects compose overlay files and
provides short subcommands for common operations.

**Key functions:**

| Function | Purpose |
|----------|---------|
| `cmd_usage()` | Token usage report via `ccusage`; merges session data from all account state dirs |
| `cmd_analyze()` | Multi-persona project analysis; delegates to `run_analysis` inside manager container |
| `get_keychain_credentials()` | Extracts OAuth tokens from macOS Keychain via `security find-generic-password -s "Claude Code-credentials" -w` |
| `inject_credentials()` | Writes credential JSON to a service's bind-mounted state directory on the host |
| `build_merged_config_dir()` | Creates a temp directory with symlinks to all account project dirs for `ccusage` aggregation |
| `list_account_dirs()` | Enumerates `~/.claude-state/account-*` directories |

**Authentication rewrite**: The `cmd_auth` subcommand was rewritten from
container-internal OAuth (`claude auth login` inside the container) to macOS
Keychain extraction. On macOS, `get_keychain_credentials()` reads the host's
OAuth tokens from the system Keychain, and `inject_credentials()` writes them
to each service's bind-mounted `~/.claude-state/account-*/` directory as
`.credentials.json`. This bypasses the container OAuth boundary problem
(localhost callback fails across the Docker network boundary; see GitHub #34917,
#30369). On non-macOS platforms, the command falls back to prompting the user
to authenticate on the host first or use API keys.

---

## 6. Operational Flows

### 6.1 First Run — Path A (Subscription)

**macOS (Keychain extraction):**

```
Host                                    Docker
─────                                   ──────
1. claude auth login                    (authenticate on host — tokens saved to macOS Keychain)
2. mkdir -p ~/.claude-state/account-{a,b}
3. cp .env.example .env
   └─ Set PROJECT_DIR only (no API keys)
4.                                      docker compose build
5.                                      docker compose up -d
6. scripts/claude-docker auth           (extracts Keychain credentials → writes .credentials.json
                                         to each bind-mounted state dir)
7.                                      docker compose exec claude-a claude
   └─ Claude Code starts with injected OAuth tokens ✓
```

**Linux / WSL2 (container-internal OAuth):**

```
Host                                    Docker
─────                                   ──────
1. mkdir -p ~/.claude-state/account-{a,b}
2. cp .env.example .env
   └─ Set PROJECT_DIR only (no API keys)
3.                                      docker compose build
4.                                      docker compose up -d
5.                                      docker compose exec claude-a claude auth login
   └─ Claude Code initiates OAuth → browser opens
   └─ .credentials.json created in bind-mounted state dir ✓
6.                                      docker compose exec claude-a claude
```

### 6.2 First Run — Path B (Console API Key)

```
Host                                    Docker
─────                                   ──────
1. mkdir -p ~/.claude-state/account-{a,b}
2. cp .env.example .env
   └─ Set PROJECT_DIR + CLAUDE_API_KEY_A + CLAUDE_API_KEY_B
3.                                      docker compose build
4.                                      docker compose up -d
5.                                      docker compose exec claude-a npm install
6.                                      docker compose exec claude-b npm install
7.                                      docker compose exec claude-a claude
   └─ Claude Code starts with API key ✓
```

### 6.3 Adding Nth Account

```
1. Create state dir:    mkdir -p ~/.claude-state/account-c
2. Auth (Path A):       docker compose exec claude-c claude auth login
   Auth (Path B):       Add CLAUDE_API_KEY_C=sk-ant-... to .env
3. Add to compose:      Copy claude-b service block → rename to claude-c
                        Update account-b → account-c, _B → _C, node_modules_b → _c
4. Add named volume:    node_modules_c: under volumes:
5. Start:               docker compose up -d claude-c
6. Install deps:        docker compose exec claude-c npm install
```

### 6.4 Token Recovery (Path A)

```
Symptom: Claude Code shows "Authentication expired" inside container

1. Inside the container (not on host):
   docker compose exec claude-a claude auth login

2. Or restart container (token auto-refresh may resolve):
   docker compose restart claude-a

3. Verify:
   docker compose exec claude-a claude auth status
```

### 6.5 Troubleshooting Decision Tree

```
Container won't start
├── "image not found" → Run: docker compose build
├── "port already in use" → No ports should be exposed; check compose
└── "permission denied on volume"
    ├── Linux → Check UID/GID: id -u; add docker-compose.linux.yml
    ├── macOS → Check Docker Desktop file sharing settings
    └── Windows → Ensure path is WSL2 fs, not /mnt/c/

Claude Code won't authenticate
├── Path A (OAuth)
│   ├── macOS → Run: scripts/claude-docker auth (extracts Keychain → injects to state dirs)
│   ├── "No credentials" → Linux/WSL2: re-run claude auth login INSIDE the container
│   ├── "Token expired" → Re-run auth (Keychain or container-internal); restart container
│   └── "Redirect URI error" → Use Keychain extraction on macOS; container OAuth on Linux
└── Path B (API key)
    ├── "Invalid API key" → Check .env; ensure no quotes around key value
    └── "API key not found" → Check variable name matches compose: CLAUDE_API_KEY_A

Bind mount not working
├── File created on host not visible in container → Check PROJECT_DIR path
├── File created in container not visible on host → Check volume type (named vs bind)
└── Permission denied writing to /workspace
    ├── Linux → Add docker-compose.linux.yml with user: "${UID}:${GID}"
    └── Windows → Move source to WSL2 filesystem
```

### 6.6 Orchestration First Run (Phase 5)

```
Host                                    Docker
─────                                   ──────
1. mkdir -p ~/.claude-state/account-{manager,w1,w2,w3}
2. Configure .env (install.sh generates WORKER_AUTH_TOKEN and REDIS_PASSWORD automatically):
   Path A (OAuth): Set PROJECT_DIR and WORKER_COUNT=3 only (no API keys)
   Path B (API key): Add CLAUDE_API_KEY_MANAGER, CLAUDE_API_KEY_1~3 to .env
3.                                      docker compose -f docker-compose.yml \
                                          -f docker-compose.orchestration.yml build
4.                                      docker compose -f docker-compose.yml \
                                          -f docker-compose.orchestration.yml up -d
5. Authenticate (Path A only):
   macOS:                               scripts/claude-docker auth
   └─ Extracts Keychain credentials → writes .credentials.json to all state dirs
   Linux/WSL2:                          docker compose exec manager claude auth login
                                        docker compose exec worker-1 claude auth login
                                        docker compose exec worker-2 claude auth login
                                        docker compose exec worker-3 claude auth login
   └─ Each initiates OAuth → browser opens → credentials saved to bind-mounted state dir
6.                                      docker compose -f docker-compose.yml \
                                          -f docker-compose.orchestration.yml \
                                          exec manager bash
7. source /scripts/manager-helpers.sh
8. set_shared_context "project_summary" "Description of the project..."
9. dispatch_task worker-1 "analyze auth module"
   dispatch_task worker-2 "analyze database layer"
   dispatch_task worker-3 "analyze API routes"
10. get_findings
    └─ Returns combined findings from all workers
```

### 6.7 Analyze Flow (Multi-Persona)

```
Host                                    Docker (manager)             Docker (workers)
─────                                   ────────────────             ────────────────
1. scripts/claude-docker analyze \
     "Review this codebase"
                                        2. source manager-helpers.sh
                                           run_analysis "..."
                                           ├─ Load /scripts/personas.json
                                           ├─ clear_findings
                                           ├─ dispatch_task worker-1   ──→  3a. [Sentinel] security analysis
                                           ├─ dispatch_task worker-2   ──→  3b. [Reviewer] quality analysis
                                           └─ dispatch_task worker-3   ──→  3c. [Profiler] performance analysis
                                                                            (each writes findings to Redis)
                                        4. Collect results from Redis
                                           ├─ Print categorized summary
                                           └─ save_session (auto-archive)
5. View summary output
```

---

## 7. SRS Traceability

| SRS Spec Range | SDS Section | Deliverable File |
|---------------|-------------|-----------------|
| SRS-5.1.1~10 (Image Build); SRS-5.1.11~12 (Phase 5) | 2. Dockerfile Design | `Dockerfile` |
| SRS-5.2.1~11 (Orchestration) | 3.1 Base Compose | `docker-compose.yml` |
| SRS-5.3.1 (Path A OAuth) | 6.1 First Run Path A | (operational procedure) |
| SRS-5.3.2 (Path B API Key) | 6.2 First Run Path B | (operational procedure) |
| SRS-5.3.3 (Precedence) | 3.1 compose `:-` syntax | `docker-compose.yml` |
| SRS-5.4.1 (Tier A) | 3.1 Base Compose | `docker-compose.yml` |
| SRS-5.4.2 (Tier B) | 3.3 Worktree Override, 5.1 Script | `docker-compose.worktree.yml`, `setup-worktrees.sh` |
| SRS-5.4.3 (Dependencies) | 3.1 named volumes | `docker-compose.yml` |
| SRS-5.5 (Scaling) | 6.3 Adding Nth Account | (operational procedure) |
| SRS-6.1.1~5 (Linux) | 3.2 Linux Override | `docker-compose.linux.yml` |
| SRS-6.2.1~4 (macOS) | 3.1 Base Compose (default) | `docker-compose.yml` |
| SRS-6.3.1~6 (Windows) | 4.4 .gitattributes, 6.5 Troubleshooting | `.gitattributes` |
| SRS-7.3 (Security/Firewall) | 3.4 Firewall Override | `docker-compose.firewall.yml` |
| SRS-4.4 (Volume Matrix) | 3.1~3.3 all compose files | `docker-compose*.yml` |
| SRS-4.5 (.env Format) | 4.1 .env.example | `.env.example` |
| SRS-8.1.1~11 (Orchestration Compose) | 3.6 Orchestration Override | `docker-compose.orchestration.yml` |
| SRS-8.2.1~18 (Worker Server) | 5.3 Worker Server | `scripts/worker-server.js` |
| SRS-8.3.1~5 (Manager Helpers) | 5.4 Manager Helpers | `scripts/manager-helpers.sh` |
| SRS-8.4.1~5 (Orchestration Tests) | 5.5 Test Script | `scripts/test-orchestration.sh` |
| SRS-8.5.1~15 (Cold Memory) | 5.6 Cold Memory Layer | `scripts/manager-helpers.sh` (additions), `docker-compose.orchestration.yml` (mount) |

### Deliverable File Inventory

| File | Phase | SRS Coverage |
|------|-------|-------------|
| `Dockerfile` | 1 (+ Phase 5 additions) | SRS-5.1.1~10; SRS-5.1.11~12 deferred to Phase 5 |
| `.dockerignore` | 1 | SRS-5.1.9 |
| `docker-compose.yml` | 2 | SRS-5.2.1~11, 5.4.1, 5.4.3 |
| `docker-compose.linux.yml` | 2 | SRS-6.1.1~3 |
| `docker-compose.worktree.yml` | 3 | SRS-5.4.2 |
| `docker-compose.firewall.yml` | 4 | SRS-7.3 |
| `.env.example` | 2 | SRS-4.5 |
| `.gitignore` | 2 | SRS-7.3 (security) |
| `.gitattributes` | 2 | SRS-6.3.4 |
| `scripts/setup-worktrees.sh` | 3 | SRS-5.4.2 |
| `scripts/test-concurrent-git.sh` | 3 | SRS-5.4.2 (verification) |
| `scripts/cleanup.sh` | 4 | SRS-5.5 (FR-17) |
| `docker-compose.orchestration.yml` | 5 | SRS-8.1.1~11 |
| `scripts/worker-server.js` | 5 | SRS-8.2.1~18 |
| `scripts/manager-helpers.sh` | 5 | SRS-8.3.1~5 |
| `scripts/init-firewall.sh` | 4 | SRS-7.3 |
| `scripts/personas.json` | 7 | Worker persona definitions (Sentinel, Reviewer, Profiler) |
| `CLAUDE.md` | 7 | Manager auto-orchestration instructions |
| `scripts/claude-docker` | — | Utility: CLI wrapper (Keychain auth, usage tracking via ccusage, analyze command) |
| `scripts/install.sh` | — | Utility: project installer |
| `scripts/remove.sh` | — | Utility: project uninstaller |
| `scripts/test-orchestration.sh` | 5 | SRS-8.4.1~5 |
