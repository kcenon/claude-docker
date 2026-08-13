# Performance

Measured behaviour and the benchmarks that produce it.

This document currently covers the TUI usage cache only. Container startup,
memory, and disk benchmarks for the `shared`, `worktree`, and `isolated`
modes are tracked separately in issue #335 and are **not** in this file yet;
see [Not covered yet](#not-covered-yet).

Absolute figures below are machine-specific. What the benchmark is designed
to establish is the *relationship* between the two arms, which is stable
across machines.

## TUI usage cache

### What it does

The dashboard recomputes each account's token summary on every refresh by
walking that account's `projects` directory and parsing every `.jsonl`
session file. `usage.Cache` memoizes the parsed result per file, keyed on
path plus size plus mtime, so a refresh that changes nothing re-reads
nothing. One `Cache` lives on the `account.Manager` and is shared by every
account in a refresh.

### Why pruning is scoped per account

A scan can only build a "seen" set for the tree it walked. Pruning the whole
cache against that set therefore deletes every *other* account's entries as
a side effect of scanning one account. With two accounts alternating, each
scan evicts the other and the cache stops being a cache — every refresh
reparses the full history of both accounts, and the cost grows with history
rather than with what changed.

`Cache.pruneScope` therefore restricts the sweep to entries under the
scanned root, and `Cache.RetainRoots` runs once at the end of a refresh to
release entries under roots that are no longer scanned at all (an account
that has gone away). Scoped pruning alone cannot reclaim those, because
nothing walks that tree any more.

### Running the benchmark

```bash
cd tui
go test ./internal/usage -run '^$' -bench BenchmarkAlternatingAccountScans -benchmem -count=5
```

`BenchmarkAlternatingAccountScans` reproduces the refresh pattern: two
accounts, each with a synthetic history, scanned one after the other. The
`cache=off` arm uses no cache and is the baseline; the `cache=on` arm shares
one cache across both accounts, as the dashboard does.

### Measured results

Windows 11, amd64, Intel Core i5-14600KF (20 logical CPUs), Go 1.24. Each
session file holds 40 assistant entries. Median of 5 samples; the range
across those samples is given because the `cache=off` arm is GC-bound and
therefore noisy.

| History per account | `cache=off` | `cache=on` | Ratio |
|---|---|---|---|
| 20 files | 8.29 ms (8.16–11.52) | 0.216 ms (0.213–0.300) | 38x |
| 400 files | 275 ms (245–516) | 0.880 ms (0.866–1.197) | 313x |

Allocation per refresh, which varies far less than wall time:

| History per account | `cache=off` | `cache=on` |
|---|---|---|
| 20 files | 43.3 MB, 19,858 allocs | 32.2 KB, 214 allocs |
| 400 files | 862.7 MB, 396,070 allocs | 574 KB, 3,286 allocs |

Two things to read out of this:

- **The arms scale differently.** Twenty times more history costs the
  uncached arm 33x more time, but the cached arm only 4x. What remains in
  the cached arm is directory walking and `stat`, not parsing, so its cost
  tracks file *count* rather than accumulated content.
- **The gap is mostly allocation.** At 400 files the uncached arm allocates
  roughly 863 MB per refresh. That is the number that made this defect worth
  fixing rather than the wall time: a dashboard refreshing on a timer was
  producing that garbage repeatedly.

### What a regression looks like

If per-account scoping regresses to a whole-cache sweep, the two accounts
evict each other every round and `cache=on` collapses onto the `cache=off`
figures. That convergence is the signal, not any absolute number.
`TestCacheAlternatingAccountsRetainEntries` fails first and more cheaply, so
the benchmark is corroboration rather than the gate.

## Not covered yet

Issue #335 stage 5 also asks for a Node heap limit validated against the
container memory cap, per-account and aggregate resource budgets surfaced
before startup, transactional `scale`, and a reproducible 1/2/4-account
benchmark matrix across all three isolation modes recording startup time,
idle and peak memory, CPU and wall time for a representative workload, and
disk usage. None of that is measured here. Until it is, this file is not a
capacity statement, and the syntactic account ceiling described in
[`README.md`](../README.md) remains a parser range rather than a supported
simultaneous capacity.
