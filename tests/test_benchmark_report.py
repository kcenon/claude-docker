#!/usr/bin/env python3
"""Corrupt complete synthetic reports; never treat these as measurements."""
import copy
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import benchmark_isolation as driver
from benchmark_report import aggregate_disk, disk_summary, summarize, validate


def complete_report():
    samples = []
    for index in range(1, 6):
        account = {"account": 1, "cpu_seconds": 1, "wall_seconds": 2, "verified_reads": 5000, "package_tests": 3,
                   "disk": {kind: {"source_id": kind + ":1", "apparent_bytes": 32, "allocated_bytes": 512, "files": 1}
                            for kind in ("workspace", "git", "dependency", "state")}}
        observation = {"started": 2, "finished": 3, "memory_bytes": 128,
                       "accounts": [{"memory_bytes": 128, "memory_peak_bytes": 128, "pids": 2,
                                     "pids_peak": 2, "oom_kills": 0, "cgroup_version": 2, "scratch": {}}]}
        idle = copy.deepcopy(observation)
        idle.update(started=0, finished=1, memory_bytes=64)
        idle["accounts"][0]["memory_bytes"] = 64
        samples.append({"sample": index, "startup_seconds": 1, "executable_ready_seconds": 2,
                        "idle_memory_bytes": 64, "observed_peak_memory_bytes": 128, "workload_cpu_seconds": 1,
                        "workload_wall_seconds": 3, "workload_started": 1, "workload_finished": 4,
                        "account_results": [account], "memory_observations": [observation],
                        "physical_disk": aggregate_disk([account]), "oom_kill_delta": 0,
                        "idle_cgroup": idle, "after_cgroup": copy.deepcopy(observation),
                        "idle_docker_cli": {"cache_adjusted_memory_bytes": 32, "cpu_percent": 0}})
    image = "sha256:" + "1" * 64
    cell = {"mode": "isolated", "accounts": 1, "runtime": "claude", "image_id": image, "status": "complete",
            "cleanup": "passed", "manifest": {"budget": {"fixture": True}}, "runtime_versions": ["fixture"],
            "tool_versions": [{"node": "fixture", "npm": "fixture"}], "setup_seconds": 1, "initial_start_seconds": 1,
            "initial_workload": [account], "samples": samples, "summary": summarize(samples), "disk_summary": disk_summary(samples)}
    return {"schema": 2, "status": "complete", "scope": "smoke", "planned_cells": [["isolated", 1]],
            "runtime": "claude", "workload": "npm-local-build-test-v1", "source_dirty": False,
            "source_commit": "0" * 40, "source_fingerprint_sha256": "0" * 64, "image_id": image,
            "started_at": "fixture", "finished_at": "fixture", "compose_version": "fixture", "engine_version": "fixture",
            "platform": "fixture", "architecture": "fixture", "readiness": "fixture", "sampling": "fixture",
            "disk_accounting": "fixture", "docker_capacity": {"cpus": 2, "memory_bytes": 1024},
            "daemon": {"os": "fixture", "kernel": "fixture"}, "image_preparation": {"mode": "fixture"},
            "samples_per_cell": 5, "cells": [cell], "executed_cells": 1, "failures": []}


class ReportTest(unittest.TestCase):
    def test_aggregate_metrics_must_match_account_and_sampler_evidence(self):
        for mutate in (
                lambda s: s.update(workload_cpu_seconds=999),
                lambda s: s.update(workload_wall_seconds=999),
                lambda s: s.update(observed_peak_memory_bytes=999),
                lambda s: s.update(idle_memory_bytes=32),
                lambda s: s["after_cgroup"]["accounts"][0].update(oom_kills=1)):
            report = complete_report()
            cell = report["cells"][0]
            mutate(cell["samples"][0])
            cell["summary"] = summarize(cell["samples"])
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                validate(report)

    def test_variance_rounding_is_portable_across_python_versions(self):
        report = complete_report()
        cell = report["cells"][0]
        # These readiness samples exposed a one-ULP statistics.variance
        # difference between the Linux runner and local Python 3.9.
        values = [1.4213858879999748, 1.4117288169999824, 1.4524703249999789,
                  1.4408422559999963, 1.4479060300000128]
        for sample, value in zip(cell["samples"], values):
            sample["executable_ready_seconds"] = value
        cell["summary"] = summarize(cell["samples"])
        summary = cell["summary"]["executable_ready_seconds"]
        summary["sample_variance"] = math.nextafter(summary["sample_variance"], math.inf)
        self.assertEqual("valid", validate(report)["status"])
        summary["sample_variance"] *= 1.01
        with self.assertRaises(ValueError):
            validate(report)

    def test_valid_smoke_and_full_scope_refusal(self):
        report = complete_report()
        self.assertEqual(5, validate(report)["measured_samples"])
        with self.assertRaisesRegex(ValueError, "smoke"):
            validate(report, full=True)

    def test_corrupt_reports_are_rejected(self):
        mutations = [
            lambda r: r.update(status="incomplete"),
            lambda r: r.update(source_fingerprint_sha256=""),
            lambda r: r.update(source_dirty=None),
            lambda r: r["cells"].append(copy.deepcopy(r["cells"][0])),
            lambda r: r["cells"][0].update(cleanup="failed"),
            lambda r: r["cells"][0].update(image_id="sha256:" + "2" * 64),
            lambda r: r["cells"][0]["samples"].pop(),
            lambda r: r["cells"][0]["samples"][0].update(sample=2),
            lambda r: r["cells"][0]["samples"][0].update(oom_kill_delta=1),
            lambda r: r["cells"][0]["samples"][0]["account_results"].clear(),
            lambda r: r["cells"][0]["samples"][0]["account_results"][0].update(verified_reads=0),
            lambda r: r["cells"][0]["samples"][0].update(memory_observations=[]),
            lambda r: r["cells"][0]["samples"][0]["memory_observations"][0].update(finished=10),
            lambda r: r["cells"][0]["samples"][0]["physical_disk"]["git"].update(apparent_bytes=999),
            lambda r: r["cells"][0]["summary"]["startup_seconds"].update(median=999),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index), self.assertRaises(ValueError):
                report = complete_report()
                mutate(report)
                validate(report)

    def test_nonfinite_missing_and_boolean_measurements_are_rejected(self):
        for value in (None, float("nan"), float("inf"), -1, True, "1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                report = complete_report()
                report["cells"][0]["samples"][0]["startup_seconds"] = value
                validate(report)

    def test_shared_disk_is_counted_once(self):
        account = complete_report()["cells"][0]["samples"][0]["account_results"][0]
        self.assertEqual(32, aggregate_disk([account, copy.deepcopy(account)])["workspace"]["apparent_bytes"])
        altered = copy.deepcopy(account)
        altered["disk"]["workspace"]["apparent_bytes"] = 33
        with self.assertRaises(ValueError):
            aggregate_disk([account, altered])

    def test_failed_collection_retains_an_incomplete_report(self):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(output=Path(directory) / "report.json", samples=5, runtime="claude")
            report = complete_report()
            report.update(status="running", cells=[], failures=[])
            with patch.object(driver, "measure_cell", side_effect=RuntimeError("injected sampler failure")):
                with self.assertRaises(RuntimeError):
                    driver.collect(args, report)
            retained = json.loads(args.output.read_text())
            self.assertEqual("incomplete", retained["status"])
            self.assertEqual(0, retained["executed_cells"])
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("benchmark_report.py")), str(args.output)],
                                    capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("incomplete", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
