"""The one item chooser (everywhere an item is wanted: a container's contents, a goal, a reward, a talk's give / take):
the quest's own items and the items it already uses on top, then every item of the game (the catalog's item page:
tree, search, icons). A window of its own (CatalogWindow) - several can be open, one per purpose. A click shows an
item in the inspector next to the grid, its button takes it. `then(ref)`: a game item's name or "own:<id>"."""
from PySide6 import QtCore, QtWidgets

from .tooltips import tip

CHOOSER_STYLE = ("QLabel#name{color:#bbb;font:12px}QLabel#field{color:#9a9a9a;font:11px}"
                 "QPushButton#close{background:transparent;border:none;padding:0}"
                 "QPushButton#close:hover{background:#5a2a2a}")


def quest_item_refs(q):
    """The items a quest has or uses: own ones ("own:<id>") first, then the game's (by name), each once."""
    refs = [f"own:{iid}" for iid in (q.get("items") or {})]

    def walk(x):
        if isinstance(x, dict):
            for k, v in x.items():
                if k == "item" and isinstance(v, str) and v:
                    refs.append(v)
                elif k == "items" and isinstance(v, list):
                    refs.extend(i for i in v if isinstance(i, str) and i)
                elif k != "items":
                    walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk({k: v for k, v in q.items() if k != "items"})
    return list(dict.fromkeys(refs))


def numbered_steps(quest):
    """[(number, step)]: a graph's steps by the number the graph shows (goals counted along the story - an action has
    none: its kind instead), the older form's steps in order and its paths'."""
    if quest.get("nodes"):
        from .quest_graph import build_nodes
        from .quest_nodes import order
        try:
            shown = {nid: n.number for nid, n in build_nodes(quest).nodes.items()}
        except Exception:                           # noqa: BLE001 - a graph it cannot draw: no numbers
            shown = {}
        out = []
        for nid in order(quest):
            st = (quest["nodes"].get(nid) or {}).get("step") or {}
            kind = next(iter(st), None)
            if kind and kind not in ("start", "end", "remember"):
                out.append((shown.get(nid) or kind, st))
        return out
    out = list(enumerate(quest.get("steps") or [], 1))
    for name, p in (quest.get("paths") or {}).items():
        out += [(f"{name} {k}", st) for k, st in enumerate(p.get("steps") or [], 1)]
    return out


def _names(x, value):
    if isinstance(x, dict):
        return any(_names(v, value) for v in x.values())
    if isinstance(x, list):
        return any(_names(v, value) for v in x)
    return x == value


def steps_about(quest, ref):
    """[(number, the step's text)] of the quest's steps that name the object `ref` (place/id) anywhere (a graph's
    nodes too - 02.10.: it read only the older list)."""
    from .quest import default_text, step_type
    out = []
    for n, st in numbered_steps(quest):
        kind, a = step_type(st)
        if _names(a, ref):
            out.append((n, (a or {}).get("text") or default_text(kind, a or {}, quest.get("items")) or kind))
    return out


def item_uses(quest, iid):
    """[(number, kind)] of the steps that use the quest's own item `iid` (own:<iid> anywhere in them)."""
    from .quest import step_type
    return [(n, step_type(st)[0]) for n, st in numbered_steps(quest) if _names(st, f"own:{iid}")]


def drop_item(quest, iid):
    """The own item `iid` out of the quest: its entry, and every place a step names it (an item field empties - the
    card shows it missing; a list loses it) -> how many places were cleared."""
    ref, count = f"own:{iid}", [0]

    def clear(x):
        if isinstance(x, dict):
            for k, v in list(x.items()):
                if v == ref:
                    x[k] = ""
                    count[0] += 1
                elif isinstance(v, list) and ref in v:
                    x[k] = [i for i in v if i != ref]
                    count[0] += 1
                else:
                    clear(v)
        elif isinstance(x, list):
            for v in x:
                clear(v)
    (quest.get("items") or {}).pop(iid, None)
    if not quest.get("items"):
        quest.pop("items", None)
    clear({k: v for k, v in quest.items() if k != "items"})
    return count[0]


def puts_in(quest, ref):
    """[(number, item ref)] what the quest puts into the container `ref` (place/id): a Loot step's items to take -
    put in when the quest starts (not the container's own inventory)."""
    from .quest import step_type
    out = []
    for n, st in numbered_steps(quest):
        kind, a = step_type(st)
        if kind == "loot" and isinstance(a, dict) and a.get("object") == ref:
            for it in [a.get("item")] + list(a.get("more_items") or []):
                it = it.get("item") if isinstance(it, dict) else it
                if it:
                    out.append((n, it))
    return out


