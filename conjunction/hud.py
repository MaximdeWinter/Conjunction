"""The editor's overlay over the game - laid out like a professional tool, the game left free (Maxim 05.10.: "so viel
vom spiel übrig wie möglich", "übersichtlich, gut verstehbar, klar strukturiert", square corners):

  the bar        one thin line at the top: the menus (File, Edit, View, Build, Help), the four modes in the
                 middle, on the right the project's windows (Outliner, Quest), the project with its menu, the world
                 and Build & Play
  the strip      under the bar, only what the mode needs (select: grid, collision, drop, duplicate, delete;
                 place: grid, turn, align, random turn; terrain: the brush; look: lamp, light, fly speed)
  the hints      bottom left, on the game itself: what a click does now and the keys that apply
  windows        the things: an object's own window, the catalog, the outliner, the quest - opened when wanted

The menus are drawn in this window (a real menu is a window of its own - it would take the focus from the game).
Every action can have a key (Edit > Keyboard shortcuts), kept in the config as "hotkeys" (id -> key name).
"""
from PySide6 import QtCore, QtGui, QtWidgets

from . import config
from .cursor import user32
from .tooltips import tip


def export_label(e):
    """The menus' export: named for what the project is (a place mod or a quest)."""
    return "Export place mod ..." if e.project.meta.get("kind") == "place" else "Export quest file ..."


def _vanilla_on():
    """Edit Vanilla Objects is experimental (features.py, Maxim 06.10.)."""
    from . import features
    return features.experimental()


GWL_EXSTYLE, WS_EX_TRANSPARENT, WS_EX_LAYERED, WS_EX_NOACTIVATE = -20, 0x20, 0x80000, 0x08000000
GIZMO_M = 0.8
LIGHTS = ["game", "morning", "midday", "evening", "night"]
ON, OFF = "#f0f0f0", "#6a6a6a"
GOLD = "#d9a441"
BAR_H = 32

# id, kind, (unused: was 'pinned'), key by default
ACTIONS = [
    ("mode.select", "mode", True, "1"),
    ("mode.place", "mode", True, "2"),
    ("mode.terrain", "mode", True, "3"),
    ("mode.look", "mode", True, "4"),
    ("opt.edit_existing", "toggle", False, ""),
    ("opt.collision", "toggle", True, ""),
    ("opt.snap", "toggle", True, ""),
    ("opt.grid", "cycle", False, ""),
    ("opt.turn", "cycle", False, ""),
    ("opt.align", "toggle", False, ""),
    ("opt.random", "toggle", False, ""),
    ("opt.light", "choice", False, ""),
    ("opt.lamp", "toggle", False, "H"),
    ("opt.senses", "toggle", True, "V"),
    ("opt.markers", "cycle", True, "M"),
    ("opt.speed", "hold", False, "F"),
    ("opt.music", "toggle", False, ""),
    ("opt.sound", "toggle", False, ""),
    ("opt.catalog_screen", "cycle", False, ""),
    ("act.outliner", "button", True, ""),
    ("act.story", "button", True, ""),
    ("act.panel", "button", True, "Q"),
    ("act.play", "button", True, ""),
    ("act.build_play", "button", True, ""),
    ("act.player_here", "button", False, ""),
    ("act.drop", "button", False, ""),
    ("act.duplicate", "button", False, ""),
    ("act.delete", "button", False, ""),
]
KIND = {a: k for a, k, _p, _h in ACTIONS}
DEFAULT_KEYS = {a: h for a, _k, _p, h in ACTIONS if h}
MODES = [a for a, k, _p, _h in ACTIONS if k == "mode"]
# keys the editor uses itself (flying, looking, editing) - not for actions
RESERVED = {"W", "A", "S", "D", "SPACE", "CTRL", "SHIFT", "ALT", "TAB", "DELETE", "END", "F8", "ESC"}
MODE_ICONS = {"mode.look": "eye", "mode.select": "mouse-pointer-2", "mode.place": "package-plus",
              "mode.terrain": "mountain"}

BAR_STYLE = (
    "*{border-radius:0}"
    "#bar{background:rgba(20,20,22,228);border:none;border-bottom:1px solid rgba(255,255,255,20)}"
    "#strip,#menu,#settings{background:rgba(22,22,25,232);border:1px solid #45454c}"
    "QPushButton{color:#d4d4d6;background:transparent;border:1px solid transparent;padding:3px 9px;font:12px}"
    "QPushButton:hover{border-color:#6a6a70}"
    "QPushButton:checked{background:rgba(255,255,255,24);color:#fff}"
    "QPushButton:disabled{color:#6a6a70}"
    "QPushButton#menubtn{padding:3px 8px;color:#c8c8cc}"
    "QPushButton#menubtn:checked{background:#3a3a40;border-color:#3a3a40}"
    "QPushButton#mode{background:rgba(255,255,255,8);border:1px solid rgba(255,255,255,22);padding:3px 12px;"
    "color:#bdbdc2}"
    "QPushButton#mode:checked{background:#4b4b50;border-color:#c8c8c8;color:#fff;font:bold 12px}"
    "QPushButton#mode QLabel{padding:0;background:transparent;border:0}"
    "QPushButton#mode QLabel#modekey{color:#8a8a90;font:11px}"
    "QPushButton#play{background:#3c6e3f;border:1px solid #58a35c;color:#fff;font:bold 12px;padding:3px 12px}"
    "QPushButton#play:hover{background:#467f49}"
    # the play menu's entries green as Play (Maxim 06.10.)
    "QPushButton#entryplay{background:#3c6e3f;color:#fff;font:bold 12px;border:none;text-align:left;padding:5px 14px}"
    "QPushButton#entryplay:hover{background:#467f49}"
    "QPushButton#play{padding:0;border-right:none}"
    "QPushButton#play QLabel{padding:0;background:transparent;border:0;color:#fff}"
    "QPushButton#play QLabel#playtext{font:bold 12px}"
    "QPushButton#playmenu{background:#3c6e3f;border:1px solid #58a35c;border-left:1px solid #2c522e;color:#fff;"
    "padding:3px 5px}"
    "QPushButton#playmenu:checked{background:#2f5832}"
    "QPushButton#project{color:#ececee;font:bold 12px}"
    "QPushButton#entry{text-align:left;color:#dcdcde;padding:4px 18px 4px 10px;min-width:190px}"
    "QPushButton#entry:hover{background:#3a3a40;border-color:#3a3a40}"
    "QPushButton#entry:checked{color:#fff}"
    "QLabel{color:#bbb;font:12px;padding:0 6px}"
    "QLabel#world{color:#8c8c90;padding:0 8px 0 2px}"
    "QLabel#shortcut{color:#8a8a90;padding:0 10px 0 0}"
    "QLabel#group{color:#8c8c90;font:bold 11px;padding:6px 10px 2px 10px}"
    "QFrame#line{background:#45454c;max-height:1px;min-height:1px;margin:3px 0}"
    "QLabel#sep{color:#4a4a50;padding:0 1px}"
    "QLabel#hint{color:rgba(255,255,255,175);padding:0}"
    "QLabel#doing{color:#f0e2bd;font:bold 12px;padding:0 6px 0 0}"
    "QLabel#keycap{color:#ddd;background:rgba(40,40,44,225);border:1px solid #5a5a60;padding:0 5px;font:bold 11px}"
    "QFrame#busy{background:rgba(24,24,27,215);border:1px solid #5a5a60}"
    "QLabel#busydoing{color:#f0e2bd;font:bold 22px;padding:0 10px 0 0}"
    "QLabel#busykey{color:#eee;background:rgba(60,60,66,235);border:1px solid #7a7a80;padding:2px 10px;font:bold 17px}"
    "QPushButton#key{padding:3px 8px;font:12px;min-width:34px;color:#bbb;border:1px solid #45454c}"
    "QLabel#head{color:#eee;font:bold 12px;padding:4px 4px 2px 4px}"
    "QLineEdit{background:#1b1b1e;border:1px solid #5a5a60;color:#eee;padding:2px 4px;font:12px}")


