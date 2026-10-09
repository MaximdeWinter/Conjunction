"""The quest graph on screen - the look of PathView (github.com/pathsim/pathview, MIT, by milanofthe): a dark dotted
grid, blocks in their own shapes, orthogonal wires with sharp corners and small arrowheads (all square: Maxim
05.10.). A node editor: nodes stand where they are put, wires are drawn by hand (Maxim 30.09.: 'every node has an
input and outputs that are dragged, connected and removed').

    a block from the sidebar dropped    on the grid: a node there, on its own; on a wire: put into it
    a node dragged                      moved there
    an output dragged (the handle at    onto a node: wired to it (instead of where it led; Shift: beside that - both
    a node's bottom, or at an exit)     run); let go on nothing: nothing
    an input dragged (the handle at     its wire taken off: onto another node - wired there; on nothing - gone
    a node's top)
    a click on a wire / right click     picked / its menu (remove)
    a click on a node's title           what the block does (its kinds)
    a click on a node / double click    picked (its card below) / a talk's dialogue
    a right click on a node             its menu (play from here, duplicate, remove)
    the empty grid dragged, the wheel   move, zoom; a double click on the grid: all of it in sight

    view.show_graph(graph, keep)        routes and draws it (quest_graph.build_nodes); keep: the view stays
    signals: picked(id), opened(id), kind_menu(id, QPoint), node_menu(id, QPoint), wire_menu(link, QPoint),
             place(block, drop), moved(id, x, y), connect(from, output, to, beside), relink(link, to), unlink(link)
    drop: ("free", x, y) | ("wire", link, x, y)          link: [from node, output, to node]
"""
from PySide6 import QtCore, QtGui, QtWidgets

from . import graph_layout as L
from . import graph_route as R
from . import quest_graph as QG

SURFACE = "#08080c"
RAISED = "#1c1c26"
BORDER = QtGui.QColor(128, 128, 144, 120)
EDGE = "#808090"
TEXT = "#f0f0f5"
MUTED = "#808090"
DOT = "#1f1f2b"
ACCENT = "#0088E8"
LINE_BG = QtGui.QColor(255, 255, 255, 14)
ENDS = L.ENDS
LIVE = {1: ("NOW", "#e3c65f"), 2: ("DONE", "#22c55e"), 3: ("FAILED", "#ef4444")}
MOVE_PX = 6                     # a press that moves further is a drag
PORT_HIT = 9                    # how near an exit's port a press takes the port
PICKED = "#e8b64c"               # what is picked (a block clicked goes after it, Delete removes it): gold, pulsing


def pulse():
    """0..1, slowly up and down (the picked outline breathes)."""
    import math
    import time
    return 0.5 + 0.5 * math.sin(time.perf_counter() * 3.2)



def _font(px, bold=False, spacing=0.0):
    f = QtGui.QFont("Segoe UI")
    f.setPixelSize(px)
    f.setBold(bold)
    if spacing:
        f.setLetterSpacing(QtGui.QFont.AbsoluteSpacing, spacing)
    return f


def _qc(c, alpha=None):
    q = QtGui.QColor(c)
    if alpha is not None:
        q.setAlpha(alpha)
    return q


def _chamfered(r, tl, tr, br, bl):
    """A rectangle with its corners cut off by these sizes (top left, top right, bottom right, bottom left)."""
    x0, y0, x1, y1 = r.left(), r.top(), r.right(), r.bottom()
    path = QtGui.QPainterPath()
    path.moveTo(x0 + tl, y0)
    path.lineTo(x1 - tr, y0)
    path.lineTo(x1, y0 + tr)
    path.lineTo(x1, y1 - br)
    path.lineTo(x1 - br, y1)
    path.lineTo(x0 + bl, y1)
    path.lineTo(x0, y1 - bl)
    path.lineTo(x0, y0 + tl)
    path.closeSubpath()
    return path


def shape(node, r):
    """The outline of a node: its block's shape - square, no round corners (Maxim 05.10.); what a node is shows in
    its cut corners: an end pointed at both sides, a choice cut where the way comes in and where the ways go out,
    a parallel track / start / path cut at every corner, an action and a chapter plain."""
    k, b = node.kind, node.block
    if k in ENDS:
        c = r.height() / 2
        return _chamfered(r, c, c, c, c)
    if b == "choice":
        return _chamfered(r, 12, 0, 12, 0)
    if b == "parallel" or k in ("start", "path"):
        return _chamfered(r, 9, 9, 9, 9)
    path = QtGui.QPainterPath()
    if b in ("action", "chapter"):
        path.addRect(r)
        return path
    return _chamfered(r, 5, 5, 5, 5)


