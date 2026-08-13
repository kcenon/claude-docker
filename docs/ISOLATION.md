# Workspace Isolation and Threat Model

`ISOLATION_MODE` declares the trust boundary a set of agent accounts runs
under. This document states what each mode does and does not protect against,
so a boundary is chosen deliberately rather than inferred from which compose
file happened to be passed.

Status: stages 1 to 3 of issue #335 are implemented, plus the container
hardening half of stage 4. `isolated` isolates the **workspace** — independent
clones, independent git metadata, no shared host configuration — and runs under
a hardened container profile: read-only root filesystem, every capability
dropped, no-new-privileges, an init process and a bounded PID limit. It does
**not** yet scope credentials or the network; that is the rest of stage 4. Read
[What each mode protects against](#what-each-mode-protects-against) before
relying on it, and see [Delivery order](#delivery-order) for what remains.

## Modes

| Mode | Workspace boundary | Use it for |
|---|---|---|
| `shared` (default) | Every account bind-mounts `PROJECT_DIR` read-write at `/project`. | Mutually trusted accounts collaborating on one tree. |
| `worktree` | Each account mounts only its own git worktree. Git metadata is still shared. | Concurrent branches with fewer lock and wrong-tree collisions. |
| `isolated` | Each account mounts its own independent clone, with its own git metadata and no shared host configuration. | Accounts that must not read or modify each other's source. |

### Setting up `isolated`

```bash
scripts/setup-isolated.sh /path/to/repo [account-count]   # or setup-isolated.ps1
```

It creates `<repo>-isolated-<letter>` per account with `git clone
--no-hardlinks` and prints the `.env` keys to add. `--no-hardlinks` is what
makes the clone independent: cloning a local path hardlinks the object store by
default, which would leave every account sharing objects — the property that
disqualifies `worktree` as a boundary.

The clones' `origin` is repointed at the source repository's own upstream,
because the source path is deliberately not mounted into an isolated container.
An http(s) credential embedded in that URL is stripped rather than copied into
every clone.

Regenerate compose afterwards; `ISOLATION_MODE=isolated` without
`ISOLATED_WORKSPACE_<X>` for every account is refused, not guessed.

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

| Concern | `shared` | `worktree` | `isolated` (as shipped) | `isolated` (once credentials/networks land) |
|---|---|---|---|---|
| Account A edits account B's working tree | No | Yes | Yes | Yes |
| Account A reads account B's working tree | No | Yes | Yes | Yes |
| Account A rewrites shared git history (`.git`) | No | **No** | Yes | Yes |
| Account A reads the shared host configuration | No | No | Yes | Yes |
| Container root filesystem is read-only | No | No | Yes | Yes |
| Capabilities dropped and privilege escalation blocked | No | No | Yes | Yes |
| Account A reads account B's credentials | No | No | **No** | Yes |
| Account A reaches account B over the network | No | No | **No** | Yes |
| Container escape to the host | No | No | No | No |

"No" means the mode does not defend against it.

The two `isolated` columns matter. What is shipped is the workspace boundary
(stage 3) and the container profile (the hardening half of stage 4); credential
scoping and per-account networks are the remainder. Until they land `isolated`
is the right choice for "these agents must not touch each other's source" and
"this agent should not be able to write outside its workspace", and the wrong
choice for "these agents must not learn each other's secrets".

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
| `docker-compose.isolated.yml` | resolved mode is `isolated` | Replaces each service's volume list with the clone-only set. |

All four files are generated in every mode. The mode decides which ones a
caller composes together, not which ones exist, so drift checks keep comparing
the same tracked set.

Exactly one mode overlay is ever composed. Composing two would let the later
one replace the volume list again, which is how a boundary could be undone by
an ordering accident rather than a code change.

**The overlay order settles the `user` question.** Both the base stack and
`docker-compose.linux.yml` declare `user: "${UID:-1000}:${GID:-1000}"`, and the
mode overlay is appended **after** both, so an isolated stack could override the
field outright — Compose lets a later `-f` win. It deliberately does not; see
[Why the host user, not `node`](#why-the-host-user-not-node).

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

## Interaction with the shared runtime configuration mount

Every service mounts the host's `~/.claude/` read-only at
`/home/node/.claude-host/`. That contract is documented outside this repository
in [`docs/CLAUDE_DOCKER_CONTRACT.md`](https://github.com/kcenon/claude-config/blob/develop/docs/CLAUDE_DOCKER_CONTRACT.md)
in `kcenon/claude-config`, and the entrypoint depends on its directory layout,
hook command grammar, and settings transform.

**As shipped, `isolated` takes the absent-by-default half of that requirement.**
An isolated service receives no `~/.claude` mount, no agents/skills mount and
no shared `gh` config — those are the shared host-home surfaces the mode exists
to remove. The container still starts: `scripts/lib/bootstrap-claude.sh`
returns early when its config source is missing, so the runtime degrades rather
than failing.

What an isolated account gives up, concretely: shared hooks, skills, commands,
statusline and `CLAUDE.md`. GitHub authentication still works, because it
travels through the `GH_TOKEN` environment variable rather than the mounted
`gh` config.

**Still open for stage 4.** Whether to restore any of that through an explicit
allowlisted import — issue #335 offers "copy an explicit allowlist into a
per-account staging directory and reject files classified as credentials" — is
a cross-repository decision, because the consuming side of the contract lives
in `kcenon/claude-config`. The mechanism already exists and is wired:
`CLAUDE_CONFIG_SOURCE` overrides the config source path
(`scripts/lib/bootstrap-claude.sh`), both generators emit it, and the
installers write it as a commented key. What is undecided is the policy — which
files are safe to copy — not the plumbing.

The read-only mount is unchanged in `shared` and `worktree`.

## Delivery order

Issue #335 is delivered in six stages. Each is a separate PR.

1. **Configuration contract, threat model, resolved-compose test helpers.** ✅
2. **Worktree mount correction and regression tests.** ✅
3. **Independent workspace setup and isolated mount generation.** ✅
4. Runtime, configuration, credential and network hardening. **Partial** — the
   container profile is delivered; credential scoping and per-account networks
   remain.
5. Resource validation, transactional scaling, TUI cache correction, benchmarks.
6. Cross-platform rollout, migration documentation, final benchmark report.

`isolated` became usable at stage 3, which removed a refusal rather than adding
a name — the contract had accepted the value since stage 1 precisely so that
stages could turn it on without changing what users configure.

Stage 4 is split because its four axes are independent: the container profile
constrains what an account can do to its own container, while credential and
network scoping constrain what it can reach. Landing them separately keeps a
read-only-root regression and a network regression from arriving in one CI run.

## Verifying the active mode

```bash
scripts/claude-docker config     # prints the mode, its trust boundary, then the resolved compose model
scripts/claude-docker up         # prints the same banner before starting containers
scripts/claude-docker tui        # dashboard shows the mode above the account table
```

Run the contract and mount regression suite with:

```bash
bash tests/test_isolation_modes.sh
```

The resolved-mount assertions need `docker` and `jq`; without them the suite
reports a skip locally and fails in CI, where both are present.
