# Docker on Windows — Reference

Windows-specific considerations for the dual Claude Code container setup.
Windows adds the most complexity due to the WSL2 layer, NTFS semantics,
and filesystem performance characteristics.

## Architecture

```
Windows Host
├── WSL2 (Hyper-V lightweight VM)
│   ├── Linux kernel
│   ├── Docker Engine (daemon, containerd)
│   │   ├── overlay2 (native ext4 inside VM)
│   │   ├── Container A
│   │   └── Container B
│   └── WSL2 filesystem (/home/user/)     ← FAST
│       └── ext4 on virtual disk
├── NTFS (C:\Users\)                       ← SLOW via Plan9
└── Docker Desktop (management UI)
```

### WSL2 vs Hyper-V Backend

WSL2 is the **default and recommended** backend since Docker Desktop 4.x.
Hyper-V backend is legacy and no longer necessary.

| Feature | WSL2 (default) | Hyper-V (legacy) |
|---------|---------------|-----------------|
| Windows edition | All (Home, Pro, Enterprise) | Pro/Enterprise only |
| Linux kernel | Real, Microsoft-maintained | MobyLinux VM |
| Memory | Dynamic allocation | Fixed allocation |
| Performance | Better | Slower |
| File sharing | Plan9 + ext4 | SMB |

## The Critical Performance Rule

**Store all source code and project files in the WSL2 Linux filesystem.**

| Source location | Bind mount speed | Mechanism |
|----------------|-----------------|-----------|
| `/home/user/project` (WSL2 ext4) | ~0.9x native Linux | Direct ext4 access |
| `/mnt/c/Users/project` (NTFS) | ~0.04x native Linux | Plan9 network protocol |

Real-world example: A Next.js build went from **44.2s (NTFS) → 1.6s (WSL2 fs)**,
a 27x improvement.

### How to Set Up

```powershell
# From PowerShell: open WSL2 terminal
wsl

# Inside WSL2: create project structure
mkdir -p ~/work/project
mkdir -p ~/.claude-state/account-a
mkdir -p ~/.claude-state/account-b

# Clone repository inside WSL2 filesystem
cd ~/work
git clone <repo-url> project
```

**Never** `cd /mnt/c/Users/...` for Docker work.

### Accessing WSL2 Files from Windows

Windows Explorer: `\\wsl.localhost\Ubuntu\home\<user>\work\`

VS Code: Open WSL2 folder directly via Remote-WSL extension.

## Line Endings (CRLF vs LF)

### The Problem

- Windows text editors and Git default to CRLF line endings
- Linux containers expect LF
- Bash scripts with CRLF will fail: `/bin/bash^M: bad interpreter`

### Prevention

Add `.gitattributes` to the repository root:

```gitattributes
# Force LF everywhere
* text=auto eol=lf

# Explicitly LF for scripts and Docker files
*.sh text eol=lf
*.bash text eol=lf
Dockerfile text eol=lf
docker-compose.yml text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
*.json text eol=lf
```

Configure Git globally:

```bash
# Inside WSL2
git config --global core.autocrlf input

# On Windows (if also using Git there)
git config --global core.autocrlf true
```

### Fixing Existing Files

```bash
# Inside WSL2
find . -name "*.sh" -exec sed -i 's/\r$//' {} +
```

## File Permissions

### NTFS → Container Mapping

When bind-mounting from NTFS (`/mnt/c/...`), Docker Desktop maps all
files to mode **0777**. This is not configurable.

Consequences:
- Applications expecting specific permissions (e.g., SSH keys at 0600) fail
- Security-sensitive files appear world-readable

### WSL2 Filesystem Permissions

Files on the WSL2 ext4 filesystem have proper Linux permissions.
This is another reason to use WSL2 fs instead of NTFS.

### Implications for Account State

The `.credentials.json` file should be mode 0600. This works correctly
only on the WSL2 filesystem:

```bash
chmod 600 ~/.claude-state/account-a/.credentials.json
ls -la ~/.claude-state/account-a/.credentials.json
# -rw------- 1 user user 256 ... .credentials.json
```

## Resource Allocation

### .wslconfig

Create or edit `C:\Users\<username>\.wslconfig`:

```ini
[wsl2]
memory=12GB
processors=4
swap=4GB
localhostForwarding=true
```

**Guidelines for 2 containers**:

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Memory | 8 GB | 12 GB |
| Processors | 4 | 6 |
| Swap | 2 GB | 4 GB |

Reserve at least 4 GB for Windows itself.

After editing, restart WSL2:

```powershell
wsl --shutdown
```

### Container-Level Limits

Same as Linux — use `deploy.resources` in compose or `--cpus`/`--memory`
flags. These are enforced by cgroups inside the WSL2 VM.

## Git Worktree on Windows

### MAX_PATH Limitation

Windows historically limits paths to 260 characters. Deep `node_modules`
nesting can exceed this.

**Fix** (Windows 10 1607+ / Windows 11):

```bash
# Inside WSL2 (usually not needed, but for safety)
git config --global core.longpaths true
```

On the WSL2 ext4 filesystem, MAX_PATH does not apply — it is a
Windows/NTFS limitation. Another reason to use WSL2 fs.

### Worktree Setup (Inside WSL2)

```bash
cd ~/work/project
git worktree add ../project-a branch-a
git worktree add ../project-b branch-b
```

No Windows-specific issues when operating entirely within WSL2.

## Windows Defender Impact

### The Problem

Windows Defender real-time scanning adds synchronous I/O overhead
to every file operation. For Docker bind mounts from NTFS, this
compounds with the Plan9 protocol overhead.

### Mitigations

1. **Use WSL2 filesystem** (primary) — Defender overhead is reduced
   because operations happen inside the VM

2. **Dev Drive** (Windows 11 only):
   - ReFS-based filesystem with Defender "performance mode"
   - Defers scanning instead of blocking operations
   - Create via Settings → System → Storage → Disks & volumes

3. **Named volumes** for I/O-heavy directories:
   ```yaml
   volumes:
     - node_modules_a:/workspace/node_modules   # Inside VM, no Defender
   ```

**Do NOT add Docker paths to Defender exclusions** — the security
trade-off is not worth it for development.

## Terminal Selection

### Recommended: WSL2 Terminal via Windows Terminal

```
Windows Terminal
└── Tab: Ubuntu (WSL2)
    ├── docker compose up    # Run from here
    ├── docker compose exec claude-a bash
    └── Full Linux shell
