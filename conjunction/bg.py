"""The game in the background (Maxim, 01.10.: "test in the game while I play something else or watch YouTube"): started
with tools/w3bg/w3bg.dll inside (it believes it is in front, never takes mouse, keys, pad or the front, renders on the
second card), in a small window at the very back, quiet and slow (720p, 30 fps, no ray tracing, no sound). It has
a Documents folder of its own (Documents\\w3bg\\The Witcher 3: copies of Maxim's settings made quiet, a few of his
saves to start from), a debug port of its own (PORT instead of 37001) and Conjunction beside it an agent port of its own
- so the player can play a second game on the main card at the same time.

    from conjunction import bg
    bg.start()              # the game, in the background
    bg.use()                # this process talks to it (gamelink, agent, its scriptslog)
    bg.shot(path)           # a picture of its window, without bringing it up

    python -m conjunction.bg --restore          (an old run that still rewrote Maxim's settings: his back)
"""
import ctypes
import os
import shutil
import subprocess
import sys
import time
from ctypes import wintypes

from . import config

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, "tools", "w3bg", "w3bg.dll")
LOG = os.path.join(ROOT, "tools", "w3bg", "w3bg.log")
GPU_4060TI = "2805"                     # PCI device id of the RTX 4060 Ti (the 5080: 2c02)
SETTINGS = os.path.join(os.path.expanduser("~"), "Documents", "The Witcher 3")     # Maxim's
BACKUP = ".w3bg_backup"
HOME = os.path.join(os.path.expanduser("~"), "Documents", "w3bg")         # "Documents" of the background game
DOCS = os.path.join(HOME, "The Witcher 3")
PID = os.path.join(HOME, "game.pid")
PORT, AGENT_PORT = 37011, 37111
GAME_DIR = r"Q:\W3_Hintergrund\The Witcher 3"  # its own game folder (01.10.: content hard-linked; bin, Mods,
                                                # dlc real) - its scripts and test DLCs go there, never into Maxim's
COPIED = ["user.settings", "dx12user.settings", "input.settings", "mods.settings", "profile.settings",
          "customUserData.json"]
SAVES = 4                               # Maxim's newest saves the background game may start from
# what the background game runs with: [section] key = value, in both settings files the remaster reads
QUIET = {
    "dx12user.settings": [("Viewport", "FullScreenMode", "0"), ("Viewport", "Resolution", '"1280x720"'),
                          ("Viewport", "VSync", "false"), ("Engine", "LimitFPS", "20"),
                          ("Rendering/RT", "EnableRT", "false"), ("Rendering", "AllowDLSS", "false"),
                          ("Audio", "SoundVolume", "0"), ("Audio", "MusicVolume", "0")],
    "user.settings": [("Audio", "SoundVolume", "0"), ("Audio", "MusicVolume", "0")],
}


def set_ini(text, section, key, value):
    """`key=value` in `[section]` of a settings text (added when missing), its line endings kept."""
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(nl)
    head = f"[{section}]"
    if head not in lines:
        if lines and lines[-1] == "":
            lines.pop()
        return nl.join(lines + [head, f"{key}={value}", ""])
    i = lines.index(head) + 1
    while i < len(lines) and not lines[i].startswith("["):
        if lines[i].split("=", 1)[0] == key:
            lines[i] = f"{key}={value}"
            return nl.join(lines)
        i += 1
    while i > 0 and lines[i - 1] == "":                 # before the empty line that ends the file
        i -= 1
    lines.insert(i, f"{key}={value}")
    return nl.join(lines)


def _write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    os.replace(tmp, path)


def prepare_docs():
    """The background game's Documents: Maxim's settings copied anew each start and made quiet; his newest saves
    once (later the background game's own saves are the newest - the tests go on from them)."""
    os.makedirs(os.path.join(DOCS, "gamesaves"), exist_ok=True)
    for name in COPIED:
        src = os.path.join(SETTINGS, name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(DOCS, name))
    for name, changes in QUIET.items():
        path = os.path.join(DOCS, name)
        if os.path.exists(path):
            text = open(path, encoding="utf-8", newline="").read()
            for section, key, value in changes:
                text = set_ini(text, section, key, value)
            _write(path, text)
    mine = os.path.join(DOCS, "gamesaves")
    if not any(f.endswith(".sav") for f in os.listdir(mine)):
        his = os.path.join(SETTINGS, "gamesaves")
        saves = sorted((f for f in os.listdir(his) if f.endswith(".sav")),
                       key=lambda f: os.path.getmtime(os.path.join(his, f)), reverse=True)[:SAVES]
        for f in saves:
            for ext in (".sav", ".json", ".png"):
                src = os.path.join(his, f[:-4] + ext)
                if os.path.exists(src):
                    shutil.copy2(src, mine)


