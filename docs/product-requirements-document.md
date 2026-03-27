# PRD: Dual Claude Code Container Architecture

**Status**: Draft | **Version**: 1.0.0 | **Date**: 2026-03-27

**Related docs**: [architecture.md](architecture.md), [cross-platform.md](cross-platform.md), [reference/claude-code-container.md](reference/claude-code-container.md), [reference/docker-storage.md](reference/docker-storage.md), [reference/linux-docker.md](reference/linux-docker.md), [reference/macos-docker.md](reference/macos-docker.md), [reference/windows-docker.md](reference/windows-docker.md)

---

## 1. Executive Summary

Multiple Claude Code sessions on different Anthropic accounts — including
subscription (Pro/Max/Team) accounts — need to run simultaneously on a
single host, sharing the same project source code without duplicating
the runtime environment.

This PRD defines a Docker-based solution: one shared image (~800 MB),
N containers with isolated account state (~5-20 MB each), and bind-mounted
source code. Each additional instance adds only 20-70 MB of disk overhead,
compared to 4-10 GB per additional VM. The default templates ship with 2
instances; scaling to more requires only a compose edit and additional RAM
(4 GB per instance).

The solution supports Linux, macOS, and Windows (WSL2) with two
configuration tiers — shared source (simplest) and git worktree (safest).
Two authentication paths are provided: host-first OAuth for subscription
accounts and API key for Console accounts. Implementation spans 5 phases
over an estimated 9-15 days.

---

## 2. Problem Statement

A developer or team needs two distinct Claude Code sessions on separate
Anthropic accounts, working on the same codebase concurrently. Examples:

- One session writes code while the other reviews
- Two team members sharing a workstation with separate accounts
- Parallel feature work on different branches

**Why VMs fall short:**

| Factor | Docker (proposed) | VM x 2 |
|--------|------------------|---------|
| Environment storage | ~800 MB (shared) | 4-10 GB x 2 |
| Startup time | Seconds | Minutes |
| RAM overhead per instance | ~100 MB | 1-2 GB |
| Source code | 1 copy (bind mount) | Shared folder or 2 copies |

**Success looks like:** Both sessions run independently, credentials are
fully isolated, source is not duplicated, and total additional overhead
stays under 100 MB.

---

## 3. Goals and Non-Goals

### Goals

| # | Goal | Measure |
|---|------|---------|
| G1 | Minimize storage footprint | Second instance adds < 70 MB |
| G2 | Isolate account credentials | Separate `CLAUDE_CONFIG_DIR` per container |
| G3 | Share project source | Single bind mount or shared git objects |
| G4 | Concurrent access stability | Tier B eliminates lock contention |
| G5 | Simple and reproducible setup | `docker compose up` on all 3 platforms |
| G6 | Cross-platform support | Linux, macOS, Windows (WSL2) |
| G7 | Support subscription accounts | Host-first OAuth for Pro/Max/Team |
| G8 | Scalable to N instances | Compose pattern extends to 3+ accounts |
| G9 | Manager-worker orchestration | 1 manager dispatches tasks to N workers via HTTP; results aggregated via Redis |
| G10 | Shared context accumulation | Worker N reads structured findings from workers 1..N-1 before processing |

### Non-Goals

- Multi-tenant hosting or dynamic auto-scaling
- Replacing IDE integration (VS Code DevContainers, JetBrains Remote)
- Alpine Linux or non-glibc base image support
- API key rotation, billing management, or account provisioning
- GUI-based management interface

---

## 4. User Personas

### P1: Solo Developer with Two Subscription Accounts

Has a personal Pro subscription and a work Team subscription. Both are
OAuth-based (no API keys). Authenticates each account on the host,
then runs two containers. Only one session writes at a time. Linux or macOS.
**Uses Tier A** (shared source).

### P2: Pair Programming Team

Two engineers sharing a workstation, each with their own Anthropic account.
Both actively edit and commit. Needs concurrent safety. Linux or macOS.
**Uses Tier B** (git worktree).

### P3: Windows Developer

Runs Claude Code in WSL2. Needs clear guidance on filesystem placement
(WSL2 ext4 vs NTFS — 27x performance difference) and `.wslconfig` resource
allocation. Possibly less familiar with Docker internals. **Needs the most
documentation support.**

---

## 5. Solution Overview

### 5.1 Architecture

```
Host (Linux / macOS / Windows+WSL2)
+-  ~/work/project/                  # Source code (1 copy)
+-  ~/.claude-state/account-a/       # Account A state
+-  ~/.claude-state/account-b/       # Account B state
+-  Docker
    +-  image: claude-code-base      # 1 shared image (~800 MB)
    +-  container: claude-a          # Account A
    +-  container: claude-b          # Account B
```

