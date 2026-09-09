#!/usr/bin/env python3
"""Validate measured reports before they can be used as capacity evidence."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics

MODES = ("shared", "worktree", "isolated")
COUNTS = (1, 2, 4)
METRICS = {"startup_seconds": "seconds", "executable_ready_seconds": "seconds",
           "idle_memory_bytes": "bytes", "observed_peak_memory_bytes": "bytes",
           "workload_cpu_seconds": "CPU seconds", "workload_wall_seconds": "seconds"}
DISK_KINDS = ("workspace", "git", "dependency", "state")
DISK_FIELDS = ("apparent_bytes", "allocated_bytes", "files")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, name, integer=False):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0,
            name + " must be a finite nonnegative number.")
    if integer:
        require(type(value) is int, name + " must be an integer.")
    return value


def summarize(samples):
    require(isinstance(samples, list) and len(samples) >= 5,
            "At least five measured samples are required per matrix cell.")
    result = {}
    for key, unit in METRICS.items():
        values = [number(sample.get(key), key) for sample in samples]
        result[key] = {"median": statistics.median(values),
                       "sample_variance": statistics.variance(values),
                       "samples": len(values), "unit": unit}
    return result


def aggregate_disk(accounts):
    """Sum each physical source once within its storage category."""
    result = {}
    for kind in DISK_KINDS:
        sources = {}
        for account in accounts:
            item = account["disk"][kind]
            values = {key: number(item.get(key), kind + "." + key, integer=True) for key in DISK_FIELDS}
            identity = item.get("source_id")
            require(isinstance(identity, str) and identity, "Disk source identity is required.")
            require(identity not in sources or sources[identity] == values,
                    "Repeated physical disk sources disagree.")
            sources[identity] = values
        result[kind] = {key: sum(item[key] for item in sources.values()) for key in DISK_FIELDS}
        result[kind]["physical_sources"] = len(sources)
    return result


def disk_summary(samples):
    result = {}
    for kind in DISK_KINDS:
        result[kind] = {}
        for field in DISK_FIELDS:
            values = [sample["physical_disk"][kind][field] for sample in samples]
            result[kind][field] = {"median": statistics.median(values),
                                   "sample_variance": statistics.variance(values),
                                   "samples": len(values), "unit": "count" if field == "files" else "bytes"}
    return result


def summary_matches(actual, expected):
    """Allow only variance rounding across supported Python versions."""
    if not isinstance(actual, dict) or actual.keys() != expected.keys():
        return False
    if "sample_variance" not in expected:
        return all(summary_matches(actual[key], value) for key, value in expected.items())
    for key, value in expected.items():
        if key == "sample_variance":
            observed = number(actual[key], key)
            # statistics.variance changed its final rational-to-float rounding
            # across Python releases. Raw measurements are never rounded.
            if abs(observed - value) > 4 * math.ulp(value):
                return False
        elif actual[key] != value:
            return False
    return True


def validate(report, full=False):
    require(isinstance(report, dict) and report.get("schema") == 2, "Expected benchmark schema 2.")
    require(report.get("status") == "complete", "The benchmark report is incomplete.")
    require(report.get("scope") in ("smoke", "full matrix"), "Unknown benchmark scope.")
    require(not full or report["scope"] == "full matrix", "A smoke report cannot satisfy the full matrix.")
    expected = [("isolated", 1)] if report["scope"] == "smoke" else [(m, n) for m in MODES for n in COUNTS]
    require(report.get("planned_cells") == [list(item) for item in expected], "The planned matrix is inconsistent.")
    require(report.get("runtime") in ("claude", "codex", "gemini"), "Unknown runtime.")
    require(report.get("workload") == "npm-local-build-test-v1", "Unknown workload.")
    require(type(report.get("source_dirty")) is bool, "Source dirty status is required.")
    for key, pattern in (("source_commit", r"[0-9a-f]{40}"),
                         ("source_fingerprint_sha256", r"[0-9a-f]{64}"),
                         ("image_id", r"sha256:[0-9a-f]{64}")):
        require(isinstance(report.get(key), str) and re.fullmatch(pattern, report[key]), key + " is invalid.")
    for key in ("started_at", "finished_at", "compose_version", "engine_version", "platform",
                "architecture", "readiness", "sampling", "disk_accounting"):
        require(isinstance(report.get(key), str) and report[key].strip(), key + " is required.")
    for key in ("cpus", "memory_bytes"):
        require(number(report.get("docker_capacity", {}).get(key), key) > 0, "Docker capacity must be positive.")
    require(isinstance(report.get("daemon"), dict) and report["daemon"].get("os") and report["daemon"].get("kernel"),
            "Daemon platform provenance is required.")
    require(isinstance(report.get("image_preparation"), dict) and report["image_preparation"].get("mode"),
            "Image preparation provenance is required.")
    requested = number(report.get("samples_per_cell"), "samples_per_cell", integer=True)
    require(requested >= 5, "At least five measured samples are required.")
    cells = report.get("cells")
    require(isinstance(cells, list) and len(cells) == len(expected), "Missing matrix cells.")
    require(report.get("executed_cells") == len(expected), "Executed cell count is inconsistent.")
    require(not report.get("failures"), "The report contains failed operations.")
    found = []
    for cell in cells:
        identity = (cell.get("mode"), cell.get("accounts"))
        require(identity in expected and identity not in found, "Duplicate or unexpected matrix cell.")
        found.append(identity)
        count = identity[1]
        require(cell.get("runtime") == report["runtime"], "Cell runtime does not match provenance.")
        require(cell.get("image_id") == report["image_id"], "Cell image does not match provenance.")
        require(cell.get("status") == "complete" and cell.get("cleanup") == "passed", "Cell did not finish cleanly.")
        require(isinstance(cell.get("manifest"), dict) and cell["manifest"].get("budget"), "Effective budgets are missing.")
        require(len(cell.get("runtime_versions", [])) == count and all(cell["runtime_versions"]),
                "Runtime version count is inconsistent.")
        require(len(cell.get("tool_versions", [])) == count and all(v.get("node") and v.get("npm") for v in cell["tool_versions"]),
                "Workload tool versions are missing.")
        number(cell.get("setup_seconds"), "setup_seconds")
        number(cell.get("initial_start_seconds"), "initial_start_seconds")
        require(len(cell.get("initial_workload", [])) == count, "Initial workload account count is inconsistent.")
        samples = cell.get("samples", [])
        require(len(samples) == requested, "Incorrect measured sample count.")
        require([s.get("sample") for s in samples] == list(range(1, requested + 1)), "Duplicate or missing sample IDs.")
        summary = summarize(samples)
        require(summary_matches(cell.get("summary"), summary), "Stored timing summary does not match raw samples.")
        for sample in samples:
            require(sample["observed_peak_memory_bytes"] >= sample["idle_memory_bytes"], "Peak memory is below idle memory.")
            accounts = sample.get("account_results", [])
            require(len(accounts) == count and [a.get("account") for a in accounts] == list(range(1, count + 1)),
                    "Workload account count/order is inconsistent.")
            for account in accounts:
                require(account.get("verified_reads") == 5000 and account.get("package_tests") == 3,
                        "The expected build/test workload did not execute.")
                number(account.get("cpu_seconds"), "account CPU time")
                number(account.get("wall_seconds"), "account wall time")
            require(sample.get("physical_disk") == aggregate_disk(accounts), "Physical storage totals are inconsistent.")
            observations = sample.get("memory_observations", [])
            start = number(sample.get("workload_started"), "workload_started")
            end = number(sample.get("workload_finished"), "workload_finished")
            require(end > start and observations, "Workload sampling interval is missing.")
            covered = 0
            for observation in observations:
                began = number(observation.get("started"), "observation start")
                ended = number(observation.get("finished"), "observation finish")
                require(ended >= began, "Observation time runs backwards.")
                rows = observation.get("accounts", [])
                require(len(rows) == count, "Resource sampler missed an account.")
                for row in rows:
                    for key in ("memory_bytes", "pids", "oom_kills"):
                        number(row.get(key), key, integer=True)
                require(observation.get("memory_bytes") == sum(row["memory_bytes"] for row in rows),
                        "Memory aggregation is inconsistent.")
                covered += int(start <= began <= ended <= end)
            require(covered > 0, "No resource observation completed during the workload.")
            require(sample.get("oom_kill_delta") == 0, "A workload was OOM killed.")
        require(summary_matches(cell.get("disk_summary"), disk_summary(samples)), "Stored disk summary does not match raw samples.")
    return {"status": "valid", "scope": report["scope"], "executed_cells": len(cells),
            "measured_samples": len(cells) * requested, "budget_review": report.get("budget_review", "pending")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--require-full", action="store_true")
    parser.add_argument("--summary", action="store_true", help="Print validated per-cell timing and physical storage summaries")
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text())
        result = validate(report, args.require_full)
        if args.summary:
            result.update(source_commit=report["source_commit"], image_id=report["image_id"],
                          runtime=report["runtime"], workload=report["workload"],
                          cells=[{key: cell[key] for key in ("mode", "accounts", "summary", "disk_summary")}
                                 for cell in report["cells"]])
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, "Invalid benchmark report: " + str(error) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
