# Workspace Isolation and Threat Model

`ISOLATION_MODE` declares the trust boundary a set of agent accounts runs
under. This document states what each mode does and does not protect against,
so a boundary is chosen deliberately rather than inferred from which compose
file happened to be passed.

Status: workspace/network profiles, resolved boundary checks, sandbox refusal,
resource reports and transactional scaling are implemented. Local regression,
Compose-model and TUI benchmark evidence is recorded in
[ISSUE-335-VALIDATION.md](ISSUE-335-VALIDATION.md). Linux live-container and full
45-sample performance evidence, plus native Windows policy/ACL CI, are recorded.
Authenticated workflows, Desktop/rootless platform runs and budget review remain
required before issue #335 can be closed. The host, daemon owner and kernel/runtime compromise remain outside
this boundary.

## Modes

| Mode | Workspace boundary | Use it for |
|---|---|---|
| `shared` (default) | Every account bind-mounts `PROJECT_DIR` read-write at `/project`. | Mutually trusted accounts collaborating on one tree. |
| `worktree` | Each account mounts only its own git worktree. Git metadata is still shared. | Concurrent branches with fewer lock and wrong-tree collisions. |
| `isolated` | Each account mounts its own independent clone, with its own git metadata and no shared host configuration. | Accounts that must not read or modify each other's source. |

### Setting up `isolated`

```bash
scripts/setup-isolated.sh --dry-run /path/to/repo 2
scripts/setup-isolated.sh /path/to/repo 2
# Windows: .\scripts\setup-isolated.ps1 -RepoDir C:\Projects\repo -AccountCount 2 -DryRun
```

The preview lists every clone, state path, mount, network and resource budget.
It does not change destinations, installation files, credentials or Docker
resources. Daemon discovery is read-only and bounded; missing capacity is shown
as unknown. Apply uses the same plan after validating all destinations.

Fresh clones are staged beside the source, created with
`git clone --no-hardlinks --dissociate`, and verified before publication.
Dissociation is necessary when the source itself borrows objects. The Git/common
directories must remain internal, with no alternates, symlinked object stores or
hardlinked objects. Existing destinations are verified before reuse; unsafe
repositories are refused and preserved. No untracked files or host configuration
are copied. A failed publication removes only this setup's new destinations.

The clones' `origin` is repointed at the source repository's own upstream,
because the source path is deliberately not mounted into an isolated container.
An http(s) credential embedded in that URL is stripped rather than copied into
every clone.

Regenerate compose afterwards; `ISOLATION_MODE=isolated` without
`ISOLATED_WORKSPACE_<X>` for every account is refused, not guessed.

