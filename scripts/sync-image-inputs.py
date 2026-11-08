#!/usr/bin/env python3
"""Synchronize a pinned Node base, the image version, docs and Compose defaults."""

import argparse
from datetime import date
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request

NODE_FROM = re.compile(r"^FROM (node:(\d+)\.\d+\.\d+-slim@sha256:[0-9a-f]{64})$", re.M)


def node_image(dockerfile):
    matches = list(NODE_FROM.finditer(dockerfile))
    if len(matches) != 1:
        raise ValueError("Expected one digest-pinned node:<version>-slim FROM line")
    return matches[0][1]


def validate_update(before, after):
    old, new = node_image(before), node_image(after)
    if after != before.replace("FROM " + old, "FROM " + new, 1):
        raise ValueError("Automatic synchronization only accepts a FROM-only change")
    old_version = tuple(map(int, old.split(":", 1)[1].split("-", 1)[0].split(".")))
    new_version = tuple(map(int, new.split(":", 1)[1].split("-", 1)[0].split(".")))
    if new_version[0] != old_version[0] or new_version < old_version:
        raise ValueError("Automatic synchronization refuses major changes and downgrades")
    return new


def verify_digest(image):
    tag, digest = image.removeprefix("node:").split("@")
    for variant in (tag, tag.replace("-slim", "-trixie-slim")):
        url = "https://hub.docker.com/v2/repositories/library/node/tags/" + variant
        with urllib.request.urlopen(url, timeout=30) as response:
            actual = json.load(response).get("digest")
        if actual != digest:
            raise ValueError(f"Docker Hub digest mismatch for {variant}: {actual}")


def next_version(previous, today=None):
    # Multiple images on the same day still need distinct local Docker tags.
    today = (today or date.today()).strftime("%Y.%m.%d")
    if not re.fullmatch(r"\d{4}\.\d{2}\.\d{2}(?:\.[1-9]\d*)?", previous):
        raise ValueError("VERSION must be YYYY.MM.DD or YYYY.MM.DD.N")
    day = previous[:10]
    if day > today:
        raise ValueError("VERSION is in the future")
    if day < today:
        return today
    revision = int(previous[11:]) if len(previous) > 10 else 0
    return f"{today}.{revision + 1}"


def synchronize(root, image, version=None):
    dockerfile = (root / "Dockerfile").read_text()
    previous_image = node_image(dockerfile)
    validate_update(dockerfile, dockerfile.replace("FROM " + previous_image, "FROM " + image, 1))
    previous_version = (root / "VERSION").read_text().strip()
    version = version or next_version(previous_version)
    if version == previous_version:
        raise ValueError("A different image must get a new VERSION")
    old_tag, new_tag = previous_image.split("@")[0], image.split("@")[0]
    for name in ("Dockerfile", "README.md", "docs/MAINTENANCE.md"):
        path = root / name
        text = path.read_text().replace(old_tag, new_tag)
        if name == "Dockerfile":
            text = text.replace("FROM " + new_tag + "@" + previous_image.split("@")[1], "FROM " + image, 1)
        elif name == "README.md":
            text = text.replace(f"[`{previous_version}`](VERSION)", f"[`{version}`](VERSION)")
        path.write_text(text)
    (root / "VERSION").write_text(version + "\n")
    # Ignore installation config and exported generator inputs. Nothing reads,
    # deletes or rewrites a maintainer's .env while generating tracked defaults.
    environment = dict(os.environ)
    keys = set(re.findall(r"^[ \t]*(?:#[ \t]*)?([A-Za-z_][A-Za-z0-9_]*)=",
                          (root / ".env.example").read_text(), re.M))
    for key in keys | {"CLAUDE_DOCKER_LOCK_TOKEN", "CLAUDE_DOCKER_ENV_FILE"}:
        environment.pop(key, None)
    subprocess.run(["bash", str(root / "scripts/generate-compose.sh"),
                    "--env-file", os.devnull, "--output-dir", str(root)],
                   env=environment, check=True, cwd=root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--image", required=True)
    parser.add_argument("--version")
    args = parser.parse_args()
    verify_digest(args.image)
    synchronize(args.root.resolve(), args.image, args.version)


if __name__ == "__main__":
    main()
