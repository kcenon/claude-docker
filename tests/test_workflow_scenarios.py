#!/usr/bin/env python3
"""Contract and failure controls for credentialed scenarios, without API calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from test_runtime_workflows import push_workflow, requested_sandbox, verify_identity
from workflow_support import WorkflowFailure, remote_ref_errors
from workflow_terminal import arm_markers, markers_match


class WorkflowScenarioTest(unittest.TestCase):
    def test_stale_or_sibling_markers_cannot_satisfy_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            states = [Path(directory) / name for name in ("a", "b")]
            for state in states:
                (state / "local-config").mkdir(parents=True)
                for marker in ("hook-dispatched", "statusline-dispatched"):
                    (state / marker).write_text("old-session")
            fixture = SimpleNamespace(states=states, spec={"containerConfigMount": "/account"})
            challenge = arm_markers(fixture, 0)
            self.assertFalse(markers_match(fixture, 0, challenge))
            for name in ("hook-dispatched", "statusline-dispatched"):
                (states[0] / name).write_text("old-session")
            self.assertFalse(markers_match(fixture, 0, challenge))
            for name in ("hook-dispatched", "statusline-dispatched"):
                (states[0] / name).write_text(challenge)
            self.assertTrue(markers_match(fixture, 0, challenge))
            (states[1] / "hook-dispatched").write_text(challenge)
            with self.assertRaisesRegex(WorkflowFailure, "^wrong_account_dispatch$"):
                markers_match(fixture, 0, challenge)

    def test_github_identity_match_is_required_and_never_published(self):
        fixture = SimpleNamespace(execute=Mock(return_value="unexpected-secret-canary\n"))
        credentials = {"accounts": [{"github_user": "test-owner"}]}
        with self.assertRaisesRegex(WorkflowFailure, "^github_account_mismatch$"):
            verify_identity(fixture, 0, credentials)
        fixture.execute.return_value = "Test-Owner\n"
        self.assertEqual({"expected_account_match": True}, verify_identity(fixture, 0, credentials))

    def test_capability_refusal_never_calls_provider_and_restores_fixture_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / "local-config").mkdir()
            paths = [state / "settings.json", state / "local-config/settings.json"]
            content = json.dumps({"sandbox": {"enabled": False}, "preserved": True})
            for path in paths:
                path.write_text(content)
            fixture = SimpleNamespace(states=[state], execute=Mock(side_effect=WorkflowFailure("sandbox_refused")))
            with patch("test_runtime_workflows.provider_workflow") as provider:
                with self.assertRaisesRegex(WorkflowFailure, "^sandbox_refused$"):
                    requested_sandbox(fixture, 0, {})
                provider.assert_not_called()
            self.assertTrue(all(path.read_text() == content for path in paths))

    def test_remote_ref_created_concurrently_is_never_overwritten_or_deleted(self):
        for same_commit in (False, True):
            with self.subTest(same_commit=same_commit):
                self.assert_concurrent_ref_preserved(same_commit)

    def test_owned_remote_ref_is_created_verified_and_removed(self):
        self.assert_concurrent_ref_preserved(None)

    def assert_concurrent_ref_preserved(self, same_commit):
        # A real local bare remote creates the racing ref after ls-remote says
        # absent. It deliberately points at a fast-forwardable ancestor.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work, remote = root / "work", root / "remote.git"
            def git(*args, cwd=None, check=True):
                return subprocess.run(["git"] + list(args), cwd=cwd, capture_output=True, text=True, check=check,
                                      env=dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1"))
            git("init", "--bare", str(remote))
            git("init", str(work))
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "base", cwd=work)
            original = git("rev-parse", "HEAD", cwd=work).stdout.strip()
            git("push", str(remote), "HEAD:refs/heads/base", cwd=work)
            (work / "integration-output.txt").write_text("placeholder")
            reference = "refs/heads/issue335-fixture/test-owned-1"
            expected = original
            def execute(index, *argv, **unused):
                nonlocal expected
                if argv[0] == "gh":
                    return ""
                if same_commit is not None and argv[:2] == ("git", "push") and not argv[-1].startswith(":"):
                    if same_commit:
                        git("--git-dir", str(remote), "fetch", str(work), "HEAD")
                        expected = git("rev-parse", "HEAD", cwd=work).stdout.strip()
                    git("--git-dir", str(remote), "update-ref", reference, expected)
                result = git(*argv[1:], cwd=work, check=False)
                if result.returncode:
                    raise WorkflowFailure("command_failed")
                return result.stdout
            fixture = SimpleNamespace(runtime="claude", project="test-owned", remote_refs=[], execute=execute,
                probe=lambda index, *argv, **unused: git(*argv[1:], cwd=work, check=False))
            if same_commit is None:
                metadata = push_workflow(fixture, 0, str(remote))
                self.assertNotEqual(0, git("--git-dir", str(remote), "show-ref", "--verify", reference, check=False).returncode)
                self.assertEqual("absence_verified", fixture.remote_refs[0]["cleanup"])
                report = {"schema": 2, "cases": [{"runtime": "claude", "account": 1,
                    "name": "authenticated_push", "status": "passed", "metadata": metadata}],
                    "remote_refs": fixture.remote_refs}
                self.assertEqual([], remote_ref_errors(report))
                report["remote_refs"] = []
                self.assertEqual(["remote_ref_evidence_missing"], remote_ref_errors(report))
            else:
                with self.assertRaises(WorkflowFailure):
                    push_workflow(fixture, 0, str(remote))
                self.assertEqual(expected, git("--git-dir", str(remote), "rev-parse", reference).stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
