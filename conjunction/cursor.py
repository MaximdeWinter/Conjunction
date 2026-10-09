"""Cursor bridge (spike): the game cannot read its mouse cursor in the world, this does - and sends the ray inputs.

    python -m conjunction.cursor

While the game window is in front: F8 editor mode on / off, move the mouse -> the preview follows (cj_pick),
left click -> place (cj_place), right click -> delete ours under the cursor (cj_delete), F7 -> toggle whether
the camera fov counts vertically or horizontally (for the first calibration by eye). Ctrl+C ends.
"""
import ctypes
import ctypes.wintypes as wt
import time

from .gamelink import GameLink

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
user32.SetProcessDPIAware()
VK_LBUTTON, VK_RBUTTON, VK_F7, VK_F8 = 0x01, 0x02, 0x76, 0x77
RATE = 30.0


def game_window():
    """Main window of witcher3.exe."""
    from . import bg
    pids = bg.our_pids()                    # this process's game (the background one, or not it)
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value in pids and user32.IsWindowVisible(hwnd):
            r = wt.RECT()
            user32.GetClientRect(hwnd, ctypes.byref(r))
            if r.right - r.left > 200:
                found.append(hwnd)
        return True
    user32.EnumWindows(cb, 0)
    return found[0] if found else None


def client_rect_on_screen(hwnd):
    r = wt.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(r))
    p = wt.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(p))
    return p.x, p.y, r.right - r.left, r.bottom - r.top


def pressed(vk):
    from . import bg
    if bg.BACKGROUND:                       # Conjunction in the background: only the virtual keys count
        return vk in bg.VKEYS
    return bool(user32.GetAsyncKeyState(vk) & 0x8000)


def activate(hwnd):
    """Bring a window to the front even when another process has the focus (Windows refuses SetForegroundWindow
    then - unless our thread shares the input state of the foreground window's thread for a moment). Never in the
    background (bg.py): the front stays Maxim's."""
    from . import bg
    if bg.BACKGROUND:
        return
    fg = user32.GetForegroundWindow()
    if fg == hwnd:
        return
    me = kernel32.GetCurrentThreadId()
    other = user32.GetWindowThreadProcessId(fg, None)
    if other and other != me:
        user32.AttachThreadInput(me, other, True)
    user32.SetForegroundWindow(hwnd)
    user32.SetFocus(hwnd)
    if other and other != me:
        user32.AttachThreadInput(me, other, False)


def main():
    hwnd = game_window()
    if not hwnd:
        print("[cursor] game window not found")
        return
    link = GameLink()
    print("[cursor] ready: F8 editor on/off, left click place, right click delete, F7 fov convention, Ctrl+C end")
    editing, fov_vertical = False, True
    prev = {VK_LBUTTON: False, VK_RBUTTON: False, VK_F7: False, VK_F8: False}
    last_sent = None
    try:
        while True:
            t0 = time.perf_counter()
            front = user32.GetForegroundWindow() == hwnd
            now = {vk: pressed(vk) and front for vk in prev}
            edge = {vk: now[vk] and not prev[vk] for vk in prev}
            prev = now
            if edge[VK_F8]:
                editing = not editing
                link.exec(f"cj_edit({'true' if editing else 'false'})")
                print(f"[cursor] editor {'on' if editing else 'off'}")
            if edge[VK_F7]:
                fov_vertical = not fov_vertical
                link.exec(f"cj_fov({'true' if fov_vertical else 'false'})")
                print(f"[cursor] fov counted {'vertically' if fov_vertical else 'horizontally'}")
            if editing and front:
                x, y, w, h = client_rect_on_screen(hwnd)
                c = wt.POINT()
                user32.GetCursorPos(ctypes.byref(c))
                sx, sy = (c.x - x) / w, (c.y - y) / h
                if 0 <= sx <= 1 and 0 <= sy <= 1:
                    args = f"{sx:.4f}, {sy:.4f}, {w / h:.4f}"
                    if args != last_sent:
                        link.exec(f"cj_pick({args})")
                        last_sent = args
                    if edge[VK_LBUTTON]:
                        link.exec("cj_place()")
                    if edge[VK_RBUTTON]:
                        link.exec(f"cj_delete({args})")
            time.sleep(max(0.0, 1.0 / RATE - (time.perf_counter() - t0)))
    except KeyboardInterrupt:
        pass
    finally:
        if editing:
            link.exec("cj_edit(false)")
        link.close()


if __name__ == "__main__":
    main()
