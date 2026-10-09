"""The dialogue drawn (dialogue_flow lays it out), in the look of the quest graph: the dark dotted grid, blocks,
orthogonal wires. A click on a block picks what it shows; the wheel zooms to the mouse, the empty grid dragged moves.

    view.show_flow(flow, keep)      draws it; keep: the view stays where it was
    signals: picked(ref, row)       ref: the box's (see dialogue_flow.Box.ref); row: the answer clicked or -1
             opened(ref, row)       a double click
             menu(ref, row, QPoint) a right click (global point)
             place(block, ref, row) a block of the sidebar let go on a box (block_over / block_dropped: the sidebar
                                    drags it by hand, as on the quest graph)
"""
from PySide6 import QtCore, QtGui, QtWidgets

from . import dialogue_flow as F
from .graph_view import DOT, MUTED, PICKED, RAISED, SURFACE, TEXT, _font, _qc, pulse, wire_path

BORDER = QtGui.QColor(128, 128, 144, 120)
MOVE_PX = 6


class BoxItem(QtWidgets.QGraphicsItem):
    def __init__(self, box, view):
        super().__init__()
        self.box, self.view = box, view
        self.setPos(box.x, box.y)
        self.setAcceptHoverEvents(True)
        self.hot = False
        self.hot_row = -1
        self.selected = False

    def boundingRect(self):
        return QtCore.QRectF(-6, -6, self.box.w + 12, self.box.h + 12)

    def row_at(self, pos):
        b = self.box
        if b.kind != "choice":
            return -1
        k = int((pos.y() - F.HEAD) // F.ROW)
        return k if 0 <= k < len(b.rows) and pos.y() >= F.HEAD else -1

    def paint(self, p, _o, _w=None):
        b = self.box
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        r = QtCore.QRectF(0.5, 0.5, b.w - 1, b.h - 1)
        radius = {"start": 15, "pill": b.h / 2, "choice": 6, "if": 6, "random": 6}.get(b.kind, 8)
        colour = _qc(b.colour or MUTED)
        if self.selected and not (b.kind == "choice" and self.view.chosen_row):
            p.setPen(QtGui.QPen(_qc(PICKED, int(50 + 110 * pulse())), 6))     # picked: gold, breathing
            p.setBrush(QtCore.Qt.NoBrush)
            p.drawRect(r)
        if b.kind == "label":
            self.paint_label(p, b)
            return
        p.setBrush(_qc(RAISED))
        pen = QtGui.QPen(BORDER, 1)
        if b.kind in ("pill", "choice", "if", "random"):
            pen = QtGui.QPen(_qc(b.colour, 200), 1.2)
        elif self.hot or self.selected:
            pen = QtGui.QPen(_qc("#b0b0c0", 160), 1)
        p.setPen(pen)
        p.drawRect(r)
        if b.kind == "label":                   # an answer's words over its way
            p.setFont(_font(10, True))
            p.setPen(colour)
            p.drawText(r, QtCore.Qt.AlignVCenter | QtCore.Qt.AlignLeft,
                       QtGui.QFontMetrics(_font(10, True)).elidedText(b.title, QtCore.Qt.ElideRight, int(b.w)))
            return
        if b.kind == "pill":
            p.setFont(_font(9, True, 0.6))
            p.setPen(colour)
            p.drawText(r, QtCore.Qt.AlignCenter, b.title)
            return
        if b.kind == "start":
            p.setFont(_font(9, True, 0.6))
            p.setPen(_qc(MUTED))
            p.drawText(QtCore.QRectF(14, 0, 130, b.h), QtCore.Qt.AlignVCenter, b.title)
            p.setFont(_font(11))
            if b.rows:                              # (a monologue: no one to talk to)
                p.drawText(QtCore.QRectF(130, 0, b.w - 140, b.h), QtCore.Qt.AlignVCenter, "· " + str(b.rows[0]))
            return
        if b.kind == "lines":
            y = 8
            for who, name, text, _voiced, speaker in b.rows:
                c = _qc(speaker)
                h = F.LINE * len(text)
                p.setPen(QtCore.Qt.NoPen)
                p.setBrush(c)
                p.drawRect(QtCore.QRectF(10, y + 2, 3, h - 3))
                p.setFont(_font(9, True, 0.5))
                p.setPen(c)
                p.drawText(QtCore.QRectF(20, y, 84, F.LINE), QtCore.Qt.AlignVCenter, name[:14])
                p.setFont(_font(12))
                p.setPen(_qc(TEXT))
                for k, t in enumerate(text):
                    p.drawText(QtCore.QRectF(104, y + k * F.LINE, b.w - 112, F.LINE), QtCore.Qt.AlignVCenter, t)
                y += h + 5
            return
        if b.kind == "script":
            p.setFont(_font(9, True, 0.6))
            p.setPen(colour)
            p.drawText(QtCore.QRectF(12, 0, 70, b.h), QtCore.Qt.AlignVCenter, b.title)
            p.setFont(_font(11))
            p.drawText(QtCore.QRectF(80, 0, b.w - 90, b.h), QtCore.Qt.AlignVCenter, str(b.rows[0]))
            return
        # a choice / if / random: its title, a choice its answers
        p.setFont(_font(9, True, 0.6))
        p.setPen(colour)
        p.drawText(QtCore.QRectF(12, 0, b.w - 20, F.HEAD if b.kind == "choice" else b.h),
                   QtCore.Qt.AlignVCenter, b.title)
        if b.kind != "choice":
            return
        fm = QtGui.QFontMetrics(_font(12))
        for k, row in enumerate(b.rows):
            y = F.HEAD + k * F.ROW
            kind = row["kind"]
            c = _qc(F.MAIN if row["main"] and kind == "on" else F.COLOUR[kind])
            if self.view.chosen_row == (b.ref, k):     # the answer picked: gold, breathing
                p.setPen(QtGui.QPen(_qc(PICKED, int(90 + 130 * pulse())), 1.6))
                p.setBrush(_qc(PICKED, 24))
                p.drawRect(QtCore.QRectF(2, y + 1, b.w - 4, F.ROW - 2))
            elif self.hot_row == k:
                p.setPen(QtCore.Qt.NoPen)
                p.setBrush(_qc("#ffffff", 14))
                p.drawRect(QtCore.QRectF(1, y, b.w - 2, F.ROW))
            p.setPen(QtCore.Qt.NoPen)
            p.setBrush(c)
            p.drawRect(QtCore.QRectF(8, y + 5, 3, F.ROW - 10))
            # the tags at the right: what kind of answer, what it costs / needs / does
            tags = [t for t in row["chips"] if t != "main"] + ([F.WORD[kind]] if F.WORD[kind] else [])
            x = b.w - 10
            p.setFont(_font(9, True))
            tm = QtGui.QFontMetrics(_font(9, True))
            for t in reversed(tags):
                tw = tm.horizontalAdvance(t) + 12
                x -= tw
                tc = c if t == F.WORD[kind] else _qc("#a0a0b0")
                p.setPen(QtGui.QPen(tc, 1))
                p.setBrush(QtCore.Qt.NoBrush)
                p.drawRect(QtCore.QRectF(x, y + 4, tw, F.ROW - 8))
                p.drawText(QtCore.QRectF(x, y + 4, tw, F.ROW - 8), QtCore.Qt.AlignCenter, t)
                x -= 5
            p.setFont(_font(12, row["main"]))
            p.setPen(c)
            p.drawText(QtCore.QRectF(18, y, x - 22, F.ROW), QtCore.Qt.AlignVCenter,
                       fm.elidedText(row["text"], QtCore.Qt.ElideRight, int(max(10, x - 26))))
            if kind != "on":                    # its way leaves on the right: a port
                p.setPen(QtGui.QPen(c, 1.2))
                p.setBrush(c)
                p.drawRect(QtCore.QRectF(b.w - 3, y + F.ROW / 2 - 4, 6, 8))

    def paint_label(self, p, b):
        p.setFont(_font(10, True))
        p.setPen(_qc(b.colour or MUTED))
        p.drawText(QtCore.QRectF(2, 0, b.w, b.h), QtCore.Qt.AlignVCenter | QtCore.Qt.AlignLeft,
                   QtGui.QFontMetrics(_font(10, True)).elidedText(b.title, QtCore.Qt.ElideRight, int(b.w - 4)))

    def hoverEnterEvent(self, _e):
        self.hot = True
        self.update()

    def hoverLeaveEvent(self, _e):
        self.hot, self.hot_row = False, -1
        self.update()

    def hoverMoveEvent(self, e):
        k = self.row_at(e.pos())
        if k != self.hot_row:
            self.hot_row = k
            self.update()


class WireItem(QtWidgets.QGraphicsPathItem):
    def __init__(self, wire):
        super().__init__()
        pts = list(wire.points)
        c = _qc(wire.colour or MUTED)
        (x0, y0), (x1, y1) = pts[-2], pts[-1]
        dx, dy = (x1 > x0) - (x1 < x0), (y1 > y0) - (y1 < y0)
        if wire.arrow:
            pts[-1] = (x1 - 6 * dx, y1 - 6 * dy)
        self.setPath(wire_path(pts))
        pen = QtGui.QPen(c, 1.4)
        pen.setCapStyle(QtCore.Qt.FlatCap)
        if wire.dashed:
            pen.setDashPattern([4, 3])
        self.setPen(pen)
        self.setZValue(-1)
        if wire.arrow:
            head = QtGui.QPainterPath()
            head.moveTo(-6, -3.2)
            head.lineTo(0, 0)
            head.lineTo(-6, 3.2)
            head.closeSubpath()
            arrow = QtWidgets.QGraphicsPathItem(head, self)
            arrow.setBrush(c)
            arrow.setPen(QtCore.Qt.NoPen)
            arrow.setRotation({(1, 0): 0, (-1, 0): 180, (0, 1): 90, (0, -1): -90}.get((dx, dy), 0))
            arrow.setPos(x1, y1)


class FlowView(QtWidgets.QGraphicsView):
    picked = QtCore.Signal(object, int)
    opened = QtCore.Signal(object, int)
    menu = QtCore.Signal(object, int, QtCore.QPoint)
    place = QtCore.Signal(str, object, int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setScene(QtWidgets.QGraphicsScene(self))
        self.setRenderHints(QtGui.QPainter.Antialiasing | QtGui.QPainter.TextAntialiasing)
        self.setTransformationAnchor(QtWidgets.QGraphicsView.NoAnchor)
        self.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        self.setFrameShape(QtWidgets.QFrame.NoFrame)
        self.setViewportUpdateMode(QtWidgets.QGraphicsView.FullViewportUpdate)
        self.setMouseTracking(True)
        self.flow = None
        self.items_ = []
        self.chosen = None                  # the ref picked
        self.chosen_row = None              # (ref, row) of the answer picked
        self.press = None
        self.panning = None
        self.breathe = QtCore.QTimer(self)             # the picked box's outline breathes
        self.breathe.setInterval(60)
        self.breathe.timeout.connect(self._breathe)
        self.breathe.start()
        self.drop_on = None                 # (box item, row) a block dragged from the sidebar is over
        self.drag_block = None
        self.cursor_at = None

    def show_flow(self, flow, keep=True):
        centre = self.mapToScene(self.viewport().rect().center()) if self.flow is not None and keep else None
        self.flow = flow
        s = self.scene()
        s.clear()
        self.items_ = []
        for w in flow.wires:
            if len(w.points) >= 2:
                s.addItem(WireItem(w))
        for b in flow.boxes:
            it = BoxItem(b, self)
            it.selected = self._same(b.ref, self.chosen)
            self.items_.append(it)
            s.addItem(it)
        s.setSceneRect(QtCore.QRectF(-3000, -3000, flow.w + 6000, flow.h + 6000))
        if centre is not None:
            self.centerOn(centre)
        else:
            self.home()

    @staticmethod
    def _same(a, b):
        return a is not None and b is not None and len(a) == len(b) and all(
            x is y or (isinstance(x, (str, int)) and x == y) for x, y in zip(a, b))

    def home(self):
        self.resetTransform()
        if self.flow is None:
            return
        want = min(1.0, max(0.55, (self.viewport().width() - 40) / max(1.0, self.flow.w + 40)))
        self.scale(want, want)
        self.centerOn(QtCore.QPointF(self.flow.w / 2, self.viewport().height() / 2 / want - 20 / want))

    def _breathe(self):
        if self.chosen is not None and self.isVisible():
            for it in self.items_:
                if it.selected:
                    it.update()

    def select(self, ref, row=-1):
        self.chosen = ref
        self.chosen_row = (ref, row) if row >= 0 else None
        for it in self.items_:
            on = self._same(it.box.ref, ref)
            if it.selected != on or it.box.kind == "choice":
                it.selected = on
                it.update()

    def item_at(self, pt):
        for it in self.items_:
            b = it.box
            if b.x <= pt.x() <= b.x + b.w and b.y <= pt.y() <= b.y + b.h:
                return it
        return None

    def wheelEvent(self, e):
        f = 1.15 ** (e.angleDelta().y() / 120)
        now = self.transform().m11()
        f = max(0.25 / now, min(2.0 / now, f))
        at = e.position().toPoint()
        before = self.mapToScene(at)
        self.scale(f, f)
        moved = self.mapFromScene(before) - at
        self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() + moved.x())
        self.verticalScrollBar().setValue(self.verticalScrollBar().value() + moved.y())

    def drawBackground(self, p, rect):
        p.fillRect(rect, QtGui.QColor(SURFACE))
        if self.transform().m11() < 0.4:
            return
        p.setPen(QtCore.Qt.NoPen)
        p.setBrush(QtGui.QColor(DOT))
        gap = 20
        y = int(rect.top()) // gap * gap
        while y < rect.bottom():
            x = int(rect.left()) // gap * gap
            while x < rect.right():
                p.drawEllipse(QtCore.QPointF(x, y), 1.1, 1.1)
                x += gap
            y += gap

    def mousePressEvent(self, e):
        if e.button() in (QtCore.Qt.LeftButton, QtCore.Qt.MiddleButton):
            self.press = e.position().toPoint()
            self.panning = None

    def mouseMoveEvent(self, e):
        at = e.position().toPoint()
        if self.press is not None and (self.panning is not None or (at - self.press).manhattanLength() >= MOVE_PX):
            last = self.panning or self.press
            d = at - last
            self.panning = at
            self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() - d.x())
            self.verticalScrollBar().setValue(self.verticalScrollBar().value() - d.y())

    def mouseReleaseEvent(self, e):
        press, panned = self.press, self.panning
        self.press = self.panning = None
        if press is None or panned is not None or e.button() != QtCore.Qt.LeftButton:
            return
        pt = self.mapToScene(e.position().toPoint())
        it = self.item_at(pt)
        if it is None:
            return
        row = it.row_at(QtCore.QPointF(pt.x() - it.box.x, pt.y() - it.box.y))
        self.select(it.box.ref, row)
        self.picked.emit(it.box.ref, row)

    def contextMenuEvent(self, e):
        pt = self.mapToScene(e.pos())
        it = self.item_at(pt)
        if it is not None:
            row = it.row_at(QtCore.QPointF(pt.x() - it.box.x, pt.y() - it.box.y))
            self.select(it.box.ref, row)
            self.picked.emit(it.box.ref, row)
            self.menu.emit(it.box.ref, row, e.globalPos())

    # --- a block of the sidebar dragged over the flow: it goes after the box it is let go on (into an answer's way
    # on its row); the empty grid: after what is picked
    def block_over(self, kind, global_pos):
        at = self.viewport().mapFromGlobal(global_pos)
        inside = self.viewport().rect().contains(at)
        self.drag_block = kind if inside else None
        self.cursor_at = self.mapToScene(at) if inside else None
        self.drop_on = None
        if inside:
            it = self.item_at(self.cursor_at)
            if it is not None:
                self.drop_on = (it, it.row_at(QtCore.QPointF(self.cursor_at.x() - it.box.x,
                                                             self.cursor_at.y() - it.box.y)))
        self.viewport().update()
        return inside

    def block_dropped(self, kind, global_pos):
        inside = self.block_over(kind, global_pos)
        on = self.drop_on
        self.drag_block = self.drop_on = self.cursor_at = None
        self.viewport().update()
        if inside:
            if on is not None:
                self.place.emit(kind, on[0].box.ref, on[1])
            else:
                self.place.emit(kind, self.chosen, self.chosen_row[1] if self.chosen_row else -1)
        return inside

    def drawForeground(self, p, rect):
        if self.drag_block is None or self.cursor_at is None:
            return
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        accent = QtGui.QColor("#0088E8")
        if self.drop_on is not None:
            b = self.drop_on[0].box
            row = self.drop_on[1]
            p.setPen(QtGui.QPen(accent, 2))
            p.setBrush(QtCore.Qt.NoBrush)
            if row >= 0:
                p.drawRect(QtCore.QRectF(b.x + 2, b.y + F.HEAD + row * F.ROW, b.w - 4, F.ROW))
            else:
                p.drawLine(QtCore.QPointF(b.x + b.w / 2 - 60, b.y + b.h + F.GAP / 2),
                           QtCore.QPointF(b.x + b.w / 2 + 60, b.y + b.h + F.GAP / 2))
        ghost = QtCore.QRectF(self.cursor_at.x() - 50, self.cursor_at.y() - 13, 100, 26)
        p.setPen(QtGui.QPen(accent, 1, QtCore.Qt.DashLine))
        p.setBrush(_qc(RAISED, 200))
        p.drawRect(ghost)
        p.setPen(_qc(TEXT))
        p.setFont(_font(10, True))
        p.drawText(ghost, QtCore.Qt.AlignCenter, self.drag_block.upper())

    def mouseDoubleClickEvent(self, e):
        pt = self.mapToScene(e.position().toPoint())
        it = self.item_at(pt)
        if it is None:
            self.home()
            return
        row = it.row_at(QtCore.QPointF(pt.x() - it.box.x, pt.y() - it.box.y))
        self.opened.emit(it.box.ref, row)
