#!/usr/bin/env python3
"""Host-side isolation policy. Stdlib only; never print a resolved environment.

Both shell frontends invoke this module so filesystem aliases, resource policy,
and compensation have one implementation on Windows, macOS, and Linux.
"""
import argparse
import contextlib
import json
import math
import ntpath
import os
from pathlib import Path
import posixpath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid


class PolicyError(Exception):
    def __init__(self, message, exit_code=1):
        super().__init__(message)
        self.exit_code = exit_code if 0 < exit_code < 256 else 1


FILES = (".env", "docker-compose.yml", "docker-compose.linux.yml",
         "docker-compose.worktree.yml", "docker-compose.isolated.yml")
DEFAULTS = {"CONTAINER_CPU_LIMIT": "2", "CONTAINER_CPU_RESERVATION": "1",
            "CONTAINER_MEM_LIMIT": "4G", "CONTAINER_MEM_RESERVATION": "2G",
            "ISOLATED_PIDS_LIMIT": "1024", "ISOLATED_TMP_MB": "256",
            "ISOLATED_CONFIG_MB": "16", "ISOLATED_CACHE_MB": "128",
            "ISOLATED_NPM_MB": "256", "ISOLATED_AGENTS_MB": "16"}
SCRATCH = {"/tmp": "ISOLATED_TMP_MB", "/home/node/.config": "ISOLATED_CONFIG_MB",
           "/home/node/.cache": "ISOLATED_CACHE_MB", "/home/node/.npm": "ISOLATED_NPM_MB",
           "/home/node/.agents": "ISOLATED_AGENTS_MB"}


def read_env(path):
    """The parse_env.sh value rule, including greedy quotes and last key wins."""
    values = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.rstrip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", key):
            continue
        match = re.fullmatch(r'''(["'])(.*)\1(?:\s+\#.*)?''', value)
        values[key] = match[2] if match else re.split(r"\s+#", value, 1)[0].rstrip()
    return values


def environment(root, env_file=None):
    values = read_env(Path(env_file) if env_file else root / ".env")
    values.update({k: v for k, v in os.environ.items() if v})
    return values


def account_letter(index):
    if not 1 <= index <= 702:
        raise PolicyError("Account count must be between 1 and 702.")
    result = ""
    while index:
        index, digit = divmod(index - 1, 26)
        result = chr(97 + digit) + result
    return result


def count_value(value):
    if not re.fullmatch(r"[0-9]+", str(value)) or not 1 <= int(value) <= 702:
        raise PolicyError("Account count must be between 1 and 702.")
    return int(value)


def mode_value(env):
    mode = (env.get("ISOLATION_MODE") or ("worktree" if env.get("PROJECT_DIR_A") else "shared")).lower()
    if mode not in ("shared", "worktree", "isolated"):
        raise PolicyError("ISOLATION_MODE must be shared, worktree or isolated.")
    return mode


