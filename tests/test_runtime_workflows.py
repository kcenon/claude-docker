#!/usr/bin/env python3
"""Run isolated package workflows; opt in explicitly to authenticated sessions."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import time
import uuid
from container_fixture import ROOT, policy
from workflow_support import (AuthenticatedFixture, WorkflowFailure, finish,
                              load_credentials, provenance, record, runtime_command)


def writable_workflow(fixture, index, recreated=False):
    state = fixture.spec["containerConfigMount"]
    workspace = fixture.model["services"][fixture.services[index]]["working_dir"]
    persistent = [workspace, workspace + "/node_modules", state]
    scratch = list(policy.SCRATCH)
    for directory in persistent + scratch:
        marker = directory + "/.issue335-writable"
        if recreated:
            exists = fixture.probe(index, "test", "-f", marker).returncode == 0
            if exists != (directory in persistent):
                raise WorkflowFailure("persistence_expectation_failed")
        fixture.execute(index, "sh", "-c", 'printf account-%s "$1" > "$2"', "fixture", str(index + 1), marker)
    fixture.execute(index, "git", "config", "--global", "fixture.account", str(index + 1))
    if fixture.execute(index, "git", "config", "--global", "--get", "fixture.account").strip() != str(index + 1):
        raise WorkflowFailure("global_git_config_failed")
    fixture.execute(index, "gh", "auth", "setup-git", "--hostname", "github.com")
    fixture.execute(index, "git", "add", ".issue335-writable")
    fixture.execute(index, "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "--allow-empty", "-m", "disposable writable workflow")
    return {"persistent_paths": persistent, "scratch_paths": scratch, "recreation_checked": recreated,
            "global_git_config": "passed", "credential_helper_setup": "passed", "local_commit": "passed"}


def package_workflow(fixture, index):
    workspace = fixture.model["services"][fixture.services[index]]["working_dir"]
    result = json.loads(fixture.execute(index, "env", "ISSUE335_USE_DEFAULT_NPM_CACHE=1", "python3", workspace + "/.isolation-workload/measure.py",
                                        policy.account_letter(index + 1), timeout=180))
    if result.get("verified_reads") != 5000 or result.get("package_tests") != 3:
        raise WorkflowFailure("workload_incomplete")
    return {"verified_reads": 5000, "package_tests": 3}


def prepare_auth(fixture, credentials):
    for index, account in enumerate(credentials["accounts"]):
        letter = policy.account_letter(index + 1).upper()
        fixture.values.update({fixture.spec["apiKeyVarPrefix"] + letter: account["api_key"],
                               "GH_USER_" + letter: account["github_user"], "GH_TOKEN_" + letter: account["github_token"]})
        if fixture.runtime == "claude":
            local = fixture.states[index] / "local-config"
            state = fixture.spec["containerConfigMount"]
            (local / "hook.sh").write_text("#!/bin/sh\ntouch " + shlex.quote(state + "/hook-dispatched") + "\nprintf hook-ok\n")
            (local / "statusline.sh").write_text("#!/bin/sh\ntouch " + shlex.quote(state + "/statusline-dispatched") + "\nprintf statusline-ok\n")
            settings = json.loads((local / "settings.json").read_text())
            settings.update(model=credentials["model"], statusLine={"type": "command", "command": "sh " + state + "/local-config/statusline.sh"})
            (local / "settings.json").write_text(json.dumps(settings))
    fixture.generate()
    for service in fixture.model["services"].values():
        service["environment"]["GH_HOST"] = "github.com"


def provider_workflow(fixture, index, credentials):
    workspace = fixture.workspaces[index]
    nonce = uuid.uuid4().hex
    (workspace / "integration-input.txt").write_text(nonce + "\n")
    destination = workspace / "integration-output.txt"
    destination.unlink(missing_ok=True)
    if fixture.runtime == "claude":
        (fixture.states[index] / "hook-dispatched").unlink(missing_ok=True)
    prompt = "Read integration-input.txt and copy its exact contents to integration-output.txt in the current directory. Use the file tools. Do no other work."
    command = runtime_command(fixture.runtime, fixture.spec, credentials["model"], prompt, credentials["claude_budget"])
    help_text = fixture.execute(index, fixture.spec["binary"], "--help")
    if fixture.runtime == "codex":
        help_text += fixture.execute(index, fixture.spec["binary"], "exec", "--help")
        login_help = fixture.execute(index, fixture.spec["binary"], "login", "--help")
        if "--with-api-key" not in login_help:
            raise WorkflowFailure("unsupported_runtime_version")
        fixture.execute(index, "sh", "-c", 'printenv "$1" | "$2" -c \'cli_auth_credentials_store="file"\' login --with-api-key',
                        "fixture", fixture.spec["sdkApiKeyVar"], fixture.spec["binary"])
    required = {arg for arg in command if arg.startswith("--")}
    if any(flag not in help_text for flag in required):
        raise WorkflowFailure("unsupported_runtime_version")
    fixture.execute(index, "timeout", "--signal=TERM", "--kill-after=5s", str(credentials["timeout"]) + "s",
                    *command, timeout=credentials["timeout"] + 20)
    if not destination.is_file() or destination.read_text() != nonce + "\n":
        raise WorkflowFailure("provider_work_result_missing")
    if fixture.runtime == "claude" and not (fixture.states[index] / "hook-dispatched").exists():
        raise WorkflowFailure("runtime_hook_not_dispatched")
    return {"runtime_version": fixture.execute(index, fixture.spec["binary"], "--version").strip(),
            "model": credentials["model"], "auth_method": "explicit account API key",
            "result_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
            "hook_dispatch": "passed" if fixture.runtime == "claude" else "not_applicable"}


def push_workflow(fixture, index, remote):
    reference = "refs/heads/issue335-fixture/" + fixture.project + "-" + str(index + 1)
    fixture.execute(index, "gh", "auth", "setup-git", "--hostname", "github.com")
    probe = fixture.probe(index, "git", "ls-remote", "--exit-code", remote, reference, timeout=30)
    if probe.returncode != 2:
        raise WorkflowFailure("remote_ref_not_confirmed_absent")
    fixture.execute(index, "git", "add", "integration-output.txt")
    fixture.execute(index, "git", "-c", "user.name=Isolation Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "-m", "disposable isolation workflow")
    commit = fixture.execute(index, "git", "rev-parse", "HEAD").strip()
    cleanup = {"runtime": fixture.runtime, "account": index + 1, "ref": reference, "commit": commit,
               "cleanup": "unverified"}
    fixture.remote_refs.append(cleanup)
    try:
        fixture.execute(index, "git", "push", remote, commit + ":" + reference, timeout=60)
        actual = fixture.execute(index, "git", "ls-remote", "--exit-code", remote, reference, timeout=30).split()[0]
        if actual != commit:
            raise WorkflowFailure("remote_commit_mismatch")
    finally:
        # A lease protects deletion if somebody updates this test ref after
        # creation. It never permits overwriting an existing branch history.
        current = fixture.probe(index, "git", "ls-remote", "--exit-code", remote, reference, timeout=30)
        if current.returncode == 0:
            if current.stdout.split()[0] != commit:
                cleanup["cleanup"] = "ref_changed_deletion_refused"
                raise WorkflowFailure("remote_ref_changed_cleanup_refused")
            fixture.execute(index, "git", "push", "--force-with-lease=" + reference + ":" + commit,
                            remote, ":" + reference, timeout=60)
        elif current.returncode != 2:
            raise WorkflowFailure("remote_cleanup_unverified")
        if fixture.probe(index, "git", "ls-remote", "--exit-code", remote, reference, timeout=30).returncode != 2:
            raise WorkflowFailure("remote_cleanup_unverified")
        cleanup["cleanup"] = "absence_verified"
    return {"created_and_removed_ref": reference, "commit": commit}


def terminal_statusline(fixture, index):
    if os.name == "nt":
        raise WorkflowFailure("terminal_probe_requires_posix_pty")
    import pty
    import select
    state = fixture.states[index]
    marker = state / "statusline-dispatched"
    marker.unlink(missing_ok=True)
    master, slave = pty.openpty()
    prefix = (["pwsh", "-NoProfile", "-File", str(fixture.root / "scripts/claude-docker.ps1")]
              if fixture.language == "powershell" else ["bash", str(fixture.root / "scripts/claude-docker")])
    env = {key: value for key, value in fixture.host_env.items() if key != "HOME"}
    process = subprocess.Popen(prefix + [fixture.runtime, fixture.services[index]], cwd=fixture.root, env=env,
                               stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    began, accepted = time.monotonic(), False
    try:
        while time.monotonic() - began < 30 and process.poll() is None:
            if marker.exists():
                return {"statusline_dispatch": "passed", "entry_point": fixture.language + " wrapper", "model_tasks_submitted": 0}
            if select.select([master], [], [], 0.1)[0]:
                output = os.read(master, 8192)
                # The terminal sees only this test-owned repository. No task
                # is submitted; headless sessions separately prove API use.
                if not accepted and b"trust" in output.lower():
                    os.write(master, b"\r")
                    accepted = True
        raise WorkflowFailure("terminal_statusline_not_observed")
    finally:
        try:
            os.write(master, b"\x03\x03")
            process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            process.kill()
            process.wait(timeout=5)
        os.close(master)
        # Terminate any container-side terminal child as well.
        fixture.run(fixture.cmd + ["stop", fixture.services[index]], timeout=60)
        fixture.up()


def run_runtime(runtime, args, report):
    credentials = load_credentials(args.credentials_file, runtime) if args.credentials_file else None
    fixture = AuthenticatedFixture(runtime=runtime, image=args.image)
    fixture.language = args.language
    fixture.remote_refs = []
    try:
        report.setdefault("provenance", {})[runtime] = provenance(fixture)
        fixture.prepare()
        if credentials:
            prepare_auth(fixture, credentials)
        fixture.materialize_for_wrapper()
        fixture.wrapper("up", "--no-build", "--wait", "--wait-timeout", "90")
        for index in range(2):
            record(report, runtime, "writable_paths", lambda i=index: writable_workflow(fixture, i), index + 1)
            record(report, runtime, "offline_package_workflow", lambda i=index: package_workflow(fixture, i), index + 1)
            if credentials:
                passed = record(report, runtime, "authenticated_session", lambda i=index: provider_workflow(fixture, i, credentials), index + 1)
                if passed:
                    record(report, runtime, "authenticated_push", lambda i=index: push_workflow(fixture, i, credentials["remote"]), index + 1)
                else:
                    report["cases"].append({"runtime": runtime, "account": index + 1, "name": "authenticated_push",
                                            "status": "skipped", "reason": "session_prerequisite_failed"})
            else:
                for name in ("authenticated_session", "authenticated_push"):
                    report["cases"].append({"runtime": runtime, "account": index + 1, "name": name,
                                            "status": "skipped", "reason": "explicit_test_credentials_missing"})
        fixture.run(fixture.cmd + ["up", "--force-recreate", "--detach", "--no-build", "--wait", "--wait-timeout", "90"], timeout=150)
        record(report, runtime, "writable_paths_after_recreation", lambda: writable_workflow(fixture, 0, recreated=True), 1)
        record(report, runtime, "package_after_recreation", lambda: package_workflow(fixture, 0), 1)
        if credentials:
            record(report, runtime, "authenticated_after_recreation", lambda: provider_workflow(fixture, 0, credentials), 1)
        else:
            report["cases"].append({"runtime": runtime, "account": 1, "name": "authenticated_after_recreation",
                                    "status": "skipped", "reason": "explicit_test_credentials_missing"})
        if runtime == "claude":
            if credentials and args.terminal:
                record(report, runtime, "terminal_statusline", lambda: terminal_statusline(fixture, 0), 1)
            else:
                report["cases"].append({"runtime": runtime, "account": 1, "name": "terminal_statusline",
                                        "status": "skipped", "reason": "explicit_terminal_and_credentials_required"})
    finally:
        report.setdefault("remote_refs", []).extend(fixture.remote_refs)
        record(report, runtime, "fixture_cleanup", fixture.close)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image")
    registry = json.loads((ROOT / "tui/internal/config/runtimes.json").read_text())["runtimes"]
    parser.add_argument("--runtime", choices=tuple(registry) + ("all",), default="all")
    parser.add_argument("--language", choices=("bash", "powershell"), default="powershell" if os.name == "nt" else "bash")
    parser.add_argument("--credentials-file", type=Path)
    parser.add_argument("--terminal", action="store_true")
    parser.add_argument("--require-complete", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("runtime-workflows.json"))
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args()
    runtimes = list(registry) if args.runtime == "all" else [args.runtime]
    report = {"schema": 1, "started_at": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
              "language": args.language, "authenticated_requested": bool(args.credentials_file), "cases": []}
    if args.plan:
        print(json.dumps({"runtimes": runtimes, "accounts_per_runtime": 2, "executed": 0,
                          "credentials": "explicit private JSON file; never host credential discovery"}, indent=2))
        return
    if not args.image:
        parser.error("--image is required for executed workflows")
    for runtime in runtimes:
        record(report, runtime, "runtime_workflow", lambda r=runtime: run_runtime(r, args, report))
    raise SystemExit(finish(report, args.output, args.require_complete))


if __name__ == "__main__":
    main()