def item_label(ref, quest, assets):
    """What an item reference is called: an own item's name, a game item's label."""
    if str(ref).startswith("own:"):
        return ((quest.get("items") or {}).get(ref[4:]) or {}).get("name") or ref[4:]
    it = assets.item(ref) if assets is not None else None
    return (it and (it.get("label") or it.get("name"))) or ref


class CatalogWindow(QtWidgets.QWidget):
    """Conjunction's window (every window works like the Asset Browser - Maxim 05.10.): frameless like the panel,
    dragged by its header, docked at a side of the game when dragged there, resized at its border, closed with its
    x. Several can be open at once, one per purpose (`key`); the editor keeps them above the game (Editor.stack) and
    typing works in their fields (Panel.eventFilter). Where it stood is kept per `kind`."""
    closed = QtCore.Signal()

    def __init__(self, panel, key, title, kind="items"):
        super().__init__(None, QtCore.Qt.FramelessWindowHint | QtCore.Qt.Tool)
        from .panel import STYLE, close_icon
        self.panel, self.key, self.kind, self.body = panel, key, kind, None
        self.setWindowTitle(title)                      # (frameless: not shown - agents and the taskbar read it)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground)
        self.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        self.setStyleSheet(STYLE + CHOOSER_STYLE)
        frame = QtWidgets.QFrame(self)
        frame.setObjectName("panel")
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(frame)
        self.lay = QtWidgets.QVBoxLayout(frame)
        self.lay.setContentsMargins(8, 2, 8, 6)
        self.lay.setSpacing(4)
        self.header = QtWidgets.QWidget()
        self.header.setFixedHeight(26)
        hl = QtWidgets.QHBoxLayout(self.header)
        hl.setContentsMargins(2, 0, 0, 0)
        self.title = QtWidgets.QLabel(title)
        self.title.setObjectName("title")
        self.title.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents)     # (the header under it is dragged)
        hl.addWidget(self.title)
        hl.addStretch(1)
        x = QtWidgets.QPushButton()
        x.setObjectName("close")
        x.setIcon(close_icon())
        x.setFixedSize(24, 20)
        x.setCursor(QtCore.Qt.ArrowCursor)
        x.clicked.connect(self.close)
        tip(x, "ic.close")
        hl.addWidget(x)
        self.lay.addWidget(self.header)
        from . import config
        r = config.load().get("catalog_windows", {}).get(kind)
        if r:
            self.setGeometry(*r)
        else:
            g = panel.geometry()
            self.setGeometry(g.x() + 60, g.y() + 60, max(760, g.width() - 120), max(560, g.height() - 120))
        from .dock import Mover
        self.mover = Mover(self, frame, self.header, f"window_{kind}", panel.ed)    # moved, resized, docked

    def set_body(self, w):
        self.body = w
        w.setWindowFlags(QtCore.Qt.Widget)          # (a window of its own made for itself - the bug report: inside)
        self.lay.addWidget(w, 1)
        w.show()

    def showEvent(self, ev):
        # never the active window (as the panel): the game pauses while it is not; keys come via keyboard.py
        import ctypes
        hwnd = int(self.winId())
        user32 = ctypes.windll.user32
        user32.SetWindowLongW(hwnd, -20, user32.GetWindowLongW(hwnd, -20) | 0x08000000)   # WS_EX_NOACTIVATE
        super().showEvent(ev)
        QtCore.QTimer.singleShot(0, self.mover.docker.apply)     # docked: at its side again

    def closeEvent(self, ev):
        from . import config
        cfg = config.load()
        g = self.geometry()
        cfg.setdefault("catalog_windows", {})[self.kind] = [g.x(), g.y(), g.width(), g.height()]
        config.save(cfg)
        self.panel.window_closed(self)
        super().closeEvent(ev)
        self.closed.emit()


