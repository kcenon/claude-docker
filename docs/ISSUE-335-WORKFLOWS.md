# Reproducing issue #335 workflow evidence

These commands create unique disposable Compose projects, independent clones,
account state and placeholder credentials. They use the runtime registry and the
generated security/mount topology. Fixture-owned bind sources replace host
configuration sources; targets, access flags and security/resource policy are
checked before startup. The developer installation and HOME are not modified.

## Offline workflows

```bash
docker build -t claude-code-base:issue335-validation .
python3 tests/test_runtime_workflows.py --image claude-code-base:issue335-validation --runtime all --output runtime-workflows.json
python3 tests/test_sandbox_platform.py --image claude-code-base:issue335-validation --output sandbox-platform.json
```

Use `--language powershell` on native Windows with a Linux-container Docker
Desktop backend. PowerShell launchers intentionally refuse Linux/macOS; running
PowerShell unit fixtures on Linux does not establish native Desktop behavior.
Use the Bash launcher inside WSL2. `--plan` executes zero workflows.

Each runtime uses two accounts. Each account performs offline `npm ci`, build,
three package assertions including 5,000 verified file reads, a local Git commit,
global Git configuration and credential-helper setup. The first account repeats
package work after recreation. Missing authenticated sessions, pushes and Claude
terminal dispatch appear as explicit skipped cases. An ordinary offline run
fails on any executed failure; `--require-complete` also rejects skipped cases.

| Write location | Purpose | Recreation expectation |
|---|---|---|
| Account workspace | Source edits, generated build/test files, local Git commits | Persistent bind |
| Workspace `node_modules` | Locked local dependency and package-manager working tree | Persistent private volume |
| Registry `containerConfigMount` | Runtime settings/session/auth state and global Git configuration | Persistent account bind |
| `/tmp` | Temporary files and runtime helper work | Rebuilt tmpfs |
| `/home/node/.config` | Client configuration scratch | Rebuilt tmpfs |
| `/home/node/.cache`, `.npm`, `.agents` | Runtime and default npm scratch | Rebuilt tmpfs |

Persistence markers are checked before fresh writes after recreation. The package
workflow uses npm's real default cache. The comparable performance matrix instead
uses an explicitly located persistent dependency-volume npm cache in every mode;
the report records that different cache protocol.

The sandbox check enables the requested inner sandbox under the actual generated
container restrictions. It requires either the successful bounded capability
probe and command execution or the precise unsupported-kernel refusal before
command execution, including with the degraded-settings override. It records
which outcome occurred. This is separate from an authenticated runtime session.

## Explicit authenticated integration

Provide a private, caller-owned JSON file outside the repository. The harness
does not search for credentials. On POSIX create it with mode `0600`; on Windows
use an account-only ACL. Each selected runtime needs a model and exactly two
account rows. Populate the following structure with purpose-provided test keys;
the values shown here are placeholders, not usable credentials.

```json
{
  "disposable": true,
  "github_remote": "https://github.com/TEST-OWNER/DISPOSABLE-REPOSITORY.git",
  "timeout_seconds": 120,
  "claude_max_budget_usd": 0.25,
  "runtimes": {
    "claude": {
      "model": "TEST-MODEL",
      "accounts": [
        {"api_key": "TEST-PROVIDER-A", "github_user": "TEST-USER-A", "github_token": "TEST-GITHUB-A"},
        {"api_key": "TEST-PROVIDER-B", "github_user": "TEST-USER-B", "github_token": "TEST-GITHUB-B"}
      ]
    }
  }
}
```

Add `codex` and `gemini` objects with the same fields for `--runtime all`. Use
models enabled for the supplied test accounts. Credentials must contain only
letters, digits, `_./+=:-`; dotenv interpolation/quote syntax is refused. Remote
URLs must be plain HTTPS GitHub repository URLs without embedded credentials.
Tokens must be able to create and remove test refs on that disposable repository.
The file must be owned by the calling account. Native Windows checks the owner
and every grant in the opened file's DACL before reading, and refuses reparse
points, inherited grants to other identities and a missing DACL. POSIX checks
the opened regular file's owner and mode without following symlinks. Neither
loader changes a caller's permissions.

```bash
python3 tests/test_runtime_workflows.py --image claude-code-base:issue335-validation --runtime all --credentials-file /private/test-credentials.json --terminal --requested-inner-sandbox --require-complete --output authenticated-workflows.json
```

