"""Editor session: the running game is the editor, this is its other half - with its own HUD over the game.

    python -m conjunction.editor <project dir> --place <place> [--template <depot path>] [--new "<name>"]

While the game window is in front:
  F8                    editor on / off (the game's HUD goes, ours comes; the camera flies freely)
  W A S D, Space, X     fly forward / left / back / right, up, down (Ctrl is for Ctrl+Z ..., Alt for Alt+Tab); F held
                        + wheel: faster / slower
  right mouse held      look around; a short right click without moving deletes one of ours under the cursor
  1 / 2                 place mode (preview follows the cursor, left click places) / select mode (left click selects
                        one of ours, drag its X / Y / Z arrows to move it, Del deletes it)
  mouse wheel           turn 10 deg per notch around the up axis (Shift: 1 deg); with a rotate key held around
                        another axis (config `rotate_keys`, default R = pitch, Tab = roll)
  Ctrl+D / Ctrl+Z       duplicate the selected object / undo
The HUD has buttons for the modes, collision on / off (on: dragged objects stay on surfaces) and music on / off.
Every change the game reports (through the script extender, gamelink.py) lands in <project>/places/<place>.yml
right away.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import math
import os
import queue
import subprocess
import sys
import threading
import time

os.environ.setdefault("QT_ENABLE_HIGHDPI_SCALING", "0")   # physical pixels, like the game and Win32

from PySide6 import QtCore, QtGui, QtWidgets  # noqa: E402

from . import bg  # noqa: E402
from . import config  # noqa: E402
from . import plugins  # noqa: E402
from .cursor import activate, client_rect_on_screen, game_window, pressed, user32  # noqa: E402
from . import gamelink  # noqa: E402
from .gamelink import GameLink  # noqa: E402
from .hud import RESERVED, Hud  # noqa: E402
from .keyboard import KeyRouter  # noqa: E402
from .tooltips import install as install_tips  # noqa: E402
from .panel import Panel  # noqa: E402
from .project import Project, worlds  # noqa: E402

SEE_THROUGH = 0.1               # how much of the panel shows while placing in the world (90 % see-through)

VK = dict(LBUTTON=0x01, RBUTTON=0x02, TAB=0x09, SHIFT=0x10, CTRL=0x11, ALT=0x12, SPACE=0x20, DELETE=0x2E,
          K1=0x31, K2=0x32, C=0x43, Z=0x5A, F8=0x77, END=0x23, V=0x56, W=0x57, A=0x41, S=0x53, D=0x44, H=0x48,
          R=0x52, X=0x58,
          ESC=0x1B, RETURN=0x0D, BACK=0x08, F11=0x7A)
# keys an action can have (hud.py): letters, digits, F1..F12
KEY_VK = dict({chr(c): c for c in range(0x41, 0x5B)}, **{chr(c): c for c in range(0x30, 0x3A)},
              **{f"F{i}": 0x6F + i for i in range(1, 13)})
RATE = 60.0
LOOK_DEG_PER_PX = 0.15
WHEEL_DEG = 10.0
CLICK_S = 0.3               # a right click shorter than this, without moving, deletes
GIZMO_M = 0.8               # arrow length (m)
GIZMO_PICK_PX = 14
GIZMO_FREE_PX = 11          # the middle handle: moves the selection freely over the surfaces
UNDO_MAX = 200
PLACE_OPTS = {"grid": 0.0, "turn": WHEEL_DEG, "align": False, "random": False, "light": 0}
GRID_STEPS = [0.0, 0.1, 0.25, 0.5, 1.0, 2.0]
TURN_STEPS = [1.0, 5.0, 10.0, 15.0, 45.0, 90.0]
# z-order of the overlay (Editor.stack); handles are pointer sized - HWND_TOPMOST (-1) must arrive as such
HWND_TOP, HWND_TOPMOST, HWND_NOTOPMOST, GW_HWNDPREV = 0, -1, -2, 3
SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE, WS_EX_TOPMOST = 0x1, 0x2, 0x10, 0x8
_SetWindowPos = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                   wt.UINT)(("SetWindowPos", ctypes.windll.user32))
_GetWindow = ctypes.WINFUNCTYPE(wt.HWND, wt.HWND, wt.UINT)(("GetWindow", ctypes.windll.user32))
GWL_EXSTYLE, WS_EX_TRANSPARENT, WS_EX_LAYERED, WS_EX_NOACTIVATE = -20, 0x20, 0x80000, 0x08000000


LIVE_BUILD = False      # Build & Play into the running game (TW3SE livedlc): off - two runs loaded at once (07.10.)
RETIRE_VERSION = 2     # what a run does when a newer one comes: 2 - its people out at once (CjRunGone)


class _CURSORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wt.DWORD), ("flags", wt.DWORD), ("hCursor", wt.HANDLE), ("ptScreenPos", wt.POINT)]


def _cursor_hidden():
    """Does Windows show no mouse cursor right now (the game hid it)?"""
    ci = _CURSORINFO()
    ci.cbSize = ctypes.sizeof(_CURSORINFO)
    if not ctypes.windll.user32.GetCursorInfo(ctypes.byref(ci)):
        return False
    return not (ci.flags & 1) or not ci.hCursor        # CURSOR_SHOWING


class WheelHook:
    """Low-level mouse hook: collects wheel notches (the wheel cannot be polled like keys)."""
    WH_MOUSE_LL, WM_MOUSEWHEEL = 14, 0x020A

    def __init__(self):
        from . import bg
        self.notches = 0
        self.lock = threading.Lock()
        if not bg.BACKGROUND:
            threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        class MSLL(ctypes.Structure):
            _fields_ = [("pt", wt.POINT), ("mouseData", wt.DWORD), ("flags", wt.DWORD), ("time", wt.DWORD),
                        ("extra", ctypes.c_void_p)]
        proto = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_int, wt.WPARAM, wt.LPARAM)

        def cb(code, wparam, lparam):
            if code >= 0 and wparam == self.WM_MOUSEWHEEL:
                d = ctypes.c_short(ctypes.cast(lparam, ctypes.POINTER(MSLL)).contents.mouseData >> 16).value
                with self.lock:
                    self.notches += d / 120.0
            return user32.CallNextHookEx(None, code, wparam, ctypes.c_void_p(lparam))
        self._cb = proto(cb)
        user32.CallNextHookEx.argtypes = [ctypes.c_void_p, ctypes.c_int, wt.WPARAM, ctypes.c_void_p]
        user32.SetWindowsHookExW.argtypes = [ctypes.c_int, proto, ctypes.c_void_p, wt.DWORD]
        user32.SetWindowsHookExW(self.WH_MOUSE_LL, self._cb, None, 0)
        msg = wt.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))

    def take(self):
        from . import bg
        if bg.BACKGROUND:
            return bg.take_wheel()
        with self.lock:
            n, self.notches = self.notches, 0
        return n


def click_through(w, on):
    """A window of the panel lets the mouse through to the game behind it (WS_EX_TRANSPARENT) - or not (always in
    the background: Maxim's clicks are never Conjunction's)."""
    from . import bg
    on = on or bg.BACKGROUND
    hwnd = int(w.winId())
    st = user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
    want = (st | WS_EX_TRANSPARENT | WS_EX_LAYERED) if on else (st & ~WS_EX_TRANSPARENT)
    if want != st:
        user32.SetWindowLongW(hwnd, GWL_EXSTYLE, want)


class Camera:
    """The editor camera, owned by the app: the same axes as the game's CjFlyAxes (VecFromHeading convention is
    taken from the pose the game reports at the start)."""

    def __init__(self):
        self.pos, self.pitch, self.yaw, self.fov = [0.0, 0.0, 0.0], 0.0, 0.0, 60.0
        self.heading = lambda y: (-math.sin(y), math.cos(y))
        self.ready = False

    def from_game(self, parts):
        x, y, z, pitch, yaw, fx, fy, fz, fov = (float(v) for v in parts)
        self.pos, self.pitch, self.yaw, self.fov = [x, y, z], pitch, yaw, fov
        cands = [lambda a: (-math.sin(a), math.cos(a)), lambda a: (math.sin(a), math.cos(a)),
                 lambda a: (math.cos(a), math.sin(a)), lambda a: (-math.cos(a), -math.sin(a)),
                 lambda a: (math.sin(a), -math.cos(a)), lambda a: (-math.sin(a), -math.cos(a))]
        n = math.hypot(fx, fy) or 1.0
        self.heading = max(cands, key=lambda h: h(math.radians(yaw))[0] * fx / n + h(math.radians(yaw))[1] * fy / n)
        self.ready = True

    def axes(self):
        p = math.radians(self.pitch)
        hx, hy = self.heading(math.radians(self.yaw))
        f = (hx * math.cos(p), hy * math.cos(p), math.sin(p))
        rx, ry = self.heading(math.radians(self.yaw - 90))
        r = (rx, ry, 0.0)
        u = (r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0])
        return f, r, u

    def project(self, p, w, h):
        """World point -> window pixels (None behind the camera)."""
        f, r, u = self.axes()
        d = [p[i] - self.pos[i] for i in range(3)]
        zc = sum(d[i] * f[i] for i in range(3))
        if zc <= 0.05:
            return None
        tv = math.tan(math.radians(self.fov) / 2)
        th = tv * w / h
        sx = (sum(d[i] * r[i] for i in range(3)) / zc / th + 1) / 2
        sy = (1 - sum(d[i] * u[i] for i in range(3)) / zc / tv) / 2
        return sx * w, sy * h


class Editor:
    def __init__(self, project, place, template, hwnd):
        from .project import Project, own_copy
        if own_copy(project.path) != project.path:      # one of Conjunction's examples: never edited in place, by
            print(f"[editor] {project.path} is an example: its own copy is opened", flush=True)   # any way in (06.10.)
            project = Project(own_copy(project.path))
        self.project, self.place, self.hwnd = project, place, hwnd
        self.template = template or ""      # nothing chosen: place mode shows nothing until the catalog gives it
        self.link = GameLink(robust=True)
        self.cam = Camera()
        self.mode = "look"                  # look / select / place (keys 1 2 3 by default)
        self.collide, self.music_off, self.editing = True, False, False
        self.edit_existing = False          # pick/move/delete things already in the world, not only our placed
        self.sound_off = bool(config.load().get("sound_off"))    # the game's sound, a setting of the bar
        self.sound_paused = None                    # what Conjunction last told the game: True paused, False playing
        self.catalog_screen = config.load().get("catalog_screen", "game")     # game / second
        self.selected = None                # position of the selected object
        self.drag = None                    # {"axis", "start_pos", "start_mouse"}
        self.z_top, self.panel_away = None, False   # overlay z-order: on top / above the game / unknown (stack)
        self.opts = dict(PLACE_OPTS, **config.load().get("place_opts", {}))      # grid, turn, align, random
        self.group = []                     # positions of the rest of the selection (Shift+click)
        self.lamp = False                   # H: the lamp at the camera
        self.snap = False                   # Snap to ground (the strip in select mode)
        self.lamp_level = 0                 # H held + wheel: its strength in steps (power 1.5 ** level)
        self.lamp_scrolled = False          # the wheel turned while H was held: letting go does not switch it
        self.fly_speed = float(config.load().get("fly_speed", 8.0))     # m/s, its key held + the wheel changes it
        self.clipboard, self.paste_pending = [], False     # Ctrl+C: [(template, pos, rot)]
        self.look_from, self.look_t, self.looked, self.flying = None, 0.0, False, False
        self.restarting, self.next_find, self.saved_locked = False, 0.0, False
        self.next_pause_off = 0.0               # when the game's pause menu is kept shut again (cj_pause_menu_off)
        self.last_where = None                  # the player's position the game said last (cj_where)
        self.last_heading = None                # and which way they look
        self.path_tool = None                   # a path being drawn in the world (pathtool.py)
        self.terrain_tool = None                # the terrain brush (terraintool.py), made when Terrain is first on
        self.path_pending = False               # the game is asked for the ground under a path click
        self.undo, self.undoing = [], 0
        self.last_pick = None
        # the quest board waits for an object: {"how": "pick" | "create", "kind": "people" | "creatures" | "things",
        # "done": callback(place, index)} - picked by a click in select mode, or the next one placed
        self.request = None
        self.seeing_through = False             # see_through(): the overlay lets the clicks through to the world
        # the quest being played: objective caption -> status (1 active, 2 done, 3 failed), from the game
        self.live, self.live_next, self.live_seen = {}, 0.0, {}
        cfg = config.load()
        # pitch with R (Alt flies down since 06.10.)
        self.rotate_keys = {a: VK[k] for a, k in cfg.get("rotate_keys", {"pitch": "R", "roll": "TAB"}).items()}
        self.keys = sorted(set(VK.values()) | set(KEY_VK.values()))
        self.cleared_old = False                # an earlier suite's editing copies, gone once the game is found
        self.prev = {k: False for k in self.keys}
        self.q, self.stop = queue.Queue(), threading.Event()
        threading.Thread(target=gamelink.listen, args=(self.q, self.stop), daemon=True).start()
        self.wheel = WheelHook()
        self.typing = KeyRouter()             # typing into the panel without taking the focus from the game
        self.typing.owner = lambda: self.hwnd
        # a suite that ended without closing (killed, crashed) left the game in edit mode: input blocked, Geralt a
        # ghost at the camera - off first (nothing happens when it is not on)
        self.link.exec("cj_edit(false)")
        self.link.exec(f'cj_set_place("{place}")')
        self.link.exec(f'cj_set_template("{self.template}")' if self.template else "cj_clear_template()")
        self._place_look = None
        self.link.exec("cj_clear_look()")             # (a look of an earlier session would dress the preview)
        self.link.exec("cj_mode(false)")
        self.world = None                   # radish world id of the game's current world (from "edit on")
        self.plugins = plugins.get()
        for folder, err in self.plugins.failed:
            print(f"[editor] plugin {folder} skipped:\n{err}", flush=True)
        install_tips(QtWidgets.QApplication.instance())     # Conjunction's own tooltips (tooltips.py)
        from . import theme
        theme.install(QtWidgets.QApplication.instance())    # one look for the controls (theme.py)
        self.panel = Panel(self)
        self.hud = Hud(self)
        QtCore.QTimer.singleShot(2500, self.panel.load_catalog)     # built now, not at the first selection (~2 s)
        QtCore.QTimer.singleShot(3000, self._prepare_boxes)
        self.timer = QtCore.QTimer()
        self.timer.timeout.connect(self.tick)
        self.timer.start(int(1000 / RATE))
        from . import agent
        self.agent = agent.serve(self)          # an AI agent / a script drives Conjunction from outside (agent.py)

    # --- HUD actions
    @property
    def placing(self):
        return self.mode == "place"

    def set_mode(self, mode, catalog=True):
        """look: fly and look, nothing happens in the world; select: pick and move your objects; place: the catalog
        opens (catalog=False: the panel stays as it is - a quest step's chooser gave the template), what is chosen
        follows the cursor; terrain: the terrain brush (terraintool.py)."""
        if isinstance(mode, bool):                  # the older call: set_mode(placing)
            mode = "place" if mode else "select"
        from . import features
        if mode == "terrain" and not features.experimental():
            return                                  # (experimental: features.py)
        was, self.mode = self.mode, mode
        if mode != "select":
            self.selected, self.drag = None, None
            self.hud.gizmo = None
        if mode == "terrain" and self.terrain_tool is None:
            from .terraintool import TerrainTool
            self.terrain_tool = TerrainTool(self)
        elif mode != "terrain" and self.terrain_tool is not None:
            self.terrain_tool.drag = None
        self.link.exec(f"cj_mode({'true' if mode == 'place' else 'false'})")
        if mode == "place" and catalog:
            self.open_catalog()                     # also again after its window was closed
        elif mode != "place" and was == "place" and self.panel.isVisible() and self.panel.tabs.isVisible():
            self.panel.hide()
            self.typing.stop()
        self.hud.sync()

    def open_catalog(self):
        self.panel.load_catalog()
        self.panel.tabs.setCurrentIndex(0)
        if not self.panel.isVisible() or not self.panel.tabs.isVisible():
            self.toggle_panel()

    def catalog_open(self):
        return self.panel.isVisible() and self.panel.tabs.isVisible() and self.panel.tabs.currentIndex() == 0

    def close_catalog(self):
        self.panel.close_panel()
        self.hud.sync()

    def toggle_project(self):
        """The bar's Quest: the panel on the project (quest, places, build) at the quest's graph - or away."""
        if self.panel.isVisible() and self.panel.tabs.isVisible() and self.panel.tabs.currentIndex() != 0:
            self.panel.hide()
            self.typing.stop()
        else:
            if not (self.panel.isVisible() and self.panel.tabs.isVisible()):
                self.toggle_panel()
            self.panel.tabs.setCurrentWidget(self.panel.board)
        self.hud.sync()

    def open_projects(self):
        """File > Open project: the project browser over the game (one; kept among the panel's own windows, so its
        clicks are not clicks into the world and it stays above the game)."""
        from .project_browser import ProjectBrowser
        b = self.panel.windows.get("projects")
        if b is None:
            b = self.panel.windows["projects"] = ProjectBrowser(self)
        b.show_over(client_rect_on_screen(self.hwnd) if self.hwnd else (0, 0, 1600, 900))

    def set_editing(self, on):
        """Edit or play (Maxim 05.10., as in Unreal): editing - the overlay, the free camera, the game paused for the
        player; playing - the player walks the world as it is now, Esc (or F8) comes back."""
        self.editing = on
        self.link.exec(f"cj_edit({'true' if on else 'false'})")
        if on:
            self.send_place_opts()
            self.link.exec(f"cj_edit_existing({'true' if self.edit_existing else 'false'})")
        self.wheel.take()
        self.selected, self.drag, self.cam.ready = None, None, False
        self.z_top = None
        if on:
            self.hud.show()
        else:
            self.show_built()
            self.music_off = False
            self.typing.stop()
            self.hud.close_menu()
            self.hud.hide()
            self.panel.hide()
            if not getattr(self, "said_play", False):     # (once a session)
                self.said_play = True
                self.panel.notice.say("Playing. Press Esc to return to the editor")
        self.hud.sync()

    def play(self):
        """The bar's Play: walk the world as the player (no build - what was placed is in the world already)."""
        self.set_editing(False)

    def open_game_menu(self):
        """File > Game menu: the game's own menu (save, load, settings) - played, the menu open."""
        self.set_editing(False)
        self.link.exec("cj_game_menu()")

    def open_story(self, then=None):
        """The bar's Story: the story map - every quest of the game on its timeline (story_view.py), a window of
        the app's kind (it docks: at the bottom it reads like a timeline). `then`: opened from the quest's Starts -
        once a quest is picked (with / after it), the window closes and then() runs."""
        from .story_view import StoryWindow
        w = self.panel.open_window("story", "Story map", lambda: StoryWindow(self), kind="story")
        if w.body is not None and hasattr(w.body, "refresh"):
            w.body.refresh()                    # (the project's quest may have been hooked elsewhere since)
            if then is not None:
                def done(w=w):
                    w.body.on_hook = None
                    w.close()
                    then()
                w.body.on_hook = done
            else:
                w.body.on_hook = None

    def open_outliner(self):
        """The bar's Outliner: the panel on the project's places and their objects - or away."""
        if self.panel.isVisible() and self.panel.tabs.isVisible() and self.panel.tabs.currentIndex() == 1:
            self.panel.hide()
            self.typing.stop()
        else:
            if not (self.panel.isVisible() and self.panel.tabs.isVisible()):
                self.toggle_panel()
            self.panel.tabs.setCurrentIndex(1)
        self.hud.sync()

    def open_panel_tab(self, index):
        """The bar's Project menu: the panel open at that tab."""
        if not (self.panel.isVisible() and self.panel.tabs.isVisible()):
            self.toggle_panel()
        self.panel.tabs.setCurrentIndex(index)
        self.hud.sync()

    def build_play_now(self):
        """The bar's Build & Play: one click (the Build tab's button)."""
        if self.panel.b_play.isEnabled():
            self.panel._build(True)

    def panel_open(self):
        return self.panel.isVisible() and self.panel.tabs.isVisible() and self.panel.tabs.currentIndex() != 0

    def _ask_path_ground(self, a):
        self.path_pending = True                # the answer (cursor|...) goes to the path tool
        self.link.exec(f"cj_cursor_hit({a})")

    def hide_area(self, index=None):
        """A hide area of the place being edited (envhide.py): its outline drawn in the world with the path tool -
        a new one (index None) or one already there. Every point is kept as it is set; the area needs three."""
        from . import envhide
        from .pathtool import PathTool
        objs = self.project.place(self.place, self.world)["objects"]
        o = objs[index] if index is not None else None
        spec = (o or {}).get("envhide") or {}
        pts = [[o["pos"][0] + dx, o["pos"][1] + dy, o["pos"][2] + 1.0] for dx, dy in spec.get("points", [])] if o else []
        state = {"index": index}

        def keep(points):
            if len(points) < 3:
                return
            i = state["index"]
            old = objs[i] if i is not None else {}
            flags = old.get("envhide") or {}
            new = envhide.area_object(points, height=flags.get("height", 20.0), foliage=flags.get("foliage", True),
                                      terrain=flags.get("terrain", False), water=flags.get("water", False),
                                      oid=old.get("id"))
            if i is None:
                objs.append(new)
                state["index"] = i = len(objs) - 1
                self.project.name_object(self.place, i, base="hide_area")
            else:
                new["id"] = old.get("id")
                objs[i] = {**old, **new}
                self.project.save_place(self.place)
            if self.panel.isVisible():
                self.panel.sync_places()
                self.panel.show_area(self.place, state["index"])

        def done(points):
            keep(points)
            # (Maxim 06.10.: Enter, "es ist nix passiert" - the area only shows after a build)
            notice = getattr(self.panel, "notice", None)
            if notice is not None:
                notice.say(f"Hide area saved ({len(points)} points). Build & Play shows it in the game", ms=6000)

        if self.path_tool is not None:
            self.path_tool.finish()
        PathTool(self, pts, done, label="Hide area", closed=True, min_points=3, on_change=keep).start()

    def set_area(self, place, index, **flags):
        """Foliage / terrain / water / height of a hide area - takes effect with the next build."""
        o = self.project.places[place]["objects"][index]
        o["envhide"].update(flags)
        self.project.save_place(place)

    def draw_path(self, points, on_done, label="Path", closed=False, min_points=1):
        """The path tool (pathtool.py) on these points; `on_done(points)` with Enter."""
        from .pathtool import PathTool
        if self.path_tool is not None:
            self.path_tool.cancel()
        PathTool(self, points, on_done, label, closed, min_points=min_points).start()

    def doing(self):
        """What is going on right now - (text, keys) for the bar's context line, or (None, [])."""
        if self.path_tool is not None:
            return self.path_tool.doing()
        board = getattr(self.panel, "board", None)
        drawing = getattr(board, "drawing", None) if board is not None else None
        if drawing:
            return "Laying the trail", []
        r = self.request
        name = os.path.splitext(os.path.basename(self.template or ""))[0].replace("_", " ")
        if r:
            what = r.get("what")
            if r["how"] == "point":
                return (f"Pick a point · {what}" if what else "Pick a point"), ["Esc"]
            if r["how"] == "pick":
                return (f"Pick · {what}" if what else "Pick an object"), ["Esc"]
            return f"Place · {getattr(board, 'chosen_title', None) or name}", ["Esc"]    # (the catalog's name)
        if self.mode == "terrain" and self.terrain_tool is not None:
            return self.terrain_tool.doing()
        if self.mode == "place" and self.template:
            return f"Placing · {name}", ["Esc"]
        if self.mode == "select" and self.selected:
            oid = self.selected_object_id() if hasattr(self, "selected_object_id") else None
            return (f"Selected · {oid}" if oid else "Selected"), []
        return None, []

    def info_text(self):
        name = os.path.splitext(os.path.basename(self.template))[0] if self.template else "-"
        return f"{self.project.id} / {self.place}  |  {name}"

    def cycle_catalog_screen(self):
        self.catalog_screen = "second" if self.catalog_screen == "game" else "game"
        cfg = config.load()
        cfg["catalog_screen"] = self.catalog_screen
        config.save(cfg)
        self.place_panel()
        self.hud.sync()

    def toggle_collision(self):
        self.collide = not self.collide
        self.hud.sync()

    def toggle_snap(self):
        """Snap to ground: a moved object always sits on what is below it (Maxim 06.10.)."""
        self.snap = not getattr(self, "snap", False)
        self.hud.sync()

    def toggle_edit_existing(self):
        # on: a click in select mode grabs any world object (to move or delete), not only what we placed
        from . import features
        if not features.experimental():                 # (experimental: features.py - Maxim 06.10.)
            self.edit_existing = False
            return
        self.edit_existing = not self.edit_existing
        self.link.exec(f"cj_edit_existing({'true' if self.edit_existing else 'false'})")
        self.hud.sync()

    def toggle_panel(self):
        self.z_top = None
        if self.panel.isVisible() and not self.panel.tabs.isVisible():
            # only the inspector was open (an object selected): C brings the tabs next to it
            self.panel.load_catalog()
            self.panel.tabs.show()
            self.panel._tab_changed(self.panel.tabs.currentIndex())
            self.place_panel()
            self.hud.sync()
            return
        if self.panel.isVisible():
            self.panel.hide()
            self.focus_game()
        else:
            self.panel.load_catalog()
            self.panel.sync_places()
            self.panel.sync_quest()
            self.panel.sync_selected()
            self.panel.tabs.show()
            self.panel._tab_changed(self.panel.tabs.currentIndex())
            self.panel.show()
            self.place_panel()
            self.panel.raise_()             # keys stay the game's until a text field is clicked
        self.hud.sync()

    def copy_selection(self):
        """Ctrl+C: the selected object and the rest of the selection, as they stand to each other."""
        objs = self.project.places.get(self.place, {}).get("objects", [])
        out = []
        for pos in [self.selected] + self.group:
            i = self.project.find_object(self.place, pos)
            if i is not None:
                o = objs[i]
                out.append((o["template"], list(o["pos"]), list(o["rot"])))
        if out:
            self.clipboard = out
            print(f"[editor] copied {len(out)} object(s) - Ctrl+V puts them under the cursor", flush=True)

    def paste_at(self, hit):
        """Ctrl+V: the copied objects with the first one at `hit` (into the place being edited, any place)."""
        anchor = self.clipboard[0][1]
        for tpl, pos, rot in self.clipboard:
            p = [hit[i] + pos[i] - anchor[i] for i in range(3)]
            self.link.exec(f'cj_place_at("{tpl}", {p[0]:.3f}, {p[1]:.3f}, {p[2]:.3f}, '
                           f"{rot[0]}, {rot[1]}, {rot[2]})")

    def cycle_option(self, key):
        """A placing option from the bar: grid / turn step to the next value, align / random on-off; kept."""
        o = self.opts
        if key == "grid":
            o["grid"] = GRID_STEPS[(GRID_STEPS.index(o["grid"]) + 1) % len(GRID_STEPS)] \
                if o["grid"] in GRID_STEPS else GRID_STEPS[0]
        elif key == "turn":
            o["turn"] = TURN_STEPS[(TURN_STEPS.index(o["turn"]) + 1) % len(TURN_STEPS)] \
                if o["turn"] in TURN_STEPS else WHEEL_DEG
        else:
            o[key] = not o[key]
        cfg = config.load()
        cfg["place_opts"] = o
        config.save(cfg)
        self.send_place_opts()
        self.hud.sync()

    def set_option(self, key, value):
        self.opts[key] = value
        cfg = config.load()
        cfg["place_opts"] = self.opts
        config.save(cfg)
        self.send_place_opts()
        self.hud.sync()

    def toggle_senses(self):
        """V: the world as in the witcher senses (clues red, things to use highlighted) - to place clues and trails
        where the player will see them (Maxim 01.10.: 'building a quest needs the witcher view')."""
        self.senses = not getattr(self, "senses", False)
        self.link.exec(f"cj_senses({'true' if self.senses else 'false'})")
        self.hud.sync()

    def toggle_lamp(self):
        """H: the lamp flying with the camera (not kept: every editing session starts without it)."""
        self.lamp = not self.lamp
        self.link.exec(f"cj_lamp({'true' if self.lamp else 'false'})")

    def lamp_step(self, n):
        """H held + wheel: the lamp brighter (up) or dimmer (down); it comes on if it was off."""
        self.lamp_level = max(-4, min(10, self.lamp_level + n))
        self.link.exec(f"cj_lamp_power({1.5 ** self.lamp_level:.3f})")
        if not self.lamp:
            self.toggle_lamp()

    def lamp_keys(self, now, up):
        """The lamp's key: let go = on / off, held with the wheel = its strength (then letting go switches nothing)."""
        vk = KEY_VK.get(self.hud.keys.get("opt.lamp") or "")
        if not vk:
            return
        if now.get(vk):
            n = self.wheel.take()
            if n:
                self.lamp_step(n)
                self.lamp_scrolled = True
        elif up.get(vk):
            if not self.lamp_scrolled:
                self.toggle_lamp()
            self.lamp_scrolled = False

    def speed_keys(self, now):
        """The fly speed's key held: each wheel notch a quarter faster or slower (0.5 to 100 m/s), also standing
        still; kept."""
        vk = KEY_VK.get(self.hud.keys.get("opt.speed") or "")
        if not vk or not now.get(vk):
            return False
        n = self.wheel.take()
        if n:
            v = min(100.0, max(0.5, self.fly_speed * 1.25 ** n))
            self.fly_speed = round(v, 1) if v < 10 else round(v)
            cfg = config.load()
            cfg["fly_speed"] = self.fly_speed
            config.save(cfg)
            self.hud.sync()
        return True

    def send_place_opts(self):
        o = self.opts
        self.link.exec(f"cj_place_opts({o['grid']}, {'true' if o['align'] else 'false'}, "
                       f"{'true' if o['random'] else 'false'})")
        self.link.exec(f"cj_light({o.get('light', 0)})")

    def place_panel(self):
        if self.hwnd:
            self.panel.place_at(*client_rect_on_screen(self.hwnd))

    def focus_game(self):
        """The keys belong to the game again (and it is the active window - it pauses when it is not)."""
        self.typing.stop()
        activate(self.hwnd)

    def back_to_catalog(self, given_up=False):
        """Something taken from the catalog was placed, or given up (Esc): nothing follows the cursor any more and
        the catalog is there again (Maxim, 30.09.) - unless 'back to the catalog' is off (the gear): then it goes on
        being placed, as often as clicked. Esc (given_up) always ends it (Maxim 08.10.: with the gear off, Esc closed
        the catalog and the next one opened placing the same thing again). Returns whether it went back."""
        from .panel import setting
        if not getattr(self, "catalog_pick", False) or not (given_up or setting("catalog_back")):
            return False
        self.catalog_pick = False
        self.template = ""
        self.link.exec("cj_clear_template()")      # ("" cannot go through the game's command line)
        self.open_catalog()
        self.hud.sync()
        return True

    def give_focus_back(self):
        """A window of Conjunction that is never meant to be the active one became it: when a program Conjunction opened
        (Explorer, a file dialog) closes, Windows hands the focus to Conjunction, not to the game - and the game,
        thinking itself in the background, stayed silent until Maxim tabbed out and in (05.10.). The game gets it
        back. Not while a dialog of Conjunction is open, nor for its own windows that are typed into (a title, not a
        tool window: the bug report, the library)."""
        hwnd = getattr(self, "hwnd", None)
        fg = user32.GetForegroundWindow()
        if not hwnd or fg == hwnd or not self._foreground_is_ours() or user32.IsIconic(hwnd):
            return
        app = QtWidgets.QApplication.instance()
        if app.activeModalWidget() is not None or app.activePopupWidget() is not None:
            return
        w = next((t for t in app.topLevelWidgets() if t.isVisible() and int(t.winId()) == fg), None)
        tool = w is not None and (w.windowFlags() & QtCore.Qt.Tool) == QtCore.Qt.Tool
        if w is not None and w.windowTitle() and not tool:
            return
        activate(hwnd)

    def game_to_front(self):
        """A click on the overlay while another program is in front (Maxim, 30.09.: 'I have to Alt+Tab or click into
        the game'): the game comes back to the front - the overlay belongs to it, and typing into its fields only
        works while the game is in front. What is being typed stays."""
        hwnd = getattr(self, "hwnd", None)
        if hwnd and user32.GetForegroundWindow() != hwnd and not self._foreground_is_ours():
            activate(hwnd)

    def plugin_catalog(self):
        return self.plugins.catalog_sources()

    def plugin_panels(self):
        return self.plugins.panels()

    # --- the quest board asks for objects
    def request_object(self, how, kind, done, template=None, what=None):
        """how: pick (click it in the world) or create (`template`, chosen in the quest window's chooser, follows the
        cursor; the next one placed is it). The quest window stays open. `what`: what it is for, in a few words (the
        bar's context line shows it)."""
        self.request = {"how": how, "kind": kind, "done": done, "what": what}
        if how == "point":
            self.set_mode("look")               # a click is only the point, nothing gets selected
        elif how == "pick":
            self.set_mode("select")
        else:
            self.template = template
            self.link.exec(f'cj_set_template("{template}")')
            self.set_mode("place", catalog=False)
        self.focus_game()
        self.hud.sync()

    def cancel_request(self):
        if self.request:
            self.request = None
            board = getattr(self.panel, "board", None)
            if board is not None:
                board.waiting = None
            self.panel.sync_quest()
            self.hud.sync()

    def escape(self):
        """Esc stops whatever is going on: an object the quest board waits for (its preview goes, the board stays),
        placing (the preview goes), the selection."""
        picked = getattr(self, "catalog_pick", False)       # (a stand-in editor of a test has none)
        if self.mode == "place" and not self.request and picked and self.back_to_catalog(given_up=True):
            return                                      # given up: the catalog again, nothing follows the cursor
        board = getattr(self.panel, "board", None)
        if getattr(board, "drawing", None):         # a trail being drawn: stopped, nothing laid
            board.drawing = None
            if getattr(self, "editing", False):
                self.load_place()                   # its flags go
        if self.request or self.mode == "place":
            self.cancel_request()
            if self.mode == "place":                    # the preview goes; the catalog / board stays open
                self.mode = "select"
                self.link.exec("cj_mode(false)")
                self.hud.sync()
            return
        if self.selected or self.group:
            self.link.exec("cj_mode(false)")           # the game lets go of its selection too
            self.selected, self.group, self.drag = None, [], None
            self.hud.gizmo = None
            self.show_selected()
            self.hud.sync()

    def _request_answer(self, index):
        """An object was selected (pick) or placed (create): the one the board waits for, if it is of its kind."""
        from .quest import is_actor
        r = self.request
        o = self.project.places.get(self.place, {}).get("objects", [])[index]
        actor = is_actor(o)
        if (r["kind"] in ("people", "creatures")) != actor:
            print(f"[editor] not a {r['kind'][:-1] if r['kind'] != 'people' else 'person'} - pick another one",
                  flush=True)
            return
        if r["kind"] in ("containers", "loot"):
            from .quest import not_loot
            why = not_loot(o["template"])
            if why:                                     # Geralt's stash: the quest's items would never be seen
                print(f"[editor] not a container for the quest: {why} - pick another one", flush=True)
                from PySide6 import QtGui, QtWidgets
                QtWidgets.QToolTip.showText(QtGui.QCursor.pos(), why)
                return
        self.request = None
        r["done"](self.place, index)
        if r["how"] == "create":
            self.set_mode("select")
        # back to the board (it stayed open; if it was closed meanwhile, it opens again)
        if not (self.panel.isVisible() and self.panel.tabs.isVisible()):
            self.toggle_panel()
        self.panel.tabs.setCurrentWidget(self.panel.board)
        self.panel.sync_quest()
        self.hud.sync()

    def quest_refs(self):
        """'place/id' of every object the quest names (its steps, talks, clues) - for the markers."""
        import re
        text = repr(self.project.meta.get("quest") or {})
        return set(re.findall(r"'([a-z0-9_]+/[a-z0-9_]+)'", text))

    def jump_to(self, place, index):
        """The camera to an object of the project (its place becomes the one edited); a beacon marks it a while -
        under leaves, behind a wall, or not shown at all (a clue still dark), it is found (Maxim, 01.10.)."""
        if place != self.place:
            self.set_place(place)
        o = self.project.places[place]["objects"][index]
        x, y, z = o["pos"]
        self.beacon = {"pos": [x, y, z], "label": o.get("display") or o.get("id") or "", "until": time.time() + 6.0}
        self.hud.update()
        self.link.exec(f"cj_cam_to({x:.3f}, {y:.3f}, {z:.3f}, {float(o['rot'][2]):.1f})")
        self.focus_game()

    def selected_object_id(self):
        """Id of the selected object of the current place (made from its template if it has none yet)."""
        i = self.project.find_object(self.place, self.selected)
        return None if i is None else self.project.name_object(self.place, i)

    @property
    def place_look(self):
        """One look of a person chosen in the catalog: the preview wears it and each one placed gets it (None: the game
        picks one for each)."""
        return getattr(self, "_place_look", None)

    @place_look.setter
    def place_look(self, look):
        # 08.10. (Maxim): the preview that follows the cursor wore the game's pick, the one placed the chosen look -
        # the game gets the look too, dresses the preview in it, and the one placed takes the preview's
        if look == getattr(self, "_place_look", None):
            return
        self._place_look = look
        link = getattr(self, "link", None)
        if link is not None:
            link.exec(f'cj_set_look("{look}")' if look else "cj_clear_look()")

    def set_template(self, path, preview=False, variants=None, look=None):
        """preview: browsing the catalog with the arrow keys (the list stays as it is). `variants`: a catalog folder's
        templates - after each one placed, another of them at random. `look`: one look of a person - each one placed
        gets it (else the game picks one)."""
        self.variants = variants
        self.place_look = look
        if path == self.template and preview:
            return
        self.template = path
        from . import foliage
        tree = foliage.reverse_index().get((path or "").lower())
        # a plant of the foliage library: placed through its ghost (the tree alone follows the cursor, cj_set_plant)
        self.link.exec(f'cj_set_plant("{tree}")' if tree else "cj_clear_plant()")
        self.link.exec(f'cj_set_template("{path}")')
        if not self.placing:
            self.set_mode("place")
        self.hud.sync()
        if not preview:
            self.panel.refresh()

    def set_place(self, name):
        if name == self.place:
            return
        self.place = name
        self.project.place(name, self.world)
        self.link.exec(f'cj_set_place("{name}")')
        if self.editing:
            self.load_place()
        self.panel.sync_places()
        self.hud.sync()

    def switch_project(self, path):
        """Another quest, the game stays: this one's copies go, its built places show again; the other one's first
        place is loaded (when editing)."""
        from . import in_game
        from .project import Project, own_copy, remember
        path = own_copy(os.path.abspath(path))     # an example: the user's own copy (06.10.: edited in place)
        try:
            others = in_game.clear_for(path, dry=True)
        except Exception as ex:                     # noqa: BLE001 - unsure: the clean way
            others = [str(ex)]
        if others and not bg.BACKGROUND:            # the game holds another project's DLCs: it starts again
            return self.start_clean(path)           # with only this one (07.10.: nothing of another in the world)
        self.link.exec("cj_clear()")
        if self.dlc_installed():
            from .quest import is_actor
            for name, p in self.project.places.items():
                if p.get("world") == self.world and p.get("objects"):
                    self.link.exec(f'cj_layer("{self.layer_group(name)}", true)')
                    for o in p["objects"]:
                        if o.get("id") and is_actor(o):
                            self.link.exec(f"cj_hide_tag({self.project.id}_{name}_{o['id']}, false)")
        self.project = Project(path)
        remember(self.project.path)
        self.selected, self.drag, self.group, self.request = None, None, [], None
        self.undo, self.live, self.live_seen = [], {}, {}
        here = [n for n, p in self.project.places.items() if p.get("world") in (None, self.world)]
        self.place = (here or list(self.project.places) or ["main"])[0]
        self.link.exec(f'cj_set_place("{self.place}")')
        if self.editing:
            self.load_place()
        self.panel.sync_places()
        self.panel.board.close_dialogue() if self.panel.board.dialogue is not None else None
        self.panel.board.sync()
        self.panel.sync_kind()
        self.hud.sync()
        print(f"[editor] project {self.project.id}: {self.project.path}", flush=True)

    def _prepare_boxes(self):
        """The boxes of everything placed in this quest, read in the background (selection by them)."""
        from . import picking
        picking.prepare([o["template"] for p in self.project.places.values() for o in p.get("objects", [])],
                        self._depot)

    def player_here(self):
        self.link.exec("cj_player_here()")

    def layer_group(self, name):
        """The layer a built place has in the game (radish: DLC\\dlc<id>\\<id>\\<place>)."""
        return "\\".join(["DLC", f"dlc{self.project.id}", self.project.id, name])

    def dlc_installed(self):
        return os.path.isdir(os.path.join(config.load()["game"], "dlc", f"dlc{self.project.id}"))

    def load_place(self):
        """The place being edited as copies that can be changed (its built layer, if installed, goes meanwhile);
        the other places of this world show their built layers."""
        self.link.exec("cj_clear()")
        self.selected, self.drag = None, None
        if self.dlc_installed():
            from .quest import is_actor
            for name, p in self.project.places.items():
                if p.get("world") == self.world and p.get("objects"):
                    show = "false" if name == self.place else "true"
                    self.link.exec(f'cj_layer("{self.layer_group(name)}", {show})')
                    # the NPCs the built quest spawned for this place step aside while it is edited
                    for o in p["objects"]:
                        if o.get("id") and is_actor(o):
                            hide = "true" if name == self.place else "false"
                            self.link.exec(f"cj_hide_tag({self.project.id}_{name}_{o['id']}, {hide})")
        p = self.project.places.get(self.place) or {}
        if p.get("world") and p.get("world") != self.world:
            print(f"[editor] place {self.place} is in world {p.get('world')}, the game is in {self.world}", flush=True)
            return
        for o in p.get("objects", []):
            if o.get("envhide"):                    # a hide area: nothing to stand there (the build makes its entity)
                continue
            if o.get("trail"):                      # a trail: its pieces (trails.py)
                for pc in o.get("pieces") or []:
                    self.link.exec(f'cj_spawn("{pc[4]}", {pc[0]}, {pc[1]}, {pc[2]}, 0, 0, {pc[3]})')
                continue
            x, y, z = o["pos"]
            r, pi, ya = o["rot"]
            self.link.exec(f'cj_spawn("{o["template"]}", {x}, {y}, {z}, {r}, {pi}, {ya})')
            # what the inspector set up: the copy looks and holds the same
            if o.get("appearance"):
                self.link.exec(f'cj_appearance({x}, {y}, {z}, "{o["appearance"]}")')
            if "loot" in o:
                from .quest import is_actor
                clear = "false" if is_actor(o) else "true"     # a person keeps what they carry
                self.link.exec(f'cj_loot_set({x}, {y}, {z}, "{o["loot"] or "cj_none"}", {clear})')
            for entry in o.get("inventory", []):
                self.link.exec(f'cj_inv_set({x}, {y}, {z}, "{entry["item"]}", {int(entry.get("count", 1))})')
        print(f"[editor] place {self.place}: {len(p.get('objects', []))} objects loaded for editing", flush=True)

    def _hide_built_people(self):
        """The built quest's people of the place being edited hidden (their copies stand there)."""
        if not self.dlc_installed():
            return
        from .quest import is_actor
        p = self.project.places.get(self.place) or {}
        if p.get("world") not in (None, self.world):
            return
        for o in p.get("objects", []):
            if o.get("id") and is_actor(o):
                self.link.exec(f"cj_hide_tag({self.project.id}_{self.place}_{o['id']}, true)")

    def show_built(self):
        """Editing ends: the copies go (they stand frozen) and the built quest is back - its layers shown, its people
        no longer hidden, so they move and talk. What was changed and not built yet shows after Build & Play."""
        self.link.exec("cj_clear()")
        self.selected, self.drag = None, None
        if getattr(self, "senses", False):          # the witcher view was the editor's: playing starts without it
            self.senses = False
            self.link.exec("cj_senses(false)")
        if not self.dlc_installed():
            return
        from .quest import is_actor
        for name, p in self.project.places.items():
            if p.get("world") == self.world and p.get("objects"):
                if p.get("visible", "start") != "start":
                    continue                    # a place a step shows: the quest shows it, not the end of editing
                self.link.exec(f'cj_layer("{self.layer_group(name)}", true)')
                for o in p["objects"]:
                    if o.get("id") and is_actor(o):
                        self.link.exec(f"cj_hide_tag({self.project.id}_{name}_{o['id']}, false)")

    # --- the inspector's changes to the selected object (place file + the copy in the game)
    def _selected_index(self):
        return self.project.find_object(self.place, self.selected)

    def _selected_is_marker(self):
        """Is the dragged one a marker of the editor (a Go to's flag)? Asked once per drag."""
        d = self.drag or {}
        if "marker" not in d:
            i = self.project.find_object(self.place, d.get("start") or self.selected)
            objs = self.project.places.get(self.place, {}).get("objects", [])
            d["marker"] = bool(i is not None and 0 <= i < len(objs) and objs[i].get("marker"))
        return d["marker"]

    def ask_inventory(self):
        if self.selected:
            x, y, z = self.selected
            self.link.exec(f"cj_inv_list({x}, {y}, {z})")

    def set_object_item(self, item, count):
        """`count` of `item` put in by this quest (0 = none, None = one more)."""
        i = self._selected_index()
        if i is None:
            return
        o = self.project.places[self.place]["objects"][i]
        inv = [dict(e) for e in o.get("inventory", [])]
        have = next((e for e in inv if e["item"] == item), None)
        if count is None:
            count = (int(have["count"]) if have else 0) + 1
        if have:
            have["count"] = count
        else:
            inv.append({"item": item, "count": count})
        inv = [e for e in inv if int(e["count"]) > 0]
        self.project.set_object(self.place, i, inventory=inv)
        x, y, z = self.selected
        if not str(item).startswith("own:"):        # an own item exists in the game only after the build
            self.link.exec(f'cj_inv_set({x}, {y}, {z}, "{item}", {int(count)})')
        if self.panel.inspector:
            self.panel.inspector.refresh_object()

    def set_object_loot(self, loot):
        """The selected container's loot table: a name, "" = none, None = the template's again. In the game: emptied,
        filled from the table, the items that are always inside put back."""
        i = self._selected_index()
        if i is None:
            return
        o = self.project.places[self.place]["objects"][i]
        if loot is None:
            self.project.set_object(self.place, i, loot=None)
            o.pop("loot", None)
        else:
            o["loot"] = loot                        # "" (no random loot) is kept: set_object drops empty values
            self.project.save_place(self.place)
        x, y, z = self.selected
        from .quest import is_actor
        # a container is emptied and filled from the table; a person or creature keeps what they carry (added to)
        clear = "loot" in o and not is_actor(o)
        self.link.exec(f'cj_loot_set({x}, {y}, {z}, "{o.get("loot") or "cj_none"}", {"true" if clear else "false"})')
        for entry in o.get("inventory", []):
            self.link.exec(f'cj_inv_set({x}, {y}, {z}, "{entry["item"]}", {int(entry.get("count", 1))})')

    def set_object_look(self, appearance):
        i = self._selected_index()
        if i is None:
            return
        self.project.set_object(self.place, i, appearance=appearance or None)
        if appearance:
            x, y, z = self.selected
            self.link.exec(f'cj_appearance({x}, {y}, {z}, "{appearance}")')

    def toggle_sound(self):
        self.sound_off = not self.sound_off
        cfg = config.load()
        cfg["sound_off"] = self.sound_off
        config.save(cfg)
        self.keep_sound(True)
        self.hud.sync()

    def keep_sound(self, front):
        """The game's sound as it should be: paused while another program is in front or the setting is off,
        playing otherwise - told to the game only when that changes (the pause menu's own events)."""
        paused = self.sound_off or not front
        back = front and not getattr(self, "_sound_front", True)
        self._sound_front = front
        if back and self.typing.active:
            self.typing.refocus()               # the field typed into: its caret again (Qt took its focus away)
        if paused != self.sound_paused:
            self.sound_paused = paused
            self.link.exec("cj_sound_pause()" if paused else "cj_sound_resume()")
        elif back and self.sound_off:
            # the game in front again: it turns its sound on by itself (Maxim 01.10.: 'Sound off, tabbed out and
            # in - the sounds are back') - paused again, now and once it has settled
            self.link.exec("cj_sound_pause()")
            for ms in (600, 1600):
                QtCore.QTimer.singleShot(ms, lambda: self.sound_off and self.sound_paused
                                         and self.link.exec("cj_sound_pause()"))

    def toggle_music(self):
        self.music_off = not self.music_off
        self.link.exec(f"cj_music({'true' if self.music_off else 'false'})")
        self.hud.sync()

    # --- game messages
    GROUND_NEAR = 300.0         # m around the player: loaded, its ground can be measured
    GROUND_BELOW = 0.25         # m under the ground: lifted (less: sunk in on purpose, a log in the mud)
    GROUND_MAX = 2.5            # m at most (more: a bridge or a roof above it, not its ground - 02.10. a flag 9 m up)

    def ground_check(self, log=print, timeout=5.0):
        """Lifts what is under the ground onto it (02.10.: a guide and the player under the ground - heights guessed by
        a script): every object of the project's places in the player's world, near enough to be loaded, measured
        against the ground there (cj_ground_z); more than GROUND_BELOW under it -> its height is the ground's, the
        place is saved. Never lowers anything; decals and trails stay as they are. -> [(place, name, old z, new z)]"""
        import math
        from .quest import is_actor
        self.last_where, self.last_world = None, None
        self.link.exec("cj_where()")
        t = time.time()
        while self.last_where is None and time.time() - t < timeout:
            time.sleep(0.05)
        if self.last_where is None:
            log("[ground] Player position unknown, not checked")
            return []
        from .project import world_paths
        paths = world_paths()
        todo = []
        for name, p in self.project.places.items():
            if self.last_world and p.get("world") and paths.get(p["world"], "") != self.last_world:
                continue
            for o in p.get("objects", []):
                pos = o.get("pos")
                if not pos or o.get("trail") or "decal" in str(o.get("template", "")).lower():
                    continue
                if not is_actor(o):                 # (things are placed onto a surface; a script guessed people)
                    continue
                if math.dist(pos[:2], self.last_where[:2]) <= self.GROUND_NEAR:
                    todo.append((name, o))
        if not todo:
            return []
        got = []
        self.groundz_pending = got.extend
        self.link.exec('cj_ground_z("{}")'.format(";".join("{:.3f},{:.3f},{:.3f}".format(*o["pos"][:3])
                                                             for _n, o in todo)))
        t = time.time()
        while not got and time.time() - t < timeout:
            time.sleep(0.05)
        self.groundz_pending = None
        fixed, places = [], set()
        for (name, o), gz in zip(todo, got):
            if gz is not None and self.GROUND_BELOW < gz - o["pos"][2] <= self.GROUND_MAX:
                fixed.append((name, o.get("id") or o["template"].rsplit("\\", 1)[-1], o["pos"][2], round(gz, 3)))
                o["pos"][2] = round(gz, 3)
                places.add(name)
        for name in places:
            self.project.save_place(name)
        for name, what, old, new in fixed:
            log(f"[ground] {name}/{what} was {new - old:.2f} m under the ground, now on it (z {old} -> {new})")
        return fixed

    def old_runs(self):
        """The runs of this quest whose DLCs are in the game's dlc folder: [(folder, quest id, run)]."""
        import re
        root = os.path.join(config.load()["game"], "dlc")
        base = re.escape(self.project.base_id)
        out = []
        for d in os.listdir(root) if os.path.isdir(root) else []:
            m = re.fullmatch(rf"dlc({base}(?:r(\d+))?)", d.lower())
            if m and d.lower() != "dlc" + self.project.id:
                out.append((d, m.group(1), int(m.group(2) or 0)))
        return out

    def fresh_run(self, log, drop_old=True, bump=True):
        """A new run of the quest for this Build & Play (project.id: <id>r<n>): to the game a new quest, started from
        the beginning or the step chosen; the DLCs (and mod bundles) of the runs before leave the game - it is
        closed now, nothing holds them (`drop_old=False`: it runs - live loading; they go at its next start)."""
        import re
        meta = self.project.meta
        if bump:
            meta["run"] = int(meta.get("run") or 0) + 1
            meta["stamp"] = int(time.time())              # (the run's age to the others in the game: quest.py)
            meta.setdefault("live_from", meta["run"])  # the first run with the waituntil.retired watcher
            if int(meta.get("gone_version") or 0) < RETIRE_VERSION:   # the first run that steps aside completely
                meta["gone_from"], meta["gone_version"] = meta["run"], RETIRE_VERSION
            self.project.save_meta()
        game = config.load()["game"]
        base = re.escape(self.project.base_id)
        gone = []
        for folder, prefix in (("dlc", "dlc"), ("Mods", "moddlc")) if drop_old else ():
            root = os.path.join(game, folder)
            if not os.path.isdir(root):
                continue
            for d in os.listdir(root):
                if re.fullmatch(rf"{prefix}{base}(r\d+)?", d.lower()) and d.lower() != prefix + self.project.id:
                    try:
                        from .project import park_run   # (parked: Build & Play's last versions)
                        park_run(self.project.path, root, d, "dlc" if folder == "dlc" else "mod")
                        gone.append(d)
                    except OSError as e:
                        log(f"[play] {d} could not go: {e}")
        if bump or gone:
            log((f"[play] Run {meta['run']} of the quest (it starts fresh)" if bump else "[play] the runs before")
                + (f" - gone: {', '.join(gone)}" if gone else ""))

    def live_check(self):
        """Can Build & Play load the new run into the running game (TW3SE) instead of restarting it?
        -> None (yes) or why not."""
        from . import setup, tw3se
        if bg.BACKGROUND:
            return "the background game restarts"
        if not tw3se.ready(bg.our_pids()):
            return "no script extender in this game"
        if setup.scripts_pending():
            return "Conjunction's scripts changed - the game compiles them at its start"
        # every older run in the game has to step aside completely (its people at once, its places, its quest) -
        # one built before that would stay half in the world (07.10.: two fathers): the restart takes it out
        first = self.project.meta.get("gone_from")
        old = [d for d, _q, run in self.old_runs() if first is None or run < int(first)]
        if old:
            return f"{', '.join(old)} cannot step aside completely (built before) - the restart takes it out"
        return None

    def _pause_editing(self, log):
        self.ground_check(log)                  # nothing of the quest under the ground (a guessed height)
        if self.editing:
            self.link.exec("cj_edit(false)")
            self.editing = False
            QtCore.QMetaObject.invokeMethod(self.hud, "hide", QtCore.Qt.QueuedConnection)
        self.show_built()                       # the save must not keep the quest's people hidden

    def _quicksave(self, log):
        """Quick save and wait for it: a save file newer than the request in the game's save folder."""
        folder = os.path.join(config.game_docs(), "gamesaves")

        def newest():
            try:
                return max(((os.path.getmtime(os.path.join(folder, f)), f) for f in os.listdir(folder)
                            if f.endswith(".sav")), default=(0.0, None))
            except OSError:
                return 0.0, None
        before = newest()[0]
        self.saved_locked = False
        self.link.exec("cj_quicksave()")
        log("[play] quick save ...")
        t, saved = time.time(), None
        while time.time() - t < 15 and not self.saved_locked:
            when, name = newest()
            if when > before and time.time() - when > 0.5:      # (written, and done being written)
                saved = name
                break
            time.sleep(0.2)
        log(f"[play] saved: {saved}" if saved else "[play] No save confirmation (saves locked?), continuing with "
                                                   "the last save")

    def _close_game(self):
        """Our game closed - and gone (it holds its DLCs: a game still there would be attached to, with every run
        in it)."""
        from . import setup
        self.restarting = True
        bw = getattr(self.panel, "bw", None)
        if bw is not None:                              # the curtain lets go of the game's window first (owned
            bw.release()                                # windows go with their owner)
        # only this Conjunction's game (two may run: the background one for tests and Maxim's - bg.our_pids)
        for pid in bg.our_pids():
            subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
        t = time.time()
        while setup.game_running() and time.time() - t < 20:
            time.sleep(0.3)
        if setup.game_running() and not bg.BACKGROUND:
            raise RuntimeError("The game did not close (it would keep the runs before loaded) - close it and press "
                               "Build & Play again")

    def _start_game(self, log):
        """The game started with only this run in it (in_game.clear_for: the gate before every start)."""
        from . import in_game, setup
        if not bg.BACKGROUND:
            if setup.game_running():
                raise RuntimeError("The game is still running - close it and press Build & Play again")
            left = in_game.clear_for(self.project.path, log)
            if left:
                raise RuntimeError(f"{', '.join(left)} cannot leave the game folder (a program holds it open) - the "
                                   f"game would load it beside this run. Close that program and press Build & Play "
                                   f"again")
        setup.install_scripts()
        setup.start_game()
        self.restarting = False
        log("[play] Starting game...")
        # F8 as soon as the save is restored (07.10.: 15 s more waited for a crash before) - a crash later is
        # __main__.watch_game's: its report closed, the game started again
        result, detail = setup.wait_loaded_settled(log=log, settle=0.0)
        log({"loaded": "[play] save loaded - F8 for the editor",
             "compile_error": "[play] the game could not compile the scripts:\n" + detail}.get(
            result, f"[play] the game did not come up ({result})"))
        return result

    def start_clean(self, path):
        """File > New project in the game: the game starts again with only that project in it (Maxim 07.10.: "es
        wäre ok wenn man neu lädt und wirklich alles andere weg wäre") - quick save, the game closed (it holds its
        DLCs), Conjunction again in the new project: every other project's DLCs and older runs are parked before
        the game starts (__main__.in_game), the quick save loads."""
        def work():
            def log(s):
                print(s, flush=True)
            try:
                self._pause_editing(log)
                self._quicksave(log)
            except Exception as ex:                     # noqa: BLE001 - the restart goes on (the last save loads)
                log(f"[editor] no quick save: {ex}")
            try:
                self._close_game()
            except RuntimeError as ex:                  # the next Conjunction closes it (_restart_clean)
                log(f"[editor] {ex}")
            root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            after = ["--after", str(os.getpid())]
            if getattr(sys, "frozen", False):           # the release: its own exe
                cmd = [sys.executable, path] + after
            else:
                exe = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
                cmd = [exe if os.path.exists(exe) else sys.executable, "-m", "conjunction", path] + after
            subprocess.Popen(cmd, cwd=root, creationflags=0x08000000)      # CREATE_NO_WINDOW
            log(f"[editor] starting again in {path}, the other projects out of the game")
            QtCore.QMetaObject.invokeMethod(QtWidgets.QApplication.instance(), "quit", QtCore.Qt.QueuedConnection)
        self.panel.notice.say("New project: the game starts again with only it in the world", ms=15000)
        threading.Thread(target=work, daemon=True).start()

    def build_and_play(self, log, play=True, test_from=None):
        """Build the project into a DLC; with `play`: into the running game with the script extender (TW3SE: built,
        mounted, the save loaded again - no restart), else quick save, close the game (it locks its DLC files),
        install, start it again - the quick start mod or you load the quick save, you are back where you were.
        Runs in a worker thread; `log` gets the lines."""
        from . import build as builder
        from . import setup
        if not play:
            builder.check(self.project.path, log=log)       # seconds: does radish accept it?
            return
        running = setup.game_running()
        # always a clean start (Maxim 07.10.: "bombenfest - dass er überhaupt da ist, muss unmöglich sein"): loading a
        # new run into the running game left the run before loaded beside it - the game holds its files, and what
        # stepped aside came back with the next load. Now the game closes, every older run and other project leaves
        # the game folder (fresh_run, park_others), the build goes in, the game starts with the quick save: only this
        # run exists for the game. (live_play stays for a later TW3SE that can take a DLC out of a running game.)
        if running and LIVE_BUILD:
            why = self.live_check()
            if why is None:
                return self.live_play(log, test_from)
            log(f"[play] a restart: {why}")
        elif running:
            log("[play] a clean start: the game closes, only this build goes back in")
        if running:
            self._pause_editing(log)
            stood = None
            if bg.BACKGROUND:                   # where the player stands: put back there after the clean save loads
                self.last_where = None
                self.link.exec("cj_where()")
                t = time.time()
                while self.last_where is None and time.time() - t < 3:
                    time.sleep(0.05)
                stood = self.last_where
            self._quicksave(log)
            self._close_game()
        self.fresh_run(log)
        from_base = False
        if bg.BACKGROUND:
            installed = os.path.isdir(os.path.join(config.load()["game"], "dlc", f"dlc{self.project.id}"))
            from_base = bg.back_to_base(self.project.id, installed, log)
        try:
            builder.build(self.project.path, install=True, log=log, test_from=test_from)
        finally:
            result = self._start_game(log)
            if result == "loaded" and from_base and running and stood:
                self.link.exec("cj_teleport({:.3f}, {:.3f}, {:.3f}, 0)".format(*stood))
                log("[play] Back where the player stood")

    def live_play(self, log, test_from=None):
        """Build & Play without a restart (TW3SE): the new run is built and installed while the game runs, the runs
        before step aside (<id>_retired: they hide their places and end - their DLCs stay until the next start),
        quick save, `livedlc` mounts and registers the new DLC, the save is loaded again - the new run starts.
        Anything the extender cannot do (a mod bundle, no answer): the restart as before."""
        from . import build as builder
        from . import setup, tw3se
        from .gamelink import run
        log("[play] Live: the game keeps running (TW3SE)")
        self._pause_editing(log)
        self.fresh_run(log, drop_old=False)
        old = [q for _d, q, _r in self.old_runs()]      # (after the new run's number: the one running is old now)
        try:
            packed = builder.build(self.project.path, install=True, log=log, test_from=test_from)
        except Exception:
            log("[play] Live: the build failed, the game goes on as it was")
            raise
        mod = os.path.join(os.path.dirname(packed), "packed_mod", "content")
        restart = "the quest changes game files (a mod bundle: only at a start)" \
            if os.path.isdir(mod) and os.listdir(mod) else None
        for q in old:                           # (their watchers hide their places before the save)
            self.link.exec(f'addfact("{q}_retired", 1)')
        if old:
            log(f"[play] live: the runs before step aside ({', '.join(old)})")
            time.sleep(1.0)
        self._quicksave(log)
        if not restart:
            target = os.path.join(config.load()["game"], "dlc", f"dlc{self.project.id}")
            ok, answer = tw3se.live_dlc(target, bg.our_pids())
            log(f"[play] live: {answer}")
            if not ok:
                restart = "the extender could not load it"
        if restart:
            log(f"[play] a restart after all: {restart}")
            self._close_game()
            self.fresh_run(log, bump=False)     # (built and installed already: the old DLCs go now)
            self._start_game(log)
            return
        time.sleep(3.0)                         # the extender registers the DLC ~2 s after mounting it
        self.link.exec("cj_reload()")
        log("[play] Live: reloading the save...")
        t = time.time()
        while time.time() - t < 20:             # until the load has begun (the old world answers no more)
            time.sleep(1.0)
            try:
                if not any("world=" in ln for ln in run(["cj_where()"], 0.5)):
                    break
            except OSError:
                break
        result, _detail = setup.wait_loaded(timeout=600)
        if result == "loaded" and old:
            # once more in the loaded game: a save made before (saves locked - in a fight: 03.10.) knows no
            # <id>_retired, its runs would go on beside the new one
            for q in old:
                self.link.exec(f'addfact("{q}_retired", 1)')
        log("[play] Save loaded - F8 to enter the editor" if result == "loaded"
            else f"[play] The save did not load ({result})")

    # --- undo: every change the game reports, with what it takes to take it back
    def undo_entry(self, what, kv, pos):
        tpl = kv.get("template", "")
        rot = [float(v) for v in kv.get("rot", "0,0,0").split(",")]
        if what == "placed":
            return ("placed", tpl, pos, rot)
        if what == "deleted":
            return ("deleted", tpl, pos, rot)
        if what in ("moved", "rotated"):
            key = [float(v) for v in kv["from"].split(",")] if what == "moved" else pos
            i = self.project.find_object(self.place, key)
            if i is not None:
                o = self.project.places[self.place]["objects"][i]
                return ("moved", tpl, list(o["pos"]), list(o["rot"]), pos)
        return None

    def undo_last(self):
        if not self.undo:
            print("[editor] nothing to undo", flush=True)
            return
        e = self.undo.pop()
        if e[0] == "terrain":               # a drag of the terrain brush
            if self.terrain_tool is not None:
                self.terrain_tool.undo()
            print("[editor] undo terrain", flush=True)
            return
        if e[0] == "quest":                 # a change of the quest (the board, a talk): back as it was
            self.panel.board.restore(e[1])
            print("[editor] undo quest", flush=True)
            return
        self.undoing += 1                   # the game reports the undo as a change - not a new undo step
        if e[0] == "placed":
            self.link.exec("cj_delete_at({:.3f}, {:.3f}, {:.3f})".format(*e[2]))
        elif e[0] == "deleted":
            self.link.exec('cj_place_at("{}", {:.3f}, {:.3f}, {:.3f}, {:.2f}, {:.2f}, {:.2f})'.format(
                e[1], *e[2], *e[3]))
        else:
            self.link.exec("cj_set_at({:.3f}, {:.3f}, {:.3f}, {:.3f}, {:.3f}, {:.3f}, {:.2f}, {:.2f}, {:.2f})".format(
                *e[4], *e[2], *e[3]))
        print(f"[editor] undo {e[0]}", flush=True)

    def set_selected_transform(self, pos, rot):
        """Exact numbers from the properties panel."""
        if self.selected:
            self.link.exec("cj_set_at({:.3f}, {:.3f}, {:.3f}, {:.3f}, {:.3f}, {:.3f}, {:.2f}, {:.2f}, {:.2f})".format(
                *self.selected, *pos, *rot))

    def select_at(self, pos):
        if self.mode == "select":
            self.link.exec("cj_select_at({:.3f}, {:.3f}, {:.3f})".format(*pos))

    def handle(self, line):
        if line.startswith("where ") and " player=" in line:
            try:
                self.last_where = [float(v) for v in line.split(" player=", 1)[1].split()[:3]]
                self.last_world = line.split("world=", 1)[1].split(" player=", 1)[0].strip().lower() \
                    if "world=" in line else None        # (its depot path)
                self.last_heading = float(line.split(" heading=", 1)[1].split()[0]) if " heading=" in line else None
            except ValueError:
                pass
        if line == "save|locked":
            self.saved_locked = True
            return
        if line == "esc|edit":                  # Esc while playing, nothing of the game's had it: back to editing
            if not self.editing:
                self.set_editing(True)
            return
        if line.startswith("edit on world="):
            path = line.split("world=", 1)[1].split(" template=", 1)[0].strip()
            self.world = worlds().get(path.lower())
            # the game (restarted by a Build & Play) may have forgotten the place: told again on every start of
            # editing - its changes are filed under it
            self.link.exec(f'cj_set_place("{self.place}")')
            self.load_place()
        elif line.startswith("spawn|missing|"):
            print(f"[editor] not in the game: {line.split('|', 2)[2]}", flush=True)
        elif line.startswith("cam|"):
            self.cam.from_game(line.split("|")[1:10])
        elif line.startswith("moving|") and self.drag and self.drag.get("sent"):
            # where the dragged object really is (snapped down a slope, stopped at a wall): the outline and the
            # arrows are drawn that far from where the cursor asks for, until the next word from the game
            try:
                got = [float(v) for v in line.split("|", 1)[1].split(",")[:3]]
                self.drag["off"] = [g - s for g, s in zip(got, self.drag["sent"])]
            except ValueError:
                pass
        elif line.startswith("change|"):
            if "|place=|" in line and self.place:      # (a game that forgot the place: the one being edited)
                line = line.replace("|place=|", f"|place={self.place}|", 1)
            parts = line.split("|")
            kv = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
            pos = [float(v) for v in kv.get("pos", "0,0,0").split(",")]
            if parts[1] in ("selected", "moved", "rotated"):
                self.selected = pos
            if parts[1] == "selected":                 # an object the game placed (edit existing): its world card
                self.world_sel = kv if self._selected_index() is None and kv.get("guid") else None
            if parts[1] in ("deleted", "removed"):
                self.selected = None
                self.world_sel = None
            ws = getattr(self, "world_sel", None)
            if parts[1] in ("moved", "rotated") and kv.get("game") == "1" and ws and ws.get("guid") == kv.get("guid"):
                line += f"|home={ws.get('pos', '')}|homerot={ws.get('rot', '')}"   # as it stood when selected
            before = self.undo_entry(parts[1], kv, pos)
            msg = self.project.apply_change(line)
            if msg:
                print(f"[editor] {msg}", flush=True)
                if before:
                    if self.undoing:
                        self.undoing -= 1
                    else:
                        self.undo.append(before)
                        del self.undo[:-UNDO_MAX]
                if self.panel.isVisible():
                    self.panel.sync_places()
            if self.panel.isVisible():
                self.panel.sync_selected()
            look = getattr(self, "place_look", None)
            if parts[1] == "placed" and msg and look:        # one look chosen in the catalog: it, not the game's pick
                name = kv.get("place") or self.place
                objs = self.project.places.get(name, {}).get("objects", [])
                if objs:
                    self.project.set_object(name, len(objs) - 1, appearance=look)
                    x, y, z = pos
                    self.link.exec(f'cj_appearance({x}, {y}, {z}, "{look}")')
            if parts[1] == "placed" and getattr(self, "variants", None) and self.placing:
                import random
                vs = self.variants
                self.set_template(random.choice(vs), preview=True, variants=vs)   # the next one: another variant
            if parts[1] == "placed" and not self.request and self.back_to_catalog():
                return
            if self.request and parts[1] in ("selected", "placed"):
                i = (self._selected_index() if parts[1] == "selected" else
                     len(self.project.places.get(self.place, {}).get("objects", [])) - 1)
                if i is not None and i >= 0 and (parts[1] == "selected") == (self.request["how"] == "pick"):
                    self._request_answer(i)
                    return
            if parts[1] == "selected":
                self.show_selected()        # the inspector shows what was clicked
            elif parts[1] in ("deleted", "removed"):
                self.show_selected()
            elif parts[1] in ("effect", "effect_off", "look") and self.panel.world_card.isVisible():
                self.panel.world_card.refresh(self.project.path)
        elif line.startswith("worldinfo|"):
            kv = dict(p.split("=", 1) for p in line.split("|")[1:] if "=" in p)
            self.panel.world_card.set_info([n for n in kv.get("fx", "").split(",") if n],
                                           [n for n in kv.get("looks", "").split(",") if n])
        elif line.startswith("worldfx|missing|"):
            self.panel.world_card.say(f"It has no effect '{line.split('|', 2)[2]}'")
        elif line == "worldlook|nocomponent":
            self.panel.world_card.say("It has no other appearances")
        elif line.startswith("drop|none"):
            self.panel.notice.say("Nothing below it to drop onto", ms=4000)
        elif line.startswith("select|none"):
            click, self.click_px = getattr(self, "click_px", None), None
            near = self.screen_pick(*click) if click else None
            if near:                                # the ray missed it (no collision, in the ground): the nearest
                self.link.exec(f"cj_select_at({near[0]:.3f}, {near[1]:.3f}, {near[2]:.3f})")
                return
            self.selected = None
            if self.panel.isVisible():
                self.panel.sync_selected()
            self.show_selected()
        elif line.startswith("group|"):
            self.group = [[float(v) for v in g.split(",")] for g in line[6:].split(";") if g.count(",") == 2]
        elif line.startswith("cursor|") and getattr(self, "path_pending", False):
            self.path_pending = False
            if self.path_tool is not None:
                self.path_tool.ground(None if line == "cursor|none" else [float(v) for v in line[7:].split(",")])
        elif line.startswith("cursor|") and getattr(self, "point_pending", False):
            self.point_pending = False
            r = self.request
            if r and r["how"] == "point" and line != "cursor|none":
                self.request = None
                r["done"](self.place, [round(float(v), 3) for v in line[7:].split(",")])
                if not (self.panel.isVisible() and self.panel.tabs.isVisible()):
                    self.toggle_panel()
                self.panel.tabs.setCurrentWidget(self.panel.board)
                self.panel.sync_quest()
                self.hud.sync()
        elif line.startswith("groundz|") and getattr(self, "groundz_pending", None):
            done, self.groundz_pending = self.groundz_pending, None
            done([None if v in ("n", "") else float(v) for v in line[8:].split(";")])
        elif line.startswith("grounds|") and getattr(self, "grounds_pending", None):
            done, self.grounds_pending = self.grounds_pending, None
            done([float(v) for v in line[8:].split(";") if v])
        elif line.startswith("cursor|") and self.paste_pending:
            self.paste_pending = False
            if line != "cursor|none":
                self.paste_at([float(v) for v in line[7:].split(",")])
        elif line.startswith("objective|") and "|status=" in line:
            caption, status = line[len("objective|"):].rsplit("|status=", 1)
            self.live_seen[caption.strip()] = int(status.strip() or 0)
            QtCore.QTimer.singleShot(400, self._live_done)      # all lines of this answer are in by then
        elif line.startswith("invlist|"):
            parts = line.split("|")
            items = None if parts[2:] == ["none"] else [
                (p.rsplit(":", 1)[0], int(p.rsplit(":", 1)[1])) for p in parts[2:] if ":" in p]
            if self.panel.inspector:
                self.panel.inspector.live_inventory(items)

    def screenshot(self):
        """F11: the game as it is on the screen, Conjunction over it -> Documents\\Conjunction\\screenshots\\conjunction_<date>_<time>.png."""
        try:
            from PIL import ImageGrab
            x, y, w, h = client_rect_on_screen(self.hwnd)
            folder = self.screenshot_folder()                  # made with the project's first screenshot
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, os.path.basename(folder) + time.strftime("_%Y-%m-%d_%H-%M-%S.png"))
            ImageGrab.grab((x, y, x + w, y + h), all_screens=True).save(path)
            print(f"[editor] screenshot {path}", flush=True)
            shutter = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sounds", "shutter.wav")
            if os.path.isfile(shutter):                 # a soft click, as a camera does (the picture is taken first)
                import winsound
                winsound.PlaySound(shutter, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
            self.panel.notice.say(f"Screenshot: {path}", ms=4000)
        except Exception as e:                          # noqa: BLE001 - say it, never stop the editor
            self.panel.notice.say(f"No screenshot: {e}", error=True)

    def screenshot_folder(self):
        """Documents\\Conjunction\\screenshots\\<project>: one folder per project (Maxim 06.10.)."""
        from . import paths
        from .project import slug_of
        name = slug_of(self.project.meta.get("name") or os.path.basename(self.project.path)) or "project"
        return os.path.join(paths.SCREENSHOTS, name)

    def open_screenshots(self):
        """The project's screenshots in Explorer (the screenshots folder while it has none yet)."""
        from . import paths
        folder = self.screenshot_folder()
        if not os.path.isdir(folder):
            folder = paths.SCREENSHOTS
            os.makedirs(folder, exist_ok=True)
        os.startfile(folder)

    def poll_live(self):
        """Every 3 s while the quest tab is shown: the quest's objectives from the game (cj_quests)."""
        if time.time() < self.live_next or not self.panel.isVisible() or self.panel.tabs.isHidden():
            return
        if self.panel.tabs.currentWidget() is not getattr(self.panel, "board", None):
            return
        self.live_next = time.time() + 3.0
        title = str((self.project.meta.get("quest") or {}).get("title") or "").replace('"', "")
        if title:
            self.live_seen = {}
            self.link.exec(f'cj_quests("{title}")')

    def _live_done(self):
        if self.live_seen and self.live_seen != self.live:
            self.live = dict(self.live_seen)
            self.panel.board.show_live(self.live)

    def show_selected(self):
        """The inspector next to the game for the object selected in the world (the panel's tabs stay as they are:
        closed -> only the inspector shows); nothing selected -> an inspector-only panel goes."""
        i = self._selected_index() if self.selected else None
        if i is None and self.selected and getattr(self, "world_sel", None):
            if not self.panel.isVisible():
                self.panel.tabs.hide()
                self.panel.show()
            self.panel.show_world_card(self.world_sel)
            self.place_panel()
            return
        self.panel.show_world_card(None)
        if i is None:
            if self.panel.isVisible() and not self.panel.tabs.isVisible():
                self.panel.hide()
            elif self.panel.inspector and self.panel.inspector.obj:
                self.panel.show_inspector(False)
            return
        self.panel.load_catalog()
        if not self.panel.inspector:
            return                          # the database is still being built
        if not self.panel.isVisible():
            self.panel.tabs.hide()
            self.panel.show()
        self.panel.inspector.show()
        self.panel.inspector.show_object(self.place, i)
        self.panel.show_inspector(True)
        self.place_panel()
        self.z_top = None

    # --- objects the game placed (edit existing): world changes, kept by the script extender (worldchanges.py)
    def world_remove(self):
        self.link.exec("cj_delete_selected()")         # the game removes it and reports it: kept by apply_change

    def world_effect(self, name, on):
        self.link.exec(f"cj_world_effect('{name}', {'true' if on else 'false'})")

    def world_look(self, name):
        self.link.exec(f'cj_world_look("{name}")')

    def world_drop(self, cid):
        from . import worldchanges
        change = next((c for c in worldchanges.load(self.project.path) if c["id"] == cid), None)
        worldchanges.drop(self.project.path, cid)
        if change and change["do"] == "effect" and self.selected:
            self.link.exec(f"cj_world_effect('{change['value']}', false)")
        if change and change["do"] == "remove":         # hidden while editing: there again at once
            self.link.exec(f'cj_world_show("{change["guid"]}")')
        if change and change["do"] == "move" and len(str(change.get("otherwise", "")).split()) == 6:
            self.link.exec('cj_world_put("{}", {})'.format(change["guid"], ", ".join(change["otherwise"].split())))
        print(f"[editor] world change {cid} forgotten", flush=True)
        self.panel.world_card.refresh(self.project.path)

    # --- the frame
    def tick(self):
        while not self.q.empty():
            self.handle(self.q.get())
        if self.restarting:
            return
        if not user32.IsWindow(self.hwnd):
            # the game was restarted: its new window (checked once a second)
            if time.time() < self.next_find:
                return
            self.next_find = time.time() + 1.0
            self.hwnd = game_window()
            if not self.hwnd:
                return
            self.editing = False
            self.hud.hide()
        if not self.cleared_old and not self.editing:
            self.cleared_old = True
            self.link.exec("cj_clear()")
            # the editor on by itself once Conjunction has found the game (Maxim 06.10.: after the start, attached
            # to a running game too, F8 had to be pressed); once a session - after Build & Play it stays playing
            QtCore.QTimer.singleShot(500, lambda: None if self.editing else self.set_editing(True))
        self.give_focus_back()
        front = self.game_in_front()
        # back in the game after Alt+Tab: the game hides its cursor again - the editor shows it again (Maxim 06.10.:
        # "keine maus sichtbar wenn ich im spiel getabbt bin", F8 off and on was needed)
        if front and not getattr(self, "_was_front", True) and self.editing:
            self.link.exec("cj_edit(true)")     # (already on: only the cursor - conjunction_editor.ws)
            QtCore.QTimer.singleShot(600, lambda: self.editing and self.link.exec("cj_edit(true)"))   # (the game
            # may hide it a few frames after it has the focus again)
        self._was_front = front
        # ... and whenever Windows says the cursor is hidden over the game while editing (07.10.: after a live Build &
        # Play the cursor was there over the editor's menus, gone over the game until Alt+Tab): measured, not guessed
        if front and self.editing and time.time() >= getattr(self, "_cursor_next", 0.0) and _cursor_hidden():
            self._cursor_next = time.time() + 1.5
            self.link.exec("cj_edit(true)")     # (already on: only the cursor - conjunction_editor.ws)
        # while editing, the built quest's people of this place stay out of the way of their copies - again and again:
        # the game spawns them anew after a load or when they stream in (07.10.: two alchemists in one another)
        if self.editing and time.time() >= getattr(self, "_hide_next", 0.0):
            self._hide_next = time.time() + 2.0
            self._hide_built_people()
        # the sound follows the focus: another program in front - paused; the game or one of Conjunction's windows
        # (a dropdown, the file dialog) - playing (unless the setting is off)
        self.keep_sound(front or self._foreground_is_ours())
        self.panel.notice.follow(front or self._foreground_is_ours())
        self.see_through()
        self.poll_live()
        mouse_only = self.typing.active         # typing into the panel: the keys are the field's, not the editor's
        # the keys count with the game in front - or the panel or one of its windows (the catalog) when no text field
        # has the focus there (06.10.: the panel's key opened it but could not close it: the catalog had the focus)
        front = front or self._panel_front()
        # Esc always counts: it leaves the text field and stops what is going on
        now = {k: pressed(k) and front and (not mouse_only or k in (VK["LBUTTON"], VK["RBUTTON"], VK["ESC"]))
               for k in self.keys}
        edge = {k: now[k] and not self.prev[k] for k in self.keys}
        up = {k: self.prev[k] and not now[k] for k in self.keys}
        self.prev = now
        x, y, w, h = client_rect_on_screen(self.hwnd)
        if self.hud.geometry() != QtCore.QRect(x, y, w, h):
            self.hud.setGeometry(x, y, w, h)
            self.panel.place_at(x, y, w, h)
            self.hud.sync()
        if edge[VK["F11"]]:
            self.screenshot()
        # Esc is Conjunction's while it runs (playing: back to editing) - the game's pause menu kept shut, only while
        # the game is in front: out of focus the game opens its pause menu, the fact closes it at once, the game opens
        # it again - while playing its HUD flickered behind the other program (07.10., commonIngameMenu.ws OnConfigUI).
        # Out of focus while playing: the game's own pause as without Conjunction (editing: the fly cam keeps it off)
        game_front = front or self._foreground_is_ours()
        if not game_front and getattr(self, "_menu_kept", True) and not self.editing:
            self._menu_kept = False
            self.link.exec('removefact("nge_pause_menu_disabled")')
        if game_front and (time.time() >= self.next_pause_off or not getattr(self, "_menu_kept", True)):
            self._menu_kept = True
            self.next_pause_off = time.time() + 3.0
            self.link.exec("cj_pause_menu_off()")
        building = getattr(self.panel, "building", False)     # (the curtain is up: F8 / Esc wait for the build)
        if edge[VK["F8"]] and not building:
            self.set_editing(not self.editing)
        elif edge[VK["ESC"]] and not self.editing and front and not building:
            self.link.exec("cj_play_esc()")     # the game answers esc|edit unless a scene or a menu has Esc
        if self.editing:
            # ours in front: the game, or a window of this process (a menu, a file dialog) - asked Windows, not Qt:
            # Qt kept calling a tool window active while another program was in front, and the overlay stayed topmost
            self.stack(front or self._foreground_is_ours())
        if not (self.editing and front):
            self.wheel.take()
            return
        c = wt.POINT(*bg.cursor_pos())
        # see-through while placing: the bar, the panel and its windows let the clicks through - the world is under
        # the mouse there too (Maxim, 01.10.: the clicks behind the see-through panel placed nothing)
        seeing = self.seeing_through
        on_bar = self.hud.over_bar(c.x, c.y) and not seeing
        self.hud.click_through(not on_bar and self.hud.name_edit.isHidden())
        if self.hud.menu_open and (edge[VK["LBUTTON"]] or edge[VK["RBUTTON"]]) and not on_bar:
            self.hud.close_menu()               # a click beside an open menu closes it (and does nothing else)
            return
        # the panel never takes the focus (the game would pause): clicks and the wheel over it are its own
        on_panel = not seeing and ((self.panel.isVisible() and self.panel.frameGeometry().contains(c.x, c.y)) or any(
            w.frameGeometry().contains(c.x, c.y) for w in self.panel.open_windows()))   # the catalog's windows too
        on_bar = on_bar or on_panel
        if on_panel:
            self.wheel.take()
        elif edge[VK["LBUTTON"]] and self.typing.active:
            self.typing.stop()                  # a click into the game: the keys are the game's again
        if edge[VK["C"]] and now[VK["CTRL"]] and self.selected:
            self.copy_selection()
            return
        if edge[VK["V"]] and now[VK["CTRL"]] and self.clipboard:
            c = wt.POINT(*bg.cursor_pos())
            self.paste_pending = True           # the game answers with the point under the cursor
            self.link.exec(f"cj_cursor_hit({(c.x - x) / w:.4f}, {(c.y - y) / h:.4f}, {w / h:.4f})")
            return
        if edge[VK["D"]] and now[VK["CTRL"]] and not self.placing and self.selected:
            self.link.exec("cj_duplicate()")
            return
        if edge[VK["Z"]] and now[VK["CTRL"]]:
            self.undo_last()
            return
        if self.hud.capturing:
            for name, vk in KEY_VK.items():
                if edge.get(vk) and name not in RESERVED:
                    self.hud.set_key(name)
                    return
            if edge[VK["ESC"]]:
                self.hud.set_key(None)
            return
        tool = self.path_tool
        if tool is not None:                    # drawing a path: Esc, Enter, Backspace are its own
            if edge[VK["ESC"]]:
                tool.cancel()
                return
            if edge[VK["RETURN"]]:
                tool.finish()
                return
            if edge[VK["BACK"]]:
                tool.back()
                return
        if edge[VK["ESC"]]:
            self.escape()
            return
        board = getattr(self.panel, "board", None)
        if edge[VK["RETURN"]] and getattr(board, "drawing", None):
            board.finish_trail()                    # a trail drawn: Enter lays it
            return
        if not now[VK["CTRL"]]:
            self.lamp_keys(now, up)
            self.speed_keys(now)
            for a, name in self.hud.keys.items():
                if name and a not in ("opt.lamp", "opt.speed") and edge.get(KEY_VK.get(name)):
                    self.hud.trigger(a)
                    return
        moved_cam = self.fly(now, edge, c, on_bar)
        sx, sy = (c.x - x) / w, (c.y - y) / h
        inside = 0 <= sx <= 1 and 0 <= sy <= 1 and not on_bar
        a = f"{sx:.4f}, {sy:.4f}, {w / h:.4f}"
        if self.path_tool is not None and inside:
            if edge[VK["LBUTTON"]]:
                self.path_tool.click(c.x - x, c.y - y, lambda a=a: self._ask_path_ground(a))
                return
            if up[VK["RBUTTON"]] and self.look_from and not self.looked and \
                    time.perf_counter() - self.look_t < CLICK_S:
                self.path_tool.right_click(c.x - x, c.y - y)
        if inside and self.request and self.request["how"] == "point" and edge[VK["LBUTTON"]]:
            self.point_pending = True           # the game answers with the ground point under the cursor
            self.link.exec(f"cj_cursor_hit({a})")
            return
        tt = self.terrain_tool
        if self.mode == "terrain" and tt is not None:
            if inside:
                tt.handle(edge, up, now, VK, c.x - x, c.y - y, w, h, moved_cam)
            elif tt.drag and up[VK["LBUTTON"]]:
                tt._finish(tt.cursor)            # let go over the bar: the drag ends all the same
        elif inside and self.mode != "look":
            if self.placing and self.template:
                if a != self.last_pick or moved_cam:
                    self.link.exec(f"cj_pick({a})")
                    self.last_pick = a
                if edge[VK["LBUTTON"]]:
                    self.link.exec("cj_place()")
            elif not self.placing:
                self.select_mode(edge, up, now, c.x - x, c.y - y, w, h, a)
            if up[VK["RBUTTON"]] and self.look_from and not self.looked and time.perf_counter() - self.look_t < CLICK_S:
                self.link.exec(f"cj_delete({a})")
        if up[VK["RBUTTON"]]:
            self.look_from = None
        if edge[VK["END"]] and self.mode == "select" and self.selected:
            self.link.exec("cj_drop_selected()")    # down onto what is below it
        if edge[VK["DELETE"]] and self._over_panel():
            self.panel.delete_picked()              # the quest's node / wire, the dialogue's line / answer
        elif edge[VK["DELETE"]] and self.mode == "select" and self.selected:
            self.link.exec("cj_delete_selected()")
        n = self.wheel.take()
        if n and self.mode == "terrain" and tt is not None:
            tt.strengthen(n) if now[VK["SHIFT"]] else tt.resize(n)    # the brush: its size, Shift its strength
        elif n:
            axis = 1 if now.get(self.rotate_keys.get("pitch")) else 2 if now.get(self.rotate_keys.get("roll")) else 0
            step = 1.0 if now[VK["SHIFT"]] else self.opts["turn"]   # Shift: fine, 1 deg per notch
            self.link.exec(f"cj_rotate({n * step:.1f}, {axis})")
        hover = self.drag["axis"] if self.drag else (
            self.gizmo_axis_at(c.x - x, c.y - y, w, h) if inside and self.mode == "select" else None)
        self.hover_object(inside and self.mode == "select" and not self.drag and hover is None and not on_bar,
                          c.x - x, c.y - y, w, h, moved_cam)
        free = bool(self.drag and self.drag["axis"] == "free")      # dragged freely: the object shows where it is
        self.hud.gizmo = {"pos": self.selected, "hover": hover} if (
            self.selected and self.mode == "select" and not free) else None
        self.hud.update()

    def shown_steps(self):
        """{node id: node} whose things in the world (ways, circles) the overlay draws: every step with its eye open,
        and the one being worked on (its card open) also with it shut (Maxim 02.10.: a big quest spread far apart
        stays readable)."""
        q = self.project.meta.get("quest") or {}
        board = getattr(getattr(self, "panel", None), "board", None)
        working = getattr(board, "graph_node", None)
        return {nid: n for nid, n in (q.get("nodes") or {}).items() if not n.get("hidden") or nid == working}

    def spot_rings(self):
        """The Go to spots of the place being edited, for the overlay's rings - a spot being dragged: where it is now."""
        from .quest import spot_rings
        q = self.project.meta.get("quest") or {}
        if q.get("nodes"):
            q = {"nodes": self.shown_steps()}
        rings = spot_rings(q, self.project, self.place)
        start = self.drag.get("start") if isinstance(self.drag, dict) else None
        if start and self.selected:
            rings = [(list(self.selected) if sum((a - b) ** 2 for a, b in zip(pos, start)) < 0.05 ** 2 else pos, r, ar)
                     for pos, r, ar in rings]
        return rings

    def slide_guess(self, mx, my, w, h):
        """Where an object dragged freely is now, as far as Conjunction can tell: the cursor's ray at the height it had
        when the drag began (on a slope a little off - the game's own position comes when it is let go)."""
        start = self.drag.get("start") if isinstance(self.drag, dict) else None
        if not start or not self.cam.ready:
            return None
        origin, d = self.cursor_ray(mx, my, w, h)
        if d[2] > -1e-4:                              # looking up / level: the ray never comes down to it
            return None
        t = (start[2] - origin[2]) / d[2]
        if t <= 0 or t > 400:
            return None
        x, y = origin[0] + d[0] * t, origin[1] + d[1] * t
        g = self.opts.get("grid") or 0
        if g:
            x, y = round(x / g) * g, round(y / g) * g
        return [x, y, start[2]]

    def see_through(self):
        """Placing or picking in the world: the panel, its windows and the bar let the world show through and the
        clicks through to it (Maxim, 30.09.: 'so one can really place in the world'; 01.10.: 'as if it were not
        there' - also where the mouse is over one of them)."""
        # busy: the board waits for a click in the world, or something chosen follows the cursor (not the catalog
        # merely open) - and only while the mouse is over the game in front (not over another program)
        from .panel import setting
        busy = (bool(self.request) or (self.mode == "place" and bool(self.template))) and setting("see_through")
        if bg.BACKGROUND:                   # invisible windows: no see-through (it would show them again)
            self.seeing_through = False
            return
        wins = [w for w in [self.panel] + self.panel.open_windows() if w.isVisible()]
        pos = QtGui.QCursor.pos()
        if busy:
            x, y, w, h = client_rect_on_screen(self.hwnd)
            front = user32.GetForegroundWindow() == self.hwnd or self._foreground_is_ours()
            busy = front and x <= pos.x() < x + w and y <= pos.y() < y + h
        self.seeing_through = busy
        bar = getattr(self.hud, "bar", None)
        see = SEE_THROUGH if busy else 1.0
        for w in wins:
            if abs(w.windowOpacity() - see) > 0.01:
                w.setWindowOpacity(see)
            click_through(w, busy)
        if bar is not None:
            effect = bar.graphicsEffect()
            if see < 1.0 and effect is None:
                effect = QtWidgets.QGraphicsOpacityEffect(bar)
                effect.setOpacity(see)
                bar.setGraphicsEffect(effect)
            elif see == 1.0 and effect is not None:
                bar.setGraphicsEffect(None)

    def _over_panel(self):
        """Is the mouse over the panel or one of its windows (not over the world)?"""
        if self.seeing_through:
            return False
        pos = QtCore.QPoint(*bg.cursor_pos())
        return any(w.isVisible() and w.frameGeometry().contains(pos) for w in [self.panel] + self.panel.open_windows())

    def game_in_front(self):
        """The game counts as the window in front: really, or always in the background (bg.py)."""
        return bg.BACKGROUND or user32.GetForegroundWindow() == self.hwnd

    def _panel_front(self):
        """The panel or one of its windows in front, and no text field of ours with the focus."""
        fg = user32.GetForegroundWindow()
        if not fg or not self.panel.isVisible():
            return False
        wins = [self.panel] + list(self.panel.open_windows())
        if not any(int(w.winId()) == fg for w in wins if w.isVisible()):
            return False
        fw = QtWidgets.QApplication.focusWidget()
        return not isinstance(fw, (QtWidgets.QLineEdit, QtWidgets.QTextEdit, QtWidgets.QPlainTextEdit,
                                   QtWidgets.QAbstractSpinBox, QtWidgets.QComboBox))

    def _foreground_is_ours(self):
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(user32.GetForegroundWindow(), ctypes.byref(pid))
        return pid.value == os.getpid()

    def stack(self, ours):
        """The overlay (bar, gizmo, panel) behaves like part of the game window: on top while the game or the panel
        is in front, otherwise right above the game window - a program moved in front of the game covers it too.
        Hidden while the game is minimized. In the background: left where they are (invisible, never topmost - over
        Maxim's own game a topmost window costs him frames)."""
        if bg.BACKGROUND:
            return
        if user32.IsIconic(self.hwnd):
            if self.hud.isVisible():
                self.panel_away = self.panel.isVisible()
                self.windows_away = self.panel.open_windows()
                self.hud.hide()
                self.panel.hide()
                for w in self.windows_away:
                    w.hide()
            return
        if not self.hud.isVisible():
            self.hud.show()
            if self.panel_away:
                self.panel.show()
            for w in getattr(self, "windows_away", []):
                w.show()
            self.panel_away, self.windows_away, self.z_top = False, [], None
        wins = [int(self.hud.winId())] + ([int(self.panel.winId())] if self.panel.isVisible() else []) + \
            [int(w.winId()) for w in self.panel.open_windows()] + \
            ([int(self.hud.menu.winId())] if self.hud.menu.isVisible() else [])   # the catalog's windows, the menu
        flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        if ours:
            if self.z_top is not True:
                for h in wins:                              # hud first, the panel ends above it
                    _SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, flags)
                self.z_top = True
            return
        # directly above the game: below whatever window lies right over it (not one of ours)
        above = _GetWindow(self.hwnd, GW_HWNDPREV)
        while above and above in wins:
            above = _GetWindow(above, GW_HWNDPREV)
        chain_ok, below = True, self.hwnd
        for h in wins:                                      # each right above the one before
            chain_ok = chain_ok and _GetWindow(below, GW_HWNDPREV) == h
            below = h
        if self.z_top is False and chain_ok:
            return
        if self.z_top is not False:
            for h in wins:
                _SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, flags)
        top_band = not above or user32.GetWindowLongW(above, GWL_EXSTYLE) & WS_EX_TOPMOST
        for h in wins:                                      # each goes right below `above`: the panel ends on top
            _SetWindowPos(h, HWND_TOP if top_band else above, 0, 0, 0, 0, flags)
        self.z_top = False

    def fly(self, now, edge, c, on_bar):
        """Camera input to the game, which integrates it every frame (smooth; poses sent from here in 60 Hz steps
        made the world shimmer). The game reports each pose it moves to; the gizmo is drawn with those. Right mouse
        held = look (the cursor goes back every frame)."""
        dyaw = dpitch = 0.0
        if edge[VK["RBUTTON"]] and not on_bar:
            self.look_from, self.look_t, self.looked = (c.x, c.y), time.perf_counter(), False
        elif now[VK["RBUTTON"]] and self.look_from:
            dx, dy = c.x - self.look_from[0], c.y - self.look_from[1]
            if dx or dy:
                self.looked = True
                dyaw, dpitch = dx * LOOK_DEG_PER_PX, dy * LOOK_DEG_PER_PX
                if bg.BACKGROUND:              # the virtual cursor goes back, Maxim's stays where it is
                    bg.VCURSOR[0] = tuple(self.look_from)
                else:
                    user32.SetCursorPos(*self.look_from)
                c.x, c.y = self.look_from
        # X flies down (Maxim 06.10.: Ctrl is for Ctrl+Z, +C, +V, +D - with Ctrl as down they flew the camera; Alt
        # is for Alt+Tab)
        mv = (now[VK["W"]] - now[VK["S"]], now[VK["D"]] - now[VK["A"]], now[VK["SPACE"]] - now[VK["X"]])
        fast = self.fly_speed / 4.0                  # the game flies 4 m/s times this
        active = any(mv) or dyaw or dpitch
        if active:
            # the game reports every pose it moves to (cam|...), the gizmo follows those - guessing the motion here
            # drifted (the app's timer is not exactly 60 Hz and the game shows a pose a little later)
            self.link.exec(f"cj_cam({mv[0]}, {mv[1]}, {mv[2]}, {fast:.1f}, {dyaw:.3f}, {dpitch:.3f})")
        elif self.flying:
            # released: stop at once (not after the game's 0.25 s timeout), then take the exact pose
            self.link.exec("cj_cam(0, 0, 0, 1, 0, 0)")
            self.link.exec("cj_cam_sync()")
        self.flying = bool(active)
        return self.flying

    def select_mode(self, edge, up, now, mx, my, w, h, a):
        if self.drag and self.drag["axis"] == "free":
            if now[VK["LBUTTON"]]:
                if (mx, my) != self.drag.get("last"):
                    self.drag["last"] = (mx, my)
                    self.link.exec(f"cj_move_free({a})")
                    guess = self.slide_guess(mx, my, w, h)
                    if guess:
                        self.selected = guess       # (the frame and its ring follow; the game says it at the end)
            else:
                s = self.drag["start"]
                self.link.exec(f"cj_move_done({s[0]:.3f}, {s[1]:.3f}, {s[2]:.3f})")
                self.drag = None
            return
        if self.drag:
            if now[VK["LBUTTON"]]:
                d = self.drag
                ax_px = d["axis_px"]
                n2 = ax_px[0] ** 2 + ax_px[1] ** 2
                if n2 > 1e-6:
                    t = ((mx - d["mouse"][0]) * ax_px[0] + (my - d["mouse"][1]) * ax_px[1]) / n2
                    target = list(d["start"])
                    target[d["axis"]] += t
                    if self.opts["grid"]:            # the dragged axis snaps to the grid (world grid)
                        g = self.opts["grid"]
                        target[d["axis"]] = round(target[d["axis"]] / g) * g
                    self.drag["sent"] = list(target)
                    off = self.drag.get("off") or (0.0, 0.0, 0.0)
                    self.selected = [t + o for t, o in zip(target, off)]     # (drawn where the game has it)
                    # a Go to's flag goes through anything, on the ground below it (Maxim 08.10.: it stuck at chests)
                    flag = self._selected_is_marker()
                    self.link.exec(f"cj_move_to({target[0]:.3f}, {target[1]:.3f}, {target[2]:.3f}, "
                                   f"{'true' if self.collide and not flag else 'false'}, "
                                   f"{'true' if flag or getattr(self, 'snap', False) else 'false'})")
            else:
                s = self.drag["start"]
                self.link.exec(f"cj_move_done({s[0]:.3f}, {s[1]:.3f}, {s[2]:.3f})")
                self.drag = None
            return
        if edge[VK["LBUTTON"]]:
            axis = self.gizmo_axis_at(mx, my, w, h)
            if axis == "free":
                self.drag = {"axis": "free", "start": list(self.selected), "last": None}
                return
            if axis is not None:
                o = self.cam.project(self.selected, w, h)
                end = list(self.selected)
                end[axis] += 1.0
                e = self.cam.project(end, w, h)
                if o and e:
                    self.drag = {"axis": axis, "start": list(self.selected), "mouse": (mx, my),
                                 "axis_px": (e[0] - o[0], e[1] - o[1])}      # pixels per metre along the axis
                    return
            # the object under the cursor by its real box, at once; the game's ray only when no box is hit
            hit = self.box_pick(mx, my, w, h)
            if hit:
                x, y, z = hit
                self.link.exec(f"cj_group_add_at({x:.3f}, {y:.3f}, {z:.3f})" if now[VK["SHIFT"]] else
                               f"cj_select_at({x:.3f}, {y:.3f}, {z:.3f})")
                return
            # Shift+click: one more into the selection (or out of it)
            self.click_px = None if now[VK["SHIFT"]] else (mx, my, w, h)
            self.link.exec(f"cj_select_add({a})" if now[VK["SHIFT"]] else f"cj_select({a})")

    def cursor_ray(self, mx, my, w, h):
        """(camera position, direction) of the ray through a window pixel (Camera.project the other way)."""
        import math
        f, r, u = self.cam.axes()
        tv = math.tan(math.radians(self.cam.fov) / 2)
        th = tv * w / h
        a, b = (2 * mx / w - 1) * th, (1 - 2 * my / h) * tv
        d = [f[i] + r[i] * a + u[i] * b for i in range(3)]
        n = math.sqrt(sum(x * x for x in d)) or 1.0
        return list(self.cam.pos), [x / n for x in d]

    def hover_object(self, on, mx, my, w, h, moved_cam):
        """Select mode: the object under the mouse for the overlay to light up (hud.hover) - worked out again only when
        the mouse or the camera moved."""
        if not on:
            self.hud.hover, self._hover_at = None, None
            return
        at = (round(mx), round(my), w, h)
        if at == getattr(self, "_hover_at", None) and not moved_cam:
            return
        self._hover_at = at
        pos = self.box_pick(mx, my, w, h) or self.screen_pick(mx, my, w, h, reach=30)
        i = self.project.find_object(self.place, pos) if pos is not None else None
        self.hud.hover = self.project.places[self.place]["objects"][i] if i is not None else None

    def box_pick(self, mx, my, w, h):
        """The own object whose box the cursor's ray goes through (picking.py), or None."""
        if not self.cam.ready:
            return None
        from . import picking
        from .quest import is_actor
        objs = self.project.places.get(self.place, {}).get("objects", [])
        picking.prepare([o["template"] for o in objs], self._depot)
        origin, direction = self.cursor_ray(mx, my, w, h)
        return picking.pick(origin, direction, objs, is_actor)

    def _depot(self):
        from .catalog_view import _depot
        return _depot()

    def screen_pick(self, mx, my, w, h, reach=40):
        """The position of the own object nearest to the click on the screen (its foot to 1 m up, within `reach`
        pixels; of several the one nearest to the camera), or None."""
        if not self.cam.ready:
            return None
        best = None
        for o in self.project.places.get(self.place, {}).get("objects", []):
            x, y, z = o["pos"]
            pts = [self.cam.project([x, y, z + dz], w, h) for dz in (0.0, 0.3, 0.6, 1.0)]
            pts = [p for p in pts if p]
            if not pts:
                continue
            px = min(((p[0] - mx) ** 2 + (p[1] - my) ** 2) ** 0.5 for p in pts)
            depth = sum((o["pos"][i] - self.cam.pos[i]) ** 2 for i in range(3)) ** 0.5
            if px <= reach and (best is None or (px, depth) < best[:2]):
                best = (px, depth, o["pos"])
        return best[2] if best else None

    def gizmo_axis_at(self, mx, my, w, h):
        """0 / 1 / 2: an arrow of the gizmo under the cursor; "free": its middle (move over the surfaces)."""
        if not self.selected or not self.cam.ready:
            return None
        o = self.cam.project(self.selected, w, h)
        if not o:
            return None
        if math.hypot(mx - o[0], my - o[1]) <= GIZMO_FREE_PX:
            return "free"
        best, best_d = None, GIZMO_PICK_PX
        for axis in range(3):
            end = list(self.selected)
            end[axis] += GIZMO_M
            e = self.cam.project(end, w, h)
            if not e:
                continue
            vx, vy = e[0] - o[0], e[1] - o[1]
            L2 = vx * vx + vy * vy or 1.0
            t = max(0.0, min(1.0, ((mx - o[0]) * vx + (my - o[1]) * vy) / L2))
            d = math.hypot(mx - (o[0] + t * vx), my - (o[1] + t * vy))
            if d < best_d:
                best, best_d = axis, d
        return best

    def close(self):
        if self.editing:
            self.link.exec("cj_edit(false)")
            self.show_built()
        self.link.exec("cj_sound_resume()")       # the game plays on without Conjunction
        self.stop.set()
        self.link.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--place", default="main")
    ap.add_argument("--template", default=None)
    ap.add_argument("--new", default=None, help="create the project with this name")
    args = ap.parse_args()
    if args.new and not os.path.exists(os.path.join(args.project, "project.yml")):
        pid = "".join(c for c in os.path.basename(os.path.abspath(args.project)).lower() if c.isalnum())
        Project.create(args.project, pid, args.new)
    project = Project(args.project)
    hwnd = game_window()
    if not hwnd:
        print("[editor] game window not found")
        return
    app = QtWidgets.QApplication(sys.argv)
    ed = Editor(project, args.place, args.template, hwnd)
    print(f"[editor] project {project.id}, place {args.place}: F8 editor (HUD, fly, place / select / move)", flush=True)
    app.aboutToQuit.connect(ed.close)
    try:
        app.exec()
    except KeyboardInterrupt:
        ed.close()


if __name__ == "__main__":
    main()
