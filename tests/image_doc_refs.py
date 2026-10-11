#!/usr/bin/env python3
"""Validate local docs references in tracked image inputs (#420)."""

from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from readme_lint import anchors  # noqa: E402


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
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    try:
        count, fragments, errors = check(root)
    except (OSError, UnicodeError, subprocess.CalledProcessError) as error:
        print(f"image docs references: input error: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(error)
    print(f"Checked {count} local image docs references ({fragments} with anchors).")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
