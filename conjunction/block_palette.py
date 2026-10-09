"""The sidebar of the quest graph (docs/SESSION_PLAN_0510.md, step 4): every block one can add - the simple ones
first, by what they are for (Story flow, Wait until, Check, Facts, Journal ...), then the game's own: every block
class, every condition to wait for or check, every quest function, every action a person can be given - with a
search over names and explanations. A block is dragged onto the graph, or double clicked (it lands in the middle
of what is in sight); the line under the list says what the hovered one does.

    pal = BlockPalette()            pal.chosen(entry): double clicked; entry dragged: MIME "application/x-cj-block"
    entry: ("kind", kind id) | ("block", class) | ("wait", condition class) | ("if", condition class)
           | ("fn", function name) | ("ai", action class)
"""
import json

from PySide6 import QtCore, QtGui, QtWidgets

from . import blocks

MIME = "application/x-cj-block"
STYLE = (
    "QWidget#palette{background:#18181b}"
    "QTreeWidget{background:#18181b;color:#d8d8dc;border:none;font:12px}"
    "QTreeWidget::item{padding:2px 0}"
    "QLabel#help{color:#a8a8b0;font:11px;padding:6px;background:#1f1f23;border-top:1px solid #333}")


def game_entries(catalog):
    """[(section, [(label, entry, explanation)])] of the game's own blocks, conditions, functions, actions - the most
    used first."""
    from .game_catalog import label
    cls = catalog.get("classes") or {}
    simple_blocks = {k.cls for k in blocks.KINDS if not k.cond and not k.fn}
    simple_fns = {f for k in blocks.KINDS for f in k.fn}

    def by_count(names):
        return sorted(names, key=lambda n: -(cls.get(n, {}).get("count") or 0))
    out = []
    bl = by_count(n for n, c in cls.items() if c.get("role") == "block" and n not in simple_blocks
                  and n not in (blocks.W, blocks.I, blocks.S, blocks.A))
    out.append(("Other blocks", [(label(n), ("block", n), cls[n].get("doc") or n) for n in bl]))
    conds = by_count(n for n, c in cls.items() if c.get("role") == "condition")
    out.append(("Wait for any condition", [(label(n), ("wait", n), n) for n in conds]))
    out.append(("Check any condition", [(label(n), ("if", n), n) for n in conds]))
    fns = catalog.get("functions") or {}
    names = sorted((n for n in fns if n not in simple_fns), key=lambda n: (-(fns[n].get("count") or 0), n))
    out.append(("Game functions", [(fns[n].get("label") or n, ("fn", n),
                                    f"{n}({', '.join(p['name'] for p in fns[n].get('params') or [])})"
                                    + (f" - used {fns[n]['count']} times in the game" if fns[n].get("count") else ""))
                                   for n in names]))
    ais = by_count(n for n, c in cls.items() if c.get("role") == "ai")
    out.append(("Actions for a person", [(label(n), ("ai", n), n) for n in ais]))
    return out


class _Tree(QtWidgets.QTreeWidget):
    def mimeData(self, items):
        md = QtCore.QMimeData()
        entry = items[0].data(0, QtCore.Qt.UserRole) if items else None
        if entry:
            md.setData(MIME, json.dumps(entry).encode())
        return md

    def mimeTypes(self):
        return [MIME]


