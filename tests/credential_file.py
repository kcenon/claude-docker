"""Read explicit test inputs only after checking the opened file's privacy."""
import os
import stat


def read_private_file(path):
    if os.name == "nt":
        return _read_windows(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("private owned file required")
        return stream.read()


def _read_windows(path):
    import ctypes as c
    from ctypes import wintypes as w
    import msvcrt
    kernel = c.WinDLL("kernel32", use_last_error=True)
    security = c.WinDLL("advapi32", use_last_error=True)

    def api(dll, name, result, *arguments):
        function = getattr(dll, name)
        function.restype, function.argtypes = result, list(arguments)
        return function

    create = api(kernel, "CreateFileW", w.HANDLE, w.LPCWSTR, w.DWORD, w.DWORD,
                 c.c_void_p, w.DWORD, w.DWORD, w.HANDLE)
    close = api(kernel, "CloseHandle", w.BOOL, w.HANDLE)
    get_process = api(kernel, "GetCurrentProcess", w.HANDLE)
    free = api(kernel, "LocalFree", c.c_void_p, c.c_void_p)
    open_token = api(security, "OpenProcessToken", w.BOOL, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE))
    token_info = api(security, "GetTokenInformation", w.BOOL, w.HANDLE, c.c_int,
                     c.c_void_p, w.DWORD, c.POINTER(w.DWORD))
    get_security = api(security, "GetSecurityInfo", w.DWORD, w.HANDLE, c.c_int, w.DWORD,
                       c.POINTER(c.c_void_p), c.c_void_p, c.POINTER(c.c_void_p), c.c_void_p, c.POINTER(c.c_void_p))
    equal_sid = api(security, "EqualSid", w.BOOL, c.c_void_p, c.c_void_p)
    get_ace = api(security, "GetAce", w.BOOL, c.c_void_p, w.DWORD, c.POINTER(c.c_void_p))

    class FileInfo(c.Structure):
        _fields_ = [("attributes", w.DWORD), ("created", w.FILETIME), ("accessed", w.FILETIME),
                    ("written", w.FILETIME), ("volume", w.DWORD), ("sizeHigh", w.DWORD), ("sizeLow", w.DWORD),
                    ("links", w.DWORD), ("indexHigh", w.DWORD), ("indexLow", w.DWORD)]

    file_info = api(kernel, "GetFileInformationByHandle", w.BOOL, w.HANDLE, c.POINTER(FileInfo))

    def require(ok):
        if not ok:
            raise ValueError("private owned file required")

    # No sharing prevents replacement between the handle ACL check and read.
    # OPEN_REPARSE_POINT makes symlinks/junctions inspectable without following.
    handle = create(str(path), 0x80020000, 0, None, 3, 0x00200080, None)
    require(handle != c.c_void_p(-1).value)
    token, descriptor = w.HANDLE(), c.c_void_p()
    try:
        info = FileInfo()
        require(file_info(handle, c.byref(info)))
        require(not info.attributes & (0x400 | 0x10))
        require(open_token(get_process(), 8, c.byref(token)))
        length = w.DWORD()
        token_info(token, 1, None, 0, c.byref(length))
        token_buffer = c.create_string_buffer(length.value)
        require(token_info(token, 1, token_buffer, len(token_buffer), c.byref(length)))
        current_sid = c.cast(token_buffer, c.POINTER(c.c_void_p))[0]
        owner, dacl = c.c_void_p(), c.c_void_p()
        require(get_security(handle, 1, 1 | 4, c.byref(owner), None, c.byref(dacl), None, c.byref(descriptor)) == 0)
        require(owner.value and equal_sid(owner, current_sid))
        require(dacl.value)  # A NULL DACL grants everyone full access.
        count = c.c_ushort.from_address(dacl.value + 4).value
        allowed_owner = False
        for index in range(count):
            ace = c.c_void_p()
            require(get_ace(dacl, index, c.byref(ace)))
            kind = c.c_ubyte.from_address(ace.value).value
            if kind == 1:  # Ordinary deny ACEs cannot grant access.
                continue
            require(kind == 0)  # Unknown/object/callback grant rules fail closed.
            require(c.c_ushort.from_address(ace.value + 2).value >= 12)
            require(equal_sid(ace.value + 8, current_sid))
            allowed_owner = True
        require(allowed_owner)
        fd = msvcrt.open_osfhandle(handle, os.O_RDONLY)
        handle = None  # fd owns it now, including on decoding errors.
        with os.fdopen(fd, encoding="utf-8") as stream:
            return stream.read()
    finally:
        if descriptor:
            free(descriptor)
        if token:
            close(token)
        if handle:
            close(handle)
