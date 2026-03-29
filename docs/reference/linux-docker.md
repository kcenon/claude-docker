# Docker on Linux — Reference

Linux-specific considerations for the dual Claude Code container setup.
Linux is the simplest platform because Docker runs natively without a VM.

## Architecture

```
Linux Host (kernel)
├── Docker Engine (daemon, containerd)
│   ├── overlay2 (native ext4/xfs)
│   ├── Container A ──┐
│   └── Container B ──┤── Direct kernel namespaces + cgroups
│                      │   No VM boundary
└── Host filesystem ───┘── Bind mounts are native mounts
```

Containers share the host kernel via namespaces (PID, network, mount, user)
and cgroups (resource limits). There is no hypervisor or VM layer.

## Bind Mount Performance

| Platform | Relative Speed | Mechanism |
|----------|---------------|-----------|
| Linux | 1.0x (baseline) | Native VFS mount |
| macOS (VirtioFS) | ~0.3x | Shared memory across VM boundary |
| Windows (WSL2 fs) | ~0.9x | ext4 inside Hyper-V VM |
| Windows (NTFS) | ~0.04x | Plan9 protocol across VM + NTFS |

On Linux, bind mounts have **zero overhead** beyond a normal filesystem
operation. No special optimization (named volumes, sync engines) is needed.

## UID/GID Mapping

### The Problem

Docker does not remap UIDs by default. If the container process runs
as UID 1000 (`node` user) but the host user is UID 1001, files created
by the container on a bind mount will be owned by UID 1000 on the host —
potentially unreadable by the host user.

### Solution 1: Match UIDs (Simplest)

```yaml
services:
  claude-a:
    user: "${UID}:${GID}"   # Injected from host shell
    environment:
      - HOME=/home/node     # Ensure tools find a valid home directory
```

Run with:

```bash
export UID=$(id -u)
export GID=$(id -g)
docker compose up
```

Or add to `.env`:

```bash
UID=1000
GID=1000
```

> **Why `HOME=/home/node`**: When overriding the user, the container
> has no `/etc/passwd` entry for the new UID. Without an explicit `HOME`,
> tools like `git` and `npm` may fail looking for `~/.gitconfig` or
> `~/.npmrc`. Setting `HOME` resolves this while `CLAUDE_CONFIG_DIR`
> handles Claude Code's own config path.

### Solution 2: User Namespace Remapping

Configure `/etc/docker/daemon.json`:

```json
{
  "userns-remap": "default"
}
```

This maps container root (UID 0) to a high-numbered host UID.
Requires configuring `/etc/subuid` and `/etc/subgid`.

More secure but adds complexity. Recommended for shared servers.

### Solution 3: fixuid Entrypoint

Use a container entrypoint script that adjusts the internal user's
UID/GID to match the bind mount owner:

```dockerfile
RUN curl -SsL https://github.com/boxboat/fixuid/releases/download/v0.6.0/fixuid-0.6.0-linux-amd64.tar.gz | tar -C /usr/local/bin -xzf -
RUN chown root:root /usr/local/bin/fixuid && chmod 4755 /usr/local/bin/fixuid
```

This is heavier than Solution 1 but works when the host UID varies.

## SELinux (RHEL, CentOS, Fedora, Rocky, Alma)

### Why It Matters

SELinux enforces mandatory access control. Host directories have type
`user_home_t`; containers run in `container_t` domain. By default,
`container_t` cannot read `user_home_t`.

### The :z and :Z Flags

```yaml
volumes:
  # :z — shared label, multiple containers can access
  - ${PROJECT_DIR}:/workspace:z

  # :Z — private label, only this container can access
  - ${HOME}/.claude-state/account-a:/home/node/.claude:Z
```

For this architecture:
- Project directory: use `:z` (both containers read/write)
- Account state: use `:Z` (only one container should access)

### Checking SELinux Status

```bash
getenforce          # Enforcing, Permissive, or Disabled
sestatus            # Detailed status
ls -Z ~/work/       # Show SELinux labels on files
```

### AppArmor (Debian, Ubuntu)

AppArmor uses path-based policies and generally does not block
Docker bind mounts. No special flags are needed.

```bash
sudo aa-status      # Check AppArmor profiles
```

## Credential Storage

On Linux, Claude Code stores credentials in a plain JSON file
(no Keychain equivalent):

