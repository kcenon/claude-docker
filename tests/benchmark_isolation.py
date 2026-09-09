#!/usr/bin/env python3
"""Measure the nine-cell matrix; retain failures and validate completed evidence."""
import argparse
import concurrent.futures
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import sys
import threading
import time
from benchmark_report import (COUNTS, METRICS, MODES, aggregate_disk, disk_summary,
                              summarize, validate)
from container_fixture import ContainerFixture, ROOT, policy

RESOURCE_PROBE = r'''
import json, os, pathlib
root = pathlib.Path('/sys/fs/cgroup')
v2 = (root/'memory.current').exists()
base = root if v2 else root/'memory'
def read(name, default=None):
 p=base/name
 return int(p.read_text().strip()) if p.exists() else default
events = dict(line.split() for line in (base/'memory.events').read_text().splitlines()) if v2 else {}
pids = root if v2 else root/'pids'
print(json.dumps(dict(memory_bytes=read('memory.current' if v2 else 'memory.usage_in_bytes'),
 memory_peak_bytes=read('memory.peak' if v2 else 'memory.max_usage_in_bytes'),
 oom_kills=int(events['oom_kill']) if 'oom_kill' in events else None, cgroup_version=2 if v2 else 1,
 pids=int((pids/'pids.current').read_text()), pids_peak=int((pids/'pids.peak').read_text()) if (pids/'pids.peak').exists() else None,
 scratch={str(p):__import__('shutil').disk_usage(p).used for p in map(pathlib.Path, ['/tmp','/home/node/.config','/home/node/.cache','/home/node/.npm','/home/node/.agents'])} if os.environ.get('ISOLATION_MODE') == 'isolated' else {})))
'''

DISK_PROBE = r'''
import json, os, pathlib, subprocess, sys
def disk(path, exclude=()):
 apparent=allocated=files=0
 for base, dirs, names in os.walk(path,followlinks=False):
  dirs[:]=[d for d in dirs if d not in exclude and not pathlib.Path(base,d).is_symlink()]
  for name in names:
   p=pathlib.Path(base,name)
   if p.is_symlink(): continue
   stat=p.stat(); apparent+=stat.st_size; allocated+=getattr(stat,'st_blocks',0)*512; files+=1
 return dict(apparent_bytes=apparent,allocated_bytes=allocated,files=files)
common=subprocess.check_output(['git','rev-parse','--git-common-dir'],text=True).strip()
print(json.dumps(dict(workspace=disk('.',('.git','node_modules')),git=disk(common),dependency=disk('node_modules'),state=disk(sys.argv[1]))))
'''


def now():
    return datetime.now(timezone.utc).isoformat()


def source_fingerprint():
    digest = hashlib.sha256()
    paths = [ROOT / "Dockerfile", ROOT / "VERSION"]
    if (ROOT / ".dockerignore").is_file():
        paths.append(ROOT / ".dockerignore")
    for name in ("scripts", "tui/internal", "tests"):
        paths.extend(path for path in (ROOT / name).rglob("*") if path.is_file()
                     and not {"__pycache__", "node_modules"} & set(path.parts)
                     and (path.suffix in (".py", ".sh", ".ps1", ".psm1", ".cmd", ".go", ".cjs")
                          or "isolation-workload" in path.parts or path.name in ("runtimes.json", "claude-docker")))
    for path in sorted(set(paths)):
        if path.name.startswith(".env") or path.suffix in (".pyc", ".pyo"):
            continue
        relative, content = str(path.relative_to(ROOT)).replace(os.sep, "/").encode(), path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big") + relative)
        digest.update(len(content).to_bytes(8, "big") + content)
    return digest.hexdigest()


def stats(fixture):
    began = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=fixture.count) as pool:
        rows = list(pool.map(lambda i: json.loads(fixture.execute(i, "python3", "-c", RESOURCE_PROBE)),
                             range(fixture.count)))
    if len(rows) != fixture.count:
        raise AssertionError("Resource sampler did not return all accounts.")
    if any(row.get("oom_kills") is None for row in rows):
        raise AssertionError("Required OOM counter unavailable; this profile requires cgroup v2.")
    return {"started": began, "finished": time.monotonic(), "accounts": rows,
            "memory_bytes": sum(row["memory_bytes"] for row in rows)}


def cli_stats(fixture):
    identifiers = fixture.run(fixture.cmd + ["ps", "-q"]).split()
    if len(identifiers) != fixture.count:
        raise AssertionError("Expected every benchmark account to be running.")
    rows = [json.loads(line) for line in fixture.run(
        ["docker", "stats", "--no-stream", "--format", "{{json .}}"] + identifiers).splitlines() if line.strip()]
    if len(rows) != fixture.count:
        raise AssertionError("Docker stats did not return all accounts.")
    return {"cache_adjusted_memory_bytes": sum(policy.size_bytes(row["MemUsage"].split("/")[0].strip()) for row in rows),
            "cpu_percent": sum(float(row["CPUPerc"].rstrip("%")) for row in rows)}