Optional keys tune the isolated profile:
`ISOLATED_NETWORK_MODE` (`bridge` by default, or `none` for an offline
profile — see [Network policy](#network-policy)) `ISOLATED_PIDS_LIMIT` and the scratch limits below.
Changing either means regenerating: they select what the generator writes, not
what Compose interpolates at start time.

### Resolution

Every layer — bash, PowerShell, the Go TUI, the CLI, the installers — resolves
the mode the same way:

1. `ISOLATION_MODE` in the caller's environment.
2. `ISOLATION_MODE` in `.env`.
3. **Legacy inference**: a configured `PROJECT_DIR_A` means `worktree`.
   Installations predating this key configured Tier B by setting that variable
   alone, and compose overlay selection used to key off it directly. The
   inference is what keeps those installations behaving unchanged.
4. `shared`.

There is deliberately **no** matching inference from `ISOLATED_WORKSPACE_A`.
Nothing predates that key, so setting it without declaring the mode is a
mistake worth reporting rather than a legacy layout worth honoring — and
inferring a *stronger* boundary than the one asked for is its own surprise.

An explicit mode outranks the inference. Configuring `PROJECT_DIR_A` while
declaring `ISOLATION_MODE=shared` is honored as shared, and a warning names the
per-account paths that are consequently inert — an ignored setting is reported,
never silently dropped. The same warning covers `ISOLATED_WORKSPACE_A` under a
mode that ignores it.

An unrecognized value is refused, and so is a mode whose per-account workspace
paths are not configured. Neither degrades to `shared`: running a weaker
boundary than the one that was asked for is the failure this contract exists to
prevent.

## What each mode protects against

The adversary model for `isolated` is an agent running an unsafe or malicious
command **inside a normal container** — a wrong `rm -rf`, a prompt-injected
tool call, a compromised dependency's postinstall script.

| Concern | `shared` | `worktree` | `isolated` |
|---|---|---|---|
| Account A edits account B's working tree | No | Yes | Yes |
| Account A reads account B's working tree | No | Yes | Yes |
| Account A rewrites shared git history (`.git`) | No | **No** | Yes |
| Account A reads the shared host configuration, including the runtime credential file and `projects/` transcripts (see [the mount section](#interaction-with-the-shared-runtime-configuration-mount)) | No | No | Yes |
| Container root filesystem is read-only | No | No | Yes |
| Capabilities dropped and privilege escalation blocked | No | No | Yes |
| Account A holds account B's GitHub credential | No | No | Yes |
| Account A connects to account B over the network | No | No | Yes |
| Account A reaches the internet | No | No | **No**, unless `ISOLATED_NETWORK_MODE=none` |
| Container escape to the host | No | No | **No** |

"No" means the mode does not defend against it.

Two rows are worth reading twice. **Egress is not restricted** by default: each
account is on its own bridge, which stops A from reaching B, not from reaching
anything outside. Restricting what a container may talk to is a proxy or
firewall concern, and `ISOLATED_NETWORK_MODE=none` is the only lever this
document offers — it removes all network access rather than filtering it. And
**container escape is still out of the model**: the hardened profile raises the
cost of one, but a kernel or runtime vulnerability defeats it, so `isolated` is
not a substitute for a VM boundary when the workload is genuinely untrusted.

### Why `worktree` is a concurrency tier, not a sandbox

Git worktrees share one object store and one administrative directory. An
account with a worktree can still reach the common `.git` — it can read every
branch, rewrite refs, and delete objects other accounts depend on. Isolating
the *working tree* removes collisions between concurrent branches; it does not
make a hostile account harmless.

Treat `worktree` as the answer to "two agents keep stepping on each other's
checkout", never as the answer to "I do not trust what this agent will run".

## Non-goals

None of these modes defend against:

- a hostile host administrator, or any user with Docker daemon access — the
  daemon can mount any host path into any container;
- a container-runtime or kernel escape;
- physical access to the host;
- a malicious image, or a compromised base image layer;
- egress filtering at the domain level. Network separation in `isolated` scopes
  sibling reachability, not what an account can reach on the internet.

If your threat model includes any of these, a standard container is the wrong
boundary. Use gVisor, Kata Containers, a microVM, or one VM per account.

## Resolved-configuration correctness

Mount claims are asserted against `docker compose config` output, never against
the source YAML. That is not a style preference — it is the lesson of the
defect stage 2 fixes.

`docker-compose.worktree.yml` named only the per-account worktree mount and
read as correct. But Compose merges `volumes` **by container target**, and
`/project-a` is a different target from the base `/project`, so the shared
read-write `PROJECT_DIR` mount survived into every resolved worktree service.
Each account had its worktree *and* full write access to the shared source. A
grep over the overlay would have reported success; only the merged model showed
the extra mount.

The fix tags each overlay volume list with `!override`, which replaces the base
list instead of extending it. Because the list is replaced, the overlay
re-emits every mount the base contributes (runtime state, the read-only host
config mount, and the optional agents/skills and shared `gh` mounts); both
lists are produced by one function in each generator so they cannot drift.

This requires a Compose release that supports the `!override` merge tag
(Docker Compose v2.24.4+ per upstream release notes; `!reset` landed in
v2.24.0). `tests/test_isolation_modes.sh` asserts the resolved model rather
than the tag, so an implementation that silently ignored the tag would fail the
test instead of shipping a false boundary.

## Overlay composition

Compose overlays are applied in this order, and the combination matters:

| Overlay | Applied when | Effect |
|---|---|---|
| `docker-compose.yml` | always | Base services, shared `/project` mount. |
| `docker-compose.linux.yml` | Linux hosts, file present | Overrides the effective user with `${UID}:${GID}`. |
| `docker-compose.worktree.yml` | resolved mode is `worktree` | Replaces each service's volume list with the worktree set. |
| `docker-compose.isolated.yml` | resolved mode is `isolated` | Replaces each service's volume list with the clone-only set, replaces its environment list, and attaches it to a per-account network. |

All four files are generated in every mode. The mode decides which ones a
caller composes together, not which ones exist, so drift checks keep comparing
the same tracked set.

Exactly one mode overlay is ever composed. Composing two would let the later
one replace the volume list again, which is how a boundary could be undone by
an ordering accident rather than a code change.

**The overlay order settles the `user` question.** The base stack declares
`user: "${UID:-1000}:${GID:-1000}"` and `docker-compose.linux.yml` declares
`user: "${UID}:${GID}"` — no defaults, which is the difference that matters
below — and the mode overlay is appended **after** both, so an isolated stack
could override the field outright; Compose lets a later `-f` win. It
deliberately does not; see
[Why the host user, not `node`](#why-the-host-user-not-node).

Because the Linux overlay has no fallback, composing it with `UID`/`GID` unset
resolves to `user: ":"` and the daemon rejects the project. Nothing that goes
through `scripts/claude-docker` can hit that — `build_compose_cmd` exports both
variables itself before invoking Compose — but a raw `docker compose -f ... -f
docker-compose.linux.yml` invocation can, and `scripts/install.sh` writes the
pair into `.env` only when it classifies the platform as `linux`. **WSL2 is
classified as `wsl2`, so a WSL2 install has no `UID`/`GID` in `.env`.** Add them
by hand if you invoke Compose directly there:

```bash
printf 'UID=%s\nGID=%s\n' "$(id -u)" "$(id -g)" >> .env
```

## The hardened container profile

`isolated` services run under a restricted profile. Every field below is
asserted against the resolved model in `tests/test_isolation_modes.sh` rather
than against the overlay, because the base stack contributes fields of its own
and only the merged project shows which value wins.

| Field | Value | What it bounds |
|---|---|---|
| `read_only` | `true` | Writes anywhere outside the declared mounts, including the image's own tooling. |
| `cap_drop` | `[ALL]` | Every Linux capability, including the ones an agent workload never uses. |
| `security_opt` | `no-new-privileges:true` | A setuid binary raising privileges after start. |
| `init` | `true` | Orphaned processes accumulating as zombies under PID 1. |
| `deploy.resources.limits.pids` | `${ISOLATED_PIDS_LIMIT:-1024}` | A fork loop exhausting the host process table. |

The PID cap lives under `deploy.resources.limits`, not the legacy top-level
`pids_limit` key. The base stack already declares `deploy.resources.limits`
(cpus, memory); Compose treats the two spellings as one setting and rejects the
merged project outright when both appear. The default is chosen to leave
headroom for parallel compilers and test runners, not from measurement —
measured budgets are stage 5.

### Why the host user, not `node`

Issue #335 asks isolated services to run as "the existing non-root `node`
user". The profile keeps the host user's uid/gid instead, and the tests assert
the property the acceptance criterion actually names: the effective user is not
uid 0.

Pinning uid 1000 would break the reason the base stack declares `user` at all.
The per-account state directory is a host bind mount; on a Linux host whose user
is not uid 1000 it would become unwritable, and that directory is also what the
TUI reads. The alternatives cost more than they buy — `chown`ing the host
directories at setup mutates paths the user and the dashboard share, and moving
state into a named volume blinds account discovery.

### Writable paths under a read-only root

`read_only: true` makes the image layers unwritable, so every path the
entrypoint or the toolchain writes to needs a mount of its own. The account's
workspace, runtime state and `node_modules` already are mounts. The rest are
bounded tmpfs:

| Path | Written by |
|---|---|
| `/tmp` | general tool scratch |
| `/home/node/.config` | `bootstrap-claude.sh`, creating the ccstatusline XDG link |
| `/home/node/.cache` | generic tool caches |
| `/home/node/.npm` | npm |
| `/home/node/.agents` | `bootstrap-codex.sh` / `bootstrap-gemini.sh` |

`/home/node/.local` is deliberately **absent**: the agent CLI is installed there
and is on `PATH`, so a tmpfs would hide the binary. A test asserts its absence,
because "add one more tmpfs" is the obvious wrong fix for a future write error
in that tree.

Each tmpfs is mounted `uid=${UID:-1000},gid=${GID:-1000},mode=0700` to match the
service's own identity. Without those options Docker mounts a tmpfs root-owned
with mode 1777 — writable, but world-writable, which is not what this profile
should be shipping. `/tmp` keeps the conventional 1777 and its sticky bit,
because tools expect a shared scratch there.

### The global git config

`$HOME` stays on the read-only root, so `git config --global` and
`gh auth setup-git` cannot write `~/.gitconfig`. The profile therefore sets
`GIT_CONFIG_GLOBAL=/home/node/.claude/gitconfig`, inside the per-account state
mount, which is writable and already account-private.

This is worth stating explicitly because the failure it prevents is silent. The
entrypoint wraps `gh auth setup-git` in `2>/dev/null || true`, so without the
redirect the container starts normally, prints its "authenticated as ..."
banner, and only fails later at `git push` — with no credential helper and no
diagnostic explaining why.

## Credential scoping

An isolated service receives **no shared GitHub credential**. Under the default
`GH_AUTH_MODE`, the base stack hands every service the same `GH_TOKEN`; that
token names one GitHub account, so passing it to each isolated service would
have left the boundary decorative on the one surface carrying write access to
remote repositories.

Two configurations are therefore supported, and nothing in between:

| `GH_AUTH_MODE` | What an isolated service receives |
|---|---|
| `per-account` (from #331) | Its own `GH_TOKEN_<X>` and `GH_USER_<X>`. Each account authenticates as itself. |
| anything else | No GitHub credential. `gh` reports unauthenticated; `git push` to a remote needing auth fails. |

The second row is a deliberate cost. An isolated account that needs to push
should be configured with per-account authentication rather than handed the
shared token — that is what #331 exists for, and this mode reuses its contract
unchanged rather than growing a second mechanism.

Provider API keys were already per-account and are unaffected. The variable you
set in `.env` is `CLAUDE_API_KEY_<X>` (`CODEX_API_KEY_<X>`, `GEMINI_API_KEY_<X>`
for the other runtimes); the generator reads only that prefixed form and emits
the SDK's own name — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` —
into the container. Both halves come from `apiKeyVarPrefix` and `sdkApiKeyVar`
in `tui/internal/config/runtimes.json`. `GIT_USER_NAME` and
`GIT_USER_EMAIL` are still passed through: they are committer identity, they
name the human rather than an account, and an isolated account still has to be
able to commit.

### Why the environment list is replaced wholesale

`docker-compose.isolated.yml` tags each service's environment block
`!override`, exactly as it does the volume list, and therefore re-states every
variable the service needs.

That looks like duplication, and it is — deliberately. Compose merges an
untagged `environment` block **by key**, so the base stack's `GH_TOKEN` entry
survives into the merged service; and Compose offers no way to remove a single
inherited key. `!reset` on an individual environment entry is ignored outright,
which is worse than unsupported: the overlay reads as though it removes the
variable and the resolved model still carries it. Replacing the whole list is
the only mechanism that works.

The property this buys is worth the duplication: anything not listed in the
isolated branch never reaches an isolated service, so a credential added to the
base stack later cannot leak into this profile by being forgotten. Both lists
are emitted by one function in each generator (`emit_account_environment` /
`Get-AccountEnvironmentLines`), so the two cannot silently diverge, and
`tests/test_isolation_modes.sh` asserts on the resolved model in both
directions — that `GH_TOKEN` is gone, and that `HOME`, `AGENT_RUNTIME` and the
rest survived.

## Network policy

`ISOLATED_NETWORK_MODE` selects what an isolated account can reach. It is read
only when `ISOLATION_MODE=isolated`.

| Value | Effect |
|---|---|
| `bridge` (default) | Each account is attached to its own bridge network, `isolated_net_<x>`. |
| `none` | Each account is detached from every network. |

The base stack declares no networks at all, so without this every service lands
on the project-wide implicit `default` bridge and account A can reach account B
by service name. Declaring an explicit network in the overlay **replaces** that
attachment rather than adding to it, which is what makes the separation real.

The bridges are ordinary, not `internal: true`: outbound access to the model
API and to git remotes has to keep working. What per-account bridges buy is
that A and B sit on different ones, so neither appears in the other's DNS and
neither can open a direct connection to it. **Egress allowlisting is not
attempted here** and belongs to a proxy or firewall.

`none` is the offline policy, for workloads that need no external access at
all. It is a different YAML key (`network_mode`) rather than a different value
of `networks`, and Compose rejects a service carrying both, so the policy is
decided when the file is generated rather than interpolated at compose time —
the same shape `NUM_ACCOUNTS` and `GH_AUTH_MODE` already have. **Changing it
means regenerating**, and an unrecognized value is refused rather than
defaulting to `bridge`, because an offline profile that quietly came up
networked produces no other visible symptom.

## Interaction with the shared runtime configuration mount

Every service mounts the host's `~/.claude/` read-only at
`/home/node/.claude-host/`. That contract is documented outside this repository
in [`docs/CLAUDE_DOCKER_CONTRACT.md`](https://github.com/kcenon/claude-config/blob/develop/docs/CLAUDE_DOCKER_CONTRACT.md)
in `kcenon/claude-config`, and the entrypoint depends on its directory layout,
hook command grammar, and settings transform.

**The mount is the whole directory, not the parts the entrypoint reads.**
`bootstrap-claude.sh` consumes a finite list — `hooks/`, `scripts/`, `skills/`,
`commands/`, `ccstatusline/` and `settings.json` — but `docker-compose.yml`
binds `${HOME}/.claude` entire. Two things inside it are worth naming, because
neither is obvious from "shared host configuration":

- the runtime's OAuth credential file — `.credentials.json` for claude,
  `auth.json` for codex, `oauth_creds.json` for gemini;
- `projects/`, which holds session transcripts.

The container runs as the host user (`user: "${UID:-1000}:${GID:-1000}"`), so
the host's own `0600` on the credential file does not withhold it: every
account container can read both, and read each other's by extension. The mount
is read-only, so nothing can be modified through it.

This is a property of `shared` and `worktree` alike — it is a host-home
surface, not a workspace one, which is why the workspace table above does not
capture it. `isolated` is the only mode that removes it, by not creating the
mount at all (`generate-compose.sh` gates it on the mode). Choosing between the
modes therefore includes choosing whether accounts can read one another's
credentials and transcripts.

**As shipped, `isolated` takes the absent-by-default half of that requirement.**
An isolated service receives no `~/.claude` mount, no agents/skills mount and
no shared `gh` config — those are the shared host-home surfaces the mode exists
to remove. Missing shared configuration skips import; account-local sandbox
requirements and writable-path gates still run before the requested command.

What an isolated account gives up, concretely: shared hooks, skills, commands,
statusline and `CLAUDE.md`.

GitHub authentication does **not** survive by default. It travels through the
`GH_TOKEN` environment variable rather than the mounted `gh` config, so the
absent mount alone would not have removed it — the environment override does.
Configure per-account authentication to give an isolated account credentials of
its own; see [Credential scoping](#credential-scoping).

**Still open.** Whether to restore any of the shared configuration through an
explicit allowlisted import — issue #335 offers "copy an explicit allowlist
into a per-account staging directory and reject files classified as
credentials" — is a cross-repository decision, because the consuming side of
the contract lives in `kcenon/claude-config`. It gates that optional import
alone; the requirement it belongs to ("an absent-by-default **or**
account-scoped source") is already met by the absent-by-default half. The
mechanism exists and is wired: `CLAUDE_CONFIG_SOURCE` overrides the config
source path (`scripts/lib/bootstrap-claude.sh`), both generators emit it, and
the installers write it as a commented key. What is undecided is the policy —
which files are safe to copy — not the plumbing.

The read-only mount is unchanged in `shared` and `worktree`.

## Runtime sandbox contract

Every container declares its effective `ISOLATION_MODE`; the mode overlay wins
including when a Linux overlay is present. Isolated Claude settings preserve
sandbox and deny entries while adapting platform-specific hook/statusline
commands. Shared/worktree retain the established settings transformation.

When account, project or managed settings request Claude sandboxing, startup
checks dependencies and executes a bounded bubblewrap probe under the actual
container UID/security policy, even with no shared configuration source. Claude
must be at least 2.1.83, which introduced
[`sandbox.failIfUnavailable`](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#2183).
Successful probing adds hard-failure controls to account settings; unavailable
sandboxing, malformed settings or conflicting weaker settings refuse the
requested command. `CLAUDE_ALLOW_DEGRADED_SETTINGS=1` does not bypass this gate.
No capability, privileged mode, unconfined policy or weaker nested sandbox is
enabled automatically. See [upstream sandbox behavior](https://code.claude.com/docs/en/sandboxing).

The Codex registry marks its combined approval/sandbox bypass flag. CLI and TUI
reject that bypass in isolated mode; ordinary launch and other modes keep their
existing arguments. Approval prompts and sandbox enforcement are separate
controls. Claude's gate is not a claim that every runtime/version offers the
same inner sandbox. Unsupported kernel/runtime combinations must refuse a
requested sandbox. The outer account boundary remains in force.

## Host validation and resource budgets

Python 3.9+ is a host prerequisite. `scripts/lib/lifecycle.py` implements the
shared policy for both shell wrappers; it uses only the standard library. The
TUI starts containers through the same wrapper. Normal `config` and startup
reports use the resolved Compose model and list environment **key names only**.
Raw `compose config` is an advanced pass-through and can expose resolved secrets;
use `config` for diagnostics and reports.

Preflight keeps the installation project name/root and environment snapshot.
It validates every account, rejects UID 0, overlapping bind sources (including
real symlink/Windows aliases at startup), unapproved mounts, shared volumes or
networks, host namespaces, devices and weakened outer policy. Syntactic fixture
checks do not require host paths. Startup requires real workspaces and verifies
Git independence. Configuration sources must be reachable within approved
account-local mounts; the shared host configuration mount is not restored.

Reports show actual per-service and total CPU/memory limits/reservations, heap,
PID caps and scratch sizes. Docker capacity comes from the active daemon,
including Desktop VM limits, with a five-second query bound. Unavailable
capacity is explicitly unknown; aggregate ceilings above it generate a warning.
Ceilings are not steady-state use, reservations are separate, and scratch consumes
the memory cgroup budget rather than additional reserved RAM.

| Scratch path | Setting (MiB) | Provisional default |
|---|---|---|
| `/tmp` | `ISOLATED_TMP_MB` | 256 |
| `/home/node/.config` | `ISOLATED_CONFIG_MB` | 16 |
| `/home/node/.cache` | `ISOLATED_CACHE_MB` | 128 |
| `/home/node/.npm` | `ISOLATED_NPM_MB` | 256 |
| `/home/node/.agents` | `ISOLATED_AGENTS_MB` | 16 |

The total default scratch ceiling is 672 MiB/account. Positive finite settings
are validated before generation; regenerate after changing them. These defaults
remain unchanged: the measured persistent-cache npm profile does not establish
scratch requirements for authenticated agent sessions. `/home/node/.local`
stays visible because it contains the native Claude binary.

Docker initially owns fresh named-volume roots as root. The wrapper initializes
only newly created account dependency volumes with a short offline, read-only
initializer receiving that volume alone, UID 0, zero capabilities and
no-new-privileges. It sets mode 1777 so the account's non-root host UID can write.
No credentials or host binds enter that initializer. The persistent volume is
still exclusive to its account; account services remain non-root. Existing
volume permissions are not broadened. Global Git configuration is stored in
the writable account state in every mode, so arbitrary non-root host UIDs do
not need to write the image-owned `/home/node/.gitconfig`. An entrypoint write probe refuses an
unwritable workspace, runtime state, dependency or scratch path.

Worktree startup prepares `.container-worktree.git` inside account state and
mounts it read-only over the worktree's `.git` file. `/git-common` exposes only
the shared administrative directory. The host worktree gitfile remains intact,
so both host and container Git work on Linux/macOS and Windows path spellings.
A stale generated gitfile is refused with a repair hint. Shared metadata remains
a deliberate trust limitation.

## Scaling, interruption and migration

`scale N` acquires the installation lifecycle lock, snapshots configuration,
generates all four files into protected staging, and resolves/validates them
before publishing any `.env` change or creating final state directories. The
explicit count wins over inherited `NUM_ACCOUNTS`. Atomic replacement applies
per file; the lock protects the set. Changed services are reconciled with
Compose, unchanged services are preserved, and previously stopped services are
not started as a side effect. Scale-down retains account data and volumes.

On failure, prior managed files/modes/ACLs and service configuration are restored.
Only transaction-owned additions are removed; unrelated user/runtime writes and
nonempty account state are retained. Failed compensation is reported separately
from the original failure and retains a protected journal. A dashboard save
also refuses if configuration changed after it was loaded, preserving a
completed CLI scale. Restart the dashboard before retrying that save. Do not delete the
journal or retry through raw Compose. Restore daemon access, then run:

```bash
scripts/claude-docker recover
# Windows: .\scripts\claude-docker.ps1 recover
```

Recovery refuses while the lock owner is alive. Lifecycle wrappers and the TUI
refuse to read an incomplete publication. An interrupted operation is not a
multi-file atomic filesystem operation, and daemon outages can prevent immediate
container compensation.

To migrate into isolated mode:

1. Stop the old stack using its current mode, without `--volumes`.
2. Run isolated setup with `--dry-run`, then apply it. Reconcile any uncommitted
   source changes explicitly; clones contain tracked commits only.
3. Set `ISOLATION_MODE=isolated` and every printed workspace path. Choose matching
   per-account credentials or no GitHub credential. Shared config stays absent;
   optionally place a Linux-native config inside each account state/workspace
   and set the runtime's configuration-source path to that container path.
4. Regenerate with the platform generator and start through `claude-docker up`.
   Inspect the redacted report and run the live harness with disposable fixtures.

To migrate back, stop the isolated stack using the isolated configuration without
removing volumes. Set `ISOLATION_MODE=shared` with `PROJECT_DIR`, or `worktree`
with all worktree paths, regenerate and start. Retain the isolated clone/state
paths until account work is reconciled. Switching modes does not copy commits,
credentials or history between accounts. Worktree gitfiles generated by this
version can be regenerated without editing the host worktree's `.git` file.

## Verification and supported combinations

Generators and host policy support Bash 3.2+ on Linux/macOS/WSL2 and PowerShell 7
on native Windows. The image and runtime gates execute on Linux. Rootless Docker
is an optional daemon choice; no host security setting is changed. Its nested
sandbox capability must be checked under the actual daemon/kernel profile.

Executed and outstanding platforms are listed in
[ISSUE-335-VALIDATION.md](ISSUE-335-VALIDATION.md). Linux workflows and actual
daemon restart recovery have passed CI. macOS/Windows Docker Desktop and rootless
execution still require platform runs. A running sleep service and a successful CLI version
probe are named separately from an authenticated agent session. Live provider
calls and remote authenticated pushes require an opt-in disposable integration
account; no successful unauthenticated probe is presented as authentication.

```bash
bash tests/test_container_isolation.sh --image claude-code-base:TAG --runtime all
bash tests/test_container_isolation.sh --image claude-code-base:TAG --runtime claude --external
python3 tests/test_resolved_boundaries.py
python3 tests/test_lifecycle.py
python3 tests/test_lifecycle_process.py
python3 tests/test_runtime_workflows.py --image claude-code-base:TAG --runtime all --output runtime-workflows.json
python3 tests/test_sandbox_platform.py --image claude-code-base:TAG --output sandbox-platform.json
```

The live harness owns unique projects and literal fixture mounts, verifies
markers in both directions, tests a running sibling listener by name and IP,
uses leak/network mutation controls, checks writable/security/resource paths,
recreation and offline egress, and cleans only its project resources. External
connectivity is a separate test so an outage has a useful diagnosis. The
[workflow guide](ISSUE-335-WORKFLOWS.md) documents actual npm/build/test and
recreation checks, the explicit credential/remote contract, bounded provider
sessions, hook/statusline dispatch and daemon recovery commands. Missing
credentials are reported as skipped; completion validation rejects those skips.
The authenticated profile now checks both account selections through the wrapper
and compiled TUI, using POSIX PTYs or Windows ConPTY. Native process-adapter CI
tests remain separate from live Desktop/WSL2/rootless runtime evidence. The
requested-inner-sandbox scenario must perform authenticated Bash tool work in a
distinct mount namespace; a successful refusal test cannot satisfy that case.

On the measured Linux runner (AppArmor, built-in seccomp, no added capabilities),
the requested sandbox's actual namespace probe is unavailable. Both ordinary and
degraded-settings cases refuse before the requested command executes. This is
verified fail-closed behavior, not a claim that an authenticated inner sandbox
session ran. No privileged or unconfined workaround is used. Full measured
container results and proposed budgets are in [PERFORMANCE.md](PERFORMANCE.md);
maintainer budget acceptance remains pending.
