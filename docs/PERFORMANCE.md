# Performance

The reference Linux container matrix has **nine completed cells and 45 measured
samples** for the offline npm workload. Four concurrent accounts passed on that
runner. These measurements and the dashboard results below have proposed budgets
awaiting maintainer review; they do not establish authenticated agent capacity.

## Current dashboard path

`Manager.ListAccounts` reads account-local limitline data and enriches the account
list. The unused JSONL parser/cache remains removed; large `projects/` histories
are present only as irrelevant synthetic data in this benchmark. The Docker
listing is mocked as stopped; credentials are absent, so auth/API calls do not
participate. This measures local refresh work, not the duration of a live Docker
or authenticated provider request.

```bash
cd tui
go test ./internal/account -run '^$' -bench BenchmarkListAccounts -benchtime=100ms -count=5 -benchmem
```

Measured on 2026-09-08, Apple M4 Max, macOS arm64, Go 1.27.1, the implementation
working tree based on `4eb55c0`. Each case has five timing estimates. Setup and
history creation are excluded. Other workstation activity was not excluded.
[Raw output](benchmarks/issue-335/dashboard-darwin-arm64.txt) and
[machine-readable samples/provenance](benchmarks/issue-335/dashboard-darwin-arm64.json)
are stored with the source so these provisional numbers can be checked.

| Accounts | History files/account | Limitline padding bytes | Median µs/op | Sample variance (µs/op)² | Samples |
|---|---|---|---|---|---|
| 1 | 10 | 256 | 30.20 | 0.11 | 5 |
| 1 | 10 | 65536 | 71.11 | 0.13 | 5 |
| 1 | 10000 | 256 | 30.59 | 0.04 | 5 |
| 1 | 10000 | 65536 | 71.73 | 0.06 | 5 |
| 2 | 10 | 256 | 47.15 | 0.15 | 5 |
| 2 | 10 | 65536 | 128.76 | 0.05 | 5 |
| 2 | 10000 | 256 | 47.71 | 45.43 | 5 |
| 2 | 10000 | 65536 | 129.61 | 0.09 | 5 |
| 4 | 10 | 256 | 81.88 | 0.22 | 5 |
| 4 | 10 | 65536 | 244.89 | 0.54 | 5 |
| 4 | 10000 | 256 | 81.11 | 0.19 | 5 |
| 4 | 10000 | 65536 | 245.30 | 1.87 | 5 |

The 10,000-file history cases do not add a recursive scan. Increasing current
limitline input does increase parsing/allocation work, as expected. The
`no_jsonl_pipeline_test.go` regression remains active. These measurements do not
restore or reuse the deleted usage-cache benchmark.

**Proposed local-work budgets, pending review:** at most 1 ms per refresh for
1/2/4 accounts with a 256-byte padding fixture; at most 2 ms for the 64 KiB case
on this workstation. These are generous starting ceilings above the measured
medians, not CI timing gates or promises for other hardware. Docker/auth network
latency is outside these budgets. Measure Linux/Windows before adopting them.

## Container matrix

