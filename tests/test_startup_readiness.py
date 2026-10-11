#!/usr/bin/env python3
"""Readiness regressions: delayed bootstrap, refusal, selection and wrappers."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_lifecycle import policy

ROOT = Path(__file__).resolve().parents[1]


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.clock = 0.0
        self.calls = []
        self.probes = {"claude-a": 0, "claude-b": 0}
        self.ready_after = {"claude-a": 1, "claude-b": 4}
        self.failure = ""

    def sleep(self, duration):
        self.clock += duration

    def docker_run(self, argv, env=None, cwd=None, timeout=60):
        self.calls.append(argv)
        self.assertGreater(timeout, 0)
        if "ps" in argv:
            return "" if self.failure == "missing" else argv[-1]
        service = argv[-1] if argv[1] == "inspect" else argv[2]
        if self.failure == "probe" and argv[1] == "exec":
            raise policy.PolicyError("Command failed with private fixture detail", 23)
        if argv[1] == "inspect":
            status = "exited" if self.failure == "exited" and service == "claude-b" else "running"
            started = "changed" if self.failure == "restarted" and self.probes[service] else "original"
            return json.dumps({"Status": status, "StartedAt": started, "ExitCode": 1})
        self.probes[service] += 1
        if self.failure == "invalid":
            return ""
        return "ready" if self.probes[service] >= self.ready_after[service] else "starting"

    def wait(self, services=("claude-a", "claude-b"), timeout=3):
        with patch.object(policy, "run", self.docker_run), patch.object(policy.time, "monotonic", lambda: self.clock), \
                patch.object(policy.time, "sleep", self.sleep):
            policy.wait_for_entrypoints(["docker", "compose"], services, {}, Path.cwd(), timeout=timeout)

    def test_waits_for_every_service_and_selected_subset(self):
        self.wait()
        self.assertEqual(self.probes, {"claude-a": 1, "claude-b": 4})
        self.assertGreater(self.clock, 0)
        self.probes = {"claude-a": 0, "claude-b": 0}
        self.wait(["claude-b"])
        self.assertEqual(self.probes, {"claude-a": 0, "claude-b": 4})

    def test_refusal_probe_errors_invalid_output_and_restart_fail_closed(self):
        for failure, service in (("exited", "claude-b"), ("probe", "claude-a"),
                                 ("invalid", "claude-a"), ("restarted", "claude-a"),
                                 ("missing", "claude-a")):
            with self.subTest(failure=failure):
                self.failure = failure
                self.probes = {"claude-a": 0, "claude-b": 0}
                with self.assertRaisesRegex(policy.PolicyError, service) as caught:
                    self.wait()
                self.assertNotIn("private fixture detail", str(caught.exception))

    def test_timeout_is_bounded_and_names_pending_service(self):
        self.ready_after["claude-b"] = 999
        with self.assertRaisesRegex(policy.PolicyError, "claude-b.*timed out"):
            self.wait(timeout=0.5)
        self.assertLessEqual(self.clock, 0.5)

    def test_selection_preserves_option_values_and_dependencies(self):
        model = {"services": {"claude-a": {"depends_on": {"claude-b": {}}}, "claude-b": {}}}
        self.assertEqual(policy.startup_services(model, ["--attach", "claude-b"]), ["claude-a", "claude-b"])
        self.assertEqual(policy.startup_services(model, ["--force-recreate", "claude-b"]), ["claude-b"])
        self.assertEqual(policy.startup_services(model, ["--no-deps", "claude-a"]), ["claude-a"])
        self.assertEqual(policy.startup_services(model, ["claude-a"]), ["claude-a", "claude-b"])

    def test_probe_reads_second_argument_and_ignores_init_and_its_own_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp)
            for pid, argv in ((1, b"docker-init\0--\0entrypoint.sh\0sleep\0infinity\0"),
                              (7, b"/bin/bash\0/usr/local/bin/entrypoint.sh\0sleep\0infinity\0"),
                              (42, b"python3\0-c\0entrypoint.sh\0")):
                (proc / str(pid)).mkdir()
                (proc / str(pid) / "cmdline").write_bytes(argv)
            script = policy.ENTRYPOINT_PROBE.replace("'/proc'", repr(tmp))
            self.assertEqual(subprocess.check_output([sys.executable, "-c", script], text=True).strip(), "starting")
            (proc / "7/cmdline").write_bytes(b"sleep\0infinity\0")
            self.assertEqual(subprocess.check_output([sys.executable, "-c", script], text=True).strip(), "ready")


class WrapperReadinessTests(unittest.TestCase):
    def languages(self):
        result = []
        if os.name != "nt":
            result.append("bash")
        if shutil.which("pwsh"):
            result.append("powershell")
        elif os.environ.get("GITHUB_ACTIONS"):
            self.fail("PowerShell is required for readiness parity in CI")
        return result

    def invoke(self, language, arguments, refuse="", remove_wait=False, probe_exit=0):
        with tempfile.TemporaryDirectory(prefix="readiness-wrapper-") as tmp:
            root = Path(tmp)
            shutil.copytree(ROOT / "scripts", root / "scripts")
            shutil.copytree(ROOT / "tui/internal/config", root / "tui/internal/config")
            for name in ("VERSION", "docker-compose.yml", "docker-compose.linux.yml"):
                shutil.copy(ROOT / name, root / name)
            (root / "home").mkdir()
            (root / "project").mkdir()
            (root / "bin").mkdir()
            env = {key: value for key, value in os.environ.items() if key in {
                "PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP", "LOCALAPPDATA"}}
            env.update(HOME=str(root / "home"), USERPROFILE=str(root / "home"),
                       NUM_ACCOUNTS="2", PROJECT_DIR=str(root / "project"),
                       PATH=str(root / "bin") + os.pathsep + env["PATH"],
                       READINESS_FIXTURE=str(root / "state.json"))
            per_account = arguments[:1] == ["gh-auth"] and len(arguments) > 1
            (root / ".env").write_text("ISOLATION_MODE=shared\nGH_AUTH_MODE=" +
                ("per-account" if per_account else "shared") +
                "\nGH_USER_A=fixture-user-a\nGH_USER_B=fixture-user-b\nGH_TOKEN=placeholder-token\n"
                "GH_TOKEN_A=placeholder-token\nGH_TOKEN_B=placeholder-token\n")
            (root / ".env").chmod(0o600)
            state_path = root / "state.json"
            state_path.write_text(json.dumps({"calls": [], "premature": [], "refuse": refuse, "probe_exit": probe_exit}))
            fixture = str(ROOT / "tests/readiness_fixture.py")
            for name in ("docker", "gh"):
                if os.name == "nt":
                    script = root / "bin" / (name + ".cmd")
                    script.write_text(f'@echo off\n"{sys.executable}" "{fixture}" {name} %*\n')
                else:
                    script = root / "bin" / name
                    script.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " +
                                      shlex.quote(fixture) + " " + name + ' "$@"\n')
                    script.chmod(0o755)
            if remove_wait:
                path = root / "scripts/lib/lifecycle.py"
                original = path.read_text()
                target = "            wait_for_entrypoints(cmd, startup_services(model, argv), env, root)"
                self.assertIn(target, original)
                path.write_text(original.replace(target, "            pass  # mutation: readiness removed"))
            if language == "powershell":
                script = root / "scripts/claude-docker.ps1"
                if os.name != "nt":
                    script.write_text(script.read_text().replace("$ErrorActionPreference = 'Stop'",
                                      "$ErrorActionPreference = 'Stop'\n$PSVersionTable.OS = 'Microsoft Windows'", 1))
                command = ["pwsh", "-NoProfile", "-File", str(script)]
            else:
                command = ["bash", str(root / "scripts/claude-docker")]
            result = subprocess.run(command + arguments, env=env, cwd=root, capture_output=True, text=True, timeout=30)
            return result, json.loads(state_path.read_text())

    def test_start_update_auth_and_tui_recreate_wait_for_their_services(self):
        cases = [(["up"], ["claude-a", "claude-b"]),
                 (["up", "--force-recreate", "claude-b"], ["claude-b"]),
                 (["update"], ["claude-a", "claude-b"]),
                 (["gh-auth"], ["claude-a", "claude-b"]),
                 (["gh-auth", "b", "--user", "fixture-user-b"], ["claude-b"]),
                 (["gh-auth", "--all"], ["claude-a", "claude-b"])]
        for language in self.languages():
            for arguments, services in cases:
                with self.subTest(language=language, arguments=arguments):
                    result, state = self.invoke(language, arguments)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(sorted(state["ready"]), services)
                    self.assertEqual(state["premature"], [])
                    self.assertNotIn("placeholder-token", result.stdout + result.stderr)

    def test_refusal_fails_both_wrappers_without_success_banner(self):
        for language in self.languages():
            with self.subTest(language=language):
                result, state = self.invoke(language, ["up"], refuse="claude-b")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("claude-b", result.stdout + result.stderr)
                self.assertNotIn("Containers started.", result.stdout)
                self.assertEqual(state["premature"], [])

    def test_removing_wait_reproduces_premature_operations_in_both_wrappers(self):
        for language in self.languages():
            with self.subTest(language=language):
                result, state = self.invoke(language, ["up"], remove_wait=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(state["premature"], "mutation must expose post-start operations before bootstrap")

    def test_probe_native_exit_code_and_redaction_match_in_both_wrappers(self):
        for language in self.languages():
            with self.subTest(language=language):
                result, state = self.invoke(language, ["up"], probe_exit=23)
                self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
                self.assertNotIn("private-probe-fixture-canary", result.stdout + result.stderr)
                self.assertEqual(state["premature"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
