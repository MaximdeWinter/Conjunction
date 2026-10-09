"""The bug report window (the bug in the bar): what happened, screenshots of the game with the overlay (this window
hidden while taken), drawn on and marked, then Save report: one file in Documents\\Conjunction\\bug-reports to
keep or send (bugreport.py collects the rest, anonymous); Copy for Nexus puts a short text of it into the clipboard
(Nexus takes text only). Opened from the app too (no editor: ed None).
"""
from PySide6 import QtCore, QtGui, QtWidgets

from .icons import icon, icon_button
from .tooltips import tip

STYLE = """
QWidget#bug{background:#232326;color:#ddd;font:12px}
QLabel#note{color:#999;font:11px}
QToolButton#tool{background:#2e2e33;border:1px solid #444;border-radius:0;padding:3px}
QToolButton#tool:checked{border-color:#d9d9d9;background:#44444a}
"""
COLOURS = ["#ff3b30", "#ffcc00", "#34c759", "#ffffff"]
INCLUDED = ("Saved as one file in Documents\\Conjunction\\bug-reports. Nothing is sent. Inside: what you write, "
            "the screenshots, Conjunction's and the game's logs, the open project (quest and places), the editor's "
            "and the game's state, installed mods and DLCs. Anonymous (your names, the PC's name and your profile "
            "are taken out)")


