# Dual Claude Code Container Architecture

Storage-optimized architecture for running two Claude Code instances simultaneously
on a single host using Docker. Supports Linux, macOS, and Windows (WSL2).

> **Cross-platform details**: See [cross-platform.md](cross-platform.md) for
> platform-specific adjustments, compose templates, and the full comparison matrix.

## Problem Statement

Two separate Claude Code sessions (different accounts) need to:

- Access the same project source code on the host
- Run independently without interfering with each other
- Minimize total disk consumption (no full duplication of environments)

VM-based approaches duplicate the guest OS and toolchain per instance.
A container-based design shares read-only image layers and avoids that overhead.

## Design Goals

| Priority | Goal |
|----------|------|
| 1 | Minimize storage footprint |
| 2 | Isolate account credentials and session state |
| 3 | Share project source without duplication |
| 4 | Maintain stability under concurrent access |
| 5 | Keep the setup simple and reproducible |

## Architecture Overview

```
Host (Linux / macOS / Windows+WSL2)
├── ~/work/project/                  # Source code (single copy)
│   ├── .git/
│   └── src/ ...
├── ~/.claude-state/account-a/       # Account A: auth + session state
├── ~/.claude-state/account-b/       # Account B: auth + session state
└── Docker
    ├── image: claude-code-base      # One shared image (Node 20 + Claude Code)
    ├── container: claude-a          # Runs with account-a state
    └── container: claude-b          # Runs with account-b state
```

> **Windows**: `~/` paths are inside WSL2 filesystem (`/home/<user>/`), not NTFS.
> See [cross-platform.md](cross-platform.md) for platform-specific path rules.

### Storage Breakdown

| Component | Copies | Typical Size | Notes |
|-----------|--------|-------------|-------|
| Base image (Node 20 + Claude Code + tools) | 1 | ~800 MB | Read-only layers shared |
| Container writable layer (each) | 2 | ~10-50 MB | Only diffs from image |
| Project source (bind mount) | 1 | Varies | Not duplicated |
| Account state directory (each) | 2 | ~5-20 MB | Auth tokens, settings, history |
| **Total overhead for second instance** | — | **~20-70 MB** | vs ~800 MB+ for a second VM |

### Scaling Beyond Two Instances

The pattern extends to N accounts. Each additional instance requires:

| Resource | Per Additional Instance |
|----------|----------------------|
| Disk (writable layer + state) | ~20-70 MB |
| RAM (NODE_OPTIONS heap) | 4 GB |
| CPU | 1-2 cores recommended |
| Host state directory | `~/.claude-state/account-{name}/` |
| Compose service | New service block (copy and rename) |

**Resource scaling**:

| Instances | Docker RAM | Recommended Host RAM (Linux / macOS / Windows) |
|-----------|-----------|----------------------------------------------|
| 2 | 8 GB | 12 / 16 / 16 GB |
| 3 | 12 GB | 16 / 20 / 20 GB |
| 4 | 16 GB | 20 / 24 / 24 GB |
| 1 manager + 2 workers + Redis | 12.3 GB | 16 / 20 / 20 GB |
| 1 manager + 3 workers + Redis | 16.3 GB | 20 / 24 / 24 GB |
| 1 manager + 4 workers + Redis | 20.3 GB | 24 / 28 / 28 GB |

To add a third instance, add a new service to `docker-compose.yml`:

```yaml
  claude-c:
    image: claude-code-base:latest
    working_dir: /workspace
    stdin_open: true
    tty: true
    volumes:
      - ${PROJECT_DIR}:/workspace                          # or ${PROJECT_DIR_C} for Tier B
      - ${HOME}/.claude-state/account-c:/home/node/.claude
      - node_modules_c:/workspace/node_modules
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_C:-}             # Path B only; leave empty for subscriptions
      - NODE_OPTIONS=--max-old-space-size=4096
```

And add `node_modules_c:` to the `volumes:` section. For subscription
accounts (Path A), authenticate inside the container on first launch:
`docker compose exec claude-c claude auth login`

> The default templates ship with 2 instances. Adding more is a manual
> compose edit — there is no dynamic scaling mechanism.

## Two Configuration Tiers

### Tier A — Shared Source (Simplest, Smallest Storage)

Both containers bind-mount the same host directory.

