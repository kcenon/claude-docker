#!/usr/bin/env python3
"""Cleanup must retain dirty worktrees and honor a declined removal on both shells."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CleanupWorktreeTests(unittest.TestCase):
    def check_cleanup(self, language, decision, dirty):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            install, project, home = root / "install", root / "project", root / "home"
            shutil.copytree(ROOT / "scripts", install / "scripts")
            (install / "tui/internal/config").mkdir(parents=True)
            shutil.copy(ROOT / "tui/internal/config/runtimes.json", install / "tui/internal/config")
            home.mkdir()
            state = home / ".claude-state"
            state.mkdir()
            (state / "keep").write_text("placeholder")
            subprocess.run(["git", "init", "-q", str(project)], check=True)
            subprocess.run(["git", "-C", str(project), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                            "commit", "-q", "--allow-empty", "-m", "fixture"], check=True)
            worktree = root / "project-a"
            subprocess.run(["git", "-C", str(project), "worktree", "add", "-q", "-b", "account", str(worktree)], check=True)
            if dirty:
                (worktree / "untracked.txt").write_text("keep local work")
            (install / ".env").write_text(f"PROJECT_DIR={project}\nPROJECT_DIR_A={worktree}\n")
            (root / "bin").mkdir()
            docker = root / "bin" / ("docker.cmd" if os.name == "nt" else "docker")
            docker.write_text("@exit /b 0\n" if os.name == "nt" else "#!/bin/sh\nexit 0\n")
            docker.chmod(0o755)
            environment = dict(os.environ, HOME=str(home), USERPROFILE=str(home),
                               PATH=str(docker.parent) + os.pathsep + os.environ["PATH"])
            if language == "powershell":
                script = install / "scripts/cleanup.ps1"
                if os.name != "nt":
                    text, count = re.subn(
                        r"if \(\$PSVersionTable.PSEdition.*?\n}\n", "", script.read_text(), count=1, flags=re.S)
                    self.assertEqual(count, 1)
                    script.write_text(text)
                argv = ["pwsh", "-NoProfile", "-File", str(script), "-RepoDir", str(project)]
                argv += {"no": ["-SkipState"], "yes": ["-Force"], "ask": []}[decision]
            else:
                argv = ["/bin/bash" if sys.platform == "darwin" else "bash", str(install / "scripts/cleanup.sh"), str(project)]
                argv += {"no": ["--no"], "yes": ["--yes"], "ask": []}[decision]
            result = subprocess.run(argv, env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True)
            if decision == "ask":
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            retained = dirty or decision != "yes"
            self.assertEqual(worktree.is_dir(), retained, result.stdout + result.stderr)
            if dirty:
                self.assertEqual((worktree / "untracked.txt").read_text(), "keep local work")
            if decision != "yes":
                self.assertTrue((state / "keep").is_file())

    def test_confirmation_and_dirty_work_preservation(self):
        languages = (["bash"] if os.name != "nt" else []) + (["powershell"] if shutil.which("pwsh") else [])
        self.assertTrue(languages)
        for language in languages:
            for decision in ("ask", "no", "yes"):
                for dirty in (False, True):
                    with self.subTest(language=language, decision=decision, dirty=dirty):
                        self.check_cleanup(language, decision, dirty)


if __name__ == "__main__":
    unittest.main()
