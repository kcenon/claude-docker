"""Docker boundary for auth-selection tests, including Python host callers."""
import json
import os
from pathlib import Path
import runpy
import sys

args = sys.argv[1:]
with open(os.environ["DOCKER_MOCK_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
if args[:1] == ["info"] or "config" in args:
    runpy.run_path(str(Path(__file__).with_name("mock_compose.py")), run_name="__main__")
elif args[:1] == ["inspect"]:
    print(json.dumps({"Status": "running", "StartedAt": "fixture-start"}))
elif args[:1] == ["exec"]:
    if args[2:4] == ["python3", "-c"]:
        print("ready")
    else:
        print("replacement-user-b" if args[1] == "cid-b" else "fixture-user-a")
elif "ps" in args and ("-q" in args or "--quiet" in args):
    print("cid-b" if args[-1] == "claude-b" else "cid-a")
