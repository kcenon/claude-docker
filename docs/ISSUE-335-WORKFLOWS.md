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

```bash
python3 tests/test_runtime_workflows.py --image claude-code-base:issue335-validation --runtime all --credentials-file /private/test-credentials.json --terminal --require-complete --output authenticated-workflows.json
```

Each runtime must copy a fresh nonce from a disposable input file through its
actual file tools. The prompt does not contain the nonce. Both account mappings
execute a session and push a commit from inside their containers using the GitHub
credential helper. Ref names are unique to the fixture; a pre-existing ref is
refused. The created SHA is read back. Cleanup uses a SHA lease only to delete the
ref created by this test, so an external update prevents deletion. No branch
history is overwritten. A cleanup refusal/failure makes the report fail.

The first account repeats its session after recreation. Claude must dispatch its
SessionStart hook. `--terminal` opens a bounded actual launcher attach session to
observe Claude statusline dispatch; it submits no model task. Its PTY adapter
currently requires POSIX. Native Windows terminal/TUI evidence remains required.
Codex/Gemini do not use the Claude-specific hook/statusline contract.

Each provider command has a container-side timeout of 10–300 seconds plus a
five-second termination grace. Claude also has a three-turn and configurable
per-session USD limit (default 0.25, maximum 5). There are three sessions per
runtime; the timeout bounds Codex/Gemini execution but is not a dollar ceiling.
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

Workflow reports have schema `1`, case status/reason, executed/passed/failed/skipped
counts and sanitized source/image/daemon provenance. Benchmark reports have their
separate schema `2` and validator. CI retains available reports on success and
failure; an absent required artifact fails upload. Skipped authenticated cases
and unexecuted platforms cannot satisfy issue #335 completion.

See [the validation table](ISSUE-335-VALIDATION.md) for exact executed platforms
and workflow links, and [performance evidence](PERFORMANCE.md) for measured
capacity and proposed budgets.
