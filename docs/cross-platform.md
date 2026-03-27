# Cross-Platform Analysis

Can the dual Claude Code container architecture work identically
on Linux, Windows, and macOS? Short answer: **yes, with platform-specific
adjustments.** This document maps what changes per platform and what stays the same.

## Platform Comparison Matrix

| Factor | Linux | macOS | Windows (WSL2) |
|--------|-------|-------|----------------|
| Docker engine | Native (no VM) | Apple Virtualization VM | WSL2 Linux VM |
| Bind mount speed | ~1.0x (native) | ~0.3x | ~0.04x (NTFS) / ~0.9x (WSL2 fs) |
| Storage driver | overlay2 (native) | overlay2 (in VM) | overlay2 (in WSL2 VM) |
| Image layer sharing | Yes | Yes | Yes |
| Credential storage (in container) | `.credentials.json` (0600) | `.credentials.json` (0600) | `.credentials.json` (0600) |
| Credential storage (host native) | `.credentials.json` (0600) | Keychain | `.credentials.json` (0600, in WSL2) |
| UID/GID mapping | Required | Not needed (VM) | Not needed (VM) |
| SELinux/AppArmor | May need `:z` flag | N/A | N/A |
| Line endings | LF (native) | LF (native) | CRLF risk if source on NTFS |
| Antivirus impact | Minimal | None | Significant (Windows Defender) |
| TTY support | Full | Full | Full (WSL2 terminal) |
| `docker compose up` | Works | Works | Works |

## What Works Identically Across All Platforms

These aspects of the architecture require **zero changes**:

1. **Image layer sharing** — Same image, multiple containers, shared read-only layers.
   This is a Docker engine feature independent of host OS.

2. **Container count and composition** — `docker-compose.yml` structure
   (2 services, same image, different volume mounts) is identical.

3. **`CLAUDE_CONFIG_DIR` separation** — Each container points to its own
   state directory. Works the same everywhere.

4. **`ANTHROPIC_API_KEY` authentication** — Environment variable injection
   is platform-independent.

5. **Named volumes for dependencies** — `node_modules` in a Docker-managed
   volume performs well on all platforms.

6. **TTY allocation** — `stdin_open: true` + `tty: true` in compose works everywhere.

7. **Firewall script** — iptables inside the container is Linux regardless of host.

## What Requires Platform-Specific Adjustment

### A. Source Code Location

| Platform | Recommended Source Location | Why |
|----------|---------------------------|-----|
| Linux | Anywhere on host filesystem | Native bind mount, no penalty |
| macOS | Anywhere under `/Users/` | VirtioFS handles it (~3x slower than native) |
| Windows | **Inside WSL2 filesystem** (`/home/user/project`) | NTFS mount is ~27x slower than WSL2 fs |

**Windows critical rule**: Never store source on `/mnt/c/` (Windows drive).
Always use the WSL2 Linux filesystem. This single decision determines
whether the setup is usable or painfully slow.

### B. Path Syntax in docker-compose.yml

The compose templates below use `${PROJECT_DIR}` and `${HOME}` variables
defined in `.env`. Here is what the **expanded** paths look like per platform:

```
# Linux / macOS (expanded example)
/home/alice/work/project → ${PROJECT_DIR}
/home/alice/.claude-state/account-a → ${HOME}/.claude-state/account-a

# Windows WSL2 (expanded example)
/home/alice/work/project → ${PROJECT_DIR}   (WSL2 ext4, fast)
/mnt/c/Users/alice/project → AVOID          (NTFS, slow)
```

On Windows, `${HOME}` inside WSL2 points to `/home/<username>`,
which is the correct (fast) filesystem. If running from PowerShell,
paths must use Windows format or be prefixed with `\\wsl.localhost\`.

### C. File Permissions (Linux Only)

Linux bind mounts expose raw UID/GID to the container.
If the container runs as `node` (UID 1000) but the host user
is UID 1001, permission mismatches occur.

**Solution**: Match UIDs or pass `--user` flag.

```yaml
# docker-compose.yml (Linux only)
services:
  claude-a:
    user: "${UID}:${GID}"    # Match host user
```

> **Note**: When `user` overrides the default `node` user, the container
> has no matching `/etc/passwd` entry for that UID. `CLAUDE_CONFIG_DIR`
> ensures Claude Code finds its config, but other tools (`git`, `npm`)
> may warn about missing home directories. To suppress this, set
> `HOME=/home/node` in the environment or add `--userns=host` to the run.

macOS and Windows do not have this issue because Docker Desktop's VM
handles permission translation.

### D. SELinux (RHEL/CentOS/Fedora Only)

SELinux blocks container access to host directories by default.
Add the `:z` flag to bind mounts:

```yaml
# RHEL/CentOS/Fedora
volumes:
  - ${HOME}/work/project:/workspace:z
  - ${HOME}/.claude-state/account-a:/home/node/.claude:Z
```

- `:z` — shared label (multiple containers can access)
- `:Z` — private label (only this container)

Use `:z` for the project directory (both containers access it).
Use `:Z` for account state (each container has exclusive access).
Debian/Ubuntu (AppArmor) do not need these flags.

### E. Line Endings (Windows Only)

If source files touch NTFS at any point (cloned on Windows,
then moved to WSL2), CRLF line endings may corrupt shell scripts.

**Prevention**: Add `.gitattributes` to the repository:

```gitattributes
# Force LF for all text files
* text=auto eol=lf

