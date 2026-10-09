"""Conjunction for an AI agent (or any script): everything a person does with it, from outside - its windows and
widgets (find, click, type, choose in menus), screenshots of a window, a widget or the game, the quest itself, builds,
and the game: commands, its state (where, the quest's objectives, facts), keys and the mouse, so it can be played as
far as it goes. Maxim, 01.10.: 'a dedicated interface for AI agents: full control of Conjunction, screenshots of the
windows asked for, and playing the game'.

The editor serves it on 127.0.0.1:37110 while it runs (one JSON object per line in, one per line out):

    {"cmd": "widgets", "text": "Open dialogue"}     ->  {"ok": true, "result": [{"id": 17, "class": ...}, ...]}

From a shell (prints the result as JSON):

    python -m conjunction.agent ping
    python -m conjunction.agent widgets '{"text": "Build"}'
    python -m conjunction.agent click '{"text": "Build & Play"}'
    python -m conjunction.agent shot '{"target": "panel"}'
    python -m conjunction.agent game '{"cmds": ["cj_where()"]}'
    python -m conjunction.agent keys '{"keys": ["e"]}'

Commands: see COMMANDS (each handler's first docstring line); docs/agent-api.md shows a whole quest built and played.
"""
import ast
import json
import os
import socket
import sys
import threading
import time
import traceback

PORT = 37110


def _port():
    """The agent's port (the background Conjunction's own: bg.AGENT_PORT, by CJ_AGENT_PORT)."""
    from . import config
    return config.agent_port(PORT)
SHOTS = os.path.join(os.path.expanduser("~"), "Documents", "conjunction", "_agent_shots")


# --- the client
def call(cmd, timeout=900, port=None, **args):
    """One command to the running suite -> its result (raises RuntimeError with Conjunction's error)."""
    with socket.create_connection(("127.0.0.1", port or _port()), timeout=timeout) as s:
        s.sendall((json.dumps(dict(args, cmd=cmd)) + "\n").encode("utf-8"))
        buf = b""
        while not buf.endswith(b"\n"):
            part = s.recv(1 << 20)
            if not part:
                break
            buf += part
    answer = json.loads(buf.decode("utf-8"))
    if not answer.get("ok"):
        raise RuntimeError(answer.get("error", "failed"))
    return answer.get("result")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    try:
        print(json.dumps(call(sys.argv[1], **args), indent=1, ensure_ascii=False, default=str))
    except (RuntimeError, OSError) as ex:
        print(json.dumps({"error": str(ex)}))
        sys.exit(1)


# --- the server (inside Conjunction)
class Agent:
    """Serves the commands in a thread of its own; what touches Qt runs on the Qt thread (`ui`)."""

    def __init__(self, ed, port=PORT):
        from PySide6 import QtCore
        self.ed = ed
        self.ids = {}                       # widget id -> widget (ids handed out by `widgets`)
        self.ns = {}                        # the `eval` namespace (kept between calls)

        class Invoker(QtCore.QObject):
            run = QtCore.Signal(object)
        self.invoker = Invoker()
        self.invoker.run.connect(self._run_job, QtCore.Qt.QueuedConnection)
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)    # a second suite: not silently
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(4)
        threading.Thread(target=self._serve, daemon=True).start()

    # the Qt thread
    def _run_job(self, job):
        fn, box, done = job
        try:
            box["result"] = fn()
        except Exception as ex:                         # noqa: BLE001 - handed back to the caller
            box["error"] = f"{type(ex).__name__}: {ex}\n{traceback.format_exc(limit=4)}"
        done.set()

    def ui(self, fn, timeout=60):
        """Run `fn` on the Qt thread, wait for its result."""
        box, done = {}, threading.Event()
        self.invoker.run.emit((fn, box, done))
        if not done.wait(timeout):
            raise TimeoutError("Conjunction did not answer (busy?)")
        if "error" in box:
            raise RuntimeError(box["error"])
        return box.get("result")

    def _serve(self):
        while True:
            try:
                conn, _a = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._client, args=(conn,), daemon=True).start()

    def _client(self, conn):
        with conn:
            f = conn.makefile("rwb")
            for line in f:
                try:
                    req = json.loads(line.decode("utf-8"))
                    cmd = req.pop("cmd")
                    handler = COMMANDS.get(cmd)
                    if handler is None:
                        raise ValueError(f"unknown command {cmd!r} (commands: {', '.join(sorted(COMMANDS))})")
                    out = {"ok": True, "result": handler(self, **req)}
                except Exception as ex:                 # noqa: BLE001 - handed back to the caller
                    out = {"ok": False, "error": str(ex)}
                f.write((json.dumps(out, ensure_ascii=False, default=str) + "\n").encode("utf-8"))
                f.flush()

    # --- helpers (Qt thread)
    def _id(self, w):
        self.ids[id(w)] = w
        return id(w)

    def _widget(self, wid=None, text=None, name=None):
        from PySide6 import QtWidgets
        if wid is not None:
            w = self.ids.get(int(wid))
            if w is None:
                raise ValueError(f"no widget {wid} (ask `widgets` again - the cards are rebuilt)")
            return w
        found = [w for w in self._all() if w.isVisible() and (text is None or _text(w) == text) and
                 (name is None or w.objectName() == name)]
        if not found and text is not None:              # as it looks: a painted 'GOAL' is the tile 'Goal'
            found = [w for w in self._all() if w.isVisible() and _norm(_text(w)) == _norm(text)
                     and (name is None or w.objectName() == name)]
        if not found:
            raise ValueError(f"no visible widget with text={text!r} name={name!r}")
        # the one in front: a list or menu that opened last over everything else
        found.sort(key=lambda w: isinstance(w, (QtWidgets.QPushButton, QtWidgets.QToolButton)), reverse=True)
        return found[0]

    def _all(self):
        from PySide6 import QtWidgets
        out = []
        for top in QtWidgets.QApplication.topLevelWidgets():
            out.append(top)
            out += top.findChildren(QtWidgets.QWidget)
        return out


