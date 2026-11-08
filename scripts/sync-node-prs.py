#!/usr/bin/env python3
"""Complete FROM-only Dependabot PRs using trusted base-branch generators."""

import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import urllib.parse
import urllib.request

spec = importlib.util.spec_from_file_location("image_sync", Path(__file__).with_name("sync-image-inputs.py"))
image_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image_sync)

ALLOWED = {"Dockerfile", "VERSION", "README.md", "docs/MAINTENANCE.md",
           "docker-compose.yml", "docker-compose.linux.yml",
           "docker-compose.worktree.yml", "docker-compose.isolated.yml"}
SYNC_MESSAGE = "build(image): synchronize base image version and references"


def api(repository, path, data=None, method=None):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/{path}",
        data=json.dumps(data).encode() if data is not None else None,
        method=method,
        headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                 "Accept": "application/vnd.github+json", "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
    return json.loads(body) if body else None


def dispatch_checks(repository, pr, head):
    runs = api(repository, "actions/runs?event=workflow_dispatch&head_sha=" + head)["workflow_runs"]
    for workflow in ("ci.yml", "doc-audit.yml", "isolation-evidence.yml"):
        if any(run["path"] == ".github/workflows/" + workflow for run in runs):
            continue
        payload = {"ref": pr["head"]["ref"]}
        if workflow == "ci.yml":
            payload["inputs"] = {"base_sha": pr["base"]["sha"]}
        api(repository, f"actions/workflows/{workflow}/dispatches", payload)


def synchronize_pr(repository, root, pr):
    if (pr["user"]["login"] != "dependabot[bot]" or
            not pr["head"]["repo"] or pr["head"]["repo"]["full_name"] != repository):
        return
    number, head = pr["number"], pr["head"]["sha"]
    files = api(repository, f"pulls/{number}/files?per_page=100")
    if [entry["filename"] for entry in files] != ["Dockerfile"]:
        # Retry a dispatch that failed after the synchronization commit landed.
        # Existing runs (including failures) are left for normal review/reruns.
        commit = api(repository, "git/commits/" + head)
        if (commit["message"] == SYNC_MESSAGE and
                {entry["filename"] for entry in files} <= ALLOWED):
            dispatch_checks(repository, pr, head)
        print(f"#{number}: already synchronized or has manual changes; leaving it intact")
        return
    if pr["base"]["sha"] != subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip():
        raise ValueError("Base moved; rerun synchronization against the current base")
    content = api(repository, "contents/Dockerfile?ref=" + head)
    proposed = base64.b64decode(content["content"]).decode()
    image = image_sync.validate_update((root / "Dockerfile").read_text(), proposed)
    image_sync.verify_digest(image)
    image_sync.synchronize(root, image)
    changed = subprocess.check_output(["git", "-C", str(root), "diff", "--name-only"], text=True).splitlines()
    if not changed or not set(changed) <= ALLOWED:
        raise ValueError("Unexpected synchronization output")
    tree = api(repository, "git/trees", {
        "base_tree": api(repository, "git/commits/" + head)["tree"]["sha"],
        "tree": [{"path": name, "mode": "100644", "type": "blob",
                  "content": (root / name).read_text()} for name in changed]})
    commit = api(repository, "git/commits", {
        "message": SYNC_MESSAGE,
        "tree": tree["sha"], "parents": [head]})
    branch = pr["head"]["ref"]
    # A non-forced update rejects a concurrently advanced PR branch.
    api(repository, "git/refs/heads/" + urllib.parse.quote(branch, safe=""),
        {"sha": commit["sha"], "force": False}, method="PATCH")
    print(f"#{number}: synchronized {image} at {commit['sha']}")
    # GITHUB_TOKEN writes do not reliably trigger CI. Dispatch checks explicitly
    # on the new head so all checks attach to the commit that will be merged.
    dispatch_checks(repository, pr, commit["sha"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--base", choices=("main", "develop"), required=True)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    if subprocess.check_output(["git", "-C", str(args.root), "status", "--porcelain"], text=True).strip():
        raise ValueError("Use a clean disposable checkout for PR synchronization")
    pulls = api(args.repository, f"pulls?state=open&base={args.base}&per_page=100")
    for pr in pulls:
        try:
            synchronize_pr(args.repository, args.root.resolve(), pr)
        finally:
            # Only this disposable Actions checkout is reset, never a user's tree.
            subprocess.run(["git", "-C", str(args.root), "restore", "--worktree", "."], check=True)


if __name__ == "__main__":
    main()
