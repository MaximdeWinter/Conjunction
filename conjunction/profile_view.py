"""Profiles in the app (identity.py): the name asked at the first start, Settings > Profile, a project's history and
Check origin. The key itself is never shown - only where its file is.

    ask_first(parent) -> bool            the first start: a name, the key made, How signing works
    explain(profile, parent)             How signing works (Maxim 06.10.: worth reading once, says why anyone can
                                         stay anonymous)
    ProfilePage()                        Settings > Profile
    HistoryDialog(steps, check, parent)  who did what, with which tools, and whether the signatures hold
    CheckOriginDialog(parent)            a file or folder in, its history and the marks of this PC's profiles out
"""
import os
import subprocess

from PySide6 import QtCore, QtWidgets

from . import identity, theme
from .tooltips import tip

KEEP = ("This file is the profile's key. Keep it and copy it to a new PC (Documents\\Conjunction\\identity). "
        "Never post or send it: whoever has it can sign as this profile")


HOW_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "how_signing.html")


def how_text():
    """The text of How signing works (data/how_signing.html - edited there, read each time it opens)."""
    try:
        return open(HOW_FILE, encoding="utf-8").read()
    except OSError:
        return "<p>How signing works: the text file is missing (conjunction/data/how_signing.html).</p>"


def explain(profile=None, parent=None):
    """How signing works: what a profile is, what is signed, the key file, staying anonymous (recommended reading)."""
    d = QtWidgets.QDialog(parent)
    d.setWindowTitle("How signing works")
    d.setWindowIcon(theme.window_icon())
    d.setStyleSheet(theme.sheet())
    v = QtWidgets.QVBoxLayout(d)
    v.setContentsMargins(20, 16, 20, 16)
    head = QtWidgets.QLabel("How signing works (please read this once)")
    head.setObjectName("head")
    v.addWidget(head)
    text = QtWidgets.QTextBrowser()
    text.setOpenLinks(False)
    text.setHtml(how_text())
    v.addWidget(text, 1)
    row = QtWidgets.QHBoxLayout()
    if profile is not None:
        where = QtWidgets.QLabel(f"Key file of {profile.name}: {profile.path}")
        where.setWordWrap(True)
        where.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
        where.setStyleSheet(f"color:{theme.DIM}")
        row.addWidget(where, 1)
        b = QtWidgets.QPushButton("Show file")
        b.clicked.connect(lambda: show_file(profile.path))
        row.addWidget(b)
    else:
        row.addStretch(1)
    ok = QtWidgets.QPushButton("OK")
    ok.setDefault(True)
    ok.clicked.connect(d.accept)
    row.addWidget(ok)
    v.addLayout(row)
    d.resize(640, 640)
    from . import dialogs
    dialogs.run_dialog(d, "How signing works", "how signing")


def show_file(path):
    """Explorer with the file selected (Conjunction never shows what is in it)."""
    subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])


def first_hint(parent=None):
    """The first start (Maxim 08.10.: a profile is opt-in, like its name): once, what a profile is and that it can be
    made now or later in Settings > Profile. Never stops the start."""
    from . import config
    cfg = config.load()
    if identity.profiles() or cfg.get("profile_hint_shown"):
        return
    cfg["profile_hint_shown"] = True
    config.save(cfg)
    d = QtWidgets.QDialog(parent)
    d.setWindowTitle("Conjunction")
    d.setWindowIcon(theme.window_icon())
    v = QtWidgets.QVBoxLayout(d)
    v.setContentsMargins(20, 16, 20, 16)
    head = QtWidgets.QLabel("Profile (optional)")
    head.setObjectName("head")
    v.addWidget(head)
    info = QtWidgets.QLabel("A profile signs what you make with your name, so it shows that a quest is yours. It is "
                            "a name and a key file on this PC. You can make one now or later in Settings > Profile")
    info.setWordWrap(True)
    v.addWidget(info)
    row = QtWidgets.QHBoxLayout()
    row.addStretch(1)
    later = QtWidgets.QPushButton("Not now")
    later.setDefault(True)
    later.clicked.connect(d.reject)
    make = QtWidgets.QPushButton("Make a profile")
    make.clicked.connect(d.accept)
    row.addWidget(later)
    row.addWidget(make)
    v.addLayout(row)
    d.setMinimumWidth(460)
    if d.exec() == QtWidgets.QDialog.Accepted:
        ask_first(parent)