class Annotate(QtWidgets.QDialog):
    """A screenshot to draw on: pen, arrow, box, text; colours; undo. Done -> self.result_image."""

    def __init__(self, image, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Mark the problem")
        self.setObjectName("bug")
        self.setStyleSheet(STYLE)
        self.base = image
        self.marks = []                         # [(tool, colour, points or (rect) or (pos, text))]
        self.tool, self.colour, self.cur = "pen", COLOURS[0], None
        self.result_image = None
        v = QtWidgets.QVBoxLayout(self)
        bar = QtWidgets.QHBoxLayout()
        self.tools = {}
        for key, name, tipkey in (("pen", "pencil", "bug.pen"), ("arrow", "move-up-right", "bug.arrow"),
                                  ("box", "square", "bug.box"), ("text", "type", "bug.text")):
            b = icon_button(name, lambda _c=False, k=key: self._tool(k), tipkey, object_name="tool")
            b.setCheckable(True)
            b.setStyleSheet("")
            self.tools[key] = b
            bar.addWidget(b)
        bar.addSpacing(12)
        self.swatches = []
        for c in COLOURS:
            s = QtWidgets.QToolButton()
            s.setCheckable(True)
            s.setFixedSize(22, 22)
            s.setStyleSheet(f"QToolButton{{background:{c};border:2px solid #333;border-radius:0}}"
                            f"QToolButton:checked{{border-color:#fff}}")
            s.clicked.connect(lambda _c=False, c=c: self._colour(c))
            tip(s, "bug.colour")
            self.swatches.append((c, s))
            bar.addWidget(s)
        bar.addSpacing(12)
        bar.addWidget(icon_button("undo-2", lambda _c=False: self._undo(), "bug.undo", object_name="tool"))
        bar.addStretch(1)
        ok = QtWidgets.QPushButton("Done")
        ok.clicked.connect(self._done)
        cancel = QtWidgets.QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        bar.addWidget(cancel)
        bar.addWidget(ok)
        v.addLayout(bar)
        self.canvas = QtWidgets.QLabel()
        self.canvas.setAlignment(QtCore.Qt.AlignCenter)
        self.canvas.setMouseTracking(True)
        self.canvas.installEventFilter(self)
        v.addWidget(self.canvas, 1)
        screen = QtGui.QGuiApplication.primaryScreen().availableGeometry()
        self.scale = min(1.0, (screen.width() * 0.85) / image.width(), (screen.height() * 0.8) / image.height())
        self.canvas.setFixedSize(int(image.width() * self.scale), int(image.height() * self.scale))
        self._tool("pen")
        self._colour(COLOURS[0])
        self._paint()

    def _tool(self, k):
        self.tool = k
        for key, b in self.tools.items():
            b.setChecked(key == k)

    def _colour(self, c):
        self.colour = c
        for col, s in self.swatches:
            s.setChecked(col == c)

    def _undo(self):
        if self.marks:
            self.marks.pop()
            self._paint()

    def _pos(self, ev):
        return QtCore.QPointF(ev.position().x() / self.scale, ev.position().y() / self.scale)

    def eventFilter(self, obj, ev):
        t = ev.type()
        if t == QtCore.QEvent.MouseButtonPress and ev.button() == QtCore.Qt.LeftButton:
            p = self._pos(ev)
            if self.tool == "text":
                text, ok = QtWidgets.QInputDialog.getText(self, "Text", "Text:")
                if ok and text:
                    self.marks.append(("text", self.colour, (p, text)))
                    self._paint()
                return True
            self.cur = (self.tool, self.colour, [p, p])
            return True
        if t == QtCore.QEvent.MouseMove and self.cur is not None:
            p = self._pos(ev)
            if self.cur[0] == "pen":
                self.cur[2].append(p)
            else:
                self.cur[2][1] = p
            self._paint()
            return True
        if t == QtCore.QEvent.MouseButtonRelease and self.cur is not None:
            self.marks.append(self.cur)
            self.cur = None
            self._paint()
            return True
        return False

    def _draw(self, img):
        p = QtGui.QPainter(img)
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        w = max(3.0, img.width() / 400)
        for tool, colour, data in self.marks + ([self.cur] if self.cur else []):
            pen = QtGui.QPen(QtGui.QColor(colour), w, QtCore.Qt.SolidLine, QtCore.Qt.RoundCap, QtCore.Qt.RoundJoin)
            p.setPen(pen)
            p.setBrush(QtCore.Qt.NoBrush)
            if tool == "pen":
                p.drawPolyline(QtGui.QPolygonF(data))
            elif tool == "box":
                p.drawRect(QtCore.QRectF(data[0], data[1]).normalized())
            elif tool == "arrow":
                a, b = data
                p.drawLine(a, b)
                line = QtCore.QLineF(b, a)
                for turn in (25, -25):
                    head = QtCore.QLineF(line)
                    head.setLength(w * 6)
                    head.setAngle(line.angle() + turn)
                    p.drawLine(head)
            elif tool == "text":
                pos, text = data
                f = p.font()
                f.setPointSizeF(max(14.0, img.width() / 90))
                f.setBold(True)
                p.setFont(f)
                p.drawText(pos, text)
        p.end()

    def _paint(self):
        img = self.base.copy()
        self._draw(img)
        self.canvas.setPixmap(QtGui.QPixmap.fromImage(img).scaled(self.canvas.size(), QtCore.Qt.KeepAspectRatio,
                                                                   QtCore.Qt.SmoothTransformation))

    def _done(self):
        img = self.base.copy()
        self._draw(img)
        self.result_image = img
        self.accept()


def png_bytes(img):
    buf = QtCore.QBuffer()
    buf.open(QtCore.QIODevice.WriteOnly)
    img.save(buf, "PNG")
    return bytes(buf.data())


class BugWindow(QtWidgets.QWidget):
    """What happened, screenshots, Send."""

    def __init__(self, ed):
        super().__init__(None, QtCore.Qt.Window | QtCore.Qt.WindowStaysOnTopHint)
        self.ed = ed
        self.shots = []                         # [(original QImage, marked QImage)]
        self.setObjectName("bug")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        self.setStyleSheet(STYLE)
        self.setWindowTitle("Report a bug")
        self.setWindowIcon(icon("bug"))
        self.resize(560, 460)
        v = QtWidgets.QVBoxLayout(self)
        head = QtWidgets.QLabel("Report a bug")
        head.setStyleSheet("font:bold 14px;color:#eeeeee")
        v.addWidget(head)
        self.text = QtWidgets.QPlainTextEdit()
        self.text.setPlaceholderText("Please write what happened and what you expected to happen")
        tip(self.text, "bug.text_field")
        v.addWidget(self.text, 1)
        self.strip = QtWidgets.QHBoxLayout()
        self.strip.setSpacing(6)
        strip_box = QtWidgets.QWidget()
        strip_box.setLayout(self.strip)
        v.addWidget(strip_box)
        h = QtWidgets.QHBoxLayout()
        self.b_shot = QtWidgets.QPushButton("Add screenshot")
        self.b_shot.setIcon(icon("camera"))
        self.b_shot.clicked.connect(self.add_screenshot)
        tip(self.b_shot, "bug.screenshot")
        h.addWidget(self.b_shot)
        h.addStretch(1)
        cancel = QtWidgets.QPushButton("Cancel")
        cancel.clicked.connect(lambda: self.window().close())      # its window, not only this page of it
        self.b_send = QtWidgets.QPushButton("Save report")
        self.b_send.clicked.connect(self.send)
        tip(self.b_send, "bug.send")
        self.b_folder = QtWidgets.QPushButton("Show file")
        self.b_folder.setIcon(icon("folder-open"))
        self.b_folder.clicked.connect(lambda: self.saved and __import__("conjunction.bugreport").bugreport.show(
            self.saved))
        tip(self.b_folder, "bug.folder")
        self.b_folder.hide()
        # Nexus takes text only in its Bugs tab (Maxim 08.10.): a short report from the saved one, to paste there
        self.b_copy = QtWidgets.QPushButton("Copy for Nexus")
        self.b_copy.setIcon(icon("copy"))
        self.b_copy.clicked.connect(self._copy)
        tip(self.b_copy, "bug.copy")
        self.b_copy.hide()
        self.saved = None
        h.addWidget(cancel)
        h.addWidget(self.b_folder)
        h.addWidget(self.b_copy)
        h.addWidget(self.b_send)
        v.addLayout(h)
        note = QtWidgets.QLabel(INCLUDED)
        note.setObjectName("note")
        note.setWordWrap(True)
        v.addWidget(note)
        self.status = QtWidgets.QLabel("")
        self.status.setObjectName("note")
        self.status.setWordWrap(True)
        self.status.setTextInteractionFlags(QtCore.Qt.TextBrowserInteraction)
        self.status.setOpenExternalLinks(True)
        v.addWidget(self.status)

    def add_screenshot(self):
        """The game with the overlay as it is now - this window out of the picture - then drawn on."""
        self.window().hide()                    # (its window: it lives in one of Conjunction's windows)
        QtCore.QTimer.singleShot(350, self._grab)

    def _grab(self):
        from .editor import client_rect_on_screen
        hwnd = getattr(self.ed, "hwnd", None)
        screen = QtGui.QGuiApplication.primaryScreen()
        try:
            x, y, w, h = client_rect_on_screen(hwnd) if hwnd else screen.geometry().getRect()
        except Exception:                       # noqa: BLE001 - the game is gone: the whole screen
            x, y, w, h = screen.geometry().getRect()
        shot = screen.grabWindow(0, x, y, w, h).toImage()
        self.window().show()
        self.window().raise_()
        a = Annotate(shot, self)
        from .dialogs import bring_up
        a.setWindowFlag(QtCore.Qt.WindowStaysOnTopHint, True)     # (in front of the game while it is open)
        QtCore.QTimer.singleShot(0, lambda: bring_up(a))
        if a.exec() == QtWidgets.QDialog.Accepted and a.result_image is not None:
            self.shots.append((shot, a.result_image))
            self._strip()

    def _strip(self):
        while self.strip.count():
            w = self.strip.takeAt(0).widget()
            if w:
                w.deleteLater()
        for k, (_orig, marked) in enumerate(self.shots):
            box = QtWidgets.QWidget()
            hl = QtWidgets.QVBoxLayout(box)
            hl.setContentsMargins(0, 0, 0, 0)
            pic = QtWidgets.QLabel()
            pic.setPixmap(QtGui.QPixmap.fromImage(marked).scaled(120, 68, QtCore.Qt.KeepAspectRatio,
                                                                 QtCore.Qt.SmoothTransformation))
            hl.addWidget(pic)
            hl.addWidget(icon_button("trash-2", lambda _c=False, k=k: (self.shots.pop(k), self._strip()), "bug.remove"),
                         0, QtCore.Qt.AlignHCenter)
            self.strip.addWidget(box)
        self.strip.addStretch(1)

    def _copy(self):
        from . import bugreport
        if not self.saved:
            return
        QtWidgets.QApplication.clipboard().setText(bugreport.nexus_text(self.saved))
        self.status.setText("Copied. Paste it into the Bugs tab of the mod's Nexus page (Add a new report)")

    def send(self):
        from . import bugreport
        self.b_send.setEnabled(False)
        self.status.setText("Collecting...")
        QtWidgets.QApplication.processEvents()
        shots = []
        for k, (orig, marked) in enumerate(self.shots):
            shots += [(f"marked_{k + 1}", png_bytes(marked)), (f"original_{k + 1}", png_bytes(orig))]
        log = ""
        p = getattr(self.ed, "panel", None)
        if p is not None and hasattr(p, "log"):
            log = p.log.toPlainText()
        text = self.text.toPlainText().strip()
        try:
            path = bugreport.collect(self.ed, text, shots, log)
        except Exception as e:                  # noqa: BLE001 - say it, do not lose the window
            self.status.setText(f"Could not collect the report: {e}")
            self.b_send.setEnabled(True)
            return
        self.saved = path
        self.status.setText("Saved. Copy for Nexus puts a short report into the clipboard: paste it into the Bugs tab "
                            "of the mod's Nexus page. The author may ask you for the file. Thank you")
        self.b_folder.show()
        self.b_copy.show()
        self.b_send.setEnabled(True)
        self.text.clear()
        self.shots.clear()
        self._strip()
