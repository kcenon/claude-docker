#!/usr/bin/env python3
"""Fault injection at external boundaries; all paths and inputs are disposable."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("lifecycle", ROOT / "scripts/lib/lifecycle.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class LifecycleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "installation"
        self.root.mkdir()
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        (self.root / "tui/internal/config").mkdir(parents=True)
        shutil.copy(ROOT / "tui/internal/config/runtimes.json", self.root / "tui/internal/config/runtimes.json")
        shutil.copy(ROOT / "VERSION", self.root / "VERSION")
        self.fixture_home = Path(self.temp.name) / "fixture-home"
        self.fixture_home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.fixture_home), "NUM_ACCOUNTS": "2",
                    "PROJECT_DIR": str(Path(self.temp.name) / "project"), "ISOLATION_MODE": "shared"}
        for key in ("SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA"):
            if key in os.environ:
                self.env[key] = os.environ[key]
        self.write_env()
        self.running = {"claude-a"}
        self.existing = {"claude-a", "claude-b"}
        self.calls = []
        self.failure = ""
        self.phase = "staging"
        self.resource_set = {"volume": ["fixture_node_modules_a", "fixture_node_modules_b"], "network": ["fixture_default"]}
        self.volume_labels = {}
        self.real_run = policy.run
        self.real_atomic = policy.atomic_file
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, self.env, clear=True).start()

    def write_env(self):
        (self.root / ".env").write_text("\n".join(k + "=" + v for k, v in self.env.items() if k not in ("PATH",)) + "\n")
        (self.root / ".env").chmod(0o600)

    def generate(self):
        language = getattr(self, "language_override", "powershell" if os.name == "nt" else "bash")
        self.language = language
        argv = (["pwsh", "-NoProfile", "-File", str(self.root / "scripts/generate-compose.ps1")]
                if language == "powershell" else ["bash", str(self.root / "scripts/generate-compose.sh")])
        self.real_run(argv, self.env, self.root)

    def snapshot(self):
        return {name: ((self.root / name).read_bytes(), stat.S_IMODE((self.root / name).stat().st_mode)) for name in policy.FILES}

    def test_journal_sync_requires_a_writable_descriptor(self):
        lock = self.root / "journal-test"
        lock.mkdir()
        journal = {"phase": "staged", "files": [".env"]}
        real_fsync = os.fsync
        synced = []
        def sync(fd):
            # Windows rejects fsync on a read-only handle. A zero-byte write
            # exercises that same handle requirement on every test platform.
            os.write(fd, b"")
            real_fsync(fd)
            synced.append(fd)
        with patch.object(policy.os, "fsync", sync):
            policy.journal_write(lock, journal)
        self.assertEqual(1, len(synced))
        self.assertEqual(journal, json.loads((lock / "journal.json").read_text()))

    def model(self, env=None, count=None):
        env = env or self.env
        count = count or int(env["NUM_ACCOUNTS"])
        mode = policy.mode_value(env)
        result = {"name": "fixture", "services": {}, "volumes": {}, "networks": {}}
        for i in range(1, count + 1):
            letter = policy.account_letter(i)
            state = self.fixture_home / ".claude-state" / ("account-" + letter)
            ws = env.get("ISOLATED_WORKSPACE_" + letter.upper(), env["PROJECT_DIR"])
            target = "/workspace-" + letter if mode == "isolated" else "/project"
            service = {"image": "claude-code-base:fixture", "user": "1001:1002", "read_only": True, "init": True, "cap_drop": ["ALL"],
                       "security_opt": ["no-new-privileges:true"],
                       "environment": {"ISOLATION_MODE": mode, "AGENT_RUNTIME": "claude", "NODE_OPTIONS": "--max-old-space-size=3072"},
                       "deploy": {"resources": {"limits": {"cpus": "2", "memory": 4294967296, "pids": 1024},
                                                "reservations": {"cpus": "1", "memory": 2147483648}}},
                       "volumes": [{"type": "bind", "source": ws, "target": target},
                                   {"type": "bind", "source": str(state), "target": "/home/node/.claude"},
                                   {"type": "volume", "source": "node_modules_" + letter, "target": target + "/node_modules"}],
                       "networks": {"isolated_net_" + letter: {}},
                       "tmpfs": [path + ":" + ("mode=1777" if path == "/tmp" else "uid=1001,gid=1002,mode=0700") + ",size=16777216" for path in policy.SCRATCH]}
            result["services"]["claude-" + letter] = service
            result["volumes"]["node_modules_" + letter] = {"name": "fixture_node_modules_" + letter}
            result["networks"]["isolated_net_" + letter] = {"name": "fixture_isolated_net_" + letter, "driver": "bridge"}
        return result

    def fake_run(self, argv, env=None, cwd=None, timeout=60):
        env = env or self.env
        if Path(argv[0]).name != "docker":
            if self.failure == "generator" and any(Path(arg).name in ("generate-compose.sh", "generate-compose.ps1") for arg in argv):
                output = Path(argv[-1])
                (output / "docker-compose.yml").write_text("partial staged output")
                raise policy.PolicyError("Injected generator failure.")
            return self.real_run(argv, env, cwd, timeout)
        self.calls.append(argv)
        if argv[1] == "info":
            return json.dumps({"NCPU": 4, "MemTotal": 8589934592})
        if argv[1] in ("volume", "network"):
            if argv[2] == "ls":
                return "\n".join(self.resource_set[argv[1]])
            if argv[2] == "create":
                self.resource_set[argv[1]].append(argv[-1])
                self.volume_labels[argv[-1]] = next(item.split("=", 1)[1] for item in argv if item.startswith("com.claude-docker.initializer="))
                return argv[-1]
            if argv[2] == "inspect":
                return self.volume_labels[argv[-1]]
            self.resource_set[argv[1]].remove(argv[-1])
            return ""
        if argv[1] == "image":
            return "fixture-image-id"
        if argv[1] == "run":
            self.assertIn("--cap-drop", argv)
            self.assertEqual("ALL", argv[argv.index("--cap-drop") + 1])
            self.assertEqual("none", argv[argv.index("--network") + 1])
            self.assertNotIn("--env", argv)
            if self.failure == "initializer":
                raise policy.PolicyError("Injected cache initialization failure.", 23)
            return ""
        if argv[1] == "rm":
            return ""
        if "config" in argv:
            if self.failure == "config" and "staged" in argv[argv.index("--env-file") + 1]:
                return "invalid JSON with placeholder-secret"
            base = Path(argv[argv.index("-f") + 1])
            count = sum(1 for line in base.read_text().splitlines() if line.startswith("  claude-") and line.endswith(":"))
            return json.dumps(self.model(env, count))
        if "ps" in argv:
            return "\n".join(sorted(self.running if "--status" in argv else self.existing))
        if "up" in argv:
            services = {x for x in argv[argv.index("up") + 1:] if x.startswith("claude-")}
            self.existing |= services
            self.running |= services
            self.resource_set["volume"] += ["fixture_node_modules_c"] if "claude-c" in services and "fixture_node_modules_c" not in self.resource_set["volume"] else []
            if self.failure == "signal" and self.phase == "staging":
                self.phase = "recovering"
                os.kill(os.getpid(), signal.SIGTERM)
            if self.failure == "startup-data" and self.phase == "staging":
                (self.fixture_home / ".claude-state/account-c/user-data").write_text("unrelated runtime write")
            if self.failure in ("startup", "startup-data", "rollback") and self.phase == "staging":
                self.phase = "recovering"
                raise policy.PolicyError("Injected startup failure after partial creation.", 17)
            if self.failure == "rollback":
                raise policy.PolicyError("Injected daemon outage during recovery.")
            return ""
        if "rm" in argv:
            services = {x for x in argv[argv.index("rm") + 1:] if x.startswith("claude-")}
            self.existing -= services
            self.running -= services
            return ""
        if "create" in argv:
            self.existing |= {x for x in argv[argv.index("create") + 1:] if x.startswith("claude-")}
            return ""
        if "stop" in argv:
            self.running -= {x for x in argv[argv.index("stop") + 1:] if x.startswith("claude-")}
            return ""
        raise AssertionError("Unmodeled daemon operation: " + repr(argv))

    def scale(self, count):
        with patch.object(policy, "run", self.fake_run), contextlib.redirect_stdout(io.StringIO()) as output:
            try:
                policy.scale(self.root, count, self.language)
            finally:
                self.output = output.getvalue()

    def test_transaction_success_and_stopped_service(self):
        self.generate()
        (self.fixture_home / ".claude-state/account-c").mkdir(parents=True)
        keep = self.fixture_home / ".claude-state/account-c/user-data"
        keep.write_text("existing account data")
        self.scale(3)
        self.assertEqual({"claude-a", "claude-c"}, self.running)
        self.assertEqual("existing account data", keep.read_text())
        self.assertEqual("3", policy.read_env(self.root / ".env")["NUM_ACCOUNTS"])
        self.assertFalse((self.root / ".claude-docker-lifecycle").exists())
        self.scale(1)
        self.assertEqual({"claude-a"}, self.running)
        self.assertTrue(keep.is_file())
        self.assertFalse(any("down" in call for call in self.calls))

    def test_normal_up_creates_state_before_docker_creates_binds(self):
        self.generate()
        with patch.object(sys, "argv", ["lifecycle.py", "--root", str(self.root), "up"]), patch.object(policy, "run", self.fake_run), contextlib.redirect_stdout(io.StringIO()):
            policy.main()
        for letter in ("a", "b"):
            state = self.fixture_home / ".claude-state" / ("account-" + letter)
            self.assertTrue(state.is_dir())
            if os.name != "nt":
                self.assertEqual(os.getuid(), state.stat().st_uid)
                self.assertEqual(0o700, stat.S_IMODE(state.stat().st_mode))

    def test_failures_restore_files_modes_and_running_set(self):
        self.generate()
        before = self.snapshot()
        for failure in ("generator", "config", "startup", "publication"):
            with self.subTest(failure=failure):
                self.failure = failure
                self.phase = "staging"
                published = [False]
                def publish(source, destination, mode=None):
                    if failure == "publication" and destination.name == "docker-compose.yml" and not published[0]:
                        published[0] = True
                        raise policy.PolicyError("Injected publication failure.")
                    return self.real_atomic(source, destination, mode)
                with patch.object(policy, "atomic_file", publish), self.assertRaises(policy.PolicyError):
                    self.scale(3)
                self.assertEqual(before, self.snapshot())
                self.assertEqual({"claude-a"}, self.running)
                self.assertEqual({"claude-a", "claude-b"}, self.existing)
                self.assertNotIn("Scaled to", self.output)
                self.assertFalse((self.root / ".claude-docker-lifecycle").exists())
                self.assertFalse((self.fixture_home / ".claude-state/account-c").exists())

    def test_failed_compensation_retains_protected_journal(self):
        self.generate()
        before = self.snapshot()
        self.failure = "rollback"
        with contextlib.redirect_stderr(io.StringIO()) as errors, self.assertRaises(policy.PolicyError):
            self.scale(3)
        self.assertEqual(before, self.snapshot())
        journal = self.root / ".claude-docker-lifecycle/journal.json"
        self.assertTrue(journal.is_file())
        if os.name != "nt":
            self.assertEqual(0o600, stat.S_IMODE(journal.stat().st_mode))
        self.assertIn("Recovery incomplete", errors.getvalue())
        self.assertNotIn("Scaled to", self.output)

    def test_explicit_count_wins_and_no_running_is_not_started(self):
        self.generate()
        self.running.clear()
        os.environ["NUM_ACCOUNTS"] = "999"
        self.scale(1)
        self.assertEqual("1", policy.read_env(self.root / ".env")["NUM_ACCOUNTS"])
        self.assertFalse(self.running)
        self.assertEqual({"claude-a"}, self.existing)
        self.assertFalse(any("up" in call for call in self.calls))
        self.scale(1)
        self.assertIn("Scaled to 1", self.output)

    def test_auth_and_budget_rejected_before_publish(self):
        self.generate()
        for key, value in (("GH_AUTH_MODE", "per-account"), ("CONTAINER_MEM_LIMIT", "512M"), ("ISOLATED_PIDS_LIMIT", "0"), ("ISOLATED_TMP_MB", "-1")):
            with self.subTest(key=key), patch.dict(os.environ, {key: value}):
                before = self.snapshot()
                with self.assertRaises(policy.PolicyError):
                    self.scale(1)
                self.assertEqual(before, self.snapshot())
                self.assertNotIn("Scaled to", self.output)

    def test_model_boundary_mutations(self):
        self.env.update(ISOLATION_MODE="isolated", ISOLATED_WORKSPACE_A=str(self.root / "a"), ISOLATED_WORKSPACE_B=str(self.root / "b"))
        original = self.model()
        self.assertEqual(2, len(policy.validate_model(original, self.env, self.root)["services"]))
        mutations = [
            lambda m: m["services"]["claude-a"].update(user="0:0"),
            lambda m: m["services"]["claude-a"].update(privileged=True),
            lambda m: m["services"]["claude-a"].update(cap_add=["SYS_ADMIN"]),
            lambda m: m["services"]["claude-a"].update(security_opt=["seccomp:unconfined"]),
            lambda m: m["services"]["claude-a"].update(networks={"isolated_net_b": {}}),
            lambda m: m["services"]["claude-a"]["volumes"][0].update(source=self.env["ISOLATED_WORKSPACE_B"]),
            lambda m: m["services"]["claude-a"]["volumes"][1].update(source=str(self.fixture_home)),
            lambda m: m["services"]["claude-a"]["volumes"][2].update(source="node_modules_b"),
            lambda m: m["services"]["claude-a"]["environment"].update(GH_TOKEN="placeholder-global"),
            lambda m: m["services"]["claude-a"]["environment"].update(CLAUDE_CONFIG_SOURCE="/shared/config"),
            lambda m: m["services"]["claude-a"]["environment"].update(CLAUDE_CONFIG_SOURCE="/home/node/.claude/../../other"),
            lambda m: m["volumes"]["node_modules_a"].update(driver="unapproved-plugin"),
            lambda m: m["networks"]["isolated_net_a"].update(name="other-project-bridge"),
            lambda m: m["services"]["claude-a"].update(tmpfs=["/tmp:mode=1777"]),
            lambda m: m["services"]["claude-a"].update(ports=[{"target": 1234, "published": "1234"}]),
            lambda m: m["services"]["claude-a"].update(volumes_from=["claude-b"]),
            lambda m: m["services"]["claude-a"].update(secrets=["sibling"]),
            lambda m: m["services"]["claude-a"].update(security_opt=["no-new-privileges:true", "no-new-privileges:false"]),
        ]
        for mutation in mutations:
            model = copy.deepcopy(original)
            mutation(model)
            with self.assertRaises(policy.PolicyError):
                policy.validate_model(model, self.env, self.root)
        model = copy.deepcopy(original)
        model["services"]["claude-a"]["environment"]["ANTHROPIC_API_KEY"] = "placeholder-account-a"
        manifest = policy.validate_model(model, dict(self.env, CLAUDE_API_KEY_A="placeholder-account-a"), self.root)
        self.assertNotIn("placeholder-account-a", json.dumps(manifest))
        self.assertIn("ANTHROPIC_API_KEY", json.dumps(manifest))
        with self.assertRaises(policy.PolicyError):
            policy.validate_model(original, dict(self.env, CLAUDE_API_KEY_A="placeholder-new-mapping"), self.root)

    def test_symlink_nested_and_windows_aliases(self):
        root = Path(self.temp.name)
        target = root / "real"
        target.mkdir()
        alias = root / "alias"
        try:
            alias.symlink_to(target, target_is_directory=True)
        except OSError:
            self.skipTest("Host does not permit symlink creation")
        env = dict(self.env, ISOLATION_MODE="isolated", ISOLATED_WORKSPACE_A=str(target), ISOLATED_WORKSPACE_B=str(alias))
        policy.validate_inputs(env, self.root, host=False)
        with self.assertRaises(policy.PolicyError):
            policy.validate_inputs(env, self.root, host=True)
        env["ISOLATED_WORKSPACE_B"] = str(target / "nested")
        with self.assertRaises(policy.PolicyError):
            policy.validate_inputs(env, self.root)
        env.update(ISOLATED_WORKSPACE_A="C:/Projects/Account", ISOLATED_WORKSPACE_B="c:\\projects\\account\\.")
        with self.assertRaises(policy.PolicyError):
            policy.validate_inputs(env, self.root)

    def test_budget_resolved_values_are_authoritative(self):
        model = self.model()
        service = model["services"]["claude-a"]
        service["deploy"]["resources"]["limits"]["cpus"] = "3"
        result = policy.resolved_budget(model, policy.describe(model))
        self.assertEqual(5, result["total"]["cpu_limit"])
        self.assertEqual(0, result["total"]["scratch_bytes"])

    def test_recovery_retries_failed_compensation(self):
        self.generate()
        self.failure = "rollback"
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(policy.PolicyError) as failure:
            self.scale(3)
        self.assertEqual(17, failure.exception.exit_code)
        with self.assertRaisesRegex(policy.PolicyError, "still running"):
            policy.recover(self.root)
        self.failure = ""
        with patch.object(policy, "process_alive", return_value=False), patch.object(policy, "run", self.fake_run), contextlib.redirect_stdout(io.StringIO()):
            policy.recover(self.root)
        self.assertFalse((self.root / ".claude-docker-lifecycle").exists())
        self.assertEqual({"claude-a"}, self.running)
        self.assertEqual({"claude-a", "claude-b"}, self.existing)

    def test_fresh_cache_initialization_failure_removes_only_owned_volume(self):
        self.generate()
        before = self.snapshot()
        self.failure = "initializer"
        with self.assertRaises(policy.PolicyError) as failure:
            self.scale(3)
        self.assertEqual(23, failure.exception.exit_code)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(["fixture_node_modules_a", "fixture_node_modules_b"], self.resource_set["volume"])
        self.assertNotIn("Scaled to", self.output)

    @unittest.skipIf(os.name == "nt", "POSIX signals; native Windows interruption remains a separate platform check")
    def test_signal_interrupt_compensates_before_releasing_lock(self):
        self.generate()
        before = self.snapshot()
        self.failure = "signal"
        with self.assertRaisesRegex(policy.PolicyError, "interrupted by signal"):
            self.scale(3)
        self.assertEqual(before, self.snapshot())
        self.assertEqual({"claude-a"}, self.running)
        self.assertFalse((self.root / ".claude-docker-lifecycle").exists())

    def test_rollback_retains_unrelated_writes_in_new_state(self):
        self.generate()
        before = self.snapshot()
        self.failure = "startup-data"
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(policy.PolicyError):
            self.scale(3)
        self.assertEqual(before, self.snapshot())
        self.assertEqual("unrelated runtime write", (self.fixture_home / ".claude-state/account-c/user-data").read_text())

    def test_alternate_environment_file_selects_every_policy(self):
        self.generate()
        alternative = self.root / "candidate.env"
        alternative.write_text("NUM_ACCOUNTS=1\nAGENT_RUNTIME=codex\nISOLATION_MODE=isolated\nISOLATED_WORKSPACE_A=/fixture/alternate\n")
        output = self.root / "candidate-output"
        output.mkdir()
        env = {key: value for key, value in self.env.items() if key not in ("NUM_ACCOUNTS", "ISOLATION_MODE", "AGENT_RUNTIME")}
        argv = (["pwsh", "-NoProfile", "-File", str(self.root / "scripts/generate-compose.ps1"), "-EnvFile", str(alternative), "-OutputDir", str(output)]
                if self.language == "powershell" else ["bash", str(self.root / "scripts/generate-compose.sh"), "--env-file", str(alternative), "--output-dir", str(output)])
        before = self.snapshot()
        self.real_run(argv, env, self.root)
        self.assertEqual(before, self.snapshot())
        generated = (output / "docker-compose.isolated.yml").read_text()
        self.assertIn("  codex-a:", generated)
        self.assertNotIn("  codex-b:", generated)
        self.assertIn("ISOLATION_MODE=isolated", generated)

    def test_setup_preview_and_all_destinations_preflight(self):
        source = Path(self.env["PROJECT_DIR"])
        self.real_run(["git", "init", "-q", str(source)], self.env)
        (source / "tracked").write_text("fixture\n")
        self.real_run(["git", "-C", str(source), "add", "tracked"], self.env)
        self.real_run(["git", "-C", str(source), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], self.env)
        (source / "untracked-secret").write_text("placeholder; must not be copied")
        before = sorted(str(path.relative_to(Path(self.temp.name))) for path in Path(self.temp.name).rglob("*"))
        with patch.object(policy, "capacity", return_value={"status": "unknown"}), contextlib.redirect_stdout(io.StringIO()) as preview:
            policy.setup(self.root, self.env, source, "2", True)
        plan = json.loads(preview.getvalue())
        self.assertEqual(2, len(plan["accounts"]))
        self.assertEqual(before, sorted(str(path.relative_to(Path(self.temp.name))) for path in Path(self.temp.name).rglob("*")))
        unsafe = Path(str(source) + "-isolated-b")
        unsafe.mkdir()
        (unsafe / "keep").write_text("existing user data")
        with patch.object(policy, "capacity", return_value={"status": "unknown"}), self.assertRaises(policy.PolicyError):
            policy.setup(self.root, self.env, source, "2", False)
        self.assertFalse(Path(str(source) + "-isolated-a").exists())
        self.assertEqual("existing user data", (unsafe / "keep").read_text())
        with patch.object(policy, "capacity", return_value={"status": "unknown"}), contextlib.redirect_stdout(io.StringIO()):
            policy.setup(self.root, self.env, source, "1", False)
        clone = Path(plan["accounts"][0]["workspace"])
        policy.independent_clone(clone)
        self.assertFalse((clone / "untracked-secret").exists())
        # A caller's hook environment cannot redirect the independence proof.
        with patch.dict(os.environ, {"GIT_DIR": str(unsafe)}):
            policy.independent_clone(clone)

    @unittest.skipUnless(os.name == "nt", "Native Windows ACL validation requires Windows")
    def test_windows_file_acl_survives_publication_and_rollback(self):
        self.windows_acl_roundtrip(protected=False)

    @unittest.skipUnless(os.name == "nt", "Native Windows ACL validation requires Windows")
    def test_windows_protected_file_acl_survives_publication_and_rollback(self):
        self.windows_acl_roundtrip(protected=True)

    @unittest.skipUnless(os.name == "nt", "Native Windows ACL validation requires Windows")
    def test_windows_automatic_acl_survives_publication_and_rollback(self):
        self.windows_acl_roundtrip(protected=False, auto_inherit=True)

    def windows_acl_roundtrip(self, protected, auto_inherit=False):
        self.generate()
        if protected:
            policy.protect(self.root / ".env")
        elif auto_inherit:
            self.real_run(["icacls", str(self.root / ".env"), "/inheritance:e"])
        helper = self.root / "read-acl.ps1"
        helper.write_text("param([string]$TargetPath)\n(Get-Acl -LiteralPath $TargetPath).Sddl\n")
        def acl():
            argv = ["pwsh", "-NoProfile", "-File", str(helper), "-TargetPath", str(self.root / ".env")]
            return self.real_run(argv, self.env, self.root).strip()
        before = acl()
        self.scale(3)
        self.assertEqual(before, acl())
        self.failure = "startup"
        self.phase = "staging"
        with self.assertRaises(policy.PolicyError):
            self.scale(4)
        self.assertEqual(before, acl())


class PowerShellLifecycleTest(LifecycleTest):
    language_override = "powershell"

    def setUp(self):
        if not shutil.which("pwsh"):
            self.skipTest("PowerShell 7 is unavailable")
        super().setUp()
        if os.name != "nt":
            # Only disposable copies receive the platform simulation. Child
            # generators need it too; no production guard is disabled.
            for name in ("generate-compose.ps1", "claude-docker.ps1", "setup-isolated.ps1"):
                path = self.root / "scripts" / name
                script = path.read_text().replace("$ErrorActionPreference = 'Stop'", "$ErrorActionPreference = 'Stop'\n$PSVersionTable.OS = 'Microsoft Windows'", 1)
                path.write_text(script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
