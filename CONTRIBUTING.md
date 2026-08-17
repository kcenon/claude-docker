# Contributing to claude-docker

## The one rule this project keeps re-learning

**Every behavioral rule in this repository is implemented more than once, in
more than one language. A change to one copy is not a change to the rule.**

That is not a design goal — it is the shape of the project. A Windows user and
a Linux user configure the same repository and must get the same containers,
the same trust boundary, and the same refusals, so the same logic exists in
bash, in PowerShell, and sometimes in Go. Nothing in a compiler or a linter
connects those copies. Only a test does, and only if one exists.

The history is a run of after-the-fact repairs, each one "a change landed on
one side and the two drifted":

| commit | closes | repair |
|--------|--------|--------|
| `d2b966c` | #318 | `generate-compose.ps1` did not honor `NUM_ACCOUNTS`/`IMAGE_TAG` from the environment |
| `ba5fd88` | #319 | added the bash-vs-PowerShell generator equivalence harness at all |
| `c5ec02e` | #320, #323, #324, #325 | account-count validation aligned across generators and CLI wrappers |
| `92a6a41` | #321 | Go default service count aligned with the generator default |

`c5ec02e` is the archetype: it added `normalize_account_count` to
`scripts/lib/index.sh` and did not touch `scripts/lib/index.ps1`, which
declares itself a mirror of that file. The drift outlived the commit that
created it by months.

## The four layers

When you change a rule, ask which of these implement it. Usually more than one.

| Layer | Files | Reads |
|-------|-------|-------|
| bash libraries | `scripts/lib/*.sh` | sourced by `scripts/claude-docker`, both installers, both generators, `scripts/entrypoint.sh` |
| PowerShell | `scripts/*.ps1`, `scripts/ClaudeDocker.psm1`, `scripts/lib/index.ps1` | the Windows-native counterparts of all of the above |
| Go | `tui/internal/config` | the TUI dashboard, which reads `.env` and the runtime registry itself |
| container | `scripts/entrypoint.sh`, `scripts/lib/bootstrap-*.sh` | runs inside every container; ships in the image, so a change here needs a `VERSION` bump |

`tui/internal/config/runtimes.json` is the cross-language single source of
truth for per-runtime values (binary name, build arg, state directory, config
paths). **Read a runtime value from the registry rather than restating it.**
All three languages have an accessor.

## The tests that hold the layers together

Each of these compares implementations against each other rather than against
a fixture, which is what makes them able to notice drift:

| Test | Pins |
|------|------|
| `tests/test_parse_env_equivalence.sh` | bash `parse_env_value` vs PowerShell `Get-EnvValue` produce identical output for identical input |
| `tests/test_compose_generator_equivalence.sh` | `generate-compose.sh` and `generate-compose.ps1` emit byte-identical compose files |
| `tests/test_runtime_registry_equivalence.sh` | all three registry readers return byte-identical values for every (runtime, field) pair |
| `tests/test_installer_github_equivalence.sh` | both installers write the same GitHub block into `.env` in per-account mode |
| `tests/test_isolation_modes.sh` | the shell, PowerShell and compose layers accept and refuse the same `ISOLATION_MODE` values |
| `tests/test_num_accounts_precedence.sh` | all four shell-side `NUM_ACCOUNTS` readers use one precedence order |
| `tests/test_bash32_portability.sh` | no bash 4+ construct enters `scripts/` or `tests/` |

The `bash-tests` job in `.github/workflows/ci.yml` is the authoritative list;
this table is the subset that exists to catch cross-layer drift specifically.

**If you change a rule these tests do not cover, add coverage in the same PR.**
A rule with copies and no equivalence test is a future repair commit.

## Before you open a PR

### Verification

- **Run the tests, do not reason about them.** The CI matrix is in
  `.github/workflows/ci.yml`; the bash suite is the `bash-tests` job's list.
- **A test that passes is not the same as a test that would fail.** Break the
  thing your test guards and confirm it goes red. If it does not, the test is
  documentation, not a check.
- **When you fix a defect, first run the new test against the unfixed code**
  and quote the failure in the PR. If the test cannot fail against the old
  code, it is testing something else.
- Silence is not success: a harness that finds nothing to check reports the
  same "0 failures" as one that checked everything. Assert your input count.

### Portability

- macOS ships bash 3.2 as `/bin/bash`. No `${var,,}`, no `mapfile`, no
  associative arrays, no namerefs, no `wait -n`. The full list is in
  `tests/test_bash32_portability.sh`, which enforces it.
- Windows PowerShell 5.1 is **not** supported; scripts require `pwsh` 7+.
- `scripts/lib/*.sh` is sourced by the container entrypoint, so it must not
  assume anything the Debian image does not have.

### Image content

Anything the `Dockerfile` `COPY`s — itself, `scripts/entrypoint.sh`,
`scripts/lib/`, `tui/internal/config/runtimes.json` — ships inside the image.
`docker compose up` reuses a local image already carrying the pinned tag rather
than rebuilding, so **a change to those paths that leaves `VERSION` alone never
reaches an existing installation.** Bump `VERSION` and regenerate the compose
files:

```bash
rm -f .env && bash scripts/generate-compose.sh
```

The `Image content changes bump VERSION` job enforces this. Check the paths it
matches before relying on it: the rule is "anything the Dockerfile `COPY`s",
and the job's pattern is a hand-maintained approximation of that list — which
makes it one more copy that can drift from what it describes.

### Generated files

The four `docker-compose*.yml` files are generated and **tracked**. Regenerate
with no `.env` present, which is what the `Compose files are current` job
compares against. Do not hand-edit them.

## Conventions

- **Branch from `develop`**, and open PRs against `develop`. `main` takes
  releases only.
- **Conventional Commit** subjects: `type(scope): description`, imperative,
  lowercase, no trailing period.
- **English** for code, comments, commit messages, issues and PRs.
- **No AI or tool attribution** in commits, issues or PRs.
- Explain **why** in comments, not what. A comment that says what the line
  below does goes stale silently; one that says why it is written that way is
  what stops the next person from undoing it.

## Where the deeper documents are

- [`README.md`](README.md) — installation, usage, configuration reference
- [`docs/ISOLATION.md`](docs/ISOLATION.md) — the three workspace isolation
  modes and exactly what each one does and does not defend against
- [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) — benchmark numbers of record