def ask_first(parent=None):
    """The name a new profile signs with (its key made, How signing works shown). -> True when there is one."""
    if identity.profiles():
        return True
    d = QtWidgets.QDialog(parent)
    d.setWindowTitle("Conjunction")
    d.setWindowIcon(theme.window_icon())
    v = QtWidgets.QVBoxLayout(d)
    v.setContentsMargins(20, 16, 20, 16)
    head = QtWidgets.QLabel("Your name")
    head.setObjectName("head")
    v.addWidget(head)
    info = QtWidgets.QLabel("Shown in the history of everything made with Conjunction (more profiles and a new "
                            "name in Settings > Profile)")
    info.setWordWrap(True)
    v.addWidget(info)
    name = QtWidgets.QLineEdit()
    name.setPlaceholderText("Name")
    name.setMaxLength(40)
    v.addWidget(name)
    ok = QtWidgets.QPushButton("OK")
    ok.setEnabled(False)
    ok.setDefault(True)
    name.textChanged.connect(lambda t: ok.setEnabled(bool(t.strip())))
    ok.clicked.connect(d.accept)
    row = QtWidgets.QHBoxLayout()
    row.addStretch(1)
    row.addWidget(ok)
    v.addLayout(row)
    d.setMinimumWidth(460)
    if d.exec() != QtWidgets.QDialog.Accepted or not name.text().strip():
        return False
    explain(identity.create(name.text().strip()), parent)
    return True


class ProfilePage(QtWidgets.QWidget):
    """Settings > Profile: the profile that signs, its name, its key file; more profiles; Check origin."""

    def __init__(self, parent=None):
        super().__init__(parent)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(16, 12, 16, 12)
        v.setSpacing(8)
        head = QtWidgets.QLabel("Profile")
        head.setObjectName("head")
        v.addWidget(head)
        form = QtWidgets.QFormLayout()
        form.setLabelAlignment(QtCore.Qt.AlignLeft)
        form.setHorizontalSpacing(16)
        form.setVerticalSpacing(8)
        v.addLayout(form)
        self.choice = tip(QtWidgets.QComboBox(), "set.profile.choice")
        self.choice.activated.connect(self._chosen)
        self.name = tip(QtWidgets.QLineEdit(), "set.profile.name")
        self.name.setPlaceholderText("Name")
        self.name.setMaxLength(40)
        self.name.editingFinished.connect(self._renamed)
        for label, w in (("Signs as", self.choice), ("Name", self.name)):
            lab = QtWidgets.QLabel(label)
            lab.setFixedWidth(theme.LABEL_W)
            w.setMaximumWidth(theme.FIELD_W)
            form.addRow(lab, w)
        self.file = QtWidgets.QLabel()
        self.file.setWordWrap(True)
        self.file.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
        lab = QtWidgets.QLabel("Key file")
        lab.setFixedWidth(theme.LABEL_W)
        form.addRow(lab, self.file)
        keep = QtWidgets.QLabel(KEEP)
        keep.setWordWrap(True)
        keep.setStyleSheet(f"color:{theme.DIM}")
        v.addWidget(keep)
        row = QtWidgets.QHBoxLayout()
        self.b_show = tip(QtWidgets.QPushButton("Show key file"), "set.profile.show")
        self.b_show.clicked.connect(lambda: self.current() and show_file(self.current().path))
        b_new = tip(QtWidgets.QPushButton("New profile"), "set.profile.new")
        b_new.clicked.connect(self._new)
        b_add = tip(QtWidgets.QPushButton("Add key file"), "set.profile.add")
        b_add.clicked.connect(self._add_file)
        b_check = tip(QtWidgets.QPushButton("Check origin"), "set.profile.check")
        b_check.clicked.connect(self._check)
        from . import timestamp
        self.stamp = tip(QtWidgets.QCheckBox("Public timestamp on export"), "set.profile.timestamp")
        self.stamp.setChecked(timestamp.on())
        self.stamp.toggled.connect(timestamp.set_on)
        v.addWidget(self.stamp)
        b_how = tip(QtWidgets.QPushButton("How signing works"), "set.profile.how")
        b_how.clicked.connect(lambda: explain(self.current(), self))
        for b in (self.b_show, b_new, b_add, b_check, b_how):
            row.addWidget(b)
        row.addStretch(1)
        v.addLayout(row)
        v.addStretch(1)
        self.fill()

    def current(self):
        return identity.active()

    def fill(self):
        self.choice.blockSignals(True)
        self.choice.clear()
        act = identity.active()
        self.choice.addItem("No profile (nothing is signed)", identity.NONE)
        for p in identity.profiles():
            self.choice.addItem(p.name, p.id)
            if act and p.id == act.id:
                self.choice.setCurrentIndex(self.choice.count() - 1)
        self.choice.blockSignals(False)
        self.name.setText(act.name if act else "")
        self.name.setEnabled(act is not None)
        self.file.setText(act.path if act else "No profile (New profile makes one)")
        self.b_show.setEnabled(act is not None)

    def _chosen(self, i):
        pid = self.choice.itemData(i)
        if pid == identity.NONE:
            identity.set_active(None)
        else:
            p = next((q for q in identity.profiles() if q.id == pid), None)
            if p:
                identity.set_active(p)
        self.fill()

    def _renamed(self):
        p = identity.active()
        t = self.name.text().strip()
        if p and t and t != p.name:
            p.rename(t)
            self.fill()

    # (06.10.: these opened windows outside the game - now over it, dialogs.py)
    def _check(self):
        from . import dialogs
        dialogs.run_dialog(CheckOriginDialog(None if dialogs.host is not None else self), "Check origin",
                           "check origin")

    def _new(self):
        from . import dialogs
        t = dialogs.ask_text(self, "New profile", "Name (a key of its own, nothing links it to the other profiles)")
        if t:
            identity.create(t)
            self.fill()

    def _add_file(self):
        from . import dialogs
        path = dialogs.pick_file(self, "Add key file", os.path.expanduser("~"), f"Conjunction key (*{identity.EXT})")
        if not path:
            return
        try:
            p = identity.add_file(path)
            identity.set_active(p)
        except Exception as ex:                         # noqa: BLE001 - not a key file
            box = QtWidgets.QMessageBox(QtWidgets.QMessageBox.Warning, "Add key file",
                                        f"Not a Conjunction key file ({ex})")
            dialogs.run_dialog(box, "Add key file", "ask")
        self.fill()


