#!/usr/bin/env python3
"""Review decisions retain evidence bindings and enforce the acceptance gate."""
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from container_fixture import ROOT
from budget_review import validate_review


class BudgetReviewTest(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / "docs/benchmarks/issue-335"
        self.record = json.loads((self.directory / "budget-review.json").read_text())

    def decision_fixture(self, status):
        # Only evidence bindings come from the published record. Its eventual
        # decision must not change the states exercised by these tests.
        record = copy.deepcopy(self.record)
        record.update(status=status, reviewer=None, review_date=None,
                      decision_url=None, accepted_regressions=None)
        if status != "pending":
            record.update(reviewer="fixture-reviewer", review_date="2000-01-01",
                          decision_url="https://github.com/kcenon/claude-docker/issues/335#issuecomment-1",
                          accepted_regressions=[])
        for profile in record["profiles"]:
            for metric in profile["metrics"]:
                metric["accepted_limits"] = copy.deepcopy(metric["proposed_limits"]) if status == "accepted" else None
        return record

    def test_committed_review_is_valid_in_its_recorded_state(self):
        result = validate_review(self.record, self.directory)
        self.assertEqual(self.record["status"], result["budget_review"])

    def test_pending_proposal_is_valid_but_not_accepted(self):
        record = self.decision_fixture("pending")
        self.assertEqual("pending", validate_review(record, self.directory)["budget_review"])
        with self.assertRaisesRegex(ValueError, "acceptance pending"):
            validate_review(record, self.directory, require_accepted=True)

    def test_accepted_decision_passes_the_acceptance_gate(self):
        result = validate_review(self.decision_fixture("accepted"), self.directory, require_accepted=True)
        self.assertEqual("accepted", result["budget_review"])
        self.assertEqual("requires checking the linked maintainer decision", result["decision_authenticity"])

    def test_rejected_decision_is_valid_but_not_accepted(self):
        record = self.decision_fixture("rejected")
        self.assertEqual("rejected", validate_review(record, self.directory)["budget_review"])
        with self.assertRaisesRegex(ValueError, "acceptance pending or rejected"):
            validate_review(record, self.directory, require_accepted=True)

    def test_modified_identity_hash_scope_or_decision_is_rejected(self):
        mutations = [
            lambda r: r["profiles"][0]["evidence"].update(sha256="0" * 64),
            lambda r: r["profiles"][0]["evidence"]["identity"].update(image_id="sha256:" + "0" * 64),
            lambda r: r["profiles"][0].update(account_counts=[1, 2]),
            lambda r: r["profiles"][0]["metrics"].pop(),
            lambda r: r["profiles"][0].update(modes=["isolated"]),
            lambda r: r["profiles"].pop(),
        ]
        for status in ("pending", "accepted", "rejected"):
            for index, mutate in enumerate(mutations):
                with self.subTest(status=status, mutation=index):
                    record = self.decision_fixture(status)
                    mutate(record)
                    with self.assertRaises((ValueError, KeyError, TypeError)):
                        validate_review(record, self.directory)

    def test_pending_proposal_cannot_contain_a_decision(self):
        mutations = [
            lambda r: r["profiles"][0]["metrics"][0].update(accepted_limits=2),
            lambda r: r.update(status="accepted"),
            lambda r: r.update(reviewer="invented-reviewer"),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                record = self.decision_fixture("pending")
                mutate(record)
                with self.assertRaises((ValueError, KeyError, TypeError)):
                    validate_review(record, self.directory)

    def test_decisions_require_all_review_fields(self):
        for status in ("accepted", "rejected"):
            for field in ("reviewer", "review_date", "decision_url", "accepted_regressions"):
                for missing in (False, True):
                    with self.subTest(status=status, field=field, missing=missing):
                        record = self.decision_fixture(status)
                        if missing:
                            del record[field]
                        else:
                            record[field] = None
                        with self.assertRaises((ValueError, KeyError, TypeError)):
                            validate_review(record, self.directory)

    def test_invalid_limits_are_rejected(self):
        invalid = (None, 0, -1, True, "2", float("nan"), float("inf"),
                   {"1": 2, "2": 2}, {"1": 2, "2": 2, "4": 0})
        for field in ("proposed_limits", "accepted_limits"):
            for value in invalid:
                with self.subTest(field=field, value=value):
                    record = self.decision_fixture("accepted")
                    record["profiles"][0]["metrics"][0][field] = value
                    with self.assertRaisesRegex(ValueError, "invalid metric limit|incomplete per-count limits"):
                        validate_review(record, self.directory, require_accepted=True)

    def test_unaccepted_decisions_cannot_have_accepted_limits(self):
        for status in ("pending", "rejected"):
            with self.subTest(status=status):
                record = self.decision_fixture(status)
                record["profiles"][0]["metrics"][0]["accepted_limits"] = 2
                with self.assertRaisesRegex(ValueError, "unaccepted review contains acceptance values"):
                    validate_review(record, self.directory)

    def test_cli_decision_exit_codes(self):
        with tempfile.TemporaryDirectory(prefix="budget-review-fixture-") as directory:
            root = Path(directory)
            for profile in self.record["profiles"]:
                filename = profile["evidence"]["report"]
                shutil.copyfile(self.directory / filename, root / filename)
            path = root / "review.json"
            for status in ("pending", "accepted", "rejected"):
                path.write_text(json.dumps(self.decision_fixture(status)))
                for strict in (False, True):
                    with self.subTest(status=status, require_accepted=strict):
                        command = [sys.executable, str(ROOT / "tests/budget_review.py"), str(path)]
                        if strict:
                            command.append("--require-accepted")
                        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                        rejected = strict and status != "accepted"
                        self.assertEqual(1 if rejected else 0, result.returncode, result.stderr)
                        report = json.loads(result.stdout)
                        self.assertEqual("invalid_or_unaccepted" if rejected else "valid", report["status"])
                        if not rejected:
                            self.assertEqual(status, report["budget_review"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
