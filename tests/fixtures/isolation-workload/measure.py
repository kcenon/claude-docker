"""Execute the offline npm build/test fixture inside one account container."""
import json
import os
from pathlib import Path
import shutil
import re
import subprocess
import sys
import time
from npm_command import npm_command

workspace = Path.cwd()
package = workspace / "node_modules/.issue335-package"
package.mkdir(parents=True, exist_ok=True)
for source in Path(__file__).resolve().parent.iterdir():
    if source.name in ("package.json", "package-lock.json", "build.cjs", "test.cjs"):
        shutil.copyfile(source, package / source.name)
shutil.copytree(Path(__file__).resolve().parent / "vendor", package / "vendor", dirs_exist_ok=True)
environment = dict(os.environ, ISSUE335_OUTPUT_ROOT=str(workspace / (".benchmark-" + sys.argv[1])))
if os.environ.get("ISSUE335_USE_DEFAULT_NPM_CACHE") != "1":
    # A comparable persistent cache in every mode, including arbitrary Linux
    # host UIDs that cannot write image-owned home directories in shared mode.
    environment["npm_config_cache"] = str(package / ".npm-cache")
before = os.times()
started = time.perf_counter()
for arguments in (["ci", "--offline", "--no-audit", "--no-fund"], ["run", "build"], ["test"]):
    command = npm_command() + arguments
    result = subprocess.run(command, cwd=package, env=environment, capture_output=True, text=True, timeout=120)
    if result.returncode:
        codes = sorted(set(re.findall(r"\bE[A-Z]{3,20}\b", result.stderr)))
        raise RuntimeError("Offline npm workload failed at " + arguments[0] + "; exit " + str(result.returncode) + "; " + ",".join(codes))
    if arguments[0] == "test" and "ISSUE335_WORKLOAD_OK" not in result.stdout:
        raise RuntimeError("Package tests did not produce their completion marker")
subprocess.run(["git", "status", "--porcelain"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
after = os.times()
print(json.dumps({"wall_seconds": time.perf_counter() - started,
                  "cpu_seconds": sum(after[:4]) - sum(before[:4]),
                  "verified_reads": 5000, "package_tests": 3}))
