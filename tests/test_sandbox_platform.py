#!/usr/bin/env python3
"""Record actual requested-sandbox capability or fail-closed refusal."""
import argparse
import json
from pathlib import Path
import platform
from workflow_support import AuthenticatedFixture, WorkflowFailure, finish, provenance, record


def verify(fixture, degraded):
    settings = fixture.states[0] / "local-config/settings.json"
    settings.write_text(json.dumps({"sandbox": {"enabled": True}}))
    fixture.execute(0, "rm", "-f", "/tmp/issue335-sandbox-executed")
    result = fixture.probe(0, "env", "CLAUDE_ALLOW_DEGRADED_SETTINGS=" + ("1" if degraded else "0"),
                           "entrypoint.sh", "sh", "-c", "touch /tmp/issue335-sandbox-executed", timeout=60)
    marker = fixture.probe(0, "test", "-e", "/tmp/issue335-sandbox-executed").returncode == 0
    if result.returncode == 0:
        if not marker or "Requested sandbox: capability probe passed; runtime fallback disabled." not in result.stdout:
            raise WorkflowFailure("requested_command_not_executed")
        return {"capability": "sandbox_probe_executed", "degraded_override": degraded}
    if marker or "requested sandbox cannot execute under the current kernel/container policy" not in result.stderr:
        raise WorkflowFailure("sandbox_refusal_not_established")
    return {"capability": "unavailable_refused_before_exec", "degraded_override": degraded}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", type=Path, default=Path("sandbox-platform.json"))
    args = parser.parse_args()
    fixture = AuthenticatedFixture(runtime="claude", image=args.image)
    report = {"schema": 1, "platform": platform.platform(), "scope": "actual container gate, no authenticated session", "cases": []}
    try:
        report["provenance"] = provenance(fixture)
        fixture.prepare()
        fixture.up()
        for degraded in (False, True):
            name = "requested_sandbox_degraded_override" if degraded else "requested_sandbox"
            record(report, "claude", name, lambda d=degraded: verify(fixture, d), 1)
    except Exception:
        report["cases"].append({"name": "startup", "status": "failed", "reason": "fixture_startup_failed"})
    finally:
        record(report, "claude", "cleanup", fixture.close)
    raise SystemExit(finish(report, args.output, require_complete=True))


if __name__ == "__main__":
    main()