```yaml
services:
  claude-a:
    image: claude-code-base:latest
    working_dir: /workspace
    stdin_open: true
    tty: true
    volumes:
      - ${PROJECT_DIR}:/workspace
      - ${HOME}/.claude-state/account-a:/home/node/.claude
      - node_modules_a:/workspace/node_modules
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_A:-}  # Path B only; leave empty for subscriptions
      - NODE_OPTIONS=--max-old-space-size=4096

  claude-b:
    image: claude-code-base:latest
    working_dir: /workspace
    stdin_open: true
    tty: true
    volumes:
      - ${PROJECT_DIR}:/workspace
      - ${HOME}/.claude-state/account-b:/home/node/.claude
      - node_modules_b:/workspace/node_modules
    environment:
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_B:-}  # Path B only; leave empty for subscriptions
      - NODE_OPTIONS=--max-old-space-size=4096

volumes:
  node_modules_a:
  node_modules_b:
```

> **First run**: Named volumes start empty. Run `npm install` inside each
> container after first startup: `docker compose exec claude-a npm install`

**Pros**: Absolute minimum storage; zero source duplication.
**Cons**: Concurrent writes to the same file can conflict; `.git/index.lock`
contention if both run git commands simultaneously.

**Best for**: One session writes, the other reads/reviews.

### Tier B — Git Worktree Isolation (Recommended for Active Development)

Each container gets its own worktree from the same repository.
Git objects are shared; only checked-out files are duplicated.

```
Host
├── ~/work/project/            # Main worktree (repo + objects)
├── ~/work/project-a/          # Worktree A (checked-out files only)
└── ~/work/project-b/          # Worktree B (checked-out files only)
```

```bash
# One-time setup
cd ~/work/project
git worktree add ../project-a branch-a
git worktree add ../project-b branch-b
```

**Storage cost**: Source files × 2 (no git object duplication).
A 100 MB source tree adds ~100 MB, not another full clone.

**Pros**: No lock contention; independent branches; full concurrent safety.
**Cons**: Slightly more storage than Tier A; worktree setup step required.

> **Limitation**: Git does not allow the same branch to be checked out
> in two worktrees simultaneously. If both accounts need to work on `main`,
> create tracking branches: `git worktree add ../project-a main-a`
> (where `main-a` is based on `main`), then merge back.

**Best for**: Both sessions actively editing and committing.

## Orchestration Tier (Phase 5)

For coordinated multi-agent analysis, the orchestration overlay adds a
manager-worker pattern with Redis shared context on top of the base
container architecture.

### Architecture

```
Host
└── Docker Compose (default bridge network)
    ├── redis              (shared context store, redis:7-alpine)
    ├── manager            (interactive Claude session, dispatches work)
    ├── worker-1           (HTTP server + claude -p, port 9000)
    ├── worker-2           (HTTP server + claude -p, port 9000)
    ├── worker-3           (HTTP server + claude -p, port 9000)
    └── [claude-a, claude-b from base — still available]
```

### Communication Flow

```
Manager ──HTTP POST──> Worker-N:9000/task
                       │
                       ├── Read context:shared from Redis
                       ├── Read findings:all from Redis
                       ├── Build enriched prompt (context + prior findings + task)
                       ├── Execute claude -p
                       ├── Parse structured JSON findings
                       ├── Write result:{taskId} to Redis
                       └── RPUSH findings:{category} + findings:all to Redis
                       │
Manager <──JSON resp── Worker-N
```

### Redis Data Model

| Key Pattern | Type | Purpose |
|-------------|------|---------|
| `context:shared` | HASH | Project context set by manager (summary, architecture, focus areas) |
| `findings:{category}` | LIST | Categorized findings (security, performance, architecture, ...) |
| `findings:all` | LIST | All findings chronologically across all workers |
| `result:{taskId}` | HASH | Per-task result (worker, raw output, structured findings, timestamp) |
| `task:{taskId}` | HASH | Task metadata (prompt, assignee, status, timestamp) |
| `worker:{name}:status` | STRING | Worker status with 60s TTL (idle/busy/error) |
| `worker:{name}:heartbeat` | STRING | Heartbeat timestamp with 30s TTL |

### Worker Personas (Phase 7)

Each worker runs a specialized persona injected via the `WORKER_PERSONA`
environment variable in the orchestration compose file. The worker HTTP server
(`worker-server.js`) reads `WORKER_PERSONA` and prepends it as a system prompt
section to every task it receives.

