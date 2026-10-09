"""In this quest - a window of its own (Maxim 02.10.: the list folded out on the Quest tab was cramped): the quest's
people, things and items in three lists, each with where it is and the steps that use it.

- a person / a thing: double click (or its arrow) flies there; a step number opens that step's card
- an own item: its name edited in place; removed by its bin (asks once more: it goes out of the steps too)
- a filter field over all three
"""
from PySide6 import QtCore, QtGui, QtWidgets

from .icons import icon
from .tooltips import tip

STYLE = """
QWidget#cast{background:#232326;color:#ddd;font:12px}
QLabel{color:#ddd;background:transparent}
QLabel#kind{color:#8a8a8a;font:bold 11px;padding:8px 0 2px 0}
QLabel#grey{color:#9a9a9a;font:11px}
QFrame#row{background:#1c1c1f;border:1px solid #303034;border-radius:0}
QFrame#row:hover{border-color:#5a5a60}
QToolButton#step{background:#2e2e33;color:#ddd;border:1px solid #4a4a50;border-radius:0;padding:1px 6px;font:11px}
QToolButton#step:hover{border-color:#999}
QToolButton#icon{background:transparent;border:none;padding:2px}
QToolButton#icon:hover{background:#3a3a3e}
QToolButton#danger{background:#5a2626;color:#fff;border:1px solid #8a3a3a;border-radius:0;padding:1px 8px}
QScrollArea{background:#232326;border:none}
"""