def _text(w):
    for attr in ("text", "toPlainText", "currentText", "windowTitle", "placeholderText"):
        f = getattr(w, attr, None)
        if callable(f):
            try:
                t = f()
            except TypeError:
                continue
            if t:
                return t
    return w.accessibleName()                           # painted widgets (the block tiles) name themselves


def _norm(t):
    """Text as compared loosely: case, spacing and a menu's arrow do not count ('choose who  ▾' = 'choose who')."""
    return " ".join(str(t).replace("▾", " ").replace("▴", " ").split()).lower()


def _rect(w):
    from PySide6 import QtCore
    p = w.mapToGlobal(QtCore.QPoint(0, 0))
    return [p.x(), p.y(), w.width(), w.height()]


def _describe(a, w):
    d = {"id": a._id(w), "class": type(w).__name__, "name": w.objectName(), "text": _text(w)[:200],
         "rect": _rect(w), "enabled": w.isEnabled()}
    if w.toolTip():
        d["tooltip"] = w.toolTip()[:200]
    if w.isWindow():
        d["window"] = True
    return d


# --- the commands
def c_ping(a):
    """Is Conjunction there: its project, whether the editor is on in the game, whether the game answers."""
    ed = a.ed
    return {"project": ed.project.path, "place": ed.place, "editing": ed.editing,
            "game": bool(getattr(ed.link, "connected", False)), "world": getattr(ed, "world", None)}


def c_help(a):
    """The commands and what each does."""
    return {k: (f.__doc__ or "").strip().split("\n")[0] for k, f in sorted(COMMANDS.items())}


def c_windows(a):
    """Conjunction's windows that are open (the panel, its own windows, menus, dialogs) and the game's window."""
    def work():
        from PySide6 import QtWidgets
        out = [dict(_describe(a, w), title=w.windowTitle()) for w in QtWidgets.QApplication.topLevelWidgets()
               if w.isVisible()]
        return out
    out = a.ui(work)
    if a.ed.hwnd:
        from .cursor import client_rect_on_screen
        out.append({"id": "game", "class": "game", "rect": list(client_rect_on_screen(a.ed.hwnd))})
    return out


def c_widgets(a, window=None, text=None, contains=None, name=None, cls=None, limit=200, all=False):
    """Widgets (visible ones; all=true: also hidden) - filter by text, contains (in text or tooltip), name, cls."""
    def work():
        ws = a._all() if window is None else [a._widget(window)] + a._widget(window).findChildren(
            __import__("PySide6.QtWidgets", fromlist=["QWidget"]).QWidget)
        out = []
        for w in ws:
            if not (all or w.isVisible()):
                continue
            t = _text(w)
            if text is not None and t != text:
                continue
            if contains is not None and contains.lower() not in (t + " " + w.toolTip()).lower():
                continue
            if name is not None and w.objectName() != name:
                continue
            if cls is not None and type(w).__name__ != cls:
                continue
            if text is None and contains is None and name is None and cls is None and not t and not w.isWindow():
                continue                        # the bare containers: noise
            out.append(_describe(a, w))
            if len(out) >= limit:
                break
        return out
    return a.ui(work)


