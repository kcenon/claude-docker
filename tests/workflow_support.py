"""Bounded integration execution with reports that never contain command output."""
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit
from container_fixture import ContainerFixture, policy
from credential_file import read_private_file


class WorkflowFailure(Exception):
    def __init__(self, category):
        self.category = category
        super().__init__(category)


def classify(output, returncode):
    text = output.lower()
    if returncode in (124, 137):
        return "timeout"
    if any(item in text for item in ("invalid api key", "authentication", "unauthorized", "401", "403")):
        return "authentication_refused"
    if any(item in text for item in ("rate limit", "429", "503", "502", "connection refused")):
        return "provider_unavailable"
    if "sandbox" in text and any(item in text for item in ("unavailable", "denied", "failed", "conflicts")):
        return "sandbox_refused"
    if "read-only" in text or "permission denied" in text:
        return "mount_permission"
    return "command_failed"


class AuthenticatedFixture(ContainerFixture):
    """Do not inherit the placeholder fixture's stdout/log diagnostics."""
    def run(self, argv, timeout=120):
        result = self.probe_command(argv, timeout)
        if result.returncode:
            raise WorkflowFailure(classify(result.stdout + result.stderr, result.returncode))
        return result.stdout

    def probe_command(self, argv, timeout):
        try:
            return subprocess.run(argv, env=self.host_env, cwd=self.root, capture_output=True,
                                  text=True, timeout=timeout, encoding="utf-8", errors="replace")
        except subprocess.TimeoutExpired:
            raise WorkflowFailure("timeout") from None
        except OSError:
            raise WorkflowFailure("command_unavailable") from None

    def probe(self, index, *argv, timeout=15):
        return self.probe_command(self.cmd + ["exec", "-T", self.services[index]] + list(argv), timeout)

    def up(self):
        # Host policy also redacts its subprocess errors. Never request logs.
        try:
            policy.prepare_dependency_volumes(self.model, self.cmd, self.host_env, self.root)
            self.run(self.cmd + ["up", "--detach", "--no-build", "--wait", "--wait-timeout", "90"], timeout=150)
        except policy.PolicyError:
            raise WorkflowFailure("startup_failed") from None


def load_credentials(path, runtime):
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        raise WorkflowFailure("credentials_file_required")
    try:
        content = read_private_file(path)
    except (OSError, ValueError):
        raise WorkflowFailure("credentials_file_must_be_private") from None
    try:
        data = json.loads(content)
        if data.get("disposable") is not True:
            raise ValueError()
        remote = urlsplit(data["github_remote"])
        if (remote.scheme != "https" or remote.hostname != "github.com" or remote.username or remote.password
                or remote.query or remote.fragment or remote.port
                or not re.fullmatch(r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?", remote.path)):
            raise ValueError()
        selected = data["runtimes"][runtime]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./:-]{0,120}", selected["model"]):
            raise ValueError()
        accounts = selected["accounts"]
        if not isinstance(accounts, list) or len(accounts) != 2:
            raise ValueError()
        for account in accounts:
            for key in ("api_key", "github_user", "github_token"):
                value = account[key]
                # The generators read a literal dotenv contract. Refuse syntax
                # that Compose could interpolate rather than altering a key.
                if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_./+=:-]+", value):
                    raise ValueError()
            if not re.fullmatch(r"[A-Za-z0-9-]+", account["github_user"]):
                raise ValueError()
        timeout = data.get("timeout_seconds", 120)
        if type(timeout) is not int or not 10 <= timeout <= 300:
            raise ValueError()
        budget = data.get("claude_max_budget_usd", 0.25)
        if type(budget) not in (int, float) or not 0 < budget <= 5:
            raise ValueError()
        return {"accounts": accounts, "model": selected["model"], "remote": data["github_remote"],
                "timeout": timeout, "claude_budget": budget}
    except (ValueError, KeyError, TypeError, OSError):
        raise WorkflowFailure("invalid_credentials_contract") from None


