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

# SRS-5.1.5: Memory heap limit
ENV NODE_OPTIONS=--max-old-space-size=4096

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

### 3.4 Firewall Override — docker-compose.firewall.yml (Phase 4)

```yaml
# docker-compose.firewall.yml

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

### 3.5 Compose Combination Matrix

| Scenario | Command |
|----------|---------|
| macOS/Windows + Tier A | `docker compose up` |
| macOS/Windows + Tier B | `docker compose -f docker-compose.yml -f docker-compose.worktree.yml up` |
| Linux + Tier A | `docker compose -f docker-compose.yml -f docker-compose.linux.yml up` |
| Linux + Tier B | `docker compose -f docker-compose.yml -f docker-compose.linux.yml -f docker-compose.worktree.yml up` |
| Any + Firewall | Append `-f docker-compose.firewall.yml` |

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

---

## 6. Operational Flows

### 6.1 First Run — Path A (Subscription)

```
Host                                    Docker
─────                                   ──────
1. npm install -g @anthropic-ai/claude-code
2. mkdir -p ~/.claude-state/account-{a,b}
3. CLAUDE_CONFIG_DIR=~/.claude-state/account-a \
     claude auth login
   └─ Browser opens → OAuth → .credentials.json created
4. CLAUDE_CONFIG_DIR=~/.claude-state/account-b \
     claude auth login
   └─ Browser opens → OAuth → .credentials.json created
5. cp .env.example .env
   └─ Set PROJECT_DIR only (no API keys)
6.                                      docker compose build
7.                                      docker compose up -d
8.                                      docker compose exec claude-a npm install
9.                                      docker compose exec claude-b npm install
10.                                     docker compose exec claude-a claude
    └─ Claude Code starts with account-a credentials ✓
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
2. Auth (Path A):       CLAUDE_CONFIG_DIR=~/.claude-state/account-c claude auth login
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

1. On HOST (not container):
   CLAUDE_CONFIG_DIR=~/.claude-state/account-a claude auth login

2. Restart container to reload credentials:
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
│   ├── "No credentials" → Re-run claude auth login on HOST
│   ├── "Token expired" → Re-run claude auth login on HOST; restart container
│   └── "Redirect URI error" → You're running auth INSIDE container; do it on HOST
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

---

## 7. SRS Traceability

| SRS Spec Range | SDS Section | Deliverable File |
|---------------|-------------|-----------------|
| SRS-5.1.1~10 (Image Build) | 2. Dockerfile Design | `Dockerfile` |
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

### Deliverable File Inventory

| File | Phase | SRS Coverage |
|------|-------|-------------|
| `Dockerfile` | 1 | SRS-5.1.1~10 |
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