class SceneChooser(QtWidgets.QWidget):
    """The body of a window to replace one of the game's scenes: its scenes on the left (searched by quest and
    name), what the one clicked is made of on the right (who is in it, where the quest starts it, where it goes on,
    lines); Replace takes it."""

    def __init__(self, panel, window, then):
        super().__init__()
        from .panel import INSPECTOR_W
        from .scene_swap import label, scene_index
        self.panel, self.window_, self.then, self.path = panel, window, then, None
        from .scene_swap import scene_info
        info = scene_info()
        # only scenes a quest can start (a way in): trailer shots and the like are left out
        self.index = [(p, label(p), info[p][0]) for p in scene_index() if info.get(p, ["", 0])[1]]
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(8)
        left = QtWidgets.QVBoxLayout()
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText(f"Search the game's scenes ({len(self.index)}): quest, scene, who is in it")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self._fill)
        tip(self.search, "gs.search")
        left.addWidget(self.search)
        self.list = QtWidgets.QListWidget()
        self.list.currentItemChanged.connect(lambda cur, _p: cur and self._show(cur.data(QtCore.Qt.UserRole)))
        self.list.itemDoubleClicked.connect(lambda _it: self._take())
        left.addWidget(self.list, 1)
        h.addLayout(left, 1)
        right = QtWidgets.QVBoxLayout()
        self.title = QtWidgets.QLabel("")
        self.title.setObjectName("title")
        self.title.setWordWrap(True)
        right.addWidget(self.title)
        self.about = QtWidgets.QLabel("")
        self.about.setWordWrap(True)
        self.about.setAlignment(QtCore.Qt.AlignTop)
        self.about.setStyleSheet("color:#bbb;font:12px")
        right.addWidget(self.about, 1)
        self.take = QtWidgets.QPushButton("Replace this scene")
        self.take.setEnabled(False)
        self.take.clicked.connect(self._take)
        tip(self.take, "gs.take")
        right.addWidget(self.take)
        box = QtWidgets.QWidget()
        box.setLayout(right)
        box.setFixedWidth(INSPECTOR_W + 60)
        h.addWidget(box)
        self._fill("")
        QtCore.QTimer.singleShot(0, lambda: panel.ed.typing.start(self.search))

    def _fill(self, text):
        self.list.clear()
        words = text.lower().replace("_", " ").split()
        shown = 0
        for path, lab, people in self.index:
            hay = (lab + " " + path.replace("_", " ") + " " + people).lower()
            if all(w in hay for w in words):
                it = QtWidgets.QListWidgetItem(lab)
                it.setData(QtCore.Qt.UserRole, path)
                it.setToolTip(path)
                self.list.addItem(it)
                shown += 1
                if shown >= 500:                    # enough to choose from; more words narrow it
                    break

    def _show(self, path):
        from .scene_swap import label, outline
        self.path = path
        o = outline(self.panel_depot(), path)
        self.outline = o
        people = [a["voicetag"].title() for a in o["actors"] if a["voicetag"] != "GERALT"]
        parts = [f"with {', '.join(people)}" if people else "only the player",
                 f"{o['lines']} lines" + (f", {len(o['inputs'])} entries, {len(o['outputs'])} exits"
                                          if len(o["inputs"]) > 1 or len(o["outputs"]) > 1 else "")]
        if o["cutscenes"] or o["videos"]:
            parts.append("has a cutscene or a film, replaced as a whole")
        if not o["inputs"]:
            parts = ["No quest starts this scene - it cannot be replaced."]
        self.title.setText(label(path))
        self.about.setText("\n".join(parts))
        self.take.setEnabled(bool(o["inputs"]))

    def panel_depot(self):
        from .bundles import Depot
        if getattr(self.panel, "_depot", None) is None:
            self.panel._depot = Depot()
        return self.panel._depot

    def _take(self):
        if not self.path:
            return
        from .scene_import import load_into
        from .scene_swap import new_swap
        swap = load_into(new_swap(self.panel_depot(), self.path), self.panel_depot())      # the game's own words
        then = self.then
        self.window_.close()
        then(swap)


