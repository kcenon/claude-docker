# Claude Docker

Run multiple Claude Code instances simultaneously on a single host with
isolated accounts and shared source code.

Each additional instance adds only **20-70 MB** of disk overhead (vs 4-10 GB
per VM) by sharing a single Docker image and bind-mounting the project source.

## Features

- **Multi-account isolation** -- Each container has its own credentials, settings, and history
- **Shared source code** -- Bind mount (Tier A) or git worktree (Tier B) for concurrent editing
- **Cross-platform** -- Linux, macOS, Windows (WSL2)
- **Subscription + API key** -- Host-first OAuth for Pro/Max/Team, or `ANTHROPIC_API_KEY` for Console
- **Scalable to N instances** -- Add accounts by copying a compose service block

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) 24.0+ (Linux) or [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS / Windows)
- [Node.js](https://nodejs.org/) 20+ (for host-side authentication only)
- Git

**Platform-specific:**

| Platform | Additional Requirements |
|----------|----------------------|
| Linux | UID/GID matching (`id -u`, `id -g`) |
| macOS | Docker Desktop with VirtioFS (default) |
| Windows | WSL2 with source code on WSL2 filesystem (not `/mnt/c/`) |

## Quick Start

### 1. Clone and configure

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

```bash
# Install Claude Code on the host
npm install -g @anthropic-ai/claude-code

# Create state directories
mkdir -p ~/.claude-state/account-a ~/.claude-state/account-b

# Authenticate each account (browser opens)
CLAUDE_CONFIG_DIR=~/.claude-state/account-a claude auth login
CLAUDE_CONFIG_DIR=~/.claude-state/account-b claude auth login
```

**Path B -- Console API keys:**

Add to `.env`:

```bash
CLAUDE_API_KEY_A=sk-ant-...
CLAUDE_API_KEY_B=sk-ant-...
```

### 3. Build and run

```bash
docker compose build
docker compose up -d
```

**Linux users** -- add the Linux override for UID/GID mapping:

```bash
export UID=$(id -u) GID=$(id -g)
docker compose -f docker-compose.yml -f docker-compose.linux.yml up -d
```

### 4. Install project dependencies

```bash
docker compose exec claude-a npm install
docker compose exec claude-b npm install
```

### 5. Start Claude Code

```bash
docker compose exec claude-a claude
```

In a separate terminal:

```bash
docker compose exec claude-b claude
```

## Usage

### Entering a Container

Each container runs in the background (`sleep infinity`). Use `docker compose exec`
to open an interactive session:

```bash
# Start an interactive shell
docker compose exec claude-a bash

# Start Claude Code directly
docker compose exec claude-a claude

# Start Claude Code with a specific prompt
docker compose exec claude-a claude -p "explain the authentication module"
```

### Working with Multiple Sessions

Open a separate terminal for each account:

```bash
# Terminal 1 -- Account A
docker compose exec claude-a claude

# Terminal 2 -- Account B
docker compose exec claude-b claude
```

Both sessions see the same project source at `/workspace` (Tier A) or
their own worktree (Tier B). Each session has independent conversation
history, settings, and credentials.

### Checking Authentication Status

```bash
# Verify which account is active in each container
docker compose exec claude-a claude auth status
docker compose exec claude-b claude auth status
```

### Stopping and Restarting

```bash
# Stop all containers (state is preserved on host)
docker compose down

# Restart after stop (credentials and history persist via bind mount)
docker compose up -d

# Restart a single container
docker compose restart claude-a
```

### Rebuilding the Image

When a new Claude Code version is released:

```bash
# Rebuild with latest Claude Code
docker compose build --no-cache

# Or pin a specific version
docker compose build --build-arg CLAUDE_CODE_VERSION=1.2.3

# Recreate containers with the new image
docker compose up -d --force-recreate
```

### Running Commands Inside Containers

```bash
# Run a one-off command
docker compose exec claude-a git status

# Check Node.js and Claude Code versions
docker compose exec claude-a node --version
docker compose exec claude-a claude --version

# Install additional tools (temporary, lost on recreate)
docker compose exec claude-a sudo apt-get update && sudo apt-get install -y <package>
```

### Viewing Logs

```bash
# View container logs
docker compose logs claude-a
docker compose logs claude-b

# Follow logs in real time
docker compose logs -f

# View last 50 lines
docker compose logs --tail 50 claude-a
```

### Switching Between Accounts on the Same Terminal

If you prefer using one terminal, detach and reattach:

```bash
# Start Claude Code in account A
docker compose exec claude-a claude
# (use Claude Code, then exit with /exit or Ctrl+C)

# Switch to account B
docker compose exec claude-b claude
```

### Using Git Inside Containers

Tier A (shared source) -- both containers share `.git`:

```bash
# Only run git commands from ONE container at a time to avoid lock contention
docker compose exec claude-a git add -A && git commit -m "feat: add feature"
```

Tier B (worktrees) -- each container has its own branch:

```bash
# Container A commits to branch-a
docker compose exec claude-a git add -A && git commit -m "feat: add feature"

# Container B commits to branch-b (no conflict)
docker compose exec claude-b git add -A && git commit -m "fix: resolve bug"
```

### Read-Only Mode (Code Review)

For review-only sessions where you want to prevent accidental writes:

```bash
# Override the project mount to read-only in your docker-compose.override.yml
# or pass it inline:
docker compose run --volume ${PROJECT_DIR}:/workspace:ro claude-a claude
```

Files in `/workspace` will be read-only. The container can still write to
`/home/node/.claude` (settings/history) and `/workspace/node_modules` (named volume).

### Cleanup

```bash
# Remove containers and named volumes (node_modules)
docker compose down -v

# Full cleanup (containers, volumes, worktrees, state)
scripts/cleanup.sh ~/work/project
```

## Configuration Tiers

### Tier A -- Shared Source (default)

Both containers mount the same project directory. Simplest setup, minimum
storage. Best when one session writes and the other reads/reviews.

```bash
docker compose up -d
```

### Tier B -- Git Worktree

Each container gets its own worktree for full concurrent editing safety.
No `.git/index.lock` contention.

```bash
# Create worktrees
scripts/setup-worktrees.sh ~/work/project

# Add worktree paths to .env
# PROJECT_DIR_A=~/work/project-a
# PROJECT_DIR_B=~/work/project-b

# Start with worktree override
docker compose -f docker-compose.yml -f docker-compose.worktree.yml up -d
```

## Adding More Accounts

```bash
# 1. Create state directory
mkdir -p ~/.claude-state/account-c

# 2. Authenticate (Path A)
CLAUDE_CONFIG_DIR=~/.claude-state/account-c claude auth login

# 3. Copy a service block in docker-compose.yml:
#    claude-b → claude-c (rename account-b → account-c, _B → _C)

# 4. Start the new container
docker compose up -d claude-c
docker compose exec claude-c npm install
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

Combine with `-f`:

```bash
# Linux + Tier B + Firewall
docker compose \
  -f docker-compose.yml \
  -f docker-compose.linux.yml \
  -f docker-compose.worktree.yml \
  -f docker-compose.firewall.yml \
  up -d
```

## Troubleshooting

**"Authentication expired" inside container:**

```bash
# Re-authenticate on HOST (not inside container)
CLAUDE_CONFIG_DIR=~/.claude-state/account-a claude auth login
docker compose restart claude-a
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
+-- Dockerfile                         Base image (Phase 1)
+-- .dockerignore
+-- docker-compose.yml                 Base config -- Tier A
+-- docker-compose.linux.yml           Linux override
+-- docker-compose.worktree.yml        Tier B override
+-- docker-compose.firewall.yml        Firewall override
+-- .env.example                       Environment template
+-- .gitignore
+-- .gitattributes                     LF line endings
+-- scripts/
|   +-- init-firewall.sh             Outbound firewall (iptables whitelist)
|   +-- setup-worktrees.sh            Tier B worktree setup
|   +-- test-concurrent-git.sh        E2E test: Tier B concurrent git safety
|   +-- cleanup.sh                    Full cleanup
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
