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


def validate_review(record, directory, require_accepted=False):
    def require(condition, reason):
        if not condition:
            raise ValueError(reason)

    require(record.get("schema") == 1, "unsupported review schema")
    status = record.get("status")
    require(status in ("pending", "accepted", "rejected"), "invalid review status")
    profiles = record["profiles"]
    expected = {"linux-npm-reference": ("container-linux-x86_64-claude.json", 9),
                "macos-local-dashboard": ("dashboard-darwin-arm64.json", 2)}
    require(len(profiles) == 2 and {p["name"] for p in profiles} == set(expected), "missing or duplicate profile")
    for profile in profiles:
        evidence = profile["evidence"]
        filename, metrics = expected[profile["name"]]
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
        require(len(profile["metrics"]) == metrics and len({m["metric"] for m in profile["metrics"]}) == metrics,
                "missing or duplicate metric")
        for metric in profile["metrics"]:
            require(bool(metric["unit"]) and bool(metric["scope"]), "metric units and scope required")
            for field in ("proposed_limits", "accepted_limits"):
                value = metric.get(field)
                if field == "accepted_limits" and status != "accepted":
                    require(value is None, "unaccepted review contains acceptance values")
                    continue
                values = value.values() if isinstance(value, dict) else [value]
                if isinstance(value, dict):
                    require(set(value) == {"1", "2", "4"}, "incomplete per-count limits")
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
