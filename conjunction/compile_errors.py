"""Read the text of the game's "Script Compilation Errors" window (which file, which line) - no screenshot needed.

    python -m conjunction.compile_errors
"""
import ctypes
import ctypes.wintypes as wt

user32 = ctypes.windll.user32
user32.SendMessageTimeoutW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM, wt.UINT, wt.UINT,
                                       ctypes.POINTER(ctypes.c_size_t)]
WM_GETTEXT, WM_GETTEXTLENGTH, LB_GETCOUNT, LB_GETTEXT, LB_GETTEXTLEN = 0x0D, 0x0E, 0x018B, 0x0189, 0x018A


def send(hwnd, msg, wp, lp):
    """SendMessage with a timeout: a window that does not answer (another app hanging) must not hang us."""
    res = ctypes.c_size_t()
    if not user32.SendMessageTimeoutW(hwnd, msg, wp, lp, 0x0002, 500, ctypes.byref(res)):
        return 0
    return res.value


def text_of(hwnd):
    n = send(hwnd, WM_GETTEXTLENGTH, 0, 0)
    buf = ctypes.create_unicode_buffer(n + 1)
    send(hwnd, WM_GETTEXT, n + 1, ctypes.addressof(buf))
    return buf.value


def class_of(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def read():
    """The errors of the open "Script Compilation Errors" window, or None if there is none."""
    found, lines = [], []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def top(hwnd, _):
        buf = ctypes.create_unicode_buffer(256)
        user32.GetWindowTextW(hwnd, buf, 256)
        if "Script Compilation" in buf.value:
            found.append(hwnd)
        return True
    user32.EnumWindows(top, 0)
    if not found:
        return None

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def child(hwnd, _):
        cls = class_of(hwnd)
        if cls.lower() == "listbox":
            for i in range(send(hwnd, LB_GETCOUNT, 0, 0)):
                n = send(hwnd, LB_GETTEXTLEN, i, 0)
                buf = ctypes.create_unicode_buffer(n + 1)
                send(hwnd, LB_GETTEXT, i, ctypes.addressof(buf))
                lines.append(buf.value)
        elif cls.lower() == "edit":
            lines.append(text_of(hwnd))
        return True
    for w in found:
        user32.EnumChildWindows(w, child, 0)
    # errors only (the game always warns about a few native debug functions)
    return "\n".join(ln for t in lines for ln in t.splitlines() if ln.startswith("Error")) or "\n".join(lines)


def main():
    print(read() or "no compilation error window")


if __name__ == "__main__":
    main()
