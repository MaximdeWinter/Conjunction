"""Drop-down lists drawn inside the window they belong to - never a window of their own.

A QMenu (and a combo box's list) is a window of its own on Windows: it takes the focus from the game, the game
reacts to that, Conjunction takes the focus back - and a click on an entry got lost on the way (Maxim, 30.09.: a
drop-down 'tabbed out of the game, I could never choose'). Here a button keeps its QMenu as the list of entries (the
code that fills it and the tests stay as they are), but a click shows the entries as a list laid over the same
window, under the button. A click on an entry triggers it; a click anywhere else, or the window hiding, closes it.
Sub-menus become groups with a heading.

    attach(button, menu)        the button opens `menu`'s entries inline (button.menu() still returns it)
"""
from PySide6 import QtCore, QtWidgets

STYLE = ("QFrame#inline{background:#232326;border:1px solid #5a5a60;border-radius:0}"
         "QPushButton#entry{text-align:left;color:#ddd;background:transparent;border:none;padding:4px 14px 4px 10px;"
         "font:12px}"
         "QPushButton#entry:hover,QPushButton#entry[hot=\"true\"]{background:#3a3a40;color:#fff}"
         "QPushButton#entry:checked{color:#fff;background:#4b4b50}"
         "QLabel#group{color:#9a9a9a;font:bold 11px;padding:6px 10px 2px 10px}"
         "QFrame#line{background:#444;max-height:1px;margin:3px 6px}")
_open = []                                   # the list shown now (one at a time)


class Entry(QtWidgets.QPushButton):
    """An entry that lights up under the mouse by itself: the panel is never the active window (the game stays in
    front), and Qt's :hover did not show there."""

    def __init__(self, text):
        super().__init__(text)
        self.setObjectName("entry")
        self.setMouseTracking(True)
        self.setAttribute(QtCore.Qt.WA_Hover, True)

    def _hot(self, on):
        self.setProperty("hot", on)
        self.style().unpolish(self)
        self.style().polish(self)
        self.update()

    def enterEvent(self, ev):
        self._hot(True)
        super().enterEvent(ev)

    def leaveEvent(self, ev):
        self._hot(False)
        super().leaveEvent(ev)

    def mouseMoveEvent(self, ev):
        if not self.property("hot"):
            self._hot(True)
        super().mouseMoveEvent(ev)


class InlineList(QtWidgets.QFrame):
    def __init__(self, button, menu):
        top = button.window()
        super().__init__(top)
        self.setObjectName("inline")
        self.setStyleSheet(STYLE)
        self.button = button
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(1, 1, 1, 1)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QtWidgets.QFrame.NoFrame)
        scroll.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        body = QtWidgets.QWidget()
        body.setObjectName("inlinebody")        # a rule without a selector would reach every entry and beat :hover
        body.setStyleSheet("QWidget#inlinebody{background:transparent}")
        v = QtWidgets.QVBoxLayout(body)
        v.setContentsMargins(0, 2, 0, 2)
        v.setSpacing(0)
        self.first_checked = None
        self._fill(v, menu, 0)
        v.addStretch(1)
        scroll.setWidget(body)
        outer.addWidget(scroll)
        # under the button, as wide as its entries, as high as the window allows (then it scrolls)
        body.adjustSize()
        want = body.sizeHint()
        at = button.mapTo(top, QtCore.QPoint(0, button.height()))
        room_below = top.height() - at.y() - 6
        room_above = button.mapTo(top, QtCore.QPoint(0, 0)).y() - 6
        h = min(want.height() + 6, max(room_below, room_above, 120))
        w = min(max(want.width() + 24, button.width(), 140), max(160, top.width() - 12))
        y = at.y() if room_below >= h or room_below >= room_above else at.y() - button.height() - h
        x = min(max(4, at.x()), max(4, top.width() - w - 4))
        self.setGeometry(x, max(4, y), w, h)
        if self.first_checked is not None:
            QtCore.QTimer.singleShot(0, lambda: scroll.ensureWidgetVisible(self.first_checked))
        top.installEventFilter(self)
        QtWidgets.QApplication.instance().installEventFilter(self)

    def _fill(self, v, menu, depth):
        menu.aboutToShow.emit()              # a lazily filled menu fills itself now
        for act in menu.actions():
            if act.isSeparator():
                line = QtWidgets.QFrame()
                line.setObjectName("line")
                v.addWidget(line)
                continue
            if act.menu() is not None:       # a sub-menu: its entries under a heading
                head = QtWidgets.QLabel(act.text().replace("&&", "&"))
                head.setObjectName("group")
                v.addWidget(head)
                self._fill(v, act.menu(), depth + 1)
                continue
            if not act.isVisible():
                continue
            b = Entry(("    " * depth) + act.text().replace("&&", "&"))
            b.setFocusPolicy(QtCore.Qt.NoFocus)
            b.setCheckable(True)
            b.setChecked(act.isCheckable() and act.isChecked())
            b.setEnabled(act.isEnabled())
            if not act.icon().isNull():         # the trash can of a Remove entry
                b.setIcon(act.icon())
            if act.toolTip() and act.toolTip() != act.text():
                b.setToolTip(act.toolTip())
            b.clicked.connect(lambda _c=False, act=act: self._take(act))
            if b.isChecked() and self.first_checked is None:
                self.first_checked = b
            v.addWidget(b)

    def _take(self, act):
        self.close_list()
        act.trigger()                        # after closing: what it does may rebuild the whole window

    def close_list(self):
        if self in _open:
            _open.remove(self)
        app = QtWidgets.QApplication.instance()
        if app is not None:
            app.removeEventFilter(self)
        try:
            self.parent().removeEventFilter(self)
        except RuntimeError:
            pass
        self.hide()
        self.deleteLater()

    def eventFilter(self, obj, ev):
        t = ev.type()
        if t == QtCore.QEvent.MouseButtonPress and isinstance(obj, QtWidgets.QWidget):
            inside = obj is self or self.isAncestorOf(obj)
            if not inside:
                on_button = obj is self.button
                self.close_list()
                return on_button             # a click on its own button only closes it
        elif t in (QtCore.QEvent.Hide, QtCore.QEvent.Resize) and obj is self.parent():
            self.close_list()
        elif t == QtCore.QEvent.KeyPress and ev.key() == QtCore.Qt.Key_Escape:
            self.close_list()
            return True
        return False


def close_open():
    for w in list(_open):
        w.close_list()


def show(button, menu):
    close_open()
    lst = InlineList(button, menu)
    _open.append(lst)
    lst.show()
    lst.raise_()
    return lst


def attach(button, menu):
    """The button opens the menu's entries inline; button.menu() still gives the menu (fillers, tests)."""
    button.menu = lambda: menu               # no setMenu: a button with a menu would open it as a window
    button.clicked.connect(lambda _c=False: show(button, menu))
    return button


class Combo(QtWidgets.QComboBox):
    """A combo box whose list opens inline (Qt opens it from C++: only a subclass can take that over)."""

    def showPopup(self):
        m = QtWidgets.QMenu(self)
        for i in range(self.count()):
            a = m.addAction(self.itemText(i))
            a.setCheckable(True)
            a.setChecked(i == self.currentIndex())
            a.triggered.connect(lambda _c=False, i=i: self.setCurrentIndex(i))
        show(self, m)

    def hidePopup(self):
        close_open()
