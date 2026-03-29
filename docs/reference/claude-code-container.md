# Claude Code in Containers — Reference

Technical reference for running Claude Code inside Docker containers.

## Official DevContainer

Anthropic maintains a reference DevContainer in the
[anthropics/claude-code](https://github.com/anthropics/claude-code) repository.

**Key files:**

| File | Purpose |
|------|---------|
| `.devcontainer/Dockerfile` | Node 20 base, Claude Code via npm, dev tools |
| `.devcontainer/devcontainer.json` | VS Code integration, capabilities, volumes |
| `.devcontainer/init-firewall.sh` | iptables-based outbound whitelist |

### Dockerfile Highlights

```dockerfile
# Base: Node.js 20 slim (NOT Alpine — musl causes linker errors)
FROM node:20-slim

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Dev tools: git, fzf, zsh, jq, nano, vim, gh, git-delta
# Network tools: iptables, ipset, iproute2, dnsutils

# Non-root user: node
# Memory: NODE_OPTIONS=--max-old-space-size=4096
```

### Docker Capabilities (Optional — for Firewall Only)

The following capabilities are needed only if using the `init-firewall.sh`
outbound whitelist script. Claude Code itself runs without them.

```yaml
cap_add:
  - NET_ADMIN   # Firewall management (iptables)
  - NET_RAW     # Raw socket access for networking
```

### Container Requirements

| Requirement | Detail |
|-------------|--------|
| TTY | Must have pseudo-terminal (`stdin_open: true`, `tty: true`) |
| Node.js | v20 (for npm install method) |
| Shell | bash or zsh |
| Memory | 4 GB heap minimum (NODE_OPTIONS) |
| WORKDIR | Must NOT be `/` (causes full filesystem scan during install) |

**Alpine Linux is NOT supported** — Claude Code's native binaries
require glibc, which Alpine's musl cannot provide.

## Directory Structure

### User-Level (~/.claude/)

```
~/.claude/
├── .credentials.json      # OAuth tokens (Linux/container; macOS uses Keychain)
├── settings.json          # Global user settings
├── settings.local.json    # Machine-local settings
├── CLAUDE.md              # Persistent user-level memory
├── history.jsonl          # Interaction history
├── statsig/               # Feature flags
├── projects/              # Per-project session transcripts
├── plans/                 # Plan mode documents
├── todos/                 # Task lists
├── commands/              # Custom slash commands
├── skills/                # Custom skills
├── debug/                 # Debug logs
├── ide/                   # IDE integration locks
└── keybindings.json       # Keyboard shortcuts
```

### Project-Level (.claude/)

```
project/.claude/
├── settings.json          # Team-shared project settings (committed)
└── settings.local.json    # Personal project settings (gitignored)
```

### What to Mount per Account

For minimal account separation, mount only `~/.claude/`:

| Path | Shared or Separate | Reason |
|------|-------------------|--------|
| `~/.claude/` | **Separate** | Contains credentials, settings, history |
| Project source | **Shared** (or worktree) | The code being worked on |
| `node_modules/` | Shared (via image) or named volume | Build dependencies |

The `CLAUDE_CONFIG_DIR` environment variable overrides the default
`~/.claude/` path, allowing each container to point to its own state.

## Authentication

### Method Precedence (first match wins)

1. Cloud provider env vars (`CLAUDE_CODE_USE_BEDROCK`, `_VERTEX`, `_FOUNDRY`)
2. `ANTHROPIC_AUTH_TOKEN` — sent as `Authorization: Bearer`
3. `ANTHROPIC_API_KEY` — sent as `X-Api-Key`
4. `apiKeyHelper` — shell script returning a key dynamically
5. OAuth subscription — credentials in `$CLAUDE_CONFIG_DIR/.credentials.json`

### Two Primary Paths for Containers

| | Subscription (Pro/Max/Team) | Console API Key |
|---|---|---|
| Method | Container-internal OAuth → credentials in bind-mounted state dir | `ANTHROPIC_API_KEY` env var |
| Browser | Once per account, opened from container via forwarded URL | Never |
| Container config | Mount `~/.claude-state/account-X` | Set env var in `.env` |

**Subscription accounts**: Bind-mount the state directory into the
container, then authenticate inside the container with
`claude auth login`. The container forwards the OAuth URL to the
host browser; credentials are written to the bind-mounted state
directory and persist across container restarts.

**Console API keys**: Set `ANTHROPIC_API_KEY` in `.env`. Takes
precedence over any OAuth credentials in the mounted state directory.

See [architecture.md](../architecture.md#authentication-strategy) for
step-by-step setup instructions.

### Credential Storage by Platform

| Platform | Location | Security |
|----------|----------|----------|
| macOS (host) | Keychain | OS-level encryption |
| Linux (host / container) | `$CLAUDE_CONFIG_DIR/.credentials.json` | File mode 0600 |
| Windows (WSL2) | `$CLAUDE_CONFIG_DIR/.credentials.json` | File mode 0600 |

### OAuth Token Persistence

Credential file structure after successful OAuth:

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

**Token lifecycle**:
- `accessToken` expires at the `expiresAt` timestamp
- Claude Code automatically uses `refreshToken` to obtain a new `accessToken`
- Refresh works silently as long as the container has network access to `api.anthropic.com`
- Full re-authentication is needed only on password change or account revocation

**Why container-internal OAuth with bind mount is correct**:

On macOS, host-side `claude auth login` stores tokens in the macOS
Keychain — which cannot be shared with a container. Running OAuth
inside the container instead writes `.credentials.json` to the
bind-mounted state directory, making tokens portable and persistent.

| Issue | Container OAuth (no bind mount) | Container OAuth + bind mount |
|-------|-------------------------------|------------------------------|
| #34917 — Headless redirect fails | **Not affected** — container forwards OAuth URL to host browser | **Not affected** — same mechanism |
| #22066 / #1736 — Token lost on restart | **Affected** — credential written inside ephemeral layer | **Mitigated** — credential file lives on host via bind mount |

**Recovery when tokens expire beyond refresh**:

```bash
# Inside the container
claude auth login
# Credentials are written to the bind-mounted state directory automatically
```

If Claude Code is already running in the container, restart it to reload
the credential file (`docker compose restart claude-a`).

## Known Container Issues

### OAuth Fails Headless (GitHub #34917)

- "Redirect URI not supported by client" error
- Browser-based flow incompatible with headless Docker
- **Fix**: Container OAuth works because the container forwards the OAuth URL to the host browser

### OAuth Not Persisting (GitHub #22066, #1736)

- OAuth succeeds on first run but credentials vanish on container restart
- **Root cause**: Credential file not loaded on subsequent starts
- **Fix**: Container-internal auth writes to bind-mounted state dir, persisting across restarts

### Console Login Fails in DevContainers (GitHub #14528)

- Anthropic Console auth broken in VS Code DevContainers
- **Fix**: Use API key or container-internal Claude.ai OAuth with bind mount

### Installation Hangs at Root (/)

- Installing from WORKDIR `/` causes a full filesystem scan
- Excessive memory usage and process hang
- **Fix**: Set `WORKDIR /app` or any non-root directory before `npm install`

### Interactive Commands Unsupported (GitHub #26353)

- Claude Code's shell tool has no TTY for interactive input
- Commands like `vim`, `git rebase -i`, `npm init` will hang
- **Workaround**: Use non-interactive alternatives (`git rebase --onto`)

### Docker Socket — NEVER Mount

```yaml
# DANGER — DO NOT DO THIS
volumes:
  - /var/run/docker.sock:/var/run/docker.sock  # Privilege escalation risk
```

Mounting the Docker socket allows the container to spawn privileged containers
on the host, leading to full root access. Use Docker-in-Docker (dind) if
container management is needed, but prefer avoiding it entirely.

## Firewall Configuration

The official DevContainer includes `init-firewall.sh` which sets up:

```
Default policy: DENY all outbound
Allowed:
  - DNS (port 53)
  - SSH (port 22)
  - npm registry (registry.npmjs.org)
  - GitHub (github.com, api.github.com)
  - Claude API (api.anthropic.com)
  - Custom whitelist entries
```

This is optional but recommended for security-sensitive environments.

## Sources

- [Development containers — Claude Code Docs](https://code.claude.com/docs/en/devcontainer)
- [Authentication — Claude Code Docs](https://code.claude.com/docs/en/authentication)
- [Claude Code Settings — Claude Code Docs](https://code.claude.com/docs/en/settings)
- [Official Dockerfile](https://github.com/anthropics/claude-code/blob/main/.devcontainer/Dockerfile)
- [GitHub Issue #22066](https://github.com/anthropics/claude-code/issues/22066) — OAuth persistence
- [GitHub Issue #34917](https://github.com/anthropics/claude-code/issues/34917) — Headless OAuth
- [GitHub Issue #1736](https://github.com/anthropics/claude-code/issues/1736) — Re-auth on restart
- [GitHub Issue #14528](https://github.com/anthropics/claude-code/issues/14528) — Console login in DevContainer
- [GitHub Issue #26353](https://github.com/anthropics/claude-code/issues/26353) — Interactive TTY
