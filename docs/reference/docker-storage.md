# Docker Storage Optimization — Reference

How Docker manages storage, and how to minimize disk usage
when running multiple containers from the same image.

## Image Layer Sharing

### How It Works

Docker images are composed of stacked read-only layers.
When multiple containers run from the same image, they share
every read-only layer — stored once on disk.

```
Container A          Container B
┌──────────────┐    ┌──────────────┐
│ Writable      │    │ Writable      │   ← Separate (thin)
│ Layer (~10MB) │    │ Layer (~10MB) │
├──────────────┤    ├──────────────┤
│              Shared Image Layers              │
│  Layer 4: Claude Code + npm cache (~300MB)    │   ← Stored ONCE
│  Layer 3: Dev tools (git, gh, etc.) (~100MB)  │
│  Layer 2: Node.js 20 (~300MB)                 │
│  Layer 1: Debian slim (~80MB)                 │
└───────────────────────────────────────────────┘
```

### Copy-on-Write (CoW)

When a container modifies a file from an image layer:

1. File is **copied** from read-only layer to writable layer
2. Modification is applied to the copy
3. Original layer remains untouched and shared
4. Subsequent reads/writes go to the writable copy

Deletions create "whiteout" markers — the file appears gone
in the container but the image layer is unchanged.

### Storage Arithmetic

| Scenario | Storage Used |
|----------|-------------|
| 1 container from 800 MB image | ~800 MB + writable layer |
| 2 containers from same image | ~800 MB + 2 writable layers |
| 10 containers from same image | ~800 MB + 10 writable layers |
| 2 containers from different 800 MB images | ~1600 MB + 2 writable layers |

**Key rule**: Same image = shared layers. Different images = no sharing
(unless they share common base layers, which are also deduplicated).

## overlay2 Storage Driver

### Architecture

overlay2 is the default storage driver on modern Docker installations.

```
Container mount (merged view)
    ↑
┌───┴───────────────────┐
│  upperdir (writable)  │  ← Container's changes
├───────────────────────┤
│  lowerdir (read-only) │  ← Image layers (up to 128)
└───────────────────────┘
```

- Operates at **file level** (not block level)
- Shared page cache: identical files read by multiple containers
  use the same kernel page cache entries → memory efficient
- Up to 128 lower layers natively supported

### Performance Characteristics

| Operation | Performance |
|-----------|------------|
| Read from image layer | Fast (direct read, shared page cache) |
| First write (copy-up) | Slower (copies entire file to upper) |
| Subsequent writes | Fast (writes to upper directly) |
| Delete | Fast (whiteout marker) |
| Lookup in deep layers | Slight overhead (searches multiple layers) |

### On macOS (Docker Desktop)

Docker Desktop runs a Linux VM. overlay2 operates inside the VM.
The host-to-VM file transfer adds overhead for bind mounts
(see [macos-docker.md](macos-docker.md)).

## Bind Mount vs Named Volume

### Comparison

| Feature | Bind Mount | Named Volume |
|---------|-----------|-------------|
| Source | Host filesystem path | Docker-managed storage |
| Performance (macOS) | ~3x slower than native | Near-native (inside VM) |
| Host access | Direct (read files from host) | Not directly accessible |
| Portability | Host-path dependent | Works on any Docker host |
| Use case | Source code, config files | Dependencies, databases, caches |
| Cleanup | Manual | `docker volume rm` |

### When to Use Each

**Bind mount** — for files you need to edit on the host:
- Project source code
- Configuration files
- Account state directories

**Named volume** — for files that stay inside containers:
- `node_modules/` (avoids macOS file-sharing overhead)
- Build caches
- Package manager caches (npm, pip)

### Docker Compose Syntax

```yaml
services:
  app:
    volumes:
      # Bind mount (host path : container path)
      - ${HOME}/project:/workspace

      # Bind mount read-only
      - ${HOME}/project:/workspace:ro

      # Named volume
      - node_modules:/workspace/node_modules

volumes:
  node_modules:  # Docker-managed
```

## Minimizing Image Size

