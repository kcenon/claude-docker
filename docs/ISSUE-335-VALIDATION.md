# Issue #335 implementation and validation

Historical #394 implementation started: 2026-09-08; local verification: 2026-09-09. Baseline: `develop` at
`4eb55c085be46bbd7c537ab30aab18a74b0936be`. The issue and comments were refreshed
before implementation. Image version: `2026.09.08.1`.

Issue #335 remains open. The first table preserves historical local #394 checks;
remote CI and follow-up implementation evidence are recorded below. The follow-up
starts from merged #394, `develop` at `5c4a3475938455d1f0c27cd11a6eea72b9dacfbf`,
and is reviewed in [PR #395](https://github.com/kcenon/claude-docker/pull/395).

## Historical #394 local evidence

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

## Merged and follow-up CI evidence

The final pre-merge #394 head `dd361a7` passed all 61 CI jobs in
[run 34314414245](https://github.com/kcenon/claude-docker/actions/runs/34314414245),
including native Windows policy/ACL cases, live Linux boundaries/runtime probes,
external connectivity and the benchmark smoke. That is evidence for the tested
PR head; it is not a claim that the squash commit was independently remeasured.
The earlier local “not run” entries above preserve their original scope.

The follow-up full matrix passed in
[run 34348122253](https://github.com/kcenon/claude-docker/actions/runs/34348122253)
at head `e1b2cfe`, checked-out merge `2af2343207927713f17cc4ec33d21c1b1652580d`.
The same head's [main CI run 34348122233](https://github.com/kcenon/claude-docker/actions/runs/34348122233)
passed. Exact image/source fingerprints, daemon capacity and versions are in the
committed reports and [performance protocol](PERFORMANCE.md).

Follow-up workflow and daemon tests executed in
[run 34349748157](https://github.com/kcenon/claude-docker/actions/runs/34349748157),
head `c0ee1d3`, checked-out merge `c59f851dc887db7c5ec87815626c299d6656ad22`.
The Linux Bash workflow report has **24 passed, 0 failed, 16 skipped** cases:
nine real npm/build/test executions (27 package assertions and 45,000 verified
reads), nine writable-path checks, three fixture orchestration cases and three
cleanup cases. The skipped cases are nine authenticated sessions, six
credentialed pushes and one Claude terminal/statusline dispatch. They are not
successful authentication evidence.

The requested sandbox report has two refusal checks and cleanup passing. The
actual probe cannot execute under this Linux kernel/container profile and is
refused before command execution, with and without the degraded-settings override.
The daemon report has one actual stop/start recovery scenario and cleanup passing:
five managed files restored, one running and one stopped service restored,
transaction-owned additions removed, unrelated writes retained and second recovery
idempotent. This is independent of the process fixture's simulated Docker outage.

### Requirement to evidence for the remaining work

| Requirement | Implemented behavior and measured evidence | Outstanding prerequisite |
|---|---|---|
| Real workflows and authenticated compatibility | Registry-driven Bash/native PowerShell entry point; npm/default cache, workspace/Git/helper/state/temp writes; recreation markers; sanitized opt-in provider, Git push and Claude hook/statusline adapters; [24-pass offline report](benchmarks/issue-335/runtime-workflows-linux-x86_64.json) | Explicit test API/GitHub credentials, disposable remote and enabled models for all three runtimes; actual terminal/TUI evidence, including native Windows |
| Full container matrix and reviewed budgets | Reliable schema/fingerprint, immutable image, real offline workload, aligned cgroup observations, deduplicated physical storage; [9 cells × 5 samples](benchmarks/issue-335/container-linux-x86_64-claude.json), [summaries](benchmarks/issue-335/container-linux-x86_64-claude-summary.json) | Proposed budget acceptance in PR #395; no review date or accepted regression yet |
| Measured capacity documentation | Largest passing count 4 for the named Linux npm workload; configured ceilings/reservations compared with actual daemon capacity; startup/readiness/workload/PID/scratch/storage and dashboard proposals in [PERFORMANCE.md](PERFORMANCE.md) | Authenticated/larger-workload measurements before agent capacity claims; Desktop/rootless runs before extending platform scope |
| Interrupted lifecycle recovery | Deterministic real wrapper/child process tests for staged/partial publication/application/compensation; handled POSIX signals, hard kills, live-owner/reader/concurrent recovery refusal, state/ACL assertions; [actual daemon restart report](benchmarks/issue-335/daemon-recovery-linux-x86_64.json) | Native Windows process results are linked in the PR checks; Desktop daemon recovery remains unmeasured; no universal power-loss durability claim |
| Requested inner sandbox | [Actual Linux capability/refusal report](benchmarks/issue-335/sandbox-linux-x86_64.json), plus existing conflict/dependency/version regressions | Executed supported-kernel sandbox session and rootless/Desktop profiles; successful refusal does not prove sandboxed provider execution |

### Platform matrix

| Platform/backend | Executed evidence | Remaining |
|---|---|---|
| Linux Engine, Ubuntu 24.04.4, x86_64, kernel 6.17.0-1022-azure; Engine 28.0.4, Compose 2.38.2, overlay2/cgroup v2, UID/GID 1001, AppArmor/built-in seccomp | Full Claude/npm matrix; all-runtime offline workflows; boundaries and public transport; real daemon restart; actual requested-sandbox refusal | Authenticated sessions/pushes/hooks/statusline and an inner-sandbox-compatible kernel profile |
| macOS arm64, Apple M4 Max, native Bash 3.2/Python 3.9 | Historical dashboard measurements and compatibility/policy checks; new subprocess suite: 9 passed, 1 Windows console case skipped; downloaded Linux report revalidated locally | No local Docker daemon available; Docker Desktop versions/backend, workflows, capacity and daemon restart unmeasured |
| Native Windows PowerShell 7, GitHub Windows runner | #394 policy/ACL suites and follow-up offline npm host test; native process/console/DACL suite in a separate CI step (latest result linked in PR checks) | Linux-container Docker Desktop/WSL2 integration and interactive terminal/TUI session unexecuted |
| WSL2 Bash with Desktop integration | Supported launcher path and documented fixture entry points | No live workflow/capacity/recovery result from this backend |
| Rootless Linux daemon | Explicit Docker connection selection and provenance supported by fixture | Actual resource enforcement, nested sandbox and workload/capacity runs unavailable; rootful result does not establish rootless behavior |

### Follow-up defect evidence and checks

The original fingerprint and negative-measurement regressions failed before the
benchmark changes (seven failed assertions across five tests) and then passed.
CI then exposed Windows npm launcher resolution and a shared-mode default cache
permission failure; the native Node/npm entry point and explicit private cache
fixed both. ShellCheck initially failed downloading its floating `stable` binary
before lint ran; pinning v0.11.0 passed. These are covered by the green runs above.

The retained Linux report exposed one-ULP variance differences when revalidated
with Python 3.9. The portable-rounding regression failed before the validator fix
and passed afterward, while a 1% variance mutation still fails. Raw measurements
were preserved unchanged. The first native Windows subprocess run reached three
cases but four barriers timed out because its captured-output pipe filled before
publication. A large-output regression reproduced that deadlock locally before
file-backed capture fixed it. The private integration-file creation/cleanup test
also caught an invalid pathlib `opener` argument before any credentialed run; the
correct built-in file API passes success/failure cleanup and child-environment
checks. The five fingerprint/statistics cases, six report
corruption/rounding cases, package corruption control and six credential/redaction
cases are executable independently. The subprocess suite has ten cases with
platform-specific signal skips; native command exits remain separate CI steps.

No live provider credentials were discovered or reused. The exact opt-in file
schema, bounded commands, cleanup/ref handling, CI secret scope and reproduction
commands are in [ISSUE-335-WORKFLOWS.md](ISSUE-335-WORKFLOWS.md). Missing credentials
produce skipped cases, and `--require-complete` fails on those skips. PR #395 stays
a draft and references `Refs #335` while mandatory evidence/review remains absent.