class BlockPalette(QtWidgets.QWidget):
    chosen = QtCore.Signal(object)

    def __init__(self, catalog=None):
        super().__init__()
        self.setObjectName("palette")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        self.setStyleSheet(STYLE)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(4)
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText("Search blocks (wait, fact, door, spawn)")
        self.search.textChanged.connect(self.filter)
        v.addWidget(self.search)
        self.tree = _Tree()
        self.tree.setHeaderHidden(True)
        self.tree.setIndentation(12)
        self.tree.setDragEnabled(True)
        self.tree.setDragDropMode(QtWidgets.QAbstractItemView.DragOnly)
        self.tree.setMouseTracking(True)
        self.tree.itemEntered.connect(self._hover)
        self.tree.currentItemChanged.connect(lambda cur, _prev: self._hover(cur))
        self.tree.itemDoubleClicked.connect(self._double)
        v.addWidget(self.tree, 1)
        self.help = QtWidgets.QLabel("Drag a block onto the graph or double click it")
        self.help.setObjectName("help")
        self.help.setWordWrap(True)
        self.help.setMinimumHeight(64)
        self.help.setAlignment(QtCore.Qt.AlignTop | QtCore.Qt.AlignLeft)
        v.addWidget(self.help)
        self._catalog = catalog
        self.fill()

    @property
    def catalog(self):
        if self._catalog is None:
            from . import game_catalog
            self._catalog = game_catalog.load() or {}
        return self._catalog

    def fill(self):
        t = self.tree
        t.clear()
        bold = QtGui.QFont()
        bold.setBold(True)
        from . import custom_blocks
        top = QtWidgets.QTreeWidgetItem(["Blocks"])     # a custom block, empty, and one's templates
        top.setFont(0, bold)
        top.setForeground(0, QtGui.QColor("#f0f0f2"))
        top.setFlags(QtCore.Qt.ItemIsEnabled)
        t.addTopLevelItem(top)
        it = QtWidgets.QTreeWidgetItem(["Custom block (empty)"])
        it.setData(0, QtCore.Qt.UserRole, ["kind", "phase"])
        it.setData(0, QtCore.Qt.UserRole + 1, "A block of your own: double click it to open it and build inside with "
                                              "the game's blocks; its Input and Output blocks are its ways in and "
                                              "out. Its card: 'Save as template' makes it a block here.")
        top.addChild(it)
        for tpl in custom_blocks.templates():
            it = QtWidgets.QTreeWidgetItem([tpl["label"]])
            it.setData(0, QtCore.Qt.UserRole, ["template", tpl["id"]])
            it.setData(0, QtCore.Qt.UserRole + 1, tpl.get("text") or "A block of your own.")
            it.setToolTip(0, tpl.get("text") or "")
            top.addChild(it)
        top.setExpanded(True)
        for gid, gname in blocks.GROUPS:
            if gid == "game":
                continue
            kinds = [k for k in blocks.KINDS if k.group == gid]
            if not kinds:
                continue
            top = QtWidgets.QTreeWidgetItem([gname])
            top.setFont(0, bold)
            top.setForeground(0, QtGui.QColor(blocks.GROUP_COLOUR[gid]))
            top.setFlags(QtCore.Qt.ItemIsEnabled)
            t.addTopLevelItem(top)
            for k in kinds:
                it = QtWidgets.QTreeWidgetItem([k.label])
                it.setData(0, QtCore.Qt.UserRole, ["kind", k.id])
                it.setData(0, QtCore.Qt.UserRole + 1, k.text)
                it.setToolTip(0, k.text)
                top.addChild(it)
            top.setExpanded(gid in ("flow", "wait", "check"))
        game = QtWidgets.QTreeWidgetItem(["Game blocks (all of them)"])
        game.setFont(0, bold)
        game.setForeground(0, QtGui.QColor("#9a9aa4"))
        game.setFlags(QtCore.Qt.ItemIsEnabled)
        t.addTopLevelItem(game)
        for section, entries in game_entries(self.catalog):
            sec = QtWidgets.QTreeWidgetItem([f"{section} ({len(entries)})"])
            sec.setFlags(QtCore.Qt.ItemIsEnabled)
            sec.setForeground(0, QtGui.QColor("#b4b4bc"))
            game.addChild(sec)
            for label, entry, text in entries:
                it = QtWidgets.QTreeWidgetItem([label])
                it.setData(0, QtCore.Qt.UserRole, list(entry))
                it.setData(0, QtCore.Qt.UserRole + 1, text)
                it.setToolTip(0, text)
                sec.addChild(it)

    def filter(self, text):
        words = text.lower().split()

        def visit(item):
            entry = item.data(0, QtCore.Qt.UserRole)
            if entry:
                hay = " ".join([item.text(0), str(item.data(0, QtCore.Qt.UserRole + 1) or ""), entry[1]]).lower()
                show = all(w in hay for w in words)
                item.setHidden(not show)
                return show
            any_child = False
            for k in range(item.childCount()):
                any_child |= visit(item.child(k))
            item.setHidden(bool(words) and not any_child)
            if words and any_child:
                item.setExpanded(True)
            return any_child
        for k in range(self.tree.topLevelItemCount()):
            visit(self.tree.topLevelItem(k))
        if not words:
            self.fill()

    def _hover(self, item):
        if item is None:
            return
        text = item.data(0, QtCore.Qt.UserRole + 1)
        entry = item.data(0, QtCore.Qt.UserRole)
        if text:
            used = ""
            if entry and entry[0] == "kind":
                if not hasattr(self, "_examples"):
                    from . import block_examples
                    self._examples = block_examples.load() or {}
                ex = self._examples.get(entry[1]) or {}
                if ex.get("count"):
                    used = f"<br><span style='color:#7c7c84'>The game uses it {ex['count']} times in " \
                           f"{ex['files']} quest files.</span>"
            self.help.setText(f"<b>{item.text(0)}</b><br>{text}{used}")

    def _double(self, item, _col):
        entry = item.data(0, QtCore.Qt.UserRole)
        if entry:
            self.chosen.emit(tuple(entry))
