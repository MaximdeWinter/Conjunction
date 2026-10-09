"""A game quest graph on screen, editable (docs/VANILLA_EDITING_PLAN.md, steps 2 and 3): any of the game's 10 331
quest graphs, every block with what it does, its named inputs and outputs, its links; phases open in place, a phase
of another file opens that file; every property of the picked block on the right, objects under it (conditions, AI
actions) unfolded - and all of it changed.

    a click on a block              picked: its properties on the right, its links lit
    a block dragged                 moved (kept in the project)
    an output's square dragged      onto an input (or a block): linked
    a click on a link               picked; right click: remove it
    a right click on a block        open, duplicate, remove
    a right click on the graph      add a block (any of the game's block kinds), there
    a double click on a phase       into it (the trail above leads back)
    a double click on a value       changed (a yes/no flips); right click on a list: an item more / less
    Undo, Redo, Save, Revert        Save keeps the file in the project (game_files\\<its path>); the build puts it
                                    into the project's mod bundle. Revert: the game's file again
    Live                            the blocks the running game activates light up (green, fading over a few
                                    seconds; ever active since: a thin green edge) - TW3SE's questlive hook sends
                                    each activated block's GUID
    the wheel / a drag on the graph zoom / move; Fit: all of it in sight

    VanillaWindow(ed, path)         the window's body; open_path(path) shows another file
"""
import json
import os

from PySide6 import QtCore, QtGui, QtWidgets

from . import vanilla_graph as V
from .cr2w_tree import SIMPLE, Guid, Loc, Raw, Soft, Struct, Tags, Transform, Variant, Wide
from .tooltips import tip

BG, CARD, CARD_HOVER, BORDER = "#141417", "#24242a", "#2c2c34", "#3c3c42"
PICKED = "#d9a441"
WIRE = "#7a7a86"
WIRE_COLOUR = {"True": "#5cb85c", "False": "#c0504d"}
DETAIL_ZOOM = 0.45
PORT = 8                        # how near a port a press takes it
READ_ONLY = "a game file: read only (changing it: Settings > General > Experimental)"
LIVE = "#5cb85c"
LIVE_FADE = 4.0                 # s a block stays lit after the game activated it
LAYOUT = "game_layout.json"     # in the project: where blocks were dragged, by file and block GUID
STYLE = (
    "*{border-radius:0}"
    "QWidget#vg{background:#18181b}"
    "QGraphicsView{background:#141417;border:1px solid #333}"
    "QLabel{color:#c8c8cc;font:12px}"
    "QPushButton:checked{background:#24402a;border-color:#5cb85c;color:#e8f4e8}"
    "QPushButton#crumb{background:transparent;border:none;color:#a8a8ac;padding:3px 4px}"
    "QPushButton#crumb:hover{color:#f0f0f2}"
    "QMenu{background:#1f1f23;color:#ddd;border:1px solid #45454c}"
    "QMenu::item:selected{background:#2c2c34}")
CLIP = None                     # the blocks copied: {"src": file bytes, "ns": [block numbers], "at": {n: (x, y)}}
IMPORT_CLASS = {".w2scene": "CStoryScene", ".w2phase": "CQuestPhase", ".journal": "CJournalResource",
                ".w2comm": "CCommunity", ".w2behtree": "CBehTree", ".env": "CEnvironmentDefinition",
                ".w2ent": "CEntityTemplate"}


def _font(px, bold=False):
    f = QtGui.QFont("Segoe UI")
    f.setPixelSize(px)
    f.setBold(bold)
    return f


def ports_top(b):
    return V.HEAD + V.text_rows(b) * V.LINE


