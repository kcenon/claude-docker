#!/usr/bin/env python3
import unittest
from benchmark_isolation import COUNTS, METRICS, MODES, summarize
from container_fixture import ContainerFixture


class BenchmarkHarnessTest(unittest.TestCase):
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
