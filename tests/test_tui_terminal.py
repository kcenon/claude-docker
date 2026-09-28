#!/usr/bin/env python3
"""Exercise compiled Go UI selection/ExecProcess/return with a native test child."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from container_fixture import ROOT
from terminal_support import Terminal
from workflow_support import WorkflowFailure
from workflow_terminal import drive_tui


class TUITerminalTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="tui-terminal-build-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.build = Path(cls.temp.name)
        cls.suffix = ".exe" if os.name == "nt" else ""
        subprocess.run(["go", "build", "-o", str(cls.build / ("tui" + cls.suffix)), "."], cwd=ROOT / "tui", check=True)
        subprocess.run(["go", "build", "-o", str(cls.build / ("docker" + cls.suffix)),
                        str(ROOT / "tests/fixtures/terminal-docker.go")], check=True)
        cls.registry = json.loads((ROOT / "tui/internal/config/runtimes.json").read_text())["runtimes"]

    def exercise(self, runtime, index, mutation=None):
        with tempfile.TemporaryDirectory(prefix="tui-terminal-fixture-") as directory:
            root = Path(directory).resolve()
            spec = self.registry[runtime]
            (root / "bin").mkdir()
            (root / "scripts").mkdir()
            (root / "home").mkdir()
            (root / "scripts/claude-docker").touch()
            for name in ("docker-compose.yml", "docker-compose.isolated.yml"):
                (root / name).write_text("services: {}\n")
            (root / ".env").write_text("NUM_ACCOUNTS=2\nISOLATION_MODE=isolated\nAGENT_RUNTIME=" + runtime + "\n")
            (root / "spec.json").write_text(json.dumps({"Binary": spec["binary"], "ServicePrefix": spec["servicePrefix"]}))
            binary = root / "bin" / ("claude-docker-tui" + self.suffix)
            shutil.copy2(self.build / ("tui" + self.suffix), binary)
            shutil.copy2(self.build / ("docker" + self.suffix), root / "bin" / ("docker" + self.suffix))
            env = {key: value for key, value in os.environ.items() if key.upper() in
                   ("PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP")}
            env.update(HOME=str(root / "home"), USERPROFILE=str(root / "home"),
                       PATH=str(root / "bin") + os.pathsep + env.get("PATH", ""), TERMINAL_FIXTURE_ROOT=str(root))
            if mutation:
                env[mutation] = "1"
            expected = spec["servicePrefix"] + ("-a" if index == 0 else "-b") + " " + spec["binary"]
            marker = root / "attached"
            def attached():
                if not marker.exists():
                    return False
                if marker.read_text() != expected:
                    raise WorkflowFailure("wrong_account_attach")
                return True
            with Terminal([str(binary)], root, env) as terminal:
                drive_tui(terminal, index, attached)

    def test_all_runtime_account_handoffs_return_control(self):
        for runtime in self.registry:
            for index in (0, 1):
                with self.subTest(runtime=runtime, account=index + 1):
                    self.exercise(runtime, index)

    def test_wrong_account_is_not_an_attach_success(self):
        with self.assertRaisesRegex(WorkflowFailure, "^wrong_account_attach$"):
            self.exercise("claude", 0, "TERMINAL_WRONG_ACCOUNT")

    def test_runtime_failure_survives_dashboard_restore(self):
        with self.assertRaisesRegex(WorkflowFailure, "^tui_runtime_exit_failed$"):
            self.exercise("claude", 0, "TERMINAL_CHILD_FAIL")


if __name__ == "__main__":
    unittest.main(verbosity=2)