class PointChooser(QtWidgets.QWidget):
    """The body of a window to put a quest into one of the game's quests: its quests on the left, the points of the
    one clicked on the right (each block of its graph with a way on, as questread reads it - searched by words);
    'Put my quest here' takes one."""

    def __init__(self, panel, window, then):
        super().__init__()
        from .graph_edit import phase_index
        from .panel import INSPECTOR_W
        from .scene_swap import label
        self.panel, self.window_, self.then, self.quest, self.points = panel, window, then, None, []
        self.index = [{"path": p, "name": label(p)} for p in phase_index()]
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(8)
        left = QtWidgets.QVBoxLayout()
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText(f"Search the game's quests ({len(self.index)})")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self._fill)
        tip(self.search, "gp.search")
        left.addWidget(self.search)
        self.list = QtWidgets.QListWidget()
        self.list.currentItemChanged.connect(lambda cur, _p: cur and self._show(cur.data(QtCore.Qt.UserRole)))
        left.addWidget(self.list, 1)
        box = QtWidgets.QWidget()
        box.setLayout(left)
        box.setFixedWidth(INSPECTOR_W)
        h.addWidget(box)
        right = QtWidgets.QVBoxLayout()
        self.title = QtWidgets.QLabel("")
        self.title.setObjectName("title")
        right.addWidget(self.title)
        note = QtWidgets.QLabel("(Caution: saves inside this game quest may break)")
        note.setStyleSheet("color:#e3c65f;font:12px")
        tip(note, "gp.saves")
        note.setWordWrap(True)
        right.addWidget(note)
        self.find = QtWidgets.QLineEdit()
        self.find.setPlaceholderText("Words of a point (scene, fact, name)")
        self.find.setClearButtonEnabled(True)
        self.find.textChanged.connect(self._fill_points)
        tip(self.find, "gp.find")
        right.addWidget(self.find)
        self.lines = QtWidgets.QListWidget()
        self.lines.itemDoubleClicked.connect(lambda _it: self._take())
        right.addWidget(self.lines, 1)
        self.take = QtWidgets.QPushButton("Put my quest here")
        self.take.clicked.connect(self._take)
        tip(self.take, "gp.take")
        right.addWidget(self.take)
        h.addLayout(right, 1)
        self._fill("")
        QtCore.QTimer.singleShot(0, lambda: panel.ed.typing.start(self.search))

    def _fill(self, text):
        self.list.clear()
        words = text.lower().split()
        for k, q in enumerate(self.index):
            if all(w in (q["name"] + " " + q["path"]).lower() for w in words):
                it = QtWidgets.QListWidgetItem(q["name"])
                it.setData(QtCore.Qt.UserRole, k)
                it.setToolTip(q["path"])
                self.list.addItem(it)

    def _show(self, k):
        from . import graph_edit
        from . import questread as Q
        from .assets import _cr2w_parts
        self.quest = self.index[k]
        self.title.setText(self.quest["name"])
        if getattr(self.panel, "_depot", None) is None:
            from .bundles import Depot
            self.panel._depot = Depot()
        f = _cr2w_parts(self.panel._depot.read(self.quest["path"]))[0]
        from .scene_swap import scene_people
        people = scene_people()
        self.points = []
        for gi, e in enumerate(f.exports, 1):
            if e[0] != "CQuestGraph":
                continue
            g = Q.Graph(f, gi)
            for i in sorted(g.blocks):
                for socket, targets in graph_edit.links(f, i):
                    if targets:
                        way = f"  -> {socket}" if socket not in (None, "Out", " ") else ""
                        who = ""
                        scene = g.blocks[i][1].get("scene")
                        if isinstance(scene, tuple) and scene[0] == "import" and people.get(scene[1].lower()):
                            who = f"  (with {people[scene[1].lower()]})"      # a talk: who is in it
                        self.points.append((i, socket, f"#{i} {g.describe(i)}{who}{way}"))
        self._fill_points(self.find.text())

    def _fill_points(self, text):
        self.lines.clear()
        words = text.lower().split()
        for i, socket, label in self.points:
            if all(w in label.lower() for w in words):
                it = QtWidgets.QListWidgetItem(label[:160])
                it.setData(QtCore.Qt.UserRole, (i, socket, label))
                it.setToolTip(label)
                self.lines.addItem(it)

    def _take(self):
        it = self.lines.currentItem()
        if not (self.quest and it):
            return
        i, socket, label = it.data(QtCore.Qt.UserRole)
        then = self.then
        self.window_.close()
        then({"phase": self.quest["path"], "name": self.quest["name"], "block": i, "socket": socket,
              "label": label})


class MomentChooser(QtWidgets.QWidget):
    """The body of a window to hook into the game's quests: its quests on the left (searched by name or fact), the
    moments (facts) of the one clicked on the right, in the order its graph sets them; Choose takes one."""

    def __init__(self, panel, window, then):
        super().__init__()
        from .game_quests import index
        from .panel import INSPECTOR_W
        self.panel, self.window_, self.then, self.quest = panel, window, then, None
        self.index = index()
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(8)
        left = QtWidgets.QVBoxLayout()
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText(f"Search the game's quests ({len(self.index)}) or a fact")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self._fill)
        tip(self.search, "gq.search")
        left.addWidget(self.search)
        self.list = QtWidgets.QListWidget()
        self.list.currentItemChanged.connect(lambda cur, _p: cur and self._show(cur.data(QtCore.Qt.UserRole)))
        left.addWidget(self.list, 1)
        h.addLayout(left, 1)
        right = QtWidgets.QVBoxLayout()
        self.title = QtWidgets.QLabel("")
        self.title.setObjectName("title")
        right.addWidget(self.title)
        note = QtWidgets.QLabel("The quest starts when the game's quest reaches:")
        note.setObjectName("field")
        right.addWidget(note)
        self.facts = QtWidgets.QListWidget()
        self.facts.itemDoubleClicked.connect(lambda _it: self._take())
        right.addWidget(self.facts, 1)
        self.take = QtWidgets.QPushButton("Choose")
        self.take.clicked.connect(self._take)
        tip(self.take, "gq.take")
        right.addWidget(self.take)
        box = QtWidgets.QWidget()
        box.setLayout(right)
        box.setFixedWidth(INSPECTOR_W + 60)
        h.addWidget(box)
        self._fill("")
        QtCore.QTimer.singleShot(0, lambda: panel.ed.typing.start(self.search))

    def _fill(self, text):
        self.list.clear()
        words = text.lower().split()
        found = []
        for k, q in enumerate(self.index):
            name = (q["name"] + " " + q["path"]).lower()
            if all(w in name for w in words):
                found.append((0, q["name"], k))         # by its name first
            elif words and all(w in name + " " + " ".join(q["facts"]).lower() for w in words):
                found.append((1, q["name"], k))         # then those with a moment of that name
        for _rank, _name, k in sorted(found):
            q = self.index[k]
            it = QtWidgets.QListWidgetItem(f"{q['name']}   ({len(q['facts'])})")
            it.setData(QtCore.Qt.UserRole, k)
            it.setToolTip(q["path"])
            self.list.addItem(it)

    def _show(self, k):
        self.quest = self.index[k]
        self.title.setText(self.quest["name"])
        self.facts.clear()
        words = self.search.text().lower().split()
        for fact in self.quest["facts"]:
            it = QtWidgets.QListWidgetItem(fact.replace("_", " "))
            it.setData(QtCore.Qt.UserRole, fact)
            self.facts.addItem(it)
            if words and all(w in fact.lower() for w in words):
                self.facts.setCurrentItem(it)

    def _take(self):
        it = self.facts.currentItem()
        if not (self.quest and it):
            return
        then = self.then
        self.window_.close()
        then({"quest": self.quest["path"], "name": self.quest["name"], "fact": it.data(QtCore.Qt.UserRole)})