| Persona | Worker | Focus Area | Findings Category |
|---------|--------|------------|-------------------|
| **Sentinel** (Security Analyst) | worker-1 | Vulnerabilities, hardcoded secrets, injection flaws, auth weaknesses | `security` |
| **Reviewer** (Code Quality Engineer) | worker-2 | Dead code, duplication, SOLID violations, excessive complexity | `quality` |
| **Profiler** (Performance Engineer) | worker-3 | N+1 queries, blocking I/O, memory leaks, bundle size issues | `performance` |

The `run_analysis()` function in `scripts/manager-helpers.sh` reads persona
definitions from `scripts/personas.json`, wraps the user prompt with each
persona's role instructions, and dispatches to all workers in parallel via
`dispatch_task`. Results are collected, deduplicated, and presented in a
categorized summary.

**CLI entry point**: `scripts/claude-docker analyze <prompt> [timeout]`

The project `CLAUDE.md` is configured so that a manager Claude Code session
auto-orchestrates when the user mentions analysis-related keywords (analyze,
audit, review, inspect, scan). The manager sources `manager-helpers.sh` and
calls `run_analysis` automatically.

### Key Design Decisions

- **HTTP over raw TCP**: `curl` and `jq` already in the image; HTTP provides framing and error codes
- **Workers mount source `:ro`**: Workers analyze code but do not modify it
- **Redis as context bus**: Structured findings accumulate across workers; each worker reads prior findings before processing
- **Opt-in overlay**: Base compose unchanged; add via `-f docker-compose.orchestration.yml`
- **No docker.sock**: All communication via bridge network; no container needs Docker API access

## Authentication Strategy

Two authentication paths, each primary for its account type.
Choose based on what kind of Anthropic account you have.

### Path A: Subscription Accounts (Pro / Max / Team) — OAuth

Subscription accounts use OAuth. The authentication method differs by platform.

#### macOS: Host-Side OAuth with Keychain Extraction

