#!/usr/bin/env python3
"""Native PTY/ConPTY process tests; no Docker or provider credentials."""
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from terminal_support import Terminal
from workflow_support import WorkflowFailure


class TerminalTest(unittest.TestCase):
    def session(self, script, directory):
        path = Path(directory) / "child.py"
        path.write_text(script)
        return Terminal([sys.executable, "-u", str(path)], cwd=directory, env=dict(os.environ))

    def test_bidirectional_terminal_dimensions_and_normal_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.session("import os\nprint('SIZE-%s-%s' % os.get_terminal_size())\nprint('READY')\nassert input() == 'finish'\n", directory) as terminal:
                terminal.expect(b"SIZE-160-48", timeout=10)
                terminal.send(b"finish\r")
                terminal.wait_exit()
            self.assertEqual(b"", terminal._output)

    def test_large_output_is_drained_without_deadlock_or_retained_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.session("print('x' * 2000000)\nprint('DRAINED')\ninput()\n", directory) as terminal:
                terminal.expect(b"DRAINED", timeout=15)
                self.assertLessEqual(len(terminal._output), 65536)
                terminal.send(b"\r")
                terminal.wait_exit()
            self.assertEqual(b"", terminal._output)

    def test_early_exit_and_start_failure_are_failures_without_output(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.session("print('terminal-secret-canary')\nraise SystemExit(17)\n", directory) as terminal:
                with self.assertRaisesRegex(WorkflowFailure, "^terminal_exited_early$"):
                    terminal.expect(b"impossible", timeout=10)
            with self.assertRaisesRegex(WorkflowFailure, "^terminal_start_failed$"):
                Terminal([str(Path(directory) / "missing-command")], directory, dict(os.environ))

    def test_timeout_reaps_process_and_stops_io_threads(self):
        with tempfile.TemporaryDirectory() as directory:
            terminal = self.session("import time\nprint('READY')\ntime.sleep(60)\n", directory)
            with self.assertRaisesRegex(WorkflowFailure, "^terminal_timeout$"):
                with terminal:
                    terminal.expect(b"READY", timeout=10)
                    terminal.expect(b"never", timeout=0.1)
            self.assertIsNotNone(terminal.backend.poll())
            self.assertFalse(terminal._reader.is_alive())
            self.assertFalse(terminal._writer.is_alive())
            terminal.close()

    def test_cleanup_stops_descendant_writes_even_after_leader_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = Path(directory) / "heartbeat"
            child = "import pathlib,time\np=pathlib.Path('heartbeat')\nwhile True:\n p.write_text(str(time.time_ns()))\n time.sleep(.05)\n"
            script = "import subprocess,sys,time\nsubprocess.Popen([sys.executable,'-u','-c',%r])\nprint('READY')\ninput()\n" % child
            with self.session(script, directory) as terminal:
                terminal.expect(b"READY", timeout=10)
                terminal.wait_for(heartbeat.exists, timeout=5)
                terminal.send(b"\r")
                terminal.wait_exit()
            before = heartbeat.read_bytes()
            time.sleep(0.2)
            self.assertEqual(before, heartbeat.read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