class ItemChooser(QtWidgets.QWidget):
    """The body of an item window, laid out like the catalog: the quest's items on top (quick), the game's items in
    the grid, a click shows one in the inspector on the right, its button (`action`) takes it; a double click takes
    it at once. `keep_open`: the window stays for more (a container's contents), else it closes."""

    def __init__(self, panel, window, then, keep_open=False, action="Choose item"):
        super().__init__()
        from .catalog_view import TAG, CatalogView, Flow, Inspector
        from .panel import INSPECTOR_W
        self.panel, self.window_, self.then, self.keep_open = panel, window, then, keep_open
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(6)
        # this quest: its own items and those it uses already - what is wanted most of the time
        self.quest_box = QtWidgets.QWidget()
        v.addWidget(self.quest_box)
        self.quest_items()
        # every item of the game (the catalog on its item page) and, next to it, everything about the one clicked
        body = QtWidgets.QHBoxLayout()
        body.setSpacing(8)
        self.catalog = CatalogView(panel.ed, panel.assets)
        self.catalog.tabs.setCurrentIndex(1)
        self.catalog.tabs.hide()
        body.addWidget(self.catalog, 1)
        self.inspector = Inspector(panel.ed, panel.assets, self.catalog.pictures)
        self.inspector.item_action = action
        self.inspector.setFixedWidth(INSPECTOR_W)
        self.inspector.hide()
        body.addWidget(self.inspector)
        v.addLayout(body, 1)
        self.catalog.current.connect(self._current)
        self.catalog.chosen.connect(lambda e: e and e.get("type") == "item" and self._take(e["name"]))
        self.inspector.place.connect(self._take_shown)
        self.inspector.rename.returnPressed.connect(lambda: self._take_shown(self.inspector.entry))
        self.inspector.favourite.connect(self.catalog.toggle_favourite)
        self.inspector.overview.connect(self._overview)
        QtCore.QTimer.singleShot(0, lambda: panel.ed.typing.start(self.catalog.search))

    def quest_items(self):
        """The row of this quest's items (own ones first) - made anew each time the window opens: one made since
        (renamed from a game item) is there too."""
        from .catalog_view import TAG, Flow
        quest = self.panel.ed.project.meta.get("quest") or {}
        lay = self.quest_box.layout()
        if lay is not None:
            while lay.count():
                w = lay.takeAt(0).widget()
                if w is not None:
                    w.hide()
                    w.deleteLater()
            flow = lay
        else:
            flow = Flow(self.quest_box, 4)
        lab = QtWidgets.QLabel("This quest")
        lab.setObjectName("field")
        flow.addWidget(lab)
        for ref in quest_item_refs(quest):
            b = QtWidgets.QToolButton()
            b.setText(item_label(ref, quest, self.panel.assets))
            b.setStyleSheet(TAG)
            b.clicked.connect(lambda _c=False, ref=ref: self._quest_item(ref))
            # (its own: renamed or removed under 'In this quest' on the Quest tab - a right-click menu here closed by
            # itself, the editor takes the right mouse button for the camera)
            tip(b, "ic.own_item" if ref.startswith("own:") else "ic.quest_item")
            flow.addWidget(b)

    def _own_menu(self, button, iid):
        """Rename or remove one of the quest's own items (removing takes it out of the steps that use it)."""
        project = self.panel.ed.project
        quest = project.meta.get("quest") or {}
        it = (quest.get("items") or {}).get(iid)
        if it is None:
            return
        menu = QtWidgets.QMenu(button)
        ren = menu.addAction("Rename")
        uses = item_uses(quest, iid)
        rem = menu.addAction("Remove" + (f" (used in {len(uses)} step{'s' * (len(uses) != 1)})" if uses else ""))
        got = menu.exec(button.mapToGlobal(button.rect().bottomLeft()))
        if got is ren:
            name, ok = QtWidgets.QInputDialog.getText(self, "Rename", "Name in the inventory", text=it.get("name", ""))
            if ok and name.strip():
                it["name"] = name.strip()
                project.save_meta()
        elif got is rem:
            drop_item(quest, iid)
            project.save_meta()
        else:
            return
        self.quest_items()
        board = getattr(self.panel, "board", None)
        if board is not None:
            board.sync()

    def _current(self, e):
        if e and e.get("type") == "item":
            self.inspector.show_entry(e, favourite=e["key"] in self.catalog.favourites)
            self.inspector.show()

    def _overview(self, what, value):
        """A chip of the inspector (its type, a tag): all items of it - the item page kept."""
        self.catalog.show_only(what, value)
        self.catalog.tabs.setCurrentIndex(1)

    def _quest_item(self, ref):
        """A chip of this quest: a game item shows in the inspector (its button takes it), an own one is taken."""
        if ref.startswith("own:"):
            self._take(ref)
            return
        row = self.panel.assets.item(ref)
        if row:
            self._current(self.catalog._entry_item(row))
        else:
            self._take(ref)

    def _take_shown(self, e):
        """The inspector's button: the game's item - or, renamed, a new item of this quest made from it."""
        if not e or e.get("type") != "item":
            return
        name = self.inspector.renamed_to()
        self._take(self._make_own(name, e["row"], self.inspector.described()) if name else e["name"])

    def _make_own(self, name, row, description=None):
        """A new item of this quest named `name`, made from a game item (its icon; its description unless one is
        written) -> own:<id>."""
        project = self.panel.ed.project
        quest = project.meta.setdefault("quest", {})
        items = quest.setdefault("items", {})
        # the same name made from the same item again (a second card picking "Gucci Boots"): the one there is - two
        # of them looked alike and one was looted, the other asked for (Maxim 02.10.)
        for iid, it in items.items():
            if str(it.get("name", "")).strip().lower() == name.strip().lower() and it.get("base") == row["name"]:
                return f"own:{iid}"
        from .project import ascii_id
        slug = ascii_id(name, "")[:20] or "item"     # (a-z, 0-9 only: radish takes nothing else)
        iid, n = slug, 2
        while iid in items:
            iid, n = f"{slug}{n}", n + 1
        items[iid] = {"name": name, "description": description if description is not None else row.get("descr") or "",
                      "text": "", "base": row["name"]}
        project.save_meta()
        return f"own:{iid}"

    def _take(self, ref):
        if not ref:
            return
        then = self.then
        if not self.keep_open:
            self.window_.close()
        then(ref)


