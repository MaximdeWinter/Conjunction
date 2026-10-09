"""Conjunction as an app (Maxim 05.10.: "Conjunction ist zuerst eine externe App - starten startet nicht das Spiel;
ein Projekt öffnen startet das Spiel und den Editor wie heute; was das Spiel nicht braucht, läuft in der App"): a
window with the logo and the name at the top, its pages on the left - Projects, Library, the plug-ins' pages
(api.add_page), Settings - and the long jobs at the bottom. Its look: theme.py.

    AppWindow(on_open=fn(project_dir))      on_open: the game and the editor for that project (__main__)
"""
import os
import time

from PySide6 import QtCore, QtGui, QtWidgets

from . import APP_NAME, __version__, config, theme
from .icons import icon
from .tooltips import item_tips, tip


def last_changed(path):
    """When a project was last changed: its newest file (project.yml, places, quests), not its build. -> seconds."""
    newest = 0
    for r, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if d not in ("build", "parked", "versions", "__pycache__")]
        for f in files:
            try:
                newest = max(newest, os.path.getmtime(os.path.join(r, f)))
            except OSError:
                pass
    return newest


class _SortItem(QtWidgets.QTableWidgetItem):
    """A cell that sorts by its number (a time), not by its text."""

    def __lt__(self, other):
        return (self.data(QtCore.Qt.UserRole + 1) or 0) < (other.data(QtCore.Qt.UserRole + 1) or 0)


KINDS = [("quest", "Quest", "Steps, talks and a journal entry. Its places come and go with the quest"),
         ("place", "Place mod", "A place that is always in the world: a house for Geralt, a camp, decoration")]


class NewProjectDialog(QtWidgets.QDialog):
    """A new project: its name and what it is (Maxim 06.10.: places and quests apart). -> name(), kind(), open_now"""

    def __init__(self, parent=None, in_game=False):
        super().__init__(parent)
        self.setWindowTitle("New project")
        self.open_now = False
        v = QtWidgets.QVBoxLayout(self)
        v.setSpacing(8)
        self.name_edit = tip(QtWidgets.QLineEdit(), "proj.name")
        self.name_edit.setPlaceholderText("Name")
        v.addWidget(self.name_edit)
        self.kind_buttons = {}
        for key, label, about in KINDS:
            b = QtWidgets.QRadioButton(label)
            b.setChecked(key == "quest")
            v.addWidget(b)
            note = QtWidgets.QLabel(about)
            note.setStyleSheet(f"color:{theme.DIM}; margin-left:22px")
            note.setWordWrap(True)
            v.addWidget(note)
            self.kind_buttons[key] = b
        self.dont_warn = None
        if in_game and not config.load().get("new_project_warning_off"):
            # (Maxim 07.10.) the game starts again so that only the new project is in the world
            warn = QtWidgets.QLabel("Creating a project restarts the game. Automatic quick save")
            warn.setStyleSheet(f"color:{theme.RED};font-weight:bold")
            warn.setWordWrap(True)
            v.addWidget(warn)
            self.dont_warn = QtWidgets.QCheckBox("Don't show again")
            v.addWidget(self.dont_warn)
        v.addSpacing(6)
        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        cancel = QtWidgets.QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        self.b_create = QtWidgets.QPushButton("Create")
        self.b_create.clicked.connect(lambda: self._done(False))
        self.b_create_open = QtWidgets.QPushButton("Create and open ingame")
        self.b_create_open.setObjectName("primary")
        self.b_create_open.clicked.connect(lambda: self._done(True))
        for b in (cancel, self.b_create, self.b_create_open):
            row.addWidget(b)
        if in_game:                                     # (in the game already: it opens there)
            self.b_create_open.hide()
            self.b_create.setObjectName("primary")
        v.addLayout(row)
        self.name_edit.textChanged.connect(self._named)
        self.name_edit.returnPressed.connect(lambda: self._done(False))
        self._named("")

    def _named(self, text):
        for b in (self.b_create, self.b_create_open):
            b.setEnabled(bool(text.strip()))

    def _done(self, open_now):
        if self.name() and self.dont_warn is not None and self.dont_warn.isChecked():
            cfg = config.load()
            cfg["new_project_warning_off"] = True
            config.save(cfg)
        if self.name():
            self.open_now = open_now or self.b_create_open.isHidden()
            self.accept()

    def name(self):
        return self.name_edit.text().strip()

    def kind(self):
        return next(k for k, b in self.kind_buttons.items() if b.isChecked())


