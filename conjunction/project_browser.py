"""The project browser (File > Open project; Maxim 05.10.: a window with every project, not a list in the menu):
every project in Documents\\Conjunction, the ones added from elsewhere, and Conjunction's examples (to open and look at -
opened as an own copy). A window over the game that never takes its focus, square like the bar.

    Open            the chosen project (a double click too) - Conjunction starts again in it
    Open folder     Documents\\Conjunction in Explorer (to drop projects in; the list follows)
    Add ...         a project.yml from anywhere, into the list
"""
import os
import time

from PySide6 import QtCore, QtGui, QtWidgets

from .tooltips import tip

STYLE = (
    "*{border-radius:0}"
    "#browser{background:rgba(22,22,25,240);border:1px solid #55555c}"
    "QLabel{color:#c8c8cc;font:12px}"
    "QLabel#title{color:#f0f0f2;font:bold 13px}"
    "QLabel#hint{color:#8c8c90;font:11px}"
    "QTreeWidget{selection-background-color:transparent;selection-color:#fff}"
    "QPushButton#close{background:transparent;border:none;padding:2px 6px;color:#9a9aa0}"
)


OPEN_BG = QtGui.QColor(47, 90, 50, 200)          # the project open now: green behind it
PICKED = QtGui.QColor("#c8c8c8")                 # the one clicked: a light frame round its row


class RowFrame(QtWidgets.QStyledItemDelegate):
    """The clicked row framed (round the whole row, not each cell), no selection fill."""

    def paint(self, p, opt, index):
        o = QtWidgets.QStyleOptionViewItem(opt)
        picked = bool(o.state & QtWidgets.QStyle.State_Selected)
        o.state &= ~QtWidgets.QStyle.State_Selected
        o.state &= ~QtWidgets.QStyle.State_HasFocus
        super().paint(p, o, index)
        if picked:
            r = QtCore.QRectF(opt.rect).adjusted(0.5, 0.5, -0.5, -0.5)
            last = index.model().columnCount() - 1
            p.save()
            p.setPen(QtGui.QPen(PICKED, 1))
            p.drawLine(r.topLeft(), r.topRight())
            p.drawLine(r.bottomLeft(), r.bottomRight())
            if index.column() == 0:
                p.drawLine(r.topLeft(), r.bottomLeft())
            if index.column() == last:
                p.drawLine(r.topRight(), r.bottomRight())
            p.restore()


def when(path):
    t = os.path.getmtime(os.path.join(path, "project.yml"))
    return time.strftime("%d.%m.%Y %H:%M", time.localtime(t))