# --- a container's contents: the same parts on a quest card and in the inspector

def loot_title(name):
    """A loot table's name readable: '_interrior inn_everywhere but not nml' -> 'Interrior inn - everywhere but not
    nml'."""
    t = str(name or "").strip("_ ")
    parts = [p.strip() for p in t.split("_") if p.strip()]
    t = " - ".join(parts) if parts else t
    return t[:1].upper() + t[1:]


def _count_icon(pix, n, size=30):
    """An item icon with its count in the corner (n > 1)."""
    from PySide6 import QtGui
    out = QtGui.QPixmap(size, size)
    out.fill(QtCore.Qt.transparent)
    p = QtGui.QPainter(out)
    p.setRenderHint(QtGui.QPainter.SmoothPixmapTransform)
    if pix is not None and not pix.isNull():
        p.drawPixmap(out.rect(), pix.scaled(size, size, QtCore.Qt.KeepAspectRatio, QtCore.Qt.SmoothTransformation))
    if n and n > 1:
        f = p.font()
        f.setPixelSize(10)
        f.setBold(True)
        p.setFont(f)
        r = QtCore.QRect(0, size - 12, size - 1, 12)
        p.setPen(QtGui.QColor(0, 0, 0, 200))
        p.drawText(r.translated(1, 1), QtCore.Qt.AlignRight | QtCore.Qt.AlignBottom, str(n))
        p.setPen(QtGui.QColor("#f0f0f0"))
        p.drawText(r, QtCore.Qt.AlignRight | QtCore.Qt.AlignBottom, str(n))
    p.end()
    return out


