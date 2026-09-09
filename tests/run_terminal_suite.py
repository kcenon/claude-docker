#!/usr/bin/env python3
"""Supervise placeholder terminal suites without sharing CI's log pipes."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=("test_terminal_support.py", "test_tui_terminal.py"))
    args = parser.parse_args()
    # Native console creation/teardown can hold inherited pipe handles after
    # the test process exits. A private temporary file keeps CI's log reader
    # independent and lets the supervisor publish placeholder-only diagnostics.
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen([sys.executable, "-u", str(Path(__file__).with_name(args.suite))],
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                   start_new_session=os.name != "nt")
        try:
            code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            code = 1
            if os.name == "nt":
                try:
                    subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                except subprocess.TimeoutExpired:
                    pass
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            print("Terminal suite exceeded its supervised deadline", flush=True)
        finally:
            output.seek(0)
            # Publish only test outcomes, even if a broken adapter leaks its
            # placeholder child output into the suite's standard handles.
            for line in output.read(65536).decode("utf-8", errors="replace").splitlines():
                if re.fullmatch(r"test_[a-z_]+ \([^\r\n]+\) \.\.\. (?:ok|FAIL|ERROR|skipped '[^']*')"
                                r"|Ran [0-9]+ tests? in [0-9.]+s|OK(?: \(skipped=[0-9]+\))?"
                                r"|FAILED \([a-z=0-9, ]+\)|(?:ERROR|FAIL): test_[a-z_]+ \([^\r\n]+\)"
                                r"|workflow_support.WorkflowFailure: [a-z_]+", line):
                    print(line, flush=True)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
