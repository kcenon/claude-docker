#!/usr/bin/env python3
"""Reproducible 1/2/4-account matrix; results describe measured readiness only."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time
from container_fixture import ContainerFixture, ROOT, policy

MODES = ("shared", "worktree", "isolated")
COUNTS = (1, 2, 4)
METRICS = {"startup_seconds": "seconds", "executable_ready_seconds": "seconds",
           "idle_memory_bytes": "bytes", "observed_peak_memory_bytes": "bytes",
           "workload_cpu_seconds": "CPU seconds", "workload_wall_seconds": "seconds"}

# Fixed filesystem/hash/test workload, with Node running inside the actual
# account container and using its actual workspace/cache/state mounts.
WORKLOAD = r'''
import json, os, pathlib, subprocess, sys, time
before = os.times(); start = time.perf_counter()
code = r"""
const fs = require('fs'), crypto = require('crypto');
const base = '.benchmark-' + process.argv[1]; fs.mkdirSync(base, {recursive:true});
const block = Buffer.alloc(32768, 42); let verified = 0;
for (let i=0;i<1000;i++) fs.writeFileSync(base + '/' + i, block);
for (let pass=0;pass<5;pass++) for (let i=0;i<1000;i++) {
 const data=fs.readFileSync(base+'/'+i);
 if(data.length!==32768) throw Error('fixture truncated');
 crypto.createHash('sha256').update(data).digest('hex'); verified++;
}
fs.mkdirSync('node_modules/.benchmark', {recursive:true});
fs.writeFileSync('node_modules/.benchmark/cache',block);
if(verified!==5000) throw Error('workload did not execute');
"""
subprocess.run(['node','-e',code,sys.argv[1]],check=True)
subprocess.run(['git','status','--porcelain'],check=True,stdout=subprocess.DEVNULL)
after=os.times()
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
print(json.dumps(dict(wall_seconds=time.perf_counter()-start,
 cpu_seconds=after.user+after.system+after.children_user+after.children_system-before.user-before.system-before.children_user-before.children_system,
 disk=dict(workspace=disk('.',('.git','node_modules')),git=disk(common),dependency=disk('node_modules'),state=disk(sys.argv[2])))))
'''


def summarize(samples):
    if len(samples) < 5:
        raise ValueError("At least five measured samples are required per matrix cell.")
    return {key: {"median": statistics.median(sample[key] for sample in samples),
                  "sample_variance": statistics.variance(sample[key] for sample in samples),
                  "samples": len(samples), "unit": unit} for key, unit in METRICS.items()}


def stats(fixture):
    identifiers = fixture.run(fixture.cmd + ["ps", "-q"]).split()
    if len(identifiers) != fixture.count:
        raise AssertionError("Expected every benchmark account to be running.")
    output = fixture.run(["docker", "stats", "--no-stream", "--format", "{{json .}}"] + identifiers)
    records = [json.loads(line) for line in output.splitlines() if line.strip()]
    if len(records) != fixture.count:
        raise AssertionError("Docker stats did not return all accounts.")
    return {"monotonic_seconds": time.monotonic(),
            "memory_bytes": sum(policy.size_bytes(row["MemUsage"].split("/")[0].strip()) for row in records),
            "cpu_percent": sum(float(row["CPUPerc"].rstrip("%")) for row in records)}


def source_fingerprint():
    digest = hashlib.sha256()
    paths = [ROOT / "Dockerfile", ROOT / "VERSION"]
    for directory in (ROOT / "scripts", ROOT / "tui/internal"):
        paths.extend(path for path in directory.rglob("*") if path.is_file() and "__pycache__" not in str(path))
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def measure_cell(mode, count, args):
    fixture = ContainerFixture(mode, count, args.runtime, args.image)
    try:
        fixture.prepare()
        started = time.perf_counter()
        fixture.up()
        cold_start = time.perf_counter() - started
        versions = [fixture.execute(i, fixture.spec["binary"], "--version").strip() for i in range(count)]
        # The first workload is cold-cache and reported separately. Subsequent
        # samples retain project/state/dependency data and use stopped containers.
        cold_workload = [json.loads(fixture.execute(i, "python3", "-c", WORKLOAD, policy.account_letter(i + 1), fixture.spec["containerConfigMount"], timeout=120)) for i in range(count)]
        samples = []
        for sample in range(args.samples):
            fixture.run(fixture.cmd + ["stop"], timeout=180)
            started = time.perf_counter()
            fixture.up()
            startup = time.perf_counter() - started
            for i in range(count):
                fixture.execute(i, fixture.spec["binary"], "--version")
            ready = time.perf_counter() - started
            idle = stats(fixture)
            observations, failures = [idle], []
            stop = threading.Event()
            def sample_memory():
                while not stop.is_set():
                    try:
                        observations.append(stats(fixture))
                    except Exception as error:
                        failures.append(type(error).__name__)
                        return
                    stop.wait(0.2)
            watcher = threading.Thread(target=sample_memory)
            watcher.start()
            workload_start = time.perf_counter()
            try:
                with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
                    futures = [pool.submit(fixture.execute, i, "python3", "-c", WORKLOAD, policy.account_letter(i + 1), fixture.spec["containerConfigMount"], timeout=120) for i in range(count)]
                    results = [json.loads(future.result()) for future in futures]
                    workload_elapsed = time.perf_counter() - workload_start
            finally:
                stop.set()
                watcher.join(timeout=130)
            if watcher.is_alive() or failures:
                raise AssertionError("Memory sampler failed or did not terminate.")
            samples.append({"sample": sample + 1, "startup_seconds": startup, "executable_ready_seconds": ready,
                            "idle_memory_bytes": idle["memory_bytes"], "observed_peak_memory_bytes": max(row["memory_bytes"] for row in observations),
                            "workload_cpu_seconds": sum(result["cpu_seconds"] for result in results),
                            "workload_wall_seconds": workload_elapsed,
                            "memory_observations": observations, "account_results": results})
        return {"mode": mode, "accounts": count, "runtime": args.runtime, "runtime_versions": versions,
                "setup_seconds": fixture.setup_seconds, "cold_start_seconds": cold_start, "cold_workload": cold_workload,
                "manifest": fixture.manifest, "samples": samples, "summary": summarize(samples)}
    finally:
        fixture.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", help="Prepared immutable image tag or digest (required for measurements)")
    parser.add_argument("--prepare-image", action="store_true", help="Measure a cached Docker build before the matrix")
    parser.add_argument("--runtime", choices=("claude", "codex", "gemini"), default="claude")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--output", type=Path, default=Path("isolation-benchmark.json"))
    parser.add_argument("--plan", action="store_true", help="Validate the matrix without Docker or persistent writes")
    parser.add_argument("--smoke", action="store_true", help="Measure only isolated/1 with five or more samples for CI")
    args = parser.parse_args()
    if args.samples < 5:
        parser.error("--samples must be at least 5")
    cells = [("isolated", 1)] if args.smoke else [(mode, count) for mode in MODES for count in COUNTS]
    if args.plan:
        print(json.dumps({"cells": cells, "planned_samples": len(cells) * args.samples, "executed_measurements": 0}, indent=2))
        return
    if not args.image:
        parser.error("Build an image, then pass --image with its tag or digest.")
    began = time.perf_counter()
    preparation = {"mode": "prebuilt image; build/pull cost excluded"}
    if args.prepare_image:
        policy.run(["docker", "build", "-t", args.image, str(ROOT)], timeout=1800)
        preparation = {"mode": "docker build with existing layer cache", "build_seconds": time.perf_counter() - began}
    inspect_started = time.perf_counter()
    image = json.loads(policy.run(["docker", "image", "inspect", args.image]))[0]
    info = json.loads(policy.run(["docker", "info", "--format", "{{json .}}"], timeout=10))
    report = {"schema": 1, "source_commit": policy.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).strip(),
              "source_fingerprint_sha256": source_fingerprint(), "image_id": image["Id"], "image_digests": image.get("RepoDigests", []),
              "image_preparation": dict(preparation, inspection_seconds=time.perf_counter() - inspect_started),
              "compose_version": policy.run(["docker", "compose", "version", "--short"]).strip(), "engine_version": info["ServerVersion"],
              "platform": platform.platform(), "docker_capacity": {"cpus": info["NCPU"], "memory_bytes": info["MemTotal"]},
              "workload": "1000 x 32 KiB writes; 5000 Node SHA256/read checks; private dependency write; git status",
              "readiness": "container running then installed CLI --version; no authenticated session",
              "sampling": "5+ warm stop/up samples; cold setup/start/workload separate; Docker stats observed peaks may miss short spikes; actual poll timestamps included",
              "disk_accounting": "Per-account apparent/allocated bytes; shared/worktree Git storage repeats logically and must not be summed as physical disk. Backend compression/sparse VM effects are not measured.",
              "budget_review": "pending", "scope": "smoke" if args.smoke else "full matrix", "cells": []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for mode, count in cells:
        report["cells"].append(measure_cell(mode, count, args))
        report["executed_cells"] = len(report["cells"])
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print("Measured " + mode + "/" + str(count), flush=True)
    assert len(report["cells"]) == len(cells)
    print("benchmark: executed_cells=" + str(len(cells)) + " measured_samples=" + str(len(cells) * args.samples))


if __name__ == "__main__":
    main()
