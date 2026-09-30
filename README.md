# Claude Docker

Status: active · Version [`2026.09.28`](VERSION) · Base image `node:26.10.0-slim` (Debian trixie)

Run multiple isolated accounts for Claude Code, OpenAI Codex CLI, or Google
Gemini CLI on a single host while sharing source code and one Docker image.

All accounts run from one image. In the default shared mode they also
bind-mount one project checkout, so adding an account adds a state directory
and a `node_modules` volume rather than another image or source copy.

## Features

- **Multi-runtime support** -- Select Claude Code, Codex CLI, or Gemini CLI for the generated stack
- **Multi-account isolation** -- Each container has its own credentials, settings, and history
- **Shared source code** -- Bind mount (Tier A) or git worktree (Tier B) for concurrent editing
- **Cross-platform** -- Linux, macOS, Windows (WSL2 or native PowerShell)
- **Flexible authentication** -- Runtime-specific OAuth or API keys, plus shared or per-container GitHub identities
- **Scalable to N instances** -- Use `scale` or `NUM_ACCOUNTS`; generators support up to 702 Excel-style suffixes
- **TUI dashboard** -- A Bubble Tea-based terminal UI (`scripts/claude-docker tui`) for live multi-account monitoring; build from source with Go 1.24+

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) (Linux) or [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS / Windows)
- [Docker Compose](https://docs.docker.com/compose/) v2.24.4+ -- the worktree overlay uses the `!override` merge tag, without which the shared project mount leaks into every worktree container (see [`docs/ISOLATION.md`](docs/ISOLATION.md))
- [Node.js](https://nodejs.org/) 20+ on the host (optional -- needed for `usage` subcommand token reports)
- [Go](https://go.dev/dl/) 1.24+ (required for `build-tui`; optional for other CLI commands)
- Git
- Python 3.9+ (standard library only; shared host validation and lifecycle transactions)

**Platform-specific:**

| Platform | Additional Requirements |
|----------|----------------------|
| Linux | UID/GID matching (`id -u`, `id -g`) |
| macOS | Docker Desktop with VirtioFS (default) |
| Windows (WSL2) | Source code on WSL2 filesystem (not `/mnt/c/`) |
| Windows (Native) | Docker Desktop with WSL2 backend, PowerShell 7 (`winget install --id Microsoft.PowerShell`) |

## Platform Support

claude-docker ships parallel bash and PowerShell implementations. Use the
installer and CLI wrapper that match your host platform:

| Platform | Installer | CLI Wrapper | Docker Backend | Notes |
|----------|-----------|-------------|----------------|-------|
| Linux (native) | `scripts/install.sh` | `scripts/claude-docker` | native Docker Engine | UID/GID auto-detected; uses `docker-compose.linux.yml` overlay |
| macOS | `scripts/install.sh` | `scripts/claude-docker` | Docker Desktop (VirtioFS recommended) | OAuth tokens live in Keychain — see [Authentication](docs/AUTHENTICATION.md#choosing-oauth-or-an-api-key) |
| Windows (native) | `scripts/install.ps1` | `scripts/claude-docker.ps1` or `.cmd` | Docker Desktop (WSL2 backend) | Requires PowerShell 7 (`pwsh`); Windows PowerShell 5.1 is not supported |
| Windows (WSL2) | `scripts/install.sh` (**inside** WSL2) | `scripts/claude-docker` | Docker Desktop (WSL2 integration) | Keep project files inside the WSL2 filesystem for performance |

**Do not cross platforms.** Every bash entry point with a PowerShell
counterpart, and every PowerShell entry point with a bash counterpart, validates
the host platform before doing any work. Running one on the wrong platform
fails fast with an error naming the counterpart to use instead.
`tests/test_windows_platform_guard.sh` and
`tests/test_powershell_platform_guard.ps1` check every such entry point.

## Quick Start

### Option A: Interactive Setup (Recommended)

```bash
git clone <repo-url> claude-docker
cd claude-docker
scripts/install.sh
```

The script guides you through platform detection, authentication, source sharing,
and container setup via interactive Q&A.

### Option A-2: Interactive Setup on Windows (PowerShell)

```powershell
git clone <repo-url> claude-docker
cd claude-docker
.\scripts\install.ps1
# or from cmd.exe:
pwsh -ExecutionPolicy Bypass -File scripts\install.ps1
```

Same interactive Q&A as the bash version, adapted for Windows.
Uses `winget` for auto-installing prerequisites (Docker Desktop, Git, Node.js).

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

#### 2. Authenticate

Use **OAuth** with a Claude.ai subscription or an **API key** from the
Anthropic Console, chosen per container. For OAuth, start the container and
run `claude auth login` inside it; for an API key, set
`CLAUDE_API_KEY_<LETTER>` in `.env` and re-run `scripts/generate-compose.sh`.
[Authentication](docs/AUTHENTICATION.md) has the decision table and the macOS
OAuth caveat.

#### 3. Build and run

```bash
scripts/claude-docker build
scripts/claude-docker up
```

The CLI wrapper auto-detects your platform and applies the correct
compose overrides (Linux UID/GID, worktree).

#### 4. Start Claude Code

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
| | `update` | Attempt a GitHub credential refresh, rebuild without cache, and recreate containers |
| | `ps` | Show container status |
| | `logs` | Follow container logs |
| **Interactive** | `claude [service]` | Start Claude Code (default: claude-a) |
| | `codex [service]` | Start OpenAI Codex CLI (default: codex-a) |
| | `gemini [service]` | Start Google Gemini CLI (default: gemini-a) |
| | `exec <service> [command...]` | Open a shell or run a command in a container |
| | `gh-auth [target]` | Import shared or per-account host `gh` credentials |
| **Usage Tracking** | `usage [type] [flags]` | Token usage report |
| **Dashboard** | `build-tui` | Build the TUI from source; requires Go 1.24+ |
| | `tui` (alias `dashboard`) | Launch the dashboard built by `build-tui` |
| **Scaling** | `scale <N>` / `recover` | Stage, validate and apply account changes; recover an interrupted transaction |
| **Advanced** | `config` | Show resolved compose configuration |
| | `compose ...` | Pass raw args to docker compose |

Each session has independent conversation history, settings, memory, and
credentials, and sees the same project source at `${PROJECT_DIR}` (Tier A) or
its own worktree (Tier B). [Usage](docs/USAGE.md) covers running commands and
git inside containers, token usage reports, the dashboard, rebuilding, and
cleanup.

### Runtimes

Claude Code is the default runtime. For Codex CLI or Gemini CLI, set
`AGENT_RUNTIME=codex` or `AGENT_RUNTIME=gemini` in `.env`, regenerate the
compose files and recreate the containers; services are then named `codex-a`,
`gemini-a` and so on. [Runtimes](docs/RUNTIMES.md) covers state paths,
authentication, Gemini's verification coverage, and adding a runtime.

### Authentication

Each container keeps its own credentials in its state directory, so you
authenticate once per account:
`scripts/claude-docker exec claude-a claude auth login`. The GitHub CLI is
available in every container, with one shared token by default or one
identity per container under `GH_AUTH_MODE=per-account`; see
[Authentication](docs/AUTHENTICATION.md).

### Shared configuration (claude-config)

If you manage Claude Code settings with
[claude-config](https://github.com/kcenon/claude-config), run its installer on
the host before starting any container. The host's `~/.claude/` is mounted
read-only, and startup copies or links its hooks, scripts, skills, commands
and settings into each account. See [Host configuration](docs/HOST_CONFIG.md).

### Container-side settings transformation

The entrypoint does not use `settings.json` verbatim. In shared/worktree mode
it turns `sandbox.enabled` off and removes wildcard `permissions.deny` rules
for the file tools, relying on the container boundary and on claude-config's
`sensitive-file-guard.sh` hook instead; it also rewrites PowerShell hooks for
Linux. Degraded settings stop the container unless
`CLAUDE_ALLOW_DEGRADED_SETTINGS=1`, and isolated mode keeps sandbox and
permission-deny settings. The rules, and the Docker profiles that break the
container-boundary assumption, are in
[Host configuration](docs/HOST_CONFIG.md#container-side-settings-transformation).

## Configuration Tiers

`ISOLATION_MODE` in `.env` declares which tier the accounts run under. Shared is
the default, so an install that never sets the key behaves exactly as before.
Full trust boundaries, non-goals, and what each tier does **not** protect
against are in [`docs/ISOLATION.md`](docs/ISOLATION.md).

| `ISOLATION_MODE` | Tier | Boundary |
|---|---|---|
| `shared` (default) | Tier A | One read-write project mount shared by every account. |
| `worktree` | Tier B | Each account mounts only its own worktree. Git metadata stays shared. |
| `isolated` | Tier C | Each account mounts its own independent clone, with its own git metadata and no shared host configuration, under a hardened container profile. No shared GitHub credential, and one bridge network per account. |

An unrecognized value is refused, and so is a mode whose per-account workspace
paths are missing. The active mode and its boundary are printed by
`claude-docker config`, by `claude-docker up`, and in the TUI.

Tier B is set up with `scripts/setup-worktrees.sh` and Tier C with
`scripts/setup-isolated.sh`; both print `.env` lines you must add. See
[setting up each mode](docs/ISOLATION.md#modes).

## Scaling Accounts

Use the `scale` command to add or remove accounts dynamically:

```bash
# Scale to 4 accounts (claude-a through claude-d)
scripts/claude-docker scale 4

# Scale back to 2
scripts/claude-docker scale 2
```

`scale` validates the staged configuration before changing `.env` or account
directories. A failed change is compensated, an interrupted one is completed
with `scripts/claude-docker recover`, and scale-down preserves account state
and volumes ([details](docs/ISOLATION.md#scaling-interruption-and-migration)).

Account names follow Excel-style letters: 1→`a`, 26→`z`, 27→`aa`, 52→`az`,
53→`ba`, ..., 702→`zz`. Accepted ranges are:

| Operation | Account count |
|-----------|---------------|
| `scripts/claude-docker scale <N>` | 1–702 |
| `scripts/claude-docker.ps1 scale <N>` | 1–702 |
| `scripts/generate-compose.sh` (`NUM_ACCOUNTS`) | 1–702 |
| `scripts/generate-compose.ps1` (`NUM_ACCOUNTS`) | 1–702 |

These are configuration limits; usable account counts depend on available
host resources and the configured per-account budgets.

On Windows (PowerShell):
```powershell
.\scripts\claude-docker.ps1 scale 4
```

## State and Memory Persistence

Credentials, sessions, logs and history persist per account in
`~/.claude-state/account-<x>/` (`~/.codex-state/`, `~/.gemini-state/` for the
other runtimes). **The read-only host config mount is the whole directory**:
in `shared` and `worktree` mode every account container can read the host's
runtime credential file and session transcripts, and so each other's. Only
`ISOLATION_MODE=isolated` removes that mount; see
[Compose files and state](docs/COMPOSE.md#state-and-memory-persistence).

## Resource Requirements

Each container defaults to a 4 GB memory limit (2 GB reserved) and a 2 CPU
limit (1 CPU reserved), set by the compose generators and overridable in
`.env`. The generators derive each service's Node heap from its memory cap; a
plain `docker run` of the image does not. [Resources](docs/RESOURCES.md)
covers the overrides, the heap arithmetic, and memory per instance count.

## Documentation

| Topic | Page |
|-------|------|
| Command details: sessions, git, token reports, dashboard, rebuild, cleanup | [docs/USAGE.md](docs/USAGE.md) |
| Codex and Gemini runtimes, adding a runtime | [docs/RUNTIMES.md](docs/RUNTIMES.md) |
| OAuth or API key, GitHub CLI identities | [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md) |
| Shared configuration and container-side settings transformation | [docs/HOST_CONFIG.md](docs/HOST_CONFIG.md) |
| Isolation modes, trust boundaries, setup, scaling and migration | [docs/ISOLATION.md](docs/ISOLATION.md) |
| State and mounts, generated compose files, `NUM_ACCOUNTS`, timezone | [docs/COMPOSE.md](docs/COMPOSE.md) |
| Resource requirements and Node heap headroom | [docs/RESOURCES.md](docs/RESOURCES.md) |
| Troubleshooting | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Bumping the Base Image, the installer checksum, reproducibility | [docs/MAINTENANCE.md](docs/MAINTENANCE.md) |
| Measured performance | [docs/PERFORMANCE.md](docs/PERFORMANCE.md) |
| Repository layout | [docs/PROJECT_STRUCTURE.md](docs/PROJECT_STRUCTURE.md) |
| What this README may claim | [docs/README_POLICY.md](docs/README_POLICY.md) |
| Contributing and verification | [CONTRIBUTING.md](CONTRIBUTING.md) |

## License

[BSD 3-Clause](LICENSE)