class BlockItem(QtWidgets.QGraphicsItem):
    def __init__(self, view, b):
        super().__init__()
        self.view, self.b = view, b
        self.setPos(b.x, b.y)
        self.setAcceptHoverEvents(True)
        self.setCursor(QtCore.Qt.PointingHandCursor)
        self.setFlag(QtWidgets.QGraphicsItem.ItemIsMovable, view.editable)
        self.setFlag(QtWidgets.QGraphicsItem.ItemIsSelectable, view.editable)
        self.setFlag(QtWidgets.QGraphicsItem.ItemSendsGeometryChanges, True)
        self.picked = self.hit = self.lit = False
        self.live_at = 0.0                              # when the game last activated it (0: not since Live)
        self._moved_from = None
        kind = getattr(b, "kind", None)
        self.setToolTip("\n".join([b.title + (f": {b.name}" if b.name else "")] + b.lines[:6] +
                                  ([f"comment: {b.comment}"] if b.comment else []) +
                                  ([kind.text] if kind is not None else [])))

    def boundingRect(self):
        return QtCore.QRectF(-6, -2, self.b.w + 12, self.b.h + 4)

    def itemChange(self, change, value):
        if change == QtWidgets.QGraphicsItem.ItemPositionHasChanged:
            self.b.x, self.b.y = int(self.pos().x()), int(self.pos().y())
        elif change == QtWidgets.QGraphicsItem.ItemSelectedHasChanged:
            self.update()
        return super().itemChange(change, value)

    def port_at(self, pos):
        """("in" | "out", socket name) of the port at a point of the block (its own coordinates), or None."""
        b, top = self.b, ports_top(self.b)
        for side, names, x in (("in", b.inputs, 0), ("out", b.outputs, b.w)):
            for k, name in enumerate(names):
                y = top + k * V.ROW + V.ROW / 2
                if abs(pos.x() - x) <= PORT and abs(pos.y() - y) <= V.ROW / 2:
                    return side, name
        return None

    def paint(self, p, opt, _w=None):
        b = self.b
        r = QtCore.QRectF(0, 0, b.w, b.h)
        colour = QtGui.QColor(V.FAMILY[b.family])
        lod = opt.levelOfDetailFromTransform(p.worldTransform())
        note = b.family in ("note", "notes")
        chosen = self.picked or self.isSelected()
        p.setPen(QtGui.QPen(QtGui.QColor(PICKED if chosen else "#e8e8e8" if self.hit else
                                         "#8a8a92" if self.lit else BORDER), 2 if chosen else 1,
                            QtCore.Qt.DashLine if self.isSelected() and not self.picked else QtCore.Qt.SolidLine))
        p.setBrush(QtGui.QColor("#2a2a22" if note else CARD_HOVER if self.isUnderMouse() else CARD))
        p.drawRect(r)
        if self.live_at:                                # the game ran it: green, strong while fresh
            import time as _t
            fresh = max(0.0, 1.0 - (_t.monotonic() - self.live_at) / LIVE_FADE)
            c = QtGui.QColor(LIVE)
            c.setAlpha(int(90 + 165 * fresh))
            p.setPen(QtGui.QPen(c, 1.5 + 2.5 * fresh))
            p.setBrush(QtCore.Qt.NoBrush)
            p.drawRect(r.adjusted(-3, -3, 3, 3))
        head = QtGui.QColor(colour)
        head.setAlpha(70)
        p.fillRect(QtCore.QRectF(0, 0, b.w, V.HEAD), head)
        p.fillRect(QtCore.QRectF(0, 0, 3, b.h), colour)
        if lod < DETAIL_ZOOM:                           # far out: its name big, readable from afar
            text = b.name if V.shows_name(b) else b.title
            px = int(max(10, min(13 / max(lod, 0.05), b.h * 0.4, 40)))
            p.setFont(_font(px, True))
            p.setPen(QtGui.QColor("#e8e8ec"))
            fm = QtGui.QFontMetrics(p.font())
            lines = max(1, int(b.h * 0.9 // fm.height()))
            p.drawText(r.adjusted(8, 2, -8, -2), QtCore.Qt.AlignCenter | QtCore.Qt.TextWordWrap,
                       fm.elidedText(text, QtCore.Qt.ElideRight, int((b.w - 16) * lines * 0.95)))
            return
        p.setFont(_font(12, True))
        p.setPen(QtGui.QColor("#f2f2f4"))
        fm = QtGui.QFontMetrics(p.font())
        p.drawText(QtCore.QRectF(9, 0, b.w - 16, V.HEAD), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter,
                   fm.elidedText(b.title, QtCore.Qt.ElideRight, b.w - 16))
        y = V.HEAD
        if V.shows_name(b):                             # the designer's name for it
            p.setFont(_font(11, True))
            p.setPen(QtGui.QColor("#ececf0"))
            fm = QtGui.QFontMetrics(p.font())
            p.drawText(QtCore.QRectF(9, y, b.w - 16, V.LINE), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter,
                       fm.elidedText(b.name, QtCore.Qt.ElideRight, b.w - 16))
            y += V.LINE
        p.setFont(_font(11))
        fm = QtGui.QFontMetrics(p.font())
        p.setPen(QtGui.QColor("#b4b4bc" if not note else "#e0dcc0"))
        for line in b.lines[:3 if not note else 8]:
            p.drawText(QtCore.QRectF(9, y, b.w - 16, V.LINE), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter,
                       fm.elidedText(line, QtCore.Qt.ElideRight, b.w - 16))
            y += V.LINE
        p.setFont(_font(10))
        fm = QtGui.QFontMetrics(p.font())
        y = ports_top(b)
        for k, name in enumerate(b.inputs):             # inputs at the left, outputs at the right
            yy = y + k * V.ROW
            p.fillRect(QtCore.QRectF(-4, yy + V.ROW / 2 - 4, 8, 8), QtGui.QColor("#9a9aa4"))
            if name:
                p.setPen(QtGui.QColor("#9a9aa0"))
                p.drawText(QtCore.QRectF(8, yy, b.w / 2 - 8, V.ROW), QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter,
                           fm.elidedText(name, QtCore.Qt.ElideRight, int(b.w / 2 - 10)))
        for k, name in enumerate(b.outputs):
            yy = y + k * V.ROW
            p.fillRect(QtCore.QRectF(b.w - 4, yy + V.ROW / 2 - 4, 8, 8),
                       QtGui.QColor(WIRE_COLOUR.get(name, "#9a9aa4")))
            if name:
                p.setPen(QtGui.QColor("#9a9aa0"))
                p.drawText(QtCore.QRectF(b.w / 2, yy, b.w / 2 - 8, V.ROW),
                           QtCore.Qt.AlignRight | QtCore.Qt.AlignVCenter,
                           fm.elidedText(name, QtCore.Qt.ElideRight, int(b.w / 2 - 10)))
        if b.opens:
            p.setPen(QtGui.QColor("#9a9aa0"))
            p.drawText(QtCore.QRectF(b.w - 26, 0, 20, V.HEAD), QtCore.Qt.AlignRight | QtCore.Qt.AlignVCenter, "»")

    def hoverEnterEvent(self, _e):
        self.view.light(self)

    def hoverLeaveEvent(self, _e):
        self.view.light(None)

    def mousePressEvent(self, e):
        if e.button() == QtCore.Qt.LeftButton:
            port = self.port_at(e.pos()) if self.view.editable else None
            if port and port[0] == "out":
                self.view.start_wire(self, port[1], e.scenePos())
                e.accept()
                return
            if not e.modifiers() & QtCore.Qt.ControlModifier:
                self.view.pick(self)
            self._moved_from = QtCore.QPointF(self.pos())
        super().mousePressEvent(e)
        if e.button() == QtCore.Qt.LeftButton:          # (what moves with it: the blocks chosen)
            self._group = {it: QtCore.QPointF(it.pos()) for it in self.scene().selectedItems() + [self]
                           if isinstance(it, BlockItem)}

    def mouseMoveEvent(self, e):
        super().mouseMoveEvent(e)
        if self._moved_from is not None:
            self.view.reroute()

    def mouseReleaseEvent(self, e):
        super().mouseReleaseEvent(e)
        if self._moved_from is not None:
            for it, was in getattr(self, "_group", {}).items():
                if it.pos() != was:
                    self.view.moved.emit(it.b.n, int(it.pos().x()), int(it.pos().y()))
        self._moved_from = None
        self._group = {}

    def mouseDoubleClickEvent(self, e):
        if self.b.opens:
            self.view.opened.emit(self.b.n)
        e.accept()


class WireItem(QtWidgets.QGraphicsPathItem):
    def __init__(self, link, pts):
        super().__init__()
        self.link = link
        self.set_points(pts)
        self.chosen = False
        self.setZValue(-1)
        self.setAcceptHoverEvents(True)

    def set_points(self, pts):
        path = QtGui.QPainterPath(QtCore.QPointF(*pts[0]))
        for pt in pts[1:]:
            path.lineTo(*pt)
        self.setPath(path)
        self.back = pts[1][0] - pts[0][0] < 20 and len(pts) > 4
        self.style()

    def style(self, lit=False):
        c = QtGui.QColor(PICKED if getattr(self, "chosen", False) else WIRE_COLOUR.get(self.link[1], WIRE))
        if lit:
            c = c.lighter(150)
        pen = QtGui.QPen(c, 2.6 if getattr(self, "chosen", False) or lit else 1.3,
                         QtCore.Qt.DashLine if self.back else QtCore.Qt.SolidLine)
        self.setPen(pen)

    def shape(self):
        s = QtGui.QPainterPathStroker()
        s.setWidth(9)
        return s.createStroke(self.path())


class GraphView(QtWidgets.QGraphicsView):
    picked = QtCore.Signal(object)          # the Block (None: nothing)
    opened = QtCore.Signal(int)             # a phase block's number
    moved = QtCore.Signal(int, int, int)    # block, x, y
    connect_req = QtCore.Signal(int, str, int, str)
    menu_req = QtCore.Signal(object, object, QtCore.QPointF)     # (block item | wire item | None), global pos, scene pos
    drop_req = QtCore.Signal(object, QtCore.QPointF)             # a sidebar entry dropped, where

    def __init__(self, editable=True):
        super().__init__()
        self.editable = editable
        self.setScene(QtWidgets.QGraphicsScene(self))
        self.setRenderHint(QtGui.QPainter.Antialiasing)
        self.setDragMode(QtWidgets.QGraphicsView.ScrollHandDrag)
        self.setTransformationAnchor(QtWidgets.QGraphicsView.AnchorUnderMouse)
        self.setBackgroundBrush(QtGui.QColor(BG))
        self.items_, self.wires, self.current, self.g = {}, [], None, None
        self.drag = None                    # a link being drawn: (block item, output, path item)
        self.chosen_wire = None
        self.setAcceptDrops(True)

    # --- a block dragged in from the sidebar
    def dragEnterEvent(self, e):
        from .block_palette import MIME
        if self.editable and e.mimeData().hasFormat(MIME):
            e.acceptProposedAction()
        else:
            super().dragEnterEvent(e)

    def dragMoveEvent(self, e):
        from .block_palette import MIME
        if self.editable and e.mimeData().hasFormat(MIME):
            e.acceptProposedAction()
        else:
            super().dragMoveEvent(e)

    def dropEvent(self, e):
        from .block_palette import MIME
        if self.editable and e.mimeData().hasFormat(MIME):
            entry = tuple(json.loads(bytes(e.mimeData().data(MIME)).decode()))
            self.drop_req.emit(entry, self.mapToScene(e.position().toPoint()))
            e.acceptProposedAction()
        else:
            super().dropEvent(e)

    def show_graph(self, g):
        sc = self.scene()
        sc.clear()
        self.g, self.items_, self.wires, self.current, self.drag, self.chosen_wire = g, {}, [], None, None, None
        for link, pts in g.wires:
            w = WireItem(link, pts)
            sc.addItem(w)
            self.wires.append(w)
        for b in g.blocks.values():
            it = BlockItem(self, b)
            sc.addItem(it)
            self.items_[b.n] = it
        self.grow()

    def grow(self):
        sc = self.scene()
        sc.setSceneRect(sc.itemsBoundingRect().adjusted(-400, -300, 400, 300))

    def reroute(self):
        """The links again after a block moved."""
        V.route(self.g)
        by = {link: pts for link, pts in self.g.wires}
        for w in self.wires:
            if w.link in by:
                w.set_points(by[w.link])

    def light(self, item):
        """A block's links stand out while the mouse is on it (and the picked one's while nothing is)."""
        item = item or self.current
        n = item.b.n if item else None
        ends = set()
        for w in self.wires:
            mine = n is not None and n in (w.link[0], w.link[2])
            w.style(lit=mine)
            w.setZValue(-0.5 if mine or w.chosen else -1)
            if mine:
                ends |= {w.link[0], w.link[2]}
        for k, it in self.items_.items():
            if (k in ends) != it.lit:
                it.lit = k in ends
                it.update()

    def pick(self, item):
        if self.current is not None:
            self.current.picked = False
            self.current.update()
        self.current = item
        if item is not None:
            item.picked = True
            item.update()
        self.choose_wire(None)
        self.light(None)
        self.picked.emit(item.b if item else None)

    def choose_wire(self, w):
        if self.chosen_wire is not None:
            self.chosen_wire.chosen = False
            self.chosen_wire.style()
        self.chosen_wire = w
        if w is not None:
            w.chosen = True
            w.style()

    def chosen(self):
        """The blocks chosen (a frame, Ctrl+click) - else the one picked. -> block numbers."""
        sel = [it.b.n for it in self.scene().selectedItems() if isinstance(it, BlockItem)]
        if not sel and self.current is not None:
            sel = [self.current.b.n]
        return sel

    def pick_n(self, n):
        it = self.items_.get(n) or self.items_.get(getattr(self, "fold_of", {}).get(n))    # (in a template's block)
        if it is not None:
            self.pick(it)
        return it

    def find(self, words):
        """The blocks whose title, name, comment or lines hold the words: marked, the first in sight."""
        words = words.lower().strip()
        self.hits = []
        for it in sorted(self.items_.values(), key=lambda it: (it.b.y, it.b.x)):
            b = it.b
            text = " ".join([b.title, b.name, b.comment] + b.lines).lower()
            it.hit = bool(words) and words in text
            it.update()
            if it.hit:
                self.hits.append(it)
        self.hit_at = 0
        if self.hits:
            self.centerOn(self.hits[0])
        return self.hits[0] if self.hits else None

    def find_next(self):
        """Enter in the search: the next block found, in sight and picked."""
        hits = getattr(self, "hits", [])
        if not hits:
            return None
        self.hit_at = (getattr(self, "hit_at", 0) + 1) % len(hits)
        it = hits[self.hit_at]
        self.centerOn(it)
        self.pick(it)
        return it

    def fit(self):
        self.fitInView(self.scene().itemsBoundingRect(), QtCore.Qt.KeepAspectRatio)
        if self.transform().m11() > 1.0:
            self.resetTransform()

    def wheelEvent(self, e):
        k = 1.15 if e.angleDelta().y() > 0 else 1 / 1.15
        if 0.08 <= self.transform().m11() * k <= 2.5:
            self.scale(k, k)

    # --- a link drawn by hand
    def start_wire(self, item, output, at):
        line = self.scene().addPath(QtGui.QPainterPath(), QtGui.QPen(QtGui.QColor(PICKED), 1.6, QtCore.Qt.DashLine))
        line.setZValue(5)
        self.drag = (item, output, line)
        self.setDragMode(QtWidgets.QGraphicsView.NoDrag)
        self._draw_drag(at)

    def _draw_drag(self, at):
        item, output, line = self.drag
        x0, y0 = V.out_port(item.b, output)
        path = QtGui.QPainterPath(QtCore.QPointF(x0, y0))
        mx = max(x0 + 20, (x0 + at.x()) / 2)
        path.lineTo(mx, y0)
        path.lineTo(mx, at.y())
        path.lineTo(at)
        line.setPath(path)

    def _block_at(self, scene_pt):
        for it in self.scene().items(scene_pt):
            if isinstance(it, BlockItem):
                return it
        return None

    def _wire_at(self, scene_pt):
        for it in self.scene().items(scene_pt):
            if isinstance(it, WireItem):
                return it
        return None

    def mousePressEvent(self, e):
        sp = self.mapToScene(e.position().toPoint())
        on_block = self._block_at(sp)
        wire = None if on_block else self._wire_at(sp)
        if e.button() == QtCore.Qt.LeftButton and wire is not None:
            self.pick(None)
            self.choose_wire(wire)
            e.accept()
            return
        self._press = e.position().toPoint() if on_block is None else None
        if on_block is None and e.button() == QtCore.Qt.LeftButton and e.modifiers() & QtCore.Qt.ShiftModifier:
            self.setDragMode(QtWidgets.QGraphicsView.RubberBandDrag)      # a frame: the blocks in it chosen
        super().mousePressEvent(e)

    def mouseMoveEvent(self, e):
        if self.drag:
            self._draw_drag(self.mapToScene(e.position().toPoint()))
            return
        super().mouseMoveEvent(e)

    def mouseReleaseEvent(self, e):
        if self.drag:
            item, output, line = self.drag
            self.scene().removeItem(line)
            self.drag = None
            self.setDragMode(QtWidgets.QGraphicsView.ScrollHandDrag)
            sp = self.mapToScene(e.position().toPoint())
            target = self._block_at(sp)
            if target is not None and target is not item and (target.b.inputs or output == "Thunder"):
                port = target.port_at(target.mapFromScene(sp))
                put = port[1] if port and port[0] == "in" else (target.b.inputs or ["In"])[0]
                if output == "Thunder" and "Cut" in V.sockets(target.b.cls)[0]:
                    put = "Cut"                         # (a stop wired: into the block's Cut)
                self.connect_req.emit(item.b.n, output, target.b.n, put)
            return
        press, self._press = getattr(self, "_press", None), None
        super().mouseReleaseEvent(e)
        if self.dragMode() == QtWidgets.QGraphicsView.RubberBandDrag:
            self.setDragMode(QtWidgets.QGraphicsView.ScrollHandDrag)
            return
        if press is not None and (e.position().toPoint() - press).manhattanLength() < 4:
            if self.current:
                self.pick(None)                         # a click on the empty graph: nothing picked
            self.scene().clearSelection()
            self.choose_wire(None)

    def contextMenuEvent(self, e):
        sp = self.mapToScene(e.pos())
        target = self._block_at(sp) or self._wire_at(sp)
        if isinstance(target, WireItem):
            self.choose_wire(target)
        elif isinstance(target, BlockItem):
            self.pick(target)
        self.menu_req.emit(target, e.globalPos(), sp)


class VanillaWindow(QtWidgets.QWidget):
    """A game quest graph: the trail, the edit buttons and the search above, the graph, the picked block's
    properties at the right."""

    def __init__(self, ed, path=None, depot=None, project_dir=None):
        super().__init__()
        self.ed = ed
        self._depot = depot
        proj = getattr(ed, "project", None)
        self.project_dir = project_dir or (getattr(proj, "path", None) if proj is not None else None)
        self.editors, self.trail = {}, []               # trail: [(path, phase block GUID or None, label)]
        self.layout_ = self._load_layout()
        self.setObjectName("vg")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        self.setStyleSheet(STYLE)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 0, 0, 0)
        top = QtWidgets.QHBoxLayout()
        self.crumbs = QtWidgets.QHBoxLayout()
        self.crumbs.setSpacing(0)
        top.addLayout(self.crumbs)
        top.addStretch(1)
        self.state = QtWidgets.QLabel("")
        top.addWidget(self.state)
        self.buttons = {}
        self.live = QtWidgets.QPushButton("Live")
        self.live.setCheckable(True)
        self.live.toggled.connect(self.set_live)
        tip(self.live, "vg.live")
        top.addWidget(self.live)
        self.folding = QtWidgets.QPushButton("Templates")   # the translator: blocks read as templates (view only)
        self.folding.setCheckable(True)
        self.folding.setChecked(True)
        self.folding.toggled.connect(lambda _on: (self.unfolded.clear(), self.show_current()))
        tip(self.folding, "vg.templates")
        top.addWidget(self.folding)
        self.unfolded = set()                           # GUIDs of first blocks of templates shown as their blocks
        self.fold_of = {}                               # a block of a template's block -> that block's number
        self.follow = QtWidgets.QPushButton("Follow")   # with Live: the graph goes where the game is
        self.follow.setCheckable(True)
        tip(self.follow, "vg.follow")
        top.addWidget(self.follow)
        self.live_seen = {}                             # GUID -> when the game last activated it
        self.live_timer = QtCore.QTimer(self)
        self.live_timer.timeout.connect(self.live_tick)
        for key, label in (("undo", "Undo"), ("redo", "Redo"), ("save", "Save"), ("revert", "Revert")):
            b = QtWidgets.QPushButton(label)
            b.clicked.connect(getattr(self, key))
            tip(b, f"vg.{key}")
            top.addWidget(b)
            self.buttons[key] = b
        top.addSpacing(8)
        self.opener = QtWidgets.QLineEdit()             # any quest file of the game, by a part of its name
        self.opener.setPlaceholderText("Open a game quest...")
        self.opener.setFixedWidth(220)
        self.opener.returnPressed.connect(self._open_typed)
        tip(self.opener, "vg.open")
        self._opener_ready = False
        self.opener.installEventFilter(self)
        top.addWidget(self.opener)
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText("Find a block")
        self.search.setFixedWidth(220)
        self.search.textChanged.connect(lambda t: self.view.find(t))
        self.search.returnPressed.connect(lambda: self.view.find_next())
        tip(self.search, "vg.search")
        top.addWidget(self.search)
        fit = QtWidgets.QPushButton("Fit")
        fit.clicked.connect(lambda: self.view.fit())
        tip(fit, "vg.fit")
        top.addWidget(fit)
        book = QtWidgets.QPushButton("Handbook")
        book.clicked.connect(self.handbook)
        tip(book, "vg.handbook")
        top.addWidget(book)
        v.addLayout(top)
        self.tips = self._tips_bar()                    # the first steps, until closed once
        if self.tips is not None:
            v.addWidget(self.tips)
        split = QtWidgets.QSplitter()
        from .block_card import BlockCard
        from .block_palette import BlockPalette
        self.palette = BlockPalette()
        self.palette.chosen.connect(lambda entry: self.add_entry(entry, None))
        split.addWidget(self.palette)
        self.view = GraphView()
        self.view.picked.connect(self.show_block)
        self.view.opened.connect(self.open_block)
        self.view.moved.connect(self.block_moved)
        self.view.connect_req.connect(self.link)
        self.view.menu_req.connect(self.menu)
        self.view.drop_req.connect(self.add_entry)
        split.addWidget(self.view)
        side = QtWidgets.QWidget()
        sv = QtWidgets.QVBoxLayout(side)
        sv.setContentsMargins(0, 0, 0, 0)
        self.head = QtWidgets.QLabel()
        self.head.setWordWrap(True)
        self.head.setTextFormat(QtCore.Qt.RichText)
        sv.addWidget(self.head)
        self.tabs = QtWidgets.QTabWidget()
        self.tabs.setStyleSheet("QTabWidget::pane{border:none}QTabBar::tab{background:#1f1f23;color:#9a9aa0;"
                                "padding:4px 12px;border:none}QTabBar::tab:selected{background:#2c2c34;color:#f0f0f2}")
        self.card = BlockCard(self)
        self.tabs.addTab(self.card, "Block")
        sv.addWidget(self.tabs, 1)
        self.props = QtWidgets.QTreeWidget()
        self.props.setHeaderLabels(["Property", "Value", "Type"])
        self.props.setColumnWidth(0, 150)
        self.props.setColumnWidth(1, 220)
        self.props.itemDoubleClicked.connect(self._prop_double)
        self.props.setContextMenuPolicy(QtCore.Qt.CustomContextMenu)
        self.props.customContextMenuRequested.connect(self._prop_menu)
        self.tabs.addTab(self.props, "All values")
        self._props_of = None
        self.tabs.currentChanged.connect(lambda _i: self.tabs.currentWidget() is self.props and
                                         self._props_of is not None and self._fill_props(self._props_of))
        split.addWidget(side)
        split.setStretchFactor(0, 0)
        split.setStretchFactor(1, 3)
        split.setStretchFactor(2, 1)
        split.setSizes([250, 1050, 400])
        v.addWidget(split, 1)
        for keys, fn in (("Ctrl+C", self.copy), ("Ctrl+V", self.paste), ("Ctrl+D", self.duplicate_chosen),
                         ("Delete", self.remove_chosen), ("Ctrl+A", self.choose_all), ("Ctrl+Z", self.undo),
                         ("Ctrl+Y", self.redo), ("Ctrl+S", self.save)):
            sc = QtGui.QShortcut(QtGui.QKeySequence(keys), self)
            sc.setContext(QtCore.Qt.WidgetWithChildrenShortcut)
            sc.activated.connect(fn)
        if path:
            self.open_path(path)

    @property
    def depot(self):
        if self._depot is None:
            from .bundles import Depot
            self._depot = Depot()
        return self._depot

    # --- files and where we are in them
    def editor(self, path):
        if path not in self.editors:
            from .vanilla_edit import GAME_FILES, OWN_FILE, Editor, own_quest_data
            rel, data, base = own_quest_data(self.project_dir) if self.project_dir else (None, None, None)
            if rel and os.path.normcase(rel) == os.path.normcase(path):     # the project's own quest
                from . import blocks
                from .journal_index import own_objectives
                blocks.OWN_CAPTIONS.update({o["guid"]: o["caption"] for o in own_objectives(self.project_dir)})
                self.editors[path] = Editor(self.depot, path, self.project_dir, base=base,
                                            data=data if data is not None else base,
                                            own=os.path.join(self.project_dir, GAME_FILES, OWN_FILE))
            else:
                self.editors[path] = Editor(self.depot, path, self.project_dir)
        return self.editors[path]

    def eventFilter(self, obj, ev):
        if obj is getattr(self, "opener", None) and ev.type() == QtCore.QEvent.FocusIn and not self._opener_ready:
            self._quest_files()                         # (the list made at the first use)
        return super().eventFilter(obj, ev)

    def _quest_files(self):
        """{label: path} of every quest file of the game - its completer."""
        if not self._opener_ready:
            from .story import game_file
            self._files = {}
            for p in sorted(p for p in self.depot.where if p.endswith((".w2phase", ".w2quest")) and game_file(p)):
                self._files[f"{os.path.splitext(os.path.basename(p))[0]}   ({os.path.dirname(p)})"] = p
            comp = QtWidgets.QCompleter(list(self._files), self.opener)
            comp.setCaseSensitivity(QtCore.Qt.CaseInsensitive)
            comp.setFilterMode(QtCore.Qt.MatchContains)
            comp.setMaxVisibleItems(16)
            comp.activated.connect(lambda text: self._open_typed(text))
            self.opener.setCompleter(comp)
            self._opener_ready = True
        return self._files

    def _open_typed(self, text=None):
        """The quest file chosen (or the first whose name holds what is typed) opened."""
        files = self._quest_files()
        text = (text or self.opener.text()).strip()
        path = files.get(text) or next((p for k, p in files.items() if text.lower() in k.lower()), None)
        if path:
            self.open_path(path)
            self.opener.clear()
        return path

    def open_own_quest(self):
        """The project's own quest in the graph (as the last build encoded it, with the graph's changes). -> False
        before the first build."""
        from .vanilla_edit import own_quest
        rel, _built = own_quest(self.project_dir)
        if not rel:
            self.state.setText("Build the quest once, then it opens here")
            self._not_built()
            return False
        self.open_path(rel)
        return True

    def _not_built(self):
        """The graph's middle before the quest's first build: what to do, and a button that does it."""
        sc = self.view.scene()
        sc.clear()
        self.view.items_, self.view.wires = {}, []
        box = QtWidgets.QWidget()
        box.setStyleSheet("QWidget{background:transparent}QLabel{color:#c8c8cc;font:13px}"
                          "QPushButton{color:#eee;background:#2c2c30;border:1px solid #d9a441;padding:6px 16px}")
        v = QtWidgets.QVBoxLayout(box)
        lab = QtWidgets.QLabel("This quest has not been built yet.\n\nBuild it once to see and change every "
                               "block the game will run.\nUntil then: the quest board.")
        lab.setAlignment(QtCore.Qt.AlignCenter)
        v.addWidget(lab)
        go = QtWidgets.QPushButton("Build now")
        go.setEnabled(bool(self.ed is not None and getattr(self.ed, "panel", None)))
        go.clicked.connect(self._build_now)
        v.addWidget(go, 0, QtCore.Qt.AlignCenter)
        proxy = sc.addWidget(box)
        proxy.setPos(0, 0)
        self.view.resetTransform()
        self.view.centerOn(proxy)
        self.not_built = proxy
        self.trail = []
        self.sync_buttons()

    def _build_now(self):
        """The quest built (Build & Play: a check builds nothing to keep); the graph opens when it is done."""
        panel = self.ed.panel
        panel._build(True)
        timer = QtCore.QTimer(self)

        def poll():
            if panel.b_play.isEnabled() and panel.b_check.isEnabled():
                timer.stop()
                if self.open_own_quest():
                    self.state.setText("Built. Every block of the quest is here")
        timer.timeout.connect(poll)
        timer.start(1500)
        self.state.setText("Building... (progress in the Build tab)")

    def here(self):
        """(editor, QuestFile, graph object number) of the graph shown."""
        path, holder, _label = self.trail[-1]
        e = self.editor(path)
        qf = e.qf
        gn = qf.root
        if holder is not None:
            n = self._by_guid(qf, holder)
            emb = qf.tree.obj(n).get("embeddedGraph") if n else None
            if isinstance(emb, int) and emb > 0:
                gn = emb
        return e, qf, gn

    @staticmethod
    def _by_guid(qf, guid):
        for k, o in enumerate(qf.tree.objects, 1):
            g = o.get("guid") if o.props else None
            if isinstance(g, Guid) and g.hex() == guid:
                return k
        return None

    @staticmethod
    def _guid(qf, n):
        g = qf.tree.obj(n).get("guid") if n else None
        return g.hex() if isinstance(g, Guid) else None

    def open_path(self, path):
        """A quest file from its start (the trail begins anew)."""
        self.trail = [(path, None, os.path.basename(path))]
        self.show_current(home=True)

    def open_block(self, n):
        e, qf, gn = self.here()
        shown = self.shown(n)
        if shown is not None and shown.opens and shown.opens[0] == "fold":
            return self.unfold(n)
        b = qf.graph(gn).blocks.get(n)
        if not b or not b.opens:
            return
        if b.opens[0] == "graph":
            self.trail.append((self.trail[-1][0], self._guid(qf, n), b.name or "phase"))
        elif b.opens[1] and self.depot.exists(b.opens[1]):
            self.trail.append((b.opens[1], None, os.path.basename(b.opens[1])))
        else:
            return
        self.show_current(home=True)

    def _tips_bar(self):
        """A bar with the first steps (closed once: not again)."""
        from . import config
        try:
            if config.load().get("quest_graph_tips_closed"):
                return None
        except Exception:                               # noqa: BLE001 - no config: the bar shows
            pass
        bar = QtWidgets.QFrame()
        bar.setStyleSheet("QFrame{background:#1f2a1f;border:1px solid #2f4a2f}QLabel{color:#cfe3cf;font:12px}"
                          "QPushButton{background:transparent;border:none;color:#8fbf8f;padding:0 6px}")
        h = QtWidgets.QHBoxLayout(bar)
        h.setContentsMargins(8, 4, 4, 4)
        lab = QtWidgets.QLabel(
            "First steps:  drag a block from the left onto the graph  ·  click a block to see what it does and "
            "how the game uses it  ·  drag from an output's square to an input to connect  ·  Custom block: an "
            "own block with the game's blocks inside  ·  Handbook: every block with examples")
        lab.setWordWrap(True)
        h.addWidget(lab, 1)
        close = QtWidgets.QPushButton("Got it")

        def closed():
            bar.hide()
            try:
                cfg = config.load()
                cfg["quest_graph_tips_closed"] = True
                config.save(cfg)
            except Exception:                           # noqa: BLE001
                pass
        close.clicked.connect(closed)
        h.addWidget(close)
        return bar

    def handbook(self):
        """docs/QUEST_BLOCKS.md: every kind of block with real places of the game that use it."""
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "QUEST_BLOCKS.md")
        if os.path.exists(path):
            QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(path))
        return path

    def open_place(self, trail_guids, guid):
        """A block of the file shown, wherever it is: the phases in (their GUIDs), then it picked and in sight."""
        path = self.trail[0][0]
        e = self.editor(path)
        trail = [(path, None, os.path.basename(path))]
        for g in trail_guids:
            n = self._by_guid(e.qf, g)
            name = (e.tree.obj(n).get("name") or "phase") if n else "phase"
            trail.append((path, g, name))
        self.trail = trail
        self.reveal = guid                              # (a block of a template's block: shown on its own)
        self.show_current(home=True, pick=guid)
        if self.view.current is not None:
            self.view.centerOn(self.view.current)

    def open_example(self, ex):
        """A place of the game's quests (block_examples): its file, the phases in, the block picked and in sight."""
        trail = [(ex["file"], None, os.path.basename(ex["file"]))]
        names = (ex.get("where") or "").split(" > ")
        for k, g in enumerate(ex.get("trail") or []):
            trail.append((ex["file"], g, names[k] if k < len(names) and names[k] else "phase"))
        self.trail = trail
        self.reveal = ex.get("guid")
        self.show_current(home=True, pick=ex.get("guid"))
        if self.view.current is not None:
            self.view.centerOn(self.view.current)

    def back_to(self, k):
        self.trail = self.trail[:k + 1]
        self.show_current(home=True)

    # --- drawn
    def placed(self, qf, gn):
        g = self.folded(qf, gn)
        V.place(g)
        mine = self.layout_.get(qf.path, {})
        for b in g.blocks.values():
            at = mine.get(self._guid(qf, b.n) or "")
            if at:
                b.x, b.y = at
        V.route(g)
        return g

    def folded(self, qf, gn):
        """Graph gn as shown: with Templates on, the blocks wired as a template is inside as that template's block
        (translator.py) - those double clicked open as their blocks."""
        g = qf.graph(gn)
        self.fold_of = self.view.fold_of = {}
        if not getattr(self, "folding", None) or not self.folding.isChecked():
            return g
        from . import translator as T
        try:
            ms = T.find(g, T.shapes(self.depot))
        except Exception as ex:                         # noqa: BLE001 - the plain graph then
            self.state.setText(f"templates not read: {ex}")
            return g
        reveal, self.reveal = getattr(self, "reveal", None), None
        for m in ms:                                    # a block gone to (Follow, a fact's use ...): its own
            if reveal and any(self._guid(qf, x) == reveal for x in m["blocks"]):
                self.unfolded.add(self._guid(qf, m["blocks"][0]))
        ms = [m for m in ms if self._guid(qf, m["blocks"][0]) not in self.unfolded]
        for m in ms:
            for x in m["blocks"]:
                self.fold_of[x] = m["blocks"][0]
        return T.fold(g, ms)

    def shown(self, n):
        """The block as the graph shows it (a template's block for its first block), or None."""
        it = self.view.items_.get(n)
        return it.b if it is not None else None

    def real(self, a, out, b, put):
        """A link as drawn -> the link in the file (a template's block: the block and socket its port stands for)."""
        ba, bb = self.shown(a), self.shown(b)
        if ba is not None and getattr(ba, "ports", None):
            a, out = ba.ports.get(("out", out), (ba.last, out))
        if bb is not None and getattr(bb, "ports", None):
            b, put = bb.ports.get(("in", put), (b, put))
        return a, out, b, put

    def real_blocks(self, ns):
        """Block numbers as drawn -> the file's (a template's block: all its blocks)."""
        out = []
        for n in ns:
            b = self.shown(n)
            out.extend(b.folded if b is not None and getattr(b, "folded", None) else [n])
        return out

    def unfold(self, n):
        """A template's block shown as its blocks again."""
        e, qf, _gn = self.here()
        guid = self._guid(qf, n)
        if guid:
            self.unfolded.add(guid)
        self.show_current(pick=guid)

    def show_current(self, home=False, pick=None):
        e, qf, gn = self.here()
        g = self.placed(qf, gn)
        while self.crumbs.count():
            w = self.crumbs.takeAt(0).widget()
            if w is not None:
                w.hide()
                w.deleteLater()
        for k, (path, _holder, label) in enumerate(self.trail):
            if k:
                self.crumbs.addWidget(QtWidgets.QLabel("›"))
            edited = path in self.editors and self.editors[path].changed
            b = QtWidgets.QPushButton(label + (" *" if edited else ""))
            b.setObjectName("crumb")
            b.setStyleSheet("color:#f0f0f2;font-weight:bold" if k == len(self.trail) - 1 else "")
            b.clicked.connect(lambda _c=False, k=k: self.back_to(k))
            self.crumbs.addWidget(b)
        keep = (self.view.transform(), self.view.horizontalScrollBar().value(),
                self.view.verticalScrollBar().value())
        self.view.show_graph(g)
        if home:                                        # all of it when it fits readably, else its start
            self.view.resetTransform()
            rect = self.view.scene().itemsBoundingRect().adjusted(-30, -30, 30, 30)
            port = self.view.viewport().rect()
            fits = rect.width() > 0 and min(port.width() / rect.width(), port.height() / rect.height()) >= 0.6
            first = next((it for it in self.view.items_.values()
                          if it.b.cls in ("CQuestPhaseInputBlock", "CQuestStartBlock")), None)
            if fits:
                self.view.fitInView(rect, QtCore.Qt.KeepAspectRatio)
                if self.view.transform().m11() > 1.0:
                    self.view.resetTransform()
                    self.view.centerOn(rect.center())
            elif first is not None:
                self.view.centerOn(first.pos() + QtCore.QPointF(port.width() / 2 - 60, 0))
        else:
            self.view.setTransform(keep[0])
            self.view.horizontalScrollBar().setValue(keep[1])
            self.view.verticalScrollBar().setValue(keep[2])
        if self.search.text():
            self.view.find(self.search.text())
        self.guid_n = {self._guid(qf, n): n for n in g.blocks}
        self.guid_n.update({self._guid(qf, x): v for x, v in self.fold_of.items()})
        for guid, at in self.live_seen.items():
            if guid in self.guid_n and self.guid_n[guid] in self.view.items_:
                self.view.items_[self.guid_n[guid]].live_at = at
        self.sync_buttons()
        n = self._by_guid(qf, pick) if pick else None
        n = self.fold_of.get(n, n)
        if n and n in self.view.items_:
            self.view.pick_n(n)
        else:
            self.show_block(None)

    def sync_buttons(self):
        e = self.editor(self.trail[-1][0]) if self.trail else None
        editable = e is not None
        self.buttons["undo"].setEnabled(editable and bool(e.history))
        self.buttons["redo"].setEnabled(editable and bool(e.future))
        self.buttons["save"].setEnabled(editable and e.dirty and bool(self.project_dir))
        self.buttons["revert"].setEnabled(editable and e.changed)
        if not e:
            self.state.setText("")
        elif self.read_only(e) and not e.changed:
            self.state.setText(READ_ONLY)
        elif e.changed and getattr(e, "_own", None):    # the project's own quest
            self.state.setText(("unsaved · " if e.dirty else "") + "Changed in the graph. Build uses this "
                                                                    "version (changes on the quest board reach "
                                                                    "it after Revert)")
        elif e.changed:
            gu = e.changed_guids()
            self.state.setText(("unsaved · " if e.dirty else "") + "Changed from the game" +
                               (f" · {gu['gone']} game blocks gone (Caution: saves inside this quest may not fit)"
                                if gu["gone"] else ""))
        else:
            self.state.setText("")

    # --- edits
    def read_only(self, e=None):
        """A game quest's file while the experimental features are off (features.py): shown, not changed."""
        from . import features
        e = e if e is not None else (self.editor(self.trail[-1][0]) if self.trail else None)
        return e is not None and not getattr(e, "_own", None) and not features.experimental()

    def edit(self, fn, pick_guid=None, allow=False):
        """One change on the file shown, then everything drawn again (the picked block stays picked). A game
        quest's file read only (read_only) takes none - but going back to the game's (allow)."""
        e, qf, _gn = self.here()
        if not allow and self.read_only(e):
            self.state.setText(READ_ONLY)
            return None
        cur = self.view.current
        keep = pick_guid or (self._guid(qf, cur.b.n) if cur is not None else None)
        try:
            result = fn(e)
        except (ValueError, KeyError, IndexError) as ex:
            self.state.setText(f"not changed: {ex}")
            return None
        self.show_current(pick=keep if not isinstance(result, int) else self._guid(e.qf, result) or keep)
        return result

    def undo(self):
        self.edit(lambda e: e.undo())

    def redo(self):
        self.edit(lambda e: e.redo())

    def save(self):
        e = self.editor(self.trail[-1][0])
        if self.project_dir:
            from .features import Off
            try:
                e.save()
            except Off as ex:
                self.state.setText(str(ex))
                return
            self._save_layout()
        self.show_current(pick=self._guid(e.qf, self.view.current.b.n) if self.view.current else None)

    def revert(self):
        self.edit(lambda e: e.revert(), allow=True)

    def link(self, a, out, b, put):
        a, out, b, put = self.real(a, out, b, put)
        self.edit(lambda e: e.connect(a, out, b, put))

    def block_moved(self, n, x, y):
        e, qf, _gn = self.here()
        guid = self._guid(qf, n)
        if guid:
            self.layout_.setdefault(qf.path, {})[guid] = (x, y)
            self._save_layout()
        self.view.grow()

    def add_block(self, cls, at):
        e, qf, gn = self.here()

        def fn(ed):
            n = ed.add_block(gn, cls)
            guid = self._guid(ed.qf, n)
            if guid:
                self.layout_.setdefault(qf.path, {})[guid] = (int(at.x()), int(at.y()))
            return n
        n = self.edit(fn)
        self._save_layout()
        return n

    # --- copy and paste: blocks between graphs and quest files (a pattern of the game's quests into one's own)
    def copy(self):
        """The blocks chosen, kept for Paste (in any graph, any quest file of this window). -> how many."""
        global CLIP
        if not self.trail:
            return 0
        e, qf, gn = self.here()
        drawn = self.view.chosen()
        if not drawn:
            return 0
        ns = self.real_blocks(drawn)
        at = {}
        for n in drawn:                                 # (a template's blocks: in a row from where it stands)
            it = self.view.items_.get(n)
            for k, x in enumerate(self.real_blocks([n])):
                if it is not None:
                    at[x] = (it.b.x + k * (V.NODE_W + V.GAP_X), it.b.y)
        CLIP = {"src": e.data, "ns": ns, "at": at, "from": qf.path}
        self.state.setText(f"{len(ns)} block{'s' if len(ns) != 1 else ''} copied")
        return len(ns)

    def paste(self, at=None):
        """The blocks copied, into the graph shown, at `at` (None: where the mouse is, else the middle) - the links
        among them kept. One undo. -> their numbers."""
        if not CLIP or not self.trail:
            return []
        e, qf, gn = self.here()
        if at is None:
            pos = self.view.mapFromGlobal(QtGui.QCursor.pos())
            inside = self.view.viewport().rect().contains(pos)
            at = self.view.mapToScene(pos if inside else self.view.viewport().rect().center())
        x0 = min(x for x, _y in CLIP["at"].values()) if CLIP["at"] else 0
        y0 = min(y for _x, y in CLIP["at"].values()) if CLIP["at"] else 0

        def fn(ed):
            new = ed.paste(gn, CLIP["src"], CLIP["ns"])
            for old, n in zip(CLIP["ns"], new):
                guid = self._guid(ed.qf, n)
                x, y = CLIP["at"].get(old, (x0, y0))
                if guid:
                    self.layout_.setdefault(qf.path, {})[guid] = (int(at.x() + x - x0), int(at.y() + y - y0))
            return new
        new = self.edit(fn) or []
        self._save_layout()
        for n in new:
            if n in self.view.items_:
                self.view.items_[n].setSelected(True)
        return new

    def duplicate_chosen(self):
        if self.copy():
            pos = QtCore.QPointF(min(x for x, _y in CLIP["at"].values()) + 40,
                                 min(y for _x, y in CLIP["at"].values()) + 40)
            return self.paste(pos)
        return []

    def remove_chosen(self):
        if not self.trail:
            return
        e, qf, gn = self.here()
        ns = self.real_blocks(self.view.chosen())
        if ns:
            self.edit(lambda ed: ed.remove_blocks(gn, ns))

    def choose_all(self):
        for it in self.view.items_.values():
            it.setSelected(True)

    def add_entry(self, entry, at=None):
        """A block from the sidebar (a simple kind or one of the game's) put into the graph shown, at `at` (None:
        the middle of what is in sight). One undo takes it back. -> its number."""
        from . import blocks
        if not self.trail:                              # (no quest open yet)
            return None
        e, qf, gn = self.here()
        if at is None:
            at = self.view.mapToScene(self.view.viewport().rect().center()) - QtCore.QPointF(V.NODE_W / 2, 30)
        what, name = entry[0], entry[1]
        if what == "template":
            return self.add_template(name, at)

        def make(ed):
            if what == "kind":
                return blocks.create(ed, gn, blocks.BY_ID[name])
            if what == "block":
                return ed.add_block(gn, name)
            if what == "wait":
                return ed.add_wait(gn, name)
            if what == "if":
                n = ed.add_block(gn, blocks.I)
                ed.add_condition(n, name)
                return n
            if what == "fn":
                return ed.add_function(gn, name, blocks.function_params(name, self.palette.catalog))
            if what == "ai":
                return ed.add_ai(gn, name)
            raise ValueError(f"unknown block {entry}")

        def fn(ed):
            n = ed.batch(make)
            guid = self._guid(ed.qf, n)
            if guid:
                self.layout_.setdefault(qf.path, {})[guid] = (int(at.x()), int(at.y()))
            return n
        n = self.edit(fn)
        self._save_layout()
        return n

    def add_template(self, tid, at):
        """A template (custom_blocks) put in: a custom block with all inside, named as the template; the project
        remembers which template it is (its exposed fields on the card). -> its number."""
        from . import custom_blocks as CB
        tpl = CB.by_id(tid)
        if tpl is None:
            return None
        e, qf, gn = self.here()

        def fn(ed):
            def make(ed2):
                n = CB.insert(ed2, gn, tpl)
                ed2.set_field(n, "name", tpl["label"], "String")
                return n
            n = ed.batch(make)
            guid = self._guid(ed.qf, n)
            if guid:
                self.layout_.setdefault(qf.path, {})[guid] = (int(at.x()), int(at.y()))
                self.instances().set(guid, template=tid)
            return n
        n = self.edit(fn)
        self._save_layout()
        return n

    def instances(self):
        """The project's custom blocks (custom_blocks.Instances): which template, which fields shown outside."""
        from .custom_blocks import Instances
        if getattr(self, "_instances", None) is None:
            self._instances = Instances(self.project_dir)
        return self._instances

    def inside_custom(self):
        """The custom block the graph shown is the inside of: its number in the file, else None."""
        if len(self.trail) < 2 or self.trail[-1][1] is None:
            return None
        e = self.editor(self.trail[-1][0])
        return self._by_guid(e.qf, self.trail[-1][1])

    def menu(self, target, global_pos, scene_pos):
        m = self.build_menu(target, scene_pos)
        if not m.isEmpty():
            m.exec(global_pos)

    def build_menu(self, target, scene_pos):
        """The right click's menu: a link's, a block's, or the graph's (add a block there)."""
        e, qf, gn = self.here()
        m = QtWidgets.QMenu(self)
        m.setStyleSheet(STYLE)
        if isinstance(target, WireItem):
            a, out, b, put = target.link
            ra, rout, rb, rput = self.real(a, out, b, put)
            m.addAction("Remove link", lambda: self.edit(lambda ed: ed.disconnect(ra, rout, rb, rput)))
        elif isinstance(target, BlockItem):
            n = target.b.n
            if target.b.opens and target.b.opens[0] == "fold":
                m.addAction("Show its blocks", lambda: self.unfold(n))
            elif target.b.opens:
                m.addAction("Open", lambda: self.open_block(n))
            m.addAction("Copy  (Ctrl+C)", self.copy)
            m.addAction("Duplicate  (Ctrl+D)", self.duplicate_chosen)
            m.addAction("Remove  (Del)", self.remove_chosen)
        else:
            if CLIP:
                m.addAction(f"Paste {len(CLIP['ns'])} block{'s' if len(CLIP['ns']) != 1 else ''}  (Ctrl+V)",
                            lambda: self.paste(scene_pos))
            from . import blocks
            from .vanilla_edit import block_classes
            add = m.addMenu("Add block")
            for gid, gname in blocks.GROUPS:            # the simple ones by what they are for
                kinds = [k for k in blocks.KINDS if k.group == gid]
                if kinds:
                    sub = add.addMenu(gname)
                    for k in kinds:
                        a = sub.addAction(k.label, lambda k=k: self.add_entry(("kind", k.id), scene_pos))
                        a.setToolTip(k.text)
            simple = {k.cls for k in blocks.KINDS}
            sub = add.addMenu("Game blocks")
            for c in block_classes():
                if c not in simple:
                    sub.addAction(V.NAMES.get(c, V.short(c)) + f"   ({c})",
                                  lambda c=c: self.add_block(c, scene_pos))
        return m

    # --- live: the blocks the game activates (TW3SE questlive)
    def set_live(self, on):
        from . import gamelink, tw3se
        try:
            reply = tw3se.send(f"questlive {'on' if on else 'off'}")
        except Exception as ex:                         # noqa: BLE001 - no game, no extender
            reply = f"no game: {ex}"
        if on and "hooked=yes" not in str(reply):
            self.state.setText("Live: TW3SE has no questlive - " + str(reply)[:80])
            self.live.blockSignals(True)
            self.live.setChecked(False)
            self.live.blockSignals(False)
            return
        if on:
            self.live_pos = gamelink.mark()
            self.live_timer.start(250)
        else:
            self.live_timer.stop()

    def live_tick(self):
        """New activations from the game: their blocks lit; the lit ones fade."""
        import time
        from . import gamelink
        try:
            self.live_pos, lines = gamelink.since(self.live_pos)
        except Exception:                               # noqa: BLE001 - the game went away
            return
        now = time.monotonic()
        self.live_activations(lines, now)
        for it in self.view.items_.values():
            if it.live_at and now - it.live_at < LIVE_FADE + 0.5:
                it.update()

    def live_activations(self, lines, now):
        """qb|on|<guid> lines: each GUID's time kept; a block of the graph shown lit. -> how many of them here."""
        here, last = 0, None
        for ln in lines:
            if not ln.startswith("qb|on|"):
                continue
            guid = ln[6:38]
            self.live_seen[guid] = now
            n = getattr(self, "guid_n", {}).get(guid)
            if n is not None and n in self.view.items_:
                self.view.items_[n].live_at = now
                self.view.items_[n].update()
                here += 1
            last = guid
        if self.follow.isChecked() and last and not here:
            self.follow_to(last)
        return here

    def follow_to(self, guid):
        """Follow: a block the game ran elsewhere in the file shown - its phase opened, it picked. -> True if it
        is in this file."""
        if not self.trail:
            return False
        from .block_examples import trail as trail_of
        e = self.editor(self.trail[0][0])
        n = self._by_guid(e.qf, guid)
        if not n or e.tree.obj(n).cls == "CJournalPath":
            return False
        graph = e.tree.obj(n).parent
        if not graph or e.tree.obj(graph).cls != "CQuestGraph":
            return False
        self.open_place(trail_of(e.tree, graph), guid)
        return True

    # --- the picked block's properties
    def show_block(self, b):
        self.props.clear()
        if not self.trail:
            return
        e, qf, gn = self.here()
        self.card.show_block(qf, b)
        self.head.setVisible(b is None)
        if b is None:
            g = qf.graph(gn)
            self.head.setText(f"<b style='color:#f0f0f2'>{self.trail[-1][2]}</b><br>"
                              f"<span style='color:#8c8c90'>{len(g.blocks)} blocks, {len(g.links)} links"
                              f"<br>{qf.path}</span>")
            return
        o = qf.tree.obj(b.n)
        self.head.setText(f"<b style='color:#f0f0f2'>{b.title}</b><br><span style='color:#8c8c90'>{o.cls} "
                          f"· object {b.n}</span>" + (f"<br><span style='color:#c8c8a0'>{b.comment}</span>"
                                                      if b.comment else ""))
        self._props_of = b
        if self.tabs.currentWidget() is not self.props:  # (filled when its tab is opened)
            return
        self._fill_props(b)

    def _fill_props(self, b):
        """The 'All values' tab: every value of the block, the objects under it unfolded."""
        self.props.clear()
        e, qf, gn = self.here()
        o = qf.tree.obj(b.n)
        self._fill(self.props.invisibleRootItem(), qf, b.n, [], o.props or [], {b.n})
        if o.args:
            args = QtWidgets.QTreeWidgetItem(["(arguments)", "", ""])
            self.props.addTopLevelItem(args)
            self._fill(args, qf, b.n, None, o.args, {b.n})
            args.setExpanded(True)
        self.props.expandToDepth(1)

    def _fill(self, parent, qf, objn, path, props, seen):
        for p in props:
            self._value(parent, qf, objn, None if path is None else path + [p.name], p.name, p.type, p.value, seen)

    def _value(self, parent, qf, objn, path, name, typ, v, seen):
        """A value's row; its data: (object, path inside it, type) - where an edit writes (path None: not
        editable here, a script's arguments follow its parameters)."""
        item = QtWidgets.QTreeWidgetItem([name, "", typ])
        parent.addChild(item)
        item.setData(0, QtCore.Qt.UserRole, (objn, path, typ))
        if isinstance(v, Struct):
            self._fill(item, qf, objn, path, v, seen)
        elif isinstance(v, list) and not isinstance(v, Tags):
            inner = typ.split(",", 2)[2] if typ.startswith("array:") else ""
            item.setText(1, f"{len(v)} item{'s' if len(v) != 1 else ''}")
            for k, x in enumerate(v):
                self._value(item, qf, objn, None if path is None else path + [k], f"[{k}]", inner, x, seen)
        elif typ.startswith(("handle:", "ptr:", "#")) and isinstance(v, int) and v > 0:
            o = qf.tree.obj(v)
            item.setText(1, o.cls)
            # (another block of the graph, a graph: named, not walked - its links lead through the whole graph)
            other = o.cls == "CQuestGraph" or (o.cls.endswith("Block") and v != objn and o.get("guid") is not None)
            if other:
                item.setText(1, f"{o.cls} (object {v})")
            elif v not in seen:
                self._fill(item, qf, v, [], o.props or [], seen | {v})
        elif isinstance(v, Soft) or (typ.startswith(("handle:", "ptr:", "#")) and isinstance(v, int) and v < 0):
            p = qf.import_path(v)
            item.setText(1, p or "none")
            item.setData(1, QtCore.Qt.UserRole, p)
        elif isinstance(v, Variant):
            item.setText(2, f"{typ} ({v.type})")
            item.setText(1, qf.text(v.value, v.type))
        elif isinstance(v, Guid):
            item.setText(1, v.hex())
        elif isinstance(v, Loc):
            item.setText(1, str(int(v)))
        elif isinstance(v, Transform):
            item.setText(1, qf.text(v))
        elif isinstance(v, Raw):
            item.setText(1, bytes(v).hex(" "))
        else:
            item.setText(1, qf.text(v, typ) if not isinstance(v, str) else v)

    def _current_value(self, objn, path):
        from .vanilla_edit import _locate
        e = self.editor(self.trail[-1][0])
        holder, key = _locate(e.tree.obj(objn).props, path)
        return holder[key] if isinstance(key, int) else holder.value

    def _prop_double(self, item, col):
        """A double click: a reference to a quest file opens it; a value is changed (yes / no flips)."""
        ref = item.data(1, QtCore.Qt.UserRole)
        objn, path, typ = item.data(0, QtCore.Qt.UserRole) or (None, None, "")
        if col == 0 and ref and ref.endswith((".w2phase", ".w2quest")) and self.depot.exists(ref):
            self.trail.append((ref, None, os.path.basename(ref)))
            self.show_current(home=True)
            return
        if path is None or objn is None:
            return
        v = self._current_value(objn, path)
        if isinstance(v, bool):
            self.edit(lambda e: e.set(objn, path, not v))
            return
        if not self.editable_value(v, typ):
            return
        is_ref = typ.startswith(("soft:", "handle:", "ptr:", "#"))
        field = QtWidgets.QLineEdit((ref or "") if is_ref else item.text(1))
        field.setStyleSheet("background:#1b1b1e;color:#fff;border:1px solid #d9a441")
        self.props.setItemWidget(item, 1, field)
        field.setFocus()
        field.selectAll()
        typing = getattr(self.ed, "typing", None)
        if typing is not None:
            typing.start(field)

        def done():
            text = field.text()
            self.props.removeItemWidget(item, 1)
            if typing is not None:
                typing.stop()
            try:
                new = None if is_ref else self.parse(v, typ, text)
            except ValueError as ex:
                self.state.setText(f"not changed: {ex}")
                return
            if is_ref:
                self.edit(lambda e: e.set_ref(objn, path, text.strip(), self._import_class(v, text)))
            elif new != v or type(new) is not type(v):
                self.edit(lambda e: e.set(objn, path, new))
        field.editingFinished.connect(done)

    @staticmethod
    def editable_value(v, typ):
        if isinstance(v, (Guid, Raw, Transform, Struct)) or (isinstance(v, list) and not isinstance(v, Tags)):
            return False
        if typ.startswith(("handle:", "ptr:", "#")) and isinstance(v, int) and v > 0:
            return False                                # (an object of the file: changed in its own rows)
        return True

    def _import_class(self, v, text):
        e = self.editor(self.trail[-1][0])
        k = v if isinstance(v, Soft) else -v if isinstance(v, int) and v < 0 else 0
        if 0 < k <= len(e.tree.f.imports):
            return e.tree.f.imports[k - 1][1]
        return IMPORT_CLASS.get(os.path.splitext(text.strip())[1].lower(), "CResource")

    @staticmethod
    def parse(old, typ, text):
        """The text typed into a value's field, as a value of its type."""
        if isinstance(old, Variant):
            return Variant(old.type, VanillaWindow.parse(old.value, old.type, text))
        if typ in SIMPLE and typ not in ("Float", "Double", "Bool"):
            return int(text.strip())
        if typ in ("Float", "Double") or isinstance(old, float):
            return float(text.strip())
        if isinstance(old, Tags):
            return Tags(x.strip() for x in text.split(",") if x.strip())
        if isinstance(old, Loc):
            return Loc(int(text.strip()))
        if isinstance(old, Wide):
            return Wide(text)
        if isinstance(old, int) and not isinstance(old, bool):
            return int(text.strip())
        return text

    def _prop_menu(self, pos):
        item = self.props.itemAt(pos)
        if item is None:
            return
        objn, path, typ = item.data(0, QtCore.Qt.UserRole) or (None, None, "")
        if path is None:
            return
        m = QtWidgets.QMenu(self)
        m.setStyleSheet(STYLE)
        if typ.startswith("array:"):
            m.addAction("Add item", lambda: self.edit(lambda e: e.add_item(objn, path) and None))
        if path and isinstance(path[-1], int):
            m.addAction("Remove item", lambda: self.edit(lambda e: e.remove_item(objn, path)))
        if not m.isEmpty():
            m.exec(self.props.viewport().mapToGlobal(pos))

    # --- where blocks were dragged: in the project
    def _layout_file(self):
        return os.path.join(self.project_dir, LAYOUT) if self.project_dir else None

    def _load_layout(self):
        f = self._layout_file()
        try:
            return json.load(open(f, encoding="utf-8")) if f and os.path.exists(f) else {}
        except (OSError, ValueError):
            return {}

    def _save_layout(self):
        f = self._layout_file()
        if not f:
            return
        tmp = f + ".tmp"
        json.dump(self.layout_, open(tmp, "w", encoding="utf-8"))
        os.replace(tmp, f)