### 5.2 Storage Model

| Component | Copies | Size | Notes |
|-----------|--------|------|-------|
| Base image (Node 20 + Claude Code + tools) | 1 | ~800 MB | Read-only, shared |
| Writable layer per container | 2 | ~10-50 MB | Only diffs |
| Project source (bind mount) | 1 | Varies | Not duplicated |
| Account state per container | 2 | ~5-20 MB | Auth, settings, history |
| **Second instance overhead** | | **20-70 MB** | |

Details: [docker-storage.md](reference/docker-storage.md)

### 5.3 Configuration Tiers

| | Tier A: Shared Source | Tier B: Git Worktree |
|---|---|---|
| Storage cost | Minimum (0 extra) | Source files x 2 |
| Concurrent safety | Risk of `.git/index.lock` | Full isolation |
| Setup complexity | None | One-time worktree setup |
| Best for | 1 writes + 1 reads | Both write concurrently |

> Tier B limitation: Git does not allow the same branch checked out in
> two worktrees. Use tracking branches (e.g., `main-a`, `main-b`).

Details: [architecture.md](architecture.md)

---

## 6. Functional Requirements

Priority: **P0** = must-have, **P1** = should-have, **P2** = nice-to-have.

### Phase 1 — Base Image

| ID | Priority | Requirement |
|----|----------|-------------|
| FR-1 | P0 | Dockerfile based on `node:20-slim` (not Alpine — glibc required) |
| FR-2 | P0 | Claude Code installed via `npm install -g @anthropic-ai/claude-code`, version pinned via build arg |
| FR-3 | P0 | Dev tools included: git, gh, fzf, jq. `NODE_OPTIONS=--max-old-space-size=4096` |
| FR-4 | P0 | `WORKDIR` must not be `/` (causes installation hang) |
| FR-5 | P1 | `.dockerignore` excludes `.git`, `node_modules`, `.env`, `.claude/` |

### Phase 2 — Account Separation

| ID | Priority | Requirement |
|----|----------|-------------|
| FR-6 | P0 | Each container mounts a separate `CLAUDE_CONFIG_DIR` from host `~/.claude-state/account-{a,b}/` |
| FR-7 | P0 | Auth Path A: host-first OAuth for subscription accounts — `claude auth login` on host, bind mount credentials |
| FR-8 | P0 | Auth Path B: `ANTHROPIC_API_KEY` env var for Console accounts |
| FR-9 | P0 | `.env.example` with `PROJECT_DIR` (and API key vars for Path B users) |

### Phase 3 — Source Sharing

| ID | Priority | Requirement |
|----|----------|-------------|
| FR-10 | P0 | Tier A: single `${PROJECT_DIR}` bind mount to both containers |
| FR-11 | P0 | Tier B: per-container worktree paths (`PROJECT_DIR_A`, `PROJECT_DIR_B`) |
| FR-12 | P0 | Named Docker volumes for `node_modules` per container |
| FR-13 | P1 | Worktree setup script (`scripts/setup-worktrees.sh`) |

### Phase 4 — Hardening

| ID | Priority | Requirement |
|----|----------|-------------|
| FR-14 | P1 | Firewall script (iptables outbound whitelist; requires `NET_ADMIN` capability) |
| FR-15 | P2 | Read-only mount option (`:ro`) for review-only sessions |
| FR-16 | P2 | Container resource limits via `deploy.resources` in compose |
| FR-17 | P2 | Cleanup script for worktrees and state (`scripts/cleanup.sh`) |

### Phase 5 — Orchestration

| ID | Priority | Requirement |
|----|----------|-------------|
| FR-18 | P0 | Redis service (`redis:7-alpine`) available on default bridge network with RDB persistence |
| FR-19 | P0 | Worker HTTP server (Node.js) receives prompt via POST, executes `claude -p`, returns structured JSON findings |
| FR-20 | P0 | Workers read shared context from Redis before processing and write structured findings after completion |
| FR-21 | P0 | Manager dispatches tasks to workers via `curl` and aggregates results using `jq` |
| FR-22 | P0 | Orchestration compose overlay (`docker-compose.orchestration.yml`) compatible with all existing overlays via `-f` flag |
| FR-23 | P1 | Worker heartbeat and status tracking in Redis with TTL-based expiration |
| FR-24 | P1 | E2E test script verifies parallel dispatch, Redis result storage, and findings accumulation |

---

## 7. Non-Functional Requirements

