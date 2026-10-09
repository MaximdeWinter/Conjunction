"""The side panel of the editor HUD: catalog, places, build. A window of its own at the left edge of the game that never
takes the focus (the game would pause): a click into one of its fields starts typing - the editor's key router
(keyboard.py) hands the keys to it instead of the game - a click into the game or Esc ends it.
"""
import os
import threading

from PySide6 import QtCore, QtGui, QtWidgets

from .keyboard import TEXT_WIDGETS
from .tooltips import tab_tips, tip

WATCHED = {QtCore.QEvent.MouseMove, QtCore.QEvent.Enter, QtCore.QEvent.Hide,
           QtCore.QEvent.MouseButtonPress, QtCore.QEvent.MouseButtonRelease}   # what the panel's filter looks at

STYLE = """
#panel{background:rgba(24,24,26,235);border:1px solid #444;border-radius:0}
QLabel{color:#ccc;font:13px}
QLabel#title{color:#eee;font:bold 14px}
"""
INSPECTOR_W = 330
EDGE = 7                    # px at the panel's border that resize it
MIN_W, MIN_H = 420, 320


def plain_error(ex):
    """An exception in plain words: the tools' own messages as they are, a bug of conjunction said to be one."""
    if isinstance(ex, (RuntimeError, ValueError, OSError)) and str(ex):
        return str(ex)
    return f"conjunction hit a bug ({type(ex).__name__}: {ex}) - the log below has the details"