class _ProcessEntry(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_void_p), ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD), ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260)]


def game_pids():
    """Process ids of every running witcher3.exe - asked of Windows directly (a snapshot of the processes): no
    child process, no console window (01.10.: tasklist from a detached suite opened a terminal each time)."""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    snap = k32.CreateToolhelp32Snapshot(0x00000002, 0)          # TH32CS_SNAPPROCESS
    if not snap or snap == wintypes.HANDLE(-1).value:
        return set()
    pids = set()
    try:
        e = _ProcessEntry()
        e.dwSize = ctypes.sizeof(e)
        ok = k32.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            if e.szExeFile.lower() == "witcher3.exe":
                pids.add(int(e.th32ProcessID))
            ok = k32.Process32NextW(snap, ctypes.byref(e))
    finally:
        k32.CloseHandle(snap)
    return pids


def bg_pid():
    """The background game's process id while it runs, else None."""
    try:
        pid = int(open(PID).read().strip())
    except (OSError, ValueError):
        return None
    return pid if pid in game_pids() else None


def our_pids():
    """The games this process may use: the background one (in the background), else every other one."""
    pids, mine = game_pids(), bg_pid()
    if BACKGROUND:
        return {mine} if mine else set()
    return pids - {mine}


BASES = os.path.join(HOME, "bases.json")


def _saves():
    """The background game's saves: [(mtime, stem)], oldest first."""
    folder = os.path.join(DOCS, "gamesaves")
    if not os.path.isdir(folder):
        return []
    return sorted((os.path.getmtime(os.path.join(folder, f)), f[:-4]) for f in os.listdir(folder) if f.endswith(".sav"))


def back_to_base(project_id, quest_installed, log=print):
    """Build & Play of a quest that is in the save already: the game would go on with the old one (its blocks are
    kept in the save by name - 01.10.: a rebuilt Keira quest never ran its new steps). The background game's saves
    are the tests' own: the project's first clean save is kept aside as its base (the game reuses its save slots);
    each Build & Play moves the test saves away and puts the base back as the only save - it loads, the player is put
    back where they stood. -> True when the base is what loads next."""
    import json
    folder = os.path.join(DOCS, "gamesaves")
    kept = os.path.join(HOME, "bases", project_id)
    bases = json.load(open(BASES, encoding="utf-8")) if os.path.exists(BASES) else {}
    base = bases.get(project_id)
    have = base and os.path.exists(os.path.join(kept, base + ".sav"))
    if not have:
        saves = _saves()
        if quest_installed or not saves:
            log("[play] no clean save of this quest known - it goes on from the last save")
            return False
        base = saves[-1][1]                     # the quick save just made, before the quest was ever there
        os.makedirs(kept, exist_ok=True)
        for ext in (".sav", ".json", ".png"):
            src = os.path.join(folder, base + ext)
            if os.path.exists(src):
                shutil.copy2(src, kept)
        bases[project_id] = base
        _write(BASES, json.dumps(bases, indent=1))
        log(f"[play] clean save for this quest kept: {base}")
        return True
    aside = os.path.join(HOME, "old_saves", time.strftime("%Y%m%d_%H%M%S"))
    moved = 0
    for f in os.listdir(folder):
        if f.endswith((".sav", ".json", ".png")):
            os.makedirs(aside, exist_ok=True)
            shutil.move(os.path.join(folder, f), os.path.join(aside, f))
            moved += f.endswith(".sav")
    for f in os.listdir(kept):
        shutil.copy2(os.path.join(kept, f), folder)
    log(f"[play] from the clean save {base} ({moved} test save{'s' * (moved != 1)} moved aside)")
    return True