```

### Comparison

| Terminal | Docker Integration | Performance | Recommendation |
|----------|-------------------|-------------|----------------|
| WSL2 (bash/zsh) | Native | Best | **Use this** |
| PowerShell | Via Docker Desktop | Path translation overhead | Admin tasks only |
| CMD | Via Docker Desktop | Limited | Avoid |
| Git Bash | Partial | TTY issues | Avoid |

**Git Bash is explicitly incompatible** with Claude Code's TTY requirements.

## Networking Caveats

### WSL2 NAT

WSL2 uses NAT networking by default. `127.0.0.1` inside WSL2 points to
the Linux VM loopback, not Windows loopback.

To access a container port from Windows:

```
http://localhost:<port>    # Docker Desktop forwards automatically
```

### Do NOT Use Mirrored Networking

Setting `networkingMode=mirrored` in `.wslconfig` breaks Docker Desktop
and Kubernetes. Stick with the default NAT mode.

### MCP Server Localhost Issues

If Claude Code MCP servers bind to `localhost`, they may not be
reachable from Windows or vice versa due to NAT. Use `0.0.0.0`
bindings inside containers.

## Known Issues with Claude Code on Windows

### 1. Docker MCP Gateway Failures (GitHub docker/for-win#14867)

Docker MCP gateway reports "Docker Desktop is not running" even when it is.

**Workaround**: Ensure Docker Desktop's WSL2 integration is enabled
for your distro (Settings → Resources → WSL integration).

### 2. Network Connectivity Issues (GitHub #14550)

"Unable to connect to Anthropic services" with silent timeouts.

**Fix**: Check WSL2 DNS resolution:

```bash
# Inside WSL2
nslookup api.anthropic.com
```

If DNS fails, add nameservers to WSL2:

```bash
sudo tee /etc/resolv.conf <<< "nameserver 8.8.8.8"
```

### 3. Sandboxing Requires WSL2 (Not WSL1)

Claude Code sandboxing features require WSL2. WSL1 is not supported.

**Check version**:

```powershell
wsl --list --verbose
# Should show VERSION 2
```

**Upgrade if needed**:

```powershell
wsl --set-version Ubuntu 2
```

## Complete Setup Checklist

```
[ ] Windows 10 (1903+) or Windows 11
[ ] WSL2 enabled with a Linux distro (Ubuntu recommended)
[ ] Docker Desktop installed with WSL2 backend
[ ] WSL integration enabled for your distro in Docker Desktop
[ ] .wslconfig with adequate resources (12 GB RAM, 4 CPU)
[ ] Source code cloned inside WSL2 filesystem (/home/user/)
[ ] .gitattributes with eol=lf in repository
[ ] Git configured: core.autocrlf=input (inside WSL2)
[ ] .claude-state directories created in WSL2 filesystem
[ ] .env file with PROJECT_DIR and API keys if Path B (in WSL2 filesystem, gitignored)
[ ] Windows Terminal with WSL2 tab as default
[ ] Dev Drive configured (Windows 11, optional)
```

## Sources

- [Docker Desktop WSL 2 Backend](https://docs.docker.com/desktop/features/wsl/)
- [WSL2 Best Practices for Docker](https://docs.docker.com/desktop/features/wsl/best-practices/)
- [WSL2 File System Performance](https://learn.microsoft.com/en-us/windows/wsl/compare-versions)
- [Windows Defender and Docker](https://docs.docker.com/engine/security/antivirus/)
- [Git Line Endings](https://docs.github.com/en/get-started/getting-started-with-git/configuring-git-to-handle-line-endings)
- [MAX_PATH Limitation](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)
- [WSL Networking](https://learn.microsoft.com/en-us/windows/wsl/networking)
- [GitHub docker/for-win#14867](https://github.com/docker/for-win/issues/14867) — MCP gateway
- [GitHub anthropics/claude-code#14550](https://github.com/anthropics/claude-code/issues/14550) — Connectivity
- [GitHub anthropics/claude-code#26450](https://github.com/anthropics/claude-code/issues/26450) — Plugin marketplace