def runtime_command(runtime, spec, model, prompt, budget):
    binary = spec["binary"]
    if runtime == "claude":
        return [binary, "-p", prompt, "--model", model, "--max-turns", "3",
                "--max-budget-usd", str(budget), "--allowedTools", "Read,Write", "--output-format", "json"]
    if runtime == "codex":
        return [binary, "-c", 'cli_auth_credentials_store="file"', "--ask-for-approval", "never",
                "exec", "--sandbox", "workspace-write", "--model", model, prompt]
    return [binary, "--prompt", prompt, "--model", model, "--approval-mode", "auto_edit", "--output-format", "json"]


def record(report, runtime, name, operation, account=None):
    row = {"runtime": runtime, "name": name, "account": account, "status": "running"}
    report["cases"].append(row)
    try:
        metadata = operation()
        row.update(status="passed")
        if metadata:
            row["metadata"] = metadata
    except WorkflowFailure as error:
        row.update(status="failed", reason=error.category)
    except Exception:
        row.update(status="failed", reason="check_failed")
    return row["status"] == "passed"


def provenance(fixture):
    """Allowlist host/daemon/image details; never publish the resolved model."""
    from benchmark_isolation import source_fingerprint
    from container_fixture import ROOT
    # Wrappers and the TUI must discover only fixture HOME/state. Freeze the
    # selected local daemon endpoint first so that changing HOME cannot switch
    # a Desktop/rootless context back to a different daemon's default socket.
    if fixture.host_env.get("DOCKER_CONTEXT") or not fixture.host_env.get("DOCKER_HOST"):
        contexts = json.loads(fixture.run(["docker", "context", "inspect"], timeout=10))
        endpoint = contexts[0]["Endpoints"]["docker"]["Host"]
    else:
        endpoint = fixture.host_env["DOCKER_HOST"]
    if not endpoint.startswith(("unix://", "npipe://")):
        raise WorkflowFailure("workflow_requires_local_daemon_endpoint")
    fixture.host_env["DOCKER_HOST"] = endpoint
    fixture.host_env.pop("DOCKER_CONTEXT", None)
    info = json.loads(fixture.run(["docker", "info", "--format", "{{json .}}"], timeout=15))
    image = json.loads(fixture.run(["docker", "image", "inspect", fixture.image]))[0]
    fixture.image = image["Id"]
    return {"source_commit": fixture.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).strip(),
            "source_dirty": bool(fixture.run(["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=normal"]).strip()),
            "source_fingerprint_sha256": source_fingerprint(), "image_id": fixture.image,
            "engine_version": info["ServerVersion"], "compose_version": fixture.run(["docker", "compose", "version", "--short"]).strip(),
            "daemon": {key: info.get(key) for key in ("OperatingSystem", "Architecture", "KernelVersion", "CgroupVersion", "Driver", "SecurityOptions", "NCPU", "MemTotal")},
            "container_uid": fixture.uid, "container_gid": fixture.gid}


def expected_workflows(runtimes):
    expected = set()
    for runtime in runtimes:
        for name in ("runtime_workflow", "fixture_cleanup", "runtime_environment"):
            expected.add((runtime, None, name))
        for account in (1, 2):
            for name in ("writable_paths", "offline_package_workflow", "authenticated_identity",
                         "authenticated_session", "authenticated_push", "wrapper_attach", "tui_attach"):
                expected.add((runtime, account, name))
            if runtime == "claude":
                expected.add((runtime, account, "requested_inner_sandbox"))
        for name in ("writable_paths_after_recreation", "package_after_recreation", "authenticated_after_recreation"):
            expected.add((runtime, 1, name))
    return expected