def c_click(a, id=None, text=None, name=None, button="left", double=False, x=None, y=None, wait=2.0):
    """Click a widget (by id from `widgets`, or its text / name) - at its middle, or at x, y inside it. One that is
    being rebuilt (a card after a change) is waited for up to `wait` s."""
    t0 = time.time()
    while True:
        try:
            return _click_once(a, id, text, name, button, double, x, y)
        except RuntimeError as ex:
            if "no visible widget" not in str(ex) or id is not None or time.time() - t0 > wait:
                raise
            time.sleep(0.15)


def _click_once(a, id, text, name, button, double, x, y):
    def work():
        from PySide6 import QtCore
        from PySide6.QtTest import QTest
        w = a._widget(id, text, name)
        said = _describe(a, w)                          # (before: a click often rebuilds the card it is on)
        b = {"left": QtCore.Qt.LeftButton, "right": QtCore.Qt.RightButton}[button]
        target = w.viewport() if hasattr(w, "viewport") else w
        pos = QtCore.QPoint(int(x), int(y)) if x is not None else target.rect().center()
        if double:
            QTest.mouseDClick(target, b, QtCore.Qt.NoModifier, pos)
        elif button == "right" and hasattr(w, "contextMenuEvent"):
            QTest.mouseClick(target, b, QtCore.Qt.NoModifier, pos)
            from PySide6 import QtGui
            ev = QtGui.QContextMenuEvent(QtGui.QContextMenuEvent.Mouse, pos, target.mapToGlobal(pos))
            QtCore.QCoreApplication.sendEvent(target, ev)
        else:
            QTest.mouseClick(target, b, QtCore.Qt.NoModifier, pos)
        return said
    return a.ui(work)


def c_type(a, text, id=None, name=None, field=None, enter=True, clear=True):
    """Type into a text field (by id, name or its placeholder `field`); enter: then Enter (the field takes it)."""
    def work():
        from PySide6 import QtCore, QtWidgets
        from PySide6.QtTest import QTest
        if field is not None:
            ws = [w for w in a._all() if w.isVisible() and isinstance(w, (QtWidgets.QLineEdit, QtWidgets.QTextEdit,
                                                                          QtWidgets.QPlainTextEdit))
                  and w.placeholderText() == field]
            if not ws:
                raise ValueError(f"no visible field {field!r}")
            w = ws[0]
        else:
            w = a._widget(id, None, name)
        if isinstance(w, QtWidgets.QAbstractSpinBox):     # a number: set, and said as when typed
            w.setValue(type(w.value())(float(text)))
            w.editingFinished.emit()
            return _describe(a, w)
        if isinstance(w, QtWidgets.QComboBox):
            w.setCurrentText(text)
            return _describe(a, w)
        w.setFocus()
        if clear:
            w.clear() if hasattr(w, "clear") else None
        if isinstance(w, QtWidgets.QLineEdit):
            w.insert(text)
            if enter:
                QTest.keyClick(w, QtCore.Qt.Key_Return)
                w.editingFinished.emit()
        else:
            w.insertPlainText(text)
            done = getattr(w, "done", None)                     # AutoText: says what it holds when it loses focus
            if enter and done is not None:
                done.emit(w.toPlainText())
            w.clearFocus()
        return _describe(a, w)
    return a.ui(work)


def c_menu(a, text, wait=2.0):
    """Choose an entry of the menu or list that is open (a QMenu, or Conjunction's own inline lists) - one that opens
    in a moment is waited for (up to `wait` s)."""
    t0 = time.time()
    while True:
        try:
            return _menu_once(a, text)
        except ValueError:
            if time.time() - t0 > wait:
                raise
            time.sleep(0.15)


def c_item(a, text, list=None, double=False):
    """Click an entry of a list or grid (the catalog's tiles, the people of a chooser): the first whose text starts
    with `text` (case ignored); double: as a double click (the catalog: take it)."""
    def work():
        from PySide6 import QtCore, QtWidgets
        from PySide6.QtTest import QTest
        views = [w for w in a._all() if isinstance(w, QtWidgets.QAbstractItemView) and w.isVisible()]
        if list is not None:
            views = [a._widget(list)]
        want = text.strip().lower()
        seen = []
        for v in views:
            m = v.model()
            if m is None:
                continue
            for r in range(min(m.rowCount(), 2000)):
                idx = m.index(r, 0)
                label = " ".join(str(m.data(idx) or "").split())
                seen.append(label)
                if label.lower().startswith(want):
                    v.scrollTo(idx)
                    rect = v.visualRect(idx)
                    v.setCurrentIndex(idx)
                    if double:
                        QTest.mouseDClick(v.viewport(), QtCore.Qt.LeftButton, QtCore.Qt.NoModifier, rect.center())
                    else:
                        QTest.mouseClick(v.viewport(), QtCore.Qt.LeftButton, QtCore.Qt.NoModifier, rect.center())
                    return {"item": label, "row": r}
        raise ValueError(f"no entry starting with {text!r} (first ones: {seen[:15]})")
    return a.ui(work)