def _changes_text(s):
    ch = s.get("changes") or []
    if not ch:
        return ""
    return ch[0] if len(ch) == 1 else f"{ch[0]} (+{len(ch) - 1} more)"


def history_table(steps, detail=None):
    """Who did what with which tools, what changed; `detail` (a QLabel): every change of the row clicked."""
    t = QtWidgets.QTableWidget(len(steps), 5)
    t.setHorizontalHeaderLabels(["When", "Who", "What", "Changes", "Tools"])
    t.verticalHeader().setVisible(False)
    t.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
    t.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
    t.setSelectionMode(QtWidgets.QAbstractItemView.SingleSelection)
    for r, s in enumerate(steps):
        when = (s.get("at") or "")[:16].replace("T", " ")
        for c, text in enumerate((when, s.get("name", "?"), s.get("label", s.get("step", "")), _changes_text(s),
                                  ", ".join(s.get("tools") or []))):
            it = QtWidgets.QTableWidgetItem(text)
            if c == 4:
                it.setToolTip(text)
            elif s.get("changes"):
                it.setToolTip("\n".join(s["changes"]))
            t.setItem(r, c, it)
    t.horizontalHeader().setStretchLastSection(True)
    for c, w in enumerate((130, 120, 80, 330)):
        t.setColumnWidth(c, w)
    if detail is not None:
        def show(r, _c=0):
            s = steps[r]
            ch = s.get("changes") or []
            head = f"{s.get('label', '')} by {s.get('name', '?')}"
            detail.setText(head + (":\n" + "\n".join(ch) if ch else " (no changes named)"))
        t.cellClicked.connect(show)
        if steps:
            t.selectRow(len(steps) - 1)
            show(len(steps) - 1)
    return t


