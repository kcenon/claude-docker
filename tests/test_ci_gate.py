#!/usr/bin/env python3
"""Execute the actual aggregate check with failing, skipped and cancelled jobs."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CIGateTests(unittest.TestCase):
    def setUp(self):
        path = Path(os.environ.get("CI_WORKFLOW", ROOT / ".github/workflows/ci.yml"))
        workflow = path.read_text().split("jobs:\n", 1)[1]
        match = re.search(r"^  required:\n(.*?)(?=^  [a-z][\w-]*:)", workflow, re.M | re.S)
        self.assertIsNotNone(match, "Missing aggregate CI job")
        gate = match[1]
        needs = re.search(r"needs: \[(.*?)\]", gate, re.S)
        self.assertIsNotNone(needs)
        self.needs = re.findall(r"[a-z][\w-]*", needs[1])
        jobs = set(re.findall(r"^  ([a-z][\w-]*):", workflow, re.M)) - {"required"}
        self.assertEqual(set(self.needs), jobs, "Every CI job must feed the required gate")
        self.code = textwrap.dedent(re.search(r"python3 - <<'PY'\n(.*?)^          PY$", gate, re.M | re.S)[1])

    def run_gate(self, statuses, event="pull_request"):
        results = {name: {"result": statuses.get(name, "success")} for name in self.needs}
        return subprocess.run([sys.executable, "-c", self.code], capture_output=True,
                              env=dict(os.environ, RESULTS=json.dumps(results), EVENT=event)).returncode

    def test_success_and_push_only_freshness_skip(self):
        self.assertEqual(self.run_gate({}), 0)
        self.assertEqual(self.run_gate({"image-tag-freshness": "skipped"}, "push"), 0)
        self.assertNotEqual(self.run_gate({"image-tag-freshness": "skipped"}), 0)

    def test_every_failed_skipped_or_cancelled_job_blocks_merging(self):
        for name in self.needs:
            for status in ("failure", "skipped", "cancelled"):
                with self.subTest(job=name, result=status):
                    self.assertNotEqual(self.run_gate({name: status}), 0)


if __name__ == "__main__":
    unittest.main()
