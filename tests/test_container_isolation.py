#!/usr/bin/env python3
"""Live boundary/readiness checks. No provider authentication is claimed."""
import argparse
import json
import os
import time
from container_fixture import ContainerFixture, policy


def boundaries(fixture):
    # Look in the actual mount targets, including equal paths such as runtime
    # state, rather than assuming the sibling uses a guessed absent pathname.
    for index, service in enumerate(fixture.services):
        own, other = policy.account_letter(index + 1), policy.account_letter(2 - index)
        mounts = fixture.model["services"][service]["volumes"]
        for mount in mounts:
            target = mount["target"]
            fixture.execute(index, "test", "-f", target + "/.boundary-" + own)
            if fixture.probe(index, "test", "-e", target + "/.boundary-" + other).returncode == 0:
                raise AssertionError("Sibling marker is visible through a resolved mount.")
        sibling_mounts = fixture.model["services"][fixture.services[1 - index]]["volumes"]
        own_targets = {mount["target"] for mount in mounts}
        for mount in sibling_mounts:
            if mount["target"] in own_targets:
                continue  # Equal mount targets were checked with both markers.
            assert fixture.probe(index, "cat", mount["target"] + "/.boundary-" + other).returncode != 0
            assert fixture.probe(index, "touch", mount["target"] + "/.sibling-write-probe").returncode != 0


