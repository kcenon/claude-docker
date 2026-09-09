#!/usr/bin/env python3
import tempfile
import json
import os
import subprocess
import sys
from types import SimpleNamespace
import unittest
from pathlib import Path
from unittest.mock import patch
import benchmark_isolation
from benchmark_isolation import COUNTS, METRICS, MODES, summarize
from container_fixture import ContainerFixture


class BenchmarkHarnessTest(unittest.TestCase):
    def test_unavailable_oom_counter_is_not_reported_as_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in (("memory/memory.usage_in_bytes", "128"),
                                ("memory/memory.max_usage_in_bytes", "256"), ("pids/pids.current", "2")):
                path = root / name
                path.parent.mkdir(exist_ok=True)
                path.write_text(value)
            probe = benchmark_isolation.RESOURCE_PROBE.replace("pathlib.Path('/sys/fs/cgroup')", "pathlib.Path(" + repr(str(root)) + ")")
            output = subprocess.check_output([sys.executable, "-c", probe], text=True,
                                             env=dict(os.environ, ISOLATION_MODE="shared"))
            self.assertIsNone(json.loads(output)["oom_kills"])
            fixture = SimpleNamespace(count=1, execute=lambda *args: output)
            with self.assertRaisesRegex(AssertionError, "OOM counter unavailable"):
                benchmark_isolation.stats(fixture)

    def test_workload_changes_change_the_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("scripts", "tui/internal", "tests"):
                (root / name).mkdir(parents=True)
            (root / "Dockerfile").write_text("FROM scratch\n")
            (root / "VERSION").write_text("fixture\n")
            with patch.object(benchmark_isolation, "ROOT", root):
                for name in ("tests/benchmark_isolation.py", "scripts/claude-docker", "scripts/claude-docker.cmd", ".dockerignore"):
                    with self.subTest(input=name):
                        workload = root / name
                        workload.write_text("workload version one\n")
                        before = benchmark_isolation.source_fingerprint()
                        workload.write_text("workload version two\n")
                        self.assertNotEqual(before, benchmark_isolation.source_fingerprint())
                before = benchmark_isolation.source_fingerprint()
                (root / "tests/report.json").write_text('{"output": true}')
                (root / "scripts/.env.fixture").write_text("TOKEN=placeholder-secret\n")
                self.assertEqual(before, benchmark_isolation.source_fingerprint())

    def test_summary_rejects_negative_measurements(self):
        for key in METRICS:
            with self.subTest(metric=key):
                samples = [{metric: 1 for metric in METRICS} for _ in range(5)]
                samples[2][key] = -1
                with self.assertRaises(ValueError):
                    summarize(samples)

    def test_matrix_and_sample_statistics(self):
        executed = 0
        for _mode in MODES:
            for _count in COUNTS:
                samples = [{key: value for key in METRICS} for value in (1, 2, 3, 4, 5)]
                summary = summarize(samples)
                for metric in summary.values():
                    self.assertEqual(3, metric["median"])
                    self.assertEqual(2.5, metric["sample_variance"])
                    self.assertEqual(5, metric["samples"])
                executed += 1
        self.assertEqual(9, executed)

    def test_missing_samples_are_not_a_pass(self):
        with self.assertRaises(ValueError):
            summarize([])

    def test_cleanup_removes_only_fixture_resources_after_offline_switch(self):
        fixture = ContainerFixture()
        fixture.cmd = ["docker", "compose", "--project-name", fixture.project]
        remaining = {"network": [fixture.project + "_isolated_net_a"], "volume": [fixture.project + "_node_modules_a"]}
        def run(argv, timeout=120):
            if "down" in argv:
                return ""  # The current offline model no longer lists bridges.
            kind, operation = argv[1:3]
            if operation == "ls":
                self.assertIn("label=com.docker.compose.project=" + fixture.project, argv)
                return "\n".join(remaining[kind])
            self.assertEqual("rm", operation)
            self.assertIn(argv[-1], remaining[kind])
            remaining[kind].remove(argv[-1])
            return ""
        fixture.run = run
        fixture.close()
        self.assertEqual({"network": [], "volume": []}, remaining)


if __name__ == "__main__":
    unittest.main(verbosity=2)
