"""The Settings page (settings.py keeps the values): its sections on the left - General, Game, Tools, Performance,
Plug-ins, the plug-ins' own sections indented under Plug-ins with lines to them (Maxim 05.10.) - their fields on the
right, saved at once. Plug-ins: a table of the plug-ins found (on / off, name, version, author, status) and the
folders they are found in."""
import os

from PySide6 import QtCore, QtGui, QtWidgets

from . import theme
from .icons import icon, icon_button
from .settings import FIELDS, SECTIONS, set_enabled, set_value, value
from .tooltips import TIPS, item_tips, tip

ROW_H = 28
HEAD_H = 26


class NavTree(QtWidgets.QTreeWidget):
    """The sections: one level, a section's children indented with a line down from it and one to each child."""
    INDENT = 22

    def __init__(self):
        super().__init__()
        self.setObjectName("nav")
        self.setHeaderHidden(True)
        self.setRootIsDecorated(False)
        self.setItemsExpandable(False)
        self.setIndentation(self.INDENT)
        self.setFocusPolicy(QtCore.Qt.NoFocus)
        self.setVerticalScrollMode(QtWidgets.QAbstractItemView.ScrollPerPixel)
        item_tips(self)

    def add(self, title, parent=None, key=None):
        it = QtWidgets.QTreeWidgetItem([title])
        if key and TIPS.get(key):
            it.setToolTip(0, TIPS[key])
        (parent.addChild(it) if parent is not None else self.addTopLevelItem(it))
        if parent is not None:
            parent.setExpanded(True)
        return it

    def items(self):
        out = []
        for k in range(self.topLevelItemCount()):
            top = self.topLevelItem(k)
            out.append(top)
            out += [top.child(c) for c in range(top.childCount())]
        return out

    def names(self):
        return [it.text(0) for it in self.items()]

    def drawBranches(self, painter, rect, index):
        parent = index.parent()
        if not parent.isValid():
            return
        last = index.row() == self.model().rowCount(parent) - 1
        x = rect.left() + 12
        mid = rect.center().y()
        painter.save()
        painter.fillRect(rect, QtGui.QColor(theme.BG))     # the indent stays unmarked when the child is chosen
        painter.setPen(QtGui.QPen(QtGui.QColor(theme.EDGE), 1))
        painter.drawLine(x, rect.top(), x, mid if last else rect.bottom() + 1)
        painter.drawLine(x, mid, rect.right(), mid)
        painter.restore()


