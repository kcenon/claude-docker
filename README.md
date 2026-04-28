# Claude Docker

Run multiple Claude Code instances simultaneously on a single host with
isolated accounts and shared source code.

Each additional instance adds only **20-70 MB** of disk overhead (vs 4-10 GB
per VM) by sharing a single Docker image and bind-mounting the project source.

## Features

- **Multi-account isolation** -- Each container has its own credentials, settings, and history
- **Shared source code** -- Bind mount (Tier A) or git worktree (Tier B) for concurrent editing
- **Cross-platform** -- Linux, macOS, Windows (WSL2 or native PowerShell)
- **Flexible authentication** -- OAuth for Pro/Max/Team subscriptions, or API key for Console
- **Scalable to N instances** -- Add accounts by copying a compose service block (up to 702 via Excel-style suffixes)
- **TUI dashboard** -- A Bubble Tea-based terminal UI (`scripts/claude-docker tui`) for live multi-account monitoring; auto-downloads a signed prebuilt binary from GitHub Releases or builds from source when Go 1.21+ is available

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) 24.0+ (Linux) or [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS / Windows)
- [Node.js](https://nodejs.org/) 20+ (optional -- needed for `usage` subcommand token reports)
- Git

**Platform-specific:**

| Platform | Additional Requirements |
|----------|----------------------|
| Linux | UID/GID matching (`id -u`, `id -g`) |
| macOS | Docker Desktop with VirtioFS (default) |
| Windows (WSL2) | Source code on WSL2 filesystem (not `/mnt/c/`) |
| Windows (Native) | Docker Desktop with WSL2 backend, PowerShell 5.1+ |

## Platform Support

claude-docker ships parallel bash and PowerShell implementations. Use the
installer and CLI wrapper that match your host platform:

| Platform | Installer | CLI Wrapper | Docker Backend | Notes |
|----------|-----------|-------------|----------------|-------|
| Linux (native) | `scripts/install.sh` | `scripts/claude-docker` | native Docker Engine | UID/GID auto-detected; uses `docker-compose.linux.yml` overlay |
| macOS | `scripts/install.sh` | `scripts/claude-docker` | Docker Desktop (VirtioFS recommended) | OAuth tokens live in Keychain — see Troubleshooting |
| Windows (native) | `scripts/install.ps1` | `scripts/claude-docker.ps1` or `.cmd` | Docker Desktop (WSL2 backend) | Run from PowerShell 5.1+ or PowerShell 7 |
| Windows (WSL2) | `scripts/install.sh` (**inside** WSL2) | `scripts/claude-docker` | Docker Desktop (WSL2 integration) | Keep project files inside the WSL2 filesystem for performance |

**Do not cross platforms.** Running `install.sh` from a native Windows shell
(Git Bash / MSYS / Cygwin) or `install.ps1` from PowerShell 7 on Linux/macOS
will fail fast with a clear error pointing at the correct script.

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
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
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

### 2. Authenticate

Choose **OAuth** (subscription) or **API key** (Anthropic Console):

| You have... | Host OS | Use |
|-------------|---------|-----|
| Claude.ai Pro / Max / Team subscription | Linux / WSL2 | **OAuth** |
| Claude.ai Pro / Max / Team subscription | macOS | **OAuth** inside container; fall back to API key if Keychain errors appear |
| Anthropic Console account only | any | **API key** |
| Mix of both | any | **Per-container**: set `CLAUDE_API_KEY_<LETTER>` only for API-key slots — others fall back to OAuth |

**OAuth** — authenticate inside each container after starting:

```bash
scripts/claude-docker claude claude-a
# Inside container: claude auth login
```

Container-internal OAuth may fail on macOS due to Docker network
boundary limitations. If it does, switch the affected account to API key.

**API key** — add to `.env`:

```bash
CLAUDE_API_KEY_A=sk-ant-...
CLAUDE_API_KEY_B=sk-ant-...
```

Re-run `scripts/generate-compose.sh` after editing so the generator emits
`ANTHROPIC_API_KEY` only for slots that actually have a key (see
[Switching between OAuth and API key](#authentication) below).

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
| | `exec <service>` | Open shell in a container |
| **Usage Tracking** | `usage [type] [flags]` | Token usage report |
| **Dashboard** | `tui` (alias `dashboard`) | Launch multi-account TUI; auto-downloads a prebuilt binary if missing |
| | `build-tui` | Rebuild the TUI dashboard binary from source (requires Go 1.21+) |
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

Both sessions see the same project source at `${PROJECT_DIR}` (Tier A) or
their own worktree (Tier B). Each session has independent conversation
history, settings, memory, and credentials.

### Authentication

Authenticate directly inside each container. Each container keeps its own
credentials in its bind-mounted state directory, so you run this once per
account.

```bash
# Authenticate inside a specific container
scripts/claude-docker exec claude-a claude auth login

# Check status in any container
scripts/claude-docker exec claude-a claude auth status
```

If container-internal OAuth fails on macOS due to Docker network boundary
limitations, switch to API keys in `.env`.

> **Switching between OAuth and API key**: After editing `CLAUDE_API_KEY_*`
> in `.env`, re-run `scripts/generate-compose.sh` (or `.ps1`) and
> `docker compose up -d` so the generated compose files reflect the new
> state. `ANTHROPIC_API_KEY` is only injected into a container when the
> matching `CLAUDE_API_KEY_<LETTER>` is set at generate time — emitting
> it with an empty string would otherwise make the SDK ignore the
> `.credentials.json` from OAuth.

**GitHub CLI (`gh`)** is automatically available inside containers. The host's
`~/.config/gh/` is bind-mounted read-only, so `gh` commands use the host's
GitHub session without separate authentication.

```bash
# Verify gh auth inside container
scripts/claude-docker exec claude-a gh auth status

# Use gh normally
scripts/claude-docker exec claude-a gh pr list
```

### Shared Configuration (claude-config)

If you use [claude-config](https://github.com/kcenon/claude-config) to manage global
Claude Code settings, containers automatically inherit your host configuration.

> **Prerequisite**: Run claude-config's installer (`scripts/install.sh` /
> `install.ps1`, or `bootstrap.sh`) on the host **before** starting any
> claude-docker container. Containers are pure consumers — they do not run
> the installer. Without a populated `~/.claude/` tree on the host, the
> entrypoint symlinks below resolve to missing targets and Claude Code
> falls back to its built-in defaults.
>
> **Compatibility**: Tested against claude-config v1.10+. The contract
> claude-docker relies on (directory layout, hook command grammar,
> dual-variant pairing, full-suite probe, CRLF normalization) is documented
> in [`docs/CLAUDE_DOCKER_CONTRACT.md`](https://github.com/kcenon/claude-config/blob/develop/docs/CLAUDE_DOCKER_CONTRACT.md)
> in the claude-config repo. Older claude-config installs may work but are
> not gate-tested.

The host's `~/.claude/` is mounted read-only at `/home/node/.claude-host/` inside
each container. On startup, the entrypoint script creates symlinks from the
account state directory to the shared config:

| Config | Host Path | Symlinked From |
|--------|-----------|---------------|
| Hooks | `~/.claude/hooks/` | `/home/node/.claude/hooks` -> `.claude-host/hooks` |
| Skills | `~/.claude/skills/` | `/home/node/.claude/skills` -> `.claude-host/skills` |
| Commands | `~/.claude/commands/` | `/home/node/.claude/commands` -> `.claude-host/commands` |
| Scripts | `~/.claude/scripts/` | `/home/node/.claude/scripts` -> `.claude-host/scripts` |
| Statusline | `~/.claude/ccstatusline/` | `/home/node/.claude/ccstatusline` -> `.claude-host/ccstatusline` |
| Global instructions | `~/.claude/CLAUDE.md` | `/home/node/.claude/CLAUDE.md` -> `.claude-host/CLAUDE.md` |
| Commit settings | `~/.claude/commit-settings.md` | `/home/node/.claude/commit-settings.md` -> `.claude-host/commit-settings.md` |
| Hook config | `~/.claude/settings.json` | `/home/node/.claude/settings.json` -> `.claude-host/settings.json` |
| Full-suite probe | `~/.claude/.full-suite-active` (optional) | `/home/node/.claude/.full-suite-active` -> `.claude-host/.full-suite-active` |

The host config is read-only. Account-specific state (credentials, memory,
sessions) remains writable and per-container. Symlinks are created when the
target does not exist or is an empty file, so per-account overrides with
real content are preserved.

### Container-side settings transformation

The entrypoint does not use your host `settings.json` verbatim. It rewrites a
working copy at `~/.claude/settings.json` (inside the container) before Claude
Code starts. Two of those transforms are load-bearing but easy to miss from
the code alone:

**1. `sandbox.enabled` is forced to `false`.**

The host sandbox gates filesystem and network access on the host. Inside a
container it would re-confine already-confined code and, more importantly,
break hooks and skills that `exec` into `/usr/bin`. The entrypoint relies on
the container itself being the isolation boundary.

This assumption holds for the **default** Docker isolation (cgroups +
namespaces + read-only bind mounts). It does **not** hold when:

- the container runs with `--privileged`,
- Docker-in-Docker is used so nested containers share the parent's kernel
  namespace,
- a skill uses `docker run` on the host socket to spawn a sibling container.

If you run claude-docker in any of those modes you lose the host sandbox
without warning. Either keep the outer Docker isolation strict or edit the
entrypoint to leave `sandbox.enabled` untouched for that profile.

**2. PowerShell hook commands are rewritten to bash.**

Host `settings.json` entries that invoke `pwsh -NoProfile -File ...` are
transformed so they work inside the Linux-native container image. This is
best-effort: trivial single-call hooks are rewritten cleanly, but the
following patterns fail **silently** (transformed command is produced but
never fires):

| Pattern | Example | Status |
|---------|---------|--------|
| `pwsh -NoProfile -File ./foo.ps1` | top-level script | supported |
| Heredoc / multi-line `-Command` | `pwsh -c @"..."@` | not supported |
| `$env:VAR` expansion | `pwsh -c '$env:FOO'` | not supported |
| Quoted paths with spaces | `pwsh -File "C:\\Program Files\\..."` | not supported |
| `Join-Path` outside the statusLine slot | inside a hook array | not supported |

If a hook works on the host but never fires in the container, check whether
its command matches one of the unsupported patterns above. The workaround is
to ship a Linux-native shell alternative via `CLAUDE_CONFIG_SOURCE` (which
bypasses the transform entirely — the container reads the config tree you
point at without rewriting it).

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

### Multi-account dashboard (TUI)

A Bubble Tea-based terminal dashboard surfaces per-account container state,
authentication status, recent activity, and live token usage in one view.

```bash
scripts/claude-docker tui            # Launch dashboard (auto-fetches binary if missing)
scripts/claude-docker dashboard      # Alias of tui
scripts/claude-docker build-tui      # Rebuild from source (Go 1.21+)
```

`tui` first looks for `tui/claude-docker-tui` in the project tree. If it is
missing, the wrapper calls `download_tui_release` (`scripts/lib/tui-release.sh`)
to fetch the matching `claude-docker-tui-<os>-<arch>` asset from the latest
GitHub Release, verifies its `.sha256`, and installs it in place. If neither
the binary nor `curl` is available, the command falls back to a clear error
that points operators to `build-tui`. PowerShell users can run
`.\scripts\claude-docker.ps1 tui` for the same flow.

### Rebuilding the Image

```bash
scripts/claude-docker build --no-cache                # Rebuild with latest Claude Code
scripts/claude-docker up --force-recreate             # Recreate containers
```

### Cleanup and Removal

```bash
scripts/claude-docker down -v    # Stop + remove named volumes
scripts/cleanup.sh               # Quick cleanup (bash)
scripts/remove.sh                # Complete removal (bash)

# Windows PowerShell equivalents
.\scripts\cleanup.ps1            # Quick cleanup
.\scripts\remove.ps1             # Complete removal
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

## Scaling Accounts

Use the `scale` command to add or remove accounts dynamically:

```bash
# Scale to 4 accounts (claude-a through claude-d)
scripts/claude-docker scale 4

# Scale back to 2
scripts/claude-docker scale 2
```

The `scale` command automatically:
1. Updates `NUM_ACCOUNTS` in `.env`
2. Creates new state directories (when scaling up)
3. Regenerates Docker Compose files
4. Restarts containers if running

Each additional container needs ~4 GB RAM (2 GB reserved, 4 GB limit).

Account names follow Excel-style letters: 1→`a`, 26→`z`, 27→`aa`, 52→`az`,
53→`ba`, ..., 702→`zz`. You can set `NUM_ACCOUNTS` up to 702, though host
memory is usually the binding constraint well before then.

On Windows (PowerShell):
```powershell
.\scripts\claude-docker.ps1 scale 4
```

## State and Memory Persistence

All state is preserved across container restarts via Docker volume mounts:

| State | Host Path | Container Path | Mode |
|-------|-----------|----------------|------|
| Account state | `~/.claude-state/account-a/` | `/home/node/.claude/` | Read-write |
| Credentials | `~/.claude-state/account-a/.credentials.json` | `/home/node/.claude/.credentials.json` | Read-write |
| Memory | `~/.claude-state/account-a/projects/*/memory/` | `/home/node/.claude/projects/*/memory/` | Read-write |
| Host config (claude-config) | `~/.claude/` | `/home/node/.claude-host/` (symlinked) | Read-only |
| GitHub CLI auth | `~/.config/gh/` | `/home/node/.config/gh/` | Read-only |
| node_modules | Named volume `node_modules_a` | `${PROJECT_DIR}/node_modules/` | Read-write |
| Project files | `${PROJECT_DIR}` bind mount | `${PROJECT_DIR}/` (mirrors host path) | Read-write |

## Compose Overrides

All compose files are **generated** by `scripts/generate-compose.sh` (or `.ps1`)
based on `NUM_ACCOUNTS` in `.env`. Do not edit them manually.

| File | Purpose | When active |
|------|---------|-------------|
| `docker-compose.yml` | Base config (Tier A), incl. `user: ${UID:-1000}:${GID:-1000}` and `HOME=/home/node` | Always |
| `docker-compose.linux.yml` | Legacy UID/GID + HOME override (kept for backward compat; base already carries it) | Optional |
| `docker-compose.worktree.yml` | Per-container worktree paths | Tier B only |

Set `UID` / `GID` in `.env` (or export them in the shell before running
`docker compose up`) to match the host user that owns `~/.claude-state/`.
Without these, bind-mounted paths such as `~/.claude-state/account-a/` are
not writable from inside the container, producing errors like
`hook: /home/node/.claude/hooks/<name>.sh: not found` (failure to stat
under non-matching UID) and Bash tool failures caused by the harness
being unable to create `session-env/` subdirectories.

To regenerate after editing `.env`:
```bash
scripts/generate-compose.sh
```

The `scripts/claude-docker` CLI auto-detects which overlays to apply.

## Timezone

Containers match the host's IANA timezone so `date`, Node.js `Date` objects,
and hook timestamps render the same wall-clock time the host shows.

`scripts/install.sh` / `install.ps1` auto-detect the host zone and write
`TZ=<IANA>` to `.env`. Compose files forward the value as `TZ=${TZ:-UTC}`,
so leaving `TZ` unset keeps containers on UTC.

To change zones on an existing install, append or edit the line in `.env`
and restart:

```bash
echo 'TZ=Asia/Seoul' >> .env
scripts/claude-docker down && scripts/claude-docker up
```

## Troubleshooting

**"Authentication expired" inside container:**

```bash
scripts/claude-docker exec claude-a claude auth login
```

**Permission denied on bind mount (or `hook: ... not found`, `session-env` write failures):**

Host UID/GID must match what owns `~/.claude-state/`. Add them to `.env`
and restart — the base compose now reads these directly, so no extra
overlay is required.

```bash
cat >> .env <<EOF
UID=$(id -u)
GID=$(id -g)
EOF
scripts/claude-docker down && scripts/claude-docker up
```

On Linux the legacy overlay still works and is equivalent:

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

**CRLF errors in container (`$'\r': command not found`):**

This happens when a Windows editor saved a `.sh` file with CRLF line endings,
overriding the `.gitattributes eol=lf` rule. Fix the underlying cause first
(`git config core.autocrlf input`, add/fix `.gitattributes`, or have your
editor save as LF for `.sh` files).

If you cannot fix the host setup and need the container to auto-patch bind-
mounted scripts, set `CLAUDE_NORMALIZE_CRLF=1` in `.env` and restart. This
reinstates the former entrypoint sweep under `/project` with a bounded depth.
**Warning**: this modifies host files via the bind mount, which can appear
as unexpected `git status` diffs and conflict with host-side editors. It's
off by default for that reason.

**`${HOME}` not expanding in docker-compose.yml (Windows):**

The PowerShell installer writes `HOME` explicitly to `.env` at install time.
If you edit `.env` manually, make sure the value uses forward slashes
(`HOME=C:/Users/you`) so Docker Compose parses the path correctly.

**`.env.tmp` files left over after running `install.sh`:**

This was fixed by migrating the installer from BSD/GNU `sed -i` to cross-
platform `perl -i -pe`. If you still see stale `.env.tmp` files from a
pre-fix install, delete them manually — they are not consumed by the
current installer.

**Stray `.env.backup.*` files from pre-rotation installs:**

Current `install.sh` / `install.ps1` keep at most three `.env.backup.*`
files and set them to `chmod 600` (owner-only) immediately after creation.
If your working tree has leftover backups from before this change — often
world-readable because they inherited umask — review and delete them:

```bash
ls -la .env.backup.*
rm .env.backup.*   # or keep the newest by hand
```

**Container memory limit vs reservation:**

`docker-compose.yml` sets `limits.memory: 4G` (hard cap — Docker will refuse
to let the container exceed this) and `reservations.memory: 2G` (soft
guarantee — Docker ensures at least this much is available). The Resource
Requirements section below uses `limits` to size Docker Desktop memory;
`reservations` matters only when multiple containers compete for memory.

## Bumping the Base Image

The `Dockerfile` pins the Node base image to a specific patch version **and
content digest** so rebuilds are byte-for-byte reproducible and any upstream
repush of the tag is caught at build time as a digest mismatch. Inside the
image, **Claude Code is installed via Anthropic's official native installer**
(`https://claude.ai/install.sh`), not via npm. The installer places `claude`
at `/home/node/.local/bin/claude`, so `/doctor` no longer warns about
"leftover npm global install". Pin a specific Claude Code release with the
`CLAUDE_CODE_VERSION` build arg (read from `.env`); leave it empty for
`latest`. To bump:

1. Check <https://hub.docker.com/_/node/tags?name=slim> for the latest 20.x LTS
2. Capture the digest on a trusted host (**required**, not optional):
   ```bash
   docker pull node:<new-version>-slim
   docker inspect --format='{{index .RepoDigests 0}}' node:<new-version>-slim
   ```
3. Update the `FROM` line in `Dockerfile` — **both** the tag and the
   `@sha256:` suffix must be updated together
4. Update `VERSION` at the repo root to today's date
   (e.g. `2026.04.17`). Both `scripts/generate-compose.sh`/`.ps1` and
   `scripts/install.sh`/`.ps1` read this file, so regenerating compose
   or running `install` picks up the new default automatically. Do not
   hand-edit the generated `docker-compose.yml` — its header forbids it
5. Rebuild everything from scratch: `docker compose build --no-cache`
6. Check the build log for the `[build] GitHub CLI keyring fingerprint:` line
   and confirm it matches prior builds (unexpected changes may indicate an
   upstream keyring swap)

## Resource Requirements

Each container **defaults** to a 4 GB memory limit (2 GB reserved), 2 CPU limit
(1 CPU reserved). Override per installation in `.env`:

```env
CONTAINER_CPU_LIMIT=2
CONTAINER_CPU_RESERVATION=1
CONTAINER_MEM_LIMIT=4G
CONTAINER_MEM_RESERVATION=2G
```

Re-run `scripts/generate-compose.sh` (or `.ps1`) after changing these so the
generated compose files pick up the new values. The table below assumes
defaults. Docker RAM is the recommended Docker Desktop memory allocation to
allow all containers to run at peak load.

| Instances | Docker RAM (recommended) | Host RAM (Linux / macOS / Windows) |
|:---------:|:------------------------:|:----------------------------------:|
| 2 | 8 GB | 12 / 12 / 12 GB |
| 3 | 12 GB | 16 / 16 / 16 GB |
| 4 | 16 GB | 20 / 20 / 20 GB |
| 5 | 20 GB | 24 / 24 / 24 GB |
| 6+ | N x 4 GB | (N x 4) + 4 GB |

## Project Structure

```
claude-docker/
+-- .dockerignore                      Docker build context exclusions
+-- Dockerfile                         Base image (Claude Code installed via Anthropic native installer)
+-- VERSION                            Release tag consumed by docker-compose IMAGE_TAG
+-- docker-compose.yml                 Generated: base config (Tier A)
+-- docker-compose.linux.yml           Generated: Linux override
+-- docker-compose.worktree.yml        Generated: Tier B override
+-- .env.example                       Environment template
+-- .gitignore
+-- .gitattributes                     LF line endings
+-- LICENSE                            BSD 3-Clause
+-- README.md                          This file
+-- scripts/
|   +-- claude-docker                  CLI wrapper (bash)
|   +-- claude-docker.ps1              CLI wrapper (PowerShell)
|   +-- claude-docker.cmd              CLI wrapper (cmd.exe batch)
|   +-- ClaudeDocker.psm1              Shared PowerShell module
|   +-- generate-compose.sh            Compose file generator (bash)
|   +-- generate-compose.ps1           Compose file generator (PowerShell)
|   +-- entrypoint.sh                  Container init (config symlinks, full-suite probe forwarding)
|   +-- install.sh                     Interactive setup (bash)
|   +-- install.ps1                    Interactive setup (PowerShell)
|   +-- remove.sh                      Complete removal (bash)
|   +-- remove.ps1                     Complete removal (PowerShell)
|   +-- cleanup.sh                     Quick cleanup (bash)
|   +-- cleanup.ps1                    Quick cleanup (PowerShell)
|   +-- setup-worktrees.sh             Tier B worktree setup (bash)
|   +-- setup-worktrees.ps1            Tier B worktree setup (PowerShell)
|   +-- test-concurrent-git.sh         E2E test (bash)
|   +-- test-concurrent-git.ps1        E2E test (PowerShell)
|   +-- test-entrypoint-settings.sh    Entrypoint settings normalization test (bash)
|   +-- lib/
|       +-- tui-release.sh             Download + SHA256-verify prebuilt TUI binary (bash)
|       +-- tui-release.ps1            Same, PowerShell port
|       +-- parse_env.sh               Shared .env parser (bash)
|       +-- index.sh / index.ps1       Excel-style account index helpers
+-- tui/                               Bubble Tea multi-account dashboard (Go module)
|   +-- main.go
|   +-- Makefile
|   +-- go.mod / go.sum
|   +-- internal/                      account, auth, config, docker, ui, usage subpackages
+-- tests/                             Hadolint, parse_env, ccstatusline regression tests
    +-- env_fixtures/
```

## License

[BSD 3-Clause](LICENSE)
