# Troubleshooting

Symptoms and fixes for common problems, one entry per symptom.

**"Authentication expired" inside container:**

```bash
scripts/claude-docker exec claude-a claude auth login
```

**Permission denied on bind mount (or `hook: ... not found`, `session-env` write failures):**

On native Linux **and under WSL2**, the container UID/GID must match the owner
of the selected runtime's state root. Add them to `.env` and restart — the base
compose reads these directly, so no extra overlay is required.

This is the usual cause under WSL2 specifically, because `scripts/install.sh`
writes the pair only when it classifies the platform as `linux`, and WSL2 is
classified separately — so a WSL2 install reaches this state by default rather
than by misconfiguration.

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
**not** an NTFS path (`/mnt/c/...`). Microsoft recommends keeping files in the
WSL file system when working from a Linux command line; see
[Working across file systems](https://learn.microsoft.com/en-us/windows/wsl/filesystems#file-storage-and-performance-across-file-systems).

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
to let the container exceed this) and `reservations.memory: 2G`, which
`docker compose` applies as the container's memory reservation: a soft limit
that Docker activates only when it detects contention or low memory on the
host ([Docker's memory options](https://docs.docker.com/engine/containers/resource_constraints/)).
[Resource Requirements](RESOURCES.md) uses `limits` to size Docker Desktop
memory; `reservations` matters only when multiple containers compete for memory.