class Notice(QtWidgets.QWidget):
    """A message over the game that stays until closed (a failed build) or goes by itself (a build that worked).
    Hidden while another program is in front."""

    def __init__(self, panel):
        super().__init__(None, QtCore.Qt.FramelessWindowHint | QtCore.Qt.Tool | QtCore.Qt.WindowStaysOnTopHint)
        self.panel = panel
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground)
        self.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        frame = QtWidgets.QFrame(self)
        frame.setObjectName("notice")
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(frame)
        h = QtWidgets.QHBoxLayout(frame)
        h.setContentsMargins(12, 8, 8, 8)
        self.text = QtWidgets.QLabel()
        self.text.setWordWrap(True)
        self.text.setMaximumWidth(620)
        h.addWidget(self.text, 1)
        self.more = QtWidgets.QPushButton("Build tab")
        self.more.clicked.connect(self._open_build)
        tip(self.more, "pan.notice_more")
        h.addWidget(self.more)
        x = QtWidgets.QPushButton()
        x.setIcon(close_icon())
        x.setFixedSize(24, 22)
        x.clicked.connect(self.hide)
        tip(x, "pan.notice_close")
        h.addWidget(x)
        self.wanted = False
        self.timer = QtCore.QTimer(self, singleShot=True)
        self.timer.timeout.connect(self.dismiss)

    def say(self, text, error=False, ms=8000):
        from . import bg
        if bg.BACKGROUND:                       # nobody to read it (and a window over Maxim's own program): the log
            print(f"[notice] {text}", flush=True)
            return
        colour = "#e57a7a" if error else "#9fd38a"
        self.setStyleSheet(STYLE + f"#notice{{background:rgba(24,24,26,240);border:1px solid {colour};"
                                   f"border-radius:0}}QLabel{{color:{colour};font:bold 13px}}")
        self.text.setText(text)
        self.more.setVisible(error)
        self.adjustSize()
        self.wanted = True
        self.place()
        self.show()
        self.timer.stop()
        if not error:
            self.timer.start(ms)

    def dismiss(self):
        self.wanted = False
        self.hide()

    def place(self):
        from .cursor import client_rect_on_screen
        hwnd = getattr(self.panel.ed, "hwnd", None)
        if hwnd:
            x, y, w, _h = client_rect_on_screen(hwnd)
            self.move(x + (w - self.width()) // 2, y + 60)

    def follow(self, front):
        """Shown only while the game (or Conjunction) is in front."""
        if self.wanted and front and not self.isVisible():
            self.place()
            self.show()
        elif self.isVisible() and not front:
            self.hide()

    def _open_build(self):
        self.dismiss()
        p = self.panel
        if not (p.isVisible() and p.tabs.isVisible()):
            p.ed.toggle_panel()
        p.tabs.setCurrentIndex(3)

    def showEvent(self, ev):
        no_activate(self)
        super().showEvent(ev)


def no_activate(w):
    """A window of Conjunction that must never become the active one (the game would lose the focus and pause)."""
    import ctypes
    w.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
    hwnd = int(w.winId())
    user32 = ctypes.windll.user32
    user32.SetWindowLongW(hwnd, -20, user32.GetWindowLongW(hwnd, -20) | 0x08000000)   # WS_EX_NOACTIVATE


# the panel's own settings (the gear next to its X): (config key, label, on by default)
SETTINGS = [("catalog_stays", "Stays open while placing", False),
            ("catalog_back", "Back to the catalog after placing", True),
            ("see_through", "See-through while placing", True)]


_settings = {}                  # read once (the editor asks up to 60 times a second while placing)


def setting(key):
    """One of the panel's SETTINGS as it is now (config), else its default."""
    if key not in _settings:
        from . import config
        default = next(d for k, _l, d in SETTINGS if k == key)
        _settings[key] = bool(config.load().get(key, default))
    return _settings[key]


def gear_icon(color="#cfcfcf"):
    from .icons import icon
    return icon("settings", color)


def close_icon(color="#cfcfcf"):
    from .icons import icon
    return icon("x", color, 14)


class Panel(QtWidgets.QWidget):
    built = QtCore.Signal(str)          # log lines from the build thread (Qt: only the GUI thread touches widgets)
    exported = QtCore.Signal(str, str)  # the export thread's end: the file made (or ""), the error (or "")

    def __init__(self, editor):
        # not "stays on top": the editor keeps it right above the game (Editor.stack) - other programs can cover it
        super().__init__(None, QtCore.Qt.FramelessWindowHint | QtCore.Qt.Tool)
        self.ed = editor
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground)
        self.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        self.setAttribute(QtCore.Qt.WA_AlwaysShowToolTips)
        QtWidgets.QApplication.instance().installEventFilter(self)     # clicks into its fields start typing
        from . import theme
        theme.install(QtWidgets.QApplication.instance())     # the controls (theme.py)
        self.setStyleSheet(STYLE)
        # the first OpenGL widget (the inspector's 3D preview) in a shown window makes Qt recreate that window - a new
        # handle the editor no longer keeps above the game: the panel vanished at the first 3D click. A hidden one
        # from the start makes the window an OpenGL one before it is shown (checked: _scratch/gl_recreate_probe.py).
        from PySide6 import QtOpenGLWidgets
        self._gl_ready = QtOpenGLWidgets.QOpenGLWidget(self)
        self._gl_ready.setFixedSize(1, 1)
        self._gl_ready.hide()
        frame = QtWidgets.QFrame(self)
        frame.setObjectName("panel")
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(frame)
        frame.setMouseTracking(True)
        frame.installEventFilter(self)                  # its border resizes the window
        self.frame = frame
        col = QtWidgets.QVBoxLayout(frame)
        col.setContentsMargins(EDGE, 2, EDGE, EDGE)
        col.setSpacing(4)
        # the header: drag the window by it, close it on the right
        self.header = QtWidgets.QWidget()
        self.header.setFixedHeight(24)
        self.header.setCursor(QtCore.Qt.SizeAllCursor)
        self.header.installEventFilter(self)
        hl = QtWidgets.QHBoxLayout(self.header)
        hl.setContentsMargins(4, 0, 0, 0)
        self.head_title = QtWidgets.QLabel("Asset Browser")
        self.head_title.setStyleSheet("color:#9a9a9a;font:12px")
        self.head_title.hide()
        hl.addWidget(self.head_title)
        # the project: its name, a click its menu (rename, another one, a new one - the editor starts in the last
        # one worked on; Maxim 04.10.)
        from .inline_menu import attach
        self.b_project = QtWidgets.QToolButton()
        self.b_project.setObjectName("project")
        self.b_project.setCursor(QtCore.Qt.ArrowCursor)
        self.b_project.setStyleSheet("QToolButton#project{color:#cfcfcf;font:bold 12px;background:transparent;"
                                     "border:none;padding:0 4px}QToolButton#project:hover{color:#fff}")
        pm = QtWidgets.QMenu(self.b_project)
        pm.aboutToShow.connect(lambda: self._fill_project_menu(pm))
        attach(self.b_project, pm)
        tip(self.b_project, "pan.project")
        hl.addWidget(self.b_project)
        self.name_edit = QtWidgets.QLineEdit()
        self.name_edit.setFixedWidth(220)
        self.name_edit.hide()
        self.name_edit.returnPressed.connect(self._rename_done)
        self.name_edit.editingFinished.connect(self._rename_done)
        tip(self.name_edit, "pan.project_name")
        hl.addWidget(self.name_edit)
        self._show_project_name()
        hl.addStretch(1)
        # the gear: the panel's own settings (how it behaves while something is placed)
        self.b_settings = QtWidgets.QToolButton()
        self.b_settings.setObjectName("close")
        self.b_settings.setIcon(gear_icon())
        self.b_settings.setFixedSize(24, 20)
        self.b_settings.setCursor(QtCore.Qt.ArrowCursor)
        sm = QtWidgets.QMenu(self.b_settings)
        sm.aboutToShow.connect(lambda: self._fill_settings(sm))
        attach(self.b_settings, sm)
        tip(self.b_settings, "pan.settings")
        hl.addWidget(self.b_settings)
        self.b_close = QtWidgets.QPushButton()
        self.b_close.setObjectName("close")
        self.b_close.setIcon(close_icon())
        self.b_close.setFixedSize(24, 20)
        self.b_close.setCursor(QtCore.Qt.ArrowCursor)
        self.b_close.clicked.connect(self.close_panel)
        tip(self.b_close, "pan.close")
        hl.addWidget(self.b_close)
        col.addWidget(self.header)
        # left: the tabs (catalog, places, quest, build); right: the inspector for the chosen / selected thing
        lay = QtWidgets.QHBoxLayout()
        lay.setContentsMargins(0, 0, 0, 0)
        col.addLayout(lay, 1)
        self._drag = self._resize = None            # moving / resizing: (start mouse, start geometry, edges)
        from .dock import Docker
        self.docker = Docker(self, "panel", self.ed)   # snap to side: dragged to an edge of the game, it docks
        self.docker.extra = self._inspector_extra
        from . import dialogs
        dialogs.host = self                             # (file choosers open as Conjunction's windows)
        self.tabs = QtWidgets.QTabWidget()
        lay.addWidget(self.tabs, 1)
        self.catalog = None                 # the catalog view, made on first open (the database may need building)
        self.inspector = None
        self.windows = {}                   # the catalog's own windows (item choosers), by purpose
        self.notice = Notice(self)          # a failed build said over the game
        self.inspector_box = QtWidgets.QWidget()
        self.inspector_lay = QtWidgets.QVBoxLayout(self.inspector_box)
        self.inspector_lay.setContentsMargins(8, 0, 0, 0)
        self.inspector_box.setFixedWidth(INSPECTOR_W)
        self.inspector_box.hide()
        lay.addWidget(self.inspector_box)
        from .world_card import WorldCard          # an object the game placed, selected: its world changes
        self.world_card = WorldCard()
        self.world_card.hide()
        self.inspector_lay.addWidget(self.world_card)
        self.world_card.remove.connect(lambda: self.ed.world_remove())
        self.world_card.effect.connect(lambda name, on: self.ed.world_effect(name, on))
        self.world_card.look.connect(lambda name: self.ed.world_look(name))
        self.world_card.drop.connect(lambda cid: self.ed.world_drop(cid))
        self._catalog_tab()
        self._places_tab()
        self._quest_tab()
        self._build_tab()
        self.sync_kind()
        for title, factory in self.ed.plugin_panels():
            try:
                self.tabs.addTab(factory(self.ed), title)
            except Exception as ex:                     # noqa: BLE001 - a broken plugin panel is skipped
                print(f"[editor] plugin panel {title} skipped: {ex}", flush=True)
        self.built.connect(self._log)
        tab_tips(self.tabs.tabBar(), ["pan.tab.catalog", "pan.tab.places", "pan.tab.quest", "pan.tab.build"])
        # the header: the project (the tab under it already says which part)
        self.tabs.currentChanged.connect(self._tab_changed)
        self.inspector_wanted = False           # the inspector has something to show (it shows on the catalog tab)
        self._tab_changed(self.tabs.currentIndex())

    def showEvent(self, ev):
        # never the active window: the game pauses while it is not (clicks still arrive, keys come via keyboard.py)
        import ctypes
        hwnd = int(self.winId())
        user32 = ctypes.windll.user32
        user32.SetWindowLongW(hwnd, -20, user32.GetWindowLongW(hwnd, -20) | 0x08000000)   # WS_EX_NOACTIVATE
        super().showEvent(ev)

    def _focus_back(self):
        """The game in front again if a window of this process took it (a dropdown that just closed)."""
        import ctypes
        import ctypes.wintypes as wt
        user32 = ctypes.windll.user32
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(user32.GetForegroundWindow(), ctypes.byref(pid))
        game = getattr(self.ed, "hwnd", None)
        from . import bg
        if game and pid.value == os.getpid() and QtWidgets.QApplication.activePopupWidget() is None \
                and not bg.BACKGROUND:
            user32.SetForegroundWindow(game)

    # --- the catalog's windows (item_chooser.py): several at once, one per purpose
    def choose_item(self, then, title="Choose an item", key=None, keep_open=False, action="Choose item"):
        """An item window; `then(ref)` when one is taken (a game item's name or "own:<id>"). The same purpose
        (`key`) again brings its window up instead of a second one. -> the window (None: no catalog yet)."""
        self.load_catalog()
        if getattr(self, "assets", None) is None:
            return None
        from .item_chooser import CatalogWindow, ItemChooser
        key = key or title
        w = self.windows.get(key)
        if w is None:
            w = CatalogWindow(self, key, title)
            w.set_body(ItemChooser(self, w, then, keep_open, action))
            self.windows[key] = w
        else:
            w.body.then, w.body.keep_open, w.body.inspector.item_action = then, keep_open, action
            w.body.quest_items()                # (an item made since it was last open: Gucci Boots, 02.10.)
        w.show()
        w.raise_()
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None                    # the editor stacks the new one above the game
        return w

    def choose_loot(self, then, title="Random loot", key=None, current=None):
        """A loot window; `then(table name)` when one is taken."""
        self.load_catalog()
        if getattr(self, "assets", None) is None:
            return None
        from .item_chooser import CatalogWindow, LootChooser
        key = key or title
        w = self.windows.get(key)
        if w is None:
            w = CatalogWindow(self, key, title, kind="loot")
            w.set_body(LootChooser(self, w, then, current))
            self.windows[key] = w
        else:
            w.body.then = then
        w.show()
        w.raise_()
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None
        return w

    def choose_moment(self, then):
        """The window to hook a quest into one of the game's quests; `then({"quest", "name", "fact"})`."""
        from .item_chooser import CatalogWindow, MomentChooser
        key = "game quest moment"
        w = self.windows.get(key)
        if w is None:
            w = CatalogWindow(self, key, "After a moment of a game quest", kind="moments")
            w.set_body(MomentChooser(self, w, then))
            self.windows[key] = w
        else:
            w.body.then = then
        w.show()
        w.raise_()
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None
        return w

    def choose_point(self, then):
        """The window to put a quest into one of the game's quests; `then({"phase", "name", "block", "socket",
        "label"})`."""
        from .item_chooser import CatalogWindow, PointChooser
        key = "game quest point"
        w = self.windows.get(key)
        if w is None:
            w = CatalogWindow(self, key, "Inside a game quest", kind="points")
            w.set_body(PointChooser(self, w, then))
            self.windows[key] = w
        else:
            w.body.then = then
        w.show()
        w.raise_()
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None
        return w

    def choose_scene(self, then):
        """The window to replace one of the game's scenes; `then(swap)` (scene_swap.new_swap)."""
        from .item_chooser import CatalogWindow, SceneChooser
        key = "game scene"
        w = self.windows.get(key)
        if w is None:
            w = CatalogWindow(self, key, "Replace a scene of the game", kind="scenes")
            w.set_body(SceneChooser(self, w, then))
            self.windows[key] = w
        else:
            w.body.then = then
        w.show()
        w.raise_()
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None
        return w

    def choose_look(self, template, current, then, speaks=False):
        """The window to choose a person's look with pictures (look_chooser.py); `then(look)` when one is used.
        speaks: the person talks in the quest - only looks whose face can move."""
        from .item_chooser import CatalogWindow
        from .look_chooser import LookChooser
        key = "look"
        w = self.windows.get(key)
        if w is not None:
            w.close()
        w = CatalogWindow(self, key, "Choose a look", kind="looks")
        w.set_body(LookChooser(self, w, template, current, then, speaks=speaks))
        self.windows[key] = w
        w.show()
        w.raise_()
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None
        return w

    def open_window(self, key, title, make, kind=None):
        """Any of Conjunction's windows (the library, the bug report, a file chooser ...) as a window like the Asset
        Browser's: `make()` gives its body the first time; the same key again brings it up. -> the window."""
        from .item_chooser import CatalogWindow
        w = self.windows.get(key)
        if w is None:
            w = CatalogWindow(self, key, title, kind=kind or key)
            w.set_body(make())
            self.windows[key] = w
        w.show()
        w.raise_()
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None                    # the editor stacks it above the game
        return w

    def window_closed(self, w):
        if self.windows.get(w.key) is w:
            del self.windows[w.key]
        if hasattr(self.ed, "z_top"):
            self.ed.z_top = None
        self.ed.typing.stop()

    def delete_picked(self):
        """Delete with the mouse over the panel: what is picked on the Quest tab goes (nothing elsewhere)."""
        if self.tabs.isVisible() and self.tabs.currentWidget() is self.board:
            self.board.delete_picked()

    def cast_window(self, board):
        """'In this quest' (cast_view.py) in a window of the catalog's kind: over the game without pausing it, where
        it was left (Maxim 02.10.: windows not to be pushed around each time)."""
        from .cast_view import CastWindow
        from .item_chooser import CatalogWindow
        w = self.windows.get("cast")
        if w is None:
            from . import config
            w = CatalogWindow(self, "cast", "In this quest", kind="cast")
            w.set_body(CastWindow(board))
            if not config.load().get("catalog_windows", {}).get("cast"):
                # the first time: narrow, beside the panel (the catalog's size covered the whole panel - 03.10.)
                g = self.geometry()
                w.setGeometry(g.right() + 8, g.top(), 460, min(720, g.height()))
            self.windows["cast"] = w
        return w

    def open_windows(self):
        return [w for w in self.windows.values() if w.isVisible()]

    # --- a window of its own: moved by the header, resized at the border, the rectangle kept
    def close_panel(self):
        self.hide()
        self.ed.typing.stop()
        if hasattr(self.ed, "hud"):
            self.ed.hud.sync()

    def _edges(self, pos):
        """Which borders a point of the frame is on: (left, top, right, bottom) - docked, only its inner one."""
        r = self.frame.rect()
        e = (pos.x() < EDGE, pos.y() < EDGE, pos.x() > r.width() - EDGE, pos.y() > r.height() - EDGE)
        inner = self.docker.inner_edge()
        if inner is None:
            return e
        keep = ("left", "top", "right", "bottom").index(inner)
        return tuple(v if i == keep else False for i, v in enumerate(e))

    def _frame_mouse(self, obj, ev):
        t = ev.type()
        gp = ev.globalPosition().toPoint() if hasattr(ev, "globalPosition") else None
        if t == QtCore.QEvent.MouseButtonPress and ev.button() == QtCore.Qt.LeftButton:
            if obj is self.header:
                self._drag = (gp, self.geometry())
                return True
            e = self._edges(ev.position().toPoint())
            if any(e):
                self._resize = (gp, self.geometry(), e)
                return True
        elif t == QtCore.QEvent.MouseMove:
            if self._drag:
                start, g = self._drag
                if (gp - start).manhattanLength() < 4:
                    return True                     # (a click on the header: nothing moves, nothing undocks)
                was = self.docker.side
                if was is None:
                    self.move(g.topLeft() + gp - start)
                self.docker.drag_moved(gp)          # undocked at once when it was docked; the gold frame
                if was is not None:
                    self._drag = (gp, self.geometry())
                return True
            if self._resize:
                start, g, (el, et, er, eb) = self._resize
                d = gp - start
                r = QtCore.QRect(g)
                if el:
                    r.setLeft(min(g.left() + d.x(), g.right() - MIN_W))
                if er:
                    r.setRight(max(g.right() + d.x(), g.left() + MIN_W))
                if et:
                    r.setTop(min(g.top() + d.y(), g.bottom() - MIN_H))
                if eb:
                    r.setBottom(max(g.bottom() + d.y(), g.top() + MIN_H))
                self.setGeometry(r)
                return True
            if obj is self.frame:
                el, et, er, eb = self._edges(ev.position().toPoint())
                shape = (QtCore.Qt.SizeFDiagCursor if (el and et) or (er and eb) else
                         QtCore.Qt.SizeBDiagCursor if (er and et) or (el and eb) else
                         QtCore.Qt.SizeHorCursor if el or er else QtCore.Qt.SizeVerCursor if et or eb else None)
                if shape is None:
                    self.frame.unsetCursor()
                else:
                    self.frame.setCursor(shape)
        elif t == QtCore.QEvent.MouseButtonRelease and (self._drag or self._resize):
            dragged, self._drag, self._resize = self._drag, None, None
            if dragged and self.docker.drag_released(gp):
                return True                         # docked at a side
            if not dragged and self.docker.side is not None:
                self.docker.resized()               # docked and made wider / higher
                return True
            self._keep_rect()
            return True
        return False

    def _inspector_extra(self):
        """px the inspector adds beside the list (0 while it is hidden): the window grows by it, the list stays."""
        box = getattr(self, "inspector_box", None)
        tabs = getattr(self, "tabs", None)
        shown = box is not None and not box.isHidden() and tabs is not None and tabs.isVisible()
        return INSPECTOR_W + 8 if shown else 0

    def _rect_key(self):
        return "panel_rect_" + getattr(self.ed, "catalog_screen", "game")

    def _keep_rect(self):
        from . import config
        cfg = config.load()
        g = self.geometry()
        # kept without the inspector: shown or not, the list has the width the user gave it
        cfg[self._rect_key()] = [g.x(), g.y(), g.width() - self._inspector_extra(), g.height()]
        config.save(cfg)

    def eventFilter(self, obj, ev):
        if obj is getattr(self, "header", None) or obj is getattr(self, "frame", None):
            if self._frame_mouse(obj, ev):
                return True
        t = ev.type()
        if t not in WATCHED:                    # most events (a board rebuilt: tens of thousands) - out at once
            return False
        # the resize arrow was set on the frame at its border; inside, the frame gets no moves and every child took
        # the arrow over - it goes as soon as the mouse moves over anything inside. Not on the panel itself: a move
        # on the border goes on from the frame to it (the frame does not take it) and took the arrow away at once.
        if t in (QtCore.QEvent.MouseMove, QtCore.QEvent.Enter) and obj is not getattr(self, "frame", None) \
                and obj is not self and isinstance(obj, QtWidgets.QWidget) and obj.window() is self \
                and not (self._drag or self._resize) and self.frame.testAttribute(QtCore.Qt.WA_SetCursor):
            self.frame.unsetCursor()
        # a dropdown / menu is a window Qt brings to the front itself (no flag stops it, and taking the focus back
        # while it is open closes it - measured, _scratch/popup_focus_probe.py): when it closes, the game gets the
        # focus back (else one more click was needed)
        if t == QtCore.QEvent.Hide and isinstance(obj, QtWidgets.QWidget) and obj.isWindow() \
                and obj.windowType() == QtCore.Qt.Popup:
            QtCore.QTimer.singleShot(0, self._focus_back)
        if ev.type() == QtCore.QEvent.MouseButtonPress and isinstance(obj, QtWidgets.QWidget) \
                and obj.window() is getattr(self.ed, "hud", None) and hasattr(self.ed, "game_to_front"):
            self.ed.game_to_front()                 # the bar clicked while another program was in front
        if ev.type() == QtCore.QEvent.MouseButtonPress and isinstance(obj, QtWidgets.QWidget) \
                and (obj.window() is self or obj.window() in self.windows.values()):
            if hasattr(self.ed, "game_to_front"):
                self.ed.game_to_front()             # another program was in front: the game again
            top = obj.window()
            w = obj
            while w is not None and w is not top and not isinstance(w, TEXT_WIDGETS):
                w = w.parentWidget()
            if w is not None and w is not top:
                self.ed.typing.start(w)           # typing into this field (the game does not get the keys)
            else:
                self.ed.typing.stop(later=True)   # a button, a tab: the keys belong to the game again
        if ev.type() == QtCore.QEvent.MouseButtonRelease:
            self.ed.typing.flush()                # the field left with the press hears it now
        return False

    # --- catalog (catalog_view.py: grid with pictures, tabs, filters) and the inspector next to it
    def _catalog_tab(self):
        self.catalog_page = QtWidgets.QWidget()
        self.catalog_lay = QtWidgets.QVBoxLayout(self.catalog_page)
        self.catalog_lay.setContentsMargins(0, 0, 0, 0)
        self.catalog_hint = QtWidgets.QLabel("")
        self.catalog_hint.setWordWrap(True)
        self.catalog_lay.addWidget(self.catalog_hint)
        self.tabs.addTab(self.catalog_page, "Assets")

    @property
    def search(self):
        """The field that takes the keys when the panel opens."""
        return self.catalog.search if self.catalog else self.new_place

    def load_catalog(self):
        if self.catalog is not None:
            return
        from .assets import Assets
        if not Assets.ready():
            self.catalog_hint.setText("Building the catalog...")
            self._build_assets()
            return
        from .catalog_view import CatalogView, Inspector
        self.catalog_hint.hide()
        self.assets = Assets()
        self.catalog = CatalogView(self.ed, self.assets)
        self.catalog_lay.addWidget(self.catalog, 1)
        self.inspector = Inspector(self.ed, self.assets, self.catalog.pictures)
        self.inspector_lay.addWidget(self.inspector)
        self.catalog.current.connect(self._current)
        self.catalog.chosen.connect(self.pick)
        self.inspector.place.connect(self.pick)
        self.inspector.favourite.connect(self.catalog.toggle_favourite)
        self.inspector.overview.connect(self._overview)

    def _build_assets(self):
        if getattr(self, "_assets_building", False):
            return
        self._assets_building = True

        def work():
            from . import assets
            assets.build(log=lambda s: self.built.emit(s))
            self.built.emit("[assets] Ready")
        threading.Thread(target=work, daemon=True).start()

    def refresh(self):
        if self.catalog:
            self.catalog.refresh()

    def _current(self, e):
        """A catalog entry is chosen (click, arrow keys): the inspector shows it (the world gets it with Place)."""
        self.show_inspector(True)
        self.inspector.show_entry(e, favourite=e["key"] in self.catalog.favourites)

    def _overview(self, what, value):
        """A chip of the inspector: the catalog shows everything of that kind."""
        if not self.tabs.isVisible():
            self.tabs.show()
            self.ed.place_panel()
        self.tabs.setCurrentIndex(0)
        self.catalog.show_only(what, value)

    def chooser(self):
        """The quest board's 'Place new ...' catalog, when it is what the panel shows (it has the inspector too)."""
        board = getattr(self, "board", None)
        c = getattr(board, "chooser", None)
        return c if c is not None and not self.tabs.isHidden() and self.tabs.currentWidget() is board else None

    def show_world_card(self, sel):
        """The world card instead of the inspector (sel: the selected object's report) - None: it goes."""
        if sel is None:
            if self.world_card.isVisible():
                self.world_card.hide()
                if self.inspector is None or self.inspector.isHidden():
                    self.show_inspector(False)
            return
        if self.inspector is not None:
            self.inspector.hide()
        self.world_card.show_object(sel, self.ed.project.path)
        self.world_card.show()
        self.show_inspector(True)

    def show_inspector(self, on):
        """The inspector belongs to the catalog (and to the world's selection with the tabs away) and to the quest
        board's 'Place new ...' catalog: on the other tabs it waits until the catalog is shown again."""
        self.inspector_wanted = on
        if on and not self.tabs.isHidden() and self.tabs.currentIndex() != 0 and self.chooser() is None:
            on = False
        if on == self.inspector_box.isHidden():
            self.inspector_box.setVisible(on)
            self.ed.place_panel()

    def _tab_changed(self, i):
        if getattr(self, "_grouping", False):
            return
        # two panels in one (02.10.): the catalog alone when placing (Place), the project's tabs when working on the
        # quest (Quest) - whichever tab is asked for brings its own (code anywhere sets a tab; the rest follows)
        self._tab_group(i)
        if self.tabs.widget(i) is getattr(self, "_build_tab_widget", None):
            self.needs.refresh()
        wanted = self.inspector_wanted
        self.show_inspector(wanted)
        self.inspector_wanted = wanted

    def _tab_group(self, i):
        """The catalog alone, or the project's tabs - the tab asked for stays (hiding the others made the bar pick
        another one: it is set again; the calls this makes in between are let through)."""
        if getattr(self, "_grouping", False):
            return
        self._grouping = True
        try:
            place = i == 0
            # a place mod has no Quest tab (sync_kind) - showing the project's tabs must not bring it back (night
            # test 07.10.: the panel of a place mod showed Quest)
            no_quest = self.ed.project.meta.get("kind") == "place"
            for k in range(self.tabs.count()):
                if (k == 0) == place and not (no_quest and self.tabs.widget(k) is self.board):
                    self.tabs.setTabVisible(k, True)
            for k in range(self.tabs.count()):
                if (k == 0) != place:
                    self.tabs.setTabVisible(k, False)
            if self.tabs.currentIndex() != i:
                self.tabs.setCurrentIndex(i)
        finally:
            self._grouping = False
        self.tabs.tabBar().setVisible(not place)
        self.head_title.setVisible(place)
        self.b_project.setVisible(not place and self.name_edit.isHidden())

    # --- the project (the header's menu)
    def _show_project_name(self):
        p = self.ed.project
        self.b_project.setText(f"{p.meta.get('name') or p.id}  ▾")

    def _fill_project_menu(self, menu):
        menu.clear()
        menu.addAction("Rename", self._rename_start)
        menu.addAction("New project", self._new_project)
        menu.addAction("Open project...", self.ed.open_projects)
        menu.addSeparator()
        menu.addAction("Library...", self._quests_to_play)

    def _rename_start(self):
        self.b_project.hide()
        self.name_edit.setText(str(self.ed.project.meta.get("name") or ""))
        self.name_edit.show()
        self.name_edit.selectAll()
        self.ed.typing.start(self.name_edit)

    def _rename_done(self):
        if self.name_edit.isHidden():
            return
        from .project import rename
        text = self.name_edit.text()
        self.name_edit.hide()
        self.ed.typing.stop()
        try:
            rename(self.ed.project, text)
        except OSError as ex:                       # (the folder in use: the name changes, the folder stays)
            print(f"[panel] rename: {ex}", flush=True)
        self._show_project_name()
        self.b_project.setVisible(not self.head_title.isVisible())
        self.ed.hud.sync()

    def _new_project(self):
        from .project import new_project
        self.ed.switch_project(new_project("Untitled"))

    def _quests_to_play(self):
        from .library_view import LibraryWindow
        self.open_window("library", "Library", LibraryWindow)

    def _fill_settings(self, menu):
        menu.clear()
        for key, label, _d in SETTINGS:
            # on / off each by itself: a tick in front, as in the bar's menus (07.10.: a lit entry read as "chosen")
            act = menu.addAction(("✓  " if setting(key) else "     ") + label)
            act.triggered.connect(lambda _c=False, key=key: self._toggle_setting(key))

    def _toggle_setting(self, key):
        from . import config
        cfg = config.load()
        cfg[key] = _settings[key] = not setting(key)
        config.save(cfg)

    def pick(self, e):
        """Take it: templates go to place mode (back to the game); items are for inventories (inspector). The panel
        goes out of the way unless it stays open while placing (the gear); after placing, the catalog comes back."""
        if not e or e["type"] != "template":
            return
        c = self.chooser()
        if c is not None:                   # a quest card waits for it ('Place new ...'): the card's button takes it
            c.entry = e
            c._take()
            return
        if e.get("members"):                # a folder: a random variant, a new one each time it is placed
            import random
            self.catalog.remember(e)
            self.ed.set_template(random.choice(e["members"]), variants=e["members"])
            self.ed.catalog_pick = True
            if not setting("catalog_stays"):
                self.close_panel()
            self.ed.focus_game()
            return
        chooser = self.chooser()
        if chooser is not None:             # the quest board's 'Place new ...': its Place
            chooser._current(e)
            chooser._take()
            return
        self.catalog.remember(e)
        self.ed.set_template(e["path"], look=e.get("look"))     # now it follows the cursor in the world
        self.ed.catalog_pick = True         # placed or given up: back to the catalog (Editor.back_to_catalog)
        if not setting("catalog_stays"):
            self.close_panel()              # out of the way: place it
        self.ed.focus_game()

    # --- places
    def _places_tab(self):
        """The project's locations as a tree: each with its objects. Click: select it (its location becomes the one
        edited); double click: the camera goes there."""
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(0, 6, 0, 0)
        v.setSpacing(6)
        self.places = QtWidgets.QTreeWidget()
        self.places.setObjectName("places")
        self.places.setHeaderHidden(True)
        self.places.setColumnCount(2)
        self.places.setRootIsDecorated(True)
        self.places.setIndentation(14)
        self.places.setUniformRowHeights(True)
        self.places.setStyleSheet("QTreeWidget#places{background:#1d1d20;border:1px solid #3a3a3e;font:13px}"
                                  "QTreeWidget#places::item{padding:3px 2px}"
                                  "QTreeWidget#places::item:selected{background:#4b4b50;color:#fff}")
        self.places.header().setStretchLastSection(True)
        self.places.itemClicked.connect(self._places_clicked)
        self.places.itemDoubleClicked.connect(self._places_jump)
        tip(self.places, "pan.places")
        self.objects = self.places                  # (one tree now: the objects are its rows)
        v.addWidget(self.places, 1)
        h = QtWidgets.QHBoxLayout()
        h.setSpacing(4)
        self.new_place = QtWidgets.QLineEdit()
        self.new_place.setPlaceholderText("New location")
        self.new_place.returnPressed.connect(self._add_place)
        tip(self.new_place, "pan.new_place")
        add = tip(QtWidgets.QPushButton("Add"), "pan.add_place")
        add.clicked.connect(self._add_place)
        h.addWidget(self.new_place, 1)
        h.addWidget(add)
        hide = tip(QtWidgets.QPushButton("Hide area"), "pan.hide_area")
        hide.clicked.connect(lambda: (self.ed.hide_area(None), self.ed.focus_game()))
        h.addWidget(hide)
        v.addLayout(h)
        # a hide area (envhide.py): what the game does not draw inside its outline
        self.area_box = QtWidgets.QFrame()
        self.area_box.setObjectName("areabox")
        self.area_box.setStyleSheet("QFrame#areabox{border:1px solid #3a3a3e;background:#202023}")
        ag = QtWidgets.QGridLayout(self.area_box)
        ag.setContentsMargins(8, 6, 8, 8)
        self.area_label = QtWidgets.QLabel("")
        self.area_label.setStyleSheet("color:#9a9a9a;font:11px")
        self.area_label.setWordWrap(True)
        ag.addWidget(self.area_label, 0, 0, 1, 3)
        self.area_flags = {}
        for k, (key, text) in enumerate((("foliage", "Foliage"), ("terrain", "Terrain"), ("water", "Water"))):
            cb = tip(QtWidgets.QCheckBox(text), f"area.{key}")
            cb.toggled.connect(lambda on, key=key: self._area_set(**{key: on}))
            self.area_flags[key] = cb
            ag.addWidget(cb, 1, k)
        from .fields import with_unit
        self.area_height = QtWidgets.QDoubleSpinBox()
        self.area_height.setLocale(QtCore.QLocale.c())
        self.area_height.setRange(1, 500)
        self.area_height.setDecimals(0)
        self.area_height.setButtonSymbols(QtWidgets.QAbstractSpinBox.NoButtons)
        self.area_height.editingFinished.connect(lambda: self._area_set(height=float(self.area_height.value())))
        tip(self.area_height, "area.height")
        ag.addWidget(with_unit(self.area_height, before="height", after="m"), 2, 0, 1, 2)
        outline = tip(QtWidgets.QPushButton("Outline"), "area.outline")
        outline.clicked.connect(lambda: self._area_at and (self.ed.hide_area(self._area_at[1]), self.ed.focus_game()))
        ag.addWidget(outline, 2, 2)
        self._area_at = None
        self.area_box.hide()
        v.addWidget(self.area_box)
        # the selected object: its name (quest steps use it) and exact position and rotation
        self.sel_box = QtWidgets.QFrame()
        self.sel_box.setObjectName("selbox")
        self.sel_box.setStyleSheet("QFrame#selbox{border:1px solid #3a3a3e;background:#202023}")
        form = QtWidgets.QGridLayout(self.sel_box)
        form.setContentsMargins(8, 6, 8, 8)
        form.setHorizontalSpacing(6)
        form.setVerticalSpacing(4)
        self.sel_label = QtWidgets.QLabel("")
        self.sel_label.setStyleSheet("color:#9a9a9a;font:11px")
        self.sel_label.setWordWrap(True)
        form.addWidget(self.sel_label, 0, 0, 1, 4)
        self.sel_id = QtWidgets.QLineEdit()
        self.sel_id.setPlaceholderText("name")
        self.sel_id.editingFinished.connect(self._rename)
        tip(self.sel_id, "obj.name")
        form.addWidget(self.sel_id, 1, 0, 1, 4)
        self.sel_num = []
        from .fields import with_unit
        for i, name in enumerate(["x", "y", "z", "roll", "pitch", "yaw"]):
            box = QtWidgets.QDoubleSpinBox()
            box.setLocale(QtCore.QLocale.c())       # 12.5, not 12,5
            box.setRange(-100000, 100000)
            box.setDecimals(2 if i < 3 else 1)
            box.setSingleStep(0.1 if i < 3 else 5.0)
            box.setButtonSymbols(QtWidgets.QAbstractSpinBox.NoButtons)
            self.sel_num.append(box)
            form.addWidget(with_unit(box, before=name), 2 + i // 3, i % 3)
        apply = tip(QtWidgets.QPushButton("Apply"), "pan.apply")
        apply.clicked.connect(self._apply_numbers)
        form.addWidget(apply, 2, 3, 2, 1)
        self.sel_box.hide()
        v.addWidget(self.sel_box)
        self.tabs.addTab(w, "Places")

    def _selected_index(self):
        return self.ed.project.find_object(self.ed.place, self.ed.selected)

    def _places_clicked(self, item, _col=0):
        place, index = item.data(0, QtCore.Qt.UserRole) or (None, None)
        if place is None:
            return
        if place != self.ed.place:
            self.ed.set_place(place)
        if index is not None:
            o = self.ed.project.places.get(place, {}).get("objects", [])[index]
            if o.get("envhide"):                # nothing stands there to select: its settings, its outline shown
                self.show_area(place, index)
                self.ed.hide_area(index)
                return
            self.show_area(None, None)
            self.ed.set_mode("select")
            self.ed.select_at(o["pos"])

    def _places_jump(self, item, _col=0):
        place, index = item.data(0, QtCore.Qt.UserRole) or (None, None)
        if place is not None and index is not None:
            self.ed.jump_to(place, index)

    def sync_selected(self):
        self.sync_places()
        i = self._selected_index()
        objs = self.ed.project.places.get(self.ed.place, {}).get("objects", [])
        if i is None or i >= len(objs):
            self.sel_box.hide()
            return
        o = objs[i]
        self.sel_box.show()
        self.sel_label.setText(o["template"])
        self.sel_id.setText(o.get("id", ""))
        for box, val in zip(self.sel_num, list(o["pos"]) + list(o["rot"])):
            box.blockSignals(True)
            box.setValue(val)
            box.blockSignals(False)

    def show_area(self, place, index):
        """The hide area's settings under the tree (None: hidden)."""
        objs = self.ed.project.places.get(place, {}).get("objects", []) if place else []
        if index is None or index >= len(objs) or not objs[index].get("envhide"):
            self._area_at = None
            self.area_box.hide()
            return
        self._area_at = (place, index)
        spec = objs[index]["envhide"]
        self.area_label.setText(f"Hide area {objs[index].get('id', '')}, {len(spec.get('points', []))} points "
                                f"(visible after Build & Play)")
        for key, cb in self.area_flags.items():
            cb.blockSignals(True)
            cb.setChecked(bool(spec.get(key, key == "foliage")))
            cb.blockSignals(False)
        self.area_height.blockSignals(True)
        self.area_height.setValue(float(spec.get("height", 20.0)))
        self.area_height.blockSignals(False)
        self.area_box.show()

    def _area_set(self, **flags):
        if self._area_at:
            self.ed.set_area(*self._area_at, **flags)

    def _rename(self):
        i = self._selected_index()
        from .project import ascii_id
        name = ascii_id(self.sel_id.text())
        if i is not None and name:
            self.ed.project.name_object(self.ed.place, i, name)
            self.sync_selected()

    def _apply_numbers(self):
        vals = [b.value() for b in self.sel_num]
        self.ed.set_selected_transform(vals[:3], vals[3:])

    def _add_place(self):
        from .project import ascii_id
        name = ascii_id(self.new_place.text())
        if name:
            self.new_place.clear()
            self.ed.set_place(name)
            self.ed.focus_game()

    def sync_places(self):
        """The tree anew: the location being edited open and marked, its selected object marked."""
        import os
        tree = self.places
        scroll = tree.verticalScrollBar().value()
        tree.blockSignals(True)
        tree.clear()
        names = sorted(set(self.ed.project.places) | {self.ed.place})
        sel = self._selected_index()
        bold = QtGui.QFont()
        bold.setBold(True)
        for n in names:
            p = self.ed.project.places.get(n, {})
            objs = p.get("objects", [])
            top = QtWidgets.QTreeWidgetItem([n, f"{p.get('world') or '-'}  ·  {len(objs)}"])
            top.setData(0, QtCore.Qt.UserRole, (n, None))
            top.setFont(0, bold)
            top.setForeground(1, QtGui.QColor("#8a8a8a"))
            if n == self.ed.place:
                top.setForeground(0, QtGui.QColor("#ffffff"))
            tree.addTopLevelItem(top)
            for k, o in enumerate(objs):
                if o.get("marker"):
                    label = o.get("id") or "spot"
                else:
                    label = o.get("display") or o.get("id") or "-"
                it = QtWidgets.QTreeWidgetItem([label, os.path.splitext(os.path.basename(o["template"]))[0]])
                it.setData(0, QtCore.Qt.UserRole, (n, k))
                it.setForeground(1, QtGui.QColor("#8a8a8a"))
                top.addChild(it)
                if n == self.ed.place and k == sel:
                    it.setSelected(True)
            top.setExpanded(n == self.ed.place)
        tree.resizeColumnToContents(0)
        tree.blockSignals(False)
        tree.verticalScrollBar().setValue(scroll)

    # --- quest
    def _quest_tab(self):
        from .questboard import QuestBoard
        self.board = QuestBoard(self.ed, lambda: getattr(self, "assets", None))
        self.board.panel = self                 # (its windows: the catalog's kind - over the game, kept in place)
        self.tabs.addTab(self.board, "Quest")

    def sync_quest(self):
        self.board.sync()

    def sync_kind(self):
        """A place mod (project.yml kind: place - Maxim 06.10.: "ein neues Haus für Geralt ist eine extra Mod, keine
        Quest") has no Quest tab; its export is named for it."""
        place = self.ed.project.meta.get("kind") == "place"
        i = self.tabs.indexOf(self.board)
        if place and self.tabs.currentIndex() == i:
            self.tabs.setCurrentIndex(i - 1)            # (the Places tab)
        self.tabs.setTabVisible(i, not place)
        self.b_export.setText("Export place mod" if place else "Export quest file")

    # --- build
    def _build_tab(self):
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(0, 6, 0, 0)
        self.status = QtWidgets.QLabel("")
        self.status.setWordWrap(True)
        self.status.hide()
        v.addWidget(self.status)
        self.b_play = tip(QtWidgets.QPushButton("Build && Play"), "pan.play")
        self.b_play.clicked.connect(lambda: self._build(True))
        self.b_check = tip(QtWidgets.QPushButton("Check"), "pan.check")
        self.b_check.clicked.connect(lambda: self._build(False))
        v.addWidget(self.b_play)
        v.addWidget(self.b_check)
        # share it: the built quest as one file anyone with Conjunction plays (packaging.py); above it the mods it
        # takes things from - what its manifest will name (export_view.py)
        from .export_view import NeedsBox
        self.needs = NeedsBox(self)
        v.addWidget(self.needs)
        self._build_tab_widget = w
        exp = QtWidgets.QHBoxLayout()
        self.b_export = tip(QtWidgets.QPushButton("Export quest file"), "pan.export")
        self.b_export.clicked.connect(self._export)
        self.exported.connect(self._export_done)
        self.c_source = tip(QtWidgets.QCheckBox("Include the project"), "pan.export_source")
        exp.addWidget(self.b_export, 1)
        exp.addWidget(self.c_source)
        v.addLayout(exp)
        from . import meshlib
        self.b_meshes = tip(QtWidgets.QPushButton("Build mesh library"), "pan.meshes")
        # (built before decals were in it: again, for them)
        self.b_meshes.setEnabled(not os.path.exists(meshlib.INDEX) or not os.path.exists(meshlib.DECAL_INDEX))
        self.b_meshes.clicked.connect(self._meshlib)
        v.addWidget(self.b_meshes)
        from . import foliage
        self.b_foliage = tip(QtWidgets.QPushButton("Build foliage library"), "pan.foliage")
        self.b_foliage.setEnabled(not os.path.exists(foliage.INDEX))
        self.b_foliage.clicked.connect(self._foliagelib)
        v.addWidget(self.b_foliage)
        b_pack = tip(QtWidgets.QPushButton("Content pack"), "lib.packs")      # (furniture, decals, items: a pack)
        b_pack.clicked.connect(self._pack_maker)
        v.addWidget(b_pack)
        self.log = QtWidgets.QPlainTextEdit()
        self.log.setReadOnly(True)
        v.addWidget(self.log, 1)
        self.tabs.addTab(w, "Build")

    def test_from(self, spec):
        """Build & Play a test that starts the quest at a step (the Build tab shows how it goes)."""
        self.tabs.setCurrentIndex(3)
        self._build(True, spec)

    def _build(self, play, test_from=None):
        if getattr(self, "building", False):
            # one at a time (03.10.: a 'Play from here' during a Build & Play - two builds into one game at once)
            self._status("A build is running - wait for it", "#e3c65f")
            return
        self.building = True
        self.b_play.setEnabled(False)
        self.b_check.setEnabled(False)
        self.log.clear()
        if play:
            self._build_window()
        self._status("Building ... about 2 minutes" if play else "Checking ...", "#c8c8c8")
        import time as _t
        path = os.path.join(self.ed.project.path, "build", "last_play.log")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        kept = open(path, "w", encoding="utf-8")        # what happened, to read afterwards (the window closes)

        def log(line):
            try:
                kept.write(f"{_t.strftime('%H:%M:%S')} {line}\n")
                kept.flush()
            except (OSError, ValueError):
                pass
            self.built.emit(line)

        def work():
            import traceback
            try:
                log(f"[play] {'Build & Play' if play else 'check'}" + (f" from {test_from}" if test_from else ""))
                self.ed.build_and_play(log, play, test_from=test_from)
                log("[done]" + ("" if play else " (no errors)"))
            except Exception as ex:                     # noqa: BLE001 - shown to the user
                log(traceback.format_exc().rstrip())
                log(f"[failed] {plain_error(ex)}")
            finally:
                kept.close()
                self.building = False
            self.built.emit("\0")
        threading.Thread(target=work, daemon=True).start()

    def _build_window(self):
        """Build & Play: Conjunction's windows away, the build window up (build_view.py) - back when it closes."""
        from . import bg
        if bg.BACKGROUND:
            return
        from .build_view import BuildWindow
        hud = getattr(self.ed, "hud", None)
        keep = {id(w) for w in ([hud] if hud is not None else [])}
        hidden = [w for w in QtWidgets.QApplication.topLevelWidgets()
                  if w.isVisible() and id(w) not in keep and w.isWindow()
                  and not w.testAttribute(QtCore.Qt.WA_TransparentForMouseEvents)
                  and w.windowType() not in (QtCore.Qt.ToolTip, QtCore.Qt.Popup)]
        hidden = [w for w in hidden if w is self or w.windowTitle() or isinstance(w, QtWidgets.QDialog)]

        def back():
            self.built.disconnect(win.line)
            failed = win.stage.text().startswith("Failed")
            if failed and not self.ed.editing:          # the build did not make it: back to editing as it was
                self.ed.set_editing(True)
            for w in hidden:
                if w is self and not self.ed.editing:   # playing now (07.10.: the panel came back over the game)
                    continue
                try:
                    w.show()
                except RuntimeError:                    # (a window closed meanwhile)
                    pass
            self.bw = None
        for w in hidden:
            w.hide()
        # the curtain over the game's picture right away (07.10.: first play mode, then a window behind the game)
        win = BuildWindow(self.ed.project.meta.get("name") or self.ed.project.id, back, curtain=True)
        win.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        from .build_view import card_rect
        from .cursor import client_rect_on_screen
        hwnd = getattr(self.ed, "hwnd", 0)
        area = QtCore.QRect(*client_rect_on_screen(hwnd)) if hwnd else             QtGui.QGuiApplication.primaryScreen().availableGeometry()
        win.setGeometry(card_rect(area))                # (a card over the game, not the whole screen - 07.10.)
        self.built.connect(win.line)
        win.show()
        win._follow_game()
        self.bw = win

    def _export(self):
        """In a thread (06.10.: the window did not answer while the quest was built again under its own id)."""
        from . import packaging
        from .export_window import ask
        self.needs.refresh()
        # what the page and the journal will say, shown and changeable first (Maxim 08.10.)
        values = ask(self.ed.project, self.c_source.isChecked(), self)
        if values is None:
            return
        self.c_source.setChecked(values["include_source"])
        chosen = values["project"]                      # any project (Maxim 08.10.), the open one by default
        mine = os.path.normcase(os.path.abspath(chosen.path)) == os.path.normcase(os.path.abspath(self.ed.project.path))
        packs = self.needs.packs if mine else None      # (another one: the mods it uses are found by the export)
        source, rebuild = values["include_source"], values["rebuild"]
        self.b_export.setEnabled(False)
        self._status("Exporting...", "#cccccc")
        self._export_window(chosen)

        def work():
            try:
                path = packaging.export(chosen.path, include_source=source, log=self.built.emit, packs=packs,
                                        rebuild=rebuild)
                self.built.emit("[done] exported")
                self.exported.emit(path, "")
            except Exception as ex:                     # noqa: BLE001 - shown to the user
                self.built.emit(f"[failed] {ex}")
                self.exported.emit("", str(ex))
        threading.Thread(target=work, daemon=True).start()

    def _export_window(self, project=None):
        """The export's progress (Maxim 06.10.): build_view's window - a bar, what is being done, the lines."""
        project = project or self.ed.project
        from . import bg
        if bg.BACKGROUND:
            return
        from .build_view import EXPORT_STAGES, BuildWindow

        def back():
            try:
                self.built.disconnect(win.line)
            except (RuntimeError, TypeError):
                pass
        win = BuildWindow(project.meta.get("name") or project.id, back, stages=EXPORT_STAGES,
                          verb="exporting", done_text="Exported")
        win.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        g = QtGui.QGuiApplication.primaryScreen().availableGeometry()
        win.move(g.center() - win.rect().center())
        self.built.connect(win.line)
        win.show()
        self.ew = win

    def _export_done(self, path, error):
        self.b_export.setEnabled(True)
        if error:
            self._status(f"Not exported: {error}", "#e57a7a")
            return
        self._status(f"Exported: {os.path.dirname(path)}", "#9fd38a")
        from PySide6 import QtGui
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(os.path.dirname(path)))

    def _pack_maker(self):
        from .pack_view import PackMakerWindow
        self.open_window("packs", "Content pack", PackMakerWindow)

    def _meshlib(self):
        from . import meshlib
        self.b_meshes.setEnabled(False)
        self.log.clear()

        def work():
            try:
                meshlib.build(log=self.built.emit)
                self.built.emit("[done] mesh library - active after the next game start")
                self.catalog = None                     # reload with the meshes the next time it opens
            except Exception as ex:                     # noqa: BLE001
                self.built.emit(f"[failed] {ex}")
        threading.Thread(target=work, daemon=True).start()

    def _foliagelib(self):
        from . import foliage
        self.b_foliage.setEnabled(False)
        self.log.clear()

        def work():
            try:
                foliage.build(log=self.built.emit)
                self.built.emit("[done] Foliage library (active after the next game start)")
                self.catalog = None                     # reload with the trees the next time it opens
            except Exception as ex:                     # noqa: BLE001 (the game holds the old library: close it)
                self.built.emit(f"[failed] {ex}")
        threading.Thread(target=work, daemon=True).start()

    def _log(self, line):
        if line == "\0":
            self.b_play.setEnabled(True)
            self.b_check.setEnabled(True)
            if getattr(self.ed, "editing", True) is False and self.isVisible():
                self.hide()                     # playing after Build & Play: the panel goes with the editor (07.10.)
            return
        if line.startswith("[failed]"):
            reason = line[9:].strip()
            self._status(f"The build failed: {reason}", "#e57a7a")
            self.notice.say(f"{self.ed.project.meta.get('name', 'The quest')} was not built: {reason}", error=True)
        elif line.startswith(("[check] played: ", "[check] stuck: ")):
            self._played = (line.startswith("[check] played"), line.split(": ", 1)[1])
        elif line.startswith("[done]"):
            built = "checked - radish finds nothing wrong" if "no errors" in line else "built and installed"
            played = getattr(self, "_played", None)
            self._played = None
            if played and "no errors" in line:
                if not played[0]:                       # radish is happy, but a way stops: say where
                    self._status(f"{self.ed.project.meta.get('name', 'The quest')}: checked - but {played[1]}",
                                 "#e3c65f")
                    self.log.appendPlainText(line)
                    return
                built += f", {played[1]}"
            meta = self.ed.project.meta
            changed = len(meta.get("swaps") or {}) + bool(((meta.get("quest") or {}).get("inside_game") or {})
                                                            .get("phase"))
            if changed:                         # the game's own files: a mod of their own, and a word about saves
                built += (f". It changes {changed} of the game's files (Mods\\moddlc{self.ed.project.id} after a build) "
                          "- saves made inside those quests may not fit")
            self._status(f"{meta.get('name', 'The quest')}: {built}", "#9fd38a")
            if "no errors" not in line:
                self.notice.say(f"{self.ed.project.meta.get('name', 'The quest')} is built and in the game now")
        if line.startswith("[assets]"):
            self.catalog_hint.setText("Building the catalog... " + line[9:])
            if line == "[assets] ready":
                self._assets_building = False
                self.load_catalog()
            return
        self.log.appendPlainText(line)

    def _status(self, text, colour):
        self.status.setText(text)
        self.status.setStyleSheet(f"color:{colour};font:bold 13px;padding:4px 0")
        self.status.show()

    # --- placement next to the game window
    def place_at(self, x, y, w, h):
        """Over the game (compact, at its left edge) or large on the second screen (editor option
        "catalog_screen"); only the inspector when the tabs are closed (an object selected in the world)."""
        if self.docker.side is not None and getattr(self.ed, "catalog_screen", "game") != "second" and                 self.docker.apply():
            return                                      # docked at a side of the game
        other = self._second_screen(x, y, w, h) if getattr(self.ed, "catalog_screen", "game") == "second" else None
        insp_w = INSPECTOR_W + 8 if not self.inspector_box.isHidden() else 0
        if self.tabs.isVisible():
            from . import config
            kept = config.load().get(self._rect_key())
            from . import bg
            if bg.BACKGROUND:                           # (Maxim's screen positions mean nothing to the hidden game)
                kept = None
            if kept and any(sc.geometry().intersects(QtCore.QRect(*kept)) for sc in QtGui.QGuiApplication.screens()):
                kx, ky, kw, kh = kept                   # where the user put it last, the inspector beside the list
                self.setGeometry(kx, ky, kw + self._inspector_extra(), kh)
                return
        if other is not None and self.tabs.isVisible():
            r = other.availableGeometry()
            self.setGeometry(r.x() + 20, r.y() + 20, r.width() - 40, r.height() - 40)
            return
        tabs_w = min(620, max(500, int(w * 0.30))) if self.tabs.isVisible() else 0   # tree + chips + grid
        # under the bar and its context line (where, what is going on) - those stay readable
        self.setGeometry(x + 12, y + 96, max(200, tabs_w + insp_w + 16), max(300, h - 110))

    @staticmethod
    def _second_screen(x, y, w, h):
        """A screen the game window is not on (None with one screen)."""
        centre = QtCore.QPoint(x + w // 2, y + h // 2)
        for sc in QtGui.QGuiApplication.screens():
            if not sc.geometry().contains(centre):
                return sc
        return None


def project_label(project):
    return f"{project.meta.get('name', project.id)} ({os.path.basename(project.path)})"
