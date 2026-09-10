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

The [native Windows follow-up run 34350733007](https://github.com/kcenon/claude-docker/actions/runs/34350733007)
passed at head `c4d9e95`: eight process/console/recovery cases passed, with two
POSIX signal cases explicitly skipped. The same ten-case suite passes nine cases
on macOS/Linux and skips the Windows console case. Managed Windows owner/group,
DACL and inheritance descriptors are compared after recovery. This does not
establish Windows Docker Desktop container behavior.

### Requirement to evidence for the remaining work

| Requirement | Implemented behavior and measured evidence | Outstanding prerequisite |
|---|---|---|
| Real workflows and authenticated compatibility | Registry-driven Bash/native PowerShell entry point; npm/default cache, workspace/Git/helper/state/temp writes; recreation markers; sanitized opt-in provider, Git push and Claude hook/statusline adapters; [historical 24-pass offline report](benchmarks/issue-335/runtime-workflows-linux-x86_64.json); expanded evidence below | Explicit test API/GitHub credentials, disposable remote and enabled models for all three runtimes; authenticated wrapper/TUI execution on the documented Docker backends |
| Full container matrix and reviewed budgets | Reliable schema/fingerprint, immutable image, real offline workload, aligned cgroup observations, deduplicated physical storage; [9 cells × 5 samples](benchmarks/issue-335/container-linux-x86_64-claude.json), [summaries](benchmarks/issue-335/container-linux-x86_64-claude-summary.json) | Proposed budget acceptance in PR #395; no review date or accepted regression yet |
| Measured capacity documentation | Largest passing count 4 for the named Linux npm workload; configured ceilings/reservations compared with actual daemon capacity; startup/readiness/workload/PID/scratch/storage and dashboard proposals in [PERFORMANCE.md](PERFORMANCE.md) | Authenticated/larger-workload measurements before agent capacity claims; Desktop/rootless runs before extending platform scope |
| Interrupted lifecycle recovery | Deterministic real wrapper/child process tests for staged/partial publication/application/compensation; handled POSIX signals, hard kills, live-owner/reader/concurrent recovery refusal, state/ACL assertions; [actual daemon restart report](benchmarks/issue-335/daemon-recovery-linux-x86_64.json) | Native Windows process results are linked in the PR checks; Desktop daemon recovery remains unmeasured; no universal power-loss durability claim |
| Requested inner sandbox | [Actual Linux capability/refusal report](benchmarks/issue-335/sandbox-linux-x86_64.json), plus existing conflict/dependency/version regressions | Executed supported-kernel sandbox session and rootless/Desktop profiles; successful refusal does not prove sandboxed provider execution |

### Platform matrix

| Platform/backend | Executed evidence | Remaining |
|---|---|---|
| Linux Engine, Ubuntu 24.04.4, x86_64, kernel 6.17.0-1022-azure; Engine 28.0.4, Compose 2.38.2, overlay2/cgroup v2, UID/GID 1001, AppArmor/built-in seccomp | Full Claude/npm matrix; all-runtime offline workflows; boundaries and public transport; real daemon restart; actual requested-sandbox refusal | Authenticated sessions/pushes/hooks/statusline and an inner-sandbox-compatible kernel profile |
| macOS arm64, Apple M4 Max, native Bash 3.2/Python 3.9 | Historical dashboard measurements and compatibility/policy checks; new subprocess suite: 9 passed, 1 Windows console case skipped; downloaded Linux report revalidated locally | No local Docker daemon available; Docker Desktop versions/backend, workflows, capacity and daemon restart unmeasured |
| Native Windows PowerShell 7, GitHub Windows runner | #394 policy/ACL suites and follow-up offline npm host test; process/console/DACL suite; [native ConPTY and compiled-TUI follow-up](benchmarks/issue-335/native-terminal-ci-pr396.json) | Linux-container Docker Desktop/WSL2 integration and authenticated interactive sessions unexecuted |
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
checks. A final provenance audit added the extensionless Bash launcher, Windows
CMD launcher and Docker build-ignore input to the fingerprint; all three mutations
failed before that fix. Corrupt CPU/wall/memory/OOM aggregates with internally
consistent summaries were also rejected after five new failing corruption checks
exposed the missing raw-to-aggregate comparisons. Unavailable cgroup OOM counters
now fail this cgroup-v2 profile instead of being reported as zero.
The six fingerprint/statistics cases, seven report
corruption/rounding cases, package corruption control and six credential/redaction
cases are executable independently. The subprocess suite has ten cases with
platform-specific signal skips; native command exits remain separate CI steps.

No live provider credentials were discovered or reused. The exact opt-in file
schema, bounded commands, cleanup/ref handling, CI secret scope and reproduction
commands are in [ISSUE-335-WORKFLOWS.md](ISSUE-335-WORKFLOWS.md). Missing credentials
produce skipped cases, and `--require-complete` fails on those skips. PR #395
merged as `05cbfc0e1025c2e3ae506504a9d66576ee4fe804`. Its final PR head
`f04f50f432d935c5d222124367462141fb69deb0` passed 65 checks; the final matrix used
merge checkout `8eecb26d9a38ac2b846faacc11a0eb93e3756cea`. Those are pre-merge
results, not a new test execution of the squash commit. Issue #335 remains open
at 15/17 criteria. Follow-ups use `Refs #335` while required evidence or review
is missing.

## Terminal and completion follow-up

This follow-up starts from `develop` at `05cbfc0e1025c2e3ae506504a9d66576ee4fe804`
in a separate worktree. Existing installation configuration and credentials were
not used. Image inputs, resource defaults and the measured workload are unchanged.

| Requirement | Reviewable implementation/evidence | Remaining prerequisite |
|---|---|---|
| Wrapper and actual TUI attach | POSIX PTY/Windows ConPTY adapters; native Linux/macOS/Windows process-fixture CI passed; both accounts and every runtime; fresh hook/statusline challenges; dashboard help response after runtime exit | Live installed-runtime tests with explicit credentials |
| Correct terminal failures and cleanup | Native child/descendant cleanup, output drain, timeout/early exit, redirected-parent privacy and actual compiled UI controls passed on all three native CI hosts | Real container-side terminal cleanup on each Docker backend |
| Credential identity and file privacy | Open-handle owner/mode/DACL checks; no caller ACL changes; native Windows ACL tests passed; GitHub identity must match; atomic absence lease on ref creation and SHA lease on deletion | Purpose-provided accounts/remote |
| Compatible requested inner sandbox | Effective restrictive settings plus authenticated Bash file work and a distinct mount namespace; capability refusal remains separate | Compatible host/kernel/runtime and explicit Claude credentials |
| Complete workflow reports | 62 expected rows for all runtimes, missing/duplicate/status/provenance/cleanup rejection; setup failures retain skipped prerequisites | Actual complete authenticated/platform reports |
| Backend and resource provenance | Native host/daemon profile assertions; enforced cgroup CPU/memory/PID, scratch and outer security checks; explicit Desktop application version | Desktop, WSL2 and rootless Linux runs |
| Reviewed performance proposals | Report hashes/source/image/workload/host bound in `budget-review.json`; pending decisions rejected by `--require-accepted` | Explicit maintainer acceptance with reviewer/date/link/accepted regressions |

Defect regressions were demonstrated before each fix:

- Report coverage: four failures against the original writer, including missing
  cases returning exit code 0 and zero cases labelled `complete`.
- Dashboard attach failure: `failed attach disappeared on dashboard return: ""`
  against the original `sessionFinishedMsg` handler.
- Remote-ref race: `WorkflowFailure not raised` when the original push replaced
  a concurrently created ref. The new local bare-remote test preserves that ref.
- Compose resource observation: `KeyError: 'pids_limit'` against a resolved
  service that stores PID limits under `deploy.resources.limits.pids`.
- Sandbox-refusal report: exit code 1 instead of 0 when two successful refusal
  scenarios reused a case name. Each now has a distinct name.
- Native console startup ordering: `terminal_start_failed` when a startup
  operation needs an output drainer before it can finish. The drainer now starts
  before the native console/process calls.
- Native Windows redirected handles: `OSError: [WinError 6] The handle is invalid`
  in the terminal-dimensions child, plus placeholder output bypassing ConPTY,
  in [the unfixed native run](https://github.com/kcenon/claude-docker/actions/runs/34362995644/job/102506350677).
  Explicit NULL standard handles with `STARTF_USESTDHANDLES` prevent Windows
  from duplicating the parent's redirected streams, as described in
  [Microsoft's ConPTY discussion](https://github.com/microsoft/terminal/discussions/15814).
  A separate redirected-parent regression checks bidirectional input and that
  neither parent output stream receives terminal content.

The native terminal CI matrix passed on Linux, macOS and Windows. Its
placeholder process adapter does not establish Docker Desktop compatibility.
Local execution is macOS arm64 with Python 3.9.6, Bash 3.2, PowerShell 7.6.3 and
Go 1.27.1. No local Docker daemon is available. Provider credentials, a disposable
authenticated remote, Docker Desktop/WSL2/rootless hosts and a maintainer budget
decision have not been supplied. No authenticated calls or external pushes are
claimed. Reproduction commands and exact report
scope are in [the workflow guide](ISSUE-335-WORKFLOWS.md).

[Local verification summary](benchmarks/issue-335/local-terminal-verification-darwin-arm64.json):
33 Bash suites and eight portable PowerShell suites passed. The 14 Python suites
passed with 99 unit checks (90 passed, nine platform-specific skips), plus the
resolved Compose model check. Go race tests, vet, formatting, all 12 dashboard
benchmark smoke cases, 56 shellcheck inputs, workflow syntax validation and
Windows cross-builds passed. Cross-builds are not native Windows execution.
The retained full container report remains valid at nine cells/45 samples; its
budget review is pending. No image inputs changed, so no image tag or generated
Compose changes are needed.

[Native terminal CI evidence](benchmarks/issue-335/native-terminal-ci-pr396.json)
records three successful jobs on merge checkout
`b256a635dc8f6908b3b61db1ab825cc6ad6e82fb`, for PR head
`51705e4944086009489605e8e551fbf5620d6e88`. Each host ran 15 checks: 13 passed
and two permission tests for the other platform were skipped. All seven terminal
process tests and all three compiled-dashboard tests passed, including six
runtime/account handoffs and two failure controls per host. Windows used Server
2025 build 10.0.26100 with Go 1.24.13 windows/amd64; macOS used 26.6.2 arm64;
Linux used the Ubuntu 24.04 runner. The record includes immutable runner-image
versions and the tested Git tree. No Docker Desktop or provider compatibility is
inferred from those placeholder process tests.

The separate [PR #396 Linux workflow job](https://github.com/kcenon/claude-docker/actions/runs/34361955529/job/102501032343)
executed the following live checks on merge checkout
`ef6860c9a68540c8f83ecfff7962cb894da74a80`, for PR head
`02fb25d3db16804ec1fbb05890677807112580b6`. These reports preserve their own image
IDs and source fingerprints; they are not measurements of a later commit or
replacements for the historical budget-review samples.

| Retained report | Passed / failed / skipped | Scope and cleanup |
|---|---|---|
| [Runtime workflows](benchmarks/issue-335/runtime-workflows-linux-pr396.json) | 27 / 0 / 35 | All three runtimes, two accounts, real Bash launcher/package/persistence work and enforced resource/security observations; all three fixtures cleaned up; authenticated and terminal rows remain incomplete |
| [Sandbox capability gate](benchmarks/issue-335/sandbox-platform-linux-pr396.json) | 3 / 0 / 0 | Unavailable capability refused before execution, including the degraded-settings override; fixture cleaned up; no authenticated inner-sandbox execution |
| [Daemon recovery](benchmarks/issue-335/daemon-recovery-linux-pr396.json) | 2 / 0 / 0 | Actual daemon interruption/recovery on an explicitly disposable Linux runner; fixture cleaned up |

The workflow host used Linux `6.17.0-1022-azure` x86_64, Docker Engine 28.0.4,
Compose 2.38.2 and cgroup v2. Each account's effective limits were 4 GiB memory,
2 CPU and 1024 PIDs, with the expected private tmpfs sizes and outer security
policy. Installed runtime versions were Claude Code 2.1.266, Codex CLI 0.153.4
and Gemini CLI 0.59.0. These observations are scoped to that runner and image.

## Budget decision test follow-up

The follow-up based on `6a85de92cf8fc4d515edb74f7d798166abb16c6d` fixes a test
failure that would occur after recording a valid accepted budget review.
`BudgetReviewTest.setUp()` read the published record, and both original tests
assumed its decision was pending. Substituting a valid accepted record in memory
before the fix produced two failures: `'pending' != 'accepted'` and an expected
validation exception not being raised. No published decision was changed for
this reproduction.

The suite now derives explicit pending, accepted and rejected fixtures from the
bound evidence, clearing decision fields before choosing each test state. A
separate test validates the real committed record in its recorded state. Tests
cover missing decision fields, evidence/scope corruption, invalid limits and
actual CLI exit codes with and without `--require-accepted`. The same ten-test
suite also passes when its input record is replaced in memory with either an
accepted or rejected fixture. Fixture identities and decision links are not
maintainer approvals.

[Local verification](benchmarks/issue-335/local-budget-review-verification-darwin-arm64.json)
records macOS arm64 execution on September 10, 2026:

| Check | Result and scope |
|---|---|
| Eight Python suites, including native terminal and compiled TUI | 47 passed, two native Windows ACL skips; 49 tests total |
| Budget suite with synthetic accepted/rejected input records | Ten tests passed for each state; 20 additional test executions |
| Resolved Compose boundaries | 18 models checked and nine disposable fixture preparations; zero live containers |
| Retained full benchmark | Valid, nine cells and 45 samples; original measurement provenance preserved |
| Published review | Valid pending record; `--require-accepted` correctly exits 1 |

The local Docker CLI/Compose and Go tools were available, but no Docker daemon
was reachable. Purpose-provided provider/GitHub inputs, the remaining native
Docker hosts and an explicit maintainer budget decision were not supplied for
this run. No new authenticated sessions, remote pushes, live Docker backend
claims or budget acceptance are recorded. The issue remains at 15/17 criteria;
the [workflow reproduction guide](ISSUE-335-WORKFLOWS.md) describes the remaining
runs. Image inputs, runtime behavior, resource defaults and raw benchmark files
are unchanged.