Each runtime must copy a fresh nonce from a disposable input file through its
actual file tools. The prompt does not contain the nonce. Both account mappings
execute a session and push a commit from inside their containers using the GitHub
credential helper. Ref names are unique to the fixture; a pre-existing ref is
refused. `gh api user` must match the configured account; only the match result is
published. Creation uses an empty SHA lease so a racing ref is also refused.
The created SHA is read back. Cleanup uses a SHA lease only to delete the
ref created by this test, so an external update prevents deletion. No branch
history is overwritten. A cleanup refusal/failure makes the report fail.

The first account repeats its session after recreation. Claude must dispatch its
SessionStart hook. `--terminal` exercises both accounts through the actual shell
wrapper and a freshly compiled Go dashboard for every selected runtime. It
requires Go 1.24+ on the test host. The binary and HOME are inside the disposable
fixture so project/state discovery cannot select the developer installation.
The dashboard selects an account, attaches through `tea.ExecProcess`, exits the
runtime with `/exit`, then must respond to a fresh help key before quitting.
Attached-command failures remain visible after the dashboard restores its screen.

POSIX PTYs and native Windows ConPTY use explicit 160×48 dimensions, continuously
drained output, bounded waits and process-tree cleanup. Only a capped in-memory
buffer is used; no terminal transcript is retained. The live check observes the
installed runtime process in the selected container and rejects a sibling launch.
Claude must dispatch fresh account-local hook and statusline challenges; earlier
headless/terminal markers cannot satisfy a later check. Codex/Gemini record this
Claude-specific contract as inapplicable. Terminal sessions submit no model task.

`--requested-inner-sandbox` adds two bounded Claude sessions with the restrictive
sandbox settings enabled. Each must copy a fresh nonce through the real Bash tool
and produce a mount-namespace observation distinct from the outer container.
The effective settings are checked before execution. An unavailable capability
fails this authenticated scenario; it does not count as successful sandboxed work.
Run `tests/test_sandbox_platform.py` separately to retain the existing precise
refusal evidence, including the degraded-settings override. The known Linux
AppArmor/default-seccomp profile may therefore collect successful ordinary
authenticated rows while its requested-sandbox rows fail. A compatible profile
must supply the outstanding successful sandbox evidence without weaker security.

Each provider command has a container-side timeout of 10–300 seconds plus a
five-second termination grace. Claude also has a three-turn and configurable
per-session USD limit (default 0.25, maximum 5). There are three sessions per
runtime, plus two Claude sessions when the sandbox scenario is selected; the
timeout bounds Codex/Gemini execution but is not a dollar ceiling.
Output is captured in memory and discarded. Reports contain allowlisted
version/model/result metadata and failure categories, without command output,
provider transcripts, environment dumps, authentication files or container logs.

