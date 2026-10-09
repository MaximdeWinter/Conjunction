"""What the quest takes from mods (Maxim, 02.10.), shown in the Build tab above Export: each content pack with its
version and the things taken; a mod without Conjunction's card by its folder, with fields for the name, version and
link players will read when they lack it (remembered on this machine, content.remember_mod); things found nowhere.
The export writes exactly this list into the quest's manifest."""
from PySide6 import QtWidgets

from . import content
from .icons import GREEN, pixmap
from .tooltips import tip

AMBER = "#e5b85c"
RED = "#e57a7a"


class NeedsBox(QtWidgets.QFrame):
    def __init__(self, panel):
        super().__init__()
        self.panel = panel
        self.packs, self.missing = [], []
        self.setStyleSheet("QLabel#things{color:#8a8a8a;font:11px}QLabel#head{color:#bbb;font:bold 12px}")
        self.v = QtWidgets.QVBoxLayout(self)
        self.v.setContentsMargins(0, 4, 0, 4)
        self.v.setSpacing(3)

    def refresh(self):
        """Read again what the quest uses (cached bundles: a fraction of a second)."""
        project = self.panel.ed.project
        try:
            labels = content.labeler(getattr(self.panel, "assets", None))
            self.packs, self.missing = content.manifest_packs(project, labels=labels)
        except OSError as ex:
            self.packs, self.missing = [], []
            print(f"[export] {ex}", flush=True)
        self._show()

    def _clear(self):
        while self.v.count():
            item = self.v.takeAt(0)
            w = item.widget()
            if w:
                w.hide()
                w.deleteLater()
            elif item.layout():
                _drop(item.layout())

    def _show(self):
        self._clear()
        head = QtWidgets.QLabel("Mods it uses" if self.packs or self.missing else "Uses only the game")
        head.setObjectName("head")
        self.v.addWidget(head)
        for p in self.packs:
            self.v.addLayout(self._pack(p))
        if self.missing:
            line = QtWidgets.QLabel(f"Not found in the game: {', '.join(self.missing[:6])}" +
                                    (f" and {len(self.missing) - 6} more" if len(self.missing) > 6 else ""))
            line.setStyleSheet(f"color:{RED}")
            line.setWordWrap(True)
            self.v.addWidget(line)

    def _pack(self, p):
        v = QtWidgets.QVBoxLayout()
        v.setSpacing(1)
        h = QtWidgets.QHBoxLayout()
        plain = "folder" in p                       # a mod without Conjunction's card: known by its folder
        mark = QtWidgets.QLabel()
        ok = not plain or (p.get("name") != p["folder"].split("/", 1)[1] and p.get("url"))
        mark.setPixmap(pixmap("package-check" if not plain else "package", GREEN if ok else AMBER, 14))
        h.addWidget(mark)
        if plain:
            name = QtWidgets.QLineEdit(p.get("name", ""))
            tip(name, "exp.mod_name")
            ver = QtWidgets.QLineEdit(p.get("version", ""))
            ver.setPlaceholderText("version")
            ver.setFixedWidth(60)
            tip(ver, "exp.mod_version")
            url = QtWidgets.QLineEdit(p.get("url", ""))
            url.setPlaceholderText("Link (Nexus)")
            tip(url, "exp.mod_url")

            def save(_t=None, p=p, name=name, ver=ver, url=url):
                content.remember_mod(p["folder"], name.text(), ver.text(), url.text())
                p.update(name=name.text().strip() or p["folder"].split("/", 1)[1], version=ver.text().strip(),
                         url=url.text().strip())
            for f in (name, ver, url):
                f.editingFinished.connect(save)
            h.addWidget(name, 2)
            h.addWidget(ver)
            h.addWidget(url, 3)
        else:
            t = QtWidgets.QLabel(f"{p.get('name')} {p.get('version', '')}" +
                                 (f" by {p['author']}" if p.get("author") else ""))
            h.addWidget(t, 1)
        v.addLayout(h)
        used = [u.get("name") or u.get("ref") for u in p.get("used") or []]
        x = QtWidgets.QLabel(f"{len(used)} {'thing' if len(used) == 1 else 'things'}: " + ", ".join(used[:8]) +
                             (" ..." if len(used) > 8 else "") + (f"  ({p['folder']})" if plain else ""))
        x.setObjectName("things")
        x.setWordWrap(True)
        v.addWidget(x)
        return v


def _drop(layout):
    while layout.count():
        item = layout.takeAt(0)
        if item.widget():
            item.widget().hide()
            item.widget().deleteLater()
        elif item.layout():
            _drop(item.layout())