def workloads(fixture):
    def one(index):
        workspace = fixture.model["services"][fixture.services[index]]["working_dir"]
        result = json.loads(fixture.execute(index, "python3", workspace + "/.isolation-workload/measure.py",
                                            policy.account_letter(index + 1), timeout=180))
        return dict(result, account=index + 1)
    with concurrent.futures.ThreadPoolExecutor(max_workers=fixture.count) as pool:
        return list(pool.map(one, range(fixture.count)))


def inventories(fixture, accounts):
    # Work has finished in every account before collecting shared-source sizes.
    common = {}
    for index, account in enumerate(accounts):
        sizes = json.loads(fixture.execute(index, "python3", "-c", DISK_PROBE, fixture.spec["containerConfigMount"]))
        for kind, values in sizes.items():
            shared = kind == "workspace" and fixture.mode == "shared" or kind == "git" and fixture.mode in ("shared", "worktree")
            identity = kind + (":shared" if shared else ":" + str(index + 1))
            if shared:
                # One physical source; use one observation rather than summing
                # repeated logical views or racing background state writes.
                values = common.setdefault(identity, values)
            sizes[kind] = dict(values, source_id=identity)
        account["disk"] = sizes


def sampled_workload(fixture):
    idle_cli = cli_stats(fixture)
    idle = stats(fixture)
    observations, failures = [], []
    stop = threading.Event()
    def observe():
        while not stop.is_set():
            try:
                observations.append(stats(fixture))
            except Exception as error:
                failures.append(type(error).__name__)
                return
            stop.wait(0.1)
    started = time.monotonic()
    watcher = threading.Thread(target=observe, daemon=True)
    watcher.start()
    try:
        accounts = workloads(fixture)
        finished = time.monotonic()
    finally:
        stop.set()
        watcher.join(timeout=65)
    if watcher.is_alive() or failures:
        raise AssertionError("Memory sampler failed or did not terminate.")
    covered = [row for row in observations if started <= row["started"] <= row["finished"] <= finished]
    if not covered:
        raise AssertionError("No memory observation completed during the workload.")
    after = stats(fixture)
    oom_delta = sum(row["oom_kills"] for row in after["accounts"]) - sum(row["oom_kills"] for row in idle["accounts"])
    if oom_delta:
        raise AssertionError("A benchmark account was OOM killed.")
    inventories(fixture, accounts)
    return {"idle_memory_bytes": idle["memory_bytes"],
            "observed_peak_memory_bytes": max([idle["memory_bytes"]] + [row["memory_bytes"] for row in covered]),
            "workload_cpu_seconds": sum(account["cpu_seconds"] for account in accounts),
            "workload_wall_seconds": finished - started, "workload_started": started, "workload_finished": finished,
            "memory_observations": observations, "idle_cgroup": idle, "after_cgroup": after,
            "idle_docker_cli": idle_cli, "oom_kill_delta": oom_delta, "account_results": accounts,
            "physical_disk": aggregate_disk(accounts)}


def measure_cell(mode, count, args, cell=None, checkpoint=lambda: None):
    cell = cell if cell is not None else {}
    cell.update(mode=mode, accounts=count, runtime=args.runtime, image_id=args.image,
                status="running", cleanup="pending", samples=[])
    fixture = ContainerFixture(mode, count, args.runtime, args.image)
    try:
        cell["phase"] = "fixture_prepare"
        fixture.prepare()
        cell.update(setup_seconds=fixture.setup_seconds, manifest=fixture.manifest)
        began = time.perf_counter()
        cell["phase"] = "initial_start"
        fixture.up()
        cell["initial_start_seconds"] = time.perf_counter() - began
        identifiers = fixture.run(fixture.cmd + ["ps", "-q"]).split()
        if len(identifiers) != count or any(fixture.run(["docker", "inspect", "--format", "{{.Image}}", cid]).strip() != args.image for cid in identifiers):
            raise AssertionError("Running image identity or account count differs from the measurement plan.")
        cell["runtime_versions"] = [fixture.execute(i, fixture.spec["binary"], "--version").strip() for i in range(count)]
        cell["tool_versions"] = [{"node": fixture.execute(i, "node", "--version").strip(),
                                  "npm": fixture.execute(i, "npm", "--version").strip()} for i in range(count)]
        cell["phase"] = "initial_workload"
        cell["initial_workload"] = workloads(fixture)
        checkpoint()
        for index in range(args.samples):
            cell["phase"] = "sample_" + str(index + 1)
            fixture.run(fixture.cmd + ["stop"], timeout=180)
            began = time.perf_counter()
            fixture.up()
            startup = time.perf_counter() - began
            for i in range(count):
                fixture.execute(i, fixture.spec["binary"], "--version")
            ready = time.perf_counter() - began
            sample = sampled_workload(fixture)
            sample.update(sample=index + 1, startup_seconds=startup, executable_ready_seconds=ready)
            cell["samples"].append(sample)
            checkpoint()
        cell["summary"] = summarize(cell["samples"])
        cell["disk_summary"] = disk_summary(cell["samples"])
        cell["status"] = "complete"
    except BaseException:
        cell["status"] = "failed"
        raise
    finally:
        try:
            fixture.close()
            cell["cleanup"] = "passed"
        except BaseException:
            cell.update(status="failed", cleanup="failed")
            raise
        finally:
            checkpoint()
    return cell


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".next")
    temporary.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    os.replace(temporary, path)


