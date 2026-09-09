# Performance

The current dashboard refresh path has measured results below. A real-container
benchmark driver now covers `shared`, `worktree`, and `isolated` at 1, 2, and 4
accounts. **The container matrix has not been measured in this implementation
environment: no Docker daemon is available.** No supported simultaneous account
count or reviewed container performance budget is claimed.

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

```bash
# Build once, then record its immutable image ID/digest in the report.
docker build -t claude-code-base:benchmark .
python3 tests/benchmark_isolation.py --image claude-code-base:benchmark --samples 5 --output docs/benchmarks/container-matrix.json
# Optional: include a measured cached image build before the matrix.
python3 tests/benchmark_isolation.py --prepare-image --image claude-code-base:benchmark --samples 5 --output docs/benchmarks/container-matrix.json
# No daemon, files, or workloads are changed by plan mode.
python3 tests/benchmark_isolation.py --plan
```

The driver records source commit and content fingerprint, image ID/digests,
runtime/Compose/Engine versions, platform and Docker VM CPU/memory capacity.
All repositories, account roots and credentials are disposable fixtures. An
explicit mount override and resolved-source assertions keep the developer HOME
unchanged and exclude real state/configuration paths.

Each of nine cells records setup/clone cost and the initial container/workload
separately, followed by at least five warm `stop`/`up` samples. Cache data is
retained between measured samples; kernel caches are not flushed. Startup means
Compose reports running containers. Executable readiness adds the installed
CLI's `--version`; **neither proves an authenticated agent session**. The workload
writes 1000 × 32 KiB files, performs 5000 Node hash/read checks, writes a private
dependency cache and runs Git status, concurrently across accounts.

Raw samples and median/sample-variance summaries include startup, executable
readiness, idle/observed peak memory, workload CPU/wall time, and per-account
workspace/Git/dependency/state apparent and allocated bytes. Docker stats sampling
can miss short memory spikes; timestamps are recorded rather than claiming an
exact peak. Shared/worktree Git storage is reported logically per account and
must not be summed as physical storage. Docker Desktop compression and sparse VM
allocation are not measured. A prepared image excludes its historical build/pull
cost unless `--prepare-image` is selected.

CI executes all twelve dashboard benchmark cases once and tests the nine-cell
matrix/statistics driver using known synthetic samples. The live image job also
runs `--smoke`, one isolated/1-account cell with five measured samples; that job
has not run for this local working tree. Plans and synthetic statistics are not
container performance measurements. Full container results, Windows/Linux
comparison, authenticated provider/push checks and budget review remain required
before closing issue #335. The parser ceiling of 702 is not a capacity statement.