class NodeItem(QtWidgets.QGraphicsItem):
    def __init__(self, node, view):
        super().__init__()
        self.node, self.view = node, view
        self.setPos(node.x, node.y)
        self.setAcceptHoverEvents(True)
        self.hot = False
        self.hot_title = False                  # the mouse on the kind (a menu)
        self.title_rect = None                  # where the kind is drawn (set when painted)
        self.selected = False
        self.setToolTip(self._tip())

    def _tip(self):
        n = self.node
        parts = [x for x in (n.text,) if x] + [e.label for e in n.exits]
        return "\n".join(parts) if len(" ".join(parts)) > 60 or n.exits else ""

    def boundingRect(self):
        extra = QG.FAIL_MARK + 10 if any(QG.fails_here(e) for e in self.node.exits) else 0
        return QtCore.QRectF(-8, -8, self.node.w + 16 + extra, self.node.h + 16)

    def paint(self, p, _opt, _w=None):
        n = self.node
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        r = QtCore.QRectF(0.5, 0.5, n.w - 1, n.h - 1)
        outline = shape(n, r)
        colour = _qc(n.colour or EDGE)
        live = LIVE.get(self.view.live(n)) if self.view.live is not None else None
        if live and live[0] == "NOW":                   # where the player is: its colour around the node
            p.setPen(QtGui.QPen(_qc(live[1], 70), 6))
            p.setBrush(QtCore.Qt.NoBrush)
            p.drawPath(outline)
        if self.selected:                               # picked: a gold glow that breathes, a gold line
            p.setPen(QtGui.QPen(_qc(PICKED, int(50 + 110 * pulse())), 6))
            p.setBrush(QtCore.Qt.NoBrush)
            p.drawPath(outline)
        p.setBrush(_qc("#22222e" if n.block == "chapter" else RAISED))
        pen = QtGui.QPen(BORDER, 1)
        if n.kind in ENDS:
            pen = QtGui.QPen(_qc(n.colour, 170), 1)
        elif self.selected:
            pen = QtGui.QPen(_qc(PICKED), 1.6)
        elif live and live[0] == "NOW":
            pen = QtGui.QPen(_qc(live[1]), 1.3)
        elif n.kind in QG.PLACEHOLDERS:
            pen = QtGui.QPen(_qc("#b0b0c0", 170), 1, QtCore.Qt.DashLine)
        elif n.kind == "path" or n.block == "parallel":
            pen = QtGui.QPen(_qc(n.colour, 190), 1, QtCore.Qt.DashLine)
        elif self.hot:
            pen = QtGui.QPen(_qc("#b0b0c0", 150), 1)
        p.setPen(pen)
        p.drawPath(outline)
        if n.lane and n.kind not in ENDS and n.kind != "path":      # a path's column: its colour on the left
            p.save()
            p.setClipPath(outline)
            p.fillRect(QtCore.QRectF(0, 0, 3, n.h), _qc(n.lane))
            p.restore()
        if n.kind in ENDS:
            p.setFont(_font(9, True, 0.6))
            p.setPen(colour)
            p.drawText(r, QtCore.Qt.AlignCenter, n.title)
            self._ports(p, n)
            return
        # the title row: number, KIND (a menu of what it does), · subject
        x = 12
        if n.number:
            p.setFont(_font(11, True))
            p.setPen(_qc(TEXT))
            p.drawText(QtCore.QRectF(x, 0, 30, L.HEAD), QtCore.Qt.AlignVCenter, str(n.number))
            x += QtGui.QFontMetrics(_font(11, True)).horizontalAdvance(str(n.number)) + 7
        title = n.title + (" ▾" if self.view.kinds_of(n) else "")
        width = QtGui.QFontMetrics(_font(9, True, 0.6)).horizontalAdvance(title)
        # the kind is a menu: under the mouse it gets an outline (else it is hit by chance - Maxim, 30.09.)
        self.title_rect = QtCore.QRectF(x - 4, 7, width + 8, L.HEAD - 14) if self.view.kinds_of(n) else None
        if self.title_rect is not None and self.hot_title:
            p.setPen(QtGui.QPen(_qc(n.colour or EDGE, 200), 1))
            p.setBrush(_qc(n.colour or EDGE, 30))
            p.drawRect(self.title_rect)
        p.setFont(_font(9, True, 0.6))
        p.setPen(colour)
        p.drawText(QtCore.QRectF(x, 0, n.w - x - 10, L.HEAD), QtCore.Qt.AlignVCenter, title)
        x += width + 6
        if n.subject:
            fm = QtGui.QFontMetrics(_font(10))
            p.setFont(_font(10))
            p.setPen(_qc(MUTED))
            p.drawText(QtCore.QRectF(x, 0, n.w - x - 18, L.HEAD), QtCore.Qt.AlignVCenter,
                       fm.elidedText("· " + n.subject, QtCore.Qt.ElideRight, int(max(0, n.w - x - 18))))
        right = n.w - 11
        if getattr(n, "hidden", False):                 # its eye shut (the card's eye): a small one here too
            from .icons import icon
            icon("eye-off", MUTED, 12).paint(p, QtCore.QRect(int(right - 6), int(L.HEAD / 2 - 6), 12, 12))
            right -= 16
        if n.missing:                                   # a red dot: something is still missing here
            p.setPen(QtCore.Qt.NoPen)
            p.setBrush(_qc("#ef4444"))
            p.drawEllipse(QtCore.QPointF(right, L.HEAD / 2), 3, 3)
            right -= 10
        if live:
            p.setFont(_font(8, True, 0.6))
            p.setPen(_qc(live[1]))
            p.drawText(QtCore.QRectF(right - 60, 0, 60, L.HEAD), QtCore.Qt.AlignVCenter | QtCore.Qt.AlignRight,
                       live[0])
        y = L.HEAD - 6
        for kind, text in L.body(n):
            if kind == "text":
                big = n.kind in ("chapter", "path")
                p.setFont(_font(12 if big else 11, n.block != "action"))
                p.setPen(_qc(n.colour if n.kind == "path" else "#b8b8c8" if n.kind in QG.PLACEHOLDERS else TEXT))
                if n.kind in QG.PLACEHOLDERS:
                    p.setFont(_font(11))
            else:
                p.setFont(_font(10))
                p.setPen(_qc("#ef6b6b"))
            p.drawText(QtCore.QRectF(12, y, n.w - 22, L.LINE), QtCore.Qt.AlignVCenter, text)
            y += L.LINE
        # the exits: one row each, the label at the right next to its port
        if n.exits:
            ey = L.exits_top(n)
            p.setPen(QtGui.QPen(LINE_BG, 1))
            p.drawLine(QtCore.QPointF(1, ey), QtCore.QPointF(n.w - 1, ey))
            fm = QtGui.QFontMetrics(_font(10))
            for k, ex in enumerate(n.exits):
                c = self.view.exit_colour(n, k)
                mark = {"next": "  ↓", "retry": "  ↺"}.get(ex.to, "")
                if QG.fails_here(ex):                   # the quest fails right here: a mark, no wire
                    c = QG.FAIL
                    y0 = ey + k * L.EXIT + L.EXIT / 2
                    tag = QtCore.QRectF(n.w + 8, y0 - 7, QG.FAIL_MARK, 14)
                    p.setPen(QtGui.QPen(_qc(QG.FAIL, 200), 1))
                    p.setBrush(_qc(RAISED))
                    p.drawRect(tag)
                    p.setFont(_font(8, True, 0.5))
                    p.setPen(_qc(QG.FAIL))
                    p.drawText(tag, QtCore.Qt.AlignCenter, "FAILS")
                p.setFont(_font(10))
                row = QtCore.QRectF(10, ey + k * L.EXIT, n.w - 22, L.EXIT)
                p.setPen(_qc(c))
                label = fm.elidedText(ex.label, QtCore.Qt.ElideRight, n.w - 40) + mark
                p.drawText(row, QtCore.Qt.AlignVCenter | QtCore.Qt.AlignRight, label)
                hot = self.view.hot_port == (n.id, k)
                self._handle(p, n.w, ey + k * L.EXIT + L.EXIT / 2, ACCENT if hot else c, vertical=False,
                             filled=getattr(ex, "wired", False))
        self._ports(p, n)

    def _ports(self, p, n):
        """Its input at the top, its one output at the bottom (filled: wired)."""
        if self.view.has_input(n.id):
            self._handle(p, L.port(n, "in")[0] - n.x, 0, EDGE, vertical=True,
                         filled=bool(self.view.links_into(n.id)))
        if n.goes_on and n.kind not in ENDS:
            hot = self.view.hot_port == (n.id, "next")
            self._handle(p, L.port(n, "next")[0] - n.x, n.h, ACCENT if hot else EDGE, vertical=True,
                         filled=getattr(n, "next_wired", False))

    def _handle(self, p, x, y, c, vertical, filled=False):
        """A port: PathView's small handle on the node's edge (hollow: not wired)."""
        p.setPen(QtGui.QPen(_qc(c), 1.2))
        p.setBrush(_qc(c) if filled else _qc(SURFACE))
        w, h = (12, 7) if vertical else (7, 12)
        p.drawRect(QtCore.QRectF(x - w / 2, y - h / 2, w, h))

    def hoverEnterEvent(self, _e):
        self.hot = True
        self.update()

    def hoverLeaveEvent(self, _e):
        self.hot = False
        self.hot_title = False
        self.update()

    def hoverMoveEvent(self, e):
        on = self.title_rect is not None and self.title_rect.contains(e.pos())
        if on != self.hot_title:
            self.hot_title = on
            self.setCursor(QtCore.Qt.PointingHandCursor if on else QtCore.Qt.ArrowCursor)
            self.update()