class CastWindow(QtWidgets.QWidget):
    """The body; its window is one of the catalog's (Panel.cast_window)."""

    def __init__(self, board):
        super().__init__()
        self.board = board
        self.setObjectName("cast")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        self.setStyleSheet(STYLE)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(4, 2, 4, 4)
        self.head = QtWidgets.QLabel()
        self.head.setStyleSheet("font:bold 14px;color:#eeeeee")
        v.addWidget(self.head)
        self.filter = QtWidgets.QLineEdit()
        self.filter.setPlaceholderText("filter")
        self.filter.textChanged.connect(lambda _t: self.fill())
        v.addWidget(self.filter)
        self.area = QtWidgets.QScrollArea()
        self.area.setWidgetResizable(True)
        self.area.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        v.addWidget(self.area, 1)
        self.asking = None              # the item whose bin was pressed once (the next press removes it)

    # --- what the quest has
    def counts(self):
        people, things, items = self._gather()
        return len(people), len(things), len(items)

    def _gather(self):
        from .item_chooser import _names, numbered_steps, quest_item_refs
        from .quest import is_actor
        b = self.board
        q = b.quest()
        steps = numbered_steps(q)
        people, things = [], []
        for place, p in b.ed.project.places.items():
            for k, o in enumerate(p.get("objects", [])):
                if o.get("trail"):
                    continue
                ref = f"{place}/{o.get('id')}" if o.get("id") else None
                name = (o.get("display") or o.get("id") or o["template"].rsplit("\\", 1)[-1].rsplit(".", 1)[0])
                uses = [(n, st) for n, st in steps if ref and _names(st, ref)]
                (people if is_actor(o) else things).append(
                    {"name": name.replace("_", " "), "place": place, "index": k, "ref": ref, "uses": uses})
        items = [{"ref": r, "uses": [(n, st) for n, st in steps if _names(st, r)]} for r in quest_item_refs(q)]
        return people, things, items

    def fill(self):
        from .item_chooser import item_label, puts_in
        b = self.board
        q = b.quest()
        people, things, items = self._gather()
        self.head.setText(f"{len(people)} people, {len(things)} things, {len(items)} items")
        want = self.filter.text().strip().lower()
        body = QtWidgets.QWidget()
        body.setObjectName("cast")
        lay = QtWidgets.QVBoxLayout(body)
        lay.setContentsMargins(0, 0, 4, 0)
        lay.setSpacing(4)
        for title, rows in (("PEOPLE", people), ("THINGS", things)):
            shown = [r for r in rows if not want or want in r["name"].lower() or want in r["place"].lower()]
            head = QtWidgets.QLabel(f"{title}  {len(shown)}")
            head.setObjectName("kind")
            lay.addWidget(head)
            for r in shown:
                extra = ""
                if title == "THINGS" and r["ref"]:
                    put = puts_in(q, r["ref"])
                    if put:
                        extra = "holds " + ", ".join(item_label(x, q, b.assets()) for _n, x in put)
                lay.addWidget(self._row(r["name"], r["place"] + (f"  ·  {extra}" if extra else ""), r["uses"],
                                        go=lambda _c=False, r=r: b.ed.jump_to(r["place"], r["index"])))
        shown = [r for r in items if not want or want in item_label(r["ref"], q, b.assets()).lower()]
        head = QtWidgets.QLabel(f"ITEMS  {len(shown)}")
        head.setObjectName("kind")
        lay.addWidget(head)
        for r in shown:
            if r["ref"].startswith("own:"):
                lay.addWidget(self._own_row(r["ref"][4:], r["uses"]))
            else:
                lay.addWidget(self._row(item_label(r["ref"], q, b.assets()), "the game's", r["uses"]))
        lay.addStretch(1)
        old = self.area.takeWidget()
        if old is not None:
            old.deleteLater()
        self.area.setWidget(body)

    def _steps(self, h, uses):
        """The step numbers, each a button that opens its card (an action has no number: its kind)."""
        if not uses:
            g = QtWidgets.QLabel("Not in a step")
            g.setObjectName("grey")
            h.addWidget(g)
        for n, st in uses:
            s = QtWidgets.QToolButton()
            s.setObjectName("step")
            s.setText(f"step {n}" if isinstance(n, int) else str(n))
            s.setCursor(QtCore.Qt.PointingHandCursor)
            s.clicked.connect(lambda _c=False, st=st: self._open_step(st))
            tip(s, "cast.step")
            h.addWidget(s)

    def _row(self, name, where, uses, go=None):
        row = QtWidgets.QFrame()
        row.setObjectName("row")
        v = QtWidgets.QVBoxLayout(row)
        v.setContentsMargins(8, 5, 6, 5)
        v.setSpacing(3)
        top = QtWidgets.QHBoxLayout()
        lab = QtWidgets.QLabel(name)
        lab.setStyleSheet("font:bold 12px;color:#f0f0f0")
        top.addWidget(lab)
        g = QtWidgets.QLabel(where)
        g.setObjectName("grey")
        top.addWidget(g, 1)
        if go:
            b = QtWidgets.QToolButton()
            b.setObjectName("icon")
            b.setIcon(icon("crosshair"))
            b.clicked.connect(go)
            tip(b, "cast.go")
            top.addWidget(b)
            row.mouseDoubleClickEvent = lambda _e, go=go: go()
        v.addLayout(top)
        h = QtWidgets.QHBoxLayout()
        h.setSpacing(4)
        self._steps(h, uses)
        h.addStretch(1)
        v.addLayout(h)
        return row

    def _own_row(self, iid, uses):
        b = self.board
        q = b.quest()
        it = (q.get("items") or {}).get(iid) or {}
        row = QtWidgets.QFrame()
        row.setObjectName("row")
        v = QtWidgets.QVBoxLayout(row)
        v.setContentsMargins(8, 5, 6, 5)
        v.setSpacing(3)
        top = QtWidgets.QHBoxLayout()
        field = QtWidgets.QLineEdit(it.get("name", iid))
        field.editingFinished.connect(lambda f=field, it=it: f.text().strip() and f.text().strip() != it.get("name")
                                      and b._set_in(it, "name", f.text().strip(), rebuild=False))
        tip(field, "qb.own_name")
        top.addWidget(field, 1)
        g = QtWidgets.QLabel("Made for this quest")
        g.setObjectName("grey")
        top.addWidget(g)
        if self.asking == iid:
            rm = QtWidgets.QToolButton()
            rm.setObjectName("danger")
            rm.setText(f"Remove from {len(uses)} step{'s' * (len(uses) != 1)}?" if uses else "Remove?")
            rm.clicked.connect(lambda _c=False: self._remove(iid))
        else:
            rm = QtWidgets.QToolButton()
            rm.setObjectName("icon")
            rm.setIcon(icon("trash-2"))
            rm.clicked.connect(lambda _c=False: self._ask(iid))
        tip(rm, "qb.own_remove")
        top.addWidget(rm)
        v.addLayout(top)
        h = QtWidgets.QHBoxLayout()
        h.setSpacing(4)
        self._steps(h, uses)
        h.addStretch(1)
        v.addLayout(h)
        return row

    def _ask(self, iid):
        self.asking = iid
        self.fill()

    def _remove(self, iid):
        self.asking = None
        self.board._remove_own(iid)
        self.fill()

    def _open_step(self, st):
        """The step's card on the Quest tab (the panel comes up there)."""
        b = self.board
        nid = b.node_of(st) if b.quest().get("nodes") else None
        panel = getattr(b.ed, "panel", None)
        if panel is not None:
            panel.tabs.setCurrentWidget(b)
            panel.show()
            panel.raise_()
        if nid is not None:
            b._graph_picked(nid)

    def showEvent(self, e):
        self.fill()
        super().showEvent(e)