def use():
    """This process talks to the background game: its port, its scriptslog, the background Conjunction's agent."""
    os.environ["CJ_GAME_PORT"] = str(PORT)
    os.environ["CJ_AGENT_PORT"] = str(AGENT_PORT)
    os.environ["CJ_GAME_DOCS"] = DOCS
    os.environ["CJ_CONFIG_LAYER"] = os.path.join(HOME, "config.json")    # its settings never Maxim's
    if os.path.isdir(GAME_DIR):
        os.environ["CJ_GAME_DIR"] = GAME_DIR


def restore():
    """An older run (before the own Documents folder) rewrote Maxim's settings: his back, once no game runs."""
    back = [n for n in QUIET if os.path.exists(os.path.join(SETTINGS, n + BACKUP))]
    if not back or game_pids():
        return False
    for name in back:
        os.replace(os.path.join(SETTINGS, name + BACKUP), os.path.join(SETTINGS, name))
    return True


# --- starting with the DLL inside: suspended, the DLL queued on its first thread (it loads before the game's own
# code runs, after Windows has set the process up), then let go
class _StartupInfo(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR),
                ("lpTitle", wintypes.LPWSTR), ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
                ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD), ("dwXCountChars", wintypes.DWORD),
                ("dwYCountChars", wintypes.DWORD), ("dwFillAttribute", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
                ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD), ("lpReserved2", ctypes.c_void_p),
                ("hStdInput", wintypes.HANDLE), ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]


class _ProcessInfo(ctypes.Structure):
    _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE), ("dwProcessId", wintypes.DWORD),
                ("dwThreadId", wintypes.DWORD)]


def _launch(exe, args, env):
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.VirtualAllocEx.restype = ctypes.c_void_p
    k32.VirtualAllocEx.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_size_t, wintypes.DWORD, wintypes.DWORD]
    k32.WriteProcessMemory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                       ctypes.c_void_p]
    k32.GetProcAddress.restype = ctypes.c_void_p
    k32.GetProcAddress.argtypes = [wintypes.HMODULE, ctypes.c_char_p]
    k32.GetModuleHandleW.restype = wintypes.HMODULE
    k32.QueueUserAPC.argtypes = [ctypes.c_void_p, wintypes.HANDLE, ctypes.c_void_p]
    si = _StartupInfo()
    si.cb = ctypes.sizeof(si)
    si.dwFlags = 1                                      # STARTF_USESHOWWINDOW
    si.wShowWindow = 4                                  # SW_SHOWNOACTIVATE
    pi = _ProcessInfo()
    block = "".join(f"{k}={v}\0" for k, v in env.items()) + "\0"
    cmd = subprocess.list2cmdline([exe] + args)
    CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT = 0x4, 0x400
    # out of the starter's job (01.10.: Conjunction was ended - and its game with it, being in the same job), in a
    # process group of its own; a job that allows no breakaway: started inside it
    BREAKAWAY, NEW_GROUP = 0x01000000, 0x00000200
    for extra in (BREAKAWAY | NEW_GROUP, NEW_GROUP):
        if k32.CreateProcessW(exe, ctypes.create_unicode_buffer(cmd), None, None, False,
                              CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | extra,
                              ctypes.create_unicode_buffer(block), os.path.dirname(exe), ctypes.byref(si),
                              ctypes.byref(pi)):
            break
    else:
        raise OSError(ctypes.get_last_error(), "the game did not start")
    try:
        path = ctypes.create_unicode_buffer(DLL)
        size = ctypes.sizeof(path)
        remote = k32.VirtualAllocEx(pi.hProcess, None, size, 0x3000, 0x04)       # MEM_COMMIT|RESERVE, READWRITE
        if not remote or not k32.WriteProcessMemory(pi.hProcess, remote, path, size, None):
            raise OSError(ctypes.get_last_error(), "the DLL path did not get into the game")
        load = k32.GetProcAddress(k32.GetModuleHandleW("kernel32.dll"), b"LoadLibraryW")
        if not k32.QueueUserAPC(load, pi.hThread, remote):
            raise OSError(ctypes.get_last_error(), "the DLL could not be queued")
    except Exception:
        k32.TerminateProcess(pi.hProcess, 1)
        raise
    finally:
        k32.ResumeThread(pi.hThread)
        k32.CloseHandle(pi.hThread)
        k32.CloseHandle(pi.hProcess)
    return pi.dwProcessId


