#!/usr/bin/env python3
"""Resolve real Compose models without a daemon; no developer .env or mounts."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from container_fixture import ContainerFixture

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("policy", ROOT / "scripts/lib/lifecycle.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def main():
    if not shutil.which("docker"):
        if os.environ.get("GITHUB_ACTIONS"):
            raise SystemExit("Docker CLI is required in CI.")
        print("SKIP: Docker CLI unavailable; executed=0")
        return
    executed = 0
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        shutil.copytree(ROOT / "scripts", root / "scripts")
        (root / "tui/internal/config").mkdir(parents=True)
        shutil.copy(ROOT / "tui/internal/config/runtimes.json", root / "tui/internal/config/runtimes.json")
        shutil.copy(ROOT / "VERSION", root / "VERSION")
        env = {"PATH": os.environ["PATH"], "HOME": str(root / "fixture-home"), "UID": "1234", "GID": "1235"}
        if os.environ.get("DOCKER_CONFIG"):
            env["DOCKER_CONFIG"] = os.environ["DOCKER_CONFIG"]
        base = {"NUM_ACCOUNTS": "2", "PROJECT_DIR": str(root / "shared"),
                "PROJECT_DIR_A": str(root / "worktree-a"), "PROJECT_DIR_B": str(root / "worktree-b"),
                "ISOLATED_WORKSPACE_A": str(root / "clone-a"), "ISOLATED_WORKSPACE_B": str(root / "clone-b"),
                "GH_TOKEN": "placeholder-global-never-in-isolated", "GH_AUTH_MODE": "shared"}
        for runtime in ("claude", "codex", "gemini"):
            config = dict(base, AGENT_RUNTIME=runtime, ISOLATION_MODE="shared")
            (root / ".env").write_text("\n".join(k + "=" + v for k, v in config.items()) + "\n")
            policy.run(["bash", str(root / "scripts/generate-compose.sh")], env, root)
            for mode in ("shared", "worktree", "isolated"):
                for linux in (False, True):
                    current = dict(config, **env, ISOLATION_MODE=mode)
                    cmd = ["docker", "compose", "--project-directory", str(root), "--env-file", str(root / ".env"), "-f", str(root / "docker-compose.yml")]
                    if linux:
                        cmd += ["-f", str(root / "docker-compose.linux.yml")]
                    if mode != "shared":
                        cmd += ["-f", str(root / ("docker-compose." + mode + ".yml"))]
                    model = json.loads(policy.run(cmd + ["config", "--format", "json"], current, root))
                    manifest = policy.validate_model(model, current, root)
                    policy.resolved_budget(model, manifest)
                    assert len(manifest["services"]) == 2
                    assert all(s["mode"] == mode for s in manifest["services"])
                    for service in model["services"].values():
                        git_config = service["environment"].get("GIT_CONFIG_GLOBAL", "")
                        assert git_config and any(git_config.startswith(mount["target"] + "/") and not mount.get("read_only") for mount in service["volumes"]), "Non-root Git global config must be inside writable account state in every mode."
                    assert "placeholder-global" not in json.dumps(manifest)
                    executed += 1
    assert executed == 18
    print("real resolved models: executed=" + str(executed))
    prepared = 0
    for runtime in ("claude", "codex", "gemini"):
        for mode, count in (("shared", 1), ("worktree", 2), ("isolated", 4)):
            fixture = ContainerFixture(mode=mode, count=count, runtime=runtime)
            try:
                fixture.prepare()
                assert len(fixture.model["services"]) == count
                prepared += 1
            finally:
                # prepare only creates host fixtures and resolves Compose; no
                # Docker resources were created and no daemon cleanup is needed.
                fixture.temp.cleanup()
    assert prepared == 9
    print("live-harness fixture preparation: executed=9; live containers=0")


if __name__ == "__main__":
    main()
