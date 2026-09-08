"""Disposable real-container fixtures shared by smoke tests and benchmarks."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("host_policy", ROOT / "scripts/lib/lifecycle.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class ContainerFixture:
    def __init__(self, mode="isolated", count=2, runtime="claude", image=None, network="bridge"):
        self.mode, self.count, self.runtime, self.network = mode, count, runtime, network
        self.temp = tempfile.TemporaryDirectory(prefix="cd335-")
        self.root = Path(self.temp.name).resolve()
        self.project = "cd335-" + uuid.uuid4().hex[:12]
        self.image = image or "claude-code-base:" + (ROOT / "VERSION").read_text().strip()
        self.spec = json.loads((ROOT / "tui/internal/config/runtimes.json").read_text())["runtimes"][runtime]
        self.services = [self.spec["servicePrefix"] + "-" + policy.account_letter(i) for i in range(1, count + 1)]
        # Keep the developer HOME unchanged. Literal fixture mount overrides,
        # followed by assertions on resolved sources, prevent accidental binds.
        self.host_env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP", "USERPROFILE") or k.startswith("DOCKER_")}
        self.host_env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        uid = os.getuid() if hasattr(os, "getuid") else 1001
        gid = os.getgid() if hasattr(os, "getgid") else 1001
        self.uid, self.gid = (1001 if uid == 0 else uid), (1001 if gid == 0 else gid)
        self.home = self.root / "fixture-home"
        self.source = self.root / "source"
        self.workspaces, self.states = [], []
        self.values = {"HOME": str(self.home), "PROJECT_DIR": str(self.source), "NUM_ACCOUNTS": str(count),
                       "AGENT_RUNTIME": runtime, "ISOLATION_MODE": mode, "ISOLATED_NETWORK_MODE": network,
                       "COMPOSE_PROJECT_NAME": self.project, "GH_AUTH_MODE": "per-account",
                       "GIT_USER_NAME": "Isolation Fixture", "GIT_USER_EMAIL": "fixture@example.invalid",
                       "UID": str(self.uid), "GID": str(self.gid),
                       self.spec["configSourceEnv"]: self.spec["containerConfigMount"] + "/local-config"}

    def run(self, argv, timeout=120):
        return policy.run(argv, self.host_env, self.root, timeout)

    def prepare(self):
        started = time.perf_counter()
        shutil.copytree(ROOT / "scripts", self.root / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
        (self.root / "tui/internal/config").mkdir(parents=True)
        shutil.copy(ROOT / "tui/internal/config/runtimes.json", self.root / "tui/internal/config/runtimes.json")
        shutil.copy(ROOT / "VERSION", self.root / "VERSION")
        self.run(["git", "init", "-q", str(self.source)])
        (self.source / "tracked.txt").write_text("disposable benchmark and isolation fixture\n")
        self.run(["git", "-C", str(self.source), "add", "."])
        self.run(["git", "-C", str(self.source), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"])
        for i in range(1, self.count + 1):
            letter = policy.account_letter(i)
            workspace = self.source if self.mode == "shared" else self.root / ("workspace-" + letter)
            if self.mode == "isolated":
                self.run(["git", "clone", "--no-hardlinks", "--dissociate", str(self.source), str(workspace)])
                policy.independent_clone(workspace)
            elif self.mode == "worktree":
                self.run(["git", "-C", str(self.source), "worktree", "add", "--detach", str(workspace), "HEAD"])
            state = self.home / self.spec["stateDir"] / ("account-" + letter)
            state.mkdir(parents=True, mode=0o700)
            self.workspaces.append(workspace)
            self.states.append(state)
            self.values.update({"ISOLATED_WORKSPACE_" + letter.upper(): str(workspace), "PROJECT_DIR_" + letter.upper(): str(workspace),
                                "GH_USER_" + letter.upper(): "fixture-" + letter, "GH_TOKEN_" + letter.upper(): "placeholder-github-" + letter,
                                self.spec["apiKeyVarPrefix"] + letter.upper(): "placeholder-provider-" + letter})
            (state / "local-config").mkdir()
            (state / "local-config" / "marker").write_text(letter)
            local = state / "local-config"
            (local / "hook.sh").write_text("#!/bin/sh\nprintf hook-ok\n")
            if self.runtime == "claude":
                command = "sh " + self.spec["containerConfigMount"] + "/local-config/hook.sh"
                (local / "settings.json").write_text(json.dumps({"sandbox": {"enabled": False}, "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": command}]}]}, "statusLine": {"type": "command", "command": "printf statusline-ok"}}))
            elif self.runtime == "codex":
                (local / "config.toml").write_text("# disposable fixture\n")
            else:
                (local / "settings.json").write_text("{}\n")
            if hasattr(os, "geteuid") and os.geteuid() == 0:
                for base, dirs, files in os.walk(workspace):
                    for item in [Path(base)] + [Path(base) / n for n in dirs + files]:
                        os.chown(item, self.uid, self.gid)
                for base, dirs, files in os.walk(state):
                    for item in [Path(base)] + [Path(base) / n for n in dirs + files]:
                        os.chown(item, self.uid, self.gid)
        if self.mode == "worktree":
            policy.worktree_metadata(self.values, self.root, create=True)
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            # Linked worktrees use the source's common Git directory too.
            for base, dirs, files in os.walk(self.root):
                for item in [Path(base)] + [Path(base) / name for name in dirs + files]:
                    os.chown(item, self.uid, self.gid)
        self.generate()
        self.setup_seconds = time.perf_counter() - started

    def generate(self):
        self.values["ISOLATED_NETWORK_MODE"] = self.network
        (self.root / ".env").write_text("\n".join(k + "=" + v for k, v in self.values.items()) + "\n")
        self.run(["bash", str(self.root / "scripts/generate-compose.sh")])
        lines = ["services:"]
        for i, service in enumerate(self.services):
            letter = policy.account_letter(i + 1)
            target = "/project" if self.mode == "shared" else ("/workspace-" if self.mode == "isolated" else "/project-") + letter
            mounts = [{"type": "bind", "source": str(self.workspaces[i]), "target": target},
                      {"type": "bind", "source": str(self.states[i]), "target": self.spec["containerConfigMount"]},
                      {"type": "volume", "source": "node_modules_" + letter, "target": target + "/node_modules"}]
            # Worktree metadata is deliberately shared; keep the original
            # absolute gitdir path reachable without mounting its working tree.
            if self.mode == "worktree":
                mounts.append({"type": "bind", "source": str(self.source / ".git"), "target": "/git-common"})
                mounts.append({"type": "bind", "source": str(self.states[i] / ".container-worktree.git"), "target": target + "/.git", "read_only": True})
            # Keep the entrypoint's advisory gh identity lookup on loopback.
            # Local smoke/benchmarks must not depend on an Internet endpoint;
            # --external uses explicit HTTPS/Git URLs in its separate phase.
            lines += ["  " + service + ":", "    image: " + json.dumps(self.image), "    user: " + json.dumps(str(self.uid) + ":" + str(self.gid)),
                      "    environment:", "      GH_HOST: '127.0.0.1:9'", "    volumes: !override"]
            lines += ["      - " + json.dumps(mount) for mount in mounts]
        (self.root / "fixture.yml").write_text("\n".join(lines) + "\n")
        self.cmd = ["docker", "compose", "--project-directory", str(self.root), "--env-file", str(self.root / ".env"), "--project-name", self.project, "-f", str(self.root / "docker-compose.yml")]
        if os.name != "nt" and os.uname().sysname == "Linux":
            self.cmd += ["-f", str(self.root / "docker-compose.linux.yml")]
        if self.mode != "shared":
            self.cmd += ["-f", str(self.root / ("docker-compose." + self.mode + ".yml"))]
        self.cmd += ["-f", str(self.root / "fixture.yml")]
        self.model = json.loads(self.run(self.cmd + ["config", "--format", "json"]))
        for service in self.model["services"].values():
            for mount in service.get("volumes", []):
                if mount["type"] == "bind" and not Path(mount["source"]).resolve().is_relative_to(self.root):
                    raise AssertionError("Fixture would mount a path outside its disposable root.")
        self.manifest = policy.validate_model(self.model, self.values, self.root, host=True)
        self.manifest["budget"] = policy.resolved_budget(self.model, self.manifest)

    def up(self):
        policy.prepare_dependency_volumes(self.model, self.cmd, self.host_env, self.root)
        self.run(self.cmd + ["up", "--detach", "--no-build", "--wait", "--wait-timeout", "90"], timeout=150)

    def execute(self, index, *argv, timeout=60):
        return self.run(self.cmd + ["exec", "-T", self.services[index]] + list(argv), timeout)

    def probe(self, index, *argv, timeout=15):
        return subprocess.run(self.cmd + ["exec", "-T", self.services[index]] + list(argv), env=self.host_env,
                              capture_output=True, text=True, timeout=timeout)

    def close(self):
        try:
            if hasattr(self, "cmd"):
                self.run(self.cmd + ["down", "--volumes", "--remove-orphans"], timeout=180)
                for kind in ("network", "volume"):
                    remaining = self.run(["docker", kind, "ls", "--filter", "label=com.docker.compose.project=" + self.project, "--format", "{{.Name}}"])
                    # Switching to network_mode=none removes the old bridges
                    # from the model, so Compose down cannot see them anymore.
                    # The unique project label identifies only this fixture.
                    for name in remaining.splitlines():
                        if name:
                            self.run(["docker", kind, "rm", name])
                    remaining = self.run(["docker", kind, "ls", "--filter", "label=com.docker.compose.project=" + self.project, "--format", "{{.Name}}"])
                    if remaining.strip():
                        raise AssertionError("Fixture left Docker resources for project " + self.project)
        finally:
            self.temp.cleanup()