# Ensure scripts are always LF
*.sh text eol=lf
*.bash text eol=lf
Dockerfile text eol=lf
docker-compose.yml text eol=lf
```

### F. Resource Allocation

| Platform | Configuration Location | Recommended (2 containers) |
|----------|----------------------|---------------------------|
| Linux | `docker run` flags / compose `deploy` | 8 GB RAM, 4 CPU (host native) |
| macOS | Docker Desktop → Settings → Resources | 8 GB RAM, 4 CPU |
| Windows | `C:\Users\<user>\.wslconfig` | 8-12 GB RAM, 4 CPU |

Windows `.wslconfig` example:

```ini
[wsl2]
memory=12GB
processors=4
swap=4GB
```

### G. Antivirus (Windows Only)

Windows Defender real-time scanning adds synchronous I/O overhead
to bind mount operations.

**Mitigations** (choose one):
1. **Store code in WSL2 filesystem** (primary — Defender overhead is reduced)
2. **Use Dev Drive** (Windows 11 — ReFS with Defender performance mode)
3. **Use named volumes** for I/O-heavy directories

Do NOT disable Defender or add broad exclusions — the security
trade-off is not worth it.

## Platform-Specific docker-compose.yml Templates

> The templates below show **Tier A** (shared source). For **Tier B**
> (git worktree isolation), replace the single `${PROJECT_DIR}` with
> per-container paths (`${PROJECT_DIR_A}`, `${PROJECT_DIR_B}`) pointing
> to separate worktrees. See [architecture.md](architecture.md#tier-b--git-worktree-isolation-recommended-for-active-development).

> **First run**: Named volumes for `node_modules` start empty.
> After `docker compose up`, run `docker compose exec claude-a npm install`
> (and same for claude-b) to populate dependencies.

### Linux

```yaml
services:
  claude-a:
    image: claude-code-base:latest
    working_dir: /workspace
    stdin_open: true
    tty: true
    user: "${UID}:${GID}"
    volumes:
      - ${PROJECT_DIR}:/workspace          # :z if SELinux
      - ${HOME}/.claude-state/account-a:/home/node/.claude
      - node_modules_a:/workspace/node_modules
    environment:
      - HOME=/home/node
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_A:-}  # Path B only; leave empty for subscriptions
      - NODE_OPTIONS=--max-old-space-size=4096

  claude-b:
    image: claude-code-base:latest
    working_dir: /workspace
    stdin_open: true
    tty: true
    user: "${UID}:${GID}"
    volumes:
      - ${PROJECT_DIR}:/workspace
      - ${HOME}/.claude-state/account-b:/home/node/.claude
      - node_modules_b:/workspace/node_modules
    environment:
      - HOME=/home/node
      - CLAUDE_CONFIG_DIR=/home/node/.claude
      - ANTHROPIC_API_KEY=${CLAUDE_API_KEY_B:-}  # Path B only; leave empty for subscriptions
      - NODE_OPTIONS=--max-old-space-size=4096

volumes:
  node_modules_a:
  node_modules_b:
```

**Notes**: `user` field matches host UID/GID. `HOME=/home/node` ensures
tools (git, npm) find a valid home directory despite the UID override.
Add `:z`/`:Z` suffixes to volume paths on SELinux distros.

### macOS

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

**Notes**: No `user` field needed. VirtioFS is default; ensure it is
selected in Docker Desktop settings.

### Windows (Run from WSL2 Terminal)

```yaml
services:
  claude-a:
    image: claude-code-base:latest
    working_dir: /workspace
    stdin_open: true
    tty: true
    volumes:
      - ${PROJECT_DIR}:/workspace                    # Must be WSL2 filesystem!
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

`.env` (inside WSL2):

```bash
PROJECT_DIR=/home/myuser/work/project    # WSL2 path, NOT /mnt/c/...
CLAUDE_API_KEY_A=sk-ant-...
CLAUDE_API_KEY_B=sk-ant-...
```

**Notes**: All paths must be in WSL2 filesystem (not `/mnt/c/`).
`${HOME}` inside WSL2 resolves to `/home/<username>`.
Run `docker compose up` from WSL2 terminal, not PowerShell.
Ensure `.wslconfig` allocates enough resources.

## Platform Suitability Ranking

For this specific dual-container architecture:

| Rank | Platform | Reason |
|------|----------|--------|
| 1 | **Linux** | Native performance, no VM overhead, simplest setup |
| 2 | **macOS** | Stable with VirtioFS, Docker Desktop well-maintained |
| 3 | **Windows (WSL2)** | Works well IF source is on WSL2 fs; more moving parts |

All three are **fully viable**. The ranking reflects operational
complexity, not capability.

## Decision Checklist

Before deploying on any platform:

- [ ] Docker (or Docker Desktop) installed and running
- [ ] Source code in the correct filesystem (WSL2 fs for Windows)
- [ ] `.claude-state/account-a` and `account-b` directories created
- [ ] `.env` file with `PROJECT_DIR` and API keys if Path B (gitignored)
- [ ] `.gitattributes` with `eol=lf` (Windows teams)
- [ ] Resource allocation configured (Docker Desktop or `.wslconfig`)
- [ ] SELinux `:z` flag added (RHEL/CentOS/Fedora only)
- [ ] UID/GID matched in compose (Linux only)

## References

- [Docker Desktop WSL 2 Backend](https://docs.docker.com/desktop/features/wsl/) — Windows architecture
- [WSL2 Best Practices for Docker](https://docs.docker.com/desktop/features/wsl/best-practices/) — File location guidance
- [Docker Rootless Mode](https://docs.docker.com/engine/security/rootless/) — Linux security option
- [SELinux and Docker](https://docs.docker.com/engine/storage/bind-mounts/#configure-the-selinux-label) — :z/:Z flags
- [OverlayFS Storage Driver](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/) — Cross-platform layer sharing
- Platform-specific references: see [linux-docker.md](reference/linux-docker.md) and [windows-docker.md](reference/windows-docker.md)