```
$CLAUDE_CONFIG_DIR/.credentials.json    # mode 0600
```

Structure:

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt": 1234567890,
    "scopes": ["user:inference", "user:profile"]
  }
}
```

**Security**: The file is unencrypted. Ensure:
- Home directory permissions are restrictive (0700)
- Consider full-disk encryption on the host
- For this architecture, each account's credentials live in a separate
  bind-mounted directory — no cross-contamination

**For Console accounts**: Use `ANTHROPIC_API_KEY` environment variable
(Path B) to avoid credential file management entirely.
**For subscription accounts**: Authenticate inside the container via OAuth
(Path A); credentials stored in bind-mounted state directory.
See [architecture.md](../architecture.md#authentication-strategy).

## cgroups v2 Resource Limits

Most modern distros (Ubuntu 22.04+, Fedora 34+, Debian 12+)
default to cgroups v2.

### Container-Level Limits

```yaml
services:
  claude-a:
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
        reservations:
          cpus: "1"
          memory: 2G
```

Or via `docker run`:

```bash
docker run --cpus=2 --memory=4g claude-code-base
```

### Checking cgroup Version

```bash
# cgroups v2: this file exists
stat /sys/fs/cgroup/cgroup.controllers

# cgroups v1: controller-specific directories exist
ls /sys/fs/cgroup/memory/
```

### Note on Kernel Memory

Kernel memory limits (`--kernel-memory`) are deprecated in cgroups v2
and silently ignored. Do not rely on them.

## Docker Rootless Mode

Rootless mode runs the Docker daemon as a non-root user.
Container escape does not yield host root access.

### Setup

```bash
# Install prerequisites
sudo apt-get install -y uidmap dbus-user-session

# Install rootless Docker
dockerd-rootless-setuptool.sh install

# Verify
docker context use rootless
docker info | grep -i root
```

### Impact on This Architecture

| Aspect | Rootless | Rootful (default) |
|--------|---------|-------------------|
| Security | Higher | Standard |
| Bind mount permissions | Requires matching UIDs | Same |
| Privileged ports (<1024) | Cannot bind | Can bind |
| Networking | slirp4netns (slight overhead) | Bridge (native) |
| Complexity | Higher | Lower |

**Recommendation**: Use rootful Docker for development workstations.
Consider rootless for shared servers or CI environments.

## Installation

### APT (Recommended for Debian/Ubuntu)

```bash
# Add Docker repository
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc

# Install
sudo apt-get install docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Add user to docker group
sudo usermod -aG docker $USER
```

### Storage Path

- Images and containers: `/var/lib/docker/`
- Volumes: `/var/lib/docker/volumes/`
- overlay2 layers: `/var/lib/docker/overlay2/`

Monitor disk usage:

```bash
docker system df
docker system df -v   # Verbose
```

## Known Issues with Claude Code on Linux

### 1. Installation Hangs at Root

Installing Claude Code with `WORKDIR /` causes a full filesystem scan.

**Fix**: Set `WORKDIR /app` or `/tmp` before `npm install -g`.

### 2. Background Process Kill Crashes (GitHub #16135)

Killing a background process (`k` key or autonomous) crashes Claude Code
with exit code 137. The agent and spawned processes share a process group.

**Workaround**: Avoid killing background processes manually.

### 3. MCP Container Cleanup

Docker containers spawned by MCP servers persist after Claude Code exits.

**Fix**: Use `docker run --rm` in MCP config, or run periodic cleanup:

```bash
docker container prune -f
```

### 4. 4 GB RAM Minimum

Claude Code requires at least 4 GB available RAM (NODE_OPTIONS heap).

**For low-memory systems**:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

## Sources

- [Docker Engine Installation — Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Rootless Mode](https://docs.docker.com/engine/security/rootless/)
- [OverlayFS Storage Driver](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
- [Bind Mounts — SELinux Labels](https://docs.docker.com/engine/storage/bind-mounts/#configure-the-selinux-label)
- [User Namespace Remapping](https://docs.docker.com/engine/security/userns-remap/)
- [Resource Constraints](https://docs.docker.com/engine/containers/resource_constraints/)
- [Claude Code Troubleshooting](https://code.claude.com/docs/en/troubleshooting)
- [GitHub #16135 — Background process crash](https://github.com/anthropics/claude-code/issues/16135)
