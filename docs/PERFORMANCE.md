# Performance

Measured behaviour and the benchmarks that produce it.

**There are currently no benchmarks in this repository.** The one it had
measured the TUI usage cache, which was removed along with the JSONL pipeline
it served; the section below records what that was and why it went. Container
startup, memory, and disk benchmarks for the `shared`, `worktree`, and
`isolated` modes are tracked in issue #335 and are **not** in this file yet;
see [Not covered yet](#not-covered-yet).

## The TUI usage cache, removed

`usage.Cache` memoized parsed `.jsonl` session files per account, keyed on
path plus size plus mtime, so a dashboard refresh that changed nothing
re-parsed nothing. It backed `Account.Tokens`.

`Account.Tokens` was written on every refresh and read only by a function with
no caller — the "fallback when limitline is unavailable" it documented was
never implemented. Filling it walked
`~/.claude-state/account-*/projects/**.jsonl` on every refresh and every
`--json` invocation, for a value nothing rendered. #358 removed the field and
the walk; the package that served them was removed once that decision could be
taken on its own terms, and the benchmark went with it, because its only
subject was the package.

Until that happened this document described the walk in the present tense, as
did `README.md`. A cache measured by a benchmark, documented in two places, and
reached by nothing is worse than no cache: every reader of those documents
learned something about the product that was not true.

The measurements are in the git history along with the code
(`tui/internal/usage`, removed after `v2026.08.17.5`). One finding is worth
keeping in prose because it is a property of the design and not of the
implementation:

> A scan can only build a "seen" set for the tree it walked, so pruning the
> whole cache against that set deletes every *other* account's entries as a
> side effect of scanning one account. With two accounts alternating, each
> scan evicts the other and the cache stops being a cache — every refresh
> re-parses everything while reporting a hit rate that looks fine. Pruning has
> to be scoped to the tree that was walked.

Anything cache-shaped added here later has the same trap available to it.

## Not covered yet

Issue #335 stage 5 also asks for per-account and aggregate resource budgets
surfaced before startup, transactional `scale`, and a reproducible
1/2/4-account benchmark matrix across all three isolation modes recording
startup time, idle and peak memory, CPU and wall time for a representative
workload, and disk usage. None of that is measured here. Until it is, this
file is not a capacity statement, and the syntactic account ceiling described
in [`README.md`](../README.md) remains a parser range rather than a supported
simultaneous capacity.

The stage-5 item this file used to list first — a Node heap limit validated
against the container memory cap — has since been implemented and is
documented under [Node heap headroom](../README.md#node-heap-headroom). It is
worth being precise about what that did and did not settle: the heap now
cannot exceed the cap, but the headroom it reserves is a stated convention
rather than a measured non-heap footprint. Measuring it is part of the
benchmark matrix above, and one of the things this file will be able to
replace a convention with once that exists.

## Adding a benchmark

The `go-test` CI job runs `go test ./... -run '^$' -bench . -benchtime=1x`,
which executes every benchmark once — enough to catch a harness that panics,
too few iterations to be a flaky gate. The step compares the number of
benchmarks it executed against the number defined in the tree, so a benchmark
that exists but never runs fails CI rather than passing quietly. Absolute
figures belong here; the job does not assert on them.