class ProjectBrowser(QtWidgets.QWidget):
    def __init__(self, ed):
        super().__init__(None, QtCore.Qt.FramelessWindowHint | QtCore.Qt.Tool)
        self.ed = ed
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground)
        self.setAttribute(QtCore.Qt.WA_ShowWithoutActivating)
        self.setStyleSheet(STYLE)
        self.resize(760, 460)
        frame = QtWidgets.QFrame(self)
        frame.setObjectName("browser")
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(frame)
        v = QtWidgets.QVBoxLayout(frame)
        v.setContentsMargins(12, 8, 12, 12)
        v.setSpacing(8)
        self.header = QtWidgets.QWidget()
        head = QtWidgets.QHBoxLayout(self.header)
        head.setContentsMargins(0, 0, 0, 0)
        title = QtWidgets.QLabel("Projects")
        title.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents)
        title.setObjectName("title")
        head.addWidget(title)
        head.addStretch(1)
        x = QtWidgets.QPushButton("✕")
        x.setObjectName("close")
        x.setFocusPolicy(QtCore.Qt.NoFocus)
        x.clicked.connect(self.hide)
        tip(x, "pan.close")
        head.addWidget(x)
        v.addWidget(self.header)
        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderLabels(["Name", "Changed", "Where"])
        self.tree.setRootIsDecorated(False)
        self.tree.setFocusPolicy(QtCore.Qt.NoFocus)
        self.tree.setColumnWidth(0, 230)
        self.tree.setColumnWidth(1, 120)
        self.tree.setItemDelegate(RowFrame(self.tree))
        self.tree.itemDoubleClicked.connect(lambda _it, _c: self.open_chosen())
        self.tree.itemSelectionChanged.connect(self._sync)
        tip(self.tree, "browse.list")
        v.addWidget(self.tree, 1)
        row = QtWidgets.QHBoxLayout()
        self.b_open = tip(self._button(row, "Open", self.open_chosen, "primary"), "browse.open")
        tip(self._button(row, "Open folder", self.open_folder), "browse.folder")
        tip(self._button(row, "Add...", self.add), "browse.add")
        row.addStretch(1)
        self.hint = QtWidgets.QLabel("")
        self.hint.setObjectName("hint")
        row.addWidget(self.hint)
        v.addLayout(row)
        self.fill()
        from .dock import Mover
        self.mover = Mover(self, frame, self.header, "projects", ed)    # moved, resized, docked at a side

    def _button(self, lay, text, fn, name=None):
        b = QtWidgets.QPushButton(text)
        b.setFocusPolicy(QtCore.Qt.NoFocus)
        if name:
            b.setObjectName(name)
        b.clicked.connect(fn)
        lay.addWidget(b)
        return b

    def fill(self):
        """Every project (the one open marked), then the examples."""
        from .project import Project, examples, recent
        self.tree.clear()
        here = os.path.normcase(os.path.abspath(self.ed.project.path))
        for p in recent():
            name = Project(p).meta.get("name") or os.path.basename(p)
            it = QtWidgets.QTreeWidgetItem(self.tree, [name, when(p), p])
            it.setData(0, QtCore.Qt.UserRole, p)
            if os.path.normcase(os.path.abspath(p)) == here:
                for c in range(3):
                    it.setBackground(c, OPEN_BG)
                it.setToolTip(0, "Open now")
        for name, p in examples():
            it = QtWidgets.QTreeWidgetItem(self.tree, [f"{name}   (example)", "", "Comes with Conjunction"])
            it.setData(0, QtCore.Qt.UserRole, p)
            it.setForeground(0, QtCore.Qt.gray)
        self._sync()

    def _sync(self):
        it = self.tree.currentItem()
        self.b_open.setVisible(it is not None)      # (Open shows once something is clicked)
        self.hint.setText(f"{self.tree.topLevelItemCount()} projects" if it is None else it.text(2))

    def show_over(self, rect):
        """Shown in the middle of the game's window (x, y, w, h), the list fresh."""
        self.fill()
        self.show()
        if not self.mover.docker.apply():           # docked: at its side; else where it was left, or the middle
            kept = self.mover.kept_rect()
            if kept is not None:
                self.setGeometry(kept)
            else:
                x, y, w, h = rect
                self.move(x + (w - self.width()) // 2, y + (h - self.height()) // 2)
        self.raise_()

    def showEvent(self, ev):
        from .panel import no_activate
        no_activate(self)
        super().showEvent(ev)

    # --- the buttons
    def open_chosen(self):
        it = self.tree.currentItem()
        if it is None:
            return
        path = it.data(0, QtCore.Qt.UserRole)
        if os.path.normcase(os.path.abspath(path)) == os.path.normcase(os.path.abspath(self.ed.project.path)):
            self.hide()
            return
        self.hide()
        # the game again with only that project in it (Maxim 07.10.): nothing of the one before stays in the world
        self.ed.start_clean(path) if hasattr(self.ed, "start_clean") else self.ed.switch_project(path)

    def open_folder(self):
        from .project import PROJECTS
        os.makedirs(PROJECTS, exist_ok=True)
        os.startfile(PROJECTS)

    def add(self):
        from .project import PROJECTS, add_project
        from .dialogs import pick_file
        path = pick_file(None, "Add a project", PROJECTS, "Project (project.yml)")
        if not path:
            return
        folder = add_project(path)
        if folder is None:
            self.hint.setText("Not a project (no project.yml there)")
            return
        self.fill()
        for i in range(self.tree.topLevelItemCount()):
            it = self.tree.topLevelItem(i)
            if os.path.normcase(it.data(0, QtCore.Qt.UserRole)) == os.path.normcase(folder):
                self.tree.setCurrentItem(it)