# the PC stays Maxim's (02.10.: the idle background game took 31 % of the CPU beside his own game): below normal,
# on the last 4 of the logical cores; frozen between tests (pause / resume)
CORES = 4
PRIORITY_BELOW_NORMAL = 0x4000


def tame(pid=None):
    """The background game below normal priority, on the last CORES logical cores."""
    pid = pid or bg_pid()
    if not pid:
        return False
    k32 = ctypes.windll.kernel32
    h = k32.OpenProcess(0x0200 | 0x0400, False, pid)        # PROCESS_SET_INFORMATION | QUERY_INFORMATION
    if not h:
        return False
    try:
        n = os.cpu_count() or 8
        mask = ((1 << min(CORES, n)) - 1) << max(0, n - CORES)
        k32.SetPriorityClass(h, PRIORITY_BELOW_NORMAL)
        if os.environ.get("CJ_BG_CORES"):             # (cores limited: suspected of crashes at start, 02.10.)
            k32.SetProcessAffinityMask(h, ctypes.c_size_t(mask))
        return True
    finally:
        k32.CloseHandle(h)


def _suspend(pid, on):
    ntdll = ctypes.windll.ntdll
    h = ctypes.windll.kernel32.OpenProcess(0x0800, False, pid)       # PROCESS_SUSPEND_RESUME
    if not h:
        return False
    try:
        return (ntdll.NtSuspendProcess if on else ntdll.NtResumeProcess)(h) == 0
    finally:
        ctypes.windll.kernel32.CloseHandle(h)


def pause():
    """The background game frozen (no CPU, no GPU) - until resume()."""
    pid = bg_pid()
    return bool(pid) and _suspend(pid, True)


def resume():
    pid = bg_pid()
    return bool(pid) and _suspend(pid, False)


def start(gpu=GPU_4060TI, cfg=None):
    """The game in the background; -> its process id. A second one while one runs: refused."""
    from .setup import EXE, skip_intro
    if bg_pid():
        raise RuntimeError("the background game is already running - end it first")
    # build.bat writes next/w3bg.dll (the running game holds the DLL): it takes its place before a start
    built = os.path.join(os.path.dirname(DLL), "next", "w3bg.dll")
    if os.path.exists(built) and (not os.path.exists(DLL) or os.path.getmtime(built) > os.path.getmtime(DLL)):
        import shutil
        shutil.copy2(built, DLL)
    if not os.path.exists(DLL):
        raise FileNotFoundError(f"{DLL} is missing - tools/w3bg/build.bat builds it")
    use()                                           # its own game folder, port, Documents
    cfg = config.load()
    exe = os.path.join(cfg["game"], EXE)
    if cfg.get("skip_intro", True):
        try:
            skip_intro(cfg)
        except OSError:
            pass
    restore()
    prepare_docs()
    env = dict(os.environ, SteamAppId="292030", SteamGameId="292030", W3BG="1", W3BG_LOG=LOG,
               W3BG_PORT=str(PORT), W3BG_DOCS=HOME)
    if gpu:
        env["W3BG_GPU"] = gpu
    import json
    job = os.path.join(HOME, "launch.json")
    _write(job, json.dumps({"exe": exe, "args": ["--launcher-skip", "-net", "-debugscripts"], "env": env}))
    if os.path.exists(PID):
        os.remove(PID)
    # a launcher that starts the game and ends: the game is nobody's child in Conjunction's tree
    subprocess.run([sys.executable, "-m", "conjunction.bg", "--launch", job], cwd=ROOT, timeout=60,
                   creationflags=0x08000000 | 0x00000200)          # CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
    os.remove(job)                                  # (it holds the environment: not left lying around)
    pid = int(open(PID).read().strip())
    # w3bg.dll really inside it - else it is a plain second game (03.10.: the virus scanner took the DLL away while
    # it started: no mutex fix, Maxim saw "already running", no input guard) - ended at once
    t0 = time.time()
    while time.time() - t0 < 15:
        try:
            if f"w3bg in pid {pid}" in open(LOG, encoding="utf-8", errors="replace").read(400):
                break
        except OSError:
            pass
        time.sleep(0.25)
    else:
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x0001, False, pid)          # PROCESS_TERMINATE - this one only
        if h:
            k32.TerminateProcess(h, 1)
            k32.CloseHandle(h)
        raise RuntimeError("the background game started without w3bg.dll (a virus scanner? see tools/w3bg) - ended")
    tame(pid)
    return pid