def label(ed, a):
    """What an action says (its state included)."""
    o = ed.opts
    texts = {"mode.look": "Look", "mode.select": "Select", "mode.place": "Asset Browser", "mode.terrain": "Terrain",
             "opt.edit_existing": "Edit Vanilla Objects", "opt.collision": "Collision", "opt.snap": "Snap to ground", "opt.align": "Align",
             "opt.random": "Random turn", "opt.lamp": "Lamp", "opt.senses": "Senses", "opt.music": "Music",
             "opt.sound": "Sound", "act.panel": "Project", "act.outliner": "Outliner", "act.story": "Story",
             "act.build_play": "Build && Play", "act.play": "Play", "act.player_here": "Player here",
             "act.drop": "Drop",
             "act.duplicate": "Duplicate", "act.delete": "Delete"}
    if a in texts:
        return texts[a]
    if a == "opt.grid":
        return f"Grid {o['grid']:g} m" if o["grid"] else "Grid off"
    if a == "opt.turn":
        return f"Turn {o['turn']:g}°"
    if a == "opt.light":
        return f"Light: {LIGHTS[min(o.get('light', 0), len(LIGHTS) - 1)]}"
    if a == "opt.markers":
        return {"quest": "Markers: quest", "all": "Markers: all"}.get(getattr(ed, "markers", "off"), "Markers: off")
    if a == "opt.speed":
        return f"Fly {speed_text(ed.fly_speed)}"
    if a == "opt.catalog_screen":
        return "Asset Browser on the second screen" if ed.catalog_screen == "second" else "Asset Browser over the game"
    return ""


def speed_text(v):
    return f"{v:.1f} m/s" if v < 10 else f"{v:.0f} m/s"


def checked(ed, a):
    if a.startswith("mode."):
        return ed.mode == a[5:]
    return {"opt.edit_existing": getattr(ed, "edit_existing", False), "opt.collision": ed.collide,
            "opt.snap": getattr(ed, "snap", False),
            "opt.align": ed.opts["align"], "opt.random": ed.opts["random"],
            "opt.lamp": ed.lamp, "opt.senses": getattr(ed, "senses", False) is True, "opt.music": not ed.music_off,
            "opt.sound": not ed.sound_off, "act.panel": ed.panel_open(),
            "opt.catalog_screen": ed.catalog_screen == "second"}.get(a, False)


# what the strip shows in each mode (None: a separator)
# every mode has what looking needs (lamp, time of day, fly speed - Maxim 06.10.), select and place their own after it
BASE = ["opt.lamp", "opt.light", "opt.speed", None]
STRIP = {"select": BASE + ["opt.grid", "opt.collision", "opt.snap", "opt.edit_existing", None, "act.drop",
                           "act.duplicate", "act.delete"],
         "place": BASE + ["opt.grid", "opt.turn", "opt.align", "opt.random", "opt.collision"],
         "look": BASE + ["act.player_here"]}


