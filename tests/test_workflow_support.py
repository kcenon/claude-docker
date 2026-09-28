#!/usr/bin/env python3
"""Exercise the live-credential boundary with canaries and no external calls."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from container_fixture import ROOT
from test_credential_file import make_private_fixture
from workflow_support import (AuthenticatedFixture, WorkflowFailure, finish,
                              load_credentials, provenance, record, runtime_command)


class WorkflowSupportTest(unittest.TestCase):
    def test_local_daemon_context_survives_private_home_without_publishing_endpoint(self):
        endpoint = "unix:///private/test-owned-endpoint-canary.sock"
        fixture = SimpleNamespace(host_env={"DOCKER_CONTEXT": "test-desktop"}, image="test-image", uid=1001, gid=1001)
        def run(argv, **unused):
            if argv[:3] == ["docker", "context", "inspect"]:
                return json.dumps([{"Endpoints": {"docker": {"Host": endpoint}}}])
            self.assertEqual(endpoint, fixture.host_env["DOCKER_HOST"])
            self.assertNotIn("DOCKER_CONTEXT", fixture.host_env)
            if argv[:2] == ["docker", "info"]:
                return json.dumps({"ServerVersion": "fixture", "OperatingSystem": "Docker Desktop"})
            if argv[:3] == ["docker", "image", "inspect"]:
                return json.dumps([{"Id": "sha256:" + "1" * 64}])
            return ""
        fixture.run = run
        with patch("benchmark_isolation.source_fingerprint", return_value="2" * 64):
            result = provenance(fixture)
        self.assertNotIn("endpoint-canary", json.dumps(result))
        self.assertEqual(endpoint, fixture.host_env["DOCKER_HOST"])

    def test_remote_daemon_is_refused_before_fixture_mounts(self):
        fixture = SimpleNamespace(host_env={"DOCKER_HOST": "ssh://fixture.invalid"})
        with self.assertRaisesRegex(WorkflowFailure, "^workflow_requires_local_daemon_endpoint$"):
            provenance(fixture)

    def test_dispatch_credentials_are_private_removed_and_not_in_child_environment(self):
        workflow = (ROOT / ".github/workflows/isolation-authenticated.yml").read_text()
        embedded = textwrap.dedent(workflow.split("python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0])
        for code in (0, 17):
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
                    "RUNNER_TEMP": directory, "ISSUE335_TEST_CREDENTIALS": "dispatch-test-canary"}):
                path = Path(directory) / "issue335-credentials.json"
                def invocation(argv):
                    self.assertEqual("dispatch-test-canary", path.read_text())
                    self.assertNotIn("ISSUE335_TEST_CREDENTIALS", os.environ)
                    if os.name != "nt":
                        self.assertEqual(0o600, path.stat().st_mode & 0o777)
                    self.assertIn("--require-complete", argv)
                    return subprocess.CompletedProcess(argv, code)
                with patch("subprocess.run", side_effect=invocation), self.assertRaises(SystemExit) as caught:
                    exec(compile(embedded, "authenticated-workflow", "exec"), {})
                self.assertEqual(code, caught.exception.code)
                self.assertFalse(path.exists())

    def test_success_failure_and_timeout_never_publish_command_output(self):
        canary = "test-secret-canary-335"
        fixture = AuthenticatedFixture()
        self.addCleanup(fixture.temp.cleanup)
        for code in (0, 1):
            with patch("workflow_support.subprocess.run", return_value=subprocess.CompletedProcess(
                    ["fixture"], code, canary, canary)):
                if code == 0:
                    self.assertEqual(canary, fixture.run(["fixture"]))
                else:
                    with self.assertRaises(WorkflowFailure) as caught:
                        fixture.run(["fixture"])
                    self.assertNotIn(canary, str(caught.exception))
        with patch("workflow_support.subprocess.run",
                   side_effect=subprocess.TimeoutExpired(["fixture", canary], 1, output=canary, stderr=canary)):
            with self.assertRaisesRegex(WorkflowFailure, "^timeout$"):
                fixture.run(["fixture"])
        report = {"cases": []}
        record(report, "claude", "canary", lambda: (_ for _ in ()).throw(RuntimeError(canary)))
        self.assertNotIn(canary, json.dumps(report))

    def test_auth_startup_never_requests_container_logs(self):
        fixture = AuthenticatedFixture()
        self.addCleanup(fixture.temp.cleanup)
        fixture.cmd, fixture.model = ["docker", "compose"], {}
        with patch("workflow_support.policy.prepare_dependency_volumes"), patch.object(
                fixture, "run", side_effect=WorkflowFailure("startup_failed")) as run:
            with self.assertRaises(WorkflowFailure):
                fixture.up()
        self.assertEqual(1, run.call_count)
        self.assertNotIn("logs", run.call_args.args[0])

    def test_credentials_require_explicit_disposable_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "credentials.json"
            path.touch(mode=0o600)
            make_private_fixture(path)
            data = {"disposable": True, "github_remote": "https://github.com/fixture/disposable.git",
                    "runtimes": {"claude": {"model": "fixture-model", "accounts": [
                        {"api_key": "canary-provider-a", "github_user": "fixture-a", "github_token": "canary-gh-a"},
                        {"api_key": "canary-provider-b", "github_user": "fixture-b", "github_token": "canary-gh-b"}]}}}
            path.write_text(json.dumps(data))
            self.assertEqual("fixture-model", load_credentials(path, "claude")["model"])
            for remote in ("https://token@github.com/fixture/repo", "https://github.com/fixture/repo?token=canary", "/local/repo"):
                data["github_remote"] = remote
                path.write_text(json.dumps(data))
                with self.assertRaisesRegex(WorkflowFailure, "^invalid_credentials_contract$"):
                    load_credentials(path, "claude")
            data["disposable"] = False
            path.write_text(json.dumps(data))
            with self.assertRaises(WorkflowFailure):
                load_credentials(path, "claude")

    def test_runtime_commands_keep_the_isolated_sandbox(self):
        registry = json.loads((ROOT / "tui/internal/config/runtimes.json").read_text())["runtimes"]
        for name, spec in registry.items():
            command = runtime_command(name, spec, "fixture-model", "fixture prompt", 0.25)
            self.assertEqual(spec["binary"], command[0])
            self.assertIn("fixture-model", command)
            self.assertNotIn(spec["skipPermissionsFlag"], command)
        command = runtime_command("codex", registry["codex"], "fixture-model", "fixture prompt", 0.25)
        self.assertEqual("workspace-write", command[command.index("--sandbox") + 1])

    def test_missing_integrations_fail_completion_mode(self):
        report = {"cases": [{"name": "provider", "status": "skipped", "reason": "credentials_missing"}]}
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            path = Path(directory) / "report.json"
            self.assertEqual(0, finish(report, path))
            self.assertEqual(1, finish(report, path, require_complete=True))
            self.assertEqual(0, report["counts"]["executed"])
            self.assertEqual("incomplete", report["status"])
            self.assertEqual(1, finish({"cases": []}, path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
