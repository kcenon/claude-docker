#!/usr/bin/env python3
"""Completion must describe the requested coverage, including failed setup."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from workflow_support import expected_workflows, finish


class CoverageTest(unittest.TestCase):
    def finish(self, report, require_complete=True):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            return finish(report, Path(directory) / "report.json", require_complete=require_complete)

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
        report = {"schema": 2, "runtimes": runtimes,
                "provenance": {r: {"source_commit": "1" * 40, "source_dirty": False,
                                   "source_fingerprint_sha256": "2" * 64, "image_id": "sha256:" + "3" * 64,
                                   "daemon": {"CgroupVersion": "2"}} for r in runtimes},
                "cases": [{"runtime": r, "account": a, "name": n, "status": "passed"}
                          for r, a, n in expected_workflows(runtimes)]}
        report["remote_refs"] = []
        for row in report["cases"]:
            if row["name"] == "authenticated_push":
                reference = "refs/heads/issue335-fixture/" + row["runtime"] + "-" + str(row["account"])
                row["metadata"] = {"created_and_removed_ref": reference, "commit": "4" * 40}
                report["remote_refs"].append({"runtime": row["runtime"], "account": row["account"],
                    "ref": reference, "commit": "4" * 40, "cleanup": "absence_verified"})
        return report

    def test_successful_pushes_require_every_remote_cleanup_record(self):
        for missing in ("collection", "all", *range(6)):
            with self.subTest(missing=missing):
                report = self.complete_report()
                if missing == "collection":
                    del report["remote_refs"]
                elif missing == "all":
                    report["remote_refs"] = []
                else:
                    del report["remote_refs"][missing]
                self.assertEqual(1, self.finish(report))
                self.assertEqual("failed", report["status"])
                self.assertIn("remote_ref_evidence_missing", report["coverage_errors"])

    def test_cleanup_evidence_must_match_the_successful_push(self):
        for field, value in (("ref", "refs/heads/issue335-fixture/different"), ("commit", "5" * 40)):
            with self.subTest(field=field):
                report = self.complete_report()
                report["remote_refs"][0][field] = value
                self.assertEqual(1, self.finish(report))
                self.assertIn("remote_ref_evidence_mismatch", report["coverage_errors"])
        for metadata in (None, {}, {"created_and_removed_ref": "placeholder"}):
            with self.subTest(metadata=metadata):
                report = self.complete_report()
                row = next(row for row in report["cases"] if row["name"] == "authenticated_push")
                row["metadata"] = metadata
                self.assertEqual(1, self.finish(report))

    def test_cleanup_records_cannot_be_duplicated_or_assigned_to_another_account(self):
        for mutation in ("duplicate", "wrong_account", "wrong_runtime", "shared_ref"):
            with self.subTest(mutation=mutation):
                report = self.complete_report()
                first, second = report["remote_refs"][:2]
                if mutation == "duplicate":
                    report["remote_refs"].append(dict(first))
                elif mutation == "wrong_account":
                    first["account"] = 3
                elif mutation == "wrong_runtime":
                    first["runtime"] = "unknown"
                else:
                    second["ref"] = first["ref"]
                    row = next(row for row in report["cases"] if row["name"] == "authenticated_push"
                               and (row["runtime"], row["account"]) == (second["runtime"], second["account"]))
                    row["metadata"]["created_and_removed_ref"] = first["ref"]
                self.assertEqual(1, self.finish(report))

    def test_reports_without_executed_pushes_need_no_remote_refs(self):
        report = self.complete_report()
        report["remote_refs"] = []
        for row in report["cases"]:
            if row["name"] == "authenticated_push":
                row["status"] = "skipped"
                row.pop("metadata")
        self.assertEqual(0, self.finish(report, require_complete=False))
        self.assertEqual("incomplete", report["status"])
        self.assertEqual([], report["coverage_errors"])

    def test_malformed_cleanup_evidence_is_reported_as_a_failure(self):
        for references in (None, {}, [None], [{}]):
            with self.subTest(references=references):
                report = self.complete_report()
                report["remote_refs"] = references
                self.assertEqual(1, self.finish(report))
                self.assertIn("invalid_remote_ref_evidence", report["coverage_errors"])
        for field, value in (("account", True), ("ref", None), ("commit", "not-a-commit")):
            with self.subTest(field=field):
                report = self.complete_report()
                report["remote_refs"][0][field] = value
                self.assertEqual(1, self.finish(report))
                self.assertIn("invalid_remote_ref_evidence", report["coverage_errors"])

    def test_a_skipped_push_cannot_claim_observed_remote_cleanup(self):
        report = self.complete_report()
        row = next(row for row in report["cases"] if row["name"] == "authenticated_push")
        row["status"] = "skipped"
        row.pop("metadata")
        self.assertEqual(1, self.finish(report, require_complete=False))
        self.assertIn("unexpected_remote_ref_evidence", report["coverage_errors"])

    def test_failed_push_retains_its_cleanup_record_without_success_metadata(self):
        report = self.complete_report()
        row = next(row for row in report["cases"] if row["name"] == "authenticated_push")
        row["status"] = "failed"
        row.pop("metadata")
        self.assertEqual(1, self.finish(report))
        self.assertEqual([], report["coverage_errors"])

    def test_only_the_selected_runtime_needs_cleanup_evidence(self):
        report = self.complete_report()
        report["runtimes"] = ["codex"]
        report["provenance"] = {"codex": report["provenance"]["codex"]}
        for name in ("cases", "remote_refs"):
            report[name] = [row for row in report[name] if row["runtime"] == "codex"]
        self.assertEqual(20, len(report["cases"]))
        self.assertEqual(2, len(report["remote_refs"]))
        self.assertEqual(0, self.finish(report))

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

    def test_sandbox_refusal_scenarios_have_distinct_case_identities(self):
        from test_sandbox_platform import main
        fixture = SimpleNamespace(prepare=lambda: None, up=lambda: None, close=lambda: None)
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            path = Path(directory) / "report.json"
            with patch("sys.argv", ["test_sandbox_platform.py", "--image", "placeholder", "--output", str(path)]), patch(
                    "test_sandbox_platform.AuthenticatedFixture", return_value=fixture), patch(
                    "test_sandbox_platform.provenance", return_value={}), patch(
                    "test_sandbox_platform.verify", side_effect=lambda f, d: {"degraded_override": d}):
                with self.assertRaises(SystemExit) as caught:
                    main()
            self.assertEqual(0, caught.exception.code)
            report = json.loads(path.read_text())
            self.assertEqual(3, report["counts"]["passed"])
            self.assertEqual([], report["coverage_errors"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
