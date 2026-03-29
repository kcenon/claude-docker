# Claude Docker

Run multiple Claude Code instances simultaneously on a single host with
isolated accounts and shared source code.

Each additional instance adds only **20-70 MB** of disk overhead (vs 4-10 GB
per VM) by sharing a single Docker image and bind-mounting the project source.

## Features

- **Multi-account isolation** -- Each container has its own credentials, settings, and history
- **Shared source code** -- Bind mount (Tier A) or git worktree (Tier B) for concurrent editing
- **Cross-platform** -- Linux, macOS, Windows (WSL2)
- **Subscription + API key** -- OAuth for Pro/Max/Team (via container), or `ANTHROPIC_API_KEY` for Console
- **Scalable to N instances** -- Add accounts by copying a compose service block

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) 24.0+ (Linux) or [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS / Windows)
- [Node.js](https://nodejs.org/) 20+ (optional -- needed for `usage` subcommand token reports)
- Git

**Platform-specific:**

| Platform | Additional Requirements |
|----------|----------------------|
| Linux | UID/GID matching (`id -u`, `id -g`) |
| macOS | Docker Desktop with VirtioFS (default) |
| Windows | WSL2 with source code on WSL2 filesystem (not `/mnt/c/`) |

## Quick Start

### Option A: Interactive Setup (Recommended)

```bash
git clone <repo-url> claude-docker
cd claude-docker
scripts/install.sh
```

The script guides you through platform detection, authentication, source sharing,
and container setup via interactive Q&A.

### Option B: Manual Setup

#### 1. Clone and configure

```bash
git clone <repo-url> claude-docker
cd claude-docker
cp .env.example .env
```

Edit `.env`:

```bash
PROJECT_DIR=/absolute/path/to/your/project
```

### 2. Authenticate

Choose your authentication path:

**Path A -- Subscription accounts (Pro / Max / Team):**

macOS:
```bash
# 1. Authenticate on host (one-time, opens browser)
claude auth login

# 2. Inject credentials into all containers
scripts/claude-docker auth
```

Linux / WSL2:
```bash
# Authenticate inside each container after starting
scripts/claude-docker claude claude-a
# Inside container: claude auth login
# (follow OAuth URL in browser, paste code)
```

Note: On macOS, container-internal OAuth fails due to Docker network
boundary limitations ([#34917](https://github.com/anthropics/claude-code/issues/34917)).
The `auth` command extracts tokens from macOS Keychain instead.

**Path B -- Console API keys:**

Add to `.env`:

```bash
CLAUDE_API_KEY_A=sk-ant-...
CLAUDE_API_KEY_B=sk-ant-...
```

### 3. Build and run

```bash
scripts/claude-docker build
scripts/claude-docker up
```

The CLI wrapper auto-detects your platform and applies the correct
compose overrides (Linux UID/GID, worktree, orchestration, firewall).

### 4. Authenticate and start

```bash
# Authenticate all containers (opens OAuth in browser)
scripts/claude-docker auth

# Start Claude Code
scripts/claude-docker claude
```

In a separate terminal:

```bash
scripts/claude-docker claude claude-b
```

## Usage

The `scripts/claude-docker` CLI wrapper automatically detects your
configuration (platform, tier, orchestration, firewall) and builds the
correct `docker compose -f` chain. All subcommands below use this wrapper.

### Quick Reference

```bash
scripts/claude-docker help       # Show all available commands
```

| Category | Command | Description |
|----------|---------|-------------|
| **Lifecycle** | `up` | Start all containers |
| | `down` | Stop all containers |
| | `restart` | Restart all containers |
| | `build` | Build/rebuild Docker image |
| | `ps` | Show container status |
| | `logs` | Follow container logs |
| **Interactive** | `claude [service]` | Start Claude Code (default: primary service) |
| | `auth [service]` | Authenticate via OAuth login |
| | `exec <service>` | Open shell in a container |
| **Orchestration** | `dispatch <worker> <prompt>` | Send task to worker |
| | `analyze <prompt>` | Multi-persona project analysis |
| | `status` | Show worker status |
| | `findings [category]` | Show accumulated findings |
| **Cold Memory** | `save` | Save session to archive |
| | `restore [id\|latest]` | Restore session from archive |
| | `sessions` | List archived sessions |
| **Usage Tracking** | `usage [type] [flags]` | Token usage report |
| **Advanced** | `config` | Show resolved compose configuration |
| | `compose ...` | Pass raw args to docker compose |

### Starting and Stopping

```bash
# Start all containers (detached)
scripts/claude-docker up

# Stop all containers (state preserved on host via bind mounts)
scripts/claude-docker down

# Restart
scripts/claude-docker restart

# Check status
scripts/claude-docker ps
```

### Running Claude Code

```bash
# Start Claude Code in the primary service (claude-a or manager)
scripts/claude-docker claude

# Start in a specific container
scripts/claude-docker claude claude-b
```

Open separate terminals for simultaneous sessions:

```bash
# Terminal 1
scripts/claude-docker claude claude-a

# Terminal 2
scripts/claude-docker claude claude-b
```

Both sessions see the same project source at `/workspace` (Tier A) or
their own worktree (Tier B). Each session has independent conversation
history, settings, and credentials.

### Authentication

On macOS, `scripts/claude-docker auth` extracts OAuth credentials from the
host's macOS Keychain and injects them into each container's state directory.
Host-side authentication (`claude auth login`) must be completed first.

On Linux/WSL2, authenticate directly inside containers.

```bash
# macOS: extract from Keychain → inject to all containers
scripts/claude-docker auth

# macOS: inject to specific container only
scripts/claude-docker auth claude-a

# Linux/WSL2: authenticate inside container
scripts/claude-docker exec claude-a claude auth login

# Check status in any container
scripts/claude-docker exec claude-a claude auth status
```

### Running Commands Inside Containers

```bash
# Open a shell
scripts/claude-docker exec claude-a

# Run a one-off command
scripts/claude-docker exec claude-a git status
scripts/claude-docker exec claude-a claude --version
```

### Viewing Logs

```bash
# Follow all container logs
scripts/claude-docker logs

# Follow a specific container
scripts/claude-docker logs claude-a

# Last 50 lines
scripts/claude-docker logs --tail 50 claude-a
```

### Rebuilding the Image

```bash
# Rebuild with latest Claude Code
scripts/claude-docker build --no-cache

# Pin a specific version in .env:
#   CLAUDE_CODE_VERSION=1.2.3
scripts/claude-docker build

# Recreate containers with the new image
scripts/claude-docker up --force-recreate
```

### Using Git Inside Containers

**Tier A** (shared source) -- both containers share `.git`:

```bash
# Only run git commands from ONE container at a time to avoid lock contention
scripts/claude-docker exec claude-a git add -A
scripts/claude-docker exec claude-a git commit -m "feat: add feature"
```

**Tier B** (worktrees) -- each container has its own branch:

```bash
# Container A commits to branch-a
scripts/claude-docker exec claude-a git commit -am "feat: add feature"

# Container B commits to branch-b (no conflict)
scripts/claude-docker exec claude-b git commit -am "fix: resolve bug"
```

### Orchestration (Multi-Agent)

When orchestration is enabled (Phase 5), the CLI detects it automatically:

```bash
# Dispatch a task to a specific worker
scripts/claude-docker dispatch worker-1 "analyze the authentication module"

# Dispatch with custom timeout (seconds)
scripts/claude-docker dispatch worker-2 "run security audit" 600

# Check worker status
scripts/claude-docker status

# View findings
scripts/claude-docker findings
scripts/claude-docker findings security
```

### Analysis (Multi-Persona)

Run a comprehensive project analysis using all three specialized worker
personas in parallel:

```bash
# Analyze with default timeout (300s)
scripts/claude-docker analyze "evaluate production readiness of this project"

# Analyze with custom timeout
scripts/claude-docker analyze "audit the authentication module" 600
```

Each analysis dispatches the prompt to three workers simultaneously:

| Persona | Worker | Focus Area |
|---------|--------|------------|
| **Sentinel** | worker-1 | Security vulnerabilities, hardcoded secrets, injection flaws |
| **Reviewer** | worker-2 | Dead code, duplication, SOLID violations, complexity |
| **Profiler** | worker-3 | N+1 queries, blocking I/O, memory leaks, bundle size |

Results are collected and displayed in a categorized summary. Sessions are
automatically saved to cold storage after each analysis.

#### Interactive Analysis

When using `scripts/claude-docker claude` to enter the manager, the manager
Claude Code reads `CLAUDE.md` and can automatically orchestrate analysis
when you ask it to analyze, audit, or review code.

### Session Archive (Cold Memory)

Save and restore orchestration sessions across container restarts:

```bash
# Save current session (context + findings + task results)
scripts/claude-docker save

# List all archived sessions
scripts/claude-docker sessions

# Restore the latest session
scripts/claude-docker restore

# Restore a specific session by ID
scripts/claude-docker restore 20260328T143000Z_a1b2c3d4
```

Sessions persist in `~/.claude-state/analysis-archive/` and survive
`docker compose down -v`. Maximum 50 sessions retained; oldest pruned
automatically.

### Token Usage Reports

View aggregated token usage across all container accounts using
[ccusage](https://github.com/ryoppippi/ccusage). Runs on the host (not
inside containers) and requires Node.js/npx.

```bash
# Daily usage (default)
scripts/claude-docker usage

# Monthly or per-session breakdown
scripts/claude-docker usage monthly
scripts/claude-docker usage session

# Filter by date range
scripts/claude-docker usage daily --since 20260301 --until 20260329

# JSON output for scripting
scripts/claude-docker usage daily --json

# Per-model cost breakdown
scripts/claude-docker usage daily --breakdown
```

The command automatically detects all account state directories under
`~/.claude-state/` and combines their data into a unified report.
Containers do not need to be running.

### Advanced: Raw Compose Commands

For operations not covered by subcommands, pass arguments directly:

```bash
# Show the resolved compose configuration
scripts/claude-docker config

# Pass raw docker compose arguments
scripts/claude-docker compose exec claude-a npm install
scripts/claude-docker compose run --rm claude-a npm test
```

### Cleanup and Removal

```bash
# Stop and remove containers + named volumes (node_modules)
scripts/claude-docker down -v

# Full cleanup (containers, volumes, worktrees, state)
scripts/cleanup.sh ~/work/project

# Complete removal (everything install.sh created)
scripts/remove.sh
```

## Configuration Tiers

### Tier A -- Shared Source (default)

Both containers mount the same project directory. Simplest setup, minimum
storage. Best when one session writes and the other reads/reviews.

```bash
scripts/claude-docker up
```

### Tier B -- Git Worktree

Each container gets its own worktree for full concurrent editing safety.
No `.git/index.lock` contention.

```bash
# Create worktrees (sets PROJECT_DIR_A/B in .env)
scripts/setup-worktrees.sh ~/work/project

# Start (CLI auto-detects worktree overlay from .env)
scripts/claude-docker up
```

## Adding More Accounts

```bash
# 1. Create state directory
mkdir -p ~/.claude-state/account-c

# 2. Copy a service block in docker-compose.yml:
#    claude-b → claude-c (rename account-b → account-c, _B → _C)

# 3. Start and authenticate the new container
scripts/claude-docker up
scripts/claude-docker auth claude-c
```

Each additional container needs ~4 GB RAM.

## Compose Overrides

Override files separate platform and feature concerns from the base compose:

| File | Purpose | When to use |
|------|---------|-------------|
| `docker-compose.yml` | Base config (Tier A) | Always |
| `docker-compose.linux.yml` | UID/GID + HOME override | Linux only |
| `docker-compose.worktree.yml` | Per-container worktree paths | Tier B only |
| `docker-compose.firewall.yml` | Outbound network whitelist | Security hardening |
| `docker-compose.orchestration.yml` | Manager-worker with Redis | Multi-agent orchestration |

Combine with `-f` (or let `scripts/claude-docker` detect them automatically):

```bash
# Manual: Linux + Tier B + Firewall
docker compose \
  -f docker-compose.yml \
  -f docker-compose.linux.yml \
  -f docker-compose.worktree.yml \
  -f docker-compose.firewall.yml \
  up -d

# Equivalent via CLI wrapper (auto-detects all overlays):
scripts/claude-docker up
```

## Troubleshooting

**"Authentication expired" inside container:**

macOS:
```bash
# Re-authenticate on host first
claude auth login
# Then re-inject to containers
scripts/claude-docker auth
```

Linux/WSL2:
```bash
scripts/claude-docker exec claude-a claude auth login
```

**Permission denied on bind mount (Linux):**

```bash
# Ensure UID/GID override is active
export UID=$(id -u) GID=$(id -g)
docker compose -f docker-compose.yml -f docker-compose.linux.yml up -d
```

**Slow file operations (macOS):**

Move `node_modules` to a named volume (already configured in the default compose).
For large projects, consider [OrbStack](https://orbstack.dev) as a faster
Docker Desktop alternative.

**Slow file operations (Windows):**

Ensure `PROJECT_DIR` points to a WSL2 filesystem path (`/home/...`),
**not** an NTFS path (`/mnt/c/...`). The difference is ~27x in performance.

## Resource Requirements

| Instances | Docker RAM | Host RAM (Linux / macOS / Windows) |
|:---------:|:----------:|:----------------------------------:|
| 2 | 8 GB | 12 / 16 / 16 GB |
| 3 | 12 GB | 16 / 20 / 20 GB |
| 4 | 16 GB | 20 / 24 / 24 GB |

## Project Structure

```
claude-docker/
+-- CLAUDE.md                          Manager orchestration guide
+-- Dockerfile                         Base image (Phase 1)
+-- .dockerignore
+-- docker-compose.yml                 Base config -- Tier A
+-- docker-compose.linux.yml           Linux override
+-- docker-compose.worktree.yml        Tier B override
+-- docker-compose.firewall.yml        Firewall override
+-- docker-compose.orchestration.yml  Manager-worker orchestration
+-- .env.example                       Environment template
+-- .gitignore
+-- .gitattributes                     LF line endings
+-- scripts/
|   +-- init-firewall.sh             Outbound firewall (iptables whitelist)
|   +-- setup-worktrees.sh            Tier B worktree setup
|   +-- test-concurrent-git.sh        E2E test: Tier B concurrent git safety
|   +-- test-orchestration.sh         E2E test: orchestration manager-worker
|   +-- manager-helpers.sh             Orchestration manager helpers
|   +-- worker-server.js              Orchestration worker HTTP server
|   +-- personas.json                 Worker persona definitions
|   +-- cleanup.sh                    Full cleanup
|   +-- install.sh                    Interactive setup script
|   +-- claude-docker                  Unified CLI wrapper
|   +-- remove.sh                     Complete removal script
+-- docs/
    +-- product-requirements-document.md
    +-- software-requirements-specification.md
    +-- software-design-specification.md
    +-- architecture.md
    +-- cross-platform.md
    +-- reference/                     Platform-specific references
```

## Documentation

| Document | Purpose |
|----------|---------|
| [PRD](docs/product-requirements-document.md) | Goals, personas, milestones, success criteria |
| [SRS](docs/software-requirements-specification.md) | 43 testable specifications, verification matrix |
| [SDS](docs/software-design-specification.md) | Dockerfile, compose files, scripts, operational flows |
| [Architecture](docs/architecture.md) | Design overview, tiers, scaling, auth strategy |
| [Cross-Platform](docs/cross-platform.md) | Linux / macOS / Windows comparison and templates |

## License

[BSD 3-Clause](LICENSE)
