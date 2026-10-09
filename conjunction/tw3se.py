"""The script extender (TW3SE, Conjunction's own: bin\\x64_dx12\\dinput8.dll + tw3se\\tw3se.dll) - its pipe
\\\\.\\pipe\\tw3se: one line in, one answer out ("ok ..." / "error ..."), opened anew for every command.

The editor talks to the game through it (gamelink.py: `exec` in, `events` out). Build & Play loads a new quest DLC
into the running game with it (no restart): the DLC folder into dlc\\ -> `livedlc <folder>` (mounts it, registers
it ~2 s later) -> a few seconds -> the last save loaded again.
The pipe serves one game: the answer only counts when the game behind it is ours (its process id)."""
import ctypes
import time
from ctypes import wintypes

PIPE = r"\\.\pipe\tw3se"
GENERIC_RW = 0x80000000 | 0x40000000
OPEN_EXISTING = 3
INVALID = ctypes.c_void_p(-1).value
ERROR_PIPE_BUSY = 231
ERROR_FILE_NOT_FOUND = 2

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.CreateFileW.restype = wintypes.HANDLE
k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                            wintypes.DWORD, wintypes.HANDLE]
k32.WaitNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
k32.GetNamedPipeServerProcessId.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.ULONG)]
k32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                          wintypes.LPVOID]
k32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                         wintypes.LPVOID]
k32.CloseHandle.argtypes = [wintypes.HANDLE]


def _open(wait_ms=3000):
    """A connection, or None. Busy: wait for a free instance. Not found: no game - or the moment between two of
    the extender's instances, so a few quick tries first."""
    for _ in range(4):
        h = k32.CreateFileW(PIPE, GENERIC_RW, 0, None, OPEN_EXISTING, 0, None)
        if h not in (None, INVALID):
            return h
        err = ctypes.get_last_error()
        if err == ERROR_PIPE_BUSY:
            if not k32.WaitNamedPipeW(PIPE, wait_ms):
                return None
        elif err == ERROR_FILE_NOT_FOUND:
            time.sleep(0.005)
        else:
            return None
    return None


def send(cmd, pids=None):
    """The extender's answer to one command - None: no extender (no pipe), or (`pids`) it runs in another game.
    Blocks until the command ran on the game's main thread."""
    h = _open()
    if h is None:
        return None
    try:
        if pids is not None:
            pid = wintypes.ULONG(0)
            if not k32.GetNamedPipeServerProcessId(h, ctypes.byref(pid)) or pid.value not in pids:
                cmd = "ping"                    # (the other game's extender waits for its line: given a harmless one)
                pids = False
        data = (cmd + "\n").encode("utf-8")
        n = wintypes.DWORD(0)
        if not k32.WriteFile(h, data, len(data), ctypes.byref(n), None):
            return None
        got, buf = b"", ctypes.create_string_buffer(8192)
        while not got.endswith(b"\n"):                # (the extender ends every answer with a newline)
            if not k32.ReadFile(h, buf, 8192, ctypes.byref(n), None) or not n.value:
                break
            got += buf.raw[:n.value]
        if not got:
            return None
        answer = got.decode("utf-8", "replace").strip()
        return None if pids is False else answer
    finally:
        k32.CloseHandle(h)


def ready(pids):
    """Does the extender run in one of these games (and answer)?"""
    return send("ping", pids) == "pong"


def live_dlc(folder, pids):
    """Mount + register a DLC folder in the running game -> (ok, answer)."""
    answer = send(f"livedlc {folder}", pids)
    if answer is None:
        return False, "the extender did not answer"
    return answer.startswith("ok"), answer
