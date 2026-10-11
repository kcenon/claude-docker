#!/usr/bin/env python3
"""Exercise the image reference contract against disposable tracked files."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from image_doc_refs import check


class ImageDocRefsTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "docs").mkdir()
        (self.root / "docs/PAGE.md").write_text(
            "# Page\n## Heap `headroom`!\n## Heap `headroom`!\n"
            "```md\n## Hidden\n```\n<a id=\"explicit\"></a>\n")

    def scan(self, content, name="Dockerfile"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        subprocess.run(["git", "-C", str(self.root), "add", name], check=True)
        return check(self.root)

    def test_valid_anchors_share_readme_rules(self):
        count, fragments, errors = self.scan(
            "# docs/PAGE.md docs/PAGE.md#heap-headroom.\n"
            "# docs/PAGE.md#heap-headroom-1 docs/PAGE.md#explicit\n")
        self.assertEqual((count, fragments, errors), (4, 3, []))

    def test_missing_page_and_anchor_name_citing_file_and_line(self):
        _, _, errors = self.scan("# docs/MISSING.md\n# docs/PAGE.md#hidden\n")
        self.assertIn("Dockerfile:1: missing docs page: docs/MISSING.md", errors)
        self.assertIn("Dockerfile:2: missing docs anchor: docs/PAGE.md#hidden", errors)

    def test_external_exception_is_narrow(self):
        count, _, errors = self.scan(
            "# See claude-config docs/CLAUDE_DOCKER_CONTRACT.md for the contract.\n"
            "# docs/PAGE.md\n# docs/CLAUDE_DOCKER_CONTRACT.md\n")
        self.assertEqual(count, 2)
        self.assertEqual(len(errors), 1)
        self.assertIn("Dockerfile:3:", errors[0])

    def test_library_and_entrypoint_are_scanned(self):
        self.scan("# docs/PAGE.md\n", "scripts/entrypoint.sh")
        count, _, errors = self.scan("# docs/MISSING.md\n", "scripts/lib/nested/helper.py")
        self.assertEqual(count, 2)
        self.assertIn("scripts/lib/nested/helper.py:1:", errors[0])

    def test_empty_scan_is_failure(self):
        self.assertIn("vacuous", self.scan("# No references\n")[2][0])

    def test_untracked_files_do_not_affect_inventory(self):
        (self.root / "scripts/lib").mkdir(parents=True)
        (self.root / "scripts/lib/local.sh").write_text("# docs/MISSING.md\n")
        self.assertEqual(self.scan("# docs/PAGE.md\n"), (1, 0, []))


if __name__ == "__main__":
    unittest.main()
