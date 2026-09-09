# Issue #335 implementation and validation

Implementation started: 2026-09-08; final verification: 2026-09-09. Baseline: `develop` at
`4eb55c085be46bbd7c537ab30aab18a74b0936be`. The issue and comments were refreshed
before implementation. Image version: `2026.09.08.1`.

This records the local implementation checks completed before PR publication,
**not evidence that issue #335 is ready to close**. Remote CI results must be
assessed separately alongside the remaining validation listed below.

## Requirement to evidence

| Requirement | Implementation and executable evidence | Local result / remaining evidence |
|---|---|---|
| Preserve isolated sandbox and permission-deny settings | Mode-aware `bootstrap-claude.sh`; `test_isolation_regressions.sh`, `test_sandbox_gate.sh` | Focused original regression passes; requested capability/version/conflict failures are exercised with deterministic binaries |
| Refuse unavailable requested inner sandbox | `bootstrap-sandbox.sh`, entrypoint gate, image bubblewrap/socat dependencies; upstream Claude minimum 2.1.83; `failIfUnavailable` and unsandboxed-command refusal | Gate tests pass, including absent shared source and degraded-hook opt-out; actual kernel/LSM/rootless combinations remain untested locally |
| Preserve correct mode across runtime/overlay selections | Both generators, runtime registry, CLI/TUI argv validation | Real Compose resolves all 18 combinations: 3 runtimes × 3 modes × Linux overlay off/on; Codex combined bypass refused in isolated mode |
| Validate actual account boundaries without secrets in diagnostics | Shared host engine reads Compose JSON; rejects overlapping/aliased workspaces, unapproved mounts/volumes/networks, UID 0 and weaker privileges; reports environment key names only | Mutation, stale/missing credential mapping, redaction and resolved-model tests pass; live enforcement is separate |
| Independent clones and preview without writes | Shared `setup` engine behind Bash/PowerShell helpers; preflights every destination, stages clones, dissociates objects, verifies metadata/object independence | Original inherited-alternates regression, existing setup suite and no-write/unsafe-destination tests pass; no untracked source/config copying |
| Transactional scaling and protected recovery | Installation lock, staged environment/all four Compose files, protected journal, per-file atomic publication, minimal Compose reconciliation, original exit code, owned-resource compensation | 30 host-policy tests pass, including real Bash/PowerShell generators, fresh state directories, publication/startup/initializer failures, recovery retry, POSIX signals, stopped services, explicit count, and unrelated writes; 2 native Windows ACL cases skipped locally |
| Explicit resource budgets and startup integration | Resolved limits/reservations/heap/PID/scratch reports, bounded Docker capacity query, finite scratch sizes; wrappers/installers/TUI startup use shared engine | Resource/parser equivalence, resolved budgets and invalid-input tests pass; scratch defaults and account capacity remain provisional |
| Non-root writable state/cache and functional worktree Git | Scoped fresh-volume initializer; account write probe; read-only container gitfile plus worktree common metadata mount | Host/Compose tests pass; actual cache, Git, hook and statusline execution require the live image job |
| Two-way filesystem/network isolation with positive controls | `test_container_isolation.sh` / `.py` and disposable `container_fixture.py`; listener, direct-IP/DNS checks, bridge-connect and marker mutation controls, offline outbound failure, recreate persistence, sandbox refusal | Harness and CI wiring implemented; **0 live container cases executed locally** |
| Runtime and outbound readiness | Live harness separates container state, CLI `--version`, local Git/hooks and external DNS/TLS/HTTP/public Git | No authenticated provider sessions or authenticated pushes were performed; those need explicit opt-in credentials and a disposable remote |
| Current dashboard performance | Actual `Manager.ListAccounts` benchmark with mocked Docker/no auth: 1/2/4 accounts, 10/10,000 history files, 256 B/64 KiB current limitline padding | **12 cases × 5 timing estimates = 60 measured estimates**; raw samples, variance and provenance stored under `benchmarks/issue-335/` |
| Container performance matrix and capacity | Driver for 9 mode/account cells, 5+ samples, cold/setup separation, CPU/wall/memory/disk observations and provenance; one-cell live CI smoke | Matrix plan has 9 cells/45 planned samples, **0 executed local container measurements**; statistics smoke covers all 9 synthetic cells; no capacity promise or reviewed budget |

