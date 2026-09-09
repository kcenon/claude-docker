#!/usr/bin/env python3
"""Real native wrapper/process interruption; only Docker is simulated."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import test_lifecycle as existing

ROOT = existing.ROOT


class LifecycleProcessTest(unittest.TestCase):
    def setUp(self):
        fixture = existing.LifecycleTest()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.generate()
        self.fixture = fixture
        self.root = fixture.root
        self.control = Path(fixture.temp.name) / "process.json"
        self.control.with_suffix(".state").write_text(json.dumps({
            "running": ["claude-a"], "existing": ["claude-a", "claude-b"],
            "resources": fixture.resource_set, "volume_labels": {}}))
        self.env = dict(fixture.env, ISSUE335_PROCESS_FIXTURE=str(self.control))
        # A disposable policy copy gets a process adapter and one publication
        # barrier. Production code has no fault flags or modified signals.
        path = self.root / "scripts/lib/lifecycle.py"
        code = path.read_text()
        adapter = "\nimport sys\nsys.path.insert(0, " + repr(str(ROOT / "tests")) + ")\nfrom lifecycle_process_fixture import pause as fixture_pause\n"
        code = code.replace("class PolicyError(Exception):", adapter + "\nclass PolicyError(Exception):", 1)
        old = "def run(argv, env=None, cwd=None, timeout=60):\n"
        self.assertIn(old, code)
        code = code.replace(old, old + "    if argv[0] == 'docker':\n        argv = [sys.executable, " + repr(str(ROOT / "tests/lifecycle_process_fixture.py")) + "] + argv[1:]\n", 1)
        old = "        os.replace(temp, destination)\n"
        self.assertEqual(1, code.count(old))
        code = code.replace(old, old + "        if destination.name == '.env' and source.parent.name == 'staged':\n            fixture_pause('publication')\n", 1)
        path.write_text(code)
        self.before = fixture.snapshot()
        self.acl_before = self.acls()
        self.prefix = (["pwsh", "-NoProfile", "-File", str(self.root / "scripts/claude-docker.ps1")]
                       if os.name == "nt" else ["bash", str(self.root / "scripts/claude-docker")])
        self.children = []
        self.addCleanup(self.stop_children)

    def acls(self):
        if os.name != "nt":
            return None
        script = self.root / "inspect-acls.ps1"
        script.write_text("param([string]$RootPath)\n@('.env','docker-compose.yml','docker-compose.linux.yml','docker-compose.worktree.yml','docker-compose.isolated.yml') | ForEach-Object { (Get-Acl -LiteralPath (Join-Path $RootPath $_)).Sddl } | ConvertTo-Json\n")
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(script), str(self.root)],
                                cwd=self.root, env=self.env, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def stop_children(self):
        self.control.with_suffix(".release").touch()
        for process in self.children:
            if process.poll() is None:
                process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            for output in process.fixture_output:
                output.close()

    def arm(self, phase):
        self.control.write_text(json.dumps({"phase": phase, "root": str(self.root), "home": str(self.fixture.fixture_home)}))
        self.control.with_suffix(".barrier").unlink(missing_ok=True)
        self.control.with_suffix(".release").unlink(missing_ok=True)

    def start(self, *arguments):
        # Windows pipes can fill before the parent reaches communicate().
        # File-backed capture keeps barrier progress independent of output.
        outputs = [tempfile.TemporaryFile(mode="w+t", encoding="utf-8", errors="replace") for _ in range(2)]
        process = subprocess.Popen(self.prefix + list(arguments), cwd=self.root, env=self.env,
                                   stdout=outputs[0], stderr=outputs[1], text=True,
                                   start_new_session=os.name != "nt",
                                   creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
        process.fixture_output = outputs
        self.children.append(process)
        return process

    def complete(self, process, timeout=30):
        process.wait(timeout=timeout)
        for output in process.fixture_output:
            output.seek(0)
        return tuple(output.read() for output in process.fixture_output)

    def wait_barrier(self, process):
        deadline = time.monotonic() + getattr(self, "barrier_timeout", 30)
        marker = self.control.with_suffix(".barrier")
        while not marker.exists():
            if process.poll() is not None:
                self.fail("Wrapper exited before fixture barrier: " + repr(self.complete(process)))
            if time.monotonic() >= deadline:
                self.fail("Wrapper did not reach fixture barrier")
            time.sleep(0.02)
        return json.loads((self.root / ".claude-docker-lifecycle/owner.json").read_text())["pid"]

    def invoke(self, *arguments, success=True):
        process = self.start(*arguments)
        output, errors = self.complete(process)
        self.assertEqual(success, process.returncode == 0, errors)
        self.assertNotIn("placeholder-secret", output + errors)
        return output + errors

    def terminate_owner(self, pid):
        if os.name == "nt":
            result = subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)
            self.assertEqual(0, result.returncode)
        else:
            os.kill(pid, signal.SIGKILL)

    def assert_restored(self, had_application):
        self.assertEqual(self.before, self.fixture.snapshot())
        self.assertEqual(self.acl_before, self.acls())
        state = json.loads(self.control.with_suffix(".state").read_text())
        self.assertEqual(["claude-a"], state["running"])
        self.assertEqual(["claude-a", "claude-b"], state["existing"])
        self.assertNotIn("fixture_node_modules_c", state["resources"]["volume"])
        if had_application:
            self.assertEqual("retain account data", (self.fixture.fixture_home / ".claude-state/account-c/unrelated-write").read_text())
        self.assertFalse((self.root / ".claude-docker-lifecycle").exists())
        self.assertIn("No interrupted", self.invoke("recover"))

    def interrupted(self, phase, signum=None, console=False):
        self.arm(phase)
        process = self.start("scale", "3")
        owner = self.wait_barrier(process)
        self.invoke("recover", success=False)
        self.invoke("claude", "claude-a", success=False)
        if console:
            process.send_signal(signal.CTRL_BREAK_EVENT)
        elif signum:
            os.kill(owner, signum)
        else:
            self.terminate_owner(owner)
        self.control.with_suffix(".release").touch()
        output, errors = self.complete(process)
        self.assertNotEqual(0, process.returncode)
        self.assertNotIn("Scaled to", output + errors)
        lock = self.root / ".claude-docker-lifecycle"
        if lock.exists() and (lock / "journal.json").exists() and os.name != "nt":
            self.assertEqual(0o600, (lock / "journal.json").stat().st_mode & 0o777)
        self.arm("none")
        self.invoke("recover")
        self.assert_restored(phase in ("application", "compensation"))

    def test_hard_termination_before_publication(self):
        self.interrupted("staged")

    def test_hard_termination_during_publication(self):
        self.interrupted("publication")

    def test_output_cannot_block_a_transaction_barrier(self):
        path = self.root / "scripts/lib/lifecycle.py"
        code = path.read_text()
        old = "            print(json.dumps(manifest, indent=2), flush=True)"
        self.assertIn(old, code)
        path.write_text(code.replace(old, "            print('fixture diagnostic ' * 65536, flush=True)\n" + old, 1))
        self.barrier_timeout = 10
        self.interrupted("publication")

    def test_hard_termination_during_application(self):
        self.interrupted("application")

    def test_hard_termination_during_compensation(self):
        self.interrupted("compensation")

    @unittest.skipIf(os.name == "nt", "POSIX SIGTERM semantics")
    def test_handled_sigterm(self):
        self.interrupted("publication", signal.SIGTERM)

    @unittest.skipIf(os.name == "nt", "POSIX SIGINT semantics")
    def test_handled_sigint(self):
        self.interrupted("publication", signal.SIGINT)

    @unittest.skipUnless(os.name == "nt", "Native Windows console break")
    def test_native_console_break(self):
        self.interrupted("publication", console=True)

    def test_connection_failure_retains_journal_until_recovery(self):
        self.arm("outage")
        self.assertIn("Recovery incomplete", self.invoke("scale", "3", success=False))
        self.assertTrue((self.root / ".claude-docker-lifecycle/journal.json").exists())
        self.arm("none")
        self.invoke("recover")
        self.assert_restored(True)

    def test_concurrent_recovery_refused(self):
        self.arm("outage")
        self.invoke("scale", "3", success=False)
        self.arm("recovery")
        process = self.start("recover")
        self.wait_barrier(process)
        self.invoke("recover", success=False)
        self.control.with_suffix(".release").touch()
        output, errors = self.complete(process)
        self.assertEqual(0, process.returncode, errors)
        self.assert_restored(True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