def size_bytes(value):
    if isinstance(value, (int, float)) and math.isfinite(value) and value >= 0:
        return int(value)
    match = re.fullmatch(r"([0-9]+)(?:\.([0-9]+))?([kmgtp]?)(?:i?b)?", str(value), re.I)
    if not match:
        raise PolicyError("Invalid memory size; use a finite byte value such as 4G.")
    unit = 1024 ** ("kmgtp".index(match[3].lower()) + 1) if match[3] else 1
    fraction = (match[2] or "")[:3]
    return int(match[1]) * unit + (int(fraction) * unit // 10 ** len(fraction) if fraction else 0)


def positive_int(value, key):
    if not re.fullmatch(r"[0-9]+", str(value)) or not 0 < int(value) <= 2147483647:
        raise PolicyError(key + " must be a positive integer no larger than 2147483647.")
    return int(value)


def budget(env, count):
    vals = {key: env.get(key) or default for key, default in DEFAULTS.items()}
    for key in ("CONTAINER_CPU_LIMIT", "CONTAINER_CPU_RESERVATION"):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", vals[key]) or not 0 < float(vals[key]) <= 1000000:
            raise PolicyError(key + " must be a positive finite CPU count.")
    cpu, cpu_res = float(vals["CONTAINER_CPU_LIMIT"]), float(vals["CONTAINER_CPU_RESERVATION"])
    mem, mem_res = size_bytes(vals["CONTAINER_MEM_LIMIT"]), size_bytes(vals["CONTAINER_MEM_RESERVATION"])
    if cpu_res > cpu or not 0 < mem_res <= mem:
        raise PolicyError("Resource reservations must be positive and no greater than limits.")
    cap_mib = mem // 1048576
    # This mirrors resources.sh's established integer arithmetic; equivalence
    # tests cover fractional byte values and leading zeros.
    heap = positive_int(env["CONTAINER_NODE_HEAP_MB"], "CONTAINER_NODE_HEAP_MB") if env.get("CONTAINER_NODE_HEAP_MB") else cap_mib - max(cap_mib // 4, 512)
    if heap <= 0 or cap_mib - heap < 512:
        raise PolicyError("CONTAINER_NODE_HEAP_MB must leave at least 512 MiB below the memory cap.")
    scratch = {path: positive_int(vals[key], key) * 1048576 for path, key in SCRATCH.items()}
    result = {"cpu_limit": cpu, "cpu_reservation": cpu_res, "memory_limit_bytes": mem,
              "memory_reservation_bytes": mem_res, "node_heap_mib": heap,
              "pids": positive_int(vals["ISOLATED_PIDS_LIMIT"], "ISOLATED_PIDS_LIMIT"),
              "scratch_bytes": sum(scratch.values()), "scratch": scratch}
    return {"accounts": count, "per_account": result,
            "total": {k: v * count for k, v in result.items() if isinstance(v, (int, float))},
            "note": "Limits are ceilings; reservations are distinct. Tmpfs uses the memory cgroup budget, not additional reserved RAM. Scratch defaults are provisional."}


def canonical(path, root, host=False):
    # Fixtures may contain Windows paths on Unix. Real host validation also
    # resolves existing symlinks/junctions (Path.resolve uses GetFinalPathNameByHandle).
    if re.match(r"^(?:[A-Za-z]:[\\/]|\\\\)", path):
        if os.name == "nt" and host:
            path = str(Path(path).resolve())
        return ntpath.normcase(ntpath.normpath(path)).replace("\\", "/").removeprefix("//?/").rstrip("/") + "/"
    item = Path(path)
    if not item.is_absolute():
        item = root / item
    return str(item.resolve() if host else Path(os.path.abspath(item))).rstrip("/") + "/"


def overlaps(a, b):
    return a.startswith(b) or b.startswith(a)


def independent_clone(path):
    path = path.resolve()
    if not (path / ".git").is_dir() or (path / ".git").is_symlink():
        raise PolicyError("Workspace must have an independent, internal .git directory.")
    for flag in ("--absolute-git-dir", "--git-common-dir"):
        directory = Path(run(["git", "-C", str(path), "rev-parse", flag]).strip())
        if not directory.is_absolute():
            directory = path / directory
        if not str(directory.resolve()).startswith(str(path) + os.sep):
            raise PolicyError("Workspace references an external Git administrative directory.")
    # Administrative symlinks can redirect refs/config/hooks even when the
    # object directory itself is local. Existing unsafe clones are preserved.
    for base, dirs, files in os.walk(path / ".git", followlinks=False):
        if any((Path(base) / name).is_symlink() for name in dirs + files):
            raise PolicyError("Workspace Git metadata contains a symlink.")
    objects = path / ".git" / "objects"
    if (objects / "info" / "alternates").exists() or (objects / "info" / "http-alternates").exists():
        raise PolicyError("Workspace borrows Git objects; create a fresh clone with --no-hardlinks --dissociate.")
    for base, dirs, files in os.walk(objects, followlinks=False):
        for name in dirs + files:
            item = Path(base) / name
            if item.is_symlink() or (item.is_file() and item.stat().st_nlink > 1):
                raise PolicyError("Workspace object store contains a symlink or hardlinked object.")
    run(["git", "-C", str(path), "fsck", "--connectivity-only", "--no-dangling"], timeout=120)


def validate_inputs(env, root, host=False):
    count, mode = count_value(env.get("NUM_ACCOUNTS") or "2"), mode_value(env)
    auth = (env.get("GH_AUTH_MODE") or "shared").lower()
    if auth not in ("shared", "per-account"):
        raise PolicyError("GH_AUTH_MODE must be shared or per-account.")
    if auth == "per-account":
        for index in range(1, count + 1):
            for prefix in ("GH_USER_", "GH_TOKEN_"):
                key = prefix + account_letter(index).upper()
                if not env.get(key, "").strip():
                    raise PolicyError(key + " is required when GH_AUTH_MODE=per-account.")
    sources = []
    for index in range(1, count + 1):
        letter = account_letter(index).upper()
        key = ("ISOLATED_WORKSPACE_" if mode == "isolated" else "PROJECT_DIR_") + letter
        if mode == "shared":
            break
        path = env.get(key, "")
        if not path.strip():
            raise PolicyError(key + " is required when ISOLATION_MODE=" + mode)
        normalized = canonical(path, root, host)
        if mode == "isolated":
            if any(overlaps(normalized, previous) for previous in sources):
                raise PolicyError(key + " overlaps another account workspace.")
            sources.append(normalized)
            if host:
                item = Path(path) if Path(path).is_absolute() else root / path
                if not item.is_dir():
                    raise PolicyError(key + " must exist before startup; run setup-isolated first.")
                if (item / ".git").exists():
                    independent_clone(item)
    if (env.get("ISOLATED_NETWORK_MODE") or "bridge").lower() not in ("bridge", "none"):
        raise PolicyError("ISOLATED_NETWORK_MODE must be bridge or none.")
    return budget(env, count)


def worktree_metadata(env, root, create=False):
    """Keep host gitfiles intact; mount a container-specific gitfile over them."""
    if mode_value(env) != "worktree":
        return []
    registry = json.loads((root / "tui/internal/config/runtimes.json").read_text())["runtimes"]
    spec = registry[(env.get("AGENT_RUNTIME") or "claude").lower()]
    source = Path(env.get("PROJECT_DIR", ""))
    if not source.is_absolute():
        source = root / source
    common = (source / ".git").resolve()
    if not common.is_dir():
        raise PolicyError("Worktree PROJECT_DIR must identify the source repository with its own .git directory.")
    plans = []
    for i in range(1, count_value(env.get("NUM_ACCOUNTS") or "2") + 1):
        letter = account_letter(i)
        workspace = Path(env["PROJECT_DIR_" + letter.upper()])
        if not workspace.is_absolute():
            workspace = root / workspace
        git_dir = Path(run(["git", "-C", str(workspace), "rev-parse", "--absolute-git-dir"] ).strip()).resolve()
        if not git_dir.is_relative_to(common / "worktrees"):
            raise PolicyError("Configured worktree does not belong to PROJECT_DIR's Git metadata.")
        content = "gitdir: /git-common/" + git_dir.relative_to(common).as_posix() + "\n"
        path = Path(env.get("HOME") or str(Path.home())) / spec["stateDir"] / ("account-" + letter) / ".container-worktree.git"
        if path.exists() and path.read_text() != content:
            raise PolicyError("Container worktree gitfile is stale; remove only .container-worktree.git in the account state and retry startup.")
        plans.append((path, content))
    if create:
        for path, content in plans:
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with path.open("x", encoding="utf-8") as output:
                    output.write(content)
                path.chmod(0o600)
    return plans


def run(argv, env=None, cwd=None, timeout=60):
    if Path(argv[0]).name in ("git", "git.exe"):
        # Host Git checks must describe the requested repository even when the
        # caller is a Git hook with administrative redirection variables set.
        env = dict(os.environ if env is None else env)
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_INDEX_FILE", "GIT_NAMESPACE"):
            env.pop(key, None)
    try:
        result = subprocess.run(argv, env=env, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PolicyError("Command unavailable or timed out: " + Path(argv[0]).name) from error
    if result.returncode:
        # stderr may contain interpolated tokens, URLs or complete YAML. Do not
        # echo it or write it to a failure artifact.
        raise PolicyError("Command failed: " + Path(argv[0]).name + " (exit " + str(result.returncode) + "). Check configuration and daemon availability.", result.returncode)
    return result.stdout


def compose(root, directory, env_file, env, project=None):
    argv = ["docker", "compose", "--project-directory", str(root), "--env-file", str(env_file)]
    if project or env.get("COMPOSE_PROJECT_NAME"):
        argv += ["--project-name", project or env["COMPOSE_PROJECT_NAME"]]
    argv += ["-f", str(directory / "docker-compose.yml")]
    if sys.platform.startswith("linux") and (directory / "docker-compose.linux.yml").exists():
        env["UID"], env["GID"] = str(os.getuid()), str(os.getgid())
        argv += ["-f", str(directory / "docker-compose.linux.yml")]
    mode = mode_value(env)
    if mode != "shared":
        argv += ["-f", str(directory / ("docker-compose." + mode + ".yml"))]
    return argv


def describe(model):
    services = []
    for name, service in sorted(model.get("services", {}).items()):
        env = service.get("environment") or {}
        limits = ((service.get("deploy") or {}).get("resources") or {})
        services.append({"service": name, "mode": env.get("ISOLATION_MODE", "shared"),
                         "user": service.get("user", ""), "mounts": service.get("volumes", []),
                         "networks": sorted((service.get("networks") or {}).keys()),
                         "network_mode": service.get("network_mode"),
                         "read_only": service.get("read_only", False), "init": service.get("init", False),
                         "cap_drop": service.get("cap_drop", []), "cap_add": service.get("cap_add", []),
                         "security_opt": service.get("security_opt", []),
                         "privileged": service.get("privileged", False), "pid": service.get("pid"),
                         "ipc": service.get("ipc"), "devices": service.get("devices", []),
                         "ports": service.get("ports", []), "tmpfs": service.get("tmpfs", []),
                         "extra_privileges": [key for key in ("volumes_from", "links", "external_links", "extra_hosts", "group_add", "device_cgroup_rules", "userns_mode", "uts", "sysctls", "secrets", "configs", "cgroup_parent") if service.get(key)],
                         "limits": limits.get("limits", {}), "reservations": limits.get("reservations", {}),
                         "environment_keys": sorted(env.keys())})
    return {"project": model.get("name"), "services": services}


def validate_model(model, env, root, host=False):
    manifest = describe(model)
    services = manifest["services"]
    count = count_value(env.get("NUM_ACCOUNTS") or "2")
    if len(services) != count:
        raise PolicyError("Resolved service count differs from NUM_ACCOUNTS.")
    mode = mode_value(env)
    registry = json.loads((root / "tui/internal/config/runtimes.json").read_text())["runtimes"]
    runtime = (env.get("AGENT_RUNTIME") or "claude").lower()
    if runtime not in registry:
        raise PolicyError("AGENT_RUNTIME is not a known runtime.")
    spec = registry[runtime]
    expected = {spec["servicePrefix"] + "-" + account_letter(i): account_letter(i) for i in range(1, count + 1)}
    if set(expected) != {s["service"] for s in services}:
        raise PolicyError("Resolved services differ from the runtime/account registry.")
    mounts, networks = [], set()
    broad = {canonical(p, root, host) for p in ("/", "/home", "/Users", "/var", "/etc", "/run", "/var/run", env.get("HOME") or str(Path.home()))}
    for service in services:
        if service["mode"] != mode:
            raise PolicyError("Resolved ISOLATION_MODE differs from selected overlay; regenerate Compose files.")
        if mode != "isolated":
            continue
        letter = expected[service["service"]]
        workspace = canonical(env["ISOLATED_WORKSPACE_" + letter.upper()], root, host)
        state_root = Path(env.get("HOME") or str(Path.home())) / spec["stateDir"] / ("account-" + letter)
        state_path = canonical(str(state_root), root, host)
        target_workspace = env.get("CONTAINER_ISOLATED_DIR_" + letter.upper()) or "/workspace-" + letter
        if not any(m.get("type") == "bind" and canonical(m.get("source", ""), root, host) == workspace and m.get("target") == target_workspace and not m.get("read_only") for m in service["mounts"]):
            raise PolicyError("Isolated service is missing its approved writable workspace mount.")
        if not any(m.get("type") == "bind" and canonical(m.get("source", ""), root, host) == state_path and m.get("target") == spec["containerConfigMount"] and not m.get("read_only") for m in service["mounts"]):
            raise PolicyError("Isolated service is missing its approved account state mount.")
        if not re.fullmatch(r"[0-9]+(?::[0-9]+)?", service["user"]) or int(service["user"].split(":")[0]) == 0:
            raise PolicyError("Isolated services require an explicit nonzero numeric UID.")
        if (not service["read_only"] or not service["init"] or "ALL" not in service["cap_drop"]
                or service["cap_add"] or service["privileged"] or service["devices"] or service["ports"]
                or service["extra_privileges"]
                or service["pid"] or service["ipc"] not in (None, "private")
                or not any(s in ("no-new-privileges:true", "no-new-privileges") for s in service["security_opt"])
                or any(s not in ("no-new-privileges:true", "no-new-privileges") for s in service["security_opt"])
                or model["services"][service["service"]].get("cgroup") == "host"
                or service["reservations"].get("devices")):
            raise PolicyError("Resolved isolated service weakens the outer container policy.")
        positive_int(service["limits"].get("pids", 0), "Resolved PID limit")
        if service["network_mode"] == "none":
            if (env.get("ISOLATED_NETWORK_MODE") or "bridge").lower() != "none":
                raise PolicyError("Resolved network policy differs from ISOLATED_NETWORK_MODE.")
            if service["networks"]:
                raise PolicyError("Offline account has network attachments.")
        elif service["network_mode"] or len(service["networks"]) != 1:
            raise PolicyError("Isolated account must have one private bridge or network_mode=none.")
        elif (env.get("ISOLATED_NETWORK_MODE") or "bridge").lower() == "none":
            raise PolicyError("Offline policy resolved to a bridge network.")
        for network in service["networks"]:
            definition = (model.get("networks") or {}).get(network, {})
            actual = definition.get("name", network)
            if (network != "isolated_net_" + letter or actual != model.get("name", "") + "_" + network
                    or actual in networks or definition.get("external") or definition.get("internal")
                    or definition.get("driver_opts") or definition.get("driver", "bridge") != "bridge"):
                raise PolicyError("Isolated accounts must use distinct project-owned bridge networks.")
            networks.add(actual)
        for mount in service["mounts"]:
            source, target, kind = mount.get("source", ""), mount.get("target", ""), mount.get("type")
            if target.rstrip("/") in ("", "/home", "/home/node", "/etc", "/proc", "/sys", "/dev", "/run", "/var/run"):
                raise PolicyError("Isolated bind target replaces a protected container root.")
            if kind not in ("bind", "volume") or not source or not target or "docker.sock" in source or "docker.sock" in target:
                raise PolicyError("Isolated account has an unsupported or forbidden mount.")
            if kind == "bind":
                key = canonical(source, root, host)
                if key in broad or re.fullmatch(r"[a-z]:/", key) or "/.git/" in key:
                    raise PolicyError("Isolated account exposes a broad host root or Git administrative path.")
                if not (key.startswith(workspace) or key.startswith(state_path)):
                    raise PolicyError("Isolated bind source is outside its approved workspace/state roots.")
                if host and Path(source).is_symlink():
                    # canonical() compares the dereferenced destination above;
                    # this branch documents that aliases are never trusted by spelling.
                    canonical(source, root, True)
            else:
                definition = (model.get("volumes") or {}).get(source, {})
                if definition.get("external") or definition.get("driver_opts") or definition.get("driver", "local") != "local":
                    raise PolicyError("Isolated volumes must be project-owned local volumes without driver options.")
                key = definition.get("name", source)
                if (source != "node_modules_" + letter or key != model.get("name", "") + "_" + source
                        or target != target_workspace.rstrip("/") + "/node_modules"):
                    raise PolicyError("Isolated dependency volume must belong to the matching account workspace.")
            for owner, other_kind, other_key in mounts:
                # Even a read-only duplicate leaks another account's data.
                if owner != service["service"] and kind == other_kind and (overlaps(key, other_key) if kind == "bind" else key == other_key):
                    raise PolicyError("Resolved mounts expose another account's data.")
            mounts.append((service["service"], kind, key))
        raw_env = model["services"][service["service"]].get("environment") or {}
        allowed_secrets = {spec["sdkApiKeyVar"], "GH_TOKEN"}
        for key in raw_env:
            if re.search(r"(?:TOKEN|API_KEY|PASSWORD|SECRET)", key) and key not in allowed_secrets:
                raise PolicyError("Isolated service exposes an unapproved credential environment key.")
        for container_key, config_key in ((spec["sdkApiKeyVar"], spec["apiKeyVarPrefix"] + letter.upper()), ("GH_TOKEN", "GH_TOKEN_" + letter.upper())):
            expected_value = env.get(config_key)
            if container_key == "GH_TOKEN" and (env.get("GH_AUTH_MODE") or "shared").lower() != "per-account":
                expected_value = None
                if container_key in raw_env:
                    raise PolicyError("Isolated services cannot use a shared GitHub token fallback.")
            if expected_value:
                if raw_env.get(container_key) != expected_value:
                    raise PolicyError("Isolated service credential mapping is missing or stale; regenerate Compose files.")
            elif container_key in raw_env:
                raise PolicyError("Isolated service exposes a credential without its account mapping.")
        for key, value in raw_env.items():
            if key.endswith("_CONFIG_SOURCE") and value:
                value = posixpath.normpath(value)
                if not any(value == m["target"] or value.startswith(m["target"].rstrip("/") + "/") for m in service["mounts"]):
                    raise PolicyError("Custom configuration source must reside in an account-local mount.")
        scratch_total = 0
        for entry in service["tmpfs"]:
            path, _, options = entry.partition(":")
            pairs = dict(part.split("=", 1) for part in options.split(",") if "=" in part)
            if path not in SCRATCH or "size" not in pairs or size_bytes(pairs["size"]) <= 0:
                raise PolicyError("Isolated scratch mounts require approved paths and explicit finite sizes.")
            if pairs.get("mode", "").lstrip("0") != ("1777" if path == "/tmp" else "700"):
                raise PolicyError("Isolated scratch mount modes differ from the approved inventory.")
            uid_gid = service["user"].split(":")
            if path != "/tmp" and (pairs.get("uid") != uid_gid[0] or pairs.get("gid") != uid_gid[-1]):
                raise PolicyError("Scratch ownership must match the effective container UID/GID.")
            scratch_total += size_bytes(pairs["size"])
        if len(service["tmpfs"]) != len(SCRATCH) or {entry.partition(":")[0] for entry in service["tmpfs"]} != set(SCRATCH):
            raise PolicyError("Isolated scratch inventory is incomplete.")
        service["scratch_bytes"] = scratch_total
    return manifest


def resolved_budget(model, manifest):
    per_service = {}
    for service in manifest["services"]:
        limits, reservations = service["limits"], service["reservations"]
        cpu, cpu_res = float(limits.get("cpus", 0)), float(reservations.get("cpus", 0))
        mem, mem_res = size_bytes(limits.get("memory", 0)), size_bytes(reservations.get("memory", 0))
        options = (model["services"][service["service"]].get("environment") or {}).get("NODE_OPTIONS", "")
        match = re.search(r"(?:^|\s)--max-old-space-size=([0-9]+)(?:\s|$)", options)
        if not match or int(match[1]) <= 0 or mem // 1048576 - int(match[1]) < 512:
            raise PolicyError("Resolved Node heap must leave at least 512 MiB below the actual memory cap.")
        if not math.isfinite(cpu) or not 0 < cpu_res <= cpu or not 0 < mem_res <= mem:
            raise PolicyError("Resolved resource reservations/limits are invalid.")
        per_service[service["service"]] = {"cpu_limit": cpu, "cpu_reservation": cpu_res,
                "memory_limit_bytes": mem, "memory_reservation_bytes": mem_res,
                "node_heap_mib": int(match[1]), "pids": limits.get("pids"),
                "scratch_bytes": service.get("scratch_bytes", 0)}
    return {"accounts": len(per_service), "services": per_service,
            "total": {key: sum(item[key] for item in per_service.values()) for key in
                      ("cpu_limit", "cpu_reservation", "memory_limit_bytes", "memory_reservation_bytes", "node_heap_mib", "scratch_bytes")},
            "note": "Configured limits are ceilings, not measured use. Reservations are distinct. Tmpfs consumes the memory cgroup budget; it is not extra reserved RAM. A null PID cap is unlimited."}


def capacity(env):
    try:
        info = json.loads(run(["docker", "info", "--format", "{{json .}}"], env=env, timeout=5))
        return {"status": "known", "cpus": info["NCPU"], "memory_bytes": info["MemTotal"]}
    except (PolicyError, ValueError, KeyError):
        return {"status": "unknown", "reason": "Docker daemon capacity unavailable (5 second query limit)."}


def resolved(root, directory, env_file, env, host=False):
    validate_inputs(env, root, host)
    if host and mode_value(env) == "worktree":
        worktree_metadata(env, root)
    cmd = compose(root, directory, env_file, env)
    try:
        model = json.loads(run(cmd + ["config", "--format", "json"], env, root))
    except ValueError as error:
        raise PolicyError("Docker Compose returned an invalid resolved model.") from error
    manifest = validate_model(model, env, root, host)
    manifest["budget"] = resolved_budget(model, manifest)
    manifest["capacity"] = capacity(env)
    cap, total = manifest["capacity"], manifest["budget"]["total"]
    manifest["warnings"] = []
    if cap["status"] == "known" and (total["cpu_limit"] > cap["cpus"] or total["memory_limit_bytes"] > cap["memory_bytes"]):
        manifest["warnings"].append("Aggregate configured ceilings exceed Docker capacity; simultaneous peak usage can contend or OOM.")
    return model, manifest, cmd


def setup_plan(root, env, source, count):
    source = source.resolve()
    if not (source / ".git").exists():
        raise PolicyError("Source is not a git repository.")
    count = count_value(count)
    registry = json.loads((root / "tui/internal/config/runtimes.json").read_text())["runtimes"]
    runtime = (env.get("AGENT_RUNTIME") or "claude").lower()
    if runtime not in registry:
        raise PolicyError("AGENT_RUNTIME is not a known runtime.")
    spec = registry[runtime]
    accounts = []
    for i in range(1, count + 1):
        letter = account_letter(i)
        destination = Path(str(source) + "-isolated-" + letter)
        if destination.exists() or destination.is_symlink():
            # Reject aliases instead of accepting an apparently idempotent
            # destination that reaches the source or a sibling through a link.
            if destination.is_symlink() or not (destination / ".git").exists():
                raise PolicyError("Destination exists but is not a git repository owned by this setup. This script never deletes host paths; choose another source path.")
            independent_clone(destination)
        state = Path(env.get("HOME") or str(Path.home())) / spec["stateDir"] / ("account-" + letter)
        accounts.append({"account": letter, "workspace": str(destination),
                         "action": "reuse verified clone" if destination.exists() else "clone --no-hardlinks --dissociate",
                         "state": str(state), "mounts": [
                             {"type": "bind", "source": str(destination), "target": "/workspace-" + letter},
                             {"type": "bind", "source": str(state), "target": spec["containerConfigMount"]},
                             {"type": "volume", "source": "node_modules_" + letter, "target": "/workspace-" + letter + "/node_modules"}],
                         "network": "none" if (env.get("ISOLATED_NETWORK_MODE") or "bridge").lower() == "none" else "isolated_net_" + letter})
    return {"source": str(source), "mode": "isolated", "accounts": accounts,
            "budget": budget(env, count), "capacity": capacity(env),
            "validation": "Destination/Git checks completed; resolved Compose and runtime checks run at startup."}


def setup(root, env, source, count, dry_run):
    plan = setup_plan(root, env, source, count)
    print(json.dumps(plan, indent=2), flush=True)
    if dry_run:
        return
    source = Path(plan["source"])
    fresh, published = [], []
    # Sibling staging keeps final publication on the same filesystem. An
    # existing target is never removed, even if another process creates it
    # between preflight and publish.
    with tempfile.TemporaryDirectory(prefix=".isolated-setup-", dir=source.parent) as scratch:
        scratch = Path(scratch)
        try:
            for account in plan["accounts"]:
                target = Path(account["workspace"])
                if account["action"] == "reuse verified clone":
                    print("Account " + account["account"] + ": already a clone, left unchanged.")
                    continue
                staged = scratch / account["account"]
                run(["git", "clone", "--no-hardlinks", "--dissociate", str(source), str(staged)], timeout=600)
                try:
                    upstream = run(["git", "-C", str(source), "remote", "get-url", "origin"]).strip()
                except PolicyError:
                    upstream = ""
                    print("Source has no origin remote; the clone keeps a local-path origin.")
                if upstream:
                    upstream = re.sub(r"^(https?://)[^/]*@", r"\1", upstream, flags=re.IGNORECASE)
                    run(["git", "-C", str(staged), "remote", "set-url", "origin", upstream])
                independent_clone(staged)
                fresh.append((staged, target))
            # mkdir reserves only new destinations; move children into the
            # reserved directory, so os.rename cannot replace a raced target.
            for staged, target in fresh:
                target.mkdir(mode=0o700)
                published.append(target)
                for child in staged.iterdir():
                    child.rename(target / child.name)
        except BaseException:
            for target in reversed(published):
                # These paths were reserved by this operation, never reused.
                shutil.rmtree(target)
            raise
    print("\nAdd to .env:\n  ISOLATION_MODE=isolated")
    for account in plan["accounts"]:
        print("  ISOLATED_WORKSPACE_" + account["account"].upper() + "=" + account["workspace"])
    print("Then regenerate compose with the platform's scripts/generate-compose helper.")


def protect(path, directory=False):
    if os.name == "nt":
        # icacls accepts the current user's SID without locale-dependent names.
        identity = run(["whoami", "/user", "/fo", "csv", "/nh"])
        sid = re.search(r"S-1-\d+(?:-\d+)+", identity)
        if not sid:
            raise PolicyError("Cannot identify the owner for transaction ACL protection.")
        grant = "*" + sid[0] + (":(OI)(CI)F" if directory else ":F")
        run(["icacls", str(path), "/inheritance:r", "/grant:r", grant])
    else:
        path.chmod(0o700 if directory else 0o600)


def atomic_file(source, destination, mode=None):
    """One atomic replacement; the lifecycle lock protects the whole set."""
    fd, name = tempfile.mkstemp(prefix=".publish-", dir=destination.parent)
    temp = Path(name)
    try:
        with os.fdopen(fd, "wb") as output, source.open("rb") as input_file:
            shutil.copyfileobj(input_file, output)
            output.flush()
            os.fsync(output.fileno())
        if os.name == "nt" and destination.exists():
            # ReplaceFile preserves the destination ACL, unlike shutil.move.
            import ctypes
            replace = ctypes.windll.kernel32.ReplaceFileW
            replace.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_wchar_p,
                                ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
            if not replace(str(destination), str(temp), None, 0, None, None):
                raise PolicyError("Atomic file publication failed on Windows.")
        else:
            if mode is not None:
                temp.chmod(mode)
            if os.name == "nt":
                protect(temp)
            os.replace(temp, destination)
    finally:
        temp.unlink(missing_ok=True)


def journal_write(lock, journal):
    temp = lock / "journal.next"
    temp.write_text(json.dumps(journal), encoding="utf-8")
    protect(temp)
    with temp.open("rb") as file:
        os.fsync(file.fileno())
    os.replace(temp, lock / "journal.json")


def process_alive(pid):
    if os.name == "nt":
        import ctypes
        kernel = ctypes.windll.kernel32
        kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_bool, ctypes.c_ulong]
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        code = ctypes.c_ulong()
        try:
            return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


@contextlib.contextmanager
def lifecycle_lock(root):
    lock = root / ".claude-docker-lifecycle"
    token = os.environ.get("CLAUDE_DOCKER_LOCK_TOKEN")
    if token and lock.is_dir() and not lock.is_symlink():
        owner = json.loads((lock / "owner.json").read_text())
        if owner["token"] == token and process_alive(owner["pid"]):
            # The process doing the transaction must remain the recorded owner
            # if a waiting shell/wrapper is killed before compensation finishes.
            borrowed = dict(owner, pid=os.getpid())
            (lock / "owner.json").write_text(json.dumps(borrowed))
            try:
                yield lock
            finally:
                if (lock / "owner.json").exists():
                    (lock / "owner.json").write_text(json.dumps(owner))
            return
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError as error:
        raise PolicyError("Lifecycle lock exists. Wait for the active operation; after an interrupted operation run claude-docker recover.") from error
    try:
        protect(lock, directory=True)
        owner = {"pid": os.getpid(), "token": uuid.uuid4().hex}
        (lock / "owner.json").write_text(json.dumps(owner))
        yield lock
    finally:
        # Failed recovery leaves protected evidence and prevents readers from
        # consuming a partly recovered installation.
        if not (lock / "journal.json").exists():
            shutil.rmtree(lock)


def names(cmd, env, root, running=False):
    arguments = ["ps", "--services"] + (["--status", "running"] if running else ["--all"])
    return sorted(set(run(cmd + arguments, env, root).split()))


def resources(project, env):
    result = {}
    for kind in ("volume", "network"):
        result[kind] = run(["docker", kind, "ls", "--filter", "label=com.docker.compose.project=" + project,
                            "--format", "{{.Name}}"], env).splitlines()
    return result


def account_state_paths(model, env, root):
    registry = json.loads((root / "tui/internal/config/runtimes.json").read_text())["runtimes"]
    target = registry[(env.get("AGENT_RUNTIME") or "claude").lower()]["containerConfigMount"]
    paths = sorted({Path(mount["source"]) for service in model["services"].values()
                    for mount in service.get("volumes", [])
                    if mount.get("type") == "bind" and mount.get("target") == target})
    if any(path.exists() and not path.is_dir() for path in paths):
        raise PolicyError("Account state bind sources must be directories.")
    return paths


def create_state_directories(paths, record=None):
    # Create binds as the host user before Docker can create root-owned paths.
    # Existing state, permissions and data are never replaced.
    for directory in paths:
        missing = []
        while not directory.exists():
            missing.append(directory)
            parent = directory.parent
            if parent == directory:
                raise PolicyError("Account state filesystem root is unavailable.")
            directory = parent
        for directory in reversed(missing):
            directory.mkdir(mode=0o700)
            if record:
                record(directory)
            protect(directory, directory=True)


def prepare_dependency_volumes(model, cmd, env, root):
    """Initialize only fresh account volumes for arbitrary non-root host UIDs.

    Docker creates an empty volume root-owned. A short, offline initializer
    owns that directory and can chmod it with *zero* capabilities. It receives
    no credentials or bind mounts. The account remains non-root/cap_drop=ALL.
    The sticky writable directory is private to one account, like its /tmp.
    """
    project = model["name"]
    known = set(resources(project, env)["volume"])
    prepared_images = set()
    for service in model["services"].values():
        for mount in service.get("volumes", []):
            if mount.get("type") != "volume":
                continue
            logical = mount["source"]
            definition = model["volumes"][logical]
            if not re.fullmatch(r"node_modules_[a-z]{1,2}", logical) or definition.get("external") or definition.get("driver_opts"):
                continue
            name = definition["name"]
            if name in known:
                continue
            image = service["image"]
            if image not in prepared_images:
                try:
                    run(["docker", "image", "inspect", "--format", "{{.Id}}", image], env)
                except PolicyError:
                    run(cmd + ["build"], env, root, 1200)
                prepared_images.add(image)
            transaction = uuid.uuid4().hex
            run(["docker", "volume", "create", "--label", "com.docker.compose.project=" + project,
                 "--label", "com.docker.compose.volume=" + logical,
                 "--label", "com.claude-docker.initializer=" + transaction, name], env)
            owner = run(["docker", "volume", "inspect", "--format", '{{index .Labels "com.claude-docker.initializer"}}', name], env).strip()
            if owner != transaction:
                raise PolicyError("Dependency volume appeared concurrently; refusing to change its permissions.")
            initializer = project + "-cache-init-" + transaction[:12]
            try:
                run(["docker", "run", "--rm", "--name", initializer, "--user", "0:0", "--read-only",
                     "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--network", "none",
                     "--pids-limit", "32", "--memory", "64m", "--entrypoint", "/bin/sh",
                     "--mount", "type=volume,source=" + name + ",target=/dependency-cache",
                     image, "-c", "chmod 1777 /dependency-cache"], env, root, 60)
            except PolicyError:
                try:
                    run(["docker", "rm", "--force", initializer], env)
                except PolicyError:
                    print("Dependency initializer cleanup failed; inspect the project initializer container.", file=sys.stderr)
                try:
                    # Docker refuses removal if a container still uses it. This
                    # name was claimed with our unique label above.
                    run(["docker", "volume", "rm", name], env)
                except PolicyError:
                    print("Fresh dependency volume cleanup failed; inspect the project volume before retrying startup.", file=sys.stderr)
                raise
            known.add(name)


def rollback(root, lock, journal):
    errors = []
    def attempt(action):
        try:
            action()
        except (OSError, PolicyError) as error:
            errors.append(str(error) if isinstance(error, PolicyError) else "Filesystem recovery failed.")
    old_env = dict(os.environ, **journal["environment"])
    old_env.pop("CLAUDE_DOCKER_ENV_FILE", None)
    backup, staged = lock / "backup", lock / "staged"
    old_cmd = compose(root, backup, backup / ".env", old_env, journal["project"])
    candidate_env = dict(old_env, **journal.get("candidate_environment", {}))
    candidate_cmd = compose(root, staged, staged / ".env", candidate_env, journal["project"])
    if journal.get("applying"):
        # Limit compensation to named services introduced by this operation.
        added = sorted(set(journal["candidate_services"]) - set(journal["existing_services"]))
        if added:
            attempt(lambda: run(candidate_cmd + ["rm", "--stop", "--force"] + added, candidate_env, root, 180))
    if journal.get("publishing"):
        for name in FILES:
            destination = root / name
            if journal["files"][name] is None:
                attempt(lambda d=destination: d.unlink(missing_ok=True))
            else:
                attempt(lambda n=name, d=destination: atomic_file(backup / n, d, journal["files"][n]))
    if journal.get("applying"):
        if journal["running_services"]:
            attempt(lambda: run(old_cmd + ["up", "--detach", "--no-deps"] + journal["running_services"], old_env, root, 600))
        stopped = sorted(set(journal["existing_services"]) - set(journal["running_services"]))
        if stopped:
            attempt(lambda: run(old_cmd + ["create", "--no-recreate"] + stopped, old_env, root, 600))
            attempt(lambda: run(old_cmd + ["stop"] + stopped, old_env, root, 180))
        try:
            current = resources(journal["project"], old_env)
            for kind in ("volume", "network"):
                owned = set(journal.get("candidate_resources", {}).get(kind, []))
                for name in sorted((set(current[kind]) - set(journal["resources"][kind])) & owned):
                    attempt(lambda k=kind, n=name: run(["docker", k, "rm", n], old_env))
        except PolicyError as error:
            errors.append(str(error))
    for filename, expected in journal.get("created_files", {}).items():
        path = Path(filename)
        if path.is_file() and path.read_text() == expected:
            attempt(lambda p=path: p.unlink())
    for directory in reversed(journal.get("created_dirs", [])):
        try:
            Path(directory).rmdir()
        except FileNotFoundError:
            pass
        except OSError:
            # Runtime/user writes made after startup belong to the account.
            # Preserve them, rather than making a byte-identical history claim.
            print("Recovery retained a nonempty new account directory.", file=sys.stderr)
    if errors:
        raise PolicyError("Recovery incomplete: " + "; ".join(errors) + " Protected journal retained; restore daemon access and run claude-docker recover.")
    (lock / "journal.json").unlink(missing_ok=True)


def scale(root, count, language):
    count = count_value(count)
    with lifecycle_lock(root) as lock:
        env_file = root / ".env"
        if not env_file.exists():
            raise PolicyError(".env not found; run the installer first.")
        if not env_file.is_file() or env_file.is_symlink():
            raise PolicyError(".env must be a regular file; run the installer first.")
        env = environment(root)
        candidate_env = dict(env, NUM_ACCOUNTS=str(count))
        validate_inputs(candidate_env, root)
        staged, backup = lock / "staged", lock / "backup"
        staged.mkdir(mode=0o700)
        backup.mkdir(mode=0o700)
        previous = {}
        for name in FILES:
            path = root / name
            if path.is_symlink() or (path.exists() and not path.is_file()):
                raise PolicyError("Managed configuration must consist of regular files.")
            previous[name] = stat.S_IMODE(path.stat().st_mode) if path.exists() else None
            if path.exists():
                shutil.copyfile(path, backup / name)
                protect(backup / name)
        original = (backup / ".env").read_bytes()
        text = original.decode("utf-8-sig")
        candidate, substitutions = re.subn(r"(?m)^\s*NUM_ACCOUNTS\s*=[^\r\n]*", "NUM_ACCOUNTS=" + str(count), text)
        if not substitutions:
            candidate = text.rstrip("\r\n") + "\nNUM_ACCOUNTS=" + str(count) + "\n"
        (staged / ".env").write_bytes(candidate.encode("utf-8"))
        protect(staged / ".env")
        candidate_env["CLAUDE_DOCKER_ENV_FILE"] = str(staged / ".env")
        if language == "powershell":
            generator = ["pwsh", "-NoProfile", "-File", str(root / "scripts/generate-compose.ps1"),
                         "-NumAccounts", str(count), "-EnvFile", str(staged / ".env"), "-OutputDir", str(staged)]
        else:
            generator = ["bash", str(root / "scripts/generate-compose.sh"), "--env-file", str(staged / ".env"), "--output-dir", str(staged)]
        run(generator, candidate_env, root, 600)
        if any(not (staged / name).is_file() or (staged / name).is_symlink() for name in FILES):
            raise PolicyError("Generator did not produce all four staged Compose files.")
        model, manifest, candidate_cmd = resolved(root, staged, staged / ".env", candidate_env, host=True)
        project = model.get("name")
        if not project:
            raise PolicyError("Compose did not report the installation project name.")
        candidate_cmd = compose(root, staged, staged / ".env", candidate_env, project)
        old_cmd = compose(root, backup, backup / ".env", env, project)
        if (backup / "docker-compose.yml").exists():
            old_model = json.loads(run(old_cmd + ["config", "--format", "json"], env, root))
            old_services = sorted(old_model["services"])
            existing, running = names(old_cmd, env, root), names(old_cmd, env, root, True)
        else:
            old_services, existing, running = [], [], []
        # Save only configuration and Docker connection inputs, not unrelated
        # developer environment variables. They remain protected like .env.
        keys = set(read_env(backup / ".env")) | {"HOME", "UID", "GID", "PATH"}
        keys.update(k for k in env if re.match(r"^(COMPOSE_|DOCKER_|CONTAINER_|ISOLAT|AGENT_|GH_|GIT_|CLAUDE_|CODEX_|GEMINI_|PROJECT_|IMAGE_|NUM_ACCOUNTS)", k))
        saved = {k: env[k] for k in keys if k in env}
        journal = {"project": project, "files": previous, "environment": saved,
                   "candidate_environment": dict(saved, NUM_ACCOUNTS=str(count)),
                   "candidate_services": sorted(model["services"]), "existing_services": existing,
                   "running_services": running, "resources": resources(project, env),
                   "candidate_resources": {kind: [v.get("name", k) for k, v in model.get(kind + "s", {}).items()]
                                           for kind in ("volume", "network")},
                   "created_dirs": [], "publishing": False, "applying": False}
        journal_write(lock, journal)
        handlers = {}
        def interrupted(signum, _frame):
            raise PolicyError("Scale interrupted by signal " + str(signum) + ".")
        for signum in (signal.SIGINT, signal.SIGTERM):
            handlers[signum] = signal.signal(signum, interrupted)
        try:
            print(json.dumps(manifest, indent=2), flush=True)
            # A real account state bind is the only directory scale creates.
            def record_directory(directory):
                journal["created_dirs"].append(str(directory))
                journal_write(lock, journal)
            create_state_directories(account_state_paths(model, candidate_env, root), record_directory)
            for name in FILES:
                path = root / name
                if ((previous[name] is None and path.exists()) or
                        (previous[name] is not None and (not path.is_file() or path.read_bytes() != (backup / name).read_bytes()))):
                    raise PolicyError("Managed configuration changed during staging; retry scale against the new configuration.")
            journal["publishing"] = True
            journal_write(lock, journal)
            for name in FILES:
                atomic_file(staged / name, root / name, previous[name] if previous[name] is not None else (0o600 if name == ".env" else 0o644))
            desired = set(model["services"])
            removed = sorted((set(existing) & set(old_services)) - desired)
            if running or removed:
                journal["applying"] = True
                journal_write(lock, journal)
            if running:
                prepare_dependency_volumes(model, candidate_cmd, candidate_env, root)
                plans = worktree_metadata(candidate_env, root)
                journal["created_files"] = {str(path): content for path, content in plans if not path.exists()}
                journal_write(lock, journal)
                worktree_metadata(candidate_env, root, create=True)
                start = sorted((set(running) & desired) | (desired - set(old_services) - set(existing)))
                if start:
                    run(candidate_cmd + ["up", "--detach", "--no-deps"] + start, candidate_env, root, 600)
                    if not set(start) <= set(names(candidate_cmd, candidate_env, root, True)):
                        raise PolicyError("Scale startup did not establish the intended running service set.")
            if removed:
                run(old_cmd + ["rm", "--stop", "--force"] + removed, env, root, 180)
            (lock / "journal.json").unlink()
        except BaseException as error:
            try:
                rollback(root, lock, journal)
            except PolicyError as recovery:
                print(str(recovery), file=sys.stderr)
            raise error
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
        print("Scaled to " + str(count) + " account(s).")


@contextlib.contextmanager
def recovery_claim(lock):
    # An OS lock is released even after a hard kill. Two recovery attempts
    # must not both replay the journal while its original owner is dead.
    with (lock / "recovery.lock").open("a+b") as claim:
        try:
            if os.name == "nt":
                import msvcrt
                claim.write(b"0")
                claim.flush()
                claim.seek(0)
                msvcrt.locking(claim.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(claim.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise PolicyError("Another recovery is active; wait for it to finish.") from error
        try:
            yield
        finally:
            if os.name == "nt":
                claim.seek(0)
                msvcrt.locking(claim.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(claim.fileno(), fcntl.LOCK_UN)


def recover(root):
    lock = root / ".claude-docker-lifecycle"
    if not lock.exists():
        print("No interrupted lifecycle operation.")
        return
    if lock.is_symlink():
        raise PolicyError("Refusing a symlink lifecycle lock.")
    with recovery_claim(lock):
        try:
            owner = json.loads((lock / "owner.json").read_text())
            pid = int(owner["pid"])
        except (OSError, ValueError, KeyError) as error:
            raise PolicyError("Lifecycle owner record is missing or invalid; inspect the protected lock directory before manual recovery.") from error
        if process_alive(pid):
            raise PolicyError("Lifecycle owner is still running; recovery would race the active operation.")
        if (lock / "journal.json").exists():
            rollback(root, lock, json.loads((lock / "journal.json").read_text()))
        # Mark this recovery as live until removal, closing the interval
        # between releasing the OS claim and deleting the directory on Windows.
        (lock / "owner.json").write_text(json.dumps({"pid": os.getpid(), "token": "recovered"}))
    shutil.rmtree(lock)
    print("Recovered prior managed configuration; existing account data retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("command", choices=("validate-input", "manifest", "preflight", "scratch", "setup", "scale", "recover", "run-locked", "up", "guard", "version"))
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--host", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--count", default="2")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--language", choices=("bash", "powershell"), default="bash")
    args, trailing = parser.parse_known_args()
    root = args.root.resolve()
    if sys.version_info < (3, 9):
        raise PolicyError("Python 3.9+ is required for host policy.")
    if args.command == "version":
        print("Python " + sys.version.split()[0] + "; host policy available.")
        return
    env_file = args.env_file or Path(os.environ.get("CLAUDE_DOCKER_ENV_FILE", root / ".env"))
    env = environment(root, env_file)
    if args.command == "guard":
        lock = root / ".claude-docker-lifecycle"
        if lock.exists() and not os.environ.get("CLAUDE_DOCKER_LOCK_TOKEN"):
            raise PolicyError("Lifecycle operation in progress; retry after it finishes or run recover after interruption.")
        return
    if args.command == "recover":
        recover(root)
        return
    if args.command == "run-locked":
        with lifecycle_lock(root) as lock:
            owner = json.loads((lock / "owner.json").read_text())
            child_env = dict(os.environ, CLAUDE_DOCKER_LOCK_TOKEN=owner["token"])
            argv = trailing[1:] if trailing[:1] == ["--"] else trailing
            if not argv:
                raise PolicyError("run-locked requires a command.")
            child = subprocess.Popen(argv, env=child_env, cwd=root, start_new_session=os.name != "nt")
            handlers = {}
            def forward_signal(signum, _frame):
                if child.poll() is None:
                    if os.name == "nt":
                        child.send_signal(signum)
                    else:
                        os.killpg(child.pid, signum)
            try:
                for signum in (signal.SIGINT, signal.SIGTERM):
                    handlers[signum] = signal.signal(signum, forward_signal)
                code = child.wait()
            finally:
                for signum, handler in handlers.items():
                    signal.signal(signum, handler)
            if code:
                sys.exit(128 - code if code < 0 else code)
        return
    if args.command == "up":
        with lifecycle_lock(root):
            env = environment(root, env_file)
            model, manifest, cmd = resolved(root, root, env_file, env, host=True)
            print(json.dumps(manifest, indent=2), flush=True)
            create_state_directories(account_state_paths(model, env, root))
            prepare_dependency_volumes(model, cmd, env, root)
            worktree_metadata(env, root, create=True)
            argv = trailing[1:] if trailing[:1] == ["--"] else trailing
            run(cmd + ["up", "--detach"] + argv, env, root, 600)
        return
    if trailing:
        raise PolicyError("Unexpected host policy arguments.")
    if args.command == "scale":
        scale(root, args.count, args.language)
        return
    if args.command == "setup":
        if args.source is None:
            raise PolicyError("setup requires --source.")
        setup(root, env, args.source, args.count, args.dry_run)
        return
    if args.command == "scratch":
        per_account = budget(env, count_value(env.get("NUM_ACCOUNTS") or "2"))["per_account"]
        print("    tmpfs:")
        for path, size in per_account["scratch"].items():
            options = "mode=1777" if path == "/tmp" else "uid=${UID:-1000},gid=${GID:-1000},mode=0700"
            print("      - " + path + ":" + options + ",size=" + str(size))
        return
    if args.command == "validate-input":
        result = validate_inputs(env, root, args.host)
    elif args.command == "manifest":
        result = validate_model(json.load(sys.stdin), env, root, args.host)
    else:
        with lifecycle_lock(root):
            env = environment(root, env_file)
            _, result, _ = resolved(root, root, env_file, env, args.host)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (PolicyError, OSError, ValueError, KeyError, TypeError) as exc:
        # PolicyError messages are authored here. OSError may contain a path
        # with sensitive text, and parser exceptions may echo input values.
        print("Error: " + (str(exc) if isinstance(exc, PolicyError) else "Host policy could not read or validate its input."), file=sys.stderr)
        sys.exit(exc.exit_code if isinstance(exc, PolicyError) else 1)
