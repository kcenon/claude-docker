# macOS Docker Performance — Reference

macOS-specific considerations for running Docker containers,
focusing on file sharing performance and bind mount behavior.

## Architecture: Docker Desktop on macOS

Docker Desktop runs a lightweight Linux VM via Apple Virtualization Framework.
Containers execute inside the VM, not natively on macOS.

```
macOS Host
└── Apple Virtualization Framework
    └── Linux VM (Docker Engine)
        ├── overlay2 storage (native ext4)
        ├── Named volumes (native ext4, fast)
        └── Bind mounts (cross VM boundary, slower)
```

The VM boundary is the primary source of performance overhead.

## File Sharing Drivers

### VirtioFS (Default, Recommended)

- Default on Docker Desktop 4.6+ (2022)
- Uses shared memory for host-VM file transfers
- **Up to 98% faster** than legacy osxfs
- Still ~3x slower than native Linux for bind mounts

### gRPC FUSE (Legacy Alternative)

- Previous-generation driver
- 2-3x slower than VirtioFS
- Known issues: incomplete file content, broken filesystem events
- **Not recommended** for new setups

### osxfs (Deprecated)

- Original file sharing implementation
- Significantly slower than both alternatives
- Only exists on very old Docker Desktop versions

### Synchronized File Shares (Docker Desktop Pro)

- Paid feature, available in Docker Desktop Pro
- Creates a synchronized ext4 cache inside the VM
- ~59% faster than standard VirtioFS for bind mounts
- Best for large codebases (100,000+ files)
- Limit: ~2 million files per share
- Trade-off: initialization time on first sync

### Performance Comparison

| Driver | Relative Speed | Notes |
|--------|---------------|-------|
| Native Linux | 1.0x (baseline) | No VM overhead |
| VirtioFS | ~0.3x | Default, good enough for most |
| Synchronized File Shares | ~0.5x | Paid, best macOS option |
| gRPC FUSE | ~0.1x | Avoid |
| osxfs | ~0.05x | Deprecated |

## Practical Impact on This Project

### Bind Mounts (Source Code)

Source code bind mounts cross the VM boundary on every file operation.
For a typical project (<10,000 files), VirtioFS performs acceptably.

**Optimization**: For large projects, consider:
- Synchronized File Shares (if Docker Desktop Pro)
- OrbStack as a Docker Desktop alternative (~4x faster file sharing)

### Named Volumes (Dependencies)

Named volumes live inside the VM's ext4 filesystem.
No VM boundary crossing = near-native performance.

**Recommendation**: Store `node_modules` in a named volume:

```yaml
services:
  claude-a:
    volumes:
      - ${PROJECT_DIR}:/workspace                # Bind mount (source)
      - node_modules_a:/workspace/node_modules   # Named volume (fast)

volumes:
  node_modules_a:
```

### Account State Directories

The `~/.claude-state/` bind mounts are tiny and rarely accessed.
Performance is not a concern here.

## Docker Desktop Configuration

### Verify File Sharing Driver

Docker Desktop → Settings → General → "Choose file sharing implementation"

Ensure **VirtioFS** is selected (or grpc FUSE if VirtioFS unavailable).

### Resource Allocation

Docker Desktop → Settings → Resources:

| Resource | Recommended for 2 Containers |
|----------|----------------------------|
| CPUs | 4+ |
| Memory | 8 GB minimum (4 GB per container) |
| Disk | 20 GB (image + volumes) |

### File Sharing Paths

Docker Desktop → Settings → Resources → File sharing

Verify that the following paths are shared:
- Home directory (`/Users/<username>`)
- Project directory (if outside home)

Modern Docker Desktop with VirtioFS shares everything under `/Users`
by default.

## Alternatives to Docker Desktop

### OrbStack

- Drop-in Docker Desktop replacement for macOS
- ~4x faster file sharing than Docker Desktop VirtioFS
- Lower memory footprint
- Free for personal use
- [orbstack.dev](https://orbstack.dev)

### Lima + nerdctl

- Open-source Linux VM manager for macOS
- Uses containerd instead of Docker daemon
- Performance similar to Docker Desktop with VirtioFS
- More complex setup

### Colima

- Open-source Docker runtime for macOS/Linux
- Wraps Lima with Docker/containerd support
- Simpler than bare Lima
- Performance varies by configuration

## Troubleshooting

### Slow File Operations in Container

1. Check file sharing driver (VirtioFS vs gRPC FUSE)
2. Move `node_modules` to a named volume
3. Reduce bind mount scope (mount specific dirs, not entire home)
4. Consider OrbStack if performance is critical

### "Operation not permitted" on Bind Mount

1. Check Docker Desktop file sharing settings
2. Verify host directory permissions
3. Check if macOS privacy settings block Docker access
   (System Settings → Privacy & Security → Files and Folders)

### High Disk Usage

```bash
# Check Docker disk usage
docker system df

# Remove unused images, containers, volumes
docker system prune

# Remove only dangling images
docker image prune

# Remove unused volumes (CAUTION: deletes data)
docker volume prune
```

## Sources

- [Docker Desktop Settings — Docker Docs](https://docs.docker.com/desktop/settings-and-maintenance/settings/)
- [VirtioFS in Docker Desktop 4.6 — Docker Blog](https://www.docker.com/blog/speed-boost-achievement-unlocked-on-docker-desktop-4-6-for-mac/)
- [Synchronized File Shares — Docker Docs](https://docs.docker.com/desktop/features/synchronized-file-sharing/)
- [Docker on macOS Performance — Paolo Mainardi](https://www.paolomainardi.com/posts/docker-performance-macos-2025/)
- [Docker on macOS Slow — CNCF](https://www.cncf.io/blog/2023/02/02/docker-on-macos-is-slow-and-how-to-fix-it/)
- [Fast Container Filesystems — OrbStack](https://orbstack.dev/blog/fast-filesystem)
