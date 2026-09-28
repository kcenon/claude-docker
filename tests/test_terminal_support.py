#!/usr/bin/env python3
"""Native PTY/ConPTY process tests; no Docker or provider credentials."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from terminal_support import Terminal
from workflow_support import WorkflowFailure


class TerminalTest(unittest.TestCase):
    def test_console_output_is_drained_during_native_startup(self):
        class StartupNeedsDrainer:
            def __init__(self, *args):
                self.reading = threading.Event()
                if args:
                    self.start(*args)

            def start(self, *args):
                if not self.reading.wait(0.3):
                    raise TimeoutError("native startup waiting for output drain")

            def read(self):
                self.reading.set()
                time.sleep(0.01)

            def write(self, data):
                pass

            def terminate(self):
                pass

            def close(self):
                pass

        with patch.dict(sys.modules, {"terminal_windows": SimpleNamespace(WindowsTerminal=StartupNeedsDrainer)}), patch(
                "terminal_support.os.name", "nt"):
            with Terminal(["placeholder"], ".", {}) as terminal:
                self.assertTrue(terminal.backend.reading.is_set())

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

    def test_redirected_parent_does_not_receive_terminal_output(self):
        script = (
            "import os,sys\nfrom terminal_support import Terminal\n"
            "with Terminal([sys.executable,'-u','-c',"
            "\"print('private-child-marker'); input()\"],os.getcwd(),dict(os.environ)) as terminal:\n"
            " terminal.expect(b'private-child-marker',timeout=5)\n"
            " terminal.send(b'\\r')\n terminal.wait_exit()\n"
            "print('parent-complete')\n"
        )
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            result = subprocess.run([sys.executable, "-u", "-c", script],
                                    cwd=Path(__file__).resolve().parent, stdin=subprocess.DEVNULL,
                                    stdout=output, stderr=errors, timeout=30)
            output.seek(0)
            errors.seek(0)
            # Boolean assertions never echo a leaked terminal buffer.
            self.assertEqual(0, result.returncode, "redirected parent failed")
            self.assertTrue(output.read().replace(b"\r\n", b"\n") == b"parent-complete\n",
                            "terminal output escaped into parent stdout")
            self.assertFalse(errors.read(), "terminal output escaped into parent stderr")

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
    # A blocked native console API must fail this placeholder-only process
    # test within a fixed bound, with a Python stack identifying the call.
    import faulthandler
    faulthandler.dump_traceback_later(90, exit=True)
    unittest.main(verbosity=2)
