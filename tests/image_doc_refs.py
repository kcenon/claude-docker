#!/usr/bin/env python3
"""Validate local docs references in tracked image inputs (#420)."""

from pathlib import Path
import argparse
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from readme_lint import anchors, base_image, prose_blocks  # noqa: E402


REFERENCE = re.compile(r"(?<![\w/])docs/[\w./-]+\.md(?:#[\w-]+)?")


def check(root):
    files = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-z", "--", "Dockerfile",
         "scripts/entrypoint.sh", "scripts/lib/"], text=True).split("\0")
    errors, count, fragments = [], 0, 0
    for name in filter(None, files):
        for line_no, line in enumerate((root / name).read_text(encoding="utf-8").splitlines(), 1):
            for match in REFERENCE.finditer(line):
                target = match[0]
                # This single explicitly attributed reference belongs to the
                # companion repository, not to this checkout.
                if (target == "docs/CLAUDE_DOCKER_CONTRACT.md" and
                        re.search(r"\bclaude-config\s+$", line[:match.start()])):
                    continue
                count += 1
                page, _, fragment = target.partition("#")
                fragments += bool(fragment)
                path = (root / page).resolve()
                if root.resolve() not in path.parents or not path.is_file():
                    errors.append(f"{name}:{line_no}: missing docs page: {target}")
                elif fragment and fragment not in anchors(path.read_text(encoding="utf-8")):
                    errors.append(f"{name}:{line_no}: missing docs anchor: {target}")
    if not count:
        errors.append("image inputs: no local docs references found; check would be vacuous")
    return count, fragments, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--base-tags", action="store_true")
    args = parser.parse_args()
    root = args.root
    try:
        if args.base_tags:
            errors = check_base_tags(root)
        else:
            count, fragments, errors = check(root)
    except (OSError, UnicodeError, subprocess.CalledProcessError) as error:
        print(f"image docs references: input error: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(error)
    if args.base_tags:
        print("Checked current Node base references against FROM.")
    else:
        print(f"Checked {count} local image docs references ({fragments} with anchors).")
    return int(bool(errors))


def check_base_tags(root):
    image, error = base_image(root)
    if error:
        return [f"Dockerfile:1: {error}"]
    errors = []
    for name, minimum in (("Dockerfile", 2), ("docs/MAINTENANCE.md", 1)):
        text = (root / name).read_text(encoding="utf-8")
        if name.endswith(".md"):
            # Procedures may show historical tags in fenced examples; only
            # current declarations in visible prose are compared with FROM.
            text, _ = prose_blocks(text)
        count = 0
        for line_no, line in enumerate(text.splitlines(), 1):
            if name == "Dockerfile" and not line.lstrip().startswith("#"):
                continue
            for match in re.finditer(r"\bnode:[0-9]+\.[0-9]+\.[0-9]+[\w.-]*", line):
                count += 1
                if match[0] != image:
                    errors.append(f"{name}:{line_no}: base tag {match[0]} differs from FROM {image}")
        if count < minimum:
            errors.append(f"{name}:1: expected at least {minimum} current Node base references, found {count}")
    return errors


if __name__ == "__main__":
    sys.exit(main())
