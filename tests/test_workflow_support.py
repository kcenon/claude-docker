#!/usr/bin/env python3
"""Exercise the live-credential boundary with canaries and no external calls."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from container_fixture import ROOT
from workflow_support import (AuthenticatedFixture, WorkflowFailure, finish,
                              load_credentials, record, runtime_command)


class WorkflowSupportTest(unittest.TestCase):
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
