#!/usr/bin/env python3
"""Completion must describe the requested coverage, including failed setup."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from workflow_support import expected_workflows, finish


class CoverageTest(unittest.TestCase):
    def finish(self, report):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            return finish(report, Path(directory) / "report.json", require_complete=True)

    def test_missing_runtime_account_scenarios_cannot_be_complete(self):
        report = {"schema": 2, "runtimes": ["claude", "codex", "gemini"], "cases": [
            {"runtime": "claude", "account": 1, "name": "authenticated_session", "status": "passed"}]}
        self.assertEqual(1, self.finish(report))
        self.assertNotEqual("complete", report["status"])

    def test_duplicate_cases_are_rejected(self):
        row = {"runtime": "claude", "account": 1, "name": "authenticated_session", "status": "passed"}
        report = {"cases": [row, dict(row)]}
        self.assertEqual(1, self.finish(report))
        self.assertEqual("failed", report["status"])

    def test_running_case_is_not_a_success(self):
        report = {"cases": [{"runtime": "claude", "name": "fixture_cleanup", "account": None, "status": "running"}]}
        self.assertEqual(1, self.finish(report))
        self.assertNotEqual("complete", report["status"])

    def test_zero_cases_are_never_labelled_complete(self):
        report = {"cases": []}
        self.assertEqual(1, self.finish(report))
        self.assertNotEqual("complete", report["status"])

    def complete_report(self):
        runtimes = ["claude", "codex", "gemini"]
        return {"schema": 2, "runtimes": runtimes,
                "provenance": {r: {"source_commit": "1" * 40, "source_dirty": False,
                                   "source_fingerprint_sha256": "2" * 64, "image_id": "sha256:" + "3" * 64,
                                   "daemon": {"CgroupVersion": "2"}} for r in runtimes},
                "cases": [{"runtime": r, "account": a, "name": n, "status": "passed"}
                          for r, a, n in expected_workflows(runtimes)]}

    def test_complete_selected_coverage_and_every_missing_case(self):
        report = self.complete_report()
        self.assertEqual(62, len(report["cases"]))
        self.assertEqual(0, self.finish(report))
        for row in list(report["cases"]):
            incomplete = dict(report, cases=[case for case in report["cases"] if case != row])
            self.assertEqual(1, self.finish(incomplete))

    def test_provenance_and_remote_cleanup_are_required(self):
        report = self.complete_report()
        report["provenance"] = {}
        self.assertEqual(1, self.finish(report))
        report = self.complete_report()
        report["remote_refs"] = [{"cleanup": "ref_changed_deletion_refused"}]
        self.assertEqual(1, self.finish(report))

    def test_runner_retains_all_cases_and_cleanup_after_daemon_setup_failure(self):
        from test_runtime_workflows import main
        from workflow_support import WorkflowFailure
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            path = Path(directory) / "report.json"
            with patch("sys.argv", ["test_runtime_workflows.py", "--image", "placeholder", "--output", str(path)]), patch(
                    "test_runtime_workflows.provenance", side_effect=WorkflowFailure("command_unavailable")):
                with self.assertRaises(SystemExit) as caught:
                    main()
            report = json.loads(path.read_text())
            self.assertEqual(1, caught.exception.code)
            self.assertEqual(62, report["counts"]["planned"])
            self.assertEqual(3, report["counts"]["failed"])
            self.assertEqual(56, report["counts"]["skipped"])
            self.assertTrue(all(row["status"] == "passed" for row in report["cases"] if row["name"] == "fixture_cleanup"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
