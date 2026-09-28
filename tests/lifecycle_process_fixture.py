"""Test-owned Docker process boundary and deterministic transaction barriers."""
import json
import os
from pathlib import Path
import sys
import time
from test_lifecycle import LifecycleTest, policy


def pause(phase):
    control = Path(os.environ["ISSUE335_PROCESS_FIXTURE"])
    config = json.loads(control.read_text())
    marker = control.with_suffix(".barrier")
    if config["phase"] != phase or marker.exists():
        return
    marker.write_text(json.dumps({"phase": phase, "pid": os.getpid()}))
    deadline = time.monotonic() + 45
    while not control.with_suffix(".release").exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("Fixture barrier timed out")
        time.sleep(0.02)


def main():
    control = Path(os.environ["ISSUE335_PROCESS_FIXTURE"])
    config = json.loads(control.read_text())
    path = control.with_suffix(".state")
    state = json.loads(path.read_text())
    fixture = LifecycleTest()
    fixture.root = Path(config["root"])
    fixture.fixture_home = Path(config["home"])
    fixture.env = dict(policy.read_env(fixture.root / ".env"), **os.environ)
    fixture.running, fixture.existing = set(state["running"]), set(state["existing"])
    fixture.calls, fixture.failure, fixture.phase = [], "", "staging"
    fixture.resource_set, fixture.volume_labels = state["resources"], state["volume_labels"]
    argv = ["docker"] + sys.argv[1:]
    if argv[1:] == ["compose", "version", "--short"]:
        print("2.39.0")
        return
    if config["phase"] == "outage" and state.get("applied"):
        raise SystemExit(17)
    output = fixture.fake_run(argv)
    state.update(running=sorted(fixture.running), existing=sorted(fixture.existing),
                 resources=fixture.resource_set, volume_labels=fixture.volume_labels)
    applying = "up" in argv and any("staged" in arg for arg in argv)
    if applying:
        state["applied"] = True
        directory = fixture.fixture_home / ".claude-state/account-c"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "unrelated-write").write_text("retain account data")
    path.write_text(json.dumps(state))
    if "config" in argv and any("staged" in arg for arg in argv):
        pause("staged")
    if applying:
        pause("application")
        if config["phase"] in ("compensation", "outage"):
            raise SystemExit(17)
    if "up" in argv and any("backup" in arg for arg in argv):
        pause("compensation")
        pause("recovery")
    print(output)


if __name__ == "__main__":
    main()
