#!/usr/bin/env python3
"""Actual daemon restart, restricted to an explicitly disposable hosted runner."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import time
from container_fixture import policy
from workflow_support import AuthenticatedFixture, WorkflowFailure, finish, provenance, record


def systemctl(action):
    result = subprocess.run(["sudo", "--non-interactive", "systemctl", action, "docker.service", "docker.socket"],
                            capture_output=True, timeout=60)
    if result.returncode:
        raise WorkflowFailure("daemon_" + action + "_failed")


def verify(fixture):
    fixture.prepare()
    alias = "claude-code-base:" + fixture.project
    fixture.run(["docker", "tag", fixture.image, alias])
    process = None
    stopped = False
    try:
        fixture.image = alias
        fixture.values.update(IMAGE_TAG=fixture.project, NUM_ACCOUNTS="2")
        fixture.count, fixture.services = 2, fixture.services[:2]
        fixture.generate()
        fixture.materialize_for_wrapper()
        fixture.wrapper("up", "--no-build", "--wait", "--wait-timeout", "90")
        fixture.run(fixture.cmd + ["stop", fixture.services[1]])
        before = {name: ((fixture.root / name).read_bytes(), (fixture.root / name).stat().st_mode & 0o777) for name in policy.FILES}
        resources = policy.resources(fixture.project, fixture.host_env)
        keep = fixture.workspaces[0] / "unrelated-daemon-recovery-write"
        keep.write_text("preserve account data")
        owned = set(fixture.run(fixture.cmd + ["ps", "--all", "--quiet"]).split())
        existing = set(fixture.run(["docker", "ps", "--all", "--quiet", "--no-trunc"]).split())
        if owned != existing:
            raise WorkflowFailure("daemon_has_unrelated_containers")
        real_docker = shutil.which("docker")
        shim = fixture.root / "daemon-proxy"
        shim.mkdir()
        marker, release = fixture.root / "applied", fixture.root / "release"
        # Forward actual application, then synchronize the daemon outage with
        # the transaction awaiting its CLI result. No production fault hooks.
        proxy = shim / "docker"
        proxy.write_text("#!/usr/bin/env python3\nimport pathlib,subprocess,sys,time\n"
                         + "args=sys.argv[1:]\ncode=subprocess.call([" + repr(real_docker) + "]+args)\n"
                         + "if code == 0 and 'up' in args and '--no-deps' in args and any('staged' in a for a in args):\n"
                         + " pathlib.Path(" + repr(str(marker)) + ").touch()\n"
                         + " deadline=time.monotonic()+90\n"
                         + " while not pathlib.Path(" + repr(str(release)) + ").exists():\n"
                         + "  if time.monotonic()>deadline: sys.exit(18)\n  time.sleep(0.05)\n code=17\n"
                         + "sys.exit(code)\n")
        proxy.chmod(0o700)
        env = {key: value for key, value in fixture.host_env.items() if key != "HOME"}
        env["PATH"] = str(shim) + os.pathsep + env["PATH"]
        process = subprocess.Popen(["bash", str(fixture.root / "scripts/claude-docker"), "scale", "3"],
                                   cwd=fixture.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 90
        while not marker.exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise WorkflowFailure("application_barrier_not_reached")
            time.sleep(0.05)
        stopped = True
        systemctl("stop")
        release.touch()
        output, errors = process.communicate(timeout=90)
        if process.returncode == 0 or "Scaled to" in output or "Recovery incomplete" not in errors:
            raise WorkflowFailure("daemon_loss_did_not_retain_failure")
        journal = fixture.root / ".claude-docker-lifecycle/journal.json"
        if not journal.is_file() or journal.stat().st_mode & 0o777 != 0o600:
            raise WorkflowFailure("protected_journal_missing")
        systemctl("start")
        stopped = False
        fixture.wrapper("recover")
        after = {name: ((fixture.root / name).read_bytes(), (fixture.root / name).stat().st_mode & 0o777) for name in policy.FILES}
        if before != after or keep.read_text() != "preserve account data":
            raise WorkflowFailure("restored_files_or_account_data_differ")
        if fixture.run(fixture.cmd + ["ps", "--services", "--status", "running"]).split() != [fixture.services[0]]:
            raise WorkflowFailure("running_selection_not_restored")
        if set(fixture.run(fixture.cmd + ["ps", "--services", "--all"]).split()) != set(fixture.services):
            raise WorkflowFailure("existing_selection_not_restored")
        current_resources = policy.resources(fixture.project, fixture.host_env)
        if any(set(current_resources[key]) != set(resources[key]) for key in resources):
            raise WorkflowFailure("owned_resource_cleanup_differs")
        if "No interrupted" not in fixture.wrapper("recover"):
            raise WorkflowFailure("recovery_not_idempotent")
        return {"daemon_stop_start": "executed", "services_before": {"running": 1, "stopped": 1},
                "managed_files_restored": 5, "unrelated_write_preserved": True, "second_recovery": "no_op"}
    finally:
        if stopped:
            systemctl("start")
        if process is not None and process.poll() is None:
            (fixture.root / "release").touch()
            try:
                process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=15)
        fixture.run(["docker", "image", "rm", alias])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--disposable-github-runner", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("daemon-recovery.json"))
    args = parser.parse_args()
    if (not args.disposable_github_runner or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or platform.system() != "Linux"
            or os.environ.get("DOCKER_HOST") or os.environ.get("DOCKER_CONTEXT", "default") != "default"):
        parser.error("requires an explicitly disposable GitHub-hosted Linux runner using its local daemon")
    fixture = AuthenticatedFixture(count=3, image=args.image)
    report = {"schema": 1, "platform": platform.platform(), "scope": "actual hosted runner daemon stop/start", "cases": []}
    try:
        report["provenance"] = provenance(fixture)
        record(report, "claude", "actual_daemon_recovery", lambda: verify(fixture))
    finally:
        record(report, "claude", "cleanup", fixture.close)
    raise SystemExit(finish(report, args.output, require_complete=True))


if __name__ == "__main__":
    main()
