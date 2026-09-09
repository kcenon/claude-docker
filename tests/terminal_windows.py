"""Native ConPTY backend; imported only on Windows (no extra Python package)."""
import ctypes as c
from ctypes import wintypes as w
import shutil
import subprocess
import threading
import time

k = c.WinDLL("kernel32", use_last_error=True)


def api(name, result, *arguments):
    function = getattr(k, name)
    function.restype, function.argtypes = result, list(arguments)
    return function


class Coord(c.Structure):
    _fields_ = [("X", c.c_short), ("Y", c.c_short)]


class Startup(c.Structure):
    _fields_ = [("cb", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR), ("title", w.LPWSTR),
                ("x", w.DWORD), ("y", w.DWORD), ("xSize", w.DWORD), ("ySize", w.DWORD),
                ("xChars", w.DWORD), ("yChars", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD),
                ("show", w.WORD), ("reservedSize", w.WORD), ("reserved2", c.c_void_p),
                ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]


class StartupEx(c.Structure):
    _fields_ = [("startup", Startup), ("attributes", c.c_void_p)]


class Process(c.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]


class BasicLimit(c.Structure):
    _fields_ = [("processTime", c.c_longlong), ("jobTime", c.c_longlong), ("flags", w.DWORD),
                ("minWorkingSet", c.c_size_t), ("maxWorkingSet", c.c_size_t), ("active", w.DWORD),
                ("affinity", c.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]


class ExtendedLimit(c.Structure):
    _fields_ = [("basic", BasicLimit), ("io", c.c_ulonglong * 6), ("processMemory", c.c_size_t),
                ("jobMemory", c.c_size_t), ("peakProcessMemory", c.c_size_t), ("peakJobMemory", c.c_size_t)]


close_handle = api("CloseHandle", w.BOOL, w.HANDLE)
create_pipe = api("CreatePipe", w.BOOL, c.POINTER(w.HANDLE), c.POINTER(w.HANDLE), c.c_void_p, w.DWORD)
create_console = api("CreatePseudoConsole", c.c_long, Coord, w.HANDLE, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE))
close_console = api("ClosePseudoConsole", None, w.HANDLE)
initialize = api("InitializeProcThreadAttributeList", w.BOOL, c.c_void_p, w.DWORD, w.DWORD, c.POINTER(c.c_size_t))
update = api("UpdateProcThreadAttribute", w.BOOL, c.c_void_p, w.DWORD, c.c_size_t, c.c_void_p, c.c_size_t, c.c_void_p, c.c_void_p)
delete = api("DeleteProcThreadAttributeList", None, c.c_void_p)
create_process = api("CreateProcessW", w.BOOL, w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p, w.BOOL,
                     w.DWORD, c.c_void_p, w.LPCWSTR, c.POINTER(StartupEx), c.POINTER(Process))