def _menu_once(a, text):
    def work():
        from PySide6 import QtWidgets
        for m in QtWidgets.QApplication.topLevelWidgets():
            if isinstance(m, QtWidgets.QMenu) and m.isVisible():
                for act in m.actions():
                    if act.text().replace("&", "") == text:
                        m.close()
                        act.trigger()
                        return {"menu": text}
        lists = [w for w in a._all() if isinstance(w, QtWidgets.QFrame) and w.objectName() == "inline"
                 and w.isVisible()]
        for lst in lists:
            for b in lst.findChildren(QtWidgets.QPushButton):
                if b.text().strip() == text:
                    b.click()
                    return {"inline": text}
        open_ = [act.text() for m in QtWidgets.QApplication.topLevelWidgets() if isinstance(m, QtWidgets.QMenu)
                 and m.isVisible() for act in m.actions()] + [b.text().strip() for lst in lists
                                                               for b in lst.findChildren(QtWidgets.QPushButton)]
        raise ValueError(f"no entry {text!r} in what is open: {open_}")
    return a.ui(work)


def c_shot(a, target="panel", path=None, front=False):
    """A screenshot -> png path. target: panel | game | screen | a window title | a widget id. game: the game's
    window as on screen (front=true: bring it to the front first - it must be visible)."""
    os.makedirs(SHOTS, exist_ok=True)
    path = path or os.path.join(SHOTS, f"{time.strftime('%H%M%S')}_{str(target).replace(' ', '_')[:30]}.png")
    if target in ("game", "screen"):
        from PIL import ImageGrab
        if target == "game":
            from . import bg
            if bg.window() and bg.running():            # the game in the background: its window, never in front
                return bg.shot(path)
            from .cursor import activate, client_rect_on_screen
            if front:
                activate(a.ed.hwnd)
                time.sleep(0.4)
            x, y, w, h = client_rect_on_screen(a.ed.hwnd)
            img = ImageGrab.grab((x, y, x + w, y + h), all_screens=True)
        else:
            img = ImageGrab.grab(all_screens=True)
        img.save(path)
        return path

    if target == "view":
        return _view_shot(a, path)

    def work():
        from PySide6 import QtWidgets
        if target == "panel":
            w = a.ed.panel
        elif isinstance(target, int) or str(target).isdigit():
            w = a._widget(int(target))
        else:
            ws = [t for t in QtWidgets.QApplication.topLevelWidgets() if t.isVisible() and t.windowTitle() == target]
            if not ws:
                raise ValueError(f"no window {target!r}")
            w = ws[0]
        if not w.grab().save(path):
            raise RuntimeError("could not save " + path)
        return path
    return a.ui(work)


def _view_shot(a, path):
    """What the user sees: the game's picture with Conjunction's windows (overlay, bar, panel, catalog windows) drawn
    over it where they stand - also for the game in the background, whose windows nobody sees (bg.py)."""
    import tempfile
    from .cursor import client_rect_on_screen
    game_png = os.path.join(tempfile.gettempdir(), "cj_view_game.png")
    c_shot(a, "game", game_png)

    def work():
        from PySide6 import QtCore, QtGui, QtWidgets
        gx, gy, gw, gh = client_rect_on_screen(a.ed.hwnd)
        game = QtGui.QImage(game_png)
        wins = [w for w in QtWidgets.QApplication.topLevelWidgets()
                if w.isVisible() and w.width() > 2 and w.height() > 2]
        area = QtCore.QRect(gx, gy, gw, gh)
        for w in wins:
            area = area.united(w.frameGeometry())
        img = QtGui.QImage(area.size(), QtGui.QImage.Format_ARGB32)
        img.fill(QtGui.QColor("#101012"))
        p = QtGui.QPainter(img)
        p.drawImage(gx - area.x(), gy - area.y(), game)
        hud = getattr(a.ed, "hud", None)
        order = ([hud] if hud in wins else []) + [w for w in wins if w is not hud]     # the overlay first
        for w in order:
            g = w.frameGeometry()
            p.drawPixmap(g.x() - area.x(), g.y() - area.y(), w.grab())
        p.end()
        if not img.save(path):
            raise RuntimeError("could not save " + path)
        return path
    return a.ui(work)


