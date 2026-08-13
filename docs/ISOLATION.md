# Workspace Isolation and Threat Model

`ISOLATION_MODE` declares the trust boundary a set of agent accounts runs
under. This document states what each mode does and does not protect against,
so a boundary is chosen deliberately rather than inferred from which compose
file happened to be passed.

Status: stages 1 and 2 of issue #335 are implemented. The `isolated` mode is
part of the configuration contract and is **not implemented yet** — see
[Delivery order](#delivery-order).

## Modes

| Mode | Workspace boundary | Use it for |
|---|---|---|
| `shared` (default) | Every account bind-mounts `PROJECT_DIR` read-write at `/project`. | Mutually trusted accounts collaborating on one tree. |
| `worktree` | Each account mounts only its own git worktree. Git metadata is still shared. | Concurrent branches with fewer lock and wrong-tree collisions. |
| `isolated` | Account-exclusive workspace, runtime state, configuration source, credentials and network. | Accounts that must not read or modify each other's data. **Not implemented yet.** |

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

An explicit mode outranks the inference. Configuring `PROJECT_DIR_A` while
declaring `ISOLATION_MODE=shared` is honored as shared, and a warning names the
per-account paths that are consequently inert — an ignored setting is reported,
never silently dropped.

An unrecognized value is refused. So is `isolated`, for as long as its stack is
unimplemented. Neither degrades to `shared`: running a weaker boundary than the
one that was asked for is the failure this contract exists to prevent.

## What each mode protects against

The adversary model for `isolated` is an agent running an unsafe or malicious
command **inside a normal container** — a wrong `rm -rf`, a prompt-injected
tool call, a compromised dependency's postinstall script.

| Concern | `shared` | `worktree` | `isolated` (planned) |
|---|---|---|---|
| Account A edits account B's working tree | No | Yes | Yes |
| Account A reads account B's working tree | No | Yes | Yes |
| Account A rewrites shared git history (`.git`) | No | **No** | Yes |
| Account A reads account B's credentials | No | No | Yes |
| Account A reaches account B over the network | No | No | Yes |
| Container escape to the host | No | No | No |

"No" means the mode does not defend against it.

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
| `docker-compose.worktree.yml` | resolved mode is `worktree` | Replaces each service's volume list. |

All three files are generated in every mode. The mode decides which ones a
caller composes together, not which ones exist, so drift checks keep comparing
the same tracked set.

**Open question for stage 3.** `docker-compose.linux.yml` sets
`user: "${UID}:${GID}"`, which conflicts with the stage 3 requirement to run
isolated services as the non-root `node` user and assert the effective user in
tests. On a Linux host the Linux overlay is applied unconditionally, so an
isolated profile cannot simply declare `user: node` and expect it to hold. The
resolution — scoping the Linux overlay to non-isolated modes, having the
isolated stack override the user back, or generating a standalone isolated
stack that skips the overlay entirely — is not decided here.

## Interaction with the shared runtime configuration mount

Every service mounts the host's `~/.claude/` read-only at
`/home/node/.claude-host/`. That contract is documented outside this repository
in [`docs/CLAUDE_DOCKER_CONTRACT.md`](https://github.com/kcenon/claude-config/blob/develop/docs/CLAUDE_DOCKER_CONTRACT.md)
in `kcenon/claude-config`, and the entrypoint depends on its directory layout,
hook command grammar, and settings transform.

**Open question for stage 4.** Issue #335 requires isolated services to replace
the shared runtime-configuration mount with an absent-by-default or
account-scoped source. That directly contradicts the current contract: an
isolated account would receive no shared hooks, skills, commands, statusline,
or `CLAUDE.md`. Which parts of the contract `isolated` keeps, which it drops,
and whether an explicit allowlisted import replaces it, cannot be decided in
claude-docker alone — the consuming side of the contract lives in another
repository. This is recorded as unresolved rather than assumed either way.

The read-only mount is unchanged in `shared` and `worktree`.

## Delivery order

Issue #335 is delivered in six stages. Each is a separate PR.

1. **Configuration contract, threat model, resolved-compose test helpers.** ✅
2. **Worktree mount correction and regression tests.** ✅
3. Independent workspace setup and isolated mount generation.
4. Runtime, configuration, credential and network hardening.
5. Resource validation, transactional scaling, TUI cache correction, benchmarks.
6. Cross-platform rollout, migration documentation, final benchmark report.

`isolated` becomes usable at stage 3. Until then it is refused with a
diagnostic that names the reason, which is why the configuration contract
accepts the value while no code path will start it.

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