def wire_path(points):
    """The corners as a path with sharp bends (square, Maxim 05.10.)."""
    path = QtGui.QPainterPath(QtCore.QPointF(*points[0]))
    for pt in points[1:]:
        path.lineTo(*pt)
    return path


class WireItem(QtWidgets.QGraphicsPathItem):
    def __init__(self, wire):
        super().__init__()
        self.wire = wire
        pts = list(wire.points)
        (x0, y0), (x1, y1) = pts[-2], pts[-1]
        dx, dy = (x1 > x0) - (x1 < x0), (y1 > y0) - (y1 < y0)
        pts[-1] = (x1 - 6 * dx, y1 - 6 * dy)                    # room for the arrowhead
        self.setPath(wire_path(pts))
        c = _qc(wire.colour or EDGE, 230 if wire.colour else 255)
        pen = QtGui.QPen(c, 1.4)
        pen.setCapStyle(QtCore.Qt.FlatCap)
        if wire.style == "lane":
            pen.setDashPattern([4, 3])
        self.setPen(pen)
        self.setZValue(-1)
        # the arrowhead, its tip on the port (PathView's shape)
        head = QtGui.QPainterPath()
        head.moveTo(-6, -3.2)
        head.lineTo(0, 0)
        head.lineTo(-6, 3.2)
        head.closeSubpath()
        angle = {(1, 0): 0, (-1, 0): 180, (0, 1): 90, (0, -1): -90}.get((dx, dy), 0)
        self.arrow = QtWidgets.QGraphicsPathItem(head, self)
        self.arrow.setBrush(c)
        self.arrow.setPen(QtCore.Qt.NoPen)
        self.arrow.setRotation(angle)
        self.arrow.setPos(x1, y1)
        self.base = QtGui.QPen(pen)

    def set_chosen(self, on):
        pen = QtGui.QPen(self.base)
        if on:
            pen.setColor(_qc(ACCENT))
            pen.setWidthF(2.6)
        self.setPen(pen)


