# Usage

Details for the commands summarized in the README quick reference.

## Starting and Stopping

```bash
scripts/claude-docker up        # Start all containers
scripts/claude-docker down      # Stop (state preserved via bind mounts)
scripts/claude-docker restart   # Restart
scripts/claude-docker ps        # Check status
```

## Running Claude Code

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

## Running Commands Inside Containers

```bash
# Open a shell
scripts/claude-docker exec claude-a

# Run a one-off command
scripts/claude-docker exec claude-a git status
scripts/claude-docker exec claude-a claude --version
```

## Using Git Inside Containers

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

## Token Usage Reports

View aggregated token usage across all container accounts using
[ccusage](https://github.com/ryoppippi/ccusage). Runs on the host (not
inside containers) and requires Node.js/npx.

```bash
scripts/claude-docker usage                                  # Daily (default)
scripts/claude-docker usage monthly                          # Monthly
scripts/claude-docker usage daily --since 20260301 --json    # Date filter + JSON
```

## Multi-account dashboard (TUI)

A Bubble Tea-based terminal dashboard shows each service's container status,
authentication status, GitHub login (including mismatches), and Claude's
5-hour/7-day usage gauges and reset times when data is available. In per-account
GitHub mode, the `g` action refreshes only the selected account and recreates
only that service when it is running.

Build with **Go 1.24+**, then launch from the repository root:

```bash
scripts/claude-docker build-tui      # Build from source (requires Go 1.24+)
scripts/claude-docker tui            # Launch dashboard
scripts/claude-docker dashboard      # Alias of tui
```

On native Windows, use PowerShell 7+:

```powershell
.\scripts\claude-docker.ps1 build-tui
.\scripts\claude-docker.ps1 tui
```

The wrappers launch the local `tui/claude-docker-tui` binary (`.exe` on Windows)
and tell you to run `build-tui` when it is missing. They do not download a
prebuilt binary.

Claude usage comes from Anthropic's usage API and the limitline cache beside
each account's state. Missing Claude usage data displays `--`, or `API limited`
after rate limiting. Codex and Gemini usage columns display `--`. The dashboard
does not read JSONL session files; see [`docs/PERFORMANCE.md`](PERFORMANCE.md)
for measured dashboard behavior.

## Rebuilding the Image

```bash
scripts/claude-docker build --no-cache                # Rebuild all installed agent CLIs
scripts/claude-docker up --force-recreate             # Recreate containers
scripts/claude-docker update                          # Perform both steps and refresh gh credentials
```

`update` refreshes the configured shared or per-account GitHub token(s) from
the host when `gh` is available, then runs a no-cache build and force-recreates
the containers. Use `.\scripts\claude-docker.ps1 update` on native Windows.

## Cleanup and Removal

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
