# Authentication

Each container keeps its own runtime credentials in its account state
directory. This page covers choosing OAuth or an API key for Claude Code,
authenticating inside containers, and GitHub CLI identities.

## Choosing OAuth or an API key

Choose **OAuth** (subscription) or **API key** (Anthropic Console):

| You have... | Host OS | Use |
|-------------|---------|-----|
| Claude.ai Pro / Max / Team subscription | Linux / WSL2 | **OAuth** |
| Claude.ai Pro / Max / Team subscription | macOS | **OAuth** inside container; fall back to API key if Keychain errors appear |
| Anthropic Console account only | any | **API key** |
| Mix of both | any | **Per-container**: set `CLAUDE_API_KEY_<LETTER>` only for API-key slots — others fall back to OAuth |

**OAuth** — authenticate inside each container after starting:

```bash
scripts/claude-docker claude claude-a
# Inside container: claude auth login
```

Container-internal OAuth may fail on macOS due to Docker network
boundary limitations. If it does, switch the affected account to API key.

**API key** — add to `.env`:

```bash
CLAUDE_API_KEY_A=sk-ant-...
CLAUDE_API_KEY_B=sk-ant-...
```

Re-run `scripts/generate-compose.sh` after editing so the generator emits
`ANTHROPIC_API_KEY` only for slots that actually have a key (see
[Switching between OAuth and API key](#authenticating-inside-containers) below).

## Authenticating inside containers

Authenticate directly inside each container. Each container keeps its own
credentials in its bind-mounted state directory, so you run this once per
account.

```bash
# Authenticate inside a specific container
scripts/claude-docker exec claude-a claude auth login

# Check status in any container
scripts/claude-docker exec claude-a claude auth status
```

If container-internal OAuth fails on macOS due to Docker network boundary
limitations, switch to API keys in `.env`.

> **Switching between OAuth and API key**: After editing `CLAUDE_API_KEY_*`
> in `.env`, re-run `scripts/generate-compose.sh` (or `.ps1`) and
> `docker compose up -d` so the generated compose files reflect the new
> state. `ANTHROPIC_API_KEY` is only injected into a container when the
> matching `CLAUDE_API_KEY_<LETTER>` is set at generate time — emitting
> it with an empty string would otherwise make the SDK ignore the
> `.credentials.json` from OAuth.

## GitHub CLI

**GitHub CLI (`gh`)** is automatically available inside containers. Shared
authentication remains the default: all services receive the same `GH_TOKEN`,
and the host's `GH_CONFIG_DIR` is mounted read-only as a Linux fallback. On
Windows and macOS, `gh` normally stores tokens in the OS credential store,
which the Linux container cannot read, so importing `GH_TOKEN` is required.

To isolate GitHub identities by container, configure every account explicitly:

```dotenv
GH_AUTH_MODE=per-account

GH_USER_A=github-login-a
GH_TOKEN_A=...
GH_USER_B=github-login-b
GH_TOKEN_B=...

# Optional commit identity overrides; global values remain the fallback.
GIT_USER_NAME_A=Account A Name
GIT_USER_EMAIL_A=account-a@example.com
```

Per-account mode has fail-closed behavior:

- both `GH_USER_<LETTER>` and `GH_TOKEN_<LETTER>` are required through the
  configured `NUM_ACCOUNTS` range (`A` through `ZZ`);
- each service receives only its matching token as the standard in-container
  `GH_TOKEN` variable, never the global token as a fallback;
- the shared `GH_CONFIG_DIR` mount is omitted, so one service cannot read a
  different account's `hosts.yml` credential; and
- startup, update, and the TUI compare `gh api user --jq .login` with the
  configured login and show the actual login or a distinct mismatch.

Import a named account already stored by the host `gh` CLI without changing
which host account is active:

```bash
# Bash / macOS / Linux
scripts/claude-docker gh-auth a --user github-login-a
scripts/claude-docker gh-auth claude-b --user github-login-b
scripts/claude-docker gh-auth --all

# Windows PowerShell equivalents
.\scripts\claude-docker.ps1 gh-auth a --user github-login-a
.\scripts\claude-docker.ps1 gh-auth --all
```

The targeted form recreates only that service when it is running. `--all` and
`update` retrieve each token with
`gh auth token --hostname github.com --user <login>`; they never call
`gh auth switch`. The TUI's `g` action applies the same operation to the
selected row.

To migrate an existing installation, add the per-account mappings, set
`GH_AUTH_MODE=per-account`, regenerate compose files, then recreate services:

```bash
scripts/generate-compose.sh       # use generate-compose.ps1 on Windows
scripts/claude-docker up --force-recreate
```

Rotate a single credential by re-authenticating that login on the host and
running targeted `gh-auth`; rotate all configured mappings with
`gh-auth --all`. Tokens remain plaintext in the host `.env`, which is
permission-hardened but should still be backed up, retained, and rotated as a
secret.

This feature covers `gh` and **HTTPS Git operations only** through `gh auth
setup-git`; it does not isolate SSH keys or SSH agents. It protects accounts
from other account containers by removing shared credential sources, but not
from host administrators or anyone with Docker daemon access, who can inspect
container environments.

Verify auth with `gh api user` (which checks the credential `gh` actually uses
for API calls) rather than `gh auth status`:

```bash
# Verify gh auth inside container
scripts/claude-docker exec claude-a gh api user --jq .login

# Use gh normally
scripts/claude-docker exec claude-a gh pr list
```
