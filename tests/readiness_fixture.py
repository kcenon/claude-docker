"""Disposable Docker/GitHub command adapter; never contacts either service."""
import json
import os
from pathlib import Path
import runpy
import sys


def main():
    program, args = sys.argv[1], sys.argv[2:]
    if program == "gh":
        if args[:2] == ["auth", "token"]:
            print("placeholder-token")
        return
    path = Path(os.environ["READINESS_FIXTURE"])
    state = json.loads(path.read_text())
    services = ["claude-a", "claude-b"]
    state["calls"].append(args[:5])
    if args[:1] == ["info"] or "config" in args:
        path.write_text(json.dumps(state))
        sys.argv = [str(Path(__file__).parent / "lib/mock_compose.py")] + args
        runpy.run_path(sys.argv[0], run_name="__main__")
        return
    if "up" in args:
        selected = [arg for arg in args[args.index("up") + 1:] if arg in services] or services
        state["started"] = selected
        state["ready"] = []
        state["probes"] = dict.fromkeys(selected, 0)
    elif "ps" in args:
        selected = [arg for arg in args if arg in services] or services
        if "-q" in args or "--quiet" in args:
            print("\n".join(selected))
    elif args[:1] == ["inspect"]:
        service = args[-1]
        print(json.dumps({"Status": "exited" if state.get("refuse") == service else "running",
                          "StartedAt": "fixture-start"}))
    elif args[:1] == ["exec"]:
        service = args[1]
        if args[2:4] == ["python3", "-c"]:
            if state.get("probe_exit"):
                print("private-probe-fixture-canary", file=sys.stderr)
                raise SystemExit(state["probe_exit"])
            state["probes"][service] += 1
            ready = state["probes"][service] >= (2 if service == "claude-a" else 3)
            if ready:
                state["ready"].append(service)
            print("ready" if ready else "starting")
        else:
            if service in state.get("started", []) and service not in state.get("ready", []):
                state["premature"].append([service] + args[2:])
            print("fixture-user-" + service[-1] if "gh" in args else "fixture-version")
    path.write_text(json.dumps(state))


if __name__ == "__main__":
    main()