| Category | Requirement | Reference |
|----------|-------------|-----------|
| **Performance** | Bind mount targets: Linux 1.0x, macOS ~0.3x (VirtioFS), Windows ~0.9x (WSL2 fs). `node_modules` in named volumes on macOS. | [macos-docker.md](reference/macos-docker.md) |
| **Resources** | Host RAM: 12 GB (Linux), 16 GB (macOS/Windows). 4 GB heap per container. 4+ CPU cores. 2 GB free disk. | [architecture.md](architecture.md) |
| **Security** | API keys via `.env` only. No Docker socket mounting. State dirs mode 0700. Optional firewall whitelist. | [claude-code-container.md](reference/claude-code-container.md) |
| **Portability** | Identical `docker-compose.yml` on all platforms; only `.env` values and Linux `user:` field differ. | [cross-platform.md](cross-platform.md) |
| **Reliability** | Two primary auth paths: host-first OAuth (subscriptions) and API key (Console). Both are production-grade with documented recovery procedures. | [claude-code-container.md](reference/claude-code-container.md) |

---

## 8. Cross-Platform Considerations

| Factor | Linux | macOS | Windows (WSL2) |
|--------|-------|-------|----------------|
| Docker engine | Native | VM (Apple Virtualization) | VM (Hyper-V) |
| Bind mount speed | 1.0x | ~0.3x | ~0.9x (WSL2 fs) / ~0.04x (NTFS) |
| UID/GID handling | `user: "${UID}:${GID}"` + `HOME=/home/node` | Not needed | Not needed |
| SELinux | `:z`/`:Z` flags (RHEL-family only) | N/A | N/A |
| Line endings | N/A | N/A | `.gitattributes` with `eol=lf` required |
| Antivirus | Minimal | None | Defender overhead; use WSL2 fs |
| Min host RAM | 12 GB | 16 GB | 16 GB |

**Linux**: Simplest. Match UID/GID. SELinux `:z`/`:Z` on RHEL-family only.
See [linux-docker.md](reference/linux-docker.md).

**macOS**: VirtioFS adequate for most projects. Named volumes for `node_modules`.
OrbStack as faster alternative. See [macos-docker.md](reference/macos-docker.md).

**Windows**: Source **must** be on WSL2 filesystem (not NTFS). Configure
`.wslconfig` for 12 GB RAM. Run all commands from WSL2 terminal. Git Bash
incompatible with Claude Code TTY. See [windows-docker.md](reference/windows-docker.md).

---

## 9. Known Risks and Mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| R1 | Concurrent file corruption (Tier A) | High (if both write) | High | Use Tier B (worktrees) |
| R2 | OAuth token expiry beyond refresh | Low | Medium | Host-first auth; re-run `claude auth login` on host to recover |
| R3 | macOS bind mount slowness | Certain | Low-Medium | Named volumes for `node_modules`; document OrbStack |
| R4 | Windows NTFS path performance | High (if misconfigured) | High | Document WSL2 fs requirement prominently |
| R5 | UID/GID mismatch on Linux | Medium | Medium | `user:` field + `HOME=/home/node` in compose |
| R6 | Claude Code upstream breaking changes | Low-Medium | Medium | Pin version via Dockerfile build arg |
| R7 | API key exposure | Low (if gitignored) | High | `.env.example` without real keys; `.gitignore` includes `.env` |

---

## 10. Implementation Milestones

### Phase 1 — Base Image

- **Deliverables**: `Dockerfile`, `.dockerignore`
- **Acceptance**: `docker build` succeeds; `claude --version` runs; image < 1 GB
- **Effort**: 1-2 days

### Phase 2 — Account Separation

- **Deliverables**: `docker-compose.yml`, `.env.example`, host directory setup
- **Acceptance**: Two containers start with different API keys; `CLAUDE_CONFIG_DIR` isolated
- **Effort**: 1-2 days | **Depends on**: Phase 1

### Phase 3 — Source Sharing

- **Deliverables**: Tier A config (default), Tier B compose override, `scripts/setup-worktrees.sh`
- **Acceptance**: Both containers read/build project; Tier B passes concurrent git test
- **Effort**: 2-3 days | **Depends on**: Phase 2

### Phase 4 — Hardening

- **Deliverables**: Firewall script, read-only mount option, resource limits, `scripts/cleanup.sh`
- **Acceptance**: Outbound limited to whitelist; review session read-only; cleanup removes state
- **Effort**: 2-3 days | **Depends on**: Phase 3

### Phase 5 — Orchestration