## Original defects: red before, green after

`tests/test_isolation_regressions.sh` was first run against the unmodified
baseline using disposable, non-secret inputs. It reported **2 passed / 5 failed**.
The failures covered all four reproduced defects:

1. Isolated settings disabled the requested sandbox and removed a deny entry.
2. Rejected per-account authentication left the scaled count published in `.env`.
3. Duplicate isolated workspace sources were accepted and output files published.
4. Cloning a repository that borrowed Git objects retained external alternates.

After implementation, the same regression script reports **7 passed / 0 failed**.
The larger fault tests validate file bytes/modes, service states, ownership and
absence of a success message on failure. Recovery preserves unrelated account
writes instead of claiming to restore application history byte for byte.

## Local environment and checks

macOS arm64, Apple M4 Max; `/bin/bash` 3.2, PowerShell 7, jq, Python 3.9+, Go
1.27.1. Disposable Docker CLI 29.8.0 and Compose 5.5.1 were used for **configuration
resolution only**. Go/Docker tooling was downloaded into a temporary directory;
no Docker daemon or VM was installed. Generation used temporary placeholder
configurations, and all four tracked Compose outputs were regenerated from
defaults without reading or removing a developer `.env`.

Local checks include the Bash/PowerShell compatibility suites, real Compose
resolution, host-policy fault tests, shellcheck, PSScriptAnalyzer with the CI
exclusions, Go race tests/vet/formatting, benchmark-statistics tests and dashboard
measurements. The old JSONL pipeline remains absent and its regression is active.
The PowerShell generator tests on macOS simulate only the production platform
guard in disposable copies; this does not establish native Windows behavior.

Final totals, including focused reruns after fixes:

- 33 CI-listed Bash test scripts and 8 portable PowerShell test scripts passed.
- 32 host-policy cases: 30 passed, 2 native Windows ACL cases explicitly skipped.
- 18 normal Compose models and 9 live-harness fixture preparations passed;
  fixture preparation starts **zero** containers.
- Go `test -race ./...`, `vet ./...`, formatting, shellcheck and PSScriptAnalyzer
  passed. Generator equivalence reported 50 passing comparisons; parser
  equivalence reported 104 passing assertions across Bash/PowerShell/Go/Python.
- Three benchmark-harness tests passed, covering nine synthetic statistics
  cells, missing-sample rejection and project-scoped cleanup after offline mode.
- Dashboard benchmark: 12 cases, five estimates each; container measurements: 0.

The initial broader run exposed GNU-only fixture `touch`/`stat` calls and macOS
`/var` versus `/private/var` path comparisons. Fixture timestamp/permission/path
handling was made portable while retaining the assertions. That exposed an
additional real BSD-sed defect in workspace-key enumeration: GNU `\|` alternation
missed configured isolated paths on macOS. The existing ownership regression
failed before the extended-regex fix and passes after it. These checks are
included in the successful focused reruns; the ownership test is also in the
macOS CI subset.

`docker info` failed because `/var/run/docker.sock` was absent. The downloaded
Docker CLI also lacked Buildx, so `docker build --check .` could not execute.
The live harness refused at daemon discovery. These are unavailable checks,
not successful skips or image/runtime validation.

## Remaining validation

- Run the updated Linux CI image job, including real boundaries for Claude,
  Codex and Gemini, external connectivity, and the five-sample benchmark smoke.
- Run native Windows lifecycle/ACL/process tests and Windows Docker Desktop
  integration; exercise Linux Docker, Desktop and any claimed rootless/nested
  sandbox configurations under their actual security profiles.
- Run the full nine-cell container benchmark on representative hosts and
  review CPU/memory/scratch settings, capacity expectations and proposed budgets.
- With explicitly supplied test credentials, verify authenticated runtime
  sessions and Git push against an owned disposable repository. Keyless startup,
  public Git transport and placeholder environment scoping do not prove these.
- Exercise abrupt host/process termination and daemon-loss recovery on target
  platforms. POSIX signal compensation and protected journal replay are covered
  locally; this is not a claim of power-loss durability across every filesystem.

See [ISOLATION.md](ISOLATION.md) for operation/migration and
[PERFORMANCE.md](PERFORMANCE.md) for measurements and reproduction commands.