class IconStrip(QtWidgets.QWidget):
    """Items as a row of icons (wrapping), each with its count; the name in the tooltip. `items`: [(item name,
    count text or number)]; more than `limit`: '+ n more'."""

    def __init__(self, assets, pictures, items, limit=12, empty="-"):
        super().__init__()
        from .catalog_view import Flow
        self.assets, self.pictures, self.labels = assets, pictures, {}
        flow = Flow(self, 3)
        if not items:
            e = QtWidgets.QLabel(empty)
            e.setStyleSheet("color:#777;font:12px")
            flow.addWidget(e)
        for name, n in items[:limit]:
            it = assets.item(name) or {"name": name, "label": name, "icon": ""}
            lab = QtWidgets.QLabel()
            lab.setFixedSize(30, 30)
            lab.setToolTip(f"{it.get('label') or name}" + (f"  x{n}" if n not in (None, "", 1, "1") else ""))
            key = f"item:{it['name']}@64"
            self.labels.setdefault(key, []).append((lab, n))
            self._paint(key, lab, n, pictures.get(key, lambda it=it: assets.icon(it)))
            flow.addWidget(lab)
        if len(items) > limit:
            more = QtWidgets.QLabel(f"+ {len(items) - limit}")
            more.setStyleSheet("color:#888;font:12px")
            flow.addWidget(more)
        pictures.ready.connect(self._ready)

    def _paint(self, key, lab, n, pix):
        num = n if isinstance(n, int) else None
        lab.setPixmap(_count_icon(pix, num))
        if pix is None or pix.isNull():
            lab.setText("·")
            lab.setAlignment(QtCore.Qt.AlignCenter)
            lab.setStyleSheet("color:#666;background:#232326;border:1px solid #333")

    def _ready(self, key):
        for lab, n in self.labels.get(key, []):
            try:
                lab.setStyleSheet("")
                lab.setText("")
                self._paint(key, lab, n, self.pictures.cache.get(key))
            except RuntimeError:                        # the strip is gone (the inspector was rebuilt)
                pass


def loot_row(o, own_table, on_set, on_change, actor=False):
    """Random loot of a container: [On | Off], and while on: its table (readable) and Change. `own_table`: the
    template's own table ('' none); on_set(value): None = its own table again, '' = no random loot; on_change():
    the loot window. actor: a person's or creature's loot when killed - added to what they carry, never instead."""
    from .catalog_view import TAG
    table = o["loot"] if "loot" in o else own_table
    on = bool(table)
    w = QtWidgets.QWidget()
    v = QtWidgets.QVBoxLayout(w)
    v.setContentsMargins(0, 0, 0, 0)
    v.setSpacing(2)
    h = QtWidgets.QHBoxLayout()
    h.setSpacing(3)
    lab = QtWidgets.QLabel("Loot when killed" if actor else "Random loot")
    lab.setStyleSheet("color:#999;font:12px")
    h.addWidget(lab)
    seg = TAG + "QToolButton:checked{color:#fff;background:#4b4b50;border-color:#c8c8c8}"
    for text, state, fn in (("On", True, lambda: on_set(None) if own_table else on_change()),
                            ("Off", False, lambda: on_set(""))):
        b = QtWidgets.QToolButton()
        b.setText(text)
        b.setCheckable(True)
        b.setChecked(on == state)
        b.setStyleSheet(seg)
        b.clicked.connect(lambda _c=False, fn=fn: fn())
        tip(b, ("loot.actor_on" if state else "loot.actor_off") if actor else ("loot.on" if state else "loot.off"))
        h.addWidget(b)
    h.addStretch(1)
    v.addLayout(h)
    if on:
        h2 = QtWidgets.QHBoxLayout()
        h2.setSpacing(4)
        name = QtWidgets.QLabel(loot_title(table))
        name.setToolTip(table)
        name.setStyleSheet("color:#ddd;font:12px")
        name.setSizePolicy(QtWidgets.QSizePolicy.Ignored, QtWidgets.QSizePolicy.Preferred)
        h2.addWidget(name, 1)
        if "loot" in o and own_table:
            back = QtWidgets.QToolButton()
            back.setText("Its own")
            back.setStyleSheet(TAG)
            back.clicked.connect(lambda: on_set(None))
            tip(back, "loot.own")
            h2.addWidget(back)
        ch = QtWidgets.QToolButton()
        ch.setText("Change")
        ch.setStyleSheet(TAG)
        ch.clicked.connect(lambda: on_change())
        tip(ch, "loot.change")
        h2.addWidget(ch)
        v.addLayout(h2)
    else:
        off = QtWidgets.QLabel("Only what they carry" if actor else "Only the quest items")
        off.setStyleSheet("color:#888;font:12px")
        v.addWidget(off)
    return w