Adapters check the installed CLI help before invoking flags. Their contracts
follow [Claude headless execution](https://code.claude.com/docs/en/headless),
[Claude CLI flags](https://code.claude.com/docs/en/cli-reference),
[Codex authentication](https://learn.chatgpt.com/docs/auth),
[Codex CLI commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
and [Gemini headless execution](https://geminicli.com/docs/cli/headless/).
An unsupported installed version is a failed compatibility case.

The `Authenticated isolation integration` dispatch workflow runs only on trusted
`main`/`develop` refs, after explicit disposable-remote selection, using the
`issue335-integration` environment's `ISSUE335_TEST_CREDENTIALS` JSON secret.
Secrets are scoped to the execution step and removed from the child environment;
the private temporary file is removed in `finally`. Fork PR jobs use placeholders.
GitHub must have the dispatch workflow on its default branch before dispatch is
available. Local execution supports reviewing the interface before that merge.
On 2026-09-09, default `main` at `86cca385e7f8b8b5f46e943d8c189b2b000cb18b`
does not contain this workflow. Use local execution until the normal release
process places it on `main`; the repository's release policy is unchanged.

## Native platform execution

Use a separate report per actual host/backend. `--profile` asserts that the
observed host and daemon match the claimed platform. Desktop runs also require
`--desktop-version VERSION_FROM_ABOUT`; that value is labelled as explicit
operator input. The Engine and Compose versions are queried independently.
`docker desktop version` reports its CLI plugin version, so it cannot substitute
for the Desktop application version.
The harness freezes the selected local Unix/named-pipe daemon endpoint before
using fixture HOME, so Desktop/rootless context selection survives the TUI's
private state discovery. Remote endpoints are refused: these bind fixtures
require a daemon that can access the test host's disposable directories.

| Native host/backend | Additional options | Evidence still required |
|---|---|---|
| Linux Engine | `--profile linux-engine --language bash` | Authenticated sessions/pushes and live terminal/TUI |
| macOS Docker Desktop | `--profile macos-desktop --language bash --desktop-version VERSION` | Live workflows, boundaries and enforced resources |
| Windows PowerShell + Linux-container Desktop | `--profile windows-desktop --language powershell --desktop-version VERSION` | Native ConPTY plus live workflows/boundaries/resources |
| WSL2 Bash + Desktop integration | `--profile wsl2-desktop --language bash --desktop-version VERSION` | Actual WSL2 workflows/boundaries/resources |
| Rootless Linux | `--profile linux-rootless --language bash` | Actual rootless workflows/boundaries/resources |

Run the authenticated command, offline command, sandbox refusal probe and
`bash tests/test_container_isolation.sh --image IMAGE --runtime all` on each
claimed profile. Native Windows uses `python tests/test_container_isolation.py
--image IMAGE --runtime all`; its fixtures select PowerShell. Also run the
boundary harness with `--runtime claude --external` to distinguish outbound
transport from provider authentication. Every workflow fixture compares actual
cgroup CPU, memory and PID limits and mounted scratch sizes to the resolved
configuration, and verifies UID, capabilities, seccomp, no-new-privileges and
read-only root. Missing enforcement is a failed case, including on rootless
backends. Native process tests cannot establish these container properties.

The placeholder terminal tests need no Docker daemon or provider keys:

```bash
python3 tests/test_credential_file.py
python3 tests/run_terminal_suite.py test_terminal_support.py
python3 tests/run_terminal_suite.py test_tui_terminal.py
```

The last command builds the actual dashboard and a native disposable Docker
process adapter. It checks six account/runtime handoffs plus wrong-account and
failed-child controls. It establishes UI handoff behavior; real installed runtime
and container compatibility are covered only by the live command above.
The supervisor gives each placeholder suite a three-minute deadline and keeps
native console handles separate from CI's output pipes. Its temporary diagnostics
contain test names and failures only; live provider sessions never use this
diagnostic wrapper.

The [retained PR #396 Linux report](benchmarks/issue-335/runtime-workflows-linux-pr396.json)
records 27 passing checks, zero failures and 35 explicit integration skips.
Resource/security observations and all three fixture cleanups passed. The
[validation guide](ISSUE-335-VALIDATION.md#terminal-and-completion-follow-up)
identifies the tested merge checkout, runtime versions, separate refusal and
daemon-recovery evidence, and outstanding platform/authentication requirements.

## Interrupted operations

```bash
python3 tests/test_lifecycle_process.py
```

This launches the real native wrapper and Python process chain with a test-owned
Docker process adapter. Deterministic barriers cover staging, partial publication,
partial application and interrupted compensation. POSIX signals and hard kills,
native Windows process termination/console break, live-owner refusal, concurrent
recovery refusal and connection-failure recovery are separate cases. Managed
bytes/modes, Windows ACLs, running/stopped selections, owned additions, unrelated
account writes and a second public `recover` invocation are checked. Only copied
test policy code receives the publication barrier. These are process recovery
checks, not a universal power-loss durability claim.

The separate `Actual daemon restart and recovery` CI job starts two real services,
leaves one stopped, applies scaling, stops its disposable runner's Docker service
and socket during the transaction, retains the failed compensation journal,
restarts the daemon and invokes public recovery. Its entry point is deliberately
restricted to an explicit GitHub-hosted Linux runner with its local daemon and no
unrelated containers:

```bash
python3 tests/test_daemon_recovery.py --image claude-code-base:issue335-validation --disposable-github-runner --output daemon-recovery.json
```

The harness refuses a developer workstation or remote Docker context. Reports
from actual daemon restart and simulated connection failure remain separate.

## Reports and platform scope

New workflow reports use schema `2`; retained #395 reports keep their original
schema `1`. Workflow reports include selected runtimes, requested scenarios,
case status/reason, executed/passed/failed/skipped counts and sanitized
source/image/host/daemon provenance. The all-runtime contract has 62 distinct
rows: 22 Claude and 20 each for Codex/Gemini. Missing prerequisites retain skipped
rows, including after setup failure. Missing/duplicate/unfinished cases, absent
provenance and unsuccessful cleanup cannot produce a complete report.
`--require-complete` rejects all required skips, including unselected terminal
and sandbox scenarios. Benchmark reports have their separate schema `2` and
validator. CI retains available reports on success and
failure; an absent required artifact fails upload. Skipped authenticated cases
and unexecuted platforms cannot satisfy issue #335 completion.

See [the validation table](ISSUE-335-VALIDATION.md) for exact executed platforms
and workflow links, and [performance evidence](PERFORMANCE.md) for measured
capacity and proposed budgets.
