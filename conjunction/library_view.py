"""The library window (Maxim, 01.10.): the quests to play - drop .w3q files into the folder it opens; at every start
Conjunction installs them (library.py). Each shows its title, author, version and whether it plays (a green check) or
what it still needs (the octagon and the reason): a mod it takes things from is named with what of it and a link
(Maxim, 02.10.). The window comes up by itself when a quest dropped into the folder lacks something
(watch_quests)."""
import os

from PySide6 import QtCore, QtGui, QtWidgets

from . import APP_NAME, theme
from .icons import GREEN
from .theme import RED
from .tooltips import tip



class LibraryWindow(QtWidgets.QWidget):
    def __init__(self, on_play=None):
        super().__init__()
        self.on_play = on_play
        self.setObjectName("lib")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        theme.install(QtWidgets.QApplication.instance())
        self.setStyleSheet(theme.sheet())
        self.setWindowTitle(f"{APP_NAME} - Library")
        self.setWindowIcon(theme.window_icon())
        self.resize(640, 520)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(16, 12, 16, 12)
        v.setSpacing(8)
        head = QtWidgets.QLabel("Library")
        head.setObjectName("head")
        v.addWidget(head)
        # (Maxim 06.10.: text only - no icons; no creator's tool here: the content pack maker is in the editor)
        self.area = QtWidgets.QScrollArea()
        self.area.setWidgetResizable(True)
        self.area.setFrameShape(QtWidgets.QFrame.NoFrame)
        self.list = QtWidgets.QWidget()
        self.rows = QtWidgets.QVBoxLayout(self.list)
        self.rows.setContentsMargins(0, 0, 0, 0)
        self.rows.setSpacing(6)
        self.area.setWidget(self.list)
        v.addWidget(self.area, 1)
        h = QtWidgets.QHBoxLayout()
        h.setSpacing(6)
        b_folder = QtWidgets.QPushButton("Open quest folder")
        b_folder.clicked.connect(self.open_folder)
        tip(b_folder, "lib.folder")
        b_refresh = QtWidgets.QPushButton("Refresh")
        b_refresh.clicked.connect(self.refresh)
        tip(b_refresh, "lib.refresh")
        h.addWidget(b_folder)
        h.addWidget(b_refresh)
        h.addStretch(1)
        if on_play is not None:
            b_play = QtWidgets.QPushButton("Start the game")
            b_play.clicked.connect(on_play)
            tip(b_play, "lib.play")
            h.addWidget(b_play)
        v.addLayout(h)
        self.status = QtWidgets.QLabel("")
        self.status.setObjectName("dim")
        v.addWidget(self.status)
        self.refresh()

    def pack_maker(self):
        from .pack_view import PackMakerWindow
        self._packs = PackMakerWindow()
        self._packs.show()

    def watch_quests(self):
        """Refresh when a file lands in the quest folder (or leaves it); come up when one lacks something."""
        from .library import QUESTS
        os.makedirs(QUESTS, exist_ok=True)
        self._watch = QtCore.QFileSystemWatcher([QUESTS], self)
        self._later = QtCore.QTimer(self, singleShot=True, interval=1500)     # a copy takes a moment
        self._watch.directoryChanged.connect(lambda _p: self._later.start())
        self._later.timeout.connect(self._dropped)

    def _dropped(self):
        before = set(self.lacking)
        self.refresh()
        if set(self.lacking) - before:
            self.come_up()

    def come_up(self):
        """Shown in front without taking the keys from the game."""
        self.setAttribute(QtCore.Qt.WA_ShowWithoutActivating, True)
        self.show()
        self.raise_()

    def open_folder(self):
        from .library import QUESTS
        os.makedirs(QUESTS, exist_ok=True)
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(QUESTS))

    def refresh(self):
        from . import library
        logs = []
        try:
            entries = library.sync(log=logs.append)
        except Exception as e:                      # noqa: BLE001 - say it in the window
            entries, logs = [], [f"The library could not be read: {e}"]
        while self.rows.count():
            w = self.rows.takeAt(0).widget()
            if w:
                w.hide()
                w.deleteLater()
        self.lacking = [e["file"] for e in entries if e["status"] != "installed"]
        if entries:
            quests = QtWidgets.QLabel("Quests")
            quests.setObjectName("head")
            self.rows.addWidget(quests)
        for e in entries:
            self.rows.addWidget(self._row(e))
        if not entries:
            empty = QtWidgets.QLabel("No quests yet")
            empty.setObjectName("dim")
            self.rows.addWidget(empty)
        self._packs_list()
        self.rows.addStretch(1)
        self.status.setText("  ".join(logs[-3:]))

    def _row(self, e):
        m = e.get("manifest") or {}
        row = QtWidgets.QFrame()
        row.setObjectName("row")
        h = QtWidgets.QHBoxLayout(row)
        ok = e["status"] == "installed"
        col = QtWidgets.QVBoxLayout()
        top = QtWidgets.QHBoxLayout()
        title = QtWidgets.QLabel(m.get("title") or e["file"])
        title.setObjectName("title")
        top.addWidget(title, 1)
        state = QtWidgets.QLabel("Ready" if ok else "Missing")       # (words, not an icon)
        state.setStyleSheet(f"color:{GREEN if ok else RED};font-weight:bold;background:transparent")
        top.addWidget(state, 0, QtCore.Qt.AlignTop)
        col.addLayout(top)
        sub = ", ".join(x for x in (m.get("author"), f"version {m['version']}" if m.get("version") else "",
                                     ", ".join(m.get("expansions") or [])) if x)
        s = QtWidgets.QLabel(sub)
        s.setObjectName("dim")
        col.addWidget(s)
        st = m.get("starts") or {}
        if st.get("text"):                          # where it begins: what a player looks for in the game
            begin = QtWidgets.QLabel(f"Starts: {st['text']}" + (f" ({st['world']})" if st.get("world") else ""))
            begin.setObjectName("dim")
            begin.setWordWrap(True)
            col.addWidget(begin)
        from .library import pack_problem
        packs = e.get("missing_packs") or []
        said = {pack_problem(n) for n in packs}
        for p in e.get("problems") or []:
            if p in said:
                continue
            pl = QtWidgets.QLabel(p)
            pl.setObjectName("problem")
            pl.setWordWrap(True)
            col.addWidget(pl)
        for need in packs:
            col.addWidget(self._pack_row(need))
        h.addLayout(col, 1)
        return row

    def _packs_list(self):
        """The content packs in the game: what quests can take from (content.installed_packs)."""
        from . import content
        try:
            packs = content.installed_packs()
        except OSError:
            packs = []
        if not packs:
            return
        head = QtWidgets.QLabel("Content packs")
        head.setObjectName("head")
        self.rows.addWidget(head)
        for pk in packs:
            row = QtWidgets.QFrame()
            row.setObjectName("row")
            h = QtWidgets.QHBoxLayout(row)
            col = QtWidgets.QVBoxLayout()
            t = QtWidgets.QLabel(f"{pk.get('name') or pk['id']} {pk.get('version', '')}".strip())
            t.setObjectName("title")
            col.addWidget(t)
            sub = ", ".join(x for x in (pk.get("author"), ", ".join(pk.get("kinds") or []),
                                         ", ".join(pk.get("folders") or [])) if x)
            lab = QtWidgets.QLabel(sub)
            lab.setObjectName("dim")
            col.addWidget(lab)
            h.addLayout(col, 1)
            if pk.get("url"):
                from .pack_view import open_url
                b = QtWidgets.QPushButton("Page")
                b.clicked.connect(lambda _c=False, u=pk["url"]: open_url(u))
                tip(b, "lib.page")
                h.addWidget(b)
            self.rows.addWidget(row)

    def _pack_row(self, need):
        """A missing mod: its name and version, what of it the quest takes, where to get it."""
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(0, 2, 0, 2)
        v.setSpacing(1)
        h = QtWidgets.QHBoxLayout()
        name = need.get("name") or need.get("id")
        ver = f" {need['version']}" if need.get("version") else ""
        old = str(need.get("why", "")).startswith("old")
        t = QtWidgets.QLabel(f"Needs {name}{ver}" + (f" or newer (installed: {need['why'][5:]})" if old else "") +
                             (f" by {need['author']}" if need.get("author") else ""))
        t.setObjectName("problem")
        t.setWordWrap(True)
        h.addWidget(t, 1)
        if need.get("url"):
            from .pack_view import open_url
            b = QtWidgets.QPushButton("Get")
            b.clicked.connect(lambda _c=False, u=need["url"]: open_url(u))
            tip(b, "lib.get")
            h.addWidget(b)
        v.addLayout(h)
        used = [u.get("name") or u.get("ref") for u in need.get("used") or []]
        if used:
            more = f" and {len(used) - 10} more" if len(used) > 10 else ""
            x = QtWidgets.QLabel("For: " + ", ".join(used[:10]) + more)
            x.setObjectName("dim")
            x.setWordWrap(True)
            v.addWidget(x)
        return w
