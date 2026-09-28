#!/usr/bin/env python3
"""Execute the real offline npm fixture, including a corrupt-build control."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("npm") and shutil.which("node"), "Node/npm required for the actual package workload")
class PackageWorkloadTest(unittest.TestCase):
    def test_package_install_build_test_and_corruption(self):
        with tempfile.TemporaryDirectory(prefix="issue335-npm-") as directory:
            root = Path(directory)
            source = root / ".isolation-workload"
            shutil.copytree(ROOT / "tests/fixtures/isolation-workload", source,
                            ignore=shutil.ignore_patterns("__pycache__", "node_modules"))
            (root / "node_modules").mkdir()
            for name in ("user.npmrc", "global.npmrc"):
                (root / name).touch()
            env = dict(os.environ, npm_config_cache=str(root / "cache"),
                       NPM_CONFIG_USERCONFIG=str(root / "user.npmrc"),
                       NPM_CONFIG_GLOBALCONFIG=str(root / "global.npmrc"),
                       GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
            subprocess.run(["git", "init", "-q", str(root)], env=env, check=True)
            result = subprocess.run([sys.executable, str(source / "measure.py"), "a"], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=180)
            self.assertEqual(0, result.returncode, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual(5000, data["verified_reads"])
            self.assertGreaterEqual(data["cpu_seconds"], 0)
            (root / ".benchmark-a/42").write_bytes(b"corrupted")
            env["ISSUE335_OUTPUT_ROOT"] = str(root / ".benchmark-a")
            sys.path.insert(0, str(source))
            try:
                from npm_command import npm_command
                command = npm_command() + ["test"]
            finally:
                sys.path.pop(0)
            rejected = subprocess.run(command, cwd=root / "node_modules/.issue335-package", env=env,
                                      capture_output=True, text=True, timeout=60)
            self.assertNotEqual(0, rejected.returncode)
            self.assertNotIn("ISSUE335_WORKLOAD_OK", rejected.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
