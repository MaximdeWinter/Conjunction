"""The card for an object the game placed (edit existing on, one selected): remove it, play an effect on it, give it
another look - each kept as a world change (worldchanges.py) that the script extender applies for everyone who has
the quest. A quest step can switch a change on or off later (Change world in the quest's World actions)."""
from PySide6 import QtCore, QtWidgets

from . import worldchanges
from .tooltips import tip


class WorldCard(QtWidgets.QFrame):
    remove = QtCore.Signal()
    effect = QtCore.Signal(str, bool)
    look = QtCore.Signal(str)
    drop = QtCore.Signal(int)

    def __init__(self):
        super().__init__()
        self.sel = None
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(6, 6, 6, 6)
        self.title = QtWidgets.QLabel()
        self.title.setWordWrap(True)
        self.title.setStyleSheet("font-weight:bold")
        v.addWidget(self.title)
        self.note = QtWidgets.QLabel()
        self.note.setWordWrap(True)
        self.note.setStyleSheet("color:#c9a")
        v.addWidget(self.note)
        self.b_remove = tip(QtWidgets.QPushButton("Remove"), "world.remove")
        self.b_remove.clicked.connect(self.remove)
        v.addWidget(self.b_remove)
        row = QtWidgets.QHBoxLayout()
        self.fx = QtWidgets.QComboBox()                # the object's own effects (the game reports them: worldinfo)
        on = tip(QtWidgets.QPushButton("On"), "world.effect_on")
        off = tip(QtWidgets.QPushButton("Off"), "world.effect_off")
        on.clicked.connect(lambda: self._effect(True))
        off.clicked.connect(lambda: self._effect(False))
        row.addWidget(QtWidgets.QLabel("Effect"))
        row.addWidget(self.fx, 1)
        row.addWidget(on)
        row.addWidget(off)
        v.addLayout(row)
        row = QtWidgets.QHBoxLayout()
        self.app = QtWidgets.QComboBox()               # its appearances
        b_look = tip(QtWidgets.QPushButton("Set"), "world.look")
        b_look.clicked.connect(lambda: self.app.currentText() and self.look.emit(self.app.currentText()))
        self.fx_row, self.look_row = [self.fx, on, off], [self.app, b_look]
        row.addWidget(QtWidgets.QLabel("Look"))
        row.addWidget(self.app, 1)
        row.addWidget(b_look)
        v.addLayout(row)
        self.list = QtWidgets.QVBoxLayout()
        v.addLayout(self.list)
        v.addStretch(1)

    def _effect(self, on):
        name = self.fx.currentText().strip()
        if name:
            self.effect.emit(name, on)

    def show_object(self, sel, project_path):
        """sel: the selected object's report {guid, name, template, pos}."""
        self.sel = sel
        self.title.setText(worldchanges.short_name(sel.get("name") or sel.get("template")) or "Object")
        self.lasting = worldchanges.guid_ok(sel.get("guid"))
        self.note.setText("" if self.lasting else "Made by the game while playing, it cannot be changed permanently")
        self.b_remove.setEnabled(self.lasting)
        self.set_info([], [])
        self.refresh(project_path)

    def set_info(self, effects, looks):
        """What the selected object can play and switch to (the game's worldinfo line)."""
        for box, names, row in ((self.fx, effects, self.fx_row), (self.app, looks, self.look_row)):
            box.clear()
            box.addItems(names)
            for w in row:
                w.setEnabled(bool(names) and getattr(self, "lasting", False))

    def say(self, text):
        self.note.setText(text)

    def refresh(self, project_path):
        while self.list.count():
            item = self.list.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        guid = (self.sel or {}).get("guid")
        for c in worldchanges.load(project_path):
            if c["guid"] != guid:
                continue
            row = QtWidgets.QWidget()
            h = QtWidgets.QHBoxLayout(row)
            h.setContentsMargins(0, 0, 0, 0)
            text = {"remove": "Removed", "effect": f"Effect {c.get('value', '')}",
                    "look": f"Look {c.get('value', '')}", "move": "Moved"}.get(c["do"], c["do"])
            h.addWidget(QtWidgets.QLabel(f"{text}  (change {c['id']})"), 1)
            x = tip(QtWidgets.QPushButton("x"), "world.drop")
            x.setFixedWidth(24)
            x.clicked.connect(lambda _=False, cid=c["id"]: self.drop.emit(cid))
            h.addWidget(x)
            self.list.addWidget(row)
