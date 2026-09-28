#!/usr/bin/env python3
"""Credential ACL checks use disposable files and never rewrite caller access."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from container_fixture import policy
from credential_file import read_private_file


def make_private_fixture(path):
    if os.name == "nt":
        # New files can carry explicit SYSTEM/Administrators grants on hosted
        # runners. Reset this test-owned DACL before removing inheritance;
        # protect() intentionally preserves explicit caller grants elsewhere.
        subprocess.run(["icacls", str(path), "/reset"], check=True, capture_output=True)
    policy.protect(path)
    if os.name == "nt":
        identity = subprocess.check_output(["whoami", "/user", "/fo", "csv", "/nh"], text=True)
        sid = re.search(r"S-1-\d+(?:-\d+)+", identity)[0]
        # Elevated Windows runners can default to Administrators ownership.
        # Only newly created test files receive this explicit owner change.
        subprocess.run(["icacls", str(path), "/setowner", "*" + sid], check=True, capture_output=True)


class PrivateFileTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "credentials.json"
        self.path.write_text("placeholder-canary")
        make_private_fixture(self.path)

    def test_owner_private_file_is_read_without_changes(self):
        before = self.path.stat()
        self.assertEqual("placeholder-canary", read_private_file(self.path))
        self.assertEqual(before.st_mtime_ns, self.path.stat().st_mtime_ns)

    @unittest.skipIf(os.name == "nt", "POSIX mode case; Windows has native ACL cases")
    def test_posix_readable_by_others_is_rejected_and_unchanged(self):
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            read_private_file(self.path)
        self.assertEqual(0o644, self.path.stat().st_mode & 0o777)

    @unittest.skipIf(os.name == "nt", "POSIX symlinks/FIFO; Windows reparse points need privileges")
    def test_links_and_nonregular_files_are_rejected_before_reading(self):
        link = self.path.with_name("link")
        link.symlink_to(self.path)
        with self.assertRaises(OSError):
            read_private_file(link)
        fifo = self.path.with_name("fifo")
        os.mkfifo(fifo, 0o600)
        with self.assertRaises(ValueError):
            read_private_file(fifo)

    @unittest.skipUnless(os.name == "nt", "native Windows ACL")
    def test_windows_everyone_read_grant_is_rejected_without_changing_acl(self):
        subprocess.run(["icacls", str(self.path), "/grant", "*S-1-1-0:R"], check=True, capture_output=True)
        before = subprocess.check_output(["icacls", str(self.path)])
        with self.assertRaises(ValueError):
            read_private_file(self.path)
        self.assertEqual(before, subprocess.check_output(["icacls", str(self.path)]))

    @unittest.skipUnless(os.name == "nt", "native Windows ACL")
    def test_windows_inherited_other_user_grant_is_rejected(self):
        subprocess.run(["icacls", str(self.path.parent), "/grant", "*S-1-1-0:(OI)(CI)R"], check=True, capture_output=True)
        subprocess.run(["icacls", str(self.path), "/inheritance:e"], check=True, capture_output=True)
        with self.assertRaises(ValueError):
            read_private_file(self.path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