def remote_ref_errors(report):
    references = report.get("remote_refs", [])
    if not isinstance(references, list) or any(not isinstance(row, dict) for row in references):
        return ["invalid_remote_ref_evidence"]
    errors = []
    if any(row.get("cleanup") != "absence_verified" for row in references):
        errors.append("remote_cleanup_unverified")
    if report.get("schema") != 2:
        return errors
    pushes = {(row.get("runtime"), row.get("account")): row for row in report["cases"]
              if row.get("name") == "authenticated_push"}
    by_account, names = {}, set()
    for row in references:
        runtime, account, reference, commit = (row.get(key) for key in ("runtime", "account", "ref", "commit"))
        if (not isinstance(runtime, str) or type(account) is not int
                or not isinstance(reference, str) or not reference
                or not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit)):
            errors.append("invalid_remote_ref_evidence")
            continue
        key = (runtime, account)
        if key not in pushes or pushes[key].get("status") == "skipped":
            errors.append("unexpected_remote_ref_evidence")
        if key in by_account or reference in names:
            errors.append("duplicate_remote_ref_evidence")
        by_account[key] = row
        names.add(reference)
    # A success row needs its own observed cleanup, not merely an absence of
    # failed cleanup rows. Bind the record to the exact pushed ref and SHA.
    for key, row in pushes.items():
        if row.get("status") != "passed":
            continue
        reference = by_account.get(key)
        if reference is None:
            errors.append("remote_ref_evidence_missing")
            continue
        metadata = row.get("metadata")
        if (not isinstance(metadata, dict) or metadata.get("created_and_removed_ref") != reference["ref"]
                or metadata.get("commit") != reference["commit"]):
            errors.append("remote_ref_evidence_mismatch")
    return list(dict.fromkeys(errors))


def coverage_errors(report):
    cases = report["cases"]
    keys = [(row.get("runtime"), row.get("account"), row.get("name")) for row in cases]
    errors = []
    if not cases:
        errors.append("no_cases")
    if len(keys) != len(set(keys)):
        errors.append("duplicate_cases")
    if any(row.get("status") not in ("passed", "failed", "skipped") for row in cases):
        errors.append("invalid_case_status")
    errors.extend(remote_ref_errors(report))
    if report.get("schema", 1) not in (1, 2):
        errors.append("unsupported_schema")
    if report.get("schema") == 2:
        from container_fixture import ROOT
        registry = json.loads((ROOT / "tui/internal/config/runtimes.json").read_text())["runtimes"]
        runtimes = report.get("runtimes", [])
        if (not runtimes or len(runtimes) != len(set(runtimes)) or any(r not in registry for r in runtimes)):
            errors.append("invalid_runtime_selection")
        expected = expected_workflows(runtimes)
        if expected - set(keys):
            errors.append("missing_required_cases")
        if set(keys) - expected:
            errors.append("unexpected_cases")
        for runtime in runtimes:
            evidence = report.get("provenance", {}).get(runtime, {})
            if (not re.fullmatch(r"[0-9a-f]{40}", evidence.get("source_commit", ""))
                    or not re.fullmatch(r"[0-9a-f]{64}", evidence.get("source_fingerprint_sha256", ""))
                    or not re.fullmatch(r"sha256:[0-9a-f]{64}", evidence.get("image_id", ""))
                    or type(evidence.get("source_dirty")) is not bool or not evidence.get("daemon")):
                errors.append("runtime_provenance_missing:" + runtime)
    return errors


def finish(report, path, require_complete=False):
    counts = {status: sum(row["status"] == status for row in report["cases"])
              for status in ("passed", "failed", "skipped")}
    report["counts"] = dict(counts, executed=counts["passed"] + counts["failed"], planned=len(report["cases"]))
    errors = coverage_errors(report)
    report["coverage_errors"] = errors
    report["status"] = "failed" if counts["failed"] or errors else ("incomplete" if counts["skipped"] else "complete")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "counts": report["counts"]}))
    return 1 if counts["failed"] or errors or require_complete and counts["skipped"] else 0