def c_eval(a, code):
    """Python inside Conjunction (the expert's way to everything): ed, panel, board, project, Q (quest_nodes), D
    (dialogue), agent are there; the value of the last line is the result."""
    def work():
        from . import dialogue, quest_nodes
        ns = a.ns
        ns.update(ed=a.ed, panel=a.ed.panel, board=getattr(a.ed.panel, "board", None), project=a.ed.project,
                  Q=quest_nodes, D=dialogue, agent=a)      # (agent._widget(id): a widget by its id)
        tree = ast.parse(code)
        last = tree.body.pop() if tree.body and isinstance(tree.body[-1], ast.Expr) else None
        exec(compile(tree, "<agent>", "exec"), ns)
        if last is not None:
            return eval(compile(ast.Expression(last.value), "<agent>", "eval"), ns)
        return None
    out = a.ui(work)
    try:
        json.dumps(out)
        return out
    except TypeError:
        return repr(out)[:4000]


def c_quest(a, set=None):
    """The project's quest (nodes, links, steps); set: replace it (saved, the Quest tab shows it)."""
    def work():
        p = a.ed.project
        if set is not None:
            p.meta["quest"] = set
            p.save_meta()
            board = getattr(a.ed.panel, "board", None)
            if board is not None:
                board.sync()
        return p.meta.get("quest")
    return a.ui(work)


def c_places(a, place=None, set=None):
    """The places and what is placed in them; place + set: replace that place's dict (saved)."""
    def work():
        p = a.ed.project
        if place is not None and set is not None:
            p.places[place] = set
            p.save_place(place)
        return p.places if place is None else p.places.get(place)
    return a.ui(work)


def c_build(a, play=False, test_from=None, wait=False, timeout=900):
    """Build: play=false only checks (radish, the quest played through); play=true: Build & Play (quick save,
    game restarted with the quest, the save loaded). wait=true: until it is done -> its log."""
    def work():
        p = a.ed.panel
        p.tabs.setCurrentIndex(3)
        p._build(play, test_from=test_from)
        return True
    a.ui(work)
    if not wait:
        return {"started": True}
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(1.0)
        st = c_build_log(a)
        if st["done"]:
            return st
    return dict(c_build_log(a), timeout=True)


def c_build_log(a, tail=60):
    """The build's log (its last lines) and whether it is done."""
    def work():
        p = a.ed.panel
        text = p.log.toPlainText()
        lines = text.splitlines()
        done = p.b_play.isEnabled() and p.b_check.isEnabled()
        return {"done": done, "failed": any(ln.startswith("[failed]") for ln in lines), "log": lines[-tail:]}
    return a.ui(work)


# --- the game
def c_game(a, cmds, wait=1.0):
    """Exec commands in the game (cj_* of Conjunction's mod, or any exec function) -> the lines it sent back."""
    from . import gamelink
    if isinstance(cmds, str):
        cmds = [cmds]
    start = gamelink.mark()
    for c in cmds:
        if not a.ed.link.exec(c):
            raise RuntimeError("the game does not answer (not running, or loading)")
    a.ed.link.flush()
    time.sleep(float(wait))
    return gamelink.since(start)[1]


def c_state(a, facts=()):
    """Where the player is, the tracked quest and its objectives, and the facts asked for."""
    cmds = ["cj_where()", "cj_quest()"] + [f'cj_fact("{f}")' for f in facts]
    return c_game(a, cmds, wait=1.0)


SCAN = {"esc": 0x01, "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06, "6": 0x07, "7": 0x08, "8": 0x09,
        "9": 0x0A, "0": 0x0B, "tab": 0x0F, "q": 0x10, "w": 0x11, "e": 0x12, "r": 0x13, "t": 0x14, "y": 0x15,
        "u": 0x16, "i": 0x17, "o": 0x18, "p": 0x19, "enter": 0x1C, "ctrl": 0x1D, "a": 0x1E, "s": 0x1F, "d": 0x20,
        "f": 0x21, "g": 0x22, "h": 0x23, "j": 0x24, "k": 0x25, "l": 0x26, "shift": 0x2A, "z": 0x2C, "x": 0x2D,
        "c": 0x2E, "v": 0x2F, "b": 0x30, "n": 0x31, "m": 0x32, "alt": 0x38, "space": 0x39, "f1": 0x3B, "f2": 0x3C,
        "f3": 0x3D, "f4": 0x3E, "f5": 0x3F, "f6": 0x40, "f7": 0x41, "f8": 0x42, "f9": 0x43, "f10": 0x44,
        "up": 0xC8, "left": 0xCB, "right": 0xCD, "down": 0xD0}


