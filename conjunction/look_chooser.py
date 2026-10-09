"""Choosing a person's look with pictures: every look the template has as a tile (drawn from the game's meshes in
their colours, kept on disk - the second time it opens at once), the one clicked large beside them to turn; Use this
look sets it (on the object in the game and in the place file). The looks the game itself spawns come first, the
quests' own ones (named __...) after them.
"""
import hashlib
import os
import threading

from PySide6 import QtCore, QtGui, QtWidgets

from . import paths
from .tooltips import tip

CACHE = os.path.join(paths.DATA, "looks")
TILE = QtCore.QSize(96, 136)


def ordered(apps, used):
    """The game's own looks first (the ones its spawns use, in their order), the quests' (__name) last."""
    apps = list(apps)
    first = [u for u in used if u in apps]
    rest = [a for a in apps if a not in first]
    return first + [a for a in rest if not a.startswith("__")] + [a for a in rest if a.startswith("__")]


def label(look):
    return look.lstrip("_").replace("_", " ") if look else "default"


def cache_file(template, look):
    key = hashlib.sha1(template.lower().encode("utf-8")).hexdigest()[:10]
    base = os.path.splitext(os.path.basename(template.replace("\\", "/")))[0]
    return os.path.join(CACHE, f"{base}_{key}", f"{look or '_default'}.png")


class LookChooser(QtWidgets.QWidget):
    """The body of the look window. `then(look)` when one is used."""
    parts_ready = QtCore.Signal(str, object, object, bool)      # look, parts, images, for a tile
    talks_ready = QtCore.Signal(object)

    def __init__(self, panel, window, template, current, then, depot=None, speaks=False):
        super().__init__()
        from . import meshview
        self.panel, self.window_, self.template, self.then = panel, window, template, then
        self.depot = depot
        self.current = current or ""
        self.shown = None
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(8)
        self.grid = QtWidgets.QListWidget()
        self.grid.setViewMode(QtWidgets.QListView.IconMode)
        self.grid.setIconSize(TILE)
        self.grid.setGridSize(QtCore.QSize(TILE.width() + 16, TILE.height() + 30))
        self.grid.setResizeMode(QtWidgets.QListView.Adjust)
        self.grid.setMovement(QtWidgets.QListView.Static)
        self.grid.setWordWrap(True)
        self.grid.currentItemChanged.connect(lambda cur, _p: cur and self._show(cur.data(QtCore.Qt.UserRole)))
        self.grid.itemDoubleClicked.connect(lambda it: self._use(it.data(QtCore.Qt.UserRole)))
        tip(self.grid, "look.tiles")
        h.addWidget(self.grid, 3)
        right = QtWidgets.QVBoxLayout()
        self.name = QtWidgets.QLabel("")
        self.name.setObjectName("title")
        right.addWidget(self.name)
        self.view = meshview.MeshView()
        tip(self.view, "ins.view3d")
        right.addWidget(self.view, 1)
        self.b_use = QtWidgets.QPushButton("Use this look")
        self.b_use.clicked.connect(lambda: self._use(self.shown))
        tip(self.b_use, "look.use")
        right.addWidget(self.b_use)
        h.addLayout(right, 2)
        # tiles are drawn by a view nobody sees (the large one keeps showing what was clicked)
        self.painter = meshview.MeshView()
        self.painter.setAttribute(QtCore.Qt.WA_DontShowOnScreen)
        self.painter.resize(TILE.width() * 2, TILE.height() * 2)
        self.parts_ready.connect(self._ready)
        apps, used = meshview.looks(template, self._depot())
        self.looks = [""] + ordered(apps, used)
        self.items = {}
        blank = QtGui.QPixmap(TILE)
        blank.fill(QtGui.QColor(48, 50, 55))
        for look in self.looks:
            it = QtWidgets.QListWidgetItem(QtGui.QIcon(blank), label(look))
            it.setData(QtCore.Qt.UserRole, look)
            it.setToolTip(look or "default")
            self.grid.addItem(it)
            self.items[look] = it
            if os.path.exists(cache_file(template, look)):
                it.setIcon(QtGui.QIcon(cache_file(template, look)))
        self.todo = [lk for lk in self.looks if not os.path.exists(cache_file(template, lk))]
        self.busy = False
        cur = self.items.get(self.current) or self.items[""]
        self.grid.setCurrentItem(cur)
        QtCore.QTimer.singleShot(50, self._next_tile)
        # which looks have a face that moves its mouth (talking.py, read in the background)
        self.speaks = speaks
        self.talks_ready.connect(self._mark_talking)

        def work():
            try:
                from . import talking
                talks = talking.talking_looks(template)
            except Exception:                           # noqa: BLE001 - no game to look in: no marks
                talks = None
            self.talks_ready.emit(talks)
        threading.Thread(target=work, daemon=True).start()

    def _mark_talking(self, talks):
        """A look without a face that moves: hidden for a person who speaks in the quest (unless it is theirs now),
        dimmed for everyone else."""
        if not talks:
            return
        for look, it in self.items.items():
            if not look:
                continue
            if look in talks:
                it.setToolTip(f"{look} (can speak)")
            elif self.speaks and look != self.current:
                it.setHidden(True)
            else:
                it.setForeground(QtGui.QColor(125, 125, 128))
                it.setToolTip(f"{look} (background look without a moving face, a speaker needs one that can)")

    def _depot(self):
        if self.depot is None:
            from .bundles import Depot
            self.depot = Depot()
        return self.depot

    # --- the look's parts, read in the background
    def _load(self, look, tile):
        from . import meshview

        def work():
            try:
                _how, parts = meshview.entity_parts(self.template, self._depot(), (), look or None)
                images = meshview.load_images(parts, 256 if tile else 512)
            except Exception:                           # noqa: BLE001 - a look that cannot be drawn keeps its blank
                parts, images = [], {}
            self.parts_ready.emit(look, parts, images, tile)
        threading.Thread(target=work, daemon=True).start()

    def _ready(self, look, parts, images, tile):
        if not tile:
            if look == self.shown:
                self.view.yaw, self.view.pitch = 180.0, 0.0         # from the front, as the tiles
                self.view.show_parts(parts, images)
            return
        self.busy = False
        if parts and self.painter is not None:
            self.painter.show()
            self.painter.yaw, self.painter.pitch = 180.0, 0.0         # from the front
            self.painter.show_parts(parts, images)
            img = self.painter.grabFramebuffer()
            path = cache_file(self.template, look)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            img.save(path)
            self.items[look].setIcon(QtGui.QIcon(QtGui.QPixmap.fromImage(img)))
        QtCore.QTimer.singleShot(0, self._next_tile)

    def _next_tile(self):
        if self.busy or not self.todo:
            if not self.todo and self.painter is not None:
                self.painter.hide()
            return
        self.busy = True
        self._load(self.todo.pop(0), True)

    # --- clicked: large, to turn; used: set
    def _show(self, look):
        self.shown = look
        self.name.setText(label(look) + ("   (current)" if look == self.current else ""))
        self._load(look, False)

    def _use(self, look):
        if look is None:
            return
        self.current = look
        self.then(look)
        self.window_.close()