class ProjectsPage(QtWidgets.QWidget):
    """The projects (the newest first): each with its quests. Nothing is chosen until it is clicked (Maxim 06.10.: a
    name typed for a new project, then Open, opened the one at the top); Open ingame names the one it opens."""

    def __init__(self, on_open):
        super().__init__()
        self.on_open = on_open
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(16, 12, 16, 12)
        v.setSpacing(8)
        top = QtWidgets.QHBoxLayout()
        head = QtWidgets.QLabel("Projects")
        head.setObjectName("head")
        top.addWidget(head)
        top.addStretch(1)
        b_folder = tip(QtWidgets.QPushButton("Add folder"), "proj.folder")
        b_folder.setIcon(icon("folder-open"))
        b_folder.clicked.connect(self.add_folder)
        top.addWidget(b_folder)
        b_new = tip(QtWidgets.QPushButton("New project"), "proj.new")
        b_new.setIcon(icon("plus"))
        b_new.clicked.connect(self.ask_new)
        top.addWidget(b_new)
        v.addLayout(top)
        self.table = QtWidgets.QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["Project", "Contents", "Last changed"])
        self.table.verticalHeader().hide()
        self.table.verticalHeader().setDefaultSectionSize(28)
        self.table.horizontalHeader().setHighlightSections(False)
        self.table.horizontalHeader().setFixedHeight(26)
        self.table.horizontalHeader().setDefaultAlignment(QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter)
        self.table.horizontalHeader().setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(1, QtWidgets.QHeaderView.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(2, QtWidgets.QHeaderView.ResizeToContents)
        self.table.setSortingEnabled(True)               # a click on a column's head sorts by it (Maxim 06.10.)
        self.table.horizontalHeader().setSortIndicatorShown(True)
        self.table.setShowGrid(False)
        self.table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        self.table.setSelectionMode(QtWidgets.QAbstractItemView.SingleSelection)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        self.table.setFocusPolicy(QtCore.Qt.NoFocus)
        self.table.cellDoubleClicked.connect(lambda _r, _c: self.open_chosen())
        item_tips(self.table)
        self.search = tip(QtWidgets.QLineEdit(), "proj.search")          # (Maxim 06.10.)
        self.search.setPlaceholderText("Search")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self.filter)
        v.addWidget(self.search)
        v.addWidget(self.table, 1)
        row = QtWidgets.QHBoxLayout()
        row.setSpacing(6)
        self.b_open = tip(QtWidgets.QPushButton("Open ingame"), "proj.open")
        self.b_open.setObjectName("primary")
        self.b_open.setIcon(icon("play"))
        self.b_open.clicked.connect(self.open_chosen)
        row.addWidget(self.b_open)
        self.b_hist = tip(QtWidgets.QPushButton("History"), "proj.history")
        self.b_hist.clicked.connect(self.show_history)
        row.addWidget(self.b_hist)
        row.addStretch(1)
        v.addLayout(row)
        self.table.itemSelectionChanged.connect(self._chosen_changed)
        self.fill()

    def fill(self):
        from . import quests as QS
        from .project import Project, recent
        self.table.setSortingEnabled(False)
        self.table.setRowCount(0)
        for path in recent():
            try:
                meta = Project(path).meta
            except Exception:                           # noqa: BLE001 - a broken project file: not offered
                continue
            titles = [q.get("title") or "Untitled" for q in QS.all_quests(meta)]
            if meta.get("kind") == "place":
                titles = ["Place mod"]
            r = self.table.rowCount()
            self.table.insertRow(r)
            name = QtWidgets.QTableWidgetItem(meta.get("name") or os.path.basename(path))
            name.setData(QtCore.Qt.UserRole, path)
            name.setToolTip(path)
            self.table.setItem(r, 0, name)
            quests = QtWidgets.QTableWidgetItem(", ".join(titles))
            quests.setForeground(QtGui.QColor(theme.DIM))
            self.table.setItem(r, 1, quests)
            changed = last_changed(path)
            when = _SortItem(time.strftime("%d.%m.%Y %H:%M", time.localtime(changed)) if changed else "")
            when.setData(QtCore.Qt.UserRole + 1, changed)
            when.setForeground(QtGui.QColor(theme.DIM))
            self.table.setItem(r, 2, when)
        self.table.setSortingEnabled(True)
        self.table.sortItems(2, QtCore.Qt.DescendingOrder)
        self.table.clearSelection()
        self.filter()
        self._chosen_changed()

    def filter(self, *_args):
        """Only the projects whose name or quests have every word typed in the search (any case). A chosen project
        that the search hides is no longer chosen."""
        words = self.search.text().lower().split() if hasattr(self, "search") else []
        for r in range(self.table.rowCount()):
            text = " ".join((self.table.item(r, c).text() if self.table.item(r, c) else "") for c in (0, 1)).lower()
            self.table.setRowHidden(r, not all(w in text for w in words))
        rows = self.table.selectionModel().selectedRows()
        if rows and self.table.isRowHidden(rows[0].row()):
            self.table.clearSelection()

    def _chosen_changed(self):
        """Open ingame and History act on the chosen project and say which one."""
        path = self.chosen()
        name = self.table.item(self.table.selectionModel().selectedRows()[0].row(), 0).text() if path else ""
        self.b_open.setEnabled(bool(path))
        self.b_hist.setEnabled(bool(path))
        self.b_open.setText(f"Open ingame: {name}" if name else "Open ingame")

    def paths(self):
        return [self.table.item(r, 0).data(QtCore.Qt.UserRole) for r in range(self.table.rowCount())]

    def chosen(self):
        rows = self.table.selectionModel().selectedRows()
        return self.table.item(rows[0].row(), 0).data(QtCore.Qt.UserRole) if rows else None

    def open_chosen(self):
        path = self.chosen()
        if path and self.on_open:
            self.on_open(path)

    def show_history(self):
        """Who made and changed the chosen project, with which tools - and whether the signatures hold."""
        path = self.chosen()
        if not path:
            return
        from . import provenance
        from .profile_view import HistoryDialog
        steps = provenance.read(path)
        check = provenance.check(steps, provenance.content_hash(path)) if steps else None
        self._history = HistoryDialog(steps, check, self, title=f"History of {os.path.basename(path)}")
        self._history.show()

    def ask_new(self):
        """New project: its name and kind asked in a small window; Create and open ingame opens it at once."""
        from . import dialogs
        dlg = NewProjectDialog()
        if dialogs.run_dialog(dlg, "New project", "new project") != QtWidgets.QDialog.Accepted:
            return None
        path = self.make(dlg.name(), dlg.kind())
        if path and dlg.open_now and self.on_open:
            self.on_open(path)
        return path

    def make(self, name, kind="quest"):
        """A new project, chosen in the list. -> its path"""
        from .project import new_project
        name = (name or "").strip()
        if not name:
            return None
        path = new_project(name, kind)
        self.search.clear()
        self.fill()
        for r, p in enumerate(self.paths()):
            if os.path.normcase(p) == os.path.normcase(path):
                self.table.selectRow(r)
                self.table.scrollToItem(self.table.item(r, 0))
        return path

    def add_folder(self):
        from .project import add_project
        d = QtWidgets.QFileDialog.getExistingDirectory(self, "Project folder")
        if d and add_project(d):
            self.fill()


