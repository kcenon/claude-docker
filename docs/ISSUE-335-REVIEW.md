# Issue #335: completion evidence and budget decision

The local completion checks on `develop` at `07ea18f55aae3caf20028b56065b1e69b11e4aa1`
passed on September 10, 2026. Issue #335 remains incomplete: authenticated
workflows on the claimed Docker backends and a maintainer budget decision still
need evidence. This packet prepares that decision without changing the recorded
review state or the supported security contract.

## Available execution results

[The local report](benchmarks/issue-335/local-completion-verification-darwin-arm64.json)
records a clean source tree during execution, exact commands and tool versions:

| Check | Result |
|---|---|
| Ten native macOS Python suites | 64 passed; two native Windows DACL cases skipped |
| PTY and actual compiled dashboard controls | Both suites passed; controlled processes only |
| Real Compose resolution | 18 models passed |
| Disposable fixture preparation | Nine preparations passed; zero live containers |
| Retained full benchmark | Nine cells and 45 samples validated |
| Existing review structure | Valid, pending |
| Strict budget acceptance | Correctly failed with exit code 1 |
| Caller-selected local Docker endpoint | Daemon unavailable |

No new container, provider, remote-push or sandbox execution is claimed. The
checks demonstrated no additional product or harness defect. Runtime/image
inputs, resource defaults and raw measurements are unchanged.

## Concrete budget proposal

[The comparison](benchmarks/issue-335/budget-comparison-post-400.json) derives
these values from the reports already bound by
[budget-review.json](benchmarks/issue-335/budget-review.json). All eleven metrics
are within their existing proposals. Report hashes and measurement identities
are retained in the comparison; its timestamp describes analysis of existing
measurements, not a new benchmark run.

| Metric | Largest observed value | Proposed ceiling | Scope |
|---|---|---|---|
| Startup | 0.747 / 0.902 / 0.989 s | 2 / 2 / 2 s | 1/2/4-account Linux batches, all modes |
| Executable readiness | 0.864 / 1.134 / 1.453 s | 3 / 3 / 3 s | Same batches; CLI version readiness |
| Workload wall time | 1.333 / 1.718 / 3.249 s | 2 / 3 / 5 s | Concurrent Linux batches |
| Workload CPU | 1.33 / 2.98 / 6.53 CPU s | 3 / 6 / 12 CPU s | Sum over each Linux batch |
| Idle memory | 25.618 MiB | 64 MiB | Per account, cgroup memory |
| Lifetime memory peak | 118.403 MiB | 256 MiB | Per account, including cache/tmpfs |
| Lifetime PID peak | 34 | 64 | Per account |
| Scratch usage | 0 MiB | 16 MiB | Per account; diagnostic persistent-cache fixture |
| Allocated fixture storage | 31.567 MiB | 48 MiB | Deduplicated batch physical allocation / account count |
| Small dashboard input | 0.082 ms | 1 ms | Largest case median, local macOS refresh |
| Large dashboard input | 0.246 ms | 2 ms | Largest case median, local macOS refresh |

Displayed upper values are rounded upward. The JSON retains the exact values.
Timing maxima use all raw samples for each count across the three modes.
Resource peaks use individual accounts' idle, workload and after-workload
observations. Dashboard values recompute each case's median from five raw
timing estimates and select the largest median per input size.

The descriptive isolated-versus-shared median wall-time differences are
+1.08%, -1.12% and +5.39% at 1/2/4 accounts. At four accounts, the isolated
median CPU difference is +0.31%; median startup and executable readiness are
slightly lower. Fixed sample order, host cache effects and uncontrolled
background activity prevent a statistical significance claim. The reviewer
should address these observed differences explicitly when recording accepted
regressions.

The proposed ceilings apply to the retained offline npm fixture on its Linux
reference host and the separately measured local macOS dashboard fixture.
Four accounts remains the largest passing measured count for that offline
workload. Four 4 GiB memory ceilings total 16 GiB against a 15.62 GiB daemon.
These data cannot establish capacity for four authenticated agents. The
persistent-cache fixture's negligible scratch use cannot justify reducing
product tmpfs limits. Full protocol and provenance remain in
[PERFORMANCE.md](PERFORMANCE.md).

The review recommendation is to consider the existing numeric ceilings within
these narrow scopes and explicitly decide how to treat the observed mode
differences. The published decision remains **pending**. A maintainer decision
must supply the reviewer, actual date, supported GitHub decision URL, accepted
limits for all eleven metrics and an explicit accepted-regressions list.
The reviewer can accept the proposals or supply different numeric limits.
An empty regression list needs an explicit decision to accept none.

After the real decision is verified, update only the corresponding fields in
`budget-review.json` and run:

```bash
python3 tests/test_budget_review.py
python3 tests/budget_review.py docs/benchmarks/issue-335/budget-review.json --require-accepted
```

Raw reports keep their original provenance and pending-review metadata. A
passing comparison or validator does not authenticate a maintainer decision.

## Remaining integration inputs and evidence

| Required input/evidence | Current state | Next action |
|---|---|---|
| Private credential JSON | Not supplied | Designate an external private file with enabled models, two account mappings per runtime and an owned disposable GitHub remote |
| Linux Engine, macOS Desktop, native Windows Desktop, WSL2 and rootless hosts | Local daemon unavailable; other hosts not designated | Provide the actual hosts; retain a separate report per backend and the required Desktop application versions |
| Ordinary authenticated workflows | Retained Linux report has 35 integration skips | Execute provider/GitHub, package/write/recreation and wrapper/TUI scenarios using the existing runner |
| Requested inner sandbox | Retained Linux capability report establishes refusal only | Execute the probe under the actual profile, then authenticated Bash-tool work on a demonstrated compatible combination |
| Budget decision | Pending | Record the maintainer's explicit decision against this packet |

Use [ISSUE-335-WORKFLOWS.md](ISSUE-335-WORKFLOWS.md) for the credential schema,
native profile arguments and executable commands. An all-runtime ordinary
authenticated run can establish 60 passing rows while retaining two sandbox
skips and an `incomplete` status. Strict completion requires all 62 expected
rows, provenance and verified cleanup. Separate reports retain their original
outcomes when assembled into the platform evidence table.

## Requested-sandbox compatibility decision

The current gate requires namespace creation and a fresh `/proc` under the
outer container restrictions. Docker's
[default seccomp documentation](https://docs.docker.com/engine/security/seccomp/)
describes restrictions on namespace and mount system calls. Claude documents
[Bubblewrap failures inside unprivileged containers](https://code.claude.com/docs/en/sandboxing#troubleshooting)
and a weaker nested setting; this repository's contract refuses that setting.
These sources explain a compatibility concern, but no new host was tested in
this run and no general impossibility claim is made.

Preserve safe refusal and the outer policy while testing any candidate supported
combination. If no compatible combination is demonstrated, retain the unresolved
successful-execution requirement. The concrete scope proposal for a separate
maintainer decision is to classify the measured default Linux profile as
supporting outer-container isolation and safe nested-sandbox refusal, and track
successful nested execution separately until a compliant combination exists.
That proposal is **not adopted here**: the issue's acceptance criteria and the
62-row completion gate remain unchanged.
