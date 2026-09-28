#!/usr/bin/env python3
"""Run isolated package workflows; opt in explicitly to authenticated sessions."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import uuid
from container_fixture import ROOT, policy
from workflow_support import (AuthenticatedFixture, WorkflowFailure, finish,
                              expected_workflows, load_credentials, provenance, record, runtime_command)
from workflow_terminal import arm_markers, build_tui, markers_match, terminal_attach
from workflow_environment import PROFILES, verify_environment


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


def provider_workflow(fixture, index, credentials, sandbox=False):
    workspace = fixture.workspaces[index]
    nonce = uuid.uuid4().hex
    (workspace / "integration-input.txt").write_text(nonce + "\n")
    destination = workspace / "integration-output.txt"
    destination.unlink(missing_ok=True)
    challenge = arm_markers(fixture, index) if fixture.runtime == "claude" else None
    prompt = "Read integration-input.txt and copy its exact contents to integration-output.txt in the current directory. Use the file tools. Do no other work."
    command = runtime_command(fixture.runtime, fixture.spec, credentials["model"], prompt, credentials["claude_budget"])
    namespace = workspace / "sandbox-namespace.txt"
    if sandbox:
        namespace.unlink(missing_ok=True)
        shell = "cat integration-input.txt > integration-output.txt; readlink /proc/self/ns/mnt > sandbox-namespace.txt"
        prompt = "Use the Bash tool once to run exactly this command: " + shell + ". Do no other work."
        command = runtime_command(fixture.runtime, fixture.spec, credentials["model"], prompt, credentials["claude_budget"])
        command[command.index("--allowedTools") + 1] = "Bash"
        outer_namespace = fixture.execute(index, "readlink", "/proc/self/ns/mnt").strip()
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
                    *(["entrypoint.sh"] if sandbox else []), *command, timeout=credentials["timeout"] + 20)
    if not destination.is_file() or destination.read_text() != nonce + "\n":
        raise WorkflowFailure("provider_work_result_missing")
    if challenge and not markers_match(fixture, index, challenge, statusline=False):
        raise WorkflowFailure("runtime_hook_not_dispatched")
    if sandbox and (not namespace.is_file() or namespace.read_text().strip() == outer_namespace
                    or not re.fullmatch(r"mnt:\[[0-9]+\]", namespace.read_text().strip())):
        raise WorkflowFailure("runtime_inner_namespace_not_observed")
    return {"inner_sandbox": "authenticated_tool_namespace_verified" if sandbox else "not_requested",
            "runtime_version": fixture.execute(index, fixture.spec["binary"], "--version").strip(),
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
    created = False
    try:
        # Absence is checked atomically on the remote, including a ref created
        # by somebody else after the earlier ls-remote probe.
        result = fixture.execute(index, "git", "push", "--porcelain", "--force-with-lease=" + reference + ":",
                                 remote, commit + ":" + reference, timeout=60)
        # Git can report success/up-to-date without checking a lease when a
        # racing ref already points at this SHA. Only '*' proves creation.
        created = any(line.startswith("*\t") and line.split("\t")[1] == commit + ":" + reference
                      for line in result.splitlines())
        if not created:
            raise WorkflowFailure("remote_ref_creation_not_verified")
        actual = fixture.execute(index, "git", "ls-remote", "--exit-code", remote, reference, timeout=30).split()[0]
        if actual != commit:
            raise WorkflowFailure("remote_commit_mismatch")
    finally:
        # A lease protects deletion if somebody updates this test ref after
        # creation. It never permits overwriting an existing branch history.
        current = fixture.probe(index, "git", "ls-remote", "--exit-code", remote, reference, timeout=30)
        if current.returncode == 0:
            if not created:
                cleanup["cleanup"] = "creation_unconfirmed_deletion_refused"
                raise WorkflowFailure("remote_creation_unconfirmed_cleanup_refused")
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


def verify_identity(fixture, index, credentials):
    actual = fixture.execute(index, "gh", "api", "user", "--jq", ".login", timeout=30).strip()
    if actual.casefold() != credentials["accounts"][index]["github_user"].casefold():
        raise WorkflowFailure("github_account_mismatch")
    return {"expected_account_match": True}


def requested_sandbox(fixture, index, credentials):
    state = fixture.states[index]
    paths = [state / "local-config/settings.json", state / "settings.json"]
    originals = {path: path.read_bytes() for path in paths}
    try:
        for path in paths:
            settings = json.loads(path.read_text())
            settings["sandbox"] = {"enabled": True, "failIfUnavailable": True, "allowUnsandboxedCommands": False}
            path.write_text(json.dumps(settings))
        # The actual entrypoint probes this account's current security policy.
        # A refusal is a failed authenticated case, never a successful session.
        fixture.execute(index, "entrypoint.sh", "true", timeout=60)
        effective = json.loads(fixture.execute(index, "cat", fixture.spec["containerConfigMount"] + "/settings.json"))["sandbox"]
        if (effective.get("enabled") is not True or effective.get("failIfUnavailable") is not True
                or effective.get("allowUnsandboxedCommands") is not False
                or effective.get("enableWeakerNestedSandbox") or effective.get("enableWeakerNetworkIsolation")
                or effective.get("filesystem", {}).get("disabled")):
            raise WorkflowFailure("effective_inner_sandbox_not_restrictive")
        return provider_workflow(fixture, index, credentials, sandbox=True)
    finally:
        for path, content in originals.items():
            path.write_bytes(content)


def skip(report, runtime, name, reason, account=None):
    report["cases"].append({"runtime": runtime, "account": account, "name": name,
                            "status": "skipped", "reason": reason})


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
        if not record(report, runtime, "runtime_environment", lambda: verify_environment(
                fixture, report["provenance"][runtime], args.profile, args.desktop_version)):
            raise WorkflowFailure("runtime_environment_prerequisite_failed")
        for index in range(2):
            record(report, runtime, "writable_paths", lambda i=index: writable_workflow(fixture, i), index + 1)
            record(report, runtime, "offline_package_workflow", lambda i=index: package_workflow(fixture, i), index + 1)
            if credentials:
                identity = record(report, runtime, "authenticated_identity",
                                  lambda i=index: verify_identity(fixture, i, credentials), index + 1)
                passed = record(report, runtime, "authenticated_session", lambda i=index: provider_workflow(fixture, i, credentials), index + 1)
                if passed and identity:
                    record(report, runtime, "authenticated_push", lambda i=index: push_workflow(fixture, i, credentials["remote"]), index + 1)
                else:
                    report["cases"].append({"runtime": runtime, "account": index + 1, "name": "authenticated_push",
                                            "status": "skipped", "reason": "session_prerequisite_failed"})
            else:
                for name in ("authenticated_identity", "authenticated_session", "authenticated_push"):
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
        binary = None
        if credentials and args.terminal:
            binary = build_tui(fixture)
        for index in range(2):
            for entry_point in ("wrapper", "tui"):
                name = entry_point + "_attach"
                if credentials and args.terminal:
                    record(report, runtime, name, lambda i=index, entry=entry_point:
                           terminal_attach(fixture, i, entry, binary), index + 1)
                else:
                    skip(report, runtime, name, "explicit_terminal_and_credentials_required", index + 1)
            if runtime == "claude":
                if credentials and args.requested_inner_sandbox:
                    record(report, runtime, "requested_inner_sandbox", lambda i=index:
                           requested_sandbox(fixture, i, credentials), index + 1)
                else:
                    skip(report, runtime, "requested_inner_sandbox", "explicit_sandbox_and_credentials_required", index + 1)
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
    parser.add_argument("--terminal", action="store_true", help="Exercise wrapper and compiled TUI attach for both accounts")
    parser.add_argument("--requested-inner-sandbox", action="store_true", help="Require authenticated Claude Bash tool execution inside its inner sandbox")
    parser.add_argument("--profile", choices=PROFILES, help="Assert the observed native host/backend matches this profile")
    parser.add_argument("--desktop-version", help="Docker Desktop application version from About, required on Desktop profiles")
    parser.add_argument("--require-complete", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("runtime-workflows.json"))
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args()
    runtimes = list(registry) if args.runtime == "all" else [args.runtime]
    report = {"schema": 2, "runtimes": runtimes, "profile_requested": args.profile,
              "terminal_requested": args.terminal, "sandbox_requested": args.requested_inner_sandbox, "started_at": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
              "language": args.language, "authenticated_requested": bool(args.credentials_file), "cases": []}
    if args.plan:
        print(json.dumps({"runtimes": runtimes, "accounts_per_runtime": 2, "executed": 0,
                          "credentials": "explicit private JSON file; never host credential discovery"}, indent=2))
        return
    if not args.image:
        parser.error("--image is required for executed workflows")
    for runtime in runtimes:
        record(report, runtime, "runtime_workflow", lambda r=runtime: run_runtime(r, args, report))
    # Setup exceptions still retain every promised row. The aggregate failure
    # remains a failure; prerequisite skips explain why the rest did not run.
    present = {(row["runtime"], row.get("account"), row["name"]) for row in report["cases"]}
    for runtime, account, name in sorted(expected_workflows(runtimes) - present, key=str):
        skip(report, runtime, name, "runtime_setup_or_prerequisite_failed", account)
    raise SystemExit(finish(report, args.output, args.require_complete))


if __name__ == "__main__":
    main()
