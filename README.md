# Claude Docker

Run multiple isolated accounts for Claude Code, OpenAI Codex CLI, or Google
Gemini CLI on a single host while sharing source code and one Docker image.

Each additional instance adds only **20-70 MB** of disk overhead (vs 4-10 GB
per VM) by sharing a single Docker image and bind-mounting the project source.

## Features

- **Multi-runtime support** -- Select Claude Code, Codex CLI, or Gemini CLI for the generated stack
- **Multi-account isolation** -- Each container has its own credentials, settings, and history
- **Shared source code** -- Bind mount (Tier A) or git worktree (Tier B) for concurrent editing
- **Cross-platform** -- Linux, macOS, Windows (WSL2 or native PowerShell)
- **Flexible authentication** -- Runtime-specific OAuth or API keys, plus shared or per-container GitHub identities
- **Scalable to N instances** -- Use `scale` or `NUM_ACCOUNTS`; generators support up to 702 Excel-style suffixes
- **TUI dashboard** -- A Bubble Tea-based terminal UI (`scripts/claude-docker tui`) for live multi-account monitoring; use a checksum-verified release binary or build from source with Go 1.24+

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) 24.0+ (Linux) or [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS / Windows)
- [Docker Compose](https://docs.docker.com/compose/) v2.24.4+ -- the worktree overlay uses the `!override` merge tag, without which the shared project mount leaks into every worktree container (see [`docs/ISOLATION.md`](docs/ISOLATION.md))
- [Node.js](https://nodejs.org/) 20+ (optional -- needed for `usage` subcommand token reports)
- [Go](https://go.dev/dl/) 1.24+ (optional -- needed only to build the TUI from source)
- Git

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
| macOS | `scripts/install.sh` | `scripts/claude-docker` | Docker Desktop (VirtioFS recommended) | OAuth tokens live in Keychain — see Troubleshooting |
| Windows (native) | `scripts/install.ps1` | `scripts/claude-docker.ps1` or `.cmd` | Docker Desktop (WSL2 backend) | Requires PowerShell 7 (`pwsh`); Windows PowerShell 5.1 is not supported |
| Windows (WSL2) | `scripts/install.sh` (**inside** WSL2) | `scripts/claude-docker` | Docker Desktop (WSL2 integration) | Keep project files inside the WSL2 filesystem for performance |

**Do not cross platforms.** Every bash entry point with a PowerShell
counterpart, and every PowerShell entry point with a bash counterpart, validates
the host platform before doing any work. Running one on the wrong platform
fails fast with an error naming the counterpart to use instead.

**Shell portability.** macOS ships bash 3.2 as `/bin/bash`, and every bash entry
point is `#!/usr/bin/env bash`, so a bash 4+ construct is not a style question
there -- it is `bad substitution` and an exited shell. Scripts under `scripts/`
and `tests/` must stay within bash 3.2: no case-modifying expansions
(`${var,,}`, `${var^^}`), no associative arrays, no `mapfile`/`readarray`, no
namerefs, no `&>>`, no `;&`/`;;&`, no `coproc`, no `wait -n`, and no
`printf '%(...)T'`. Use `printf '%s' "$v" | tr '[:upper:]' '[:lower:]'` in place
of `${v,,}`. `tests/test_bash32_portability.sh` enforces the list on every run,
and the `Bash Tests (macOS, bash 3.2)` CI job exercises a subset of the suite
under `/bin/bash` itself.

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
| **Dashboard** | `tui` (alias `dashboard`) | Launch multi-account TUI (build it first with `build-tui`) |
| | `build-tui` | Build the TUI from source; requires Go 1.24+ |
| **Scaling** | `scale <N>` | Set 1-702 accounts and regenerate Compose files |
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

### Running OpenAI Codex CLI

Codex support is opt-in. Set `AGENT_RUNTIME=codex` in `.env`, then regenerate
compose files and recreate containers:

```bash
scripts/generate-compose.sh
scripts/claude-docker up --remove-orphans
scripts/claude-docker codex
```

PowerShell users can run `.\scripts\generate-compose.ps1` and
`.\scripts\claude-docker.ps1 codex` instead.

When `AGENT_RUNTIME=codex` is active, generated services are named
`codex-a`, `codex-b`, and so on. Each account stores mutable Codex state in
`~/.codex-state/account-*/`, while host-managed Codex config is mounted
read-only from `~/.codex/` and copied or linked into `CODEX_HOME` without
importing `auth.json`, sessions, caches, or logs. Codex skills are mounted
from `${AGENTS_SKILLS_DIR}` or `~/.agents/skills`.

For API-key based Codex sessions, set per-account keys such as
`CODEX_API_KEY_A`; the generator injects `OPENAI_API_KEY` only for accounts
that have a non-empty key. The `codex` wrapper starts the CLI with
`cli_auth_credentials_store="file"` so container logins persist in the
account state bind mount.

The TUI can list and attach to Codex services. Claude-specific usage
aggregation and `scripts/claude-docker usage` remain Claude-only.

### Running Google Gemini CLI

Gemini support is opt-in. Set `AGENT_RUNTIME=gemini` in `.env`, then
regenerate compose files and recreate containers:

```bash
scripts/generate-compose.sh
scripts/claude-docker up --remove-orphans
scripts/claude-docker gemini
```

PowerShell users can run `.\scripts\generate-compose.ps1` and
`.\scripts\claude-docker.ps1 gemini` instead.

When `AGENT_RUNTIME=gemini` is active, generated services are named
`gemini-a`, `gemini-b`, and so on. Each account stores mutable Gemini state
in `~/.gemini-state/account-*/`, while host-managed Gemini config is mounted
read-only from `~/.gemini/` and linked into the container's Gemini config
directory. `settings.json`, `GEMINI.md`, `commands/`, and `extensions/` are
linked; OAuth credentials, sessions, and logs stay in the writable account
state directory.

Gemini CLI stores its user-level configuration and cached authentication under
`~/.gemini/`, with `GEMINI_CLI_HOME` selecting the parent directory. The host
OAuth cache is intentionally not linked into a container: `oauth_creds.json`,
`google_accounts.json`, sessions, and logs remain in that account's writable
`~/.gemini-state/account-*/` mount. To use **Sign in with Google**, start
Gemini inside each account container and complete the interactive flow there;
the resulting state persists for that account. See the official
[Gemini CLI authentication guide](https://geminicli.com/docs/get-started/authentication/).

For headless environments or when the browser flow cannot return to the
container, use per-account API keys such as `GEMINI_API_KEY_A`. The generator
injects `GEMINI_API_KEY` only for accounts that have a non-empty key.

The TUI can list and attach to Gemini services; usage columns show `--`.
Claude-specific usage aggregation and `scripts/claude-docker usage` remain
Claude-only.

#### Gemini verification coverage

The Gemini runtime is exercised by CI rather than resting on a one-time manual
check. What each layer proves:

| Step | Covered by | Needs a key or a terminal |
|------|------------|---------------------------|
| `generate-compose` emits a valid gemini compose file | `compose-validate (gemini)` job | no |
| `claude-docker up` brings `gemini-a` to a stable running state | `Gemini up/down smoke` job | no |
| `claude-docker gemini` resolves to `exec gemini-a gemini` | `tests/test_agent_attach_argv.sh` | no |
| the resolved binary runs inside the container | `gemini --version` step of the smoke job | no |
| the TUI discovers accounts under `~/.gemini-state/account-*` | `TestDiscoverStateDirs_GeminiRuntime` | no |
| the TUI dashboard renders those accounts on screen | Go tests in `tui/internal/ui/dashboard` | no |
| an authenticated `gemini -p` round-trip inside the container | key-gated CI check | yes, a `GEMINI_API_KEY` repository secret |

The key-gated check is inert until the repository owner configures a
`GEMINI_API_KEY` secret; without it the job emits a notice and passes, so a
green run is not by itself evidence that authenticated access works.

### Adding a runtime

The runtime registry centralizes service names, paths, environment variables,
and TUI behavior, but it is **not** a package manager. A registry entry and a
bootstrap module alone do not install a new executable in the image. Add a
runtime with this checklist:

1. **Add a complete registry entry.** Append an object under `runtimes` in
   `tui/internal/config/runtimes.json`, keyed by the runtime name, and populate
   every field used by the existing entries. Go, bash, PowerShell, and the
   container entrypoint all read this file.

   | Field group | Used for |
   |-------------|----------|
   | `binary`, `displayName`, `servicePrefix` | CLI dispatch, labels, and Compose service names |
   | `stateDir`, `containerHome`, `hostConfigMount`, `containerConfigMount` | Per-account state and host-config mounts |
   | `configDirEnv`, `configDirEnvValue`, `configSourceEnv` | Runtime-specific configuration discovery |
   | `apiKeyVarPrefix`, `sdkApiKeyVar` | Per-account API-key mapping |
   | `buildArg` | Build argument emitted by the Compose generators; the Dockerfile must also declare and use it |
   | `bootstrapModule` | Module sourced by `entrypoint.sh` |
   | `skipPermissionsFlag`, `extraRunArgs`, `supportsUsage`, `mountsAgentsSkills` | CLI and TUI capabilities |
   | `credentialFiles`, `oauthCredentialFile` | Permission hardening and authentication detection |

   `installMethod` is descriptive metadata today; no code dynamically installs
   a package from this value.

2. **Install the runtime in `Dockerfile`.** Add the package or native installer
   that provides the registry's `binary`. If the runtime supports a version
   pin, declare and consume the same argument named by `buildArg`.

3. **Add a bootstrap module.** Create `scripts/lib/bootstrap-<runtime>.sh`
   matching `bootstrapModule`. It must expose `runtime_bootstrap`; shared
   copy/link helpers live in `scripts/lib/bootstrap-common.sh`.

4. **Audit installer and authentication assumptions.** Registry-driven service
   naming, Compose generation, state creation, removal, and cleanup work
   automatically. The installers still include Claude-specific version/config
   prompts and verify authentication with `<binary> auth status`; add explicit
   handling when the new CLI uses a different contract.

5. **Add verification and documentation.** At minimum, add a Compose fixture,
   bash/PowerShell generator-equivalence coverage, attach-argv coverage, and Go
   tests for runtime parsing, account discovery, and dashboard rendering. Add
   a keyless smoke test and a separate key-gated check when authenticated
   behavior cannot be exercised without a secret.

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

**GitHub CLI (`gh`)** is automatically available inside containers. Shared
authentication remains the default: all services receive the same `GH_TOKEN`,
and the host's `GH_CONFIG_DIR` is mounted read-only as a Linux fallback. On
Windows and macOS, `gh` normally stores tokens in the OS credential store,
which the Linux container cannot read, so importing `GH_TOKEN` is required.

To isolate GitHub identities by container, configure every account explicitly:

```dotenv
GH_AUTH_MODE=per-account

GH_USER_A=github-login-a
GH_TOKEN_A=...
GH_USER_B=github-login-b
GH_TOKEN_B=...

# Optional commit identity overrides; global values remain the fallback.
GIT_USER_NAME_A=Account A Name
GIT_USER_EMAIL_A=account-a@example.com
```

Per-account mode has fail-closed behavior:

- both `GH_USER_<LETTER>` and `GH_TOKEN_<LETTER>` are required through the
  configured `NUM_ACCOUNTS` range (`A` through `ZZ`);
- each service receives only its matching token as the standard in-container
  `GH_TOKEN` variable, never the global token as a fallback;
- the shared `GH_CONFIG_DIR` mount is omitted, so one service cannot read a
  different account's `hosts.yml` credential; and
- startup, update, and the TUI compare `gh api user --jq .login` with the
  configured login and show the actual login or a distinct mismatch.

Import a named account already stored by the host `gh` CLI without changing
which host account is active:

```bash
# Bash / macOS / Linux
scripts/claude-docker gh-auth a --user github-login-a
scripts/claude-docker gh-auth claude-b --user github-login-b
scripts/claude-docker gh-auth --all

# Windows PowerShell equivalents
.\scripts\claude-docker.ps1 gh-auth a --user github-login-a
.\scripts\claude-docker.ps1 gh-auth --all
```

The targeted form recreates only that service when it is running. `--all` and
`update` retrieve each token with
`gh auth token --hostname github.com --user <login>`; they never call
`gh auth switch`. The TUI's `g` action applies the same operation to the
selected row.

To migrate an existing installation, add the per-account mappings, set
`GH_AUTH_MODE=per-account`, regenerate compose files, then recreate services:

```bash
scripts/generate-compose.sh       # use generate-compose.ps1 on Windows
scripts/claude-docker up --force-recreate
```

Rotate a single credential by re-authenticating that login on the host and
running targeted `gh-auth`; rotate all configured mappings with
`gh-auth --all`. Tokens remain plaintext in the host `.env`, which is
permission-hardened but should still be backed up, retained, and rotated as a
secret.

This feature covers `gh` and **HTTPS Git operations only** through `gh auth
setup-git`; it does not isolate SSH keys or SSH agents. It protects accounts
from other account containers by removing shared credential sources, but not
from host administrators or anyone with Docker daemon access, who can inspect
container environments.

Verify auth with `gh api user` (which checks the credential `gh` actually uses
for API calls) rather than `gh auth status`:

```bash
# Verify gh auth inside container
scripts/claude-docker exec claude-a gh api user --jq .login

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
> entrypoint has no shared files to copy or link and Claude Code falls back
> to its built-in defaults.
>
> **Compatibility**: Tested against claude-config v1.10+. The contract
> claude-docker relies on (directory layout, hook command grammar,
> dual-variant pairing, full-suite probe, CRLF normalization) is documented
> in [`docs/CLAUDE_DOCKER_CONTRACT.md`](https://github.com/kcenon/claude-config/blob/develop/docs/CLAUDE_DOCKER_CONTRACT.md)
> in the claude-config repo. Older claude-config installs may work but are
> not gate-tested.

The host's `~/.claude/` is mounted read-only at `/home/node/.claude-host/`
inside each container. Startup uses different synchronization strategies by
content type:

| Shared content | Default container behavior |
|----------------|----------------------------|
| `hooks/`, `scripts/` | Clean-copy into `/home/node/.claude/` and normalize `.sh` files to LF |
| `skills/`, `commands/`, `ccstatusline/` | Symlink into the per-account state directory |
| `CLAUDE.md`, `commit-settings.md`, `.claudeignore`, `.full-suite-active` | Symlink when the source exists |
| `settings.json` | Generate `settings.container.json`, then point the account's `settings.json` at that transformed copy |
| `ccstatusline/settings.json` | Also link into `/home/node/.config/ccstatusline/settings.json` |

The default read-only host mount is never modified. Account credentials,
memory, sessions, and logs remain writable and per-container. The managed
`hooks/` and `scripts/` destinations are clean mirrors and replace existing
same-named account directories on startup. For `skills/`, `commands/`, and
`ccstatusline/`, an existing plain target is moved to `<name>.stale.<epoch>`
before linking. Non-empty per-account instruction files are preserved, but do
not use the managed directories for persistent per-account overrides.

`CLAUDE_CONFIG_SOURCE` changes this behavior. An explicit source is treated as
writable, force-linked on every startup, and its `.sh` files are normalized to
LF **in place** before linking. If that source is under the project bind mount,
the normalization can therefore appear as host-side Git changes. The
`settings.json` transform described below still runs.

### Container-side settings transformation

The entrypoint does not use `settings.json` verbatim. For both the default host
mount and an explicit `CLAUDE_CONFIG_SOURCE`, it writes a container-local
working copy before Claude Code starts. The transform performs four operations:

1. sets `sandbox.enabled` to `false`;
2. removes wildcard entries from `permissions.deny`;
3. replaces a PowerShell `statusLine.command` with the Linux statusline script;
4. rewrites PowerShell hook commands to their bash equivalents.

**1. `sandbox.enabled` is forced to `false`.**

The host sandbox gates filesystem and network access on the host. Inside a
container it would re-confine already-confined code and, more importantly,
break hooks and skills that `exec` into `/usr/bin`. The entrypoint relies on
the container itself being the isolation boundary.

This assumption relies on the **default** profile: cgroups/namespaces, a
non-root process, no Docker socket, no privileged mode, read-only host-config
mounts, and only the documented writable project/state mounts. It does **not**
hold when:

- the container runs with `--privileged`,
- the host Docker socket or another privileged daemon is mounted, or
- additional host paths or devices are exposed with broader permissions.

If you run claude-docker in any of those modes you lose the host sandbox
without warning. Either keep the outer Docker isolation strict or edit the
entrypoint to leave `sandbox.enabled` untouched for that profile.

**2. Wildcard deny rules are removed.**

Entries in `permissions.deny` containing `*` are stripped. The claude-config
integration expects `sensitive-file-guard.sh` to provide the corresponding
sensitive-file protection. If a custom config source does not ship and enable
that hook, those wildcard restrictions are not replaced; do not assume the
host deny list remains effective inside the container.

**3. A PowerShell statusline command is replaced.**

If `statusLine.command` contains `pwsh`, it is replaced with
`~/.claude/scripts/statusline-command.sh` before the general hook rewrite.

**4. PowerShell hook commands are rewritten for Linux.**

Host `settings.json` entries that invoke `pwsh -NoProfile -File ...` are
transformed so they work inside the Linux-native container image. This is
best-effort: trivial single-call hooks are rewritten cleanly, but the following
patterns are not supported reliably:

| Pattern | Example | Status |
|---------|---------|--------|
| `pwsh -NoProfile -File ./foo.ps1` | top-level script | supported |
| Heredoc / multi-line `-Command` | `pwsh -c @"..."@` | not supported |
| `$env:VAR` expansion | `pwsh -c '$env:FOO'` | not supported |
| Quoted paths with spaces | `pwsh -File "C:\\Program Files\\..."` | not supported |
| `Join-Path` outside the statusLine slot | inside a hook array | not supported |

After transformation, startup runs `bash -n -c` against every generated command
and logs a warning for invalid shell syntax. A syntactically valid but
semantically incorrect rewrite can still fail only when the hook runs. If a
hook works on the host but not in the container, check the startup logs and the
patterns above. The workaround is to provide Linux-native commands through
`CLAUDE_CONFIG_SOURCE`, so the PowerShell rewriter has nothing to change. The
sandbox and wildcard-deny transforms still apply, and `.sh` files in that
explicit source are CRLF-normalized in place.

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
authentication status, the actual GitHub login (including mismatch state),
recent activity, and live token usage in one view. In per-account GitHub mode,
the `g` action refreshes only the selected account and recreates only that
service when it is running.

```bash
scripts/claude-docker tui            # Launch dashboard
scripts/claude-docker dashboard      # Alias of tui
scripts/claude-docker build-tui      # Build from source (requires Go 1.24+)
```

**The TUI is built from source, and Go 1.24+ is required for it.** `tui` looks
for `tui/claude-docker-tui` and tells you to run `build-tui` if it is not
there.

There is no prebuilt-binary download. The wrappers used to offer one, pointed
at this repository's `releases/latest` — and this repository has never
published a release, so the offer could only fail after a network round trip.
Removing it means a host without Go is told what it actually needs on the first
try. `.github/workflows/release-tui.yml` is retained and is triggered by a `v*`
tag; if releases are published later, a verified download path can be
reintroduced against a real tag rather than against `latest`.

Token usage is recomputed on every refresh from each account's JSONL session
files and memoized per file, so an unchanged history is not reparsed. The
cache is shared across accounts and pruned per account; the measurements and
the benchmark that produces them are in
[`docs/PERFORMANCE.md`](docs/PERFORMANCE.md).

### Rebuilding the Image

```bash
scripts/claude-docker build --no-cache                # Rebuild all installed agent CLIs
scripts/claude-docker up --force-recreate             # Recreate containers
scripts/claude-docker update                          # Perform both steps and refresh gh credentials
```

`update` refreshes the configured shared or per-account GitHub token(s) from
the host when `gh` is available, then runs a no-cache build and force-recreates
the containers. Use `.\scripts\claude-docker.ps1 update` on native Windows.

### Cleanup and Removal

```bash
scripts/claude-docker down -v          # Stop + remove named volumes
scripts/cleanup.sh --no                # Containers/volumes only; preserve runtime state
scripts/cleanup.sh --backups           # Also offer to delete backups older than 7 days
scripts/remove.sh                      # Interactive complete removal

# Windows PowerShell equivalents
.\scripts\cleanup.ps1 -SkipState      # Containers/volumes only
.\scripts\cleanup.ps1 -Backups        # Remove stale backups, then prompt for state
.\scripts\remove.ps1                  # Interactive complete removal
```

`cleanup` always stops containers and removes named volumes. If given a project
repository path, it also removes that repository's additional worktrees. It
then prompts before deleting **every registered runtime's** state root
(`~/.claude-state`, `~/.codex-state`, and `~/.gemini-state`); use `--no` or
`-SkipState` to preserve them. `remove` additionally offers to remove the image,
worktrees, state, `.env`, and host-installed tools. The PowerShell remover also
sweeps rotated `.env.backup.*` files after confirmed `.env` removal. Read each
prompt before confirming because credentials and session history live in the
state directories.

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

### Tier A -- Shared Source (default)

Both containers mount the same project directory. Simplest setup, minimum
storage. Best when one session writes and the other reads/reviews. Any account
can modify any other account's work, so use it only between mutually trusted
accounts.

### Tier B -- Git Worktree

Each container gets its own worktree for full concurrent editing safety.
No `.git/index.lock` contention.

```bash
scripts/setup-worktrees.sh ~/work/project    # Create worktrees
scripts/claude-docker up                     # Selects the worktree overlay
```

On native Windows, use
`.\scripts\setup-worktrees.ps1 C:\path\to\project`, then start with
`.\scripts\claude-docker.ps1 up`.

Setting `PROJECT_DIR_A` selects worktree mode on its own, which is how installs
predating `ISOLATION_MODE` keep working unchanged. Setting the key explicitly
outranks that inference, and configuring worktree paths under a different mode
warns that they are inert rather than ignoring them silently.

> **Worktrees are a concurrency tier, not a security boundary.** The accounts
> still share one git object store, so an account can read every branch and
> rewrite refs other accounts depend on. Use worktrees when agents collide on a
> checkout, not when you distrust what an agent will run.

### Tier C -- Independent Clones

Each container gets its own full clone: separate working tree *and* separate
git metadata, so there is no common object store to read other branches from.

```bash
scripts/setup-isolated.sh ~/work/project     # Create independent clones
# add the printed ISOLATION_MODE and ISOLATED_WORKSPACE_* lines to .env
scripts/generate-compose.sh                  # Regenerate with the new mode
scripts/claude-docker up                     # Selects the isolated overlay
```

On native Windows, use `.\scripts\setup-isolated.ps1 C:\path\to\project` and
`.\scripts\generate-compose.ps1`.

Unlike `PROJECT_DIR_A`, setting `ISOLATED_WORKSPACE_A` does not select the mode
on its own — declare `ISOLATION_MODE=isolated` explicitly. Nothing predates
that key, so an undeclared mode is a mistake worth reporting rather than a
legacy layout worth honoring.

Isolated accounts receive no shared host configuration, which means no shared
hooks, skills, commands, statusline or `CLAUDE.md`.

The container profile is hardened: a read-only root filesystem, every capability
dropped, `no-new-privileges`, an init process, and a bounded PID limit
(`ISOLATED_PIDS_LIMIT`, default 1024). The paths the entrypoint and toolchain
have to write — `/tmp`, the npm and tool caches, the XDG config directory — are
bounded tmpfs mounts, and the global git config is redirected into the account's
own state mount so `git push` keeps working.

Credentials and networks are scoped too. An isolated account receives **no
shared `GH_TOKEN`**, and each account sits on its own bridge network so siblings
cannot resolve or connect to each other. Set `GH_AUTH_MODE=per-account` to give
an account credentials of its own — it then receives only its own `GH_TOKEN_<X>`
— and `ISOLATED_NETWORK_MODE=none` for a fully offline profile.

> **What this tier does not do.** Egress is not filtered: separate bridges stop
> account A from reaching account B, not from reaching the internet. A container
> escape is also out of scope — the hardened profile raises the cost of one, but
> a kernel or runtime vulnerability defeats it, so this is not a substitute for a
> VM boundary. [`docs/ISOLATION.md`](docs/ISOLATION.md) has the per-concern
> table.

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
Scaling down does not delete account state directories, credentials, or
history; remove retained state explicitly only after confirming it is no
longer needed.

Account names follow Excel-style letters: 1→`a`, 26→`z`, 27→`aa`, 52→`az`,
53→`ba`, ..., 702→`zz`. The `scale` command and both compose generators accept
`NUM_ACCOUNTS` values from 1 through 702, though host memory is usually the
binding constraint well before then.

On Windows (PowerShell):
```powershell
.\scripts\claude-docker.ps1 scale 4
```

## State and Memory Persistence

State is preserved across container restarts through bind mounts and named
volumes. The selected runtime determines the account and host-config paths:

| Runtime | Account state on host | Container state | Read-only host config mount |
|---------|-----------------------|-----------------|-----------------------------|
| Claude | `~/.claude-state/account-a/` | `/home/node/.claude/` | `~/.claude/` -> `/home/node/.claude-host/` |
| Codex | `~/.codex-state/account-a/` | `/home/node/.codex/` | `~/.codex/` -> `/home/node/.codex-host/` |
| Gemini | `~/.gemini-state/account-a/` | `/home/node/.gemini/` | `~/.gemini/` -> `/home/node/.gemini-host/` |

Mutable credentials, sessions, logs, and runtime history stay in the account
state mount. Bootstrap modules deliberately exclude known credential and
session files when they copy or link selected host configuration. That selected
configuration is still visible to the container, so do not embed secrets in it.
Other persistent mounts are:

| Data | Host/source | Container destination | Mode |
|------|-------------|-----------------------|------|
| GitHub CLI config (shared mode only) | `${GH_CONFIG_DIR}` or the platform default | `/home/node/.config/gh/` | Read-only |
| `node_modules` | Named volume `node_modules_<suffix>` | `${CONTAINER_PROJECT_DIR:-/project}/node_modules/` | Read-write |
| Project files (Tier A) | `${PROJECT_DIR}` | `${CONTAINER_PROJECT_DIR:-/project}` | Read-write |
| Project files (Tier B, account A example) | `${PROJECT_DIR_A}` | `${CONTAINER_PROJECT_DIR_A:-/project-a}` | Read-write |

## Compose Overrides

All compose files are **generated** by `scripts/generate-compose.sh` (or `.ps1`)
based on `NUM_ACCOUNTS`, resolved as described under
[`NUM_ACCOUNTS` precedence](#num_accounts-precedence) below. Do not edit them
manually.

They are nonetheless **tracked in Git** as the committed source of truth, so
what is committed has to match generator output. The committed copies represent
the generator defaults with no `.env` present and none of these set in the
environment:

| Setting | Value | Source |
|---------|-------|--------|
| `NUM_ACCOUNTS` | `2` | `scripts/generate-compose.sh` default |
| `AGENT_RUNTIME` | `claude` | `scripts/lib/runtime.sh` default |
| `IMAGE_TAG` | contents of `VERSION` | repo-root `VERSION` file |

The `Compose files are current` CI job regenerates under exactly those defaults
and fails on any difference. Regenerating with your own `.env` during local work
is expected, but do not commit the result — restore the committed copies first:

```bash
git checkout -- docker-compose.yml docker-compose.linux.yml docker-compose.worktree.yml docker-compose.isolated.yml
```

### `NUM_ACCOUNTS` precedence

Every shell-side reader resolves `NUM_ACCOUNTS` the same way: **an exported
environment variable wins, then `.env`, then the built-in default of `2`.** This
is the rule `scripts/lib/parse_env.sh` documents for `load_env_file`, and the one
`AGENT_RUNTIME` has always followed in both languages.

| Reader | Decides |
|--------|---------|
| `scripts/generate-compose.sh`, `scripts/generate-compose.ps1` | how many services get written |
| `get_num_accounts` in `scripts/claude-docker` | which services the CLI acts on |
| `Get-NumAccounts` in `scripts/ClaudeDocker.psm1` | the same, on Windows |

The first source holding a **non-empty** value wins even if that value is
unusable: an exported `NUM_ACCOUNTS=abc` does not fall through to `.env`. What
happens next differs by layer on purpose. The generators abort, because they
write files that CI then checks. The CLI wrappers warn and fall back to `2`,
because listing the default pair beats refusing to print a service list. This
applies to non-numeric values and integers outside the supported `1..702`
range, so the wrappers never enumerate a topology the generators would reject.

The TUI dashboard sits outside this rule by design. `Env.NumAccounts()` in
`tui/internal/config/env.go` reads `.env` alone, because `Env` is the document
the TUI edits and writes back, and it treats the value as a floor rather than an
exact count. Missing or unusable values start from the generator default of `2`,
and `discoverStateDirs` raises that floor to cover any account state directory
it finds on disk.

`tests/test_num_accounts_precedence.sh` pins all four shell-side readers to the
table above and runs in the `Bash Tests` CI matrix.

| File | Purpose | When active |
|------|---------|-------------|
| `docker-compose.yml` | Base config (Tier A), incl. `user: ${UID:-1000}:${GID:-1000}` and `HOME=/home/node` | Always |
| `docker-compose.linux.yml` | Legacy UID/GID + HOME override (kept for backward compat; base already carries it) | Optional |
| `docker-compose.worktree.yml` | Per-container worktree paths | `ISOLATION_MODE=worktree` only |
| `docker-compose.isolated.yml` | Per-container independent clone, hardened container profile (`read_only`, `cap_drop: ALL`, no-new-privileges, PID limit), per-account bridge, `environment: !override` | `ISOLATION_MODE=isolated` only |

The worktree and isolated overlays are mutually exclusive: both replace the
volume list with `!override` and they disagree on `working_dir`, so composing
them together is not "the widest set" but a broken stack. All four files are
generated in every mode; the resolved mode decides which one is selected.

On native Linux, set `UID` / `GID` in `.env` (or export them before running
`docker compose up`) to match the host user that owns the selected runtime's
state root. The interactive bash installer does this automatically. Without
matching IDs, bind-mounted paths such as `~/.claude-state/account-a/` are not
writable from inside the container, producing errors like
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

On native Linux, the container UID/GID must match the owner of the selected
runtime's state root. Add them to `.env` and restart — the base compose reads
these directly, so no extra overlay is required.

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

**Slow file operations (Windows through WSL2):**

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
files and immediately restrict them to the current owner (`chmod 600` on
Unix-like hosts, a user-only Windows ACL in PowerShell).
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
content digest**, so movement of the upstream tag cannot silently change the
base layers. This does not make the complete image byte-for-byte reproducible:
APT packages and several npm-installed tools track their repositories at build
time unless explicitly pinned.

Inside the image, **Claude Code is installed via Anthropic's official native
installer** (`https://claude.ai/install.sh`), not via npm. The installer places
`claude` at `/home/node/.local/bin/claude`, so `/doctor` no longer warns about
"leftover npm global install". Optional build arguments are
`CLAUDE_CODE_VERSION`, `CODEX_CLI_VERSION`, and `GEMINI_CLI_VERSION`; leave a
value empty to follow that installer's current release. To bump the Node base:

1. Check <https://hub.docker.com/_/node/tags?name=slim> for the latest patch in
   the pinned 20.x line
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
   hand-edit the generated `docker-compose.yml` — its header forbids it.
   The committed compose files embed the tag as their default, so the bump
   must carry a regeneration from a clean checkout or worktree with no `.env`
   (`scripts/generate-compose.sh`) in the same change or the
   `Compose files are current` job fails. Do not delete a working installation's
   `.env` just to produce the repository defaults.
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
generated compose files pick up the new values.

### Node heap headroom

The container memory limit caps *everything* inside the container. The Node
old-space limit caps only the JavaScript heap, and the two are not the same
budget: V8's other heap spaces, native allocations from node modules, every
subprocess an agent spawns (git, ripgrep, package managers, compilers) and the
page cache for the bind mounts all draw on the container limit as well.

A heap allowed to reach the cap on its own is therefore OOM-killed before V8
ever reaches the ceiling that would have made it collect garbage instead — and
an OOM kill is the less useful of the two failures, since it takes the whole
container down with no JavaScript stack.

The generator derives the heap from the cap rather than setting it beside it:

| `CONTAINER_MEM_LIMIT` | Reserved | `--max-old-space-size` |
|:---|:---|:---|
| 1G | 512 MiB | 512 |
| 2G | 512 MiB | 1536 |
| 4G (default) | 1024 MiB | 3072 |
| 8G | 2048 MiB | 6144 |
| 16G | 4096 MiB | 12288 |

The reservation is a quarter of the cap, with a floor of 512 MiB — a flat
percentage collapses to nothing on small caps, where the fixed costs do not
shrink along with the cap. **This is a convention, not a measurement**: no
steady-state non-heap footprint has been measured for these containers yet, so
the number is stated as a convention on purpose, to be replaced by a measured
one rather than reinterpreted.

Override it with `CONTAINER_NODE_HEAP_MB` (in MiB, the unit
`--max-old-space-size` actually uses). An explicit value is checked against the
cap, and a combination leaving less than 512 MiB free is refused when compose
files are generated — before any container starts — rather than at run time:

```
$ CONTAINER_NODE_HEAP_MB=4096 scripts/generate-compose.sh
Error: the Node heap limit does not leave enough of the container memory cap free.
       CONTAINER_MEM_LIMIT=4G is 4096 MiB; a 4096 MiB heap leaves 0 MiB, and at least 512 MiB is required.
       Set CONTAINER_NODE_HEAP_MB to at most 3584, or raise CONTAINER_MEM_LIMIT.
```

Installations that generated compose files before this existed carried a
4096 MiB heap under a 4 GiB cap — exactly zero headroom. Regenerating lowers it
to 3072 MiB. That is a deliberate change of an existing default rather than a
preserved one.

The table below assumes defaults. Docker RAM is the recommended Docker Desktop
memory allocation to allow all containers to run at peak load.

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
+-- docker-compose.worktree.yml        Generated: worktree-mode override
+-- docker-compose.isolated.yml        Generated: isolated-mode override (hardened profile)
+-- docs/
|   +-- ISOLATION.md                   Workspace isolation modes and their trust boundaries
|   +-- PERFORMANCE.md                 Benchmark numbers of record
+-- .env.example                       Environment template
+-- .gitignore
+-- .gitattributes                     LF line endings
+-- .github/workflows/                 CI and cross-platform TUI release automation
+-- LICENSE                            BSD 3-Clause
+-- README.md                          This file
+-- scripts/
|   +-- claude-docker                  CLI wrapper (bash)
|   +-- claude-docker.ps1              CLI wrapper (PowerShell)
|   +-- claude-docker.cmd              CLI wrapper (cmd.exe batch)
|   +-- ClaudeDocker.psm1              Shared PowerShell module
|   +-- generate-compose.sh            Compose file generator (bash)
|   +-- generate-compose.ps1           Compose file generator (PowerShell)
|   +-- entrypoint.sh                  Runtime bootstrap dispatcher + GitHub auth setup
|   +-- install.sh                     Interactive setup (bash)
|   +-- install.ps1                    Interactive setup (PowerShell)
|   +-- remove.sh                      Complete removal (bash)
|   +-- remove.ps1                     Complete removal (PowerShell)
|   +-- cleanup.sh                     Container/volume/worktree/state cleanup (bash)
|   +-- cleanup.ps1                    Same cleanup flow (PowerShell)
|   +-- setup-worktrees.sh             worktree-mode setup (bash)
|   +-- setup-worktrees.ps1            worktree-mode setup (PowerShell)
|   +-- setup-isolated.sh              isolated-mode clone setup (bash)
|   +-- setup-isolated.ps1             isolated-mode clone setup (PowerShell)
|   +-- test-concurrent-git.sh         E2E test (bash)
|   +-- test-concurrent-git.ps1        E2E test (PowerShell)
|   +-- test-entrypoint-settings.sh    Entrypoint settings normalization test (bash)
|   +-- lib/
|       +-- worktrees.sh               Which git worktrees the removers may delete (bash)
|       +-- parse_env.sh               Shared .env parser (bash)
|       +-- index.sh / index.ps1       Excel-style account index helpers
|       +-- runtime.sh                 Runtime registry reader (jq, awk fallback)
|       +-- isolation.sh               Isolation-mode resolution and the trust-boundary text
|       +-- resources.sh               Memory cap to Node heap arithmetic
|       +-- build-compose-cmd.sh       Compose overlay selection (bash)
|       +-- bootstrap-common.sh        Shared entrypoint helpers
|       +-- bootstrap-claude.sh        Per-runtime container bootstrap modules
|       +-- bootstrap-codex.sh         (dispatched by entrypoint.sh via the registry)
|       +-- bootstrap-gemini.sh
+-- tui/                               Bubble Tea multi-account dashboard (Go module)
|   +-- main.go
|   +-- Makefile
|   +-- go.mod / go.sum
|   +-- internal/                      account, auth, config, docker, ui, usage subpackages
|       +-- config/runtimes.json       Runtime registry: cross-language single source of truth
+-- tests/                             Registry/parser/generator/auth/platform/entrypoint
    |                                  regression tests and fixtures
    +-- env_fixtures/
    +-- entrypoint_fixtures/
```

`sources/` contains local nested working directories that are gitignored
and never copied into the Docker image. They can be removed safely if not
in use.

## License

[BSD 3-Clause](LICENSE)
