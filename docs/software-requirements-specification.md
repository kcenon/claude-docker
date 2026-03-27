# SRS: Dual Claude Code Container Architecture

**Status**: Draft | **Version**: 1.0.0 | **Date**: 2026-03-27

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
macOS, and Windows (WSL2), two authentication paths (OAuth subscription
and Console API key), and two source-sharing tiers (shared bind mount
and git worktree).

### 1.3 Definitions

| Term | Definition |
|------|-----------|
| Path A | Host-first OAuth authentication for subscription accounts (Pro/Max/Team) |
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
| Host auth CLI | `claude auth login` (on host) | Path A: OAuth login |
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

### 4.2 Credential File Schema

**File**: `$CLAUDE_CONFIG_DIR/.credentials.json`
**Permissions**: `0600` (owner read/write only)
**Created by**: `claude auth login` on host (Path A)

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
has network access to `api.anthropic.com`. Full re-auth on host is
needed only upon password change or account revocation.

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
1. User SHALL install Claude Code on the host.
2. User SHALL run `CLAUDE_CONFIG_DIR=~/.claude-state/account-X claude auth login` for each account.
3. Browser SHALL open on the host for OAuth completion.
4. `.credentials.json` SHALL be created in the specified state directory.
5. User SHALL verify with `claude auth status`.
6. Container SHALL inherit credentials via bind mount — no in-container auth needed.
7. Token refresh SHALL occur automatically via `refreshToken`.
8. On token expiry beyond refresh, user SHALL re-run `claude auth login` on host.

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
| Token expiry (beyond refresh) | Claude Code prompts error. User re-runs `claude auth login` on host. |
| API key rotation (Path B) | User updates `.env`, runs `docker compose restart`. |
| Network loss | Claude Code shows connection error. Resumes on reconnect. |

---

## 8. Constraints and Assumptions

### 8.1 Technology Constraints

- Alpine Linux base images are NOT supported (musl incompatible with Claude Code).
- Interactive CLI commands (`vim`, `git rebase -i`) are NOT supported inside Claude Code's shell tool (GitHub #26353).
- Docker-in-Docker is NOT used. Containers do not manage other containers.
- `docker compose` V2 (Go binary, space-separated) is required. Legacy `docker-compose` V1 (Python, hyphenated) is not tested.

### 8.2 Assumptions

- Host has internet access for initial image build and Claude API communication.
- For Path A, the host has a browser for OAuth login.
- For Tier B, branches `branch-a` and `branch-b` exist or will be created.
- Host user has Docker permissions (member of `docker` group on Linux, or Docker Desktop installed on macOS/Windows).

---

## 9. Verification and Traceability

### 9.1 Upstream Traceability (SRS → PRD)

Each SRS functional section traces back to PRD Goals and Functional Requirements.

| SRS Section | Specs | PRD FR | PRD Goal | Phase |
|-------------|-------|--------|----------|-------|
| 5.1 Image Build | SRS-5.1.1~10 | FR-1~5 | G1, G5 | 1 |
| 5.2 Container Orchestration | SRS-5.2.1~11 | FR-6, FR-9, FR-10, FR-12 | G2, G3, G5 | 2, 3 |
| 5.3 Authentication | SRS-5.3.1~3 | FR-7, FR-8 | G2, G7 | 2 |
| 5.4 Source Sharing | SRS-5.4.1~3 | FR-10~13 | G3, G4 | 3 |
| 5.5 Scaling | SRS-5.5 | — | G8 | 2, 3 |
| 6.1 Linux Adaptation | SRS-6.1.1~5 | — | G6 | 2 |
| 6.2 macOS Adaptation | SRS-6.2.1~4 | — | G6 | 2 |
| 6.3 Windows Adaptation | SRS-6.3.1~6 | — | G6 | 2 |
| 7.3 Security | SRS-7.3 | FR-14 | G5 | 4 |

### 9.2 Downstream Verification (PRD FR → SRS → Test)

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
| FR-7 (Path A OAuth) | SRS-5.3.1 | Run `claude auth login` on host with `CLAUDE_CONFIG_DIR`; start container; verify `claude auth status` succeeds inside container |
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