def state_text(check):
    if check is None:
        return "No history (made before histories, or it was cut out)", False
    if not check.ok:
        return check.problem, True
    if check.changed_after:
        return "Every step signed and unbroken (changed since the last step)", False
    return "Every step signed and unbroken", False


class HistoryDialog(QtWidgets.QDialog):
    def __init__(self, steps, check, parent=None, title="History"):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumSize(760, 360)
        v = QtWidgets.QVBoxLayout(self)
        text, bad = state_text(check)
        st = QtWidgets.QLabel(text)
        st.setWordWrap(True)
        if bad:
            st.setStyleSheet(f"color:{theme.RED}")
        v.addWidget(st)
        detail = QtWidgets.QLabel()
        detail.setWordWrap(True)
        detail.setTextInteractionFlags(QtCore.Qt.TextSelectableByMouse)
        v.addWidget(history_table(steps, detail), 1)
        v.addWidget(detail)


class CheckOriginDialog(QtWidgets.QDialog):
    """A .w3q, a project or a built quest in: its history, and whether this PC's profiles' marks are in it."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Check origin")
        self.setMinimumSize(800, 480)
        v = QtWidgets.QVBoxLayout(self)
        row = QtWidgets.QHBoxLayout()
        b_file = tip(QtWidgets.QPushButton("File..."), "origin.file")
        b_dir = tip(QtWidgets.QPushButton("Folder..."), "origin.folder")
        b_file.clicked.connect(self._file)
        b_dir.clicked.connect(self._dir)
        row.addWidget(b_file)
        row.addWidget(b_dir)
        self.what = QtWidgets.QLabel("A quest file (.w3q), a project or a built quest")
        self.what.setStyleSheet(f"color:{theme.DIM}")
        row.addWidget(self.what, 1)
        v.addLayout(row)
        self.state = QtWidgets.QLabel()
        self.state.setWordWrap(True)
        v.addWidget(self.state)
        self.table_box = QtWidgets.QVBoxLayout()
        self.table_box.addStretch(1)                    # (empty, the room below: the row stays at the top - run clears it)
        v.addLayout(self.table_box, 1)
        self.marks = QtWidgets.QLabel()
        self.marks.setWordWrap(True)
        v.addWidget(self.marks)

    def _file(self):
        from . import dialogs
        p = dialogs.pick_file(self, "Check origin", os.path.expanduser("~"), "Quest file or bundle (*.w3q *.bundle)")
        if p:
            self.run(p)

    def _dir(self):
        from . import dialogs
        p = dialogs.pick_folder(self, "Check origin (a project or a built quest)")
        if p:
            self.run(p)

    def run(self, path):
        from . import origin
        QtWidgets.QApplication.setOverrideCursor(QtCore.Qt.WaitCursor)
        try:
            r = origin.check(path)
        finally:
            QtWidgets.QApplication.restoreOverrideCursor()
        self.what.setText(f"{os.path.basename(path)} ({r.kind})")
        text, bad = state_text(r.history)
        self.state.setText(text)
        self.state.setStyleSheet(f"color:{theme.RED}" if bad else "")
        while self.table_box.count():
            w = self.table_box.takeAt(0).widget()
            if w:
                w.deleteLater()
        detail = QtWidgets.QLabel()
        detail.setWordWrap(True)
        self.table_box.addWidget(history_table(r.steps, detail), 1)
        self.table_box.addWidget(detail)
        lines = []
        for name, what, m, t, verdict in r.marks:
            word = {"yes": "Mark of", "likely": "Probably the mark of", "no": "No mark of"}[verdict]
            lines.append(f"{word} {name} in the {what} ({m} of {t})")
        for name, m, t in r.same_as:
            lines.append(f"{m} of {t} objects at the same spots as the project {name} (to 2 mm)")
        for m in r.similar:
            lines.append("The same content as your project " + m.line())
        if r.timestamp == "matches":
            lines.append("Public timestamp: proves when this history existed (check history.json and history.ots "
                         "at opentimestamps.org)")
        elif r.timestamp:
            lines.append("Public timestamp: does not match the history (the history was changed after it)")
        if not lines:
            lines.append("No profile of this PC to look for marks with" if not identity.profiles()
                         else "No marks of this PC's profiles found")
        lines += r.notes
        self.marks.setText("\n".join(lines))
        self.result = r
