# Agent Runtimes

Claude Code is the default runtime. This page covers the opt-in OpenAI Codex
CLI and Google Gemini CLI runtimes, and what adding another runtime takes. The
runtime is selected with `AGENT_RUNTIME` in `.env`.

## Running OpenAI Codex CLI

Codex support is opt-in. Set `AGENT_RUNTIME=codex` in `.env`, then regenerate
compose files and recreate containers:

```bash
scripts/generate-compose.sh
scripts/claude-docker up --remove-orphans
scripts/claude-docker codex
```

PowerShell users can run `.\scripts\generate-compose.ps1` and
`.\scripts\claude-docker.ps1 codex` instead.

When `AGENT_RUNTIME=codex` is active, generated services are named
`codex-a`, `codex-b`, and so on. Each account stores mutable Codex state in
`~/.codex-state/account-*/`, while host-managed Codex config is mounted
read-only from `~/.codex/` and copied or linked into `CODEX_HOME` without
importing `auth.json`, sessions, caches, or logs. Codex skills are mounted
from `${AGENTS_SKILLS_DIR}` or `~/.agents/skills`.

For API-key based Codex sessions, set per-account keys such as
`CODEX_API_KEY_A`; the generator injects `OPENAI_API_KEY` only for accounts
that have a non-empty key. The `codex` wrapper starts the CLI with
`cli_auth_credentials_store="file"` so container logins persist in the
account state bind mount.

The TUI can list and attach to Codex services. Claude-specific usage
aggregation and `scripts/claude-docker usage` remain Claude-only.

## Running Google Gemini CLI

Gemini support is opt-in. Set `AGENT_RUNTIME=gemini` in `.env`, then
regenerate compose files and recreate containers:

```bash
scripts/generate-compose.sh
scripts/claude-docker up --remove-orphans
scripts/claude-docker gemini
```

PowerShell users can run `.\scripts\generate-compose.ps1` and
`.\scripts\claude-docker.ps1 gemini` instead.

When `AGENT_RUNTIME=gemini` is active, generated services are named
`gemini-a`, `gemini-b`, and so on. Each account stores mutable Gemini state
in `~/.gemini-state/account-*/`, while host-managed Gemini config is mounted
read-only from `~/.gemini/` and linked into the container's Gemini config
directory. `settings.json`, `GEMINI.md`, `commands/`, and `extensions/` are
linked; OAuth credentials, sessions, and logs stay in the writable account
state directory.

Gemini CLI stores its user-level configuration and cached authentication under
`~/.gemini/`, with `GEMINI_CLI_HOME` selecting the parent directory. The host
OAuth cache is intentionally not linked into a container: `oauth_creds.json`,
`google_accounts.json`, sessions, and logs remain in that account's writable
`~/.gemini-state/account-*/` mount. To use **Sign in with Google**, start
Gemini inside each account container and complete the interactive flow there;
the resulting state persists for that account. See the official
[Gemini CLI authentication guide](https://geminicli.com/docs/get-started/authentication/).

For headless environments or when the browser flow cannot return to the
container, use per-account API keys such as `GEMINI_API_KEY_A`. The generator
injects `GEMINI_API_KEY` only for accounts that have a non-empty key.

The TUI can list and attach to Gemini services; usage columns show `--`.
Claude-specific usage aggregation and `scripts/claude-docker usage` remain
Claude-only.

### Gemini verification coverage

The Gemini runtime is exercised by CI rather than resting on a one-time manual
check. What each layer proves:

| Step | Covered by | Needs a key or a terminal |
|------|------------|---------------------------|
| `generate-compose` emits a valid gemini compose file | `compose-validate (gemini)` job | no |
| `claude-docker up` brings `gemini-a` to a stable running state | `Gemini up/down smoke` job | no |
| `claude-docker gemini` resolves to `exec gemini-a gemini` | `tests/test_agent_attach_argv.sh` | no |
| the resolved binary runs inside the container | `gemini --version` step of the smoke job | no |
| the TUI discovers accounts under `~/.gemini-state/account-*` | `TestDiscoverStateDirs_GeminiRuntime` | no |
| the TUI dashboard renders those accounts on screen | Go tests in `tui/internal/ui/dashboard` | no |
| an authenticated `gemini -p` round-trip inside the container | key-gated CI check | yes, a `GEMINI_API_KEY` repository secret |

The key-gated check is inert until the repository owner configures a
`GEMINI_API_KEY` secret; without it the job emits a notice and passes, so a
green run is not by itself evidence that authenticated access works.

## Adding a runtime

The runtime registry centralizes service names, paths, environment variables,
and TUI behavior, but it is **not** a package manager. A registry entry and a
bootstrap module alone do not install a new executable in the image. Add a
runtime with this checklist:

1. **Add a complete registry entry.** Append an object under `runtimes` in
   `tui/internal/config/runtimes.json`, keyed by the runtime name, and populate
   every field used by the existing entries. Go, bash, PowerShell, and the
   container entrypoint all read this file.

   | Field group | Used for |
   |-------------|----------|
   | `binary`, `displayName`, `servicePrefix` | CLI dispatch, labels, and Compose service names |
   | `stateDir`, `containerHome`, `hostConfigMount`, `containerConfigMount` | Per-account state and host-config mounts |
   | `configDirEnv`, `configDirEnvValue`, `configSourceEnv` | Runtime-specific configuration discovery |
   | `apiKeyVarPrefix`, `sdkApiKeyVar` | Per-account API-key mapping |
   | `buildArg` | Build argument emitted by the Compose generators; the Dockerfile must also declare and use it |
   | `bootstrapModule` | Module sourced by `entrypoint.sh` |
   | `skipPermissionsFlag`, `extraRunArgs`, `supportsUsage`, `mountsAgentsSkills` | CLI and TUI capabilities |
   | `credentialFiles`, `oauthCredentialFile` | Permission hardening and authentication detection |

   `installMethod` is descriptive metadata today; no code dynamically installs
   a package from this value.

2. **Install the runtime in `Dockerfile`.** Add the package or native installer
   that provides the registry's `binary`. If the runtime supports a version
   pin, declare and consume the same argument named by `buildArg`.

3. **Add a bootstrap module.** Create `scripts/lib/bootstrap-<runtime>.sh`
   matching `bootstrapModule`. It must expose `runtime_bootstrap`; shared
   copy/link helpers live in `scripts/lib/bootstrap-common.sh`.

4. **Audit installer and authentication assumptions.** Registry-driven service
   naming, Compose generation, state creation, removal, and cleanup work
   automatically. The installers still include Claude-specific version/config
   prompts and verify authentication with `<binary> auth status`; add explicit
   handling when the new CLI uses a different contract.

5. **Add verification and documentation.** At minimum, add a Compose fixture,
   bash/PowerShell generator-equivalence coverage, attach-argv coverage, and Go
   tests for runtime parsing, account discovery, and dashboard rendering. Add
   a keyless smoke test and a separate key-gated check when authenticated
   behavior cannot be exercised without a secret.
