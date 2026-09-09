"""Bounded integration execution with reports that never contain command output."""
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit
from container_fixture import ContainerFixture, policy


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
    if os.name != "nt" and path.stat().st_mode & 0o077:
        raise WorkflowFailure("credentials_file_must_be_private")
    try:
        data = json.loads(path.read_text())
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
    info = json.loads(fixture.run(["docker", "info", "--format", "{{json .}}"], timeout=15))
    image = json.loads(fixture.run(["docker", "image", "inspect", fixture.image]))[0]
    fixture.image = image["Id"]
    return {"source_commit": fixture.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).strip(),
            "source_dirty": bool(fixture.run(["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=normal"]).strip()),
            "source_fingerprint_sha256": source_fingerprint(), "image_id": fixture.image,
            "engine_version": info["ServerVersion"], "compose_version": fixture.run(["docker", "compose", "version", "--short"]).strip(),
            "daemon": {key: info.get(key) for key in ("OperatingSystem", "Architecture", "KernelVersion", "CgroupVersion", "Driver", "SecurityOptions", "NCPU", "MemTotal")},
            "container_uid": fixture.uid, "container_gid": fixture.gid}


def finish(report, path, require_complete=False):
    counts = {status: sum(row["status"] == status for row in report["cases"])
              for status in ("passed", "failed", "skipped")}
    report["counts"] = dict(counts, executed=counts["passed"] + counts["failed"], planned=len(report["cases"]))
    report["status"] = "failed" if counts["failed"] else ("incomplete" if counts["skipped"] else "complete")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "counts": report["counts"]}))
    return 1 if counts["failed"] or require_complete and counts["skipped"] or not report["cases"] else 0
