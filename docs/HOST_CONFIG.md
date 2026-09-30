# Host Configuration

How containers consume the host's Claude Code configuration, and how the
entrypoint transforms `settings.json` before Claude Code starts.

## Shared Configuration (claude-config)

If you use [claude-config](https://github.com/kcenon/claude-config) to manage global
Claude Code settings, containers automatically inherit your host configuration.

> **Prerequisite**: Run claude-config's installer (`scripts/install.sh` /
> `install.ps1`, or `bootstrap.sh`) on the host **before** starting any
> claude-docker container. Containers are pure consumers — they do not run
> the installer. Without a populated `~/.claude/` tree on the host, the
> entrypoint has no shared files to copy or link and Claude Code falls back
> to its built-in defaults.
>
> **Compatibility**: Tested against claude-config v1.10+. The contract
> claude-docker relies on (directory layout, hook command grammar,
> dual-variant pairing, full-suite probe, CRLF normalization) is documented
> in [`docs/CLAUDE_DOCKER_CONTRACT.md`](https://github.com/kcenon/claude-config/blob/develop/docs/CLAUDE_DOCKER_CONTRACT.md)
> in the claude-config repo. Older claude-config installs may work but are
> not gate-tested.

The host's `~/.claude/` is mounted read-only at `/home/node/.claude-host/`
inside each container. Startup uses different synchronization strategies by
content type:

| Shared content | Default container behavior |
|----------------|----------------------------|
| `hooks/`, `scripts/` | Clean-copy into `/home/node/.claude/` and normalize `.sh` files to LF |
| `skills/`, `commands/`, `ccstatusline/` | Symlink into the per-account state directory |
| `CLAUDE.md`, `commit-settings.md`, `.claudeignore`, `.full-suite-active` | Symlink when the source exists |
| `settings.json` | Generate `settings.container.json`, then point the account's `settings.json` at that transformed copy |
| `ccstatusline/settings.json` | Also link into `/home/node/.config/ccstatusline/settings.json` |

The default read-only host mount is never modified. Account credentials,
memory, sessions, and logs remain writable and per-container. The managed
`hooks/` and `scripts/` destinations are clean mirrors and replace existing
same-named account directories on startup. For `skills/`, `commands/`,
`ccstatusline/` and `settings.json`, an existing plain target is moved to
`<name>.stale.<epoch>` before linking, and the move is logged. Non-empty
per-account instruction files are preserved, but do not use the managed
directories for persistent per-account overrides.

The account state directory itself is created `0700`. On Linux and macOS the
installer already sets that host-side; on Windows `chmod` is meaningless
against NTFS and Docker Desktop typically exposes bind mounts as `0777` inside
the container, so the entrypoint applies it on every start.

`CLAUDE_CONFIG_SOURCE` changes this behavior. An explicit source is treated as
writable, force-linked on every startup, and its `.sh` files are normalized to
LF **in place** before linking. If that source is under the project bind mount,
the normalization can therefore appear as host-side Git changes. The
`settings.json` transform described below still runs.

## Container-side settings transformation

The entrypoint does not use `settings.json` verbatim. For both the default host
mount and an explicit `CLAUDE_CONFIG_SOURCE`, it writes a container-local
working copy before Claude Code starts. The transform performs four operations:

1. in shared/worktree mode, sets `sandbox.enabled` to `false`;
2. in shared/worktree mode, removes wildcard `permissions.deny` entries for the file tools;
3. replaces a PowerShell `statusLine.command` with the Linux statusline script;
4. rewrites PowerShell hook commands to their bash equivalents.

**Isolated mode preserves sandbox and permission-deny settings.** Requested
Claude sandboxing requires version 2.1.83+ and a successful capability probe.
Unsupported combinations refuse startup without weakening Docker restrictions;
`CLAUDE_ALLOW_DEGRADED_SETTINGS` cannot bypass this gate. See the
[runtime sandbox contract](ISOLATION.md#runtime-sandbox-contract).

**1. Shared/worktree mode forces `sandbox.enabled` to `false`.**

The host sandbox gates filesystem and network access on the host. Inside a
container it would re-confine already-confined code and, more importantly,
break hooks and skills that `exec` into `/usr/bin`. The entrypoint relies on
the container itself being the isolation boundary.

This assumption relies on the **default** profile: cgroups/namespaces, a
non-root process, no Docker socket, no privileged mode, read-only host-config
mounts, and only the documented writable project/state mounts. It does **not**
hold when:

- the container runs with `--privileged`,
- the host Docker socket or another privileged daemon is mounted, or
- additional host paths or devices are exposed with broader permissions.

If you run claude-docker in any of those modes you lose the host sandbox
without warning. Either keep the outer Docker isolation strict or edit the
entrypoint to leave `sandbox.enabled` untouched for that profile.

**2. Wildcard deny rules for the file tools are removed.**

Entries in `permissions.deny` that name `Read(`, `Edit(`, `Write(`, `Glob(` or
`Grep(` **and** contain `*` are stripped. The claude-config integration expects
`sensitive-file-guard.sh` to provide the corresponding sensitive-file
protection. If a custom config source does not ship and enable that hook, those
wildcard restrictions are not replaced; do not assume the host deny list remains
effective inside the container.

Rules for every other tool are kept, wildcard or not — `Bash(sudo:*)` and
`WebFetch(domain:*)` survive into the container. Until #357 the filter dropped
*any* rule containing `*`, which took those with it even though
`sensitive-file-guard.sh` substitutes for the file tools only. A `Bash(...)`
rule written against a Windows host path may not match anything on Linux, but a
rule that does not match is inert, while one that was silently removed is not
there to match.

Each removed rule is now named on its own line at startup:

```
[entrypoint] settings.json: container-optimized (sandbox=off, file-tool glob deny rules stripped)
[entrypoint]   removed deny rule: Read(./secrets/**)
```

**3. A PowerShell statusline command is replaced.**

If `statusLine.command` contains `pwsh`, it is replaced with
`~/.claude/scripts/statusline-command.sh` before the general hook rewrite.

**4. PowerShell hook commands are rewritten for Linux.**

Host `settings.json` entries that invoke `pwsh -NoProfile -File ...` are
transformed so they work inside the Linux-native container image. This is
best-effort: trivial single-call hooks are rewritten cleanly, but the following
patterns are not supported reliably:

| Pattern | Example | Status |
|---------|---------|--------|
| `pwsh -NoProfile -File ./foo.ps1` | top-level script | supported |
| Heredoc / multi-line `-Command` | `pwsh -c @"..."@` | not supported |
| `$env:VAR` expansion | `pwsh -c '$env:FOO'` | not supported |
| Quoted paths with spaces | `pwsh -File "C:\\Program Files\\..."` | not supported |
| `Join-Path` outside the statusLine slot | inside a hook array | not supported |

Only commands that *begin* with `pwsh` are rewritten. A Linux-native command
that merely mentions the word passes through untouched. Statement separators are
preserved as written: `;` stays `;` and `&&` stays `&&`, so a hook chain does
not change from sequential to exit-code-dependent (or the reverse) in the
container.

After transformation, startup runs `bash -n -c` against every generated command.
A syntactically valid but semantically incorrect rewrite can still fail only
when the hook runs. If a hook works on the host but not in the container, check
the startup logs and the patterns above. The workaround is to provide
Linux-native commands through `CLAUDE_CONFIG_SOURCE`, so the PowerShell rewriter
has nothing to change. In shared/worktree mode, the sandbox and file-tool deny transforms still apply,
and `.sh` files in that explicit source are CRLF-normalized in place.

**Degraded settings stop the container.**

In shared/worktree mode, `sandbox.enabled = false` and the deny stripping are applied first and cannot
fail; only the compensating hook rewrite can. A container that started anyway
would be running with the sandbox off, deny rules stripped, and the guard hook
that was supposed to make that safe not firing — previously behind a single
warning line. The entrypoint now refuses to `exec` when any of these applied:

- one or more transformed hook commands failed the `bash -n -c` check;
- the generated `settings.container.json` was not valid JSON;
- the transform failed, or `jq` is missing, so the raw host settings are in use.

Set `CLAUDE_ALLOW_DEGRADED_SETTINGS=1` in `.env` to start anyway. The list is
printed in that case too, so the choice stays visible on every start.

One degradation is reported but does **not** block: a hook script named by
`settings.json` that is not present on disk. That verdict comes from grepping a
path-shaped token out of a free-form command string rather than from anything
the transform observed, and a false positive there would cost a container that
will not start rather than a stray warning line.