def _launch_job(job):
    import json
    j = json.load(open(job, encoding="utf-8"))
    pid = _launch(j["exe"], j["args"], j["env"])
    with open(PID, "w") as f:
        f.write(str(pid))


def watch(pid):
    k32 = ctypes.windll.kernel32
    h = k32.OpenProcess(0x00100000, False, pid)         # SYNCHRONIZE
    if h:
        k32.WaitForSingleObject(h, 0xFFFFFFFF)
        k32.CloseHandle(h)
    for _ in range(30):                                 # it writes its settings while it closes
        if restore():
            return
        time.sleep(1.0)


# --- Conjunction itself in the background (python -m conjunction --background): its windows invisible and never in the way,
# its keys and wheel and cursor the virtual ones (the editor's shortcuts read those instead of Maxim's keyboard)
BACKGROUND = False
VKEYS = set()                           # virtual keys / mouse buttons held now (VK codes)
VWHEEL = [0.0]                          # wheel notches not taken yet
VCURSOR = [None]                        # the virtual cursor on screen (None: the middle of the game's window)


def cursor_pos():
    """Where the cursor is for the editor: the virtual one in the background, else the real one."""
    if BACKGROUND:
        if VCURSOR[0] is None:
            h = window()
            if h:
                from .cursor import client_rect_on_screen
                x, y, w, hh = client_rect_on_screen(h)
                return x + w // 2, y + hh // 2
            return 0, 0
        return VCURSOR[0]
    p = wintypes.POINT()
    ctypes.windll.user32.GetCursorPos(ctypes.byref(p))
    return p.x, p.y


def take_wheel():
    n, VWHEEL[0] = VWHEEL[0], 0.0
    return n


class _Invisible(object):
    """App-wide: every window Conjunction shows gets opacity 0 and lets every click through (WS_EX_TRANSPARENT) - it
    exists for Qt (layouts, pictures by grab) but Maxim neither sees nor touches it."""

    def __init__(self):
        from PySide6 import QtCore

        class Filter(QtCore.QObject):
            def eventFilter(self, obj, ev):
                t = ev.type()
                if t in (QtCore.QEvent.Polish, QtCore.QEvent.Show) and getattr(obj, "isWindow", None) and \
                        obj.isWindow():
                    # before its first show: shown without being activated (the show itself would take the front)
                    obj.setAttribute(QtCore.Qt.WA_ShowWithoutActivating, True)
                    if t == QtCore.QEvent.Show:
                        hide_window(obj)
                        # again once it is really shown: Qt sets the window's styles anew after this event (02.10.)
                        QtCore.QTimer.singleShot(0, lambda w=obj: hide_window(w) if w.isVisible() else None)
                return False
        self.filter = Filter()

        # at the root: every change of a window's extended style keeps see-through, click-through, never
        # activated - whatever Qt sets (02.10.: a small tool window came up without them, the guard stopped Conjunction)
        class STYLESTRUCT(ctypes.Structure):
            _fields_ = [("styleOld", wintypes.DWORD), ("styleNew", wintypes.DWORD)]

        class Native(QtCore.QAbstractNativeEventFilter):
            def nativeEventFilter(self, kind, message):
                try:
                    msg = wintypes.MSG.from_address(int(message))
                    if msg.message == 0x007C and (msg.wParam & 0xFFFFFFFF) == 0xFFFFFFEC:   # STYLECHANGING, EXSTYLE
                        STYLESTRUCT.from_address(msg.lParam).styleNew |= 0x08080020
                    elif msg.message == 0x0018 and msg.wParam:      # SHOWWINDOW: any window (a QWindow without a
                        u = ctypes.windll.user32                    # widget too - 02.10. a popup no filter saw)
                        h = msg.hWnd
                        if not u.GetParent(h):
                            ex = u.GetWindowLongW(h, -20)
                            if (ex & 0x08080020) != 0x08080020:
                                cls = ctypes.create_unicode_buffer(64)
                                u.GetClassNameW(h, cls, 64)
                                print(f"[bg] native window {cls.value} made invisible before it shows", flush=True)
                                u.SetWindowLongW(h, -20, ex | 0x08080020)
                                # fully see-through (a per-pixel one too: Qt's drawing into it fails then - nobody
                                # looks; pictures of Conjunction are drawn by Qt, not taken from the screen)
                                u.SetLayeredWindowAttributes(h, 0, 0, 2)
                except (ValueError, OSError):
                    pass
                return False, 0
        self.native = Native()
        QtCore.QCoreApplication.instance().installNativeEventFilter(self.native)
        # should one of Conjunction's windows still get the front: given back at once to the window before it
        self.last_foreign = None
        self.timer = QtCore.QTimer()
        self.timer.timeout.connect(self._guard)
        self.timer.start(30)

    def _guard(self):
        u = ctypes.windll.user32
        # every window shown: still see-through and click-through (02.10.: the build's notice came up without
        # WS_EX_TRANSPARENT - Qt set its styles anew after the show - and the window guard stopped Conjunction)
        from PySide6 import QtWidgets
        for w in QtWidgets.QApplication.topLevelWidgets():
            if w.isVisible() and w.internalWinId():
                ex = u.GetWindowLongW(int(w.internalWinId()), -20)
                if (ex & 0x08000020) != 0x08000020 or w.windowOpacity() > 0.0:
                    print(f"[bg] {type(w).__name__} {w.objectName()!r} {w.windowTitle()!r} {w.geometry().getRect()}: "
                          f"made invisible again", flush=True)
                    hide_window(w)
        fg = u.GetForegroundWindow()
        if not fg:
            return
        pid = wintypes.DWORD()
        u.GetWindowThreadProcessId(fg, ctypes.byref(pid))
        if pid.value != os.getpid():
            self.last_foreign = fg
            return
        if self.last_foreign and u.IsWindow(self.last_foreign):
            u.SetForegroundWindow(self.last_foreign)
            print(f"[bg] a Conjunction window took the front - given back", flush=True)