Collected on 2026-09-09 in [workflow run 34348122253](https://github.com/kcenon/claude-docker/actions/runs/34348122253)
for [PR #395](https://github.com/kcenon/claude-docker/pull/395), head
`e1b2cfee9e9393277ed47745669ffd37ffa1f030`. GitHub checked out merge commit
`2af2343207927713f17cc4ec33d21c1b1652580d`; the clean source fingerprint is
`9b8977519d3e5c25e45b9ece70298283c0d25a49217b262c8716132355899937`.
The measured image is
`sha256:06dadcd0b2d54a06363f23e426cf7e5688df577139b4cfdfe1727674e65cb20e`.

The GitHub-hosted reference daemon reports Ubuntu 24.04.4, x86_64, kernel
6.17.0-1022-azure, four CPUs and 16,766,414,848 bytes (15.62 GiB) RAM. Engine
28.0.4 and Compose 2.38.2 use overlay2, cgroup v2, AppArmor and the built-in
seccomp profile, with no rootless security option. The container UID/GID is 1001.
Claude 2.1.266, Node 20.18.1 and npm 10.8.2 ran from one immutable image.
No authenticated tasks were run in this performance profile.

[Complete raw report](benchmarks/issue-335/container-linux-x86_64-claude.json) and
[validated summaries with sample variance and units](benchmarks/issue-335/container-linux-x86_64-claude-summary.json)
are committed. All nine cells cleaned up successfully. No failed sample or
outlier was removed from this completed run. The earlier failed collection is
retained as a CI diagnostic, not combined with these samples.

The table shows medians across five samples per cell. Memory and CPU are
aggregates across the concurrent accounts; wall time covers the concurrent batch.

| Mode | Accounts | Startup s | Executable ready s | Workload s | CPU s | Idle MiB | Observed peak MiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| shared | 1 | 0.727 | 0.842 | 1.265 | 1.290 | 23.551 | 108.727 |
| shared | 2 | 0.852 | 1.082 | 1.669 | 2.930 | 45.348 | 226.047 |
| shared | 4 | 0.982 | 1.441 | 2.938 | 6.390 | 93.508 | 257.332 |
| worktree | 1 | 0.745 | 0.860 | 1.305 | 1.310 | 23.359 | 107.059 |
| worktree | 2 | 0.867 | 1.097 | 1.633 | 2.900 | 46.848 | 227.973 |
| worktree | 4 | 0.966 | 1.419 | 3.093 | 6.470 | 93.254 | 274.930 |
| isolated | 1 | 0.740 | 0.853 | 1.278 | 1.290 | 23.332 | 108.543 |
| isolated | 2 | 0.871 | 1.101 | 1.651 | 2.930 | 47.441 | 228.582 |
| isolated | 4 | 0.974 | 1.422 | 3.097 | 6.410 | 93.969 | 279.094 |

### Protocol and reproduction

```bash
docker build -t claude-code-base:benchmark .
python3 tests/benchmark_isolation.py --image claude-code-base:benchmark --samples 5 --output container-matrix.json
python3 tests/benchmark_report.py container-matrix.json --require-full
python3 tests/benchmark_report.py container-matrix.json --require-full --summary > container-summary.json
# A plan executes no workload and creates no fixtures.
python3 tests/benchmark_isolation.py --plan
```

The nine cells run shared, worktree, then isolated, each at 1/2/4 accounts. Setup,
cloning, initial startup and initial workload are recorded separately from five
stop/up samples. Startup ends when Compose reports running; executable readiness
adds CLI `--version`. Neither is authenticated readiness. Stop time is excluded.
No host page-cache flush or background-load isolation was attempted. Sample order
can affect cache/scheduling and these small differences do not establish a
statistically significant ranking of modes.

Every account uses the same offline locked local npm package: `npm ci`, a build
of 1,000 × 32 KiB files, three test assertions including 5,000 full hash/read
checks, then Git status. Builds and tests run concurrently across accounts using
account-specific output paths. Five samples × 21 account placements give 105
measured account workloads, 315 package assertions and 525,000 verified reads;
initial workloads are additional. A deliberate corrupt-file control must fail.

The persistent dependency-volume npm cache is explicit and private in every
mode. It avoids relying on an image-owned home directory for arbitrary host UIDs
in shared mode. Stop/start retains that cache and clears isolated tmpfs. This is
not a uniformly warm profile. The separate [runtime workflow](ISSUE-335-WORKFLOWS.md)
tests npm's default scratch cache and writes after recreation.

Cgroup total memory is distinct from the cache-adjusted Docker CLI idle reading.
The sampler retains actual start/end times and requires a complete observation
inside each workload interval. Short spikes can be missed: the table reports
observed peaks. Per-account cgroup lifetime memory/PID peaks and OOM counters are
also retained before/after work; cgroup lifetime counters are not reset at the
start of just the workload. All OOM deltas are zero. This benchmark profile requires
cgroup v2: a missing OOM counter fails collection instead of becoming a zero.
These raw counters, including
filesystem cache and tmpfs, are the basis for headroom discussion. The Linux
[Docker stats CLI subtracts cache](https://docs.docker.com/reference/cli/docker/container/stats/).

Storage has both apparent and allocated bytes and separate workspace, Git,
dependency and runtime-state categories. Aggregate totals deduplicate shared
physical sources while preserving each account's logical view. At four accounts,
maximum allocated totals were 125.60 MiB shared, 125.83 MiB worktree and 126.17 MiB
isolated. These are filesystems inside the Linux daemon, excluding image layers,
logs and Desktop sparse-image/compression overhead. Build/pull cost is excluded;
`--prepare-image` separately measures a cached build when requested.

Reports use schema 2, explicit scope/status, planned and executed cells,
per-account results, raw samples, summaries and allowlisted provenance. The
fingerprint covers measurement code, fixture, lockfile/workload and image/config
inputs while excluding reports and credentials. Incomplete/interrupted reports
remain useful diagnostics and fail validation. The validator recomputes summaries;
only variance rounding within four floating-point units is tolerated across
Python releases. Nonfinite/negative/missing measurements, inconsistent counts,
missing sampler coverage, OOM kills and cleanup failure remain failures.

### Proposed budgets and capacity

These are review proposals for this exact npm workload on the four-CPU Linux
reference host, for every tested mode. They are not new product defaults, enforced
CI timing gates, or budgets for provider sessions. The allowance uses the largest
observed value across all modes/counts and leaves scheduling/headroom margin.

| Metric | Largest measured value | Proposed ceiling | Scope / allowance |
|---|---:|---:|---|
| Startup | 0.989 s | 2 s | Each 1/2/4-account batch; about 2× margin |
| Executable readiness | 1.453 s | 3 s | Batch including CLI version checks; about 2× margin |
| Workload wall time | 1.333 / 1.717 / 3.249 s | 2 / 3 / 5 s | 1/2/4 concurrent accounts |
| Aggregate workload CPU | 1.33 / 2.98 / 6.53 CPU s | 3 / 6 / 12 CPU s | 1/2/4 accounts; batch CPU is a sum |
| Idle cgroup memory | Below 27 MiB/account | 64 MiB/account | Reference fixture only |
| Cgroup lifetime memory peak | 118.41 MiB/account | 256 MiB/account | More than 2× measured peak; includes cache/tmpfs |
| PID lifetime peak | 34/account | 64/account | Allows 30 additional processes for fixture variation |
| Isolated scratch observed use | 0 bytes | 16 MiB/account diagnostic ceiling | Persistent-cache profile exercises little scratch; no justification to reduce product tmpfs |
| Total allocated fixture storage | 126.17 MiB at 4 accounts | 48 MiB/account | About 50% allowance above this fixed fixture |
| Local dashboard refresh | 0.082 / 0.246 ms maximum median | 1 / 2 ms | Existing macOS small/large-input proposals; Docker/auth excluded |

At four accounts the configured ceilings are eight CPUs and 16 GiB memory,
with reservations of four CPUs and 8 GiB. Memory ceilings exceed the daemon's
15.62 GiB and leave no host margin if every account reaches its cap. The observed
batch memory peaks reached 354.31 MiB for this small workload. That observation
cannot justify allowing four full agent sessions to consume their ceilings.
Isolated scratch has a 672 MiB cap per account (2.625 GiB aggregate), charged
inside the memory cgroups, not additional reserved memory. Node heap remains
3,072 MiB inside each 4 GiB limit, and the configured PID limit remains 1,024.

**Four is the largest tested passing count for this deterministic workload.**
The parser range of 1–702 is not a capacity promise. Provider tools, larger
repositories/dependencies and unrelated daemon workloads still need measurement.
Mac/Windows Desktop and rootless results are required before extending this
profile to those backends.

Budget review remains pending after [PR #395](https://github.com/kcenon/claude-docker/pull/395) merged.
No maintainer acceptance date or accepted regression has been recorded. Issue
#335's budget/capacity criterion stays open until that review and the remaining
workflow/platform evidence are available.

The concrete [review record](benchmarks/issue-335/budget-review.json) binds each
proposal to the retained report's SHA-256, source identity, workload and host.
It includes all nine Linux metrics and both separately scoped macOS dashboard
budgets, with explicit units and per-account/batch scope. Acceptance values,
reviewer, date, decision link and accepted regressions are deliberately unset.
Populate them only from an explicit maintainer decision; a merge or benchmark
pass is not approval. The raw measurement files retain their original provenance
and pending-review field even after a separate review record is accepted.

```bash
python3 tests/test_budget_review.py
python3 tests/benchmark_report.py docs/benchmarks/issue-335/container-linux-x86_64-claude.json --require-full
python3 tests/budget_review.py docs/benchmarks/issue-335/budget-review.json
# Exits nonzero while the decision is pending or rejected.
python3 tests/budget_review.py docs/benchmarks/issue-335/budget-review.json --require-accepted
```

The review tests construct pending, accepted and rejected fixtures independently
of the published decision, and separately validate the actual committed record.
Recording a real decision therefore does not invalidate the pending-state tests.
Synthetic fixture decisions establish test behavior only. The review validator
checks bindings and decision-field completeness; a reviewer must verify the
linked maintainer decision itself.

The terminal follow-up changed test coverage and attach-error display; the
budget-decision follow-up changes tests and documentation. Neither changes the
measured npm workload, container image, resource/security configuration, sampling
implementation or `Manager.ListAccounts` benchmark. The retained measurements
were revalidated, not relabelled as measurements of a later tree. Rerun the full
matrix when those measurement inputs change, and keep other backend reports
separate.