class LootChooser(QtWidgets.QWidget):
    """The body of a loot window: every loot table (searched by its name and the items it gives) with a row of what
    it gives; a click shows all of it on the right, Use this loot takes it."""

    def __init__(self, panel, window, then, current=None):
        super().__init__()
        from .catalog_view import PictureLoader
        from .panel import INSPECTOR_W
        self.panel, self.window_, self.then, self.name = panel, window, then, None
        self.assets = panel.assets
        self.pictures = PictureLoader()
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(8)
        left = QtWidgets.QVBoxLayout()
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText("Search a loot table or an item it gives")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self._fill)
        left.addWidget(self.search)
        self.list = QtWidgets.QListWidget()
        self.list.setStyleSheet("QListWidget{background:#1d1d20;border:1px solid #444}"
                                "QListWidget::item{border-bottom:1px solid #2c2c30}"
                                )
        self.list.currentItemChanged.connect(lambda cur, _prev: cur and self._show(cur.data(QtCore.Qt.UserRole)))
        self.list.itemDoubleClicked.connect(lambda it: self._use(it.data(QtCore.Qt.UserRole)))
        left.addWidget(self.list, 1)
        h.addLayout(left, 1)
        self.detail = QtWidgets.QWidget()
        self.detail.setFixedWidth(INSPECTOR_W)
        self.dv = QtWidgets.QVBoxLayout(self.detail)
        self.dv.setContentsMargins(0, 0, 0, 0)
        h.addWidget(self.detail)
        self.name = current
        self._fill("")
        if current:
            self._show(current)
            if self.list.currentItem():
                self.list.scrollToItem(self.list.currentItem(), QtWidgets.QAbstractItemView.PositionAtCenter)
        QtCore.QTimer.singleShot(0, lambda: panel.ed.typing.start(self.search))

    def _fill(self, text):
        self.list.clear()
        tables = self.assets.loot_tables(text, limit=150)
        if self.name and not text and all(t["name"] != self.name for t in tables):
            cur = self.assets.loot(self.name)           # the one it has now: always in the list, first
            tables = ([cur] if cur else []) + tables
        for t in tables:
            it = QtWidgets.QListWidgetItem()
            it.setData(QtCore.Qt.UserRole, t["name"])
            row = QtWidgets.QWidget()
            v = QtWidgets.QVBoxLayout(row)
            v.setContentsMargins(4, 3, 4, 3)
            v.setSpacing(1)
            title = QtWidgets.QLabel(loot_title(t["name"]))
            title.setStyleSheet("color:#e8e8e8;font:12px")
            v.addWidget(title)
            v.addWidget(IconStrip(self.assets, self.pictures, [(e[0], None) for e in t["entries"]], limit=10))
            it.setSizeHint(QtCore.QSize(0, 58))         # a title and one row of icons (the flow's own hint is wrong)
            self.list.addItem(it)
            self.list.setItemWidget(it, row)
            if t["name"] == self.name:
                self.list.setCurrentItem(it)

    def _show(self, name):
        self.name = name
        while self.dv.count():
            w = self.dv.takeAt(0).widget()
            if w:
                w.deleteLater()
        t = self.assets.loot(name)
        title = QtWidgets.QLabel(loot_title(name))
        title.setWordWrap(True)
        title.setStyleSheet("color:#f0f0f0;font:bold 13px")
        self.dv.addWidget(title)
        use = QtWidgets.QPushButton("Use this loot")
        use.clicked.connect(lambda: self._use(name))
        tip(use, "loot.use")
        self.dv.addWidget(use)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QtWidgets.QFrame.NoFrame)
        body = QtWidgets.QWidget()
        bv = QtWidgets.QVBoxLayout(body)
        bv.setContentsMargins(0, 4, 0, 0)
        bv.setSpacing(2)
        for item, lo, hi, _chance in (t or {}).get("entries", []):
            row = QtWidgets.QHBoxLayout()
            row.addWidget(IconStrip(self.assets, self.pictures, [(item, None)], limit=1))
            it = self.assets.item(item) or {}
            n = QtWidgets.QLabel(it.get("label") or item)
            n.setStyleSheet("color:#ccc;font:12px")
            row.addWidget(n, 1)
            c = QtWidgets.QLabel(f"{lo}" if lo == hi else f"{lo}-{hi}")
            c.setStyleSheet("color:#888;font:12px")
            row.addWidget(c)
            bv.addLayout(row)
        bv.addStretch(1)
        scroll.setWidget(body)
        self.dv.addWidget(scroll, 1)

    def _use(self, name):
        then = self.then
        self.window_.close()
        then(name)