def hide_window(w):
    w.setWindowOpacity(0.0)
    u = ctypes.windll.user32
    hwnd = int(w.winId())
    st = u.GetWindowLongW(hwnd, -20)
    u.SetWindowLongW(hwnd, -20, st | 0x20 | 0x80000 | 0x08000000)    # TRANSPARENT | LAYERED | NOACTIVATE
    u.SetWindowPos(hwnd, 1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)     # HWND_BOTTOM, no move / size / activation


def suite_in_background(app):
    """Called once by Conjunction's main with --background."""
    global BACKGROUND, _keep
    BACKGROUND = True
    use()
    _keep = _Invisible()
    app.installEventFilter(_keep.filter)


# --- the virtual keyboard and mouse (the DLL's pipe): input only the background game gets, Maxim's devices untouched
PIPE = r"\\.\pipe\w3bg"
VK = {"esc": 0x1B, "tab": 0x09, "enter": 0x0D, "space": 0x20, "shift": 0x10, "ctrl": 0x11, "alt": 0x12,
      "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28, **{f"f{n}": 0x6F + n for n in range(1, 13)},
      **{c: ord(c.upper()) for c in "abcdefghijklmnopqrstuvwxyz0123456789"}}


def running():
    """A game with the DLL inside answers on its pipe."""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    if k32.WaitNamedPipeW(PIPE, 1):
        return True
    return ctypes.get_last_error() == 121               # there, but busy with another writer


def send(*lines):
    """Lines to the DLL (see w3bg.cpp pipe_thread); the pipe takes one writer at a time."""
    for _ in range(50):
        try:
            with open(PIPE, "w", encoding="ascii") as f:
                f.write("".join(ln + "\n" for ln in lines))
            return True
        except OSError:
            time.sleep(0.02)
    return False


def keys(seq, hold=0.15, gap=0.15):
    """Like the agent's keys: ["e"], ["w:2.0"] (held 2 s), ["shift+w:1.5"]."""
    done = []
    for k in ([seq] if isinstance(seq, str) else seq):
        name, _, secs = k.partition(":")
        codes = [VK[p] for p in name.lower().split("+")]
        VKEYS.update(codes)
        send(*[f"k {c} 1" for c in codes])
        _wait(float(secs) if secs else hold)
        send(*[f"k {c} 0" for c in reversed(codes)])
        VKEYS.difference_update(codes)
        done.append(k)
        time.sleep(gap)
    return done