### 1. Choose a Small Base

| Base Image | Size |
|-----------|------|
| Alpine | ~5 MB |
| Debian slim | ~80 MB |
| Ubuntu | ~77 MB |
| Node 20 slim | ~200 MB |
| Node 20 (full) | ~350 MB |

**Note**: Claude Code requires glibc (Debian-based), not musl (Alpine).
Use `node:20-slim`, not `node:20-alpine`.

### 2. Combine RUN Commands

```dockerfile
# Bad: 3 layers
RUN apt-get update
RUN apt-get install -y git
RUN rm -rf /var/lib/apt/lists/*

# Good: 1 layer
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
```

### 3. Clean Package Manager Caches

```dockerfile
RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force
```

### 4. Multi-Stage Builds (General Technique)

Multi-stage builds separate build-time dependencies from runtime.
Example for a generic Node.js app:

```dockerfile
FROM node:20 AS builder
WORKDIR /build
COPY package*.json ./
RUN npm ci

FROM node:20-slim
COPY --from=builder /build/node_modules ./node_modules
COPY . .
```

> **Claude Code caveat**: Claude Code's npm global install creates
> symlinks and may include native binaries with additional dependencies.
> A simple two-path COPY may not capture everything. For Claude Code,
> prefer a single-stage Dockerfile with cache cleanup (see #3 above)
> over multi-stage. Test thoroughly if attempting multi-stage.

### 5. Use .dockerignore

```
.git
node_modules
dist
build
*.log
.env
.claude/
```

## Git Worktree Storage Efficiency

Git worktrees provide an alternative to full clones
for running multiple working directories from one repository.

### How It Works

```
~/work/project/          (main worktree)
├── .git/                ← Object database (all commits, blobs, trees)
│   └── objects/         ← ~200 MB for a typical project
├── src/                 ← Checked-out files ~100 MB
└── ...

~/work/project-a/        (linked worktree)
├── .git                 ← File (not directory!) pointing to main .git
├── src/                 ← Checked-out files ~100 MB (separate copy)
└── ...
```

### Storage Comparison

| Approach | Git Objects | Working Files | Total (2 instances) |
|----------|------------|--------------|-------------------|
| 2 full clones | 200 MB × 2 | 100 MB × 2 | **600 MB** |
| 1 repo + 1 worktree | 200 MB × 1 | 100 MB × 2 | **400 MB** |
| 1 bind mount (Tier A) | 200 MB × 1 | 100 MB × 1 | **300 MB** |

Savings scale with repository size and number of instances.

### Setup

```bash
cd ~/work/project
git worktree add ../project-a branch-a
git worktree add ../project-b branch-b
```

### Cleanup

```bash
git worktree remove ../project-a
git worktree remove ../project-b
```

### Trade-offs

| Pro | Con |
|-----|-----|
| Shared object database saves space | Operations on shared refs affect all worktrees |
| Independent branches per worktree | Each worktree needs own node_modules if versions differ |
| No `.git/index.lock` contention | Cannot check out the same branch in two worktrees |
| Full concurrent read/write safety | Slightly more setup than a single bind mount |

## Sources

- [Storage Drivers — Docker Docs](https://docs.docker.com/engine/storage/drivers/)
- [OverlayFS Storage Driver — Docker Docs](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
- [Understanding Image Layers — Docker Docs](https://docs.docker.com/get-started/docker-concepts/building-images/understanding-image-layers/)
- [Bind Mounts — Docker Docs](https://docs.docker.com/engine/storage/bind-mounts/)
- [Volumes — Docker Docs](https://docs.docker.com/engine/storage/volumes/)
- [Build Best Practices — Docker Docs](https://docs.docker.com/build/building/best-practices/)
- [Reduce Docker Image Size — DevOpsCube](https://devopscube.com/reduce-docker-image-size/)
- [Git Worktree — Pro Git](https://git-scm.com/docs/git-worktree)
- [Git Worktree Disk Space — gitcheatsheet.dev](https://gitcheatsheet.dev/docs/advanced/worktrees/disk-space-management/)
