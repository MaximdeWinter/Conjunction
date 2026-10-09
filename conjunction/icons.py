"""Conjunction's icons: Lucide outlines (lucide.dev, ISC licence - icons/LICENSE), only where an icon says it without a
word (Maxim, 01.10.): Remove is a trash can everywhere, Settings a gear, Close an x, Move up / down chevrons, Play /
Stop, Back, More, something still missing an octagon with a mark, a line's voice audio lines (red with an x: none).

    from .icons import icon, icon_button
    b = icon_button("trash-2", fn, "dlg.remove")     # a small flat button, its tooltip the TIPS line
"""
import os

from PySide6 import QtCore, QtGui, QtSvg, QtWidgets

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
GREY = "#cfcfcf"
RED = "#d9534f"
GREEN = "#5cb85c"
_cache = {}


def pixmap(name, color=GREY, size=16):
    """An icon drawn in a colour (the SVG's currentColor) at a size, sharp on high-dpi screens."""
    key = (name, color, size)
    if key not in _cache:
        with open(os.path.join(DIR, name + ".svg"), encoding="utf-8") as f:
            data = f.read().replace("currentColor", color)
        r = QtSvg.QSvgRenderer(QtCore.QByteArray(data.encode()))
        app = QtGui.QGuiApplication.instance()
        ratio = app.devicePixelRatio() if app else 1.0
        pm = QtGui.QPixmap(int(size * ratio), int(size * ratio))
        pm.fill(QtCore.Qt.transparent)
        p = QtGui.QPainter(pm)
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        r.render(p)
        p.end()
        pm.setDevicePixelRatio(ratio)
        _cache[key] = pm
    return _cache[key]


def icon(name, color=GREY, size=16, hover="#ffffff"):
    """A QIcon: grey, lighter under the mouse (Active), dim when disabled."""
    ic = QtGui.QIcon()
    ic.addPixmap(pixmap(name, color, size), QtGui.QIcon.Normal)
    ic.addPixmap(pixmap(name, hover if color == GREY else color, size), QtGui.QIcon.Active)
    ic.addPixmap(pixmap(name, "#5a5a5e", size), QtGui.QIcon.Disabled)
    return ic


def icon_button(name, fn, key=None, color=GREY, size=16, object_name="icon"):
    """A small flat button with only an icon; its tooltip (a TIPS key) is its label."""
    from .tooltips import tip
    b = QtWidgets.QToolButton()
    b.setObjectName(object_name)
    b.setIcon(icon(name, color, size))
    b.setIconSize(QtCore.QSize(size, size))
    b.setFocusPolicy(QtCore.Qt.NoFocus)
    b.setAutoRaise(True)
    b.setCursor(QtCore.Qt.PointingHandCursor)
    b.setStyleSheet("QToolButton{border:none;background:transparent;padding:2px}"
                    "QToolButton:hover{background:rgba(255,255,255,0.08);border-radius:0}")
    if fn is not None:
        b.clicked.connect(fn)
    if key:
        tip(b, key)
    return b


def set_icon(button, name, color=GREY, size=16):
    """Change a button's icon (a state: the voice of a line chosen or not)."""
    button.setIcon(icon(name, color, size))
    button.setIconSize(QtCore.QSize(size, size))
