# MCP Bridge -- Architecture and Tool Reference

The MCP (Model Context Protocol) Bridge exposes Docker orchestration
functionality as native tools within a Claude Code session. Instead of
switching terminals to run `scripts/claude-docker dispatch` or `docker exec`,
you invoke tools directly from the conversation.

## Architecture

```
┌──────────────────────────────────────────────────┐
│ Claude Code (host session)                       │
│  ├─ Native tools (Read, Edit, Bash, Agent, ...)  │
│  └─ MCP: claude-docker                           │
│       ├─ delegate(account, prompt, model)         │
│       ├─ analyze(prompt, timeout)                 │
│       ├─ dispatch(worker, prompt, timeout)        │
│       ├─ accounts()                               │
│       ├─ findings(category?, sessionId?)          │
│       ├─ sessions()                               │
│       ├─ status(worker?)                          │
│       └─ budget()                                 │
└──────────────────┬───────────────────────────────┘
                   │ stdio
┌──────────────────┴───────────────────────────────┐
│ mcp-bridge-server.js (host process, Node.js)     │
│  ├─ Anthropic SDK (api-key accounts)             │
│  ├─ docker exec (OAuth accounts)                 │
│  ├─ Redis client (findings, worker status)       │
│  └─ Filesystem (session archives)                │
└──────────────────┬───────────────────────────────┘
          ┌────────┴────────┐
          │ Docker layer    │
          │ ├─ Redis        │
          │ ├─ Manager      │
          │ ├─ Worker 1-3   │
          │ └─ claude-a/b   │
          └─────────────────┘
```

### How It Works

1. Claude Code starts `mcp-bridge-server.js` as a child process (stdio transport).
2. The server reads account credentials from environment variables and
   `~/.claude-state/` OAuth files at startup.
3. Tool calls route through one of two paths:
   - **SDK path** -- API key accounts call the Anthropic API directly from the host.
   - **Docker path** -- OAuth accounts execute `docker exec <container> claude -p`.
4. Redis queries (findings, status) connect to `127.0.0.1:6379`, which requires
   the MCP overlay (`docker-compose.mcp.yml`) to be active.

### Smart Routing

The `delegate` tool uses smart routing to pick the fastest execution path:

| Account Type | Primary Path | Fallback |
|--------------|-------------|----------|
| API key | Anthropic SDK (supports model selection) | `docker exec` |
| OAuth | `docker exec` only | -- |

If the SDK call fails (rate limit, network error), API key accounts
automatically fall back to `docker exec` on the account's container.

## Prerequisites

- Docker containers running (`scripts/claude-docker up`)
- Orchestration enabled (Redis + workers in `docker-compose.orchestration.yml`)
- `MCP_BRIDGE=yes` in `.env` (exposes Redis on `127.0.0.1:6379`)
- Node.js dependencies installed (`npm install` in project root)
- At least one account configured (API key in `.env` or OAuth in `~/.claude-state/`)

## Setup

### 1. Enable the MCP overlay

Add to `.env`:

```bash
MCP_BRIDGE=yes
```

This activates `docker-compose.mcp.yml`, which exposes Redis on
`127.0.0.1:6379` (localhost only -- not accessible from the network).

### 2. Install dependencies

```bash
cd /path/to/claude-docker
npm install
```

### 3. Restart containers

```bash
scripts/claude-docker down
scripts/claude-docker up
```

### 4. Verify

Start Claude Code from the project directory. The `.mcp.json` file is
auto-discovered, and the MCP tools appear in the tool list.

```bash
claude
# Inside Claude Code:
# /mcp   -- should show "claude-docker" server with 8 tools
```

## Tool Reference

### delegate

Run a prompt on a specified account.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `account` | string | yes | Account name: `manager`, `a`, `b`, `worker-1`, `worker-2`, `worker-3` |
| `prompt` | string | yes | Prompt to send |
| `model` | string | no | Model ID (default: `claude-sonnet-4-20250514`). Only effective for API key accounts via SDK path. |

**Example input:**

```json
{
  "account": "b",
  "prompt": "Review this function for security issues:\n\nfunction login(user, pass) { ... }",
  "model": "claude-sonnet-4-20250514"
}
```

**Example output:**

```text
The function has several security concerns:
1. Password is not hashed before comparison...
```

**Routing behavior:**
- API key account: tries Anthropic SDK first (honors `model`), falls back to `docker exec`.
- OAuth account: always uses `docker exec` (ignores `model`).

---

### analyze

Run multi-persona parallel analysis across all three worker personas
(Sentinel, Reviewer, Profiler).

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `prompt` | string | yes | Analysis prompt |
| `timeout` | number | no | Timeout in seconds, 1-3600 (default: 300) |

**Example input:**

