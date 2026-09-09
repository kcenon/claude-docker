#!/usr/bin/env python3
"""Missing backend enforcement and mismatched platform claims must fail."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from container_fixture import policy
from workflow_environment import backend_profile, verify_environment
from workflow_support import WorkflowFailure


class EnvironmentTest(unittest.TestCase):
    def test_native_profiles_use_both_host_and_daemon(self):
        for host, release, desktop, rootless, expected in (
                ("Linux", "6.1", False, False, "linux-engine"),
                ("Linux", "6.1", False, True, "linux-rootless"),
                ("Darwin", "25", True, False, "macos-desktop"),
                ("Windows", "11", True, False, "windows-desktop"),
                ("Linux", "6.1-microsoft-standard-WSL2", True, False, "wsl2-desktop")):
            provenance = {"daemon": {"OperatingSystem": "Docker Desktop" if desktop else "Ubuntu",
                                     "SecurityOptions": ["name=rootless"] if rootless else []}}
            with patch("workflow_environment.platform.system", return_value=host), patch(
                    "workflow_environment.platform.release", return_value=release):
                self.assertEqual(expected, backend_profile(provenance))
        with patch("workflow_environment.platform.system", return_value="Darwin"):
            with self.assertRaises(WorkflowFailure):
                backend_profile({"daemon": {"OperatingSystem": "Ubuntu", "SecurityOptions": []}})

    def fixture(self, override=None):
        responses = {"memory": "4294967296", "pids": "1024", "cpu": "200000 100000",
                     "status": "NoNewPrivs:\t1\nSeccomp:\t2\nCapEff:\t0\nCapBnd:\t0",
                     "uid": "1001", "version": "1.2.3"}
        responses.update(override or {})
        mounts = ["root / overlay ro 0 0"] + ["tmpfs %s tmpfs rw,size=%sm 0 0" % (path, policy.DEFAULTS[key])
                                               for path, key in policy.SCRATCH.items()]
        def execute(index, *args):
            command = " ".join(args)
            for token, key in (("memory.max", "memory"), ("pids.max", "pids"), ("cpu.max", "cpu"),
                               ("/proc/self/status", "status"), ("id -u", "uid"), ("--version", "version")):
                if token in command:
                    return responses[key]
            if command == "cat /proc/mounts":
                return "\n".join(mounts)
            raise AssertionError("unexpected test probe")
        return SimpleNamespace(services=["runtime-a", "runtime-b"], uid=1001, values={}, language="bash",
                               spec={"binary": "runtime"}, execute=execute, run=lambda args: "bash fixture",
                               model={"services": {name: {"deploy": {"resources": {"limits": {
                                   "memory": "4g", "cpus": "2"}}}, "pids_limit": 1024} for name in ("runtime-a", "runtime-b")}})

    def test_enforced_limits_and_security_are_checked_for_both_accounts(self):
        with patch("workflow_environment.backend_profile", return_value="linux-engine"):
            result = verify_environment(self.fixture(), {})
            self.assertEqual(2, len(result["effective_limits"]))
            for override in ({"memory": "0"}, {"pids": "4096"}, {"cpu": "-1 100000"},
                             {"cpu": "max 100000"}, {"uid": "0"}, {"status": "NoNewPrivs:0\nSeccomp:0\nCapEff:0\nCapBnd:0"}):
                with self.assertRaises((WorkflowFailure, ValueError)):
                    verify_environment(self.fixture(override), {})
            with self.assertRaisesRegex(WorkflowFailure, "^host_backend_profile_mismatch$"):
                verify_environment(self.fixture(), {}, "linux-rootless")

    def test_compose_deploy_pid_limits_are_compared_with_the_cgroup(self):
        fixture = self.fixture()
        for service in fixture.model["services"].values():
            service["deploy"]["resources"]["limits"]["pids"] = service.pop("pids_limit")
        with patch("workflow_environment.backend_profile", return_value="linux-engine"):
            self.assertEqual(2, len(verify_environment(fixture, {})["effective_limits"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