def _send_key(code, up):
    import ctypes
    import ctypes.wintypes as wt

    class KI(ctypes.Structure):
        _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD), ("time", wt.DWORD),
                    ("dwExtraInfo", ctypes.c_size_t)]

    class INPUT(ctypes.Structure):
        class U(ctypes.Union):
            _fields_ = [("ki", KI), ("pad", ctypes.c_byte * 32)]
        _anonymous_ = ("u",)
        _fields_ = [("type", wt.DWORD), ("u", U)]
    flags = 0x0008 | (0x0002 if up else 0)                # KEYEVENTF_SCANCODE (| KEYUP)
    if code > 0x80:
        flags |= 0x0001                                     # extended: the arrow keys
        code &= 0x7F
    from .keyboard import OWN_KEYS
    inp = INPUT(type=1, ki=KI(0, code, flags, 0, OWN_KEYS))      # (marked: typing leaves them to the game)
    ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def c_keys(a, keys, hold=0.15, gap=0.15, front=True):
    """Press keys in the game (scan codes, as a keyboard does): keys = ["e"], ["space"], ["w:2.0"] (held 2 s),
    ["shift+w:1.5"]. front=true: the game comes to the front first (it only reads keys then). The game in the
    background (bg.py): its own virtual keyboard, nothing comes to the front."""
    from . import bg
    if bg.running():
        return bg.keys(keys, hold, gap)
    if front and a.ed.hwnd:
        from .cursor import activate
        activate(a.ed.hwnd)
        time.sleep(0.3)
    done = []
    for k in ([keys] if isinstance(keys, str) else keys):
        name, _, secs = k.partition(":")
        parts = name.lower().split("+")
        codes = [SCAN[p] for p in parts]
        for c in codes:
            _send_key(c, False)
        time.sleep(float(secs) if secs else hold)
        for c in reversed(codes):
            _send_key(c, True)
        done.append(k)
        time.sleep(gap)
    return done


def c_mouse(a, dx=0, dy=0, click=None, front=True, hold=0.06):
    """Move the mouse by dx, dy (relative: the camera turns; in the game's menus its cursor moves - an absolute
    position does not reach it) and/or click (left | right | middle), held `hold` s (the witcher senses: middle,
    held ~1.5 s). The game in the background (bg.py): its own virtual mouse."""
    import ctypes
    from . import bg
    if bg.running():
        return bg.mouse(dx, dy, click, hold)
    if front and a.ed.hwnd:
        from .cursor import activate
        activate(a.ed.hwnd)
        time.sleep(0.2)
    u = ctypes.windll.user32
    steps = max(1, int(max(abs(dx), abs(dy)) / 40))
    for _ in range(steps):
        u.mouse_event(0x0001, int(dx / steps), int(dy / steps), 0, 0)
        time.sleep(0.01)
    if click:
        down, up = {"left": (0x0002, 0x0004), "right": (0x0008, 0x0010), "middle": (0x0020, 0x0040)}[click]
        u.mouse_event(down, 0, 0, 0, 0)
        time.sleep(float(hold))
        u.mouse_event(up, 0, 0, 0, 0)
    return {"moved": [dx, dy], "click": click}


def c_goto(a, ref=None, x=None, y=None, z=None, yaw=0.0, before=2.0):
    """Teleport the player: to a placed object (ref 'place/id': in front of it, facing it) or to x, y, z."""
    import math
    if ref is not None:
        place, _, oid = ref.partition("/")
        o = next((o for o in a.ed.project.places[place]["objects"] if o.get("id") == oid), None)
        if o is None:
            raise ValueError(f"nothing placed as {ref}")
        ox, oy, oz = o["pos"]
        face = math.radians(float(o["rot"][2]))
        # in front of it (its yaw: where it looks), turned towards it
        x, y, z = ox - math.sin(face) * before, oy + math.cos(face) * before, oz
        yaw = (float(o["rot"][2]) + 180.0) % 360.0
    return c_game(a, [f"cj_teleport({x}, {y}, {z}, {yaw})"], wait=1.5)


