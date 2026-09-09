"""Bounded test terminals. Output stays in a small private buffer, then is erased."""
import errno
import os
import queue
import re
import signal
import subprocess
import threading
import time
from workflow_support import WorkflowFailure


class PosixTerminal:
    def __init__(self, argv, cwd, env, columns, rows):
        import fcntl
        import pty
        import struct
        import termios
        self.master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
            self.process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=slave, stdout=slave,
                                            stderr=slave, start_new_session=True,
                                            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)

    def read(self):
        import select
        if not select.select([self.master], [], [], 0.1)[0]:
            return None
        try:
            return os.read(self.master, 8192)
        except OSError as error:
            if error.errno == errno.EIO:
                return b""
            raise

    def write(self, data):
        import select
        deadline = time.monotonic() + 3
        while data:
            if time.monotonic() >= deadline:
                raise TimeoutError()
            if select.select([], [self.master], [], 0.1)[1]:
                data = data[os.write(self.master, data):]

    def poll(self):
        return self.process.poll()

    def terminate(self):
        # The group can outlive its leader (e.g. a shell leaves a grandchild).
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.wait(timeout=5)

    def close(self):
        os.close(self.master)


class Terminal:
    def __init__(self, argv, cwd, env, columns=160, rows=48):
        if not 20 <= columns <= 500 or not 10 <= rows <= 200:
            raise WorkflowFailure("invalid_terminal_dimensions")
        self._output = b""
        self._lock = threading.Lock()
        self._stopping = threading.Event()
        self._input = queue.Queue(maxsize=64)
        self._failure = None
        self._closed = False
        env = dict(env, TERM="xterm-256color")
        try:
            if os.name == "nt":
                from terminal_windows import WindowsTerminal
                self.backend = WindowsTerminal(argv, cwd, env, columns, rows)
            else:
                self.backend = PosixTerminal(argv, cwd, env, columns, rows)
        except Exception:
            raise WorkflowFailure("terminal_start_failed") from None
        self._reader = threading.Thread(target=self._drain, daemon=True)
        self._writer = threading.Thread(target=self._write, daemon=True)
        self._reader.start()
        self._writer.start()

    def _drain(self):
        query_tail = b""
        try:
            while not self._stopping.is_set():
                data = self.backend.read()
                if data is None:
                    continue
                if not data:
                    return
                with self._lock:
                    self._output = (self._output + data)[-65536:]
                # Respond only to terminal capability queries, never model UI
                # prompts. Keep draining while the independent writer responds.
                combined = query_tail + data
                for request, reply in ((b"\x1b[6n", b"\x1b[1;1R"),
                                       (b"\x1b]10;?\x1b\\", b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\"),
                                       (b"\x1b]11;?\x1b\\", b"\x1b]11;rgb:0000/0000/0000\x1b\\"),
                                       (b"\x1b]10;?\x07", b"\x1b]10;rgb:ffff/ffff/ffff\x07"),
                                       (b"\x1b]11;?\x07", b"\x1b]11;rgb:0000/0000/0000\x07")):
                    if request in combined and request not in query_tail:
                        self.send(reply)
                query_tail = combined[-16:]
        except Exception:
            if not self._stopping.is_set():
                self._failure = "terminal_read_failed"

    def _write(self):
        try:
            while not self._stopping.is_set():
                try:
                    data = self._input.get(timeout=0.1)
                except queue.Empty:
                    continue
                self.backend.write(data)
        except Exception:
            if not self._stopping.is_set():
                self._failure = "terminal_write_failed"

    def send(self, data):
        if not isinstance(data, bytes) or len(data) > 4096:
            raise WorkflowFailure("terminal_input_invalid")
        try:
            self._input.put_nowait(data)
        except queue.Full:
            raise WorkflowFailure("terminal_input_blocked") from None

    def clear(self):
        with self._lock:
            self._output = b""

    def contains(self, token):
        with self._lock:
            plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", self._output)
            return token.lower() in plain.lower()

    def wait_for(self, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            if self._failure:
                raise WorkflowFailure(self._failure)
            if self.backend.poll() is not None:
                raise WorkflowFailure("terminal_exited_early")
            if predicate():
                return
            if time.monotonic() >= deadline:
                raise WorkflowFailure("terminal_timeout")
            time.sleep(0.05)

    def expect(self, token, timeout=30):
        self.wait_for(lambda: self.contains(token), timeout)

    def wait_exit(self, timeout=10):
        deadline = time.monotonic() + timeout
        while self.backend.poll() is None and time.monotonic() < deadline:
            if self._failure:
                raise WorkflowFailure(self._failure)
            time.sleep(0.05)
        if self.backend.poll() is None:
            raise WorkflowFailure("terminal_exit_timeout")
        if self.backend.poll() != 0:
            raise WorkflowFailure("terminal_exit_failed")

    def close(self):
        if self._closed:
            return
        self._closed = True
        failure = None
        try:
            # ConPTY emits a final frame on close. Its drainer must stay alive
            # until ClosePseudoConsole returns, including after process exit.
            self.backend.terminate()
        except Exception:
            failure = "terminal_cleanup_failed"
        finally:
            self._stopping.set()
            self._writer.join(timeout=5)
            self._reader.join(timeout=5)
            self.backend.close()
            self.clear()
        if failure or self._writer.is_alive() or self._reader.is_alive():
            raise WorkflowFailure(failure or "terminal_io_cleanup_failed")

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()