def mouse(dx=0, dy=0, click=None, hold=0.06):
    """Relative mouse movement (the camera turns), a click (left | right | middle) held `hold` s."""
    steps = max(1, int(max(abs(dx), abs(dy)) / 40))
    for _ in range(steps):
        send(f"m {int(dx / steps)} {int(dy / steps)}")
        time.sleep(0.01)
    if click:
        b = {"left": 0, "right": 1, "middle": 2}[click]
        vk = {"left": 0x01, "right": 0x02, "middle": 0x04}[click]
        VKEYS.add(vk)
        send(f"b {b} 1")
        _wait(float(hold))
        send(f"b {b} 0")
        VKEYS.discard(vk)
    return {"moved": [dx, dy], "click": click}


def wheel(notches):
    """Mouse wheel notches: for the game and for Conjunction's editor (fly speed, turning)."""
    VWHEEL[0] += notches
    send(f"w {int(notches * 120)}")
    return notches


def _wait(secs):
    """Waits - and lets Conjunction's Qt loop run meanwhile when it is this process (its shortcuts see the keys)."""
    from PySide6 import QtWidgets
    app = QtWidgets.QApplication.instance()
    end = time.time() + secs
    while time.time() < end:
        if app is not None and BACKGROUND:
            app.processEvents()
        time.sleep(0.01)


# --- a picture of the window, wherever it is (behind others too - not minimised)
def window():
    """The game's window handle, or None."""
    u = ctypes.windll.user32
    found = []

    mine = bg_pid()
    if not mine:
        return None

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def each(h, _):
        b = ctypes.create_unicode_buffer(64)
        u.GetClassNameW(h, b, 64)
        pid = wintypes.DWORD()
        u.GetWindowThreadProcessId(h, ctypes.byref(pid))
        if b.value == "W2ViewportClass" and pid.value == mine and u.IsWindowVisible(h):
            found.append(h)
        return True
    u.EnumWindows(each, 0)
    return found[0] if found else None


def shot(path):
    """The game's window into a PNG (PrintWindow with its full content: what DWM shows of it). -> path or None."""
    from PySide6 import QtGui
    h = window()
    if not h:
        return None
    u, g = ctypes.windll.user32, ctypes.windll.gdi32
    r = wintypes.RECT()
    u.GetClientRect(h, ctypes.byref(r))
    w, hh = r.right, r.bottom
    if w <= 0 or hh <= 0:
        return None
    wdc = u.GetDC(h)
    mdc = g.CreateCompatibleDC(wdc)
    bmp = g.CreateCompatibleBitmap(wdc, w, hh)
    g.SelectObject(mdc, bmp)
    ok = u.PrintWindow(h, mdc, 3)                       # PW_CLIENTONLY | PW_RENDERFULLCONTENT
    img = None
    if ok:
        img = QtGui.QImage.fromHBITMAP(bmp) if hasattr(QtGui.QImage, "fromHBITMAP") else None
        if img is None:
            from PySide6.QtGui import QImage

            class BMI(ctypes.Structure):
                _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                            ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD),
                            ("biCompression", wintypes.DWORD), ("biSizeImage", wintypes.DWORD),
                            ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                            ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]
            bmi = BMI(ctypes.sizeof(BMI), w, -hh, 1, 32, 0, 0, 0, 0, 0, 0)
            buf = ctypes.create_string_buffer(w * hh * 4)
            g.GetDIBits(mdc, bmp, 0, hh, buf, ctypes.byref(bmi), 0)
            img = QImage(buf.raw, w, hh, w * 4, QImage.Format_RGB32).copy()
    g.DeleteObject(bmp)
    g.DeleteDC(mdc)
    u.ReleaseDC(h, wdc)
    if img is None or not img.save(path):
        return None
    return path


if __name__ == "__main__":
    if sys.argv[1:2] == ["--launch"]:
        _launch_job(sys.argv[2])
    elif sys.argv[1:2] == ["--watch"]:
        watch(int(sys.argv[2]))
    elif sys.argv[1:2] == ["--restore"]:
        print("restored" if restore() else "nothing to restore (or the game still runs)")
