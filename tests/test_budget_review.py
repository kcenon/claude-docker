#!/usr/bin/env python3
"""Review provenance cannot drift and pending decisions cannot close the issue."""
import copy
import json
import unittest
from container_fixture import ROOT
from budget_review import validate_review


class BudgetReviewTest(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / "docs/benchmarks/issue-335"
        self.record = json.loads((self.directory / "budget-review.json").read_text())

    def test_pending_proposal_is_valid_but_not_accepted(self):
        self.assertEqual("pending", validate_review(self.record, self.directory)["budget_review"])
        with self.assertRaisesRegex(ValueError, "acceptance pending"):
            validate_review(self.record, self.directory, require_accepted=True)

    def test_modified_identity_hash_scope_or_decision_is_rejected(self):
        mutations = [
            lambda r: r["profiles"][0]["evidence"].update(sha256="0" * 64),
            lambda r: r["profiles"][0]["evidence"]["identity"].update(image_id="sha256:" + "0" * 64),
            lambda r: r["profiles"][0].update(account_counts=[1, 2]),
            lambda r: r["profiles"][0]["metrics"].pop(),
            lambda r: r["profiles"][0]["metrics"][0].update(accepted_limits=2),
            lambda r: r.update(status="accepted"),
            lambda r: r.update(reviewer="invented-reviewer"),
        ]
        for mutate in mutations:
            data = copy.deepcopy(self.record)
            mutate(data)
            with self.assertRaises((ValueError, KeyError, TypeError)):
                validate_review(data, self.directory)


if __name__ == "__main__":
    unittest.main(verbosity=2)
