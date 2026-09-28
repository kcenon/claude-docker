#!/usr/bin/env python3
"""Daemon-free shared-mode stub for wrapper/count tests, never a live client."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if os.environ.get("DOCKER_LOG"):
    with open(os.environ["DOCKER_LOG"], "a") as output:
        output.write(" ".join(args) + "\n")
if args[:1] == ["info"]:
    print(json.dumps({"NCPU": 4, "MemTotal": 8589934592}))
elif "config" in args:
    count = int(os.environ.get("NUM_ACCOUNTS", "2"))
    model = {"name": "fixture", "services": {}, "volumes": {}, "networks": {}}
    for index in range(1, count + 1):
        number, letter = index, ""
        while number:
            number, digit = divmod(number - 1, 26)
            letter = chr(97 + digit) + letter
        model["services"]["claude-" + letter] = {
            "user": "1001:1001", "environment": {"ISOLATION_MODE": "shared", "NODE_OPTIONS": "--max-old-space-size=3072"},
            "volumes": [{"type": "bind", "source": str(Path(os.environ["HOME"]) / ".claude-state" / ("account-" + letter)), "target": "/home/node/.claude"}],
            "deploy": {"resources": {"limits": {"cpus": "2", "memory": 4294967296}, "reservations": {"cpus": "1", "memory": 2147483648}}}}
    print(json.dumps(model))
elif "up" in args and os.environ.get("MOCK_UP_FAILURE"):
    sys.exit(int(os.environ["MOCK_UP_FAILURE"]))
# No services are running, and no volumes/networks exist. No native Docker
# binary is delegated to, including on an unrecognized command.
