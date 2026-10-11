# Compose Files, State and Timezone

Where account state persists, how the generated compose files are configured
and regenerated, and how the container timezone is set.

## State and Memory Persistence

State is preserved across container restarts through bind mounts and named
volumes. The selected runtime determines the account and host-config paths:

| Runtime | Account state on host | Container state | Read-only host config mount |
|---------|-----------------------|-----------------|-----------------------------|
| Claude | `~/.claude-state/account-a/` | `/home/node/.claude/` | `~/.claude/` -> `/home/node/.claude-host/` |
| Codex | `~/.codex-state/account-a/` | `/home/node/.codex/` | `~/.codex/` -> `/home/node/.codex-host/` |
| Gemini | `~/.gemini-state/account-a/` | `/home/node/.gemini/` | `~/.gemini/` -> `/home/node/.gemini-host/` |

Mutable credentials, sessions, logs, and runtime history stay in the account
state mount. When the bootstrap modules **copy or link** host configuration into
that account state directory, they select specific entries and leave known
credential and session files out of the selection.

That exclusion is about what gets copied. It is not a statement about what the
container can reach, and the two are different:

> **The host config mount is the whole directory.** `docker-compose.yml` binds
> `${HOME}/.claude` (and the codex/gemini equivalents) entire, not the six
> entries the entrypoint consumes. Inside it are the runtime's OAuth credential
> file — `.credentials.json`, `auth.json`, `oauth_creds.json` by runtime — and
> `projects/`, the session transcripts. The container runs as the host user, so
> the file's `0600` does not withhold it: **every account container can read
> the host's credentials and transcripts, and therefore each other's.** The
> mount is read-only, so nothing can be written back through it.
>
> `ISOLATION_MODE=isolated` is the only mode that removes the mount. See
> [`docs/ISOLATION.md`](ISOLATION.md#interaction-with-the-shared-runtime-configuration-mount).

Do not embed secrets in the selected configuration either — it is visible to the
container by the same route. Other persistent mounts are:

| Data | Host/source | Container destination | Mode |
|------|-------------|-----------------------|------|
| GitHub CLI config (shared mode only) | `${GH_CONFIG_DIR}` or the platform default | `/home/node/.config/gh/` | Read-only |
| `node_modules` | Named volume `node_modules_<suffix>` | `${CONTAINER_PROJECT_DIR:-/project}/node_modules/` | Read-write |
| Project files (Tier A) | `${PROJECT_DIR}` | `${CONTAINER_PROJECT_DIR:-/project}` | Read-write |
| Project files (Tier B, account A example) | `${PROJECT_DIR_A}` | `${CONTAINER_PROJECT_DIR_A:-/project-a}` | Read-write |

## Compose Overrides

All compose files are **generated** by `scripts/generate-compose.sh` (or `.ps1`)
based on `NUM_ACCOUNTS`, resolved as described under
[`NUM_ACCOUNTS` precedence](#num_accounts-precedence) below. Do not edit them
manually.

They are nonetheless **tracked in Git** as the committed source of truth, so
what is committed has to match generator output. The committed copies represent
the generator defaults with no `.env` present and none of these set in the
environment:

| Setting | Value | Source |
|---------|-------|--------|
| `NUM_ACCOUNTS` | `2` | `scripts/generate-compose.sh` default |
| `AGENT_RUNTIME` | `claude` | `scripts/lib/runtime.sh` default |
| `IMAGE_TAG` | contents of `VERSION` | repo-root `VERSION` file |
| `ISOLATION_MODE` | `shared` | `scripts/lib/isolation.sh` default |

The `Compose files are current` CI job regenerates under exactly those defaults
and fails on any difference. Regenerating with your own `.env` during local work
is expected, but do not commit the result — restore the committed copies first:

```bash
git checkout -- docker-compose.yml docker-compose.linux.yml docker-compose.worktree.yml docker-compose.isolated.yml
```

### `NUM_ACCOUNTS` precedence

Every shell-side reader resolves `NUM_ACCOUNTS` the same way: **an exported
environment variable wins, then `.env`, then the built-in default of `2`.** This
is the rule `scripts/lib/parse_env.sh` documents for `load_env_file`, and the one
`AGENT_RUNTIME` has always followed in both languages.

| Reader | Decides |
|--------|---------|
| `scripts/generate-compose.sh`, `scripts/generate-compose.ps1` | how many services get written |
| `get_num_accounts` in `scripts/claude-docker` | which services the CLI acts on |
| `Get-NumAccounts` in `scripts/ClaudeDocker.psm1` | the same, on Windows |

The first source holding a **non-empty** value wins even if that value is
unusable: an exported `NUM_ACCOUNTS=abc` does not fall through to `.env`. What
happens next differs by layer on purpose. The generators abort, because they
write files that CI then checks. The CLI wrappers warn and fall back to `2`,
because listing the default pair beats refusing to print a service list. This
applies to non-numeric values and integers outside the supported `1..702`
range, so the wrappers never enumerate a topology the generators would reject.

The TUI dashboard sits outside this rule by design. `Env.NumAccounts()` in
`tui/internal/config/env.go` reads `.env` alone, because `Env` is the document
the TUI edits and writes back, and it treats the value as a floor rather than an
exact count. Missing or unusable values start from the generator default of `2`,
and `discoverStateDirs` raises that floor to cover any account state directory
it finds on disk.

`tests/test_num_accounts_precedence.sh` pins all four shell-side readers to the
table above and runs in the `Bash Tests` CI matrix.

### Overlay files

| File | Purpose | When active |
|------|---------|-------------|
| `docker-compose.yml` | Base config (Tier A), incl. `user: ${UID:-1000}:${GID:-1000}` and `HOME=/home/node` | Always |
| `docker-compose.linux.yml` | Legacy UID/GID + HOME override (kept for backward compat; base already carries it) | Optional |
| `docker-compose.worktree.yml` | Per-container worktree paths | `ISOLATION_MODE=worktree` only |
| `docker-compose.isolated.yml` | Per-container independent clone, hardened container profile (`read_only`, `cap_drop: ALL`, no-new-privileges, PID limit), per-account bridge, `environment: !override` | `ISOLATION_MODE=isolated` only |

The worktree and isolated overlays are mutually exclusive: both replace the
volume list with `!override` and they disagree on `working_dir`, so composing
them together is not "the widest set" but a broken stack. All four files are
generated in every mode; the resolved mode decides which one is selected.

On native Linux, set `UID` / `GID` in `.env` (or export them before running
`docker compose up`) to match the host user that owns the selected runtime's
state root. The interactive bash installer does this automatically **on native
Linux only**: `scripts/install.sh` classifies WSL2 as its own platform, not as
`linux`, so a WSL2 install writes no `UID`/`GID` at all and you have to add
them yourself:

```bash
printf 'UID=%s\nGID=%s\n' "$(id -u)" "$(id -g)" >> .env
```

Without matching IDs, bind-mounted paths such as `~/.claude-state/account-a/`
are not writable from inside the container, producing errors like
`hook: /home/node/.claude/hooks/<name>.sh: not found` (failure to stat
under non-matching UID) and Bash tool failures caused by the harness
being unable to create `session-env/` subdirectories.

To regenerate after editing `.env`:
```bash
scripts/generate-compose.sh
```

The `scripts/claude-docker` CLI auto-detects which overlays to apply.

## Timezone

Containers match the host's IANA timezone so `date`, Node.js `Date` objects,
and hook timestamps render the same wall-clock time the host shows.

`scripts/install.sh` / `install.ps1` auto-detect the host zone and write
`TZ=<IANA>` to `.env`. Compose files forward the value as `TZ=${TZ:-UTC}`,
so leaving `TZ` unset keeps containers on UTC.

To change zones on an existing install, append or edit the line in `.env`
and restart:

```bash
echo 'TZ=Asia/Seoul' >> .env
scripts/claude-docker down && scripts/claude-docker up
```