def collect(args, report):
    def checkpoint():
        report["executed_cells"] = sum(cell["status"] == "complete" and cell["cleanup"] == "passed" for cell in report["cells"])
        write_report(args.output, report)
    checkpoint()
    try:
        for mode, count in report["planned_cells"]:
            cell = {"mode": mode, "accounts": count, "status": "pending", "cleanup": "pending"}
            report["cells"].append(cell)
            checkpoint()
            measure_cell(mode, count, args, cell, checkpoint)
            print("Measured " + mode + "/" + str(count), flush=True)
        report.update(status="complete", finished_at=now())
        report["executed_cells"] = len(report["cells"])
        validate(report)
    except BaseException as error:
        report.update(status="incomplete", finished_at=now())
        diagnostic = re.search(r"Offline npm workload failed at [a-z]+; exit [0-9]+; [A-Z,]*", str(error))
        report["failures"].append({"stage": report["cells"][-1].get("phase", "measurement") if report["cells"] else "measurement",
                                   "type": type(error).__name__, "workload_error": diagnostic.group(0) if diagnostic else None})
        raise
    finally:
        checkpoint()
    print("benchmark: executed_cells=" + str(len(report["cells"])) + " measured_samples=" + str(len(report["cells"]) * args.samples))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", help="Prepared image; resolved to its immutable ID before collection")
    parser.add_argument("--prepare-image", action="store_true", help="Measure a cached Docker build before the matrix")
    parser.add_argument("--runtime", choices=("claude", "codex", "gemini"), default="claude")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--output", type=Path, default=Path("isolation-benchmark.json"))
    parser.add_argument("--plan", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    if args.samples < 5:
        parser.error("--samples must be at least 5")
    cells = [["isolated", 1]] if args.smoke else [[mode, count] for mode in MODES for count in COUNTS]
    if args.plan:
        print(json.dumps({"cells": cells, "planned_samples": len(cells) * args.samples, "executed_measurements": 0}, indent=2))
        return
    if not args.image:
        parser.error("Build an image, then pass --image.")
    started_at = now()
    began = time.perf_counter()
    preparation = {"mode": "prebuilt image; build/pull cost excluded"}
    if args.prepare_image:
        policy.run(["docker", "build", "-t", args.image, str(ROOT)], timeout=1800)
        preparation = {"mode": "docker build with existing layer cache", "build_seconds": time.perf_counter() - began}
    image = json.loads(policy.run(["docker", "image", "inspect", args.image]))[0]
    args.image = image["Id"]
    info = json.loads(policy.run(["docker", "info", "--format", "{{json .}}"], timeout=10))
    report = {"schema": 2, "status": "running", "started_at": started_at,
              "source_commit": policy.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).strip(),
              "source_dirty": bool(policy.run(["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=normal"]).strip()),
              "source_fingerprint_sha256": source_fingerprint(), "image_id": args.image,
              "image_digests": image.get("RepoDigests", []), "image_preparation": preparation,
              "compose_version": policy.run(["docker", "compose", "version", "--short"]).strip(),
              "engine_version": info["ServerVersion"], "platform": platform.platform(), "architecture": platform.machine(),
              "daemon": {"os": info["OperatingSystem"], "kernel": info["KernelVersion"],
                         "architecture": info["Architecture"], "driver": info["Driver"],
                         "security_options": info.get("SecurityOptions", []), "cgroup_version": info.get("CgroupVersion", "unknown")},
              "docker_capacity": {"cpus": info["NCPU"], "memory_bytes": info["MemTotal"]},
              "runtime": args.runtime, "workload": "npm-local-build-test-v1",
              "readiness": "container running then installed CLI --version; no authenticated session",
              "sampling": "5+ stop/up samples; npm uses an explicit private persistent dependency-volume cache in every mode; tmpfs cleared; initial setup/start/workload separate; initial and measured work concurrent across accounts; host page caches not flushed; cgroup sampling timestamps delimit observed peaks; disk collection excluded from workload time",
              "disk_accounting": "Logical per-account bytes and category totals deduplicated by physical source; Linux filesystem apparent/allocated bytes exclude VM sparse allocation/compression",
              "budget_review": "pending", "scope": "smoke" if args.smoke else "full matrix",
              "planned_cells": cells, "samples_per_cell": args.samples, "cells": [], "failures": []}
    def interrupted(signum, _frame):
        raise InterruptedError("Benchmark interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    try:
        collect(args, report)
    except (Exception, KeyboardInterrupt) as error:
        print("Benchmark incomplete: " + type(error).__name__ + "; inspect the retained report.", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