```json
{
  "prompt": "Evaluate production readiness of the authentication module",
  "timeout": 600
}
```

**Example output:**

```text
=== Analysis Results ===
Time elapsed: 45s

[SECURITY] Sentinel found 3 issues:
  - HIGH: JWT secret stored in plaintext config
  - MEDIUM: No rate limiting on login endpoint
  - LOW: Session token entropy below recommended 128 bits

[QUALITY] Reviewer found 2 issues:
  - MEDIUM: Duplicate validation logic in login/register
  - LOW: Dead code in legacy auth adapter

[PERFORMANCE] Profiler found 1 issue:
  - MEDIUM: Synchronous bcrypt in request handler blocks event loop
```

**Notes:**
- Executes via `docker exec` into the manager container, which calls
  `run_analysis()` from `manager-helpers.sh`.
- The manager dispatches to all three workers in parallel.
- Results are stored in Redis and saved to cold storage automatically.

---

### dispatch

Send a task to a specific worker.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `worker` | string | yes | Worker name: `worker-1`, `worker-2`, `worker-3` |
| `prompt` | string | yes | Task prompt |
| `timeout` | number | no | Timeout in seconds, 1-3600 (default: 300) |

**Example input:**

```json
{
  "worker": "worker-1",
  "prompt": "Check the /scripts directory for hardcoded secrets or credentials"
}
```

**Example output:**

```json
{
  "taskId": "t_abc123",
  "status": "dispatched",
  "output": "Task dispatched to worker-1..."
}
```

**Worker personas:**

| Worker | Persona | Focus Area |
|--------|---------|------------|
| `worker-1` | Sentinel (Security Analyst) | Vulnerabilities, secrets, injection, auth |
| `worker-2` | Reviewer (Code Quality Engineer) | Dead code, duplication, SOLID, complexity |
| `worker-3` | Profiler (Performance Engineer) | N+1 queries, blocking I/O, memory, bundle size |

---

### accounts

List all configured accounts and their routing status.

**Parameters:** None.

**Example output:**

```json
[
  {
    "name": "manager",
    "type": "configured",
    "routing": "sdk",
    "status": "running"
  },
  {
    "name": "a",
    "type": "configured",
    "routing": "docker-exec",
    "status": "running"
  },
  {
    "name": "worker-1",
    "type": "configured",
    "routing": "sdk",
    "status": "running"
  }
]
```

**Fields:**
- `routing: "sdk"` -- API key configured, calls go via Anthropic SDK.
- `routing: "docker-exec"` -- OAuth credentials only, calls go via `docker exec`.
- `status` -- `running` if the container appears in `docker compose ps`, otherwise `stopped`.

---

### findings

Query analysis findings from live Redis or an archived session.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `category` | string | no | Filter: `security`, `quality`, `performance` |
| `sessionId` | string | no | Load from archive instead of live Redis |

**Example input (live):**

```json
{
  "category": "security"
}
```

**Example input (archived):**

```json
{
  "sessionId": "20260328T143000Z_a1b2c3d4"
}
```

**Example output:**

```json
[
  {
    "category": "security",
    "severity": "HIGH",
    "title": "JWT secret in plaintext",
    "details": "Config file contains unhashed JWT signing key..."
  }
]
```

**Notes:**
- Without `sessionId`, reads from Redis key `findings:{category}` (or `findings:all`).
- With `sessionId`, reads from `~/.claude-state/analysis-archive/sessions/{id}/findings.json`.
- Session IDs are validated against path traversal.

---

### sessions

List archived analysis sessions.

**Parameters:** None.

**Example output:**

```json
[
  {
    "id": "20260328T143000Z_a1b2c3d4",
    "timestamp": "2026-03-28T14:35:00Z",
    "findingsCount": 6,
    "categories": ["security", "quality", "performance"]
  },
  {
    "id": "20260327T090000Z_e5f6g7h8",
    "timestamp": "2026-03-27T09:12:00Z",
    "findingsCount": 4,
    "categories": ["security", "quality"]
  }
]
```

**Notes:**
- Reads from `~/.claude-state/analysis-archive/sessions/index.json`
  (or `~/.claude-state/analysis-archive/index.json` as fallback).
- Maximum 50 sessions retained; oldest pruned automatically.

---

### status

Show worker health and activity status from Redis.

**Parameters:**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `worker` | string | no | Specific worker (omit for all three) |

**Example input:**

```json
{
  "worker": "worker-1"
}
```

**Example output:**

```json
[
  {
    "name": "worker-1",
    "state": "idle",
    "lastTask": "Check auth module for SQL injection",
    "timestamp": "2026-03-28T14:30:00Z"
  }
]
```

**States:**
- `idle` -- Worker is ready for new tasks.
- `busy` -- Worker is currently processing a task.
- `offline` -- No status key found in Redis (worker container may be stopped).