def verify(fixture, external):
    fixture.prepare()
    fixture.up()
    executed = 0
    config = fixture.spec["containerConfigMount"]
    for index, service in enumerate(fixture.services):
        letter = policy.account_letter(index + 1)
        workspace = fixture.model["services"][service]["working_dir"]
        for mount in fixture.model["services"][service]["volumes"]:
            fixture.execute(index, "sh", "-c", 'printf "%s" "$1" > "$2/.boundary-$1"', "fixture", letter, mount["target"])
        fixture.execute(index, "sh", "-c", 'test "$(cat "$1/local-config/marker")" = "$2"', "fixture", config, letter)
        fixture.execute(index, "git", "config", "--global", "fixture.account", letter)
        assert fixture.execute(index, "git", "config", "--global", "--get", "fixture.account").strip() == letter
        fixture.execute(index, "gh", "auth", "setup-git", "--hostname", "github.com")
        fixture.execute(index, "git", "-C", workspace, "add", "tracked.txt")
        fixture.execute(index, "git", "-C", workspace, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "disposable smoke commit")
        fixture.execute(index, "sh", "-c", 'mkdir -p /home/node/.cache/probe /home/node/.npm/probe /home/node/.agents/probe; touch /home/node/.cache/probe/write /home/node/.npm/probe/write /home/node/.agents/probe/write')
        fixture.execute(index, fixture.spec["binary"], "--version")
        # Execute the commands read from the bootstrapped account settings.
        if fixture.runtime == "claude":
            settings = json.loads(fixture.execute(index, "cat", config + "/settings.json"))
            assert fixture.execute(index, "sh", "-c", settings["hooks"]["SessionStart"][0]["hooks"][0]["command"]) == "hook-ok"
            assert fixture.execute(index, "sh", "-c", settings["statusLine"]["command"]) == "statusline-ok"
        fixture.execute(index, "sh", "-c", 'test "$GH_TOKEN" = "placeholder-github-$1" && test "$(printenv "$2")" = "placeholder-provider-$1"', "fixture", letter, fixture.spec["sdkApiKeyVar"])
        status = fixture.execute(index, "cat", "/proc/self/status")
        fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
        assert int(fields["NoNewPrivs"].strip()) == 1
        assert int(fields["CapEff"].strip(), 16) == 0 and int(fields["CapBnd"].strip(), 16) == 0
        assert int(fields["Seccomp"].strip()) == 2
        assert int(fixture.execute(index, "id", "-u")) == fixture.uid != 0
        pid_cap = fixture.execute(index, "sh", "-c", 'cat /sys/fs/cgroup/pids.max 2>/dev/null || cat /sys/fs/cgroup/pids/pids.max')
        assert int(pid_cap) == 1024
        root_write = fixture.probe(index, "touch", "/home/node/.root-write-probe")
        assert root_write.returncode != 0 and "read-only" in root_write.stderr.lower()
        mount_info = fixture.execute(index, "cat", "/proc/mounts")
        for path, key in policy.SCRATCH.items():
            row = next(line for line in mount_info.splitlines() if line.split()[1] == path)
            assert "tmpfs" in row and "size=" in row
            mounted_size = next(option[5:] for option in row.split()[3].split(",") if option.startswith("size="))
            assert policy.size_bytes(mounted_size) == int(policy.DEFAULTS[key]) * 1048576
            if path != "/tmp":
                assert fixture.execute(index, "stat", "-c", "%u:%g", path).strip() == str(fixture.uid) + ":" + str(fixture.gid)
            actual = fixture.execute(index, "stat", "-c", "%a", path).strip()
            assert actual == ("1777" if path == "/tmp" else "700")
        executed += 10
    boundaries(fixture)
    executed += 6
    # Positive mutation control: a leaked marker must fail the same check.
    target = fixture.model["services"][fixture.services[0]]["working_dir"]
    fixture.execute(0, "touch", target + "/.boundary-b")
    try:
        boundaries(fixture)
    except AssertionError:
        pass
    else:
        raise AssertionError("Filesystem boundary checker accepted its leak mutation.")
    finally:
        fixture.execute(0, "rm", target + "/.boundary-b")
    executed += 1
    listener = "import http.server; http.server.HTTPServer(('0.0.0.0',18765), http.server.BaseHTTPRequestHandler).serve_forever()"
    fixture.run(fixture.cmd + ["exec", "-T", "--detach", fixture.services[1], "python3", "-c", listener])
    for _ in range(30):
        if fixture.probe(1, "curl", "--max-time", "1", "-s", "http://127.0.0.1:18765").returncode == 0:
            break
        time.sleep(0.1)
    else:
        raise AssertionError("Network listener positive control did not start.")
    cid_b = fixture.run(fixture.cmd + ["ps", "-q", fixture.services[1]]).strip()
    inspected = json.loads(fixture.run(["docker", "inspect", cid_b]))[0]
    network = next(iter(inspected["NetworkSettings"]["Networks"].values()))
    ip = network["IPAddress"]
    for address in (fixture.services[1], ip):
        assert fixture.probe(0, "curl", "--max-time", "2", "-s", "http://" + address + ":18765").returncode != 0
    # A reachable listener on B's bridge proves direct-IP failure in A is
    # isolation, not a dead endpoint. Connect A temporarily as a mutation.
    cid_a = fixture.run(fixture.cmd + ["ps", "-q", fixture.services[0]]).strip()
    bridge = next(iter(inspected["NetworkSettings"]["Networks"]))
    fixture.run(["docker", "network", "connect", bridge, cid_a])
    try:
        assert fixture.probe(0, "curl", "--max-time", "2", "-s", "http://" + ip + ":18765").returncode == 0
    finally:
        fixture.run(["docker", "network", "disconnect", bridge, cid_a])
    executed += 4
    if external:
        # DNS/TLS/HTTP and public Git transport do not prove provider auth.
        endpoint = {"claude": "https://api.anthropic.com", "codex": "https://api.openai.com", "gemini": "https://generativelanguage.googleapis.com"}[fixture.runtime]
        code = fixture.execute(0, "curl", "--max-time", "15", "--silent", "--show-error", "--output", "/dev/null", "--write-out", "%{http_code}", endpoint)
        assert 100 <= int(code) < 600
        fixture.execute(0, "curl", "--max-time", "15", "--silent", "--show-error", "--output", "/dev/null", "https://api.github.com")
        fixture.execute(0, "git", "-c", "credential.helper=", "ls-remote", "https://github.com/kcenon/claude-docker.git", "HEAD", timeout=30)
        executed += 3
    fixture.run(fixture.cmd + ["up", "--detach", "--force-recreate", "--no-build", "--wait", "--wait-timeout", "90"], timeout=150)
    boundaries(fixture)
    executed += 1
    fixture.network = "none"
    fixture.generate()
    fixture.up()
    assert fixture.execute(0, "sh", "-c", "ls /sys/class/net").strip() == "lo"
    assert fixture.probe(0, "curl", "--max-time", "2", "-s", "http://1.1.1.1").returncode != 0
    executed += 2
    if fixture.runtime == "claude":
        # A conflicting requested policy must refuse *before* command exec,
        # under the actual container user/profile, even with degraded hooks
        # explicitly allowed. No weaker Docker profile is used for this test.
        local = fixture.states[0] / "local-config" / "settings.json"
        local.write_text(json.dumps({"sandbox": {"enabled": True, "enableWeakerNestedSandbox": True}}))
        refused = fixture.probe(0, "env", "CLAUDE_ALLOW_DEGRADED_SETTINGS=1", "entrypoint.sh", "sh", "-c", "touch /tmp/sandbox-command-ran", timeout=45)
        assert refused.returncode != 0
        assert "requested isolated sandbox conflicts" in refused.stderr
        assert fixture.probe(0, "test", "-e", "/tmp/sandbox-command-ran").returncode != 0
        executed += 1
    return executed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image")
    parser.add_argument("--external", action="store_true")
    parser.add_argument("--runtime", choices=("claude", "codex", "gemini", "all"), default="all")
    args = parser.parse_args()
    policy.run(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=10)
    executed = 0
    for runtime in ("claude", "codex", "gemini") if args.runtime == "all" else (args.runtime,):
        fixture = ContainerFixture(runtime=runtime, image=args.image)
        try:
            executed += verify(fixture, args.external)
        finally:
            fixture.close()
    assert executed > 0
    print("live isolation: executed=" + str(executed) + "; authenticated provider/push checks not requested")


if __name__ == "__main__":
    main()
