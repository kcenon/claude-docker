#!/usr/bin/env python3
"""A FROM-only update becomes a consistent image without reading local config."""

from datetime import date
import base64
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from image_doc_refs import check_base_tags

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("image_sync", ROOT / "scripts/sync-image-inputs.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
pr_spec = importlib.util.spec_from_file_location("pr_sync", ROOT / "scripts/sync-node-prs.py")
pr_sync = importlib.util.module_from_spec(pr_spec)
pr_spec.loader.exec_module(pr_sync)
OLD = "node:26.10.0-slim@sha256:" + "a" * 64
NEW = "node:26.13.0-slim@sha256:" + "b" * 64


class ImageSyncTests(unittest.TestCase):
    def test_automation_ignores_forks_and_non_bot_prs(self):
        for author, repository in (("maintainer", "owner/repo"), ("dependabot[bot]", "fork/repo")):
            pr = {"user": {"login": author}, "head": {"repo": {"full_name": repository}}}
            with patch.object(pr_sync, "api") as api:
                pr_sync.synchronize_pr("owner/repo", ROOT, pr)
                api.assert_not_called()

    def test_automation_never_writes_or_runs_a_modified_pr_script(self):
        pr = {"number": 1, "user": {"login": "dependabot[bot]"},
              "head": {"repo": {"full_name": "owner/repo"}, "sha": "head"},
              "base": {"sha": "base"}}
        proposed = f"FROM {NEW}\nRUN echo untrusted\n"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Dockerfile").write_text(f"FROM {OLD}\n")
            responses = [[{"filename": "Dockerfile"}],
                         {"content": base64.b64encode(proposed.encode()).decode()}]
            with patch.object(pr_sync, "api", side_effect=responses) as api, \
                    patch.object(pr_sync.subprocess, "check_output", return_value="base\n"), \
                    patch.object(pr_sync.image_sync, "synchronize") as generate:
                with self.assertRaisesRegex(ValueError, "FROM-only"):
                    pr_sync.synchronize_pr("owner/repo", root, pr)
                generate.assert_not_called()
                self.assertTrue(all(len(call.args) == 2 for call in api.call_args_list))

    def test_dispatch_retries_only_missing_workflows_on_the_new_head(self):
        pr = {"head": {"ref": "dependabot/docker/develop/node"}, "base": {"sha": "base"}}
        responses = [{"workflow_runs": [{"path": ".github/workflows/doc-audit.yml"}]}, None, None]
        with patch.object(pr_sync, "api", side_effect=responses) as api:
            pr_sync.dispatch_checks("owner/repo", pr, "new-head")
        calls = api.call_args_list
        self.assertIn("head_sha=new-head", calls[0].args[1])
        self.assertEqual(calls[1].args[2]["inputs"], {"base_sha": "base"})
        self.assertEqual(calls[2].args[1], "actions/workflows/isolation-evidence.yml/dispatches")

    def test_only_a_from_change_is_eligible(self):
        before = f"# Base: {OLD.split('@')[0]}\nFROM {OLD}\nRUN echo trusted\n"
        after = before.replace("FROM " + OLD, "FROM " + NEW)
        self.assertEqual(sync.validate_update(before, after), NEW)
        with self.assertRaisesRegex(ValueError, "FROM-only"):
            sync.validate_update(before, after + "RUN echo unexpected\n")
        for image in (NEW.replace("26.13", "27.13"), NEW.replace("26.13", "26.9")):
            with self.assertRaisesRegex(ValueError, "major changes and downgrades"):
                sync.validate_update(before, before.replace("FROM " + OLD, "FROM " + image))

    def test_daily_revisions_do_not_reuse_an_image_tag(self):
        today = date(2026, 11, 8)
        self.assertEqual(sync.next_version("2026.10.11", today), "2026.11.08")
        self.assertEqual(sync.next_version("2026.11.08", today), "2026.11.08.1")
        self.assertEqual(sync.next_version("2026.11.08.1", today), "2026.11.08.2")
        with self.assertRaises(ValueError):
            sync.next_version("2026.11.09", today)

    @unittest.skipIf(os.name == "nt", "The scheduled synchronizer runs on Linux")
    def test_real_generators_and_lints_accept_a_synchronized_update(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("scripts", "docs", ".github"):
                shutil.copytree(ROOT / name, root / name)
            (root / "tui/internal/config").mkdir(parents=True)
            shutil.copy(ROOT / "tui/internal/config/runtimes.json", root / "tui/internal/config")
            for name in ("Dockerfile", "VERSION", "README.md", ".env.example", ".gitignore",
                         "docker-compose.yml", "docker-compose.linux.yml",
                         "docker-compose.worktree.yml", "docker-compose.isolated.yml"):
                shutil.copy(ROOT / name, root / name)
            current = sync.node_image((root / "Dockerfile").read_text())
            for name in ("Dockerfile", "README.md", "docs/MAINTENANCE.md"):
                path = root / name
                path.write_text(path.read_text().replace(current, OLD).replace(
                    current.split("@")[0], OLD.split("@")[0]))
            current = OLD
            before = (root / "Dockerfile").read_text()
            (root / "Dockerfile").write_text(before.replace("FROM " + current, "FROM " + NEW))
            # This is the original failure: Dependabot's one-line change leaves
            # the documentation contract red, even though FROM itself is valid.
            self.assertTrue(check_base_tags(root))
            (root / "Dockerfile").write_text(before)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                            "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"], check=True)
            base = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
            config = b'NUM_ACCOUNTS=19\nGH_TOKEN=placeholder-do-not-touch\n'
            (root / ".env").write_bytes(config)
            pr = {"number": 1, "user": {"login": "dependabot[bot]"}, "base": {"sha": base},
                  "head": {"repo": {"full_name": "owner/repo"}, "sha": "bot-head", "ref": "dependabot/docker/node"}}
            responses = [[{"filename": "Dockerfile"}],
                         {"content": base64.b64encode(before.replace("FROM " + OLD, "FROM " + NEW).encode()).decode()},
                         {"tree": {"sha": "bot-tree"}}, {"sha": "synchronized-tree"},
                         {"sha": "synchronized-head"}, None,
                         {"workflow_runs": []}, None, None, None]
            with patch.dict(os.environ, {"NUM_ACCOUNTS": "7", "IMAGE_TAG": "stale"}), \
                    patch.object(pr_sync, "api", side_effect=responses) as api, \
                    patch.object(pr_sync.image_sync, "verify_digest") as verify, \
                    patch.object(pr_sync.image_sync, "next_version", return_value="2099.01.01"):
                pr_sync.synchronize_pr("owner/repo", root, pr)
            verify.assert_called_once_with(NEW)
            calls = api.call_args_list
            tree = calls[3].args[2]
            self.assertEqual(tree["base_tree"], "bot-tree")
            paths = {entry["path"] for entry in tree["tree"]}
            self.assertTrue({"Dockerfile", "VERSION", "docker-compose.yml", "README.md", "docs/MAINTENANCE.md"} <= paths)
            self.assertNotIn(".env", paths)
            self.assertEqual(calls[4].args[2]["parents"], ["bot-head"])
            self.assertEqual(calls[5].args[2], {"sha": "synchronized-head", "force": False})
            self.assertEqual(calls[5].kwargs["method"], "PATCH")
            self.assertIn("head_sha=synchronized-head", calls[6].args[1])
            self.assertEqual((root / ".env").read_bytes(), config)
            self.assertEqual(sync.node_image((root / "Dockerfile").read_text()), NEW)
            self.assertEqual(check_base_tags(root), [])
            result = subprocess.run([sys.executable, str(ROOT / "scripts/readme_lint.py"),
                                     "--root", str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            compose = (root / "docker-compose.yml").read_text()
            self.assertIn("${IMAGE_TAG:-2099.01.01}", compose)
            self.assertIn("claude-b:", compose)
            self.assertNotIn("claude-c:", compose)
            self.assertTrue(all((root / name).is_file() for name in (
                "docker-compose.linux.yml", "docker-compose.worktree.yml", "docker-compose.isolated.yml")))


if __name__ == "__main__":
    unittest.main()