def _near_segment(pt, a, b, d):
    """Is pt within d of the orthogonal segment a-b?"""
    (x0, y0), (x1, y1) = a, b
    if x0 == x1:
        return abs(pt.x() - x0) <= d and min(y0, y1) - d <= pt.y() <= max(y0, y1) + d
    return abs(pt.y() - y0) <= d and min(x0, x1) - d <= pt.x() <= max(x0, x1) + d


class GraphView(QtWidgets.QGraphicsView):
    """The quest's nodes and wires, edited by hand (quest_graph.build_nodes): nodes stand where they are put, every
    output is a port that is dragged onto a node to wire it, every input takes its wire off again."""
    picked = QtCore.Signal(str)
    opened = QtCore.Signal(str)
    kind_menu = QtCore.Signal(str, QtCore.QPoint)
    node_menu = QtCore.Signal(str, QtCore.QPoint)
    wire_menu = QtCore.Signal(object, QtCore.QPoint)
    place = QtCore.Signal(str, object)
    moved = QtCore.Signal(str, int, int)
    connect = QtCore.Signal(str, str, str, bool)        # from node, its output, to node, beside those there (Shift)
    relink = QtCore.Signal(object, str)                 # a wire taken off an input, put onto another node
    unlink = QtCore.Signal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setScene(QtWidgets.QGraphicsScene(self))
        self.setRenderHints(QtGui.QPainter.Antialiasing | QtGui.QPainter.TextAntialiasing)
        self.setTransformationAnchor(QtWidgets.QGraphicsView.NoAnchor)     # (wheelEvent keeps the mouse's point)
        self.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        self.setFrameShape(QtWidgets.QFrame.NoFrame)
        self.setViewportUpdateMode(QtWidgets.QGraphicsView.FullViewportUpdate)
        self.setMouseTracking(True)
        self.graph = None
        self.items = {}
        self.wire_items = []
        self.chosen = None
        self.chosen_wire = None             # the link [from, output, to] picked (right click: remove)
        self.live = None
        self.press = None                   # (what, data, viewport point) of the left button held
        self.drag = None                    # ("move", id, offset) | ("wire", id, output) | ("rewire", link) | ("block",
        self.drop = None                    # kind) | ("pan", point); where the dragged thing would go now
        self.cursor_at = None
        self.hot_port = None
        self.breathe = QtCore.QTimer(self)             # the picked node's outline breathes
        self.breathe.setInterval(60)
        self.breathe.timeout.connect(self._breathe)
        self.breathe.start()

    # --- building
    def show_graph(self, g, keep=True):
        """A graph built (quest_graph.build_nodes): sized, routed, drawn - where the nodes were put."""
        centre = self.mapToScene(self.viewport().rect().center()) if self.graph is not None and keep else None
        for n in g.nodes.values():
            n.w, n.h = L.size(n)
        R.route(g)
        self.graph = g
        s = self.scene()
        s.clear()
        self.items, self.wire_items = {}, []
        box = QtCore.QRectF()
        for n in g.nodes.values():
            box = box.united(QtCore.QRectF(n.x, n.y, n.w, n.h))
        for w in g.wires:
            if len(w.points) >= 2:
                it = WireItem(w)
                it.set_chosen(w.link == self.chosen_wire)
                self.wire_items.append(it)
                s.addItem(it)
        for n in g.nodes.values():
            it = NodeItem(n, self)
            self.items[n.id] = it
            s.addItem(it)
        s.setSceneRect(box.adjusted(-3000, -3000, 3000, 3000))      # room to move and zoom anywhere
        if self.chosen in self.items:
            self.items[self.chosen].selected = True
        if centre is not None:
            self.centerOn(centre)
        else:
            self.home()

    def has_input(self, nid):
        return self.graph.nodes[nid].kind != "start"

    def exit_colour(self, node, k):
        ex = node.exits[k]
        return QG.PORT_COLOUR.get(ex.to, EDGE if getattr(ex, "wired", False) else MUTED)

    def kinds_of(self, node):
        """The kinds a node's block can be (its title opens them), or [] for the graph's own nodes."""
        if node.card is None or node.card[1] is None or node.block in ("chapter", "end") or not node.block:
            return []
        from . import features
        kinds = QG.KINDS_OF.get(node.block, [])
        if not features.experimental():             # Change world switches Edit Vanilla's changes (experimental)
            kinds = [k for k in kinds if k != "worldchange"]
        return kinds

    # --- looking around
    def home(self):
        """All of it in sight, from its top."""
        self.resetTransform()
        if self.graph is None or not self.graph.nodes:
            return
        g = self.graph
        left = min(n.x for n in g.nodes.values())
        right = max(n.x + n.w for n in g.nodes.values())
        top = min(n.y for n in g.nodes.values())
        want = min(1.0, max(0.55, (self.viewport().width() - 40) / max(1, right - left + 40)))
        self.scale(want, want)
        self.centerOn(QtCore.QPointF((left + right) / 2, top + self.viewport().height() / 2 / want - 30 / want))

    def _breathe(self):
        it = self.items.get(self.chosen)
        if it is not None and it.selected and self.isVisible():
            it.update()

    def select(self, nid):
        for k, it in self.items.items():
            on = k == nid
            if it.selected != on:
                it.selected = on
                it.update()
        self.chosen = nid

    def select_wire(self, link):
        self.chosen_wire = link
        for it in self.wire_items:
            it.set_chosen(it.wire.link == link)

    def show_node(self, nid, margin=40):
        it = self.items.get(nid)
        if it is not None:
            self.ensureVisible(it.sceneBoundingRect(), margin, margin)

    def wheelEvent(self, e):
        """Zoom around the point under the mouse: it stays where it is (Maxim: 'zoom does not go to the mouse')."""
        f = 1.15 ** (e.angleDelta().y() / 120)
        now = self.transform().m11()
        f = max(0.25 / now, min(2.0 / now, f))
        at = e.position().toPoint()
        before = self.mapToScene(at)
        self.scale(f, f)
        moved = self.mapFromScene(before) - at          # where that point went: scrolled back under the mouse
        self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() + moved.x())
        self.verticalScrollBar().setValue(self.verticalScrollBar().value() + moved.y())

    def drawBackground(self, p, rect):
        p.fillRect(rect, QtGui.QColor(SURFACE))
        gap = 20
        if self.transform().m11() < 0.4:
            return
        p.setPen(QtCore.Qt.NoPen)
        p.setBrush(QtGui.QColor(DOT))
        x0 = int(rect.left()) // gap * gap
        y0 = int(rect.top()) // gap * gap
        y = y0
        while y < rect.bottom():
            x = x0
            while x < rect.right():
                p.drawEllipse(QtCore.QPointF(x, y), 1.1, 1.1)
                x += gap
            y += gap

    # --- what is where
    def node_at(self, pt):
        for it in self.scene().items(pt):
            if isinstance(it, NodeItem) and it.node.x <= pt.x() <= it.node.x + it.node.w \
                    and it.node.y <= pt.y() <= it.node.y + it.node.h:
                return it.node
        return None

    def port_at(self, pt):
        """(node id, output) of the output port at pt: "next" at a node's bottom, an exit's index at its right."""
        for n in self.graph.nodes.values():
            if n.goes_on and n.kind not in L.ENDS:
                x, y = L.port(n, "next")
                if abs(pt.x() - x) <= PORT_HIT + 4 and abs(pt.y() - y) <= PORT_HIT:
                    return n.id, "next"
            if n.exits and n.x + n.w - PORT_HIT <= pt.x() <= n.x + n.w + PORT_HIT:
                for k in range(len(n.exits)):
                    if abs(pt.y() - L.port(n, k)[1]) <= L.EXIT / 2:
                        return n.id, k
        return None

    def input_at(self, pt):
        """The node whose input (the top of it) is at pt."""
        for n in self.graph.nodes.values():
            if n.kind == "start":
                continue
            x, y = L.port(n, "in")
            if abs(pt.x() - x) <= PORT_HIT + 6 and abs(pt.y() - y) <= PORT_HIT:
                return n.id
        return None

    def wire_at(self, pt, d=6):
        for w in self.graph.wires:
            if any(_near_segment(pt, a, b, d) for a, b in zip(w.points, w.points[1:])):
                return w
        return None

    def output_name(self, nid, port):
        """An output's name (the link's): "next" or the exit's."""
        return "next" if port == "next" else self.graph.nodes[nid].exits[port].to

    def links_into(self, nid):
        return [w.link for w in self.graph.wires if w.dst == nid]

    # --- the mouse
    def mousePressEvent(self, e):
        if self.graph is None:
            return
        at = e.position().toPoint()
        pt = self.mapToScene(at)
        if e.button() == QtCore.Qt.MiddleButton:
            self.press = ("pan", None, at)
            return
        if e.button() != QtCore.Qt.LeftButton:
            return
        port = self.port_at(pt)
        if port is not None:
            self.press = ("port", port, at)
            return
        inp = self.input_at(pt)
        if inp is not None and self.links_into(inp):
            self.press = ("input", inp, at)
            return
        n = self.node_at(pt)
        if n is not None:
            item = self.items.get(n.id)
            title = item is not None and item.title_rect is not None and \
                item.title_rect.contains(QtCore.QPointF(pt.x() - n.x, pt.y() - n.y))
            self.press = ("title" if title else "node", n.id, at, QtCore.QPointF(pt.x() - n.x, pt.y() - n.y))
            return
        w = self.wire_at(pt)
        if w is not None:
            self.press = ("wire", w.link, at)
            return
        self.press = ("pan", None, at)

    def mouseMoveEvent(self, e):
        if self.graph is None:
            return
        at = e.position().toPoint()
        pt = self.mapToScene(at)
        if self.press and not self.drag and (at - self.press[2]).manhattanLength() >= MOVE_PX:
            what, data = self.press[0], self.press[1]
            if what == "pan":
                self.drag = ("pan", at)
            elif what == "port":
                self.drag = ("wire", data[0], data[1])
            elif what == "input":
                self.drag = ("rewire", self.links_into(data)[-1])
            elif what in ("node", "title"):
                self.drag = ("move", data, self.press[3])
        if self.drag:
            kind = self.drag[0]
            if kind == "pan":
                d = at - self.drag[1]
                self.drag = ("pan", at)
                self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() - d.x())
                self.verticalScrollBar().setValue(self.verticalScrollBar().value() - d.y())
                return
            self.cursor_at = pt
            if kind == "move":
                it = self.items[self.drag[1]]
                it.setPos(pt - self.drag[2])            # the node follows the mouse; its wires are drawn anew after
                for w in self.wire_items:
                    if self.drag[1] in (w.wire.src, w.wire.dst):
                        w.setVisible(False)
            else:
                n = self.node_at(pt)
                self.drop = n.id if n is not None and n.kind != "start" else None
            self.viewport().update()
            return
        hot = self.port_at(pt)
        if hot != self.hot_port:
            old, self.hot_port = self.hot_port, hot
            for h in (old, hot):
                if h and h[0] in self.items:
                    self.items[h[0]].update()
        on_input = self.input_at(pt) is not None
        self.viewport().setCursor(QtCore.Qt.CrossCursor if hot or on_input else QtCore.Qt.ArrowCursor)

    def mouseReleaseEvent(self, e):
        press, drag, drop = self.press, self.drag, self.drop
        self.press = self.drag = self.drop = self.cursor_at = None
        self.viewport().update()
        if press is None or e.button() not in (QtCore.Qt.LeftButton, QtCore.Qt.MiddleButton):
            return
        if drag:
            kind = drag[0]
            if kind == "move":
                n = self.graph.nodes[drag[1]]
                pos = self.items[drag[1]].pos()
                x, y = int(round(pos.x() / L.GRID) * L.GRID), int(round(pos.y() / L.GRID) * L.GRID)
                if (x, y) != (n.x, n.y):
                    self.moved.emit(drag[1], x, y)
                else:
                    self.items[drag[1]].setPos(n.x, n.y)
                    for w in self.wire_items:
                        w.setVisible(True)
            elif kind == "wire":
                if drop is not None:
                    beside = bool(e.modifiers() & QtCore.Qt.ShiftModifier)
                    self.connect.emit(drag[1], self.output_name(drag[1], drag[2]), drop, beside)
            elif kind == "rewire":
                if drop is not None:
                    self.relink.emit(drag[1], drop)
                else:
                    self.unlink.emit(drag[1])       # taken off, let go on nothing: gone
            return
        what, data = press[0], press[1]
        if what == "title":
            n = self.graph.nodes[data]
            self.picked.emit(data)
            pos = self.mapToGlobal(self.mapFromScene(QtCore.QPointF(n.x + 10, n.y + L.HEAD)))
            self.kind_menu.emit(data, pos)
        elif what in ("node", "port", "input"):
            self.select_wire(None)
            self.picked.emit(data if what in ("node", "input") else data[0])
        elif what == "wire":
            self.select_wire(data)
        elif what == "pan":
            self.select_wire(None)

    def contextMenuEvent(self, e):
        if self.graph is None:
            return
        pt = self.mapToScene(e.pos())
        n = self.node_at(pt)
        if n is not None:
            self.picked.emit(n.id)
            self.node_menu.emit(n.id, e.globalPos())
            return
        w = self.wire_at(pt)
        if w is not None:
            self.select_wire(w.link)
            self.wire_menu.emit(w.link, e.globalPos())

    def mouseDoubleClickEvent(self, e):
        n = self.node_at(self.mapToScene(e.position().toPoint())) if self.graph is not None else None
        if e.button() != QtCore.Qt.LeftButton:
            return
        if n is not None:
            self.opened.emit(n.id)
        elif self.graph is not None:
            self.home()

    # --- a block from the sidebar, dragged over the graph: onto a wire - put into it; anywhere else - where it is
    # let go, on its own (wired by hand)
    def drop_at(self, pt):
        w = self.wire_at(pt, 8)
        if w is not None:
            return ("wire", w.link, pt.x(), pt.y())
        return ("free", pt.x(), pt.y())

    def block_over(self, kind, global_pos):
        """The sidebar's block is dragged; global_pos: where the mouse is. Returns True when over the graph."""
        at = self.viewport().mapFromGlobal(global_pos)
        inside = self.viewport().rect().contains(at)
        self.drag = ("block", kind) if inside else None
        self.cursor_at = self.mapToScene(at) if inside else None
        self.drop = self.drop_at(self.cursor_at) if inside else None
        self.viewport().update()
        return inside

    def block_dropped(self, kind, global_pos):
        inside = self.block_over(kind, global_pos)
        drop = self.drop
        self.drag = self.drop = self.cursor_at = None
        self.viewport().update()
        if inside and drop is not None:
            self.place.emit(kind, drop)
        return inside

    # --- what a drag would do, drawn over the graph
    def drawForeground(self, p, rect):
        if not self.drag or self.drag[0] == "pan" or self.cursor_at is None:
            return
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        accent = _qc(ACCENT)
        kind = self.drag[0]
        if kind in ("wire", "rewire"):
            if kind == "wire":
                src, port = self.graph.nodes[self.drag[1]], self.drag[2]
            else:
                a, name, _b = self.drag[1]
                src = self.graph.nodes[a]
                port = "next" if name == "next" else next((k for k, e in enumerate(src.exits) if e.to == name), "next")
            a = QtCore.QPointF(*L.port(src, port))
            p.setPen(QtGui.QPen(accent if self.drop else _qc(MUTED), 1.6, QtCore.Qt.DashLine))
            p.drawLine(a, self.cursor_at)
            if self.drop:
                n = self.graph.nodes[self.drop]
                p.setPen(QtGui.QPen(accent, 2))
                p.setBrush(QtCore.Qt.NoBrush)
                p.drawPath(shape(n, QtCore.QRectF(n.x - 3, n.y - 3, n.w + 6, n.h + 6)))
            return
        if kind == "move":
            it = self.items[self.drag[1]]
            n = it.node
            pos = it.pos()
            p.setPen(QtGui.QPen(_qc(MUTED), 1.2, QtCore.Qt.DashLine))
            for w in self.graph.wires:                  # its wires, straight, while it moves
                if w.src == n.id or w.dst == n.id:
                    s, d = self.graph.nodes[w.src], self.graph.nodes[w.dst]
                    sp = self.items[s.id].pos()
                    dp = self.items[d.id].pos()
                    ax, ay = L.port(s, w.port)
                    bx, by = L.port(d, "in")
                    p.drawLine(QtCore.QPointF(ax - s.x + sp.x(), ay - s.y + sp.y()),
                               QtCore.QPointF(bx - d.x + dp.x(), by - d.y + dp.y()))
            _ = pos
            return
        d = self.drop
        if d is None:
            return
        if d[0] == "wire":
            w = next((x for x in self.graph.wires if x.link == d[1]), None)
            if w is not None:
                p.setPen(QtGui.QPen(accent, 3))
                p.setBrush(QtCore.Qt.NoBrush)
                p.drawPath(wire_path(w.points))
        ghost = QtCore.QRectF(self.cursor_at.x() - 60, self.cursor_at.y() - 14, 120, 28)
        p.setPen(QtGui.QPen(accent, 1, QtCore.Qt.DashLine))
        p.setBrush(_qc(RAISED, 200))
        p.drawRect(ghost)
        p.setPen(_qc(TEXT))
        p.setFont(_font(10, True))
        what = self.drag[1]
        p.drawText(ghost, QtCore.Qt.AlignCenter, QG.LABEL.get(what, what).upper())
