"""The sidebar of the quest graph: its six blocks, each in the shape and colour it has in the graph. A block
dragged onto the graph goes where it is let go (graph_view: a wire, a node, an open exit, the empty grid); a block
clicked goes after the node picked. Dragged by hand inside the one window (a drag of the system would be a window
of its own and take the focus from the game)."""
from PySide6 import QtCore, QtGui, QtWidgets

from . import graph_view as V
from . import quest_graph as QG
from .tooltips import tip

# the colour of each block in the sidebar (in the graph: its kind's family, once chosen)
COLOUR = {"goal": "#5aa9e6", "action": QG.FAMILY["action"], "choice": QG.FAMILY["choice"],
          "parallel": QG.FAMILY["lane"], "chapter": QG.FAMILY["story"], "end": QG.SUCCESS}
WIDTH = 96


class BlockTile(QtWidgets.QWidget):
    def __init__(self, block, label, bar, colour=None, tip_key=None):
        super().__init__()
        self.block, self.label, self.bar = block, label, bar
        self.colour = colour or COLOUR[block]
        self.setFixedSize(WIDTH, 40)
        self.setCursor(QtCore.Qt.OpenHandCursor)
        self.setMouseTracking(True)
        self.setAttribute(QtCore.Qt.WA_Hover, True)
        self.hot = False
        self.pressed = None
        self.dragging = False
        tip(self, tip_key or f"blk.{block}")
        self.setAccessibleName(label)          # (painted: what screen readers and agent.py read)

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        node = QG.Node("", self.block if self.block in ("chapter", "end") else self.block, "", block=self.block)
        if self.block == "end":
            node.kind = "end"
        r = QtCore.QRectF(2.5, 4.5, self.width() - 5, self.height() - 9)
        c = QtGui.QColor(self.colour)
        p.setBrush(QtGui.QColor("#22222e" if self.block == "chapter" else V.RAISED))
        pen = QtGui.QPen(c if self.hot else QtGui.QColor(c.red(), c.green(), c.blue(), 150), 1.2)
        if self.block == "parallel":
            pen.setStyle(QtCore.Qt.DashLine)
        p.setPen(pen)
        p.drawPath(V.shape(node, r))
        p.setPen(c)
        p.setFont(V._font(10, True, 0.5))
        p.drawText(r, QtCore.Qt.AlignCenter, self.label.upper())

    def enterEvent(self, e):
        self.hot = True
        self.update()
        super().enterEvent(e)

    def leaveEvent(self, e):
        self.hot = False
        self.update()
        super().leaveEvent(e)

    def mousePressEvent(self, e):
        if e.button() == QtCore.Qt.LeftButton:
            self.pressed = e.globalPosition().toPoint()
            self.dragging = False

    def mouseMoveEvent(self, e):
        if self.pressed is None:
            return
        at = e.globalPosition().toPoint()
        if not self.dragging and (at - self.pressed).manhattanLength() >= V.MOVE_PX:
            self.dragging = True
            self.setCursor(QtCore.Qt.ClosedHandCursor)
        if self.dragging:
            self.bar.graph.block_over(self.block, at)

    def mouseReleaseEvent(self, e):
        if e.button() != QtCore.Qt.LeftButton or self.pressed is None:
            return
        at = e.globalPosition().toPoint()
        self.pressed = None
        self.setCursor(QtCore.Qt.OpenHandCursor)
        if self.dragging:
            self.dragging = False
            self.bar.graph.block_dropped(self.block, at)
        elif self.rect().contains(e.position().toPoint()):
            self.bar.clicked(self.block)


class BlockBar(QtWidgets.QWidget):
    """The blocks, one under the other. `clicked(block)`: a block clicked instead of dragged. `blocks`: [(block,
    label, colour, tooltip key)] of another graph (a dialogue's); else the quest's."""

    def __init__(self, graph, clicked, blocks=None):
        super().__init__()
        self.graph, self.clicked = graph, clicked
        self.setFixedWidth(WIDTH + 4)
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(0, 2, 0, 0)
        v.setSpacing(4)
        self.tiles = {}
        for block, label, colour, key in blocks or [(b, lab, None, None) for b, lab, _k in QG.BLOCKS]:
            t = BlockTile(block, label, self, colour, key)
            self.tiles[block] = t
            v.addWidget(t)
        v.addStretch(1)