On macOS, container-internal `claude auth login` fails because the OAuth
localhost callback cannot cross the Docker network boundary (see upstream
GitHub [#34917](https://github.com/anthropics/claude-code/issues/34917),
[#30369](https://github.com/anthropics/claude-code/issues/30369)).

The working solution is host-side OAuth with Keychain extraction:

```bash
# 1. Authenticate on the host (outside Docker)
claude auth login

# 2. Extract from Keychain and inject into container state directories
scripts/claude-docker auth          # Injects into all active services
scripts/claude-docker auth claude-a # Or target a specific service

# 3. Verify
docker compose exec claude-a claude auth status
```

Under the hood, `scripts/claude-docker auth` calls
`security find-generic-password -s "Claude Code-credentials" -w` to extract
the OAuth token from macOS Keychain, then writes `.credentials.json` to each
container's bind-mounted state directory (`~/.claude-state/account-*/`).

#### Linux / WSL2: Container-Internal OAuth

On Linux and WSL2, container-internal OAuth works normally:

```bash
# 1. Start the containers
docker compose up -d

# 2. Authenticate each account inside its container
docker compose exec claude-a claude auth login   # → prints URL to visit
docker compose exec claude-b claude auth login   # → prints URL to visit

# 3. Verify
docker compose exec claude-a claude auth status
docker compose exec claude-b claude auth status
```

Each state directory now contains `.credentials.json` with OAuth tokens.
The bind-mounted state directories persist credentials across container restarts.

```bash
# .env (never committed)
PROJECT_DIR=/path/to/your/project
```

> **Token refresh**: Claude Code automatically refreshes tokens using the
> `refreshToken` in `.credentials.json`. If a token expires beyond refresh
> (e.g., password change, account revocation), re-run the appropriate auth
> method for your platform.

### Path B: Console API Keys — Environment Variable

For [Anthropic Console](https://console.anthropic.com/) accounts (usage-based billing),
use `ANTHROPIC_API_KEY` directly. No browser or host-side setup needed.

```bash
# .env (never committed)
PROJECT_DIR=/path/to/your/project
CLAUDE_API_KEY_A=sk-ant-...
CLAUDE_API_KEY_B=sk-ant-...
```

The compose templates detect which path to use: if `CLAUDE_API_KEY_A` is set,
it takes precedence over OAuth credentials in the mounted state directory.

### Choosing Your Path

| | Path A: Subscription | Path B: API Key |
|---|---|---|
| Account type | Pro, Max, Team | Console (usage-based) |
| Auth method | macOS: host OAuth + Keychain extraction; Linux/WSL2: container-internal OAuth | Environment variable |
| Browser needed | Once per account, on any device | Never |
| Token management | Auto-refresh; re-auth on revocation | Manual key rotation |
| Container restart | Credentials persist via bind mount | Always available via `.env` |
| Billing | Included in subscription | Separate usage-based |

## Security Considerations

| Risk | Mitigation |
|------|-----------|
| API keys in environment | Use `.env` file (gitignored); never embed in Dockerfile |
| Container escape | Do NOT mount `/var/run/docker.sock` |
| Credential exposure | State directories are mode 0700; bind mount only what's needed |
| Network over-exposure | Use DevContainer firewall script to whitelist outbound only |
| Concurrent file corruption | Use Tier B (worktrees) for active dual editing |

## Resource Requirements

| Resource | Per Container | Total (2 containers) |
|----------|--------------|---------------------|
| RAM | 4 GB (NODE_OPTIONS heap) | 8 GB |
| CPU | 2 cores recommended | 4 cores recommended |
| Disk (image) | Shared ~800 MB | ~800 MB |
| Disk (state) | ~5-20 MB | ~10-40 MB |
| Disk (writable layer) | ~10-50 MB | ~20-100 MB |

**Minimum host RAM by platform (2 instances)**:
- Linux: 12 GB (8 GB for containers + 4 GB for OS; no VM overhead)
- macOS: 16 GB (8 GB Docker Desktop VM + 8 GB for macOS)
- Windows: 16 GB (12 GB WSL2 + 4 GB for Windows)

For 3+ instances, see [Scaling Beyond Two Instances](#scaling-beyond-two-instances).

**CPU**: 4+ cores (add 1-2 per additional instance). **Disk**: 2 GB free (image + volumes).

## Implementation Phases

### Phase 1 — Base Image

- [ ] Create Dockerfile based on official DevContainer reference
- [ ] Install Claude Code via npm (Node 20 base)
- [ ] Include essential dev tools (git, gh, fzf, jq)
- [ ] Set NODE_OPTIONS for 4 GB heap
- [ ] Set `NODE_PATH=/usr/local/lib/node_modules` for global npm package resolution
  (needed by `worker-server.js` which `require('redis')` from the global install)
- [ ] Test image build and basic `claude --version`

### Phase 2 — Account State Separation

- [ ] Create host state directories (`~/.claude-state/account-a`, `account-b`)
- [ ] Write docker-compose.yml with bind mounts
- [ ] Write `.env.example` for API keys
- [ ] Test: two containers start independently with different credentials

### Phase 3 — Source Sharing

- [ ] Tier A: Single bind mount to `/workspace`
- [ ] Tier B: Git worktree setup script
- [ ] Test: both containers can read/build the project
- [ ] Test: concurrent git operations (Tier B only)

### Phase 4 — Hardening

- [ ] Firewall script (outbound whitelist)
- [ ] Read-only mount option for review-only sessions
- [ ] Container resource limits (memory, CPU)
- [ ] Cleanup script for worktrees and state

### Phase 5 — Orchestration

| Deliverable | Description |
|-------------|-------------|
| `docker-compose.orchestration.yml` | Redis + manager + N worker services |
| `scripts/worker-server.js` | Node.js HTTP server with Redis context integration |
| `scripts/manager-helpers.sh` | Bash functions for task dispatch and result aggregation |
| `scripts/test-orchestration.sh` | E2E test for orchestration pipeline |
| Dockerfile update | Add `redis-tools` (apt) and `redis` npm package |
| `.env.example` update | Add orchestration environment variables |

### Phase–Requirements Traceability

| Phase | Deliverables | PRD FR | SRS Spec | PRD SC |
|-------|-------------|--------|----------|--------|
| 1 — Base Image | Dockerfile, .dockerignore | FR-1~5 | SRS-5.1.1~10 | SC-1, SC-2 |
| 2 — Account Separation | docker-compose.yml, .env.example | FR-6~9 | SRS-5.2.1~11, 5.3.1~3, 6.1~6.3 | SC-3, SC-4, SC-6 |
| 3 — Source Sharing | Tier A/B configs, setup-worktrees.sh | FR-10~13 | SRS-5.4.1~3, 5.5 | SC-5, SC-7, SC-8 |
| 4 — Hardening | Firewall, resource limits, cleanup.sh | FR-14~17 | SRS-7.2, 7.3, 4.4 | SC-9 |
| 5 — Orchestration | orchestration.yml, worker-server.js, manager-helpers.sh, test-orchestration.sh | FR-18~24 | SRS-8.1~8.4 | SC-10, SC-11 |

## Comparison: Containers vs VMs

| Factor | Docker (this design) | VM × 2 |
|--------|---------------------|---------|
| Base environment storage | ~800 MB (shared) | ~4-10 GB × 2 |
| Source code storage | 1 copy (bind mount) | Shared folder or 2 copies |
| Startup time | Seconds | Minutes |
| RAM overhead | ~100 MB per container | ~1-2 GB per VM |
| Account isolation | Directory-level | Full OS-level |
| Setup complexity | docker-compose up | Hypervisor + guest OS + toolchain |
| Host integration | Docker Engine (Linux) / Docker Desktop (macOS, Windows) | KVM/QEMU (Linux), Parallels/UTM (macOS), Hyper-V (Windows) |

## File Inventory

```
claude-docker/
├── docs/
│   ├── product-requirements-document.md          # PRD
│   ├── software-requirements-specification.md    # SRS
│   ├── software-design-specification.md          # SDS
│   ├── architecture.md              # This document
│   ├── cross-platform.md            # Linux / macOS / Windows comparison and templates
│   └── reference/
│       ├── claude-code-container.md  # Claude Code Docker internals
│       ├── docker-storage.md         # Image layers, overlay2, optimization
│       ├── linux-docker.md           # Linux: native perf, UID/GID, SELinux
│       ├── macos-docker.md           # macOS: VirtioFS, file sharing, alternatives
│       └── windows-docker.md         # Windows: WSL2, CRLF, Defender, networking
├── Dockerfile                        # (Phase 1)
├── .dockerignore                     # (Phase 1)
├── docker-compose.yml                # (Phase 2) base — macOS/Windows ready
├── docker-compose.linux.yml          # (Phase 2) Linux override (UID/GID, HOME)
├── docker-compose.worktree.yml       # (Phase 3) Tier B override
├── docker-compose.firewall.yml       # (Phase 4) firewall override (cap_add)
├── docker-compose.orchestration.yml  # (Phase 5) orchestration overlay
├── .env.example                      # (Phase 2)
├── .gitignore                        # (Phase 2)
├── .gitattributes                    # (Phase 2) LF line endings (Windows teams)
└── scripts/
    ├── claude-docker                 # Unified CLI wrapper (build, auth, analyze, usage, ...)
    ├── setup-worktrees.sh            # (Phase 3, Tier B)
    ├── test-concurrent-git.sh        # (Phase 3, Tier B — E2E concurrent git test)
    ├── cleanup.sh                    # (Phase 4)
    ├── worker-server.js              # (Phase 5) worker HTTP server with Redis
    ├── manager-helpers.sh            # (Phase 5) manager dispatch functions
    ├── personas.json                 # (Phase 7) worker persona definitions
    └── test-orchestration.sh         # (Phase 5) E2E orchestration test
```

## Usage Tracking

`scripts/claude-docker usage` aggregates token usage across all containers and
the host into a single report. It runs on the host (requires Node.js / `npx`)
and does not need containers to be running.

Under the hood, the command builds a temporary directory with symlinks that
merge each account's `~/.claude-state/account-*/projects/` subdirectories
together with the host's `~/.claude/projects/`. It then invokes
[ccusage](https://github.com/ryoppippi/ccusage) against the merged directory
so that all session data appears as a single config root.

```bash
scripts/claude-docker usage           # daily report (default)
scripts/claude-docker usage monthly   # monthly report
scripts/claude-docker usage session   # per-session breakdown
```

Supported report types: `daily`, `monthly`, `session`, `blocks`, `statusline`.

## References

- [Official DevContainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) — Anthropic's reference Dockerfile
- [Claude Code Authentication](https://docs.anthropic.com/en/docs/claude-code/authentication) — Auth methods and precedence
- [Claude Code Settings](https://docs.anthropic.com/en/docs/claude-code/settings) — Config directory structure
- [Docker Storage Drivers](https://docs.docker.com/engine/storage/drivers/) — Layer sharing mechanics
- [Docker Bind Mounts](https://docs.docker.com/engine/storage/bind-mounts/) — Host path mounting
- [Docker Desktop WSL 2 Backend](https://docs.docker.com/desktop/features/wsl/) — Windows architecture
- [VirtioFS on Docker Desktop](https://www.docker.com/blog/speed-boost-achievement-unlocked-on-docker-desktop-4-6-for-mac/) — macOS file sharing performance