- **Deliverables**: `docker-compose.orchestration.yml`, `scripts/worker-server.js`, `scripts/manager-helpers.sh`, `scripts/test-orchestration.sh`, Dockerfile update, `.env.example` update
- **Acceptance**: Manager dispatches to 3 workers; results stored in Redis; findings accumulate across sequential worker invocations
- **Effort**: 3–5 days | **Depends on**: Phase 1–4

**Total estimated effort: 9–15 days**

---

## 11. Success Criteria

| # | Criterion | Measure |
|---|-----------|---------|
| SC-1 | Storage efficiency | Each additional instance adds <= 70 MB disk overhead |
| SC-2 | Startup time | All containers reach Claude Code prompt within 30s of `docker compose up` |
| SC-3 | Account isolation | Each container's history, credentials, and settings are fully independent |
| SC-4 | Subscription auth | Host-first OAuth tokens persist across container restarts via bind mount |
| SC-5 | Concurrent safety (Tier B) | Two containers commit to different branches without errors |
| SC-6 | Cross-platform parity | Same compose file works on Linux, macOS, and Windows (WSL2) |
| SC-7 | Reproducibility | New user goes from zero to two running containers in < 15 min (Linux) / < 30 min (macOS, Windows) |
| SC-8 | Scalability | Third instance addable by copying one compose service block + creating state directory |
| SC-9 | Security baseline | No API keys in VCS; no Docker socket mounted; state dirs owner-only |
| SC-10 | Manager dispatches tasks to 3 workers and all return results within timeout | Phase 5 |
| SC-11 | Worker-2 prompt includes Worker-1's findings read from Redis shared context | Phase 5 |

---

## 12. Open Questions

1. **Pre-built image**: Should we publish to Docker Hub / GHCR, or require local builds only? Trade-off: convenience vs version pinning and license compliance.
2. **Default tier**: Should Tier B (worktree) be the default compose config? Tier A is simpler for first-run; Tier B is safer for real use.
3. **Upgrade path**: Rebuild image on new Claude Code release, or support in-place `npm update -g` inside running containers?
4. **OAuth token refresh monitoring**: Should the setup include a health check that detects expired tokens and alerts the user to re-authenticate on the host?
4. **Firewall default**: Should Phase 4 firewall be opt-in or opt-out?
5. **Future scope**: Is there a need for a third container role (e.g., shared MCP server or language server)?

---

## Appendix A: Requirements Traceability Matrix

Forward traceability: Goal → Functional Requirement → SRS Specification → Success Criterion.

| Goal | FR | SRS Spec | SC | Phase |
|------|-----|---------|-----|-------|
| G1 (storage) | FR-1, FR-5 | SRS-5.1.1, 5.1.9, 5.1.10 | SC-1 | 1 |
| G2 (isolation) | FR-6, FR-7, FR-8 | SRS-5.2.5, 5.2.7, 5.3.1, 5.3.2 | SC-3, SC-4 | 2 |
| G3 (source sharing) | FR-10, FR-11, FR-12, FR-13 | SRS-5.4.1, 5.4.2, 5.2.6 | SC-5 | 3 |
| G4 (concurrent safety) | FR-10, FR-11 | SRS-5.4.1, 5.4.2 | SC-5 | 3 |
| G5 (simple setup) | FR-2, FR-3, FR-4, FR-9 | SRS-5.1.2–6, 5.2.1–3, 4.5 | SC-2, SC-7 | 1, 2 |
| G6 (cross-platform) | — | SRS-6.1–6.3 | SC-6 | 2, 3 |
| G7 (subscription) | FR-7 | SRS-5.3.1 | SC-4 | 2 |
| G8 (scalable N) | — | SRS-5.5 | SC-8 | 2, 3 |
| G9 | FR-18, FR-19, FR-20, FR-21, FR-22, FR-23, FR-24 | SRS-8.1.1–9, SRS-8.2.1–16, SRS-8.3.1–7, SRS-8.4.1–5 | SC-10 | 5 |
| G10 | FR-20 | SRS-8.2.3–4, SRS-8.2.7, SRS-8.3.3 | SC-11 | 5 |

**Reading the table**:
- Left to right (forward): "Goal G2 is fulfilled by FR-6/7/8, specified in SRS-5.2.5/5.2.7/5.3.1/5.3.2, and verified by SC-3/SC-4."
- Right to left (backward): "SC-4 verifies SRS-5.3.1, which implements FR-7, which achieves Goal G7."

## Appendix B: Document Map

architecture.md → Sections 1-3, 5-6, 9-10 | cross-platform.md → 4, 7-9 | claude-code-container.md → 6-7, 9 | docker-storage.md → 5 | linux-docker.md → 7-9 | macos-docker.md → 7-9 | windows-docker.md → 4, 7-9