class Hud(QtWidgets.QWidget):
    """Transparent window over the game: the bar, the strip, the menus, the hints and what is drawn into the world.
    Clicks go through it except over the bar, the strip and an open menu."""

    def __init__(self, editor):
        super().__init__(None, QtCore.Qt.FramelessWindowHint | QtCore.Qt.Tool |    # z-order: Editor.stack
                         QtCore.Qt.WindowDoesNotAcceptFocus)
        self.ed = editor
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground)
        self.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        self.setAttribute(QtCore.Qt.WA_AlwaysShowToolTips)
        self.setStyleSheet(BAR_STYLE)
        cfg = config.load()
        self.keys = dict(DEFAULT_KEYS, **cfg.get("hotkeys", {}))
        for a, k in DEFAULT_KEYS.items():       # a new default key another action of the user has: not this one's
            if a not in cfg.get("hotkeys", {}) and list(self.keys.values()).count(k) > 1:
                self.keys[a] = ""
        self.capturing = None                   # action whose key is being set (the editor feeds the next key)
        self.buttons = {}                       # action -> its button in the bar or the strip
        self.menu_open = None                   # the menu shown now ("File", ... or "project")
        self.gizmo = None                       # {"pos": [x, y, z], "hover": axis or None}
        self.dock_preview = None                # where a dragged window would dock (screen rect, dock.py)
        self.rows = {}
        self._build_bar()
        self._build_strip()
        # the menu shown under its button (one at a time) - a window of its own, above the panel and the catalog's
        # windows (Maxim 06.10.: as part of the overlay it lay under the Asset Browser)
        self.menu = QtWidgets.QFrame(None, QtCore.Qt.FramelessWindowHint | QtCore.Qt.Tool |
                                     QtCore.Qt.WindowStaysOnTopHint | QtCore.Qt.WindowDoesNotAcceptFocus)
        self.menu.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        self.menu.setObjectName("menu")
        QtWidgets.QVBoxLayout(self.menu).setContentsMargins(1, 3, 1, 3)
        self.menu.layout().setSpacing(0)
        self.menu.hide()
        self.settings = QtWidgets.QFrame(self)  # Keyboard shortcuts
        self.settings.setObjectName("settings")
        self.settings.hide()
        self._build_settings()
        self._build_brush()
        self.hints = QtWidgets.QFrame(self)     # bottom left, on the game
        hl = QtWidgets.QHBoxLayout(self.hints)
        hl.setContentsMargins(0, 0, 0, 0)
        hl.setSpacing(5)
        self.h_doing = QtWidgets.QLabel()
        self.h_doing.setObjectName("doing")
        hl.addWidget(self.h_doing)
        self.h_parts = []
        for _ in range(8):
            k = QtWidgets.QLabel()
            hl.addWidget(k)
            self.h_parts.append(k)
        self.hints.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents)
        self.sync()

    # --- building
    def _button(self, lay, text, checkable, fn, name=None):
        b = QtWidgets.QPushButton(text)
        b.setCheckable(checkable)
        b.setFocusPolicy(QtCore.Qt.NoFocus)
        if name:
            b.setObjectName(name)
        b.clicked.connect(fn)
        lay.addWidget(b)
        return b

    def _build_bar(self):
        from .icons import pixmap
        self.bar = QtWidgets.QFrame(self)
        self.bar.setObjectName("bar")
        h = QtWidgets.QHBoxLayout(self.bar)
        h.setContentsMargins(8, 2, 8, 2)
        h.setSpacing(2)
        logo = QtWidgets.QLabel()
        import os
        ico = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "conjunction.ico")
        logo.setPixmap(QtGui.QIcon(ico).pixmap(18, 18))
        tip(logo, "bar.logo")
        h.addWidget(logo)
        self.menu_buttons = {}
        for name in ("File", "Edit", "View", "Build", "Help"):
            b = self._button(h, name, True, lambda _c=False, n=name: self.toggle_menu(n), "menubtn")
            tip(b, f"menu.{name.lower()}")
            self.menu_buttons[name] = b
        h.addStretch(1)
        group = QtWidgets.QFrame()
        gl = QtWidgets.QHBoxLayout(group)
        gl.setContentsMargins(0, 0, 0, 0)
        gl.setSpacing(0)
        from . import features
        for a in MODES:
            if a == "mode.terrain" and not features.experimental():
                continue                            # (experimental: features.py)
            b = self._mode_button(a, pixmap)
            gl.addWidget(b)
            tip(b, a)
            self.buttons[a] = b
        h.addWidget(group)
        h.addStretch(1)
        for a in ("act.panel",):                    # (the story map, the outliner: View - Project > Places is the
            # outliner now, Maxim 07.10.)
            # Project: a menu like File - its entries the panel's tabs, each opens the panel there (Maxim 07.10.)
            fn = (lambda _c=False: self.toggle_menu("Project")) if a == "act.panel" else                 (lambda _c=False, act=a: self.trigger(act))
            self.buttons[a] = tip(self._button(h, label(self.ed, a), True, fn), a)
        self.menu_buttons["Project"] = self.buttons["act.panel"]
        h.addSpacing(8)
        self.b_project = tip(self._button(h, "", True, lambda _c=False: self.toggle_menu("project"), "project"),
                             "bar.project")
        self.name_edit = QtWidgets.QLineEdit()
        self.name_edit.setFixedWidth(200)
        self.name_edit.hide()
        self.name_edit.returnPressed.connect(self._rename_done)
        self.name_edit.editingFinished.connect(self._rename_done)
        tip(self.name_edit, "pan.project_name")
        h.addWidget(self.name_edit)
        self.l_world = tip(QtWidgets.QLabel(""), "bar.where")
        self.l_world.setObjectName("world")
        h.addWidget(self.l_world)
        # Play as one split button (Maxim 05.10., as in Unreal): it runs what the drop-down chose - Play (the play
        # icon) or Build & Play (the wrench)
        self.play_kind = config.load().get("play_button", "play")
        split = QtWidgets.QFrame()
        sl = QtWidgets.QHBoxLayout(split)
        sl.setContentsMargins(0, 0, 0, 0)
        sl.setSpacing(0)
        h.addWidget(split)
        self.b_play = self._button(sl, "", False, lambda _c=False: self.trigger(f"act.{self.play_kind}"), "play")
        pl = QtWidgets.QHBoxLayout(self.b_play)     # icon and text as labels (they measure themselves; a styled
        pl.setContentsMargins(10, 2, 10, 2)          # button's own icon + text did not: the text was cut)
        pl.setSpacing(6)
        self.play_icon, self.play_text = QtWidgets.QLabel(), QtWidgets.QLabel()
        self.play_text.setObjectName("playtext")
        for w in (self.play_icon, self.play_text):
            w.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents)
            pl.addWidget(w)
        self.b_play_menu = tip(self._button(sl, "▾", True, lambda _c=False: self.toggle_menu("play"), "playmenu"),
                               "bar.play_menu")
        for b in (self.b_play, self.b_play_menu):  # one height: the two halves are one button
            b.setFixedHeight(24)

    def _mode_button(self, a, pixmap):
        """A mode: its icon, its name and its key in grey."""
        b = QtWidgets.QPushButton()
        b.setObjectName("mode")
        b.setCheckable(True)
        b.setFocusPolicy(QtCore.Qt.NoFocus)
        b.clicked.connect(lambda _c=False, act=a: self.trigger(act))
        lay = QtWidgets.QHBoxLayout(b)
        lay.setContentsMargins(10, 2, 10, 2)
        lay.setSpacing(6)
        ic = QtWidgets.QLabel()
        ic.setPixmap(pixmap(MODE_ICONS.get(a, "square"), "#dddddd", 14))
        text = QtWidgets.QLabel(label(self.ed, a))
        key = QtWidgets.QLabel(self.keys.get(a, ""))
        key.setObjectName("modekey")
        b.key_label = key
        for w in (ic, text, key):
            w.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents)
            lay.addWidget(w)
        b.setMinimumWidth(lay.sizeHint().width() + 16)
        b.setMinimumHeight(24)
        return b

    def _build_strip(self):
        self.strip = QtWidgets.QFrame(self)
        self.strip.setObjectName("strip")
        h = QtWidgets.QHBoxLayout(self.strip)
        h.setContentsMargins(4, 2, 4, 2)
        h.setSpacing(1)
        self.strip_items = {}
        seen = []
        for items in STRIP.values():
            for a in items:
                if a and a not in seen and (a != "opt.edit_existing" or _vanilla_on()):
                    seen.append(a)
        for a in seen:
            fn = (lambda _c=False: self._light_menu()) if a == "opt.light" else \
                (lambda _c=False, act=a: self.trigger(act))
            b = tip(self._button(h, label(self.ed, a), KIND[a] not in ("button", "hold"), fn), a)
            self.strip_items[a] = b
        self.strip_seps = []
        for _ in range(3):
            s = QtWidgets.QLabel("|")
            s.setObjectName("sep")
            h.addWidget(s)
            self.strip_seps.append(s)

    def _fill_strip(self, mode):
        """The strip's buttons in the mode's order (the others hidden)."""
        lay = self.strip.layout()
        items = STRIP.get(mode)
        for w in list(self.strip_items.values()) + self.strip_seps:
            w.hide()
        if not items:
            return False
        seps = iter(self.strip_seps)
        items = [a for a in items if a is None or a in self.strip_items]     # (an experimental one left out)
        for i, a in enumerate(items):
            w = next(seps) if a is None else self.strip_items[a]
            lay.removeWidget(w)
            lay.insertWidget(i, w)
            w.show()
        return True

    # --- the menus
    def _menu_entries(self, name):
        """[(text, fn, shortcut, checked or None, enabled)] - None: a line; ("group", text): a heading."""
        e = self.ed
        sel = bool(getattr(e, "selected", None))
        k = self.keys.get
        if name == "Project":                     # the panel's tabs (a plug-in's too); the one shown is ticked
            tabs = e.panel.tabs
            shown = e.panel.isVisible() and tabs.isVisible()
            # (asked here, not of Qt: a panel never shown yet calls every tab but the first hidden - 07.10.)
            place = e.project.meta.get("kind") == "place"
            out = [(tabs.tabText(i), lambda i=i: e.open_panel_tab(i), "", shown and tabs.currentIndex() == i, True)
                   for i in range(tabs.count()) if not (place and tabs.widget(i) is e.panel.board)]
            if shown:
                out += [None, ("Close", lambda: e.toggle_panel(), k("act.panel", ""), None, True)]
            return out
        if name == "File":
            return ([("New project", self._new_project, "", None, True),
                     ("Open project ...", e.open_projects, "", None, True),
                     ("Rename project", self._rename_start, "", None, True), None,
                    (export_label(e), lambda: e.panel._export(), "", None, True),
                    ("Open screenshots folder", e.open_screenshots, "", None, True),
                    ("Library ...", self._quests_to_play, "", None, True),   # (the app's page of that name)
                    ("Settings ...", self._open_settings, "", None, True),   # (Profile too)
                    ("History ...", self._open_history, "", None, True), None,   # (the open project's)
                    ("Game menu ...", e.open_game_menu, "", None, True),
                    ("Quit Conjunction", QtWidgets.QApplication.instance().quit, "", None, True)])
        if name == "Edit":
            return [("Undo", e.undo_last, "Ctrl+Z", None, True), None,
                    ("Copy", e.copy_selection, "Ctrl+C", None, sel),
                    ("Duplicate", lambda: e.link.exec("cj_duplicate()"), "Ctrl+D", None, sel),
                    ("Delete", lambda: e.link.exec("cj_delete_selected()"), "Del", None, sel),
                    ("Drop to ground", lambda: e.link.exec("cj_drop_selected()"), "End", None, sel), None,
                    ] + ([("Edit Vanilla Objects", e.toggle_edit_existing, k("opt.edit_existing", ""),
                            checked(e, "opt.edit_existing"), True)] if _vanilla_on() else []) + [
                    ("Player here", e.player_here, k("act.player_here", ""), None, True), None,
                    ("Keyboard shortcuts ...", self._toggle_settings, "", None, True)]
        if name == "View":
            out = [("Outliner", lambda: self.trigger("act.outliner"), k("act.outliner", ""), None, True),
                   ("Project", lambda: self.trigger("act.panel"), k("act.panel", ""), checked(e, "act.panel"), True),
                   ("Story map", lambda: self.trigger("act.story"), k("act.story", ""), None, True),
                   None]
            for a in ("opt.markers", "opt.senses", "opt.lamp", "opt.music", "opt.sound", "opt.catalog_screen"):
                c = checked(e, a) if KIND[a] == "toggle" or a == "opt.catalog_screen" else None
                out.append((label(e, a), lambda act=a: self.trigger(act), k(a, ""), c, True))
            out.append(("group", "Light"))
            light = min(e.opts.get("light", 0), len(LIGHTS) - 1)
            for i, n in enumerate(LIGHTS):
                out.append((n.capitalize(), lambda i=i: e.set_option("light", i), "", i == light, True))
            return out
        if name == "Build":
            p = e.panel
            return [("Build && Play", lambda: self.trigger("act.build_play"), k("act.build_play", ""), None, True),
                    ("Check", lambda: p._build(False), "", None, True),
                    (export_label(e), lambda: p._export(), "", None, True), None,
                    ("Build mesh library", lambda: p._meshlib(), "", None, True),
                    ("Build foliage library", lambda: p._foliagelib(), "", None, True),
                    ("Content pack ...", lambda: p._pack_maker(), "", None, True), None,
                    ("Build output", lambda: self._show_build_tab(), "", None, True)]
        if name == "Help":
            from . import __version__
            return [("Keyboard shortcuts ...", self._toggle_settings, "", None, True),
                    ("Report a bug ...", self.open_bug_report, "", None, True), None,
                    ("group", f"Conjunction {__version__}")]
        if name == "play":
            return [("Play", lambda: self.set_play_kind("play"), k("act.play", ""), self.play_kind == "play", True),
                    ("Build && Play", lambda: self.set_play_kind("build_play"), k("act.build_play", ""),
                     self.play_kind == "build_play", True)]
        if name == "project":
            return [("Rename", self._rename_start, "", None, True),
                    ("New project", self._new_project, "", None, True),
                    ("Open project ...", e.open_projects, "", None, True)]
        return []

    def toggle_menu(self, name):
        if self.menu_open == name or name is None:
            self.close_menu()
            return
        self.close_menu()
        lay = self.menu.layout()
        for e in self._menu_entries(name):
            if e is None:
                line = QtWidgets.QFrame()
                line.setObjectName("line")
                lay.addWidget(line)
                continue
            if e[0] == "group":
                g = QtWidgets.QLabel(e[1])
                g.setObjectName("group")
                lay.addWidget(g)
                continue
            text, fn, short, on, enabled = e
            b = QtWidgets.QPushButton(("✓  " if on else "     ") + text if on is not None else "     " + text)
            b.setObjectName("entryplay" if name == "play" else "entry")
            b.setFocusPolicy(QtCore.Qt.NoFocus)
            b.setEnabled(enabled)
            b.clicked.connect(lambda _c=False, f=fn: (self.close_menu(), f(), self.sync()))
            if short:
                row = QtWidgets.QHBoxLayout(b)
                row.setContentsMargins(0, 0, 0, 0)
                row.addStretch(1)
                s = QtWidgets.QLabel(short)
                s.setObjectName("shortcut")
                s.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents)
                row.addWidget(s)
                b.setMinimumWidth(b.sizeHint().width() + s.sizeHint().width() + 24)
            lay.addWidget(b)
        self.menu_open = name
        src = {"project": self.b_project, "play": self.b_play_menu}.get(name) or self.menu_buttons[name]
        src.setChecked(True)
        # under its button, measured in the overlay (the button may sit in a group of its own: its geometry is not
        # the bar's - the play menu came up at the left edge, 06.10.); a button at the right: right edges together
        def where():
            at = src.mapTo(self, QtCore.QPoint(0, 0))
            left, right = at.x(), at.x() + src.width()
            if name == "play":                          # the two halves of Play are one button: under both
                left = self.b_play.mapTo(self, QtCore.QPoint(0, 0)).x()
            x = left if left + self.menu.width() <= self.width() - 4 else right - self.menu.width()
            return x, self.bar.geometry().bottom() + 1
        self._show_menu(where)

    def _show_menu(self, where):
        """The menu window at `where()` (a point in the overlay), on top of every window of Conjunction."""
        self.menu.setStyleSheet(self.styleSheet())     # (a window of its own: the overlay's look given to it)
        self.menu.adjustSize()
        x, y = where()
        self.menu.move(self.mapToGlobal(QtCore.QPoint(max(0, x), y)))
        self.menu.show()
        self.menu.raise_()
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None                        # stacked anew: the menu last, above the rest

    def close_menu(self):
        lay = self.menu.layout()
        while lay.count():
            w = lay.takeAt(0).widget()
            if w:
                w.deleteLater()
        self.menu.hide()
        self.menu_open = None
        for b in list(self.menu_buttons.values()) + [self.b_project, self.b_play_menu]:
            b.setChecked(False)

    def _light_menu(self):
        """The strip's Light: the times of day as a menu under it."""
        if self.menu_open == "light":
            self.close_menu()
            return
        self.close_menu()
        lay = self.menu.layout()
        light = min(self.ed.opts.get("light", 0), len(LIGHTS) - 1)
        for i, n in enumerate(LIGHTS):
            b = QtWidgets.QPushButton(("✓  " if i == light else "     ") + n.capitalize())
            b.setObjectName("entry")
            b.setFocusPolicy(QtCore.Qt.NoFocus)
            b.clicked.connect(lambda _c=False, k=i: (self.close_menu(), self.ed.set_option("light", k), self.sync()))
            lay.addWidget(b)
        self.menu_open = "light"
        b = self.strip_items["opt.light"]
        self._show_menu(lambda: (b.mapTo(self, QtCore.QPoint(0, 0)).x(), self.strip.geometry().bottom() + 1))

    # --- the project (the bar's name and File)
    def _new_project(self):
        """File > New project: name and kind asked over the game (Maxim 06.10.: a quest or a place mod)."""
        from . import dialogs
        from .app import NewProjectDialog
        from .project import new_project
        dlg = NewProjectDialog(in_game=True)
        if dialogs.run_dialog(dlg, "New project", "new project") == QtWidgets.QDialog.Accepted:
            # the game again with only the new project in it (Maxim 07.10.: nothing of the others in the world)
            self.ed.start_clean(new_project(dlg.name(), dlg.kind()))

    def _open_settings(self):
        """The app's Settings in the game (Maxim 06.10.: the app's window is gone while the game runs - the profile
        and its history could not be reached)."""
        from .settings_view import SettingsPage
        w = self.ed.panel.open_window("settings", "Settings", lambda: SettingsPage(self.ed.plugins))
        if w.width() < 1000 or w.height() < 640:        # (06.10.: the key file's path and the buttons cut off)
            w.resize(max(w.width(), 1000), max(w.height(), 640))

    def _open_history(self):
        """The open project's history in the game: who made and changed it, with which tools, whether the
        signatures hold (the app's Projects > History - its window is gone while the game runs)."""
        import os
        from . import dialogs, provenance
        from .profile_view import HistoryDialog
        path = self.ed.project.path
        steps = provenance.read(path)
        check = provenance.check(steps, provenance.content_hash(path)) if steps else None
        dlg = HistoryDialog(steps, check, None, title=f"History of {os.path.basename(path)}")
        dialogs.run_dialog(dlg, f"History of {os.path.basename(path)}", "history")

    def _quests_to_play(self):
        from .library_view import LibraryWindow
        self.ed.panel.open_window("library", "Library", LibraryWindow)

    def _rename_start(self):
        self.b_project.hide()
        self.name_edit.setText(str(self.ed.project.meta.get("name") or ""))
        self.name_edit.show()
        self.name_edit.selectAll()
        self.click_through(False)
        self.ed.typing.start(self.name_edit)
        self.sync()

    def _rename_done(self):
        if self.name_edit.isHidden():
            return
        from .project import rename
        text = self.name_edit.text()
        self.name_edit.hide()
        self.b_project.show()
        self.ed.typing.stop()
        try:
            rename(self.ed.project, text)
        except OSError as ex:                       # (the folder in use: the name changes, the folder stays)
            print(f"[hud] rename: {ex}", flush=True)
        panel = getattr(self.ed, "panel", None)
        if panel is not None and hasattr(panel, "_show_project_name"):
            panel._show_project_name()
        self.sync()

    def _show_build_tab(self):
        e = self.ed
        if not (e.panel.isVisible() and e.panel.tabs.isVisible()):
            e.toggle_panel()
        e.panel.tabs.setCurrentIndex(3)

    def set_play_kind(self, kind):
        """What the play button runs (the drop-down's choice, kept)."""
        self.play_kind = kind
        cfg = config.load()
        cfg["play_button"] = kind
        config.save(cfg)
        self.sync()

    def _play_icon(self, kind):
        """Play: the play icon; Build & Play: the wrench (a pixmap)."""
        from .icons import pixmap
        return pixmap("wrench" if kind == "build_play" else "play", "#ffffff", 15)

    def open_bug_report(self):
        """The bug report window (one; shown again if it was closed)."""
        from .bugreport_view import BugWindow
        self.ed.bug_window = self.ed.panel.open_window("bug", "Report a bug", lambda: BugWindow(self.ed)).body

    def _build_brush(self):
        from .terraintool import TOOLS
        self.brush_panel = QtWidgets.QFrame(self)
        self.brush_panel.setObjectName("settings")
        lay = QtWidgets.QVBoxLayout(self.brush_panel)
        lay.setContentsMargins(8, 6, 8, 8)
        lay.setSpacing(4)

        def row():
            r = QtWidgets.QHBoxLayout()
            r.setSpacing(4)
            lay.addLayout(r)
            return r

        def button(r, text, fn, name, checkable=True):
            b = tip(self._button(r, text, checkable, fn), name)
            return b

        r = row()
        self.b_tools = {op: button(r, text, lambda _c=False, o=op: self._brush("op", o), f"terrain.{op}")
                        for op, text in TOOLS}
        r = row()
        self.l_size = tip(QtWidgets.QLabel(), "terrain.size")
        r.addWidget(self.l_size)
        button(r, "-", lambda _c=False: self._brush_step("radius", -2), "terrain.smaller", False)
        button(r, "+", lambda _c=False: self._brush_step("radius", 2), "terrain.bigger", False)
        self.l_strength = tip(QtWidgets.QLabel(), "terrain.strength")
        r.addWidget(self.l_strength)
        button(r, "-", lambda _c=False: self._brush_step("strength", -2), "terrain.weaker", False)
        button(r, "+", lambda _c=False: self._brush_step("strength", 2), "terrain.stronger", False)
        r.addSpacing(10)
        self.b_falloff = {k: button(r, text, lambda _c=False, v=k: self._brush("falloff", v), f"terrain.edge_{k}")
                          for k, text in (("smooth", "Soft"), ("linear", "Linear"), ("hard", "Hard"))}
        r.addSpacing(10)
        self.b_shape = {k: button(r, text, lambda _c=False, v=k: self._brush("shape", v), f"terrain.{k}")
                        for k, text in (("circle", "Circle"), ("square", "Square"))}
        r.addStretch(1)
        r = row()
        self.b_height = button(r, "", lambda _c=False: self._brush_height(), "terrain.height", False)
        self.l_extra = tip(QtWidgets.QLabel(), "terrain.extra")
        r.addWidget(self.l_extra)
        self.b_extra = (button(r, "-", lambda _c=False: self._brush_extra(-1), "terrain.extra_less", False),
                        button(r, "+", lambda _c=False: self._brush_extra(1), "terrain.extra_more", False))
        r.addStretch(1)
        self.l_painted = tip(QtWidgets.QLabel(), "terrain.painted")
        r.addWidget(self.l_painted)
        button(r, "Undo", lambda _c=False: self._tool() and self._tool().undo_button(), "terrain.undo", False)
        button(r, "Reset", lambda _c=False: self._tool() and self._tool().clear(), "terrain.reset", False)
        self.brush_panel.hide()

    def _tool(self):
        return getattr(self.ed, "terrain_tool", None)

    def _brush(self, key, value):
        t = self._tool()
        if t is not None:
            if key == "op":
                from .terraintool import STRENGTH
                lo, hi = STRENGTH.get(value, (0.05, 1.0))
                t.brush["strength"] = max(lo, min(hi, t.brush["strength"]))
            t.set(key, value)

    def _brush_step(self, key, notches):
        t = self._tool()
        if t is not None:
            (t.resize if key == "radius" else t.strengthen)(notches)

    def _brush_height(self):
        """Flatten / set: the height under the cursor taken (fixed), or back to 'where the drag begins'."""
        t = self._tool()
        if t is None:
            return
        if t.brush.get("height") is None and t.cursor:
            t.set("height", round(t.cursor[2], 2))
        else:
            t.set("height", None)

    def _brush_extra(self, sign):
        """Terrace: its step; Roughen: the size of its bumps."""
        t = self._tool()
        if t is None:
            return
        key = "step" if t.brush["op"] == "terrace" else "scale"
        t.set(key, round(max(0.25, min(40.0, t.brush[key] * (1.25 if sign > 0 else 0.8))), 2))

    def _sync_brush(self):
        t = self._tool()
        on = t is not None and getattr(self.ed, "mode", "") == "terrain" and getattr(self.ed, "editing", False) is True
        self.brush_panel.setVisible(on)
        if not on:
            return
        from .terraintool import STRENGTH
        b = t.brush
        for op, w in self.b_tools.items():
            w.setChecked(b["op"] == op)
        for k, w in self.b_falloff.items():
            w.setChecked(b["falloff"] == k)
        for k, w in self.b_shape.items():
            w.setChecked(b["shape"] == k)
        self.l_size.setText(f"Size {b['radius'] * 2:g} m")
        self.l_strength.setText(f"Strength {b['strength']:g} m" if b["op"] in STRENGTH else
                                f"Strength {b['strength'] * 100:.0f} %")
        level = b["op"] in ("flatten", "set")
        self.b_height.setVisible(level)
        self.b_height.setText(f"Height: {b['height']:g} m" if b.get("height") is not None else
                              "Height: where the stroke starts")
        extra = {"terrace": f"Step {b['step']:g} m", "noise": f"Bumps {b['scale']:g} m"}.get(b["op"])
        self.l_extra.setVisible(bool(extra))
        self.l_extra.setText(extra or "")
        for w in self.b_extra:
            w.setVisible(bool(extra))
        n = t.painted()
        self.l_painted.setText(f"{n} stroke{'s' if n != 1 else ''} · applied by Build && Play" if n else "")
        self.brush_panel.adjustSize()
        ctx = self.bar.geometry()
        self.brush_panel.move(max(0, (self.width() - self.brush_panel.width()) // 2), ctx.bottom() + 6)
        self.brush_panel.raise_()

    def _build_settings(self):
        """Keyboard shortcuts: every action with its key (a click on the key, then the new key; Esc: none)."""
        grid = QtWidgets.QGridLayout(self.settings)
        grid.setContentsMargins(8, 6, 8, 8)
        grid.setHorizontalSpacing(6)
        grid.setVerticalSpacing(3)
        head = QtWidgets.QLabel("KEYBOARD SHORTCUTS")
        head.setObjectName("head")
        grid.addWidget(head, 0, 0, 1, 2)
        close = self._button(QtWidgets.QHBoxLayout(), "✕", False, lambda _c=False: self._toggle_settings())
        grid.addWidget(close, 0, 2)
        from . import features
        shown = [x for x in ACTIONS if x[0] not in ("mode.terrain", "opt.edit_existing") or features.experimental()]
        for r, (a, kind, _p, _h) in enumerate(shown, start=1):
            name = QtWidgets.QLabel(label(self.ed, a).replace("&&", "&"))
            tip(name, a)
            key = QtWidgets.QPushButton()
            key.setObjectName("key")
            key.setFocusPolicy(QtCore.Qt.NoFocus)
            key.clicked.connect(lambda _c=False, act=a: self._capture(act))
            tip(key, "set.key")
            grid.addWidget(name, r, 0)
            grid.addWidget(key, r, 1)
            self.rows[a] = (name, key)

    # --- state
    def sync(self):
        e = self.ed
        editing = getattr(e, "editing", False) is True
        for a, b in self.buttons.items():
            if a.startswith("mode."):
                b.setChecked(checked(e, a))
                b.key_label.setText(self.keys.get(a, ""))
            else:
                b.setChecked(checked(e, a))
        self.play_icon.setPixmap(self._play_icon(self.play_kind))
        self.play_text.setText(label(e, f"act.{self.play_kind}").replace("&&", "&"))
        # (from the labels: the layout's own size hint still had the text before - Play -> Build & Play was cut)
        self.b_play.setMinimumWidth(10 + self.play_icon.sizeHint().width() + 6 + self.play_text.sizeHint().width() + 12)
        tip(self.b_play, f"act.{self.play_kind}")
        p = getattr(e, "project", None)
        meta = getattr(p, "meta", None)
        name = (meta.get("name") if isinstance(meta, dict) else None) or getattr(p, "id", "")
        self.b_project.setText(f"{name}  ▾")
        world = getattr(e, "world", None)
        place = getattr(e, "place", "")
        from .packaging import WORLD_NAMES
        world_text = WORLD_NAMES.get(world, world) if isinstance(world, str) else ""
        self.l_world.setText("  ·  ".join(t for t in (place if isinstance(place, str) else "", world_text) if t))
        for a, b in self.strip_items.items():
            b.setText(label(e, a))
            b.setChecked(checked(e, a) or (a == "opt.light" and self.menu_open == "light"))
            if a in ("act.drop", "act.duplicate", "act.delete"):
                b.setEnabled(bool(getattr(e, "selected", None)))
        for a, (name_w, key) in self.rows.items():
            name_w.setText(label(e, a).replace("&&", "&"))
            k = self.keys.get(a, "")
            key.setText("Press a key" if self.capturing == a else (k or "-"))
        # the bar: the window's width, at the top
        self.bar.setGeometry(0, 0, self.width(), BAR_H)
        self.bar.setVisible(editing or not hasattr(e, "editing"))
        mode = getattr(e, "mode", "")
        has_strip = self._fill_strip(mode) and self.bar.isVisible()
        self.strip.setVisible(has_strip)
        from .dock import insets
        ins = insets()                          # (windows docked at the sides: the strip and hints keep clear)
        self.ins = ins
        if has_strip:
            self.strip.adjustSize()
            free_l, free_r = ins["left"], self.width() - ins["right"]
            self.strip.move(max(free_l, free_l + (free_r - free_l - self.strip.width()) // 2), BAR_H + ins["top"] + 6)
        self._sync_brush()
        self._sync_hints()
        if not self.settings.isHidden():
            self.settings.adjustSize()
            self.settings.move(max(8, self.width() - self.settings.width() - 12), BAR_H + 6)
            self.settings.raise_()
        self.update()

    def _sync_hints(self):
        """What a click does now and its keys (the editor's doing()). Something going on that Esc ends (placing,
        picking, a point) or a path being drawn: big, bottom middle (Maxim 07.10.: the small line bottom left went
        unseen); a mode's keys (terrain): small, bottom left."""
        e = self.ed
        got = e.doing() if hasattr(e, "doing") else None
        doing, keys = got if isinstance(got, tuple) and len(got) == 2 else (None, [])
        busy = bool(doing) and ("Esc" in keys or getattr(e, "path_tool", None) is not None)
        self.hints.setObjectName("busy" if busy else "")
        self.hints.layout().setContentsMargins(*((18, 10, 18, 10) if busy else (0, 0, 0, 0)))
        self.h_doing.setObjectName("busydoing" if busy else "doing")
        self.h_doing.setText(doing or "")
        self.h_doing.setVisible(bool(doing))
        for w in [self.hints, self.h_doing]:
            w.style().unpolish(w)
            w.style().polish(w)
        for w, k in zip(self.h_parts, list(keys) + [None] * len(self.h_parts)):
            w.setObjectName("busykey" if busy else "keycap")
            w.setText(k or "")
            w.setVisible(bool(k))
            w.style().unpolish(w)
            w.style().polish(w)
        self.hints.setVisible(bool(doing) and getattr(e, "editing", False) is True)
        self.hints.adjustSize()
        ins = getattr(self, "ins", None) or {"left": 0, "right": 0, "bottom": 0}
        if busy:
            free_l, free_r = ins["left"], self.width() - ins.get("right", 0)
            x = free_l + (free_r - free_l - self.hints.width()) // 2
            self.hints.move(max(free_l, x), self.height() - self.hints.height() - 60 - ins["bottom"])
        else:
            self.hints.move(14 + ins["left"], self.height() - self.hints.height() - 12 - ins["bottom"])

    def trigger(self, a, from_menu=False):
        """An action from the bar, the strip, a menu or its key."""
        e = self.ed
        if a.startswith("mode."):
            # the key of the mode it is in: back to select (Maxim 06.10.: the place key opened the catalog but
            # did not close it)
            e.set_mode("select" if e.mode == a[5:] and a != "mode.select" else a[5:])
        elif a == "opt.edit_existing":
            e.toggle_edit_existing()
        elif a == "opt.collision":
            e.toggle_collision()
        elif a == "opt.snap":
            e.toggle_snap()
        elif a in ("opt.grid", "opt.turn", "opt.align", "opt.random"):
            e.cycle_option(a[4:])
        elif a == "opt.light":
            e.set_option("light", (e.opts.get("light", 0) + 1) % len(LIGHTS))
        elif a == "opt.lamp":
            e.toggle_lamp()
        elif a == "opt.senses":
            e.toggle_senses()
        elif a == "opt.markers":
            e.markers = {"off": "quest", "quest": "all"}.get(getattr(e, "markers", "off"), "off")
        elif a == "opt.music":
            e.toggle_music()
        elif a == "opt.sound":
            e.toggle_sound()
        elif a == "opt.catalog_screen":
            e.cycle_catalog_screen()
        elif a == "act.panel":
            e.toggle_project()
        elif a == "act.outliner":
            e.open_outliner()
        elif a == "act.story":
            e.open_story()
        elif a == "act.build_play":
            e.build_play_now()
        elif a == "act.play":
            e.play()
        elif a == "act.player_here":
            e.player_here()
        elif a == "act.drop":
            e.link.exec("cj_drop_selected()")
        elif a == "act.duplicate":
            e.link.exec("cj_duplicate()")
        elif a == "act.delete":
            e.link.exec("cj_delete_selected()")
        self.sync()

    def _toggle_settings(self):
        self.close_menu()
        self.settings.setVisible(self.settings.isHidden())
        if self.settings.isHidden():
            self.capturing = None
        self.sync()

    def _capture(self, a):
        self.capturing = None if self.capturing == a else a
        self.sync()

    def set_key(self, name):
        """The key pressed while capturing (None: Esc - the action has no key)."""
        a, self.capturing = self.capturing, None
        if a:
            for other, k in list(self.keys.items()):
                if name and k == name:
                    self.keys[other] = ""               # a key belongs to one action
            self.keys[a] = name or ""
            self._save()
        self.sync()

    def _save(self):
        cfg = config.load()
        cfg["hotkeys"] = self.keys
        config.save(cfg)

    # --- the overlay
    def over_bar(self, gx, gy):
        """Is a screen point over the overlay's own controls (not the world)?"""
        at = self.geometry().topLeft()
        if self.menu.isVisible() and self.menu.geometry().contains(gx, gy):    # (a window: screen coordinates)
            return True
        return any(w.isVisible() and w.geometry().translated(at).contains(gx, gy)
                   for w in (self.bar, self.strip, self.settings, self.brush_panel))

    def click_through(self, on):
        from . import bg
        on = on or bg.BACKGROUND                # in the background never in Maxim's way
        hwnd = int(self.winId())
        st = user32.GetWindowLongW(hwnd, GWL_EXSTYLE) | WS_EX_LAYERED | WS_EX_NOACTIVATE
        st = st | WS_EX_TRANSPARENT if on else st & ~WS_EX_TRANSPARENT
        user32.SetWindowLongW(hwnd, GWL_EXSTYLE, st)

    def _rings(self, p):
        """Around every Go to spot of this place: its radius (solid) and its search area on the map (dashed)."""
        import math
        for pos, r, area in getattr(self.ed, "spot_rings", lambda: [])():
            for radius, dashed in ((r, False), (area, True)):
                if not radius or (dashed and abs(radius - r) < 0.01):
                    continue
                pen = QtGui.QPen(QtGui.QColor("#e3c65f" if not dashed else "#c8c8c8"), 2)
                if dashed:
                    pen.setStyle(QtCore.Qt.DashLine)
                p.setPen(pen)
                pts = [self.ed.cam.project([pos[0] + radius * math.cos(t * math.pi / 32),
                                            pos[1] + radius * math.sin(t * math.pi / 32), pos[2]],
                                           self.width(), self.height()) for t in range(65)]
                for a, b in zip(pts, pts[1:]):
                    if a and b:
                        p.drawLine(QtCore.QPointF(*a), QtCore.QPointF(*b))

    def _marker(self, p, pos, label, colour, size=9, lift=1.8):
        """A ring over a spot and its name - seen through walls and leaves (the overlay is drawn over the game)."""
        top = [pos[0], pos[1], pos[2] + lift]
        a = self.ed.cam.project(top, self.width(), self.height())
        if not a:
            return
        b = self.ed.cam.project(pos, self.width(), self.height())
        col = QtGui.QColor(colour)
        if b:
            pen = QtGui.QPen(col, 1.5)
            pen.setStyle(QtCore.Qt.DotLine)
            p.setPen(pen)
            p.drawLine(QtCore.QPointF(*a), QtCore.QPointF(*b))
        p.setPen(QtGui.QPen(QtGui.QColor(0, 0, 0, 180), 4))
        p.setBrush(QtCore.Qt.NoBrush)
        p.drawEllipse(QtCore.QPointF(*a), size, size)
        p.setPen(QtGui.QPen(col, 2))
        p.drawEllipse(QtCore.QPointF(*a), size, size)
        if label:
            f = p.font()
            f.setPixelSize(12)
            f.setBold(True)
            p.setFont(f)
            r = QtCore.QRectF(a[0] + size + 4, a[1] - 9, 260, 18)
            p.setPen(QtGui.QColor(0, 0, 0, 200))
            p.drawText(r.translated(1, 1), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter, label)
            p.setPen(col)
            p.drawText(r, QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter, label)

    def _markers(self, p):
        """Markers on (the bar, M): the place's objects - the ones the quest uses, or all - each a ring and its name."""
        mode = getattr(self.ed, "markers", "off")
        if mode == "off":
            return
        self._talk_cams(p)
        used = self.ed.quest_refs() if mode == "quest" else None
        for o in self.ed.project.places.get(self.ed.place, {}).get("objects", []):
            if o.get("trail"):
                continue
            ref = f"{self.ed.place}/{o.get('id')}"
            if used is not None and ref not in used:
                continue
            self._marker(p, o["pos"], o.get("display") or o.get("id") or "", "#e3c65f" if used is not None else
                         "#9fb0ff")

    def _routes(self, p):
        """The quest's ways (Follow, Patrol ...) as dashed lines over the world, the step's kind at the start - where
        a route runs is seen without opening its card (the one being drawn: the path tool draws it)."""
        tool = getattr(self.ed, "path_tool", None)
        shown = getattr(self.ed, "shown_steps", None)
        w, h = self.width(), self.height()
        nodes = shown() if callable(shown) else None
        for node in (nodes if isinstance(nodes, dict) else {}).values():
            for kind, a in (node.get("step") or {}).items():
                pts = (a or {}).get("path") if isinstance(a, dict) else None
                if not pts or len(pts) < 2 or (tool is not None and tool.points == pts):
                    continue
                scr = [self.ed.cam.project(q, w, h) for q in pts]
                pen = QtGui.QPen(QtGui.QColor(227, 198, 95, 170), 2)
                pen.setStyle(QtCore.Qt.DashLine)
                p.setPen(pen)
                for a1, b1 in zip(scr, scr[1:]):
                    if a1 and b1:
                        p.drawLine(QtCore.QPointF(*a1), QtCore.QPointF(*b1))
                p.setBrush(QtGui.QColor(227, 198, 95, 170))
                for s in scr:
                    if s:
                        p.drawEllipse(QtCore.QPointF(*s), 3, 3)
                if scr[0]:
                    f = p.font()
                    f.setPixelSize(11)
                    p.setFont(f)
                    p.setPen(QtGui.QColor("#e3c65f"))
                    p.drawText(QtCore.QPointF(scr[0][0] + 8, scr[0][1] - 6), kind.capitalize())

    def _talk_cams(self, p):
        """The talks' own cameras over the world: each a small camera looking its way with its name, a camera move a
        dashed line from where it starts; where the player stands in a talk a pin."""
        import math
        from . import dialogue as D
        quest = (getattr(self.ed, "project", None) and self.ed.project.meta.get("quest")) or {}
        w, h = self.width(), self.height()
        colour = QtGui.QColor("#6fb4e0")
        f = p.font()
        f.setPixelSize(11)
        p.setFont(f)
        for node in (quest.get("nodes") or {}).values():
            a = (node.get("step") or {}).get("talk")
            if not isinstance(a, dict):
                continue
            cams = a.get("cams") or {}
            spots = {}
            for name, c in cams.items():
                at = self.ed.cam.project(c["pos"], w, h)
                if not at:
                    continue
                spots[name] = at
                yaw, pitch = math.radians(float(c.get("yaw", 0))), math.radians(float(c.get("pitch", 0)))
                ahead = [c["pos"][0] - math.sin(yaw) * math.cos(pitch) * 1.5,
                         c["pos"][1] + math.cos(yaw) * math.cos(pitch) * 1.5, c["pos"][2] + math.sin(pitch) * 1.5]
                to = self.ed.cam.project(ahead, w, h)
                p.setPen(QtGui.QPen(colour, 2))
                if to:
                    p.drawLine(QtCore.QPointF(*at), QtCore.QPointF(*to))
                p.setBrush(QtGui.QColor(24, 24, 26, 220))
                p.drawRect(QtCore.QRectF(at[0] - 8, at[1] - 6, 16, 12))
                p.drawText(QtCore.QPointF(at[0] + 12, at[1] + 4), name)
            pen = QtGui.QPen(colour, 2)
            pen.setStyle(QtCore.Qt.DashLine)
            p.setPen(pen)
            for x in D.walk(a.get("dialogue") or []):
                one, two = str(x.get("glide") or ""), str(x.get("camera") or "")
                if one.startswith("cam:") and two.startswith("cam:") and one[4:] in spots and two[4:] in spots:
                    p.drawLine(QtCore.QPointF(*spots[one[4:]]), QtCore.QPointF(*spots[two[4:]]))
            spot = (a.get("spots") or {}).get("player")
            if spot:
                self._marker(p, spot["pos"], "Player", "#c4c8d0", size=7, lift=0.0)

    def _beacon(self, p):
        """'Go to': a pulsing ring and a column from above where the object is, for a few seconds."""
        import time
        b = getattr(self.ed, "beacon", None)
        if not b or time.time() > b["until"]:
            return
        pos = b["pos"]
        phase = (time.time() * 2.0) % 1.0
        sky = self.ed.cam.project([pos[0], pos[1], pos[2] + 25.0], self.width(), self.height())
        foot = self.ed.cam.project(pos, self.width(), self.height())
        if sky and foot:
            p.setPen(QtGui.QPen(QtGui.QColor(255, 210, 90, 150), 3))
            p.drawLine(QtCore.QPointF(*sky), QtCore.QPointF(*foot))
        if foot:
            for k in range(2):
                r = 10 + 30 * ((phase + k * 0.5) % 1.0)
                c = QtGui.QColor(255, 210, 90, int(230 * (1 - (r - 10) / 30)))
                p.setPen(QtGui.QPen(c, 3))
                p.drawEllipse(QtCore.QPointF(*foot), r, r * 0.55)
        self._marker(p, pos, b.get("label", ""), "#ffd25a", size=11, lift=0.0)
        QtCore.QTimer.singleShot(40, self.update)       # (it pulses: drawn again)

    def _frame(self, p, o, colour, label=None):
        """An object's box (picking: its real size, turned as it stands) drawn as a glowing frame, its name above."""
        from . import picking
        from .quest import is_actor
        box = picking.box_of(o, is_actor(o))
        roll, pitch, yaw = o.get("rot") or (0, 0, 0)
        w, h = self.width(), self.height()
        corners = []
        for cx in (box[0], box[3]):
            for cy in (box[1], box[4]):
                for cz in (box[2], box[5]):
                    x, y, z = picking.turn(cx, cy, cz, roll, pitch, yaw)
                    corners.append(self.ed.cam.project([o["pos"][0] + x, o["pos"][1] + y, o["pos"][2] + z], w, h))
        edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        col = QtGui.QColor(colour)
        glow = QtGui.QColor(col)
        glow.setAlpha(70)
        # a dark edge under it (seen on snow and sky too), the glow, the line
        for pen in (QtGui.QPen(QtGui.QColor(0, 0, 0, 120), 4), QtGui.QPen(glow, 8), QtGui.QPen(col, 1.8)):
            p.setPen(pen)
            for a, b in edges:
                if corners[a] and corners[b]:
                    p.drawLine(QtCore.QPointF(*corners[a]), QtCore.QPointF(*corners[b]))
        seen = [c for c in corners if c]
        if label and seen:
            top = min(seen, key=lambda c: c[1])
            f = p.font()
            f.setPixelSize(12)
            f.setBold(True)
            p.setFont(f)
            r = QtCore.QRectF(top[0] - 130, top[1] - 24, 260, 18)
            p.setPen(QtGui.QColor(0, 0, 0, 200))
            p.drawText(r.translated(1, 1), QtCore.Qt.AlignCenter, label)
            p.setPen(col)
            p.drawText(r, QtCore.Qt.AlignCenter, label)

    def _hover_and_selected(self, p):
        """Select mode: the selected object's gold frame; the one under the mouse a bright one with its name."""
        objs = self.ed.project.places.get(self.ed.place, {}).get("objects", [])
        sel = getattr(self.ed, "selected", None)
        chosen = None
        if sel is not None:
            # found where it stood when the drag began (the place file has it there until it is let go); drawn
            # where it is now - the frame moves with it
            drag = getattr(self.ed, "drag", None)
            key = drag.get("start") if isinstance(drag, dict) and drag.get("start") else sel
            i = self.ed.project.find_object(self.ed.place, key)
            chosen = objs[i] if i is not None and i < len(objs) else None
            if chosen is not None:
                self._frame(p, dict(chosen, pos=list(sel)), "#e3c65f")
        o = getattr(self, "hover", None)
        if o is not None and o is not chosen:
            name = (o.get("display") or o.get("id") or o["template"].rsplit("\\", 1)[-1].rsplit(".", 1)[0])
            self._frame(p, o, "#bfe3ff", name.replace("_", " "))

    def _draw_dock_preview(self):
        """A window dragged near an edge: the frame where it would dock."""
        r = self.dock_preview
        if r is None:
            return
        p = QtGui.QPainter(self)
        local = QtCore.QRect(r.topLeft() - self.geometry().topLeft(), r.size())
        p.fillRect(local, QtGui.QColor(255, 255, 255, 24))
        p.setPen(QtGui.QPen(QtGui.QColor("#c8c8c8"), 2))
        p.drawRect(local.adjusted(1, 1, -1, -1))
        p.end()

    def paintEvent(self, _):
        self._draw_dock_preview()
        if not self.ed.cam.ready:
            return
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        if getattr(self.ed, "editing", False):
            self._rings(p)
            self._routes(p)                     # the ways always (each step's eye says whether)
            self._markers(p)
            self._beacon(p)
            if getattr(self.ed, "mode", "") == "select":
                self._hover_and_selected(p)
            tool = getattr(self.ed, "path_tool", None)
            if tool is not None:
                tool.draw(p, self.width(), self.height())
            brush = getattr(self.ed, "terrain_tool", None)
            if brush is not None and getattr(self.ed, "mode", "") == "terrain":
                brush.draw(p, self.width(), self.height())
        g = self.gizmo
        if not g:
            return
        o = self.ed.cam.project(g["pos"], self.width(), self.height())
        if not o:
            return
        for axis, color in ((0, "#e5484d"), (1, "#46a758"), (2, "#3e8ed0")):
            end = list(g["pos"])
            end[axis] += GIZMO_M
            e = self.ed.cam.project(end, self.width(), self.height())
            if not e:
                continue
            p.setPen(QtGui.QPen(QtGui.QColor(color), 6 if g.get("hover") == axis else 3))
            p.drawLine(QtCore.QPointF(*o), QtCore.QPointF(*e))
            p.setBrush(QtGui.QColor(color))
            p.drawEllipse(QtCore.QPointF(*e), 7, 7)
        # the middle: a handle to move it freely over the surfaces (held and dragged)
        free = g.get("hover") == "free"
        p.setPen(QtGui.QPen(QtGui.QColor("#ffffff"), 2))
        p.setBrush(QtGui.QColor(255, 255, 255, 200 if free else 60))
        p.drawRect(QtCore.QRectF(o[0] - 7, o[1] - 7, 14, 14))
        # the rest of the selection (Shift+click): rings where they stand
        p.setPen(QtGui.QPen(QtGui.QColor(ON), 2))
        for gpos in self.ed.group:
            q = self.ed.cam.project(gpos, self.width(), self.height())
            if q:
                p.drawEllipse(QtCore.QPointF(*q), 8, 8)