class JobsBar(QtWidgets.QWidget):
    """The long jobs running (jobs.py): each one's name, its progress and its line."""

    def __init__(self):
        super().__init__()
        from .jobs import jobs
        self.v = QtWidgets.QVBoxLayout(self)
        self.v.setContentsMargins(10, 4, 10, 6)
        self.bars = {}
        jobs().changed.connect(self.refresh)
        self.hide()

    def refresh(self):
        from .jobs import jobs
        active = jobs().active()
        for key in [k for k in self.bars if k not in {id(j) for j in active}]:
            self.bars.pop(key).deleteLater()
        for j in active:
            bar = self.bars.get(id(j))
            if bar is None:
                bar = QtWidgets.QProgressBar()
                bar.setRange(0, 1000)
                self.bars[id(j)] = bar
                self.v.addWidget(bar)
            bar.setValue(int(j.fraction * 1000))
            bar.setFormat(f"{j.name}" + (f"  -  {j.text}" if j.text else "") + f"  {int(j.fraction * 100)} %")
        self.setVisible(bool(active))


class AppWindow(QtWidgets.QWidget):
    def __init__(self, on_open=None, plugins=None):
        super().__init__()
        from . import plugins as P
        self.plugins = plugins or P.get()
        self.on_open = on_open
        self.setObjectName("app")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        theme.install(QtWidgets.QApplication.instance())
        self.setStyleSheet(theme.sheet())
        self.setWindowTitle(APP_NAME)
        self.setWindowIcon(theme.window_icon())
        self.resize(1100, 720)
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        h = QtWidgets.QHBoxLayout()
        h.setSpacing(0)
        outer.addLayout(h, 1)
        side = QtWidgets.QFrame()
        side.setObjectName("side")
        side.setFixedWidth(180)
        sv = QtWidgets.QVBoxLayout(side)
        sv.setContentsMargins(0, 0, 0, 10)
        sv.setSpacing(6)
        self.nav = QtWidgets.QListWidget()
        self.nav.setObjectName("nav")
        self.nav.setFocusPolicy(QtCore.Qt.NoFocus)
        sv.addWidget(self.nav, 1)
        foot = QtWidgets.QVBoxLayout()
        foot.setContentsMargins(10, 0, 10, 0)
        foot.setSpacing(6)
        self.b_bug = tip(QtWidgets.QPushButton("Report a bug"), "app.bug")
        self.b_bug.setIcon(icon("bug"))
        self.b_bug.clicked.connect(self.report_bug)
        foot.addWidget(self.b_bug, 0, QtCore.Qt.AlignLeft)
        ver = QtWidgets.QLabel(f"{APP_NAME} {__version__}")
        ver.setObjectName("dim")
        foot.addWidget(ver)
        sv.addLayout(foot)
        h.addWidget(side)
        self.stack = QtWidgets.QStackedWidget()
        h.addWidget(self.stack, 1)
        self.jobs = JobsBar()
        outer.addWidget(self.jobs)
        self.pages = {}
        self.build_pages()
        self.nav.currentRowChanged.connect(self.stack.setCurrentIndex)
        self.nav.setCurrentRow(0)

    def report_bug(self):
        from .bugreport_view import BugWindow
        self._bug = BugWindow(None)
        self._bug.show()

    def build_pages(self):
        self.nav.clear()
        while self.stack.count():
            w = self.stack.widget(0)
            self.stack.removeWidget(w)
            w.deleteLater()
        self.pages = {}
        self.add_page("Projects", ProjectsPage(self.open_project))
        try:
            from .library_view import LibraryWindow
            from . import setup
            lib = LibraryWindow(on_play=lambda: setup.game_running() or setup.start_game())
            self.add_page("Library", lib)
        except Exception as ex:                         # noqa: BLE001 - the library has its own troubles
            self.add_page("Library", QtWidgets.QLabel(f"The library did not open: {ex}"))
        for title, factory in self.plugins.pages():
            try:
                self.add_page(title, factory(self))
            except Exception as ex:                     # noqa: BLE001 - a plug-in's page that fails: said, not fatal
                self.add_page(title, QtWidgets.QLabel(f"This page did not open: {ex}"))
        from .settings_view import SettingsPage
        settings = SettingsPage(self.plugins)
        settings.plugins_changed.connect(self._plugins_changed)
        self.add_page("Settings", settings)

    def add_page(self, title, widget):
        self.nav.addItem(title)
        self.stack.addWidget(widget)
        self.pages[title] = widget

    def show_page(self, title):
        names = [self.nav.item(k).text() for k in range(self.nav.count())]
        if title in names:
            self.nav.setCurrentRow(names.index(title))

    def _plugins_changed(self):
        """Plug-ins switched on or off, a folder added: loaded again, the pages made anew (Settings shown)."""
        from . import plugins as P
        self.plugins = P.reload()
        QtCore.QTimer.singleShot(0, lambda: (self.build_pages(), self.show_page("Settings"),
                                             self.pages["Settings"].select("Plug-ins")))

    def open_project(self, path):
        if self.on_open:
            self.on_open(path)