class LookPainter(QtCore.QObject):
    """Draws looks as tiles in the background, one at a time, the last one asked for first (what the grid shows
    now), into cache_file - for the Asset Browser, where a person with several looks is a folder of them (Maxim
    08.10.). `painted(template, look, path)`: path '' if it could not be drawn."""
    painted = QtCore.Signal(str, str, str)
    _read = QtCore.Signal(str, str, object, object)

    def __init__(self):
        super().__init__()
        self.queue, self.asked, self.busy = [], set(), False
        self.painter = self.depot = None
        self._read.connect(self._ready)

    def want(self, template, look):
        if (template, look) in self.asked:
            return
        self.asked.add((template, look))
        self.queue.append((template, look))
        QtCore.QTimer.singleShot(0, self._next)

    def _next(self):
        if self.busy or not self.queue:
            return
        self.busy = True
        template, look = self.queue.pop()
        if self.depot is None:
            from .bundles import Depot
            self.depot = Depot()

        def work():
            from . import meshview
            try:
                _how, parts = meshview.entity_parts(template, self.depot, (), look or None)
                images = meshview.load_images(parts, 256)
            except Exception:                           # noqa: BLE001 - a look that cannot be drawn: no tile
                parts, images = [], {}
            self._read.emit(template, look, parts, images)
        threading.Thread(target=work, daemon=True).start()

    def _ready(self, template, look, parts, images):
        path = ""
        if parts:
            try:
                from . import meshview
                if self.painter is None:
                    self.painter = meshview.MeshView()
                    self.painter.setAttribute(QtCore.Qt.WA_DontShowOnScreen)
                    self.painter.resize(TILE.width() * 2, TILE.height() * 2)
                self.painter.show()
                self.painter.yaw, self.painter.pitch = 180.0, 0.0        # from the front
                self.painter.show_parts(parts, images)
                img = self.painter.grabFramebuffer()
                if not img.isNull():
                    path = cache_file(template, look)
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    img.save(path)
            except Exception:                           # noqa: BLE001 - no OpenGL here: no tiles
                path = ""
        self.busy = False
        if not self.queue and self.painter is not None:
            self.painter.hide()
        self.painted.emit(template, look, path)
        QtCore.QTimer.singleShot(0, self._next)


_painter = None


def painter():
    """The one LookPainter (made on first use, in the GUI thread)."""
    global _painter
    if _painter is None:
        _painter = LookPainter()
    return _painter