create_job = api("CreateJobObjectW", w.HANDLE, c.c_void_p, w.LPCWSTR)
set_job = api("SetInformationJobObject", w.BOOL, w.HANDLE, c.c_int, c.c_void_p, w.DWORD)
assign_job = api("AssignProcessToJobObject", w.BOOL, w.HANDLE, w.HANDLE)
kill_job = api("TerminateJobObject", w.BOOL, w.HANDLE, w.UINT)
kill_process = api("TerminateProcess", w.BOOL, w.HANDLE, w.UINT)
resume = api("ResumeThread", w.DWORD, w.HANDLE)
exit_code = api("GetExitCodeProcess", w.BOOL, w.HANDLE, c.POINTER(w.DWORD))
wait = api("WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
peek = api("PeekNamedPipe", w.BOOL, w.HANDLE, c.c_void_p, w.DWORD, c.c_void_p, c.POINTER(w.DWORD), c.c_void_p)
read = api("ReadFile", w.BOOL, w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p)
write = api("WriteFile", w.BOOL, w.HANDLE, c.c_void_p, w.DWORD, c.POINTER(w.DWORD), c.c_void_p)


def checked(success):
    if not success:
        raise c.WinError(c.get_last_error())


class WindowsTerminal:
    def __init__(self, argv, cwd, env, columns, rows):
        self.handles = []
        self.console, self.job, self.process = None, None, Process()
        attributes = None
        initialized = False
        try:
            input_read, self.input = w.HANDLE(), w.HANDLE()
            self.output, output_write = w.HANDLE(), w.HANDLE()
            checked(create_pipe(c.byref(input_read), c.byref(self.input), None, 0))
            self.handles.extend([input_read, self.input])
            checked(create_pipe(c.byref(self.output), c.byref(output_write), None, 0))
            self.handles.extend([self.output, output_write])
            console = w.HANDLE()
            if create_console(Coord(columns, rows), input_read, output_write, 0, c.byref(console)) < 0:
                raise OSError("ConPTY unavailable")
            self.console = console
            size = c.c_size_t()
            initialize(None, 1, 0, c.byref(size))
            attributes = c.create_string_buffer(size.value)
            checked(initialize(attributes, 1, 0, c.byref(size)))
            initialized = True
            checked(update(attributes, 0, 0x00020016, self.console, c.sizeof(w.HANDLE), None, None))
            startup = StartupEx()
            startup.startup.cb = c.sizeof(startup)
            startup.attributes = c.cast(attributes, c.c_void_p)
            self.job = create_job(None, None)
            checked(self.job)
            limits = ExtendedLimit()
            limits.basic.flags = 0x2000  # KILL_ON_JOB_CLOSE, inherited by descendants.
            checked(set_job(self.job, 9, c.byref(limits), c.sizeof(limits)))
            executable = shutil.which(argv[0], path=env.get("PATH"))
            if not executable:
                raise OSError("Executable unavailable")
            command = c.create_unicode_buffer(subprocess.list2cmdline([executable] + list(argv[1:])))
            environment = c.create_unicode_buffer("\0".join(key + "=" + value for key, value in sorted(env.items(), key=lambda kv: kv[0].upper())) + "\0\0")
            # Suspend until owned by the job: no descendant can escape cleanup
            # between CreateProcess and AssignProcessToJobObject.
            checked(create_process(executable, command, None, None, False, 0x00080000 | 0x400 | 0x4,
                                   environment, str(cwd), c.byref(startup), c.byref(self.process)))
            self.handles.extend([self.process.process, self.process.thread])
            checked(assign_job(self.job, self.process.process))
            if resume(self.process.thread) == 0xFFFFFFFF:
                raise OSError("Resume failed")
            for handle in (input_read, output_write, self.process.thread):
                checked(close_handle(handle))
                self.handles.remove(handle)
        except BaseException:
            if self.process.process:
                kill_process(self.process.process, 1)
            # Drain even construction failures before closing the pseudoconsole.
            if self.console:
                def discard():
                    try:
                        while self.read() != b"":
                            pass
                    except OSError:
                        pass
                threading.Thread(target=discard, daemon=True).start()
            try:
                self.terminate()
            finally:
                self.close()
            raise
        finally:
            if initialized:
                delete(attributes)

    def read(self):
        available = w.DWORD()
        if not peek(self.output, None, 0, None, c.byref(available), None):
            if c.get_last_error() in (109, 232):
                return b""
            checked(False)
        if not available.value:
            time.sleep(0.02)
            return None
        buffer = c.create_string_buffer(min(8192, available.value))
        size = w.DWORD()
        checked(read(self.output, buffer, len(buffer), c.byref(size), None))
        return buffer.raw[:size.value]

    def write(self, data):
        size = w.DWORD()
        checked(write(self.input, data, len(data), c.byref(size), None))
        if size.value != len(data):
            raise OSError("Short terminal write")

    def poll(self):
        if hasattr(self, "final_exit_code"):
            return self.final_exit_code
        if wait(self.process.process, 0) == 258:
            return None
        code = w.DWORD()
        checked(exit_code(self.process.process, c.byref(code)))
        return code.value

    def terminate(self):
        if self.job:
            checked(kill_job(self.job, 1))
        if self.process.process and wait(self.process.process, 5000) != 0:
            raise OSError("Process cleanup timeout")
        if self.process.process:
            self.final_exit_code = self.poll()
        if self.console:
            closer = threading.Thread(target=close_console, args=(self.console,), daemon=True)
            closer.start()
            closer.join(timeout=5)
            if closer.is_alive():
                raise OSError("ConPTY cleanup timeout")
            self.console = None

    def close(self):
        for handle in reversed(self.handles):
            close_handle(handle)
        self.handles.clear()
        if self.job:
            close_handle(self.job)
            self.job = None