**Notes:**
- Reads from Redis key `worker:{name}:status` which stores JSON with 60s TTL.
- Workers update this key periodically while running.

---

### budget

Token usage per account aggregated during the current MCP server session.

**Parameters:** None.

**Example output:**

```json
{
  "accounts": [
    {
      "name": "manager",
      "type": "configured",
      "inputTokens": 12500,
      "outputTokens": 8300,
      "calls": 5
    },
    {
      "name": "a",
      "type": "configured",
      "inputTokens": 0,
      "outputTokens": 0,
      "calls": 0
    },
    {
      "name": "worker-1",
      "status": "unavailable"
    }
  ],
  "total": {
    "inputTokens": 12500,
    "outputTokens": 8300
  }
}
```

**Data sources:**
- **API key accounts**: Token counts cached in-memory from each `delegate` SDK call.
  The `calls` field shows how many delegate calls were made this session.
  Accounts with no delegate calls yet show zero counts.
- **OAuth accounts**: Queried via `docker exec <container> claude usage --json`.
  If the container is stopped or the command fails, `status: "unavailable"` is returned.

**Notes:**
- Usage data resets when the MCP server restarts (session-level only).
- For persistent historical tracking, use `scripts/claude-docker usage`.

## Environment Variables

The `.mcp.json` file passes these variables to the bridge server:

| Variable | Purpose | Default |
|----------|---------|---------|
| `REDIS_HOST` | Redis hostname | `127.0.0.1` |
| `REDIS_PORT` | Redis port | `6379` |
| `REDIS_PASSWORD` | Redis authentication password | (empty) |
| `ARCHIVE_DIR` | Session archive directory | `~/.claude-state/analysis-archive` |
| `DOCKER_COMPOSE_DIR` | Project root for compose commands | `$PWD` |
| `CLAUDE_API_KEY_MANAGER` | API key for manager account | -- |
| `CLAUDE_API_KEY_A` | API key for account A | -- |
| `CLAUDE_API_KEY_B` | API key for account B | -- |
| `CLAUDE_API_KEY_1` | API key for worker-1 | -- |
| `CLAUDE_API_KEY_2` | API key for worker-2 | -- |
| `CLAUDE_API_KEY_3` | API key for worker-3 | -- |

API key variables are optional. Accounts without an API key fall back to OAuth
credential detection in `~/.claude-state/<account>/`.

## Security

- **Redis binding**: `docker-compose.mcp.yml` binds Redis to `127.0.0.1` only.
  External hosts cannot reach port 6379.
- **Opt-in activation**: The MCP overlay is only loaded when `MCP_BRIDGE=yes`
  is set in `.env`. Redis is not exposed by default.
- **Timeout validation**: All timeout parameters are parsed with `parseInt()`
  and clamped to 1-3600 seconds.
- **Path traversal protection**: The `findings` tool validates `sessionId`
  using `path.resolve()` + `startsWith()` to prevent directory escape.
- **Shell injection prevention**: All subprocess calls use `execFile` (not
  `exec`), which does not spawn a shell.
- **API key isolation**: Keys are passed via environment variables, never
  logged or included in error messages.

## Troubleshooting

### MCP server not detected

Verify `.mcp.json` exists in the project root and contains the
`claude-docker` entry. Restart Claude Code after adding the file.

```bash
# Check the file
cat .mcp.json
```

### "Redis connection refused"

The MCP overlay is not active. Verify:

```bash
# Check .env has MCP_BRIDGE=yes
grep MCP_BRIDGE .env

# Verify Redis port is exposed
docker compose ps redis
docker compose port redis 6379
```

If Redis is running but the port is not mapped, restart with the overlay:

```bash
scripts/claude-docker down
echo "MCP_BRIDGE=yes" >> .env
scripts/claude-docker up
```

### "Unknown account: ..."

The account has no API key and no OAuth credentials. Check:

```bash
# API key configured?
grep CLAUDE_API_KEY .env

# OAuth credentials present?
ls ~/.claude-state/account-*/. credentials.json
```

### delegate returns error for model selection

Model selection only works for API key accounts (SDK path). OAuth accounts
ignore the `model` parameter and use the default model configured in the
container's Claude Code instance.

### analyze times out

Increase the timeout (default 300s). Large codebases may need 600-900s:

```json
{ "prompt": "full analysis", "timeout": 900 }
```

Also verify all worker containers are running:

```bash
scripts/claude-docker ps
```

### Stale worker status shows "offline"

Worker status keys in Redis have a 60-second TTL. If a worker was recently
restarted, wait for it to update its status. Check container health:

```bash
scripts/claude-docker ps
scripts/claude-docker logs worker-1 --tail 20
```