class SettingsPage(QtWidgets.QWidget):
    """Sections on the left, their fields on the right. Changes are saved at once; plug-ins switched on or off: the
    app at once (it makes its pages anew), the game's editor at its next start."""
    plugins_changed = QtCore.Signal()

    def __init__(self, plugins=None):
        super().__init__()
        self.setObjectName("page")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        theme.install(QtWidgets.QApplication.instance())
        self.setStyleSheet(theme.sheet())
        from . import plugins as P
        self.plugins = plugins or P.get()
        h = QtWidgets.QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(0)
        self.sections = NavTree()
        self.sections.setFixedWidth(190)
        h.addWidget(self.sections)
        self.stack = QtWidgets.QStackedWidget()
        h.addWidget(self.stack, 1)
        self.fields = {}                                # (section, key) -> widget (tests)
        self.fill()
        self.sections.currentItemChanged.connect(
            lambda it, _old: it is not None and self.stack.setCurrentIndex(it.data(0, QtCore.Qt.UserRole)))
        self.sections.setCurrentItem(self.sections.topLevelItem(0))

    def fill(self):
        self.sections.clear()
        while self.stack.count():
            w = self.stack.widget(0)
            self.stack.removeWidget(w)
            w.deleteLater()
        for sec in SECTIONS:
            self._add(sec, self._own(sec))
            if sec == "General":                        # who signs what is made (identity.py, profile_view.py)
                from .profile_view import ProfilePage
                self.profile_page = ProfilePage()
                self._add("Profile", self.profile_page)
        top = self._add("Plug-ins", self._plugins())
        for pid, title, schema in self.plugins.settings_sections():
            self._add(title, self._plugin_section(pid, title, schema), parent=top)

    def select(self, title):
        for it in self.sections.items():
            if it.text(0) == title:
                self.sections.setCurrentItem(it)
                return True
        return False

    def _add(self, title, widget, parent=None):
        it = self.sections.add(title, parent)
        it.setData(0, QtCore.Qt.UserRole, self.stack.count())
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QtWidgets.QFrame.NoFrame)
        scroll.setWidget(widget)
        self.stack.addWidget(scroll)
        return it

    def _page(self, title):
        w = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(w)
        v.setContentsMargins(16, 12, 16, 12)
        v.setSpacing(8)
        head = QtWidgets.QLabel(title)
        head.setObjectName("head")
        v.addWidget(head)
        form = QtWidgets.QFormLayout()
        form.setLabelAlignment(QtCore.Qt.AlignLeft)
        form.setHorizontalSpacing(16)
        form.setVerticalSpacing(8)
        v.addLayout(form)
        return w, v, form

    @staticmethod
    def _row(form, label, widget):
        """One field: the labels in one column on every page, the fields no wider than FIELD_W."""
        label.setFixedWidth(theme.LABEL_W)
        widget.setMaximumWidth(min(widget.maximumWidth(), theme.FIELD_W))
        form.addRow(label, widget)

    def _own(self, sec):
        w, v, form = self._page(sec)
        from . import features
        for s, key, label, typ, _d, choices in FIELDS:
            if s != sec or (key == features.KEY and not features.offered()):
                continue
            widget = self._field(typ, value(key), choices, lambda v_, key=key: set_value(key, v_))
            self.fields[(sec, key)] = widget
            lab = tip(QtWidgets.QLabel(label), "set." + key)
            tip(widget, "set." + key)
            self._row(form, lab, widget)
            if key == features.KEY:                     # what it is, said plainly (Maxim 05.10.)
                warn = QtWidgets.QLabel(features.WARNING)
                warn.setObjectName("problem")
                warn.setWordWrap(True)
                warn.setMaximumWidth(theme.LABEL_W + 16 + theme.FIELD_W)
                self.fields[(sec, "experimental warning")] = warn
                form.addRow(warn)
        v.addStretch(1)
        return w

    def _plugin_section(self, pid, title, schema):
        w, v, form = self._page(title)
        from .plugins import Api
        values = next((p.settings() for p in self.plugins.loaded if p.id == pid), None)
        if callable(schema):                            # the plug-in builds its own section
            v.insertWidget(1, schema(values))
        else:
            values = values or Api("", {"id": pid}).settings()
            for f in schema:
                widget = self._field(f.get("type", "text"), values.get(f["key"]), f.get("choices"),
                                     lambda v_, k=f["key"]: values.__setitem__(k, v_))
                self.fields[(title, f["key"])] = widget
                lab = QtWidgets.QLabel(f.get("label") or f["key"])
                if f.get("tip"):                        # a plug-in's own line for the field
                    tip(lab, text=f["tip"])
                    tip(widget, text=f["tip"])
                self._row(form, lab, widget)
        v.addStretch(1)
        return w

    # --- Plug-ins
    def _table(self, headers):
        t = QtWidgets.QTableWidget(0, len(headers))
        t.setHorizontalHeaderLabels(headers)
        t.verticalHeader().hide()
        t.verticalHeader().setDefaultSectionSize(ROW_H)
        t.horizontalHeader().setHighlightSections(False)
        t.horizontalHeader().setFixedHeight(HEAD_H)
        t.horizontalHeader().setDefaultAlignment(QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter)
        t.setShowGrid(False)
        t.setSelectionMode(QtWidgets.QAbstractItemView.NoSelection)
        t.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        t.setFocusPolicy(QtCore.Qt.NoFocus)
        t.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        t.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        item_tips(t)
        return t

    @staticmethod
    def _fit(t):
        """The table as high as its rows (the page scrolls, not the table)."""
        t.setFixedHeight(HEAD_H + t.rowCount() * ROW_H + 2)

    @staticmethod
    def _cell(t, row, col, text, tooltip=None, dim=False):
        it = QtWidgets.QTableWidgetItem(text)
        if tooltip:
            it.setToolTip(tooltip)
        if dim:
            it.setForeground(QtGui.QColor(theme.DIM))
        t.setItem(row, col, it)
        return it

    @staticmethod
    def _centered(widget):
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(widget, 0, QtCore.Qt.AlignCenter)
        return box

    def _plugins(self):
        w, v, _form = self._page("Plug-ins")
        listing = self.plugins.listing()
        t = self._table(["On", "Plug-in", "Version", "Author", "Status", ""])
        t.setRowCount(len(listing))
        for row, (m, st) in enumerate(listing):
            on = QtWidgets.QCheckBox()
            on.setChecked(st != "off")
            on.setFocusPolicy(QtCore.Qt.NoFocus)
            on.toggled.connect(lambda c, pid=m["id"]: (set_enabled(pid, c), self.plugins_changed.emit()))
            tip(on, "set.plugins.on")
            self.fields[("Plug-ins", m["id"])] = on
            t.setCellWidget(row, 0, self._centered(on))
            self._cell(t, row, 1, m.get("name") or m["id"], m.get("description"))
            self._cell(t, row, 2, m.get("version") or "", dim=True)
            self._cell(t, row, 3, m.get("author") or "", dim=True)
            words = "off, adult content" if m.get("adult") and st == "off" else st
            self._cell(t, row, 4, words.splitlines()[0][:80], words if len(words) > 80 else None,
                       dim=st != "loaded")
            if m.get("readme"):                         # what the plug-in does, read here (Maxim 06.10.)
                b = QtWidgets.QPushButton("README")
                b.clicked.connect(lambda _c=False, m=m: self.show_readme(m))
                tip(b, "set.plugins.readme")
                self.fields[("Plug-ins", m["id"] + " readme")] = b
                t.setCellWidget(row, 5, self._centered(b))
        hh = t.horizontalHeader()
        hh.setSectionResizeMode(0, QtWidgets.QHeaderView.Fixed)
        t.setColumnWidth(0, 44)
        hh.setSectionResizeMode(1, QtWidgets.QHeaderView.Stretch)
        for col in (2, 3, 4, 5):
            hh.setSectionResizeMode(col, QtWidgets.QHeaderView.ResizeToContents)
        self._fit(t)
        self.plugin_table = t
        v.addWidget(t)
        if not listing:
            none = QtWidgets.QLabel("No plug-ins found")
            none.setObjectName("dim")
            v.addWidget(none)
        v.addSpacing(8)
        from .paths import PLUGINS
        where = QtWidgets.QLabel(PLUGINS)
        where.setObjectName("dim")
        v.addWidget(where)
        open_dir = QtWidgets.QPushButton("Open plug-ins folder")
        open_dir.setIcon(icon("folder-open"))
        open_dir.clicked.connect(self._open_dir)
        tip(open_dir, "set.plugins.folder")
        self.fields[("Plug-ins", "open folder")] = open_dir
        v.addWidget(open_dir, 0, QtCore.Qt.AlignLeft)
        v.addStretch(1)
        return w

    @staticmethod
    def _open_dir():
        from .paths import PLUGINS
        os.makedirs(PLUGINS, exist_ok=True)
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(PLUGINS))

    def show_readme(self, m):
        """A plug-in's README in a window of its own (markdown)."""
        d = QtWidgets.QDialog(self)
        d.setWindowTitle(f"{m.get('name') or m['id']} - README")
        d.setStyleSheet(theme.sheet())
        d.setObjectName("page")
        d.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        d.resize(720, 640)
        lay = QtWidgets.QVBoxLayout(d)
        lay.setContentsMargins(16, 12, 16, 12)
        text = QtWidgets.QTextBrowser()
        text.setOpenExternalLinks(True)
        text.setStyleSheet(f"QTextBrowser{{background:{theme.SURFACE};color:{theme.TEXT};border:1px solid "
                           f"{theme.LINE};padding:10px;font-size:{theme.FONT}px}}")
        try:
            text.setMarkdown(open(m["readme"], encoding="utf-8").read())
        except OSError as ex:
            text.setPlainText(str(ex))
        lay.addWidget(text)
        self._readme = d
        d.show()
        return d

    # --- one field
    def _field(self, typ, cur, choices, save):
        if typ == "bool":
            w = QtWidgets.QCheckBox()
            w.setChecked(bool(cur))
            w.toggled.connect(save)
            return w
        if typ == "int":
            w = QtWidgets.QSpinBox()
            w.setRange(0, 100000)
            w.setValue(int(cur or 0))
            w.setFixedWidth(90)
            w.valueChanged.connect(save)
            return w
        if typ == "float":
            w = QtWidgets.QDoubleSpinBox()
            w.setRange(-1e9, 1e9)
            w.setDecimals(3)
            w.setValue(float(cur or 0))
            w.setFixedWidth(110)
            w.valueChanged.connect(save)
            return w
        if typ == "choice":
            w = QtWidgets.QComboBox()
            pairs = [(c, c) if not isinstance(c, (list, tuple)) else tuple(c) for c in choices or []]
            for k, label in pairs:
                w.addItem(label, k)
            idx = next((i for i, (k, _l) in enumerate(pairs) if str(k) == str(cur)), -1)
            if idx >= 0:
                w.setCurrentIndex(idx)
            w.currentIndexChanged.connect(lambda i: save(w.itemData(i)))
            return w
        box = QtWidgets.QWidget()
        h = QtWidgets.QHBoxLayout(box)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(4)
        line = QtWidgets.QLineEdit(str(cur or ""))
        line.editingFinished.connect(lambda: save(line.text().strip()))
        h.addWidget(line, 1)
        if typ in ("path", "file"):
            pick = QtWidgets.QPushButton()
            pick.setIcon(icon("folder-open"))
            tip(pick, "set.pick_folder" if typ == "path" else "set.pick_file")

            def choose():
                got = QtWidgets.QFileDialog.getExistingDirectory(self, "Folder") if typ == "path" else \
                    QtWidgets.QFileDialog.getOpenFileName(self, "File")[0]
                if got:
                    line.setText(os.path.normpath(got))
                    save(os.path.normpath(got))
            pick.clicked.connect(choose)
            h.addWidget(pick)
        box.line = line
        return box
