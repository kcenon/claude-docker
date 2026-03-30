# Claude Docker

Run multiple Claude Code instances simultaneously on a single host with
isolated accounts and shared source code.

Each additional instance adds only **20-70 MB** of disk overhead (vs 4-10 GB
per VM) by sharing a single Docker image and bind-mounting the project source.

## Features

- **Multi-account isolation** -- Each container has its own credentials, settings, and history
- **Shared source code** -- Bind mount (Tier A) or git worktree (Tier B) for concurrent editing
- **Cross-platform** -- Linux, macOS, Windows (WSL2)
- **Flexible authentication** -- OAuth for Pro/Max/Team subscriptions, or API key for Console
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
```

Note: On macOS, container-internal OAuth fails due to Docker network
boundary limitations. The `auth` command extracts tokens from macOS
Keychain instead.

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
compose overrides (Linux UID/GID, worktree).

### 4. Start Claude Code

```bash
# Primary account
scripts/claude-docker claude

# Second account (separate terminal)
scripts/claude-docker claude claude-b
```

## Usage

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
| **Interactive** | `claude [service]` | Start Claude Code (default: claude-a) |
| | `auth [service]` | Inject OAuth credentials from macOS Keychain |
| | `exec <service>` | Open shell in a container |
| **Usage Tracking** | `usage [type] [flags]` | Token usage report |
| **Advanced** | `config` | Show resolved compose configuration |
| | `compose ...` | Pass raw args to docker compose |

### Starting and Stopping

```bash
scripts/claude-docker up        # Start all containers
scripts/claude-docker down      # Stop (state preserved via bind mounts)
scripts/claude-docker restart   # Restart
scripts/claude-docker ps        # Check status
```

### Running Claude Code

```bash
# Start in the default container (claude-a)
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
history, settings, memory, and credentials.

### Authentication

On macOS, `scripts/claude-docker auth` extracts OAuth credentials from the
host's macOS Keychain and injects them into each container's state directory.
Host-side authentication (`claude auth login`) must be completed first.

On Linux/WSL2, authenticate directly inside containers.

```bash
# macOS: extract from Keychain -> inject to all containers
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

### Token Usage Reports

View aggregated token usage across all container accounts using
[ccusage](https://github.com/ryoppippi/ccusage). Runs on the host (not
inside containers) and requires Node.js/npx.

```bash
scripts/claude-docker usage                                  # Daily (default)
scripts/claude-docker usage monthly                          # Monthly
scripts/claude-docker usage daily --since 20260301 --json    # Date filter + JSON
```

### Rebuilding the Image

```bash
scripts/claude-docker build --no-cache                # Rebuild with latest Claude Code
scripts/claude-docker up --force-recreate             # Recreate containers
```

### Cleanup and Removal

```bash
scripts/claude-docker down -v    # Stop + remove named volumes
scripts/cleanup.sh               # Quick cleanup
scripts/remove.sh                # Complete removal
```

## Configuration Tiers

### Tier A -- Shared Source (default)

Both containers mount the same project directory. Simplest setup, minimum
storage. Best when one session writes and the other reads/reviews.

### Tier B -- Git Worktree

Each container gets its own worktree for full concurrent editing safety.
No `.git/index.lock` contention.

```bash
scripts/setup-worktrees.sh ~/work/project    # Create worktrees
scripts/claude-docker up                     # Auto-detects worktree overlay
```

## Adding More Accounts

```bash
# 1. Create state directory
mkdir -p ~/.claude-state/account-c

# 2. Copy a service block in docker-compose.yml:
#    claude-b -> claude-c (rename account-b -> account-c, _B -> _C)

# 3. Start and authenticate the new container
scripts/claude-docker up
scripts/claude-docker auth claude-c
```

Each additional container needs ~4 GB RAM.

## State and Memory Persistence

All state is preserved across container restarts via Docker volume mounts:

| State | Host Path | Container Path |
|-------|-----------|----------------|
| Claude Code config | `~/.claude-state/account-a/` | `/home/node/.claude/` |
| Credentials | `~/.claude-state/account-a/.credentials.json` | `/home/node/.claude/.credentials.json` |
| Memory | `~/.claude-state/account-a/projects/*/memory/` | `/home/node/.claude/projects/*/memory/` |
| Settings | `~/.claude-state/account-a/settings.json` | `/home/node/.claude/settings.json` |
| node_modules | Named volume `node_modules_a` | `/workspace/node_modules/` |
| Project files | `${PROJECT_DIR}` bind mount | `/workspace/` |

## Compose Overrides

| File | Purpose | When active |
|------|---------|-------------|
| `docker-compose.yml` | Base config (Tier A) | Always |
| `docker-compose.linux.yml` | UID/GID + HOME override | Linux only |
| `docker-compose.worktree.yml` | Per-container worktree paths | Tier B only |

The `scripts/claude-docker` CLI auto-detects which overlays to apply.

## Troubleshooting

**"Authentication expired" inside container:**

macOS:
```bash
claude auth login              # Re-authenticate on host
scripts/claude-docker auth     # Re-inject to containers
```

Linux/WSL2:
```bash
scripts/claude-docker exec claude-a claude auth login
```

**Permission denied on bind mount (Linux):**

```bash
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
| 2 | 8 GB | 12 / 12 / 12 GB |
| 3 | 12 GB | 16 / 16 / 16 GB |
| 4 | 16 GB | 20 / 20 / 20 GB |

## Project Structure

```
claude-docker/
+-- .dockerignore                      Docker build context exclusions
+-- Dockerfile                         Base image
+-- docker-compose.yml                 Base config (Tier A)
+-- docker-compose.linux.yml           Linux override
+-- docker-compose.worktree.yml        Tier B override
+-- .env.example                       Environment template
+-- .gitignore
+-- .gitattributes                     LF line endings
+-- LICENSE                            BSD 3-Clause
+-- scripts/
    +-- claude-docker                  CLI wrapper
    +-- install.sh                     Interactive setup
    +-- remove.sh                      Complete removal
    +-- cleanup.sh                     Quick cleanup
    +-- setup-worktrees.sh             Tier B worktree setup
    +-- test-concurrent-git.sh         E2E test: Tier B concurrent git
```

## License

[BSD 3-Clause](LICENSE)
