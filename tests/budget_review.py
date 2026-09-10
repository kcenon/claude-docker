#!/usr/bin/env python3
"""Validate review bindings and decision fields; does not authenticate a reviewer."""
import argparse
from datetime import date
import hashlib
import json
import math
from pathlib import Path
import re
from benchmark_report import validate


# Metric identity, units and dimensions define the review's scope independently
# of the decision record. Numeric proposals and accepted ceilings remain editable.
METRIC_CONTRACTS = {
    "linux-npm-reference": {
        "startup": ("seconds", "batch", True),
        "executable_readiness": ("seconds", "batch", True),
        "workload_wall": ("seconds", "concurrent batch", True),
        "workload_cpu": ("CPU seconds", "sum over batch", True),
        "idle_memory": ("MiB", "per account", False),
        "lifetime_memory_peak": ("MiB", "per account", False),
        "lifetime_pid_peak": ("processes", "per account", False),
        "scratch_usage": ("MiB", "per account; diagnostic persistent-cache workload only", False),
        "allocated_fixture_storage": ("MiB", "per account; physical storage deduplicated", False),
    },
    "macos-local-dashboard": {
        "local_refresh_small": ("milliseconds", "per refresh; 256-byte input padding; Docker/auth excluded", False),
        "local_refresh_large": ("milliseconds", "per refresh; 64-KiB input padding; Docker/auth excluded", False),
    },
}


def validate_review(record, directory, require_accepted=False):
    def require(condition, reason):
        if not condition:
            raise ValueError(reason)

    require(record.get("schema") == 1, "unsupported review schema")
    status = record.get("status")
    require(status in ("pending", "accepted", "rejected"), "invalid review status")
    profiles = record["profiles"]
    expected = {"linux-npm-reference": "container-linux-x86_64-claude.json",
                "macos-local-dashboard": "dashboard-darwin-arm64.json"}
    require(len(profiles) == 2 and {p["name"] for p in profiles} == set(expected), "missing or duplicate profile")
    for profile in profiles:
        evidence = profile["evidence"]
        filename = expected[profile["name"]]
        metrics = METRIC_CONTRACTS[profile["name"]]
        require(evidence["report"] == filename, "unexpected evidence path")
        path = Path(directory) / filename
        require(hashlib.sha256(path.read_bytes()).hexdigest() == evidence["sha256"], "evidence hash mismatch")
        report = json.loads(path.read_text())
        required_identity = ({"source_commit", "source_dirty", "source_fingerprint_sha256", "image_id", "runtime", "workload", "platform", "architecture", "daemon", "docker_capacity", "sampling"}
                             if profile["name"] == "linux-npm-reference" else
                             {"date", "platform", "cpu", "go", "baseline_head", "working_tree", "benchmark_sha256", "command", "sampling"})
        require(set(evidence["identity"]) == required_identity, "incomplete evidence identity")
        require(all(report[key] == value for key, value in evidence["identity"].items()), "evidence identity mismatch")
        if profile["name"] == "linux-npm-reference":
            validate(report, full=True)
            require(profile["modes"] == ["shared", "worktree", "isolated"], "incomplete mode scope")
        require(profile["account_counts"] == [1, 2, 4], "incomplete account scope")
        require(len(profile["metrics"]) == len(metrics) and {m["metric"] for m in profile["metrics"]} == set(metrics),
                "missing, duplicate or unknown metric")
        for metric in profile["metrics"]:
            unit, scope, per_count = metrics[metric["metric"]]
            require(metric["unit"] == unit, "metric unit mismatch")
            require(metric["scope"] == scope, "metric scope mismatch")
            for field in ("proposed_limits", "accepted_limits"):
                value = metric.get(field)
                if field == "accepted_limits" and status != "accepted":
                    require(value is None, "unaccepted review contains acceptance values")
                    continue
                if per_count:
                    require(isinstance(value, dict), "invalid metric limit shape: per-count mapping required")
                    require(set(value) == {"1", "2", "4"}, "incomplete per-count limits")
                    values = value.values()
                else:
                    require(not isinstance(value, dict), "invalid metric limit shape: scalar required")
                    values = [value]
                require(all(type(v) in (int, float) and math.isfinite(v) and v > 0 for v in values), "invalid metric limit")
    if status == "pending":
        require(all(record.get(k) is None for k in ("reviewer", "review_date", "decision_url", "accepted_regressions")),
                "pending review contains a decision")
    else:
        require(bool(re.fullmatch(r"[A-Za-z0-9-]+", record.get("reviewer") or "")), "reviewer required")
        require(date.fromisoformat(record["review_date"]) <= date.today(), "future review date")
        require(bool(re.fullmatch(r"https://github\.com/kcenon/claude-docker/(?:issues|pull)/[0-9]+#(?:issuecomment|discussion_r|pullrequestreview)-[0-9]+",
                                  record.get("decision_url") or "")), "explicit maintainer decision link required")
        require(isinstance(record.get("accepted_regressions"), list), "explicit regression decision required")
    require(not require_accepted or status == "accepted", "maintainer budget acceptance pending or rejected")
    return {"status": "valid", "budget_review": status, "profiles": len(profiles),
            "decision_authenticity": "requires checking the linked maintainer decision"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path)
    parser.add_argument("--require-accepted", action="store_true")
    args = parser.parse_args()
    try:
        result = validate_review(json.loads(args.record.read_text()), args.record.parent, args.require_accepted)
    except (ValueError, KeyError, TypeError, OSError):
        print(json.dumps({"status": "invalid_or_unaccepted"}))
        raise SystemExit(1)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