def _floats(text, key):
    """The numbers after `key=` in a game line ('player=[1.0, 2.0, 3.0, 1.0]' or '1.0 2.0 3.0')."""
    import re
    part = text.split(key + "=", 1)[1] if key + "=" in text else ""
    return [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", part.split(" cam=")[0].split(" dir=")[0])]


def c_ground_check(a):
    """Lift the project's objects that are under the ground (near the player) onto it -> what was lifted."""
    lines = []
    fixed = a.ed.ground_check(log=lines.append)
    return {"fixed": [{"place": p, "what": w, "from": o, "to": n} for p, w, o, n in fixed], "log": lines}


def c_where(a):
    """The player's position and the camera (x, y, z each) and the world."""
    lines = c_game(a, ["cj_where()"], wait=0.6)
    line = next((ln for ln in lines if ln.startswith("where ")), None)
    if line is None:
        raise RuntimeError("the game did not say where (loading? not running?)")
    world = line.split("world=", 1)[1].split(" ", 1)[0]
    return {"world": world, "player": _floats(line, "player")[:3], "cam": _floats(line, "cam")[:3],
            "dir": _floats(line, "dir")[:3]}


def c_ground(a, x, y, z):
    """The height of what stands at x, y (a ray down from z + 5 m) - None: nothing there."""
    lines = c_game(a, [f"cj_probe({x}, {y}, {z})"], wait=0.5)
    line = next((ln for ln in lines if ln.startswith("probe ")), "")
    return float(line.split("top=", 1)[1].split()[0]) if "top=" in line else None


def c_place(a, template, x=None, y=None, z=None, yaw=0.0, ahead=None, side=0.0, ground=True):
    """Place something in the world as a click does (the game reports it, the place file gets it, a quest card
    waiting for 'Create a new ...' takes it). At x, y (z: the ground there), or ahead=metres in front of the player
    (side: metres to the right). -> the object (place, index, its entry)."""
    import math
    if ahead is not None:
        w = c_where(a)
        px, py, pz = w["player"]
        dx, dy = w["dir"][0], w["dir"][1]
        n = math.hypot(dx, dy) or 1.0
        dx, dy = dx / n, dy / n
        x, y, z = px + dx * ahead + dy * side, py + dy * ahead - dx * side, pz
    if z is None:
        z = c_where(a)["player"][2]
    if ground:
        top = c_ground(a, x, y, z)
        z = top if top is not None else z
    before = a.ui(lambda: len(a.ed.project.places.get(a.ed.place, {}).get("objects", [])))
    c_game(a, [f'cj_place_at("{template}", {x:.3f}, {y:.3f}, {z:.3f}, 0, 0, {yaw})'], wait=1.0)
    t0 = time.time()
    while time.time() - t0 < 5:
        objs = a.ui(lambda: list(a.ed.project.places.get(a.ed.place, {}).get("objects", [])))
        if len(objs) > before:
            return {"place": a.ed.place, "index": len(objs) - 1, "object": objs[-1]}
        time.sleep(0.3)
    raise RuntimeError("the game placed nothing (edit mode off? a template the game does not know?)")


def c_point(a, x, y, z=None):
    """Answer Conjunction when it waits for a point clicked in the world (a spot, where something stands): x, y (z: the
    ground there)."""
    if z is None:
        z = c_ground(a, x, y, c_where(a)["player"][2]) or 0.0

    def work():
        r = a.ed.request
        if not r or r.get("how") != "point":
            raise ValueError(f"Conjunction waits for no point (it waits for: {r and r.get('how')})")
        a.ed.request = None
        r["done"](a.ed.place, [float(x), float(y), float(z)])
        return [x, y, z]
    return a.ui(work)


def c_tab(a, text):
    """Switch a tab bar to the tab `text` (the panel's Catalog / Places / Quest / Build, a catalog's tabs)."""
    def work():
        from PySide6 import QtWidgets
        seen = []
        for bar in [w for w in a._all() if isinstance(w, QtWidgets.QTabBar) and w.isVisible()]:
            for i in range(bar.count()):
                seen.append(bar.tabText(i))
                if _norm(bar.tabText(i)) == _norm(text):
                    bar.setCurrentIndex(i)
                    return {"tab": bar.tabText(i)}
        raise ValueError(f"no tab {text!r} (tabs: {seen})")
    return a.ui(work)


DEG_PER_PX = 0.3            # mouse x -> camera yaw (measured 01.10.: linear, right turns clockwise)


def _target(a, ref=None, x=None, y=None):
    if ref is not None:
        place, _, oid = ref.partition("/")
        o = a.ui(lambda: next((dict(o) for o in a.ed.project.places.get(place, {}).get("objects", [])
                               if o.get("id") == oid), None))
        if o is None:
            raise ValueError(f"nothing placed as {ref}")
        return o["pos"][0], o["pos"][1]
    return float(x), float(y)


def c_face(a, ref=None, x=None, y=None):
    """Turn the camera - and with it where the player walks - towards a placed object (ref) or x, y. -> metres."""
    import math
    tx, ty = _target(a, ref, x, y)
    w = c_where(a)
    px, py = w["player"][:2]
    want = math.degrees(math.atan2(ty - py, tx - px))
    now = math.degrees(math.atan2(w["dir"][1], w["dir"][0]))
    delta = (want - now + 180) % 360 - 180
    c_mouse(a, dx=int(round(-delta / DEG_PER_PX)))
    return round(math.hypot(tx - px, ty - py), 2)


def c_walk(a, ref=None, x=None, y=None, stop=1.8, run=False, tries=10):
    """Walk to a placed object (ref) or x, y as a player does (turn, W held, again) until within `stop` metres -> the
    metres left. A person to talk to: then keys ["e"]."""
    import math
    for _ in range(tries):
        dist = c_face(a, ref, x, y)
        if dist <= stop:
            return dist
        secs = max(0.3, min(3.0, (dist - stop) / (5.0 if run else 3.2)))
        c_keys(a, [("shift+w" if run else "w") + f":{secs:.2f}"])
        time.sleep(0.3)
    tx, ty = _target(a, ref, x, y)
    w = c_where(a)
    return round(math.hypot(tx - w["player"][0], ty - w["player"][1]), 2)


def c_go(a, ref=None, x=None, y=None, z=None, run=True, timeout=120.0, stop=1.5):
    """The player goes there himself (Maxim 02.10.: "tell Geralt where to go"): on the navmesh, around houses and
    fences, as an NPC walks - to a placed object (ref 'place/id': in front of it) or x, y (, z). Waits until he is
    there or stops -> {"left": metres to go, "secs", "pos"}. Talking to a person afterwards: keys ["e"]."""
    import math
    if ref is not None:
        place, _, oid = ref.partition("/")
        o = a.ui(lambda: next((dict(o) for o in a.ed.project.places.get(place, {}).get("objects", [])
                               if o.get("id") == oid), None))
        if o is None:
            raise ValueError(f"nothing placed as {ref}")
        ox, oy, oz = o["pos"]
        w = c_where(a)
        dx, dy = w["player"][0] - ox, w["player"][1] - oy
        n = math.hypot(dx, dy) or 1.0
        x, y, z = ox + dx / n * stop, oy + dy / n * stop, oz          # (the side he comes from, `stop` m short)
    if z is None:
        z = c_where(a)["player"][2]
    x, y, z = float(x), float(y), float(z)
    c_game(a, [f"cj_player_go({x:.3f}, {y:.3f}, {z:.3f}, {'true' if run else 'false'})"], wait=0.6)
    t0, pos = time.time(), None
    while time.time() - t0 < float(timeout):
        line = next((ln for ln in c_game(a, ["cj_player_go_state()"], wait=0.4)
                     if ln.startswith("player_go_state")), "")
        if "pos=" in line:
            pos = _floats(line.split("|moving=")[0], "pos")[:3]
        if "state=CjGo" not in line:
            break
        time.sleep(0.8)
    else:
        c_game(a, ["cj_player_stop()"], wait=0.3)
    left = round(math.hypot(x - pos[0], y - pos[1]), 2) if pos else None
    return {"left": left, "secs": round(time.time() - t0, 1), "pos": pos}


def c_frames(a, n=3, every=1.5, scale=0.375, name="frames"):
    """n screenshots of the game, `every` s apart (a talk, a fight going on) -> their paths (scaled down)."""
    from PIL import ImageGrab
    from .cursor import client_rect_on_screen
    os.makedirs(SHOTS, exist_ok=True)
    x, y, w, h = client_rect_on_screen(a.ed.hwnd)
    out = []
    for k in range(int(n)):
        if k:
            time.sleep(float(every))
        img = ImageGrab.grab((x, y, x + w, y + h), all_screens=True)
        if scale != 1:
            img = img.resize((int(w * scale), int(h * scale)))
        p = os.path.join(SHOTS, f"{time.strftime('%H%M%S')}_{name}_{k}.png")
        img.save(p)
        out.append(p)
    return out


def c_wait(a, seconds=1.0):
    """Wait (the game and Conjunction go on meanwhile)."""
    time.sleep(float(seconds))
    return seconds


COMMANDS = {n[2:]: f for n, f in globals().items() if n.startswith("c_") and callable(f)}


def serve(ed):
    """Start the server for the editor `ed` (once; a port in use: a note, no server)."""
    try:
        from . import config
        port = config.agent_port(int(config.load().get("agent_port", PORT)))   # (the background suite: its own)
        return Agent(ed, port)
    except OSError as ex:
        print(f"[agent] not served: {ex}", flush=True)
        return None


if __name__ == "__main__":
    main()
