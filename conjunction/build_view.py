"""The build window (Maxim 02.10.): while a quest is built Conjunction's windows go away and this one comes up - the
logo's rings swing together and apart above the build's lines as they come in (06.10.: the green rain was out of
place), a bar says how far it is. It can be minimised; when the
game has loaded the quest it closes and the windows come back. A failed build stays open with its reason.

    w = BuildWindow(title, on_close)
    w.line("[build] ...")       # every log line of the build (the GUI thread)
"""
import os

from PySide6 import QtCore, QtGui, QtWidgets

from . import APP_NAME, theme
# how far a build is when its log says this (the first that fits)
STAGES = [("keeps running (script", 2, "building while the game runs"),
          ("[play] quick save", 3, "saving the game"), ("encode quest", 8, "writing the quest"),
          ("analyze, cook", 18, "cooking"), (": scene ", 40, "cooking the scenes"),
          ("pack, metadatastore", 62, "packing"), (": strings", 72, "texts and voices"),
          ("installed ->", 82, "installing"), ("[play] game starting", 86, "starting the game"),
          ("step aside", 84, "the runs before step aside"), ("[play] live: ok", 88, "loading it into the game"),
          ("reloading the save", 92, "loading the save"),
          ("save loaded", 97, "loading the save"), ("[done]", 100, "done")]
# the export (Maxim 06.10.: a bar and what is being done - it can build the quest again under its own id)
EXPORT_STAGES = [("[export] checking", 2, "checking the quest"),
                 ("[export] Built again", 4, "building the quest under its own id"),
                 ("encode quest", 8, "writing the quest"), ("analyze, cook", 20, "cooking"),
                 (": scene ", 40, "cooking the scenes"), ("pack, metadatastore", 58, "packing"),
                 (": strings", 66, "texts and voices"), ("[export] the quest file", 76, "the quest file"),
                 ("[export] the zip", 88, "the zip for mod managers"),
                 ("[export] the page text", 96, "the text for its page"), ("[done]", 100, "done")]
MAX_LINES = 400


class Spheres(QtWidgets.QWidget):
    """The build's animation (Maxim 06.10.: the green rain was out of place; of four ideas the sway): the logo's two
    rings swing together until they lie on each other and apart until they only touch - a seamless loop; done, they
    settle where the logo has them; failed, they stop and turn red."""
    PERIOD = 2.4                        # s: together and apart once

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAttribute(QtCore.Qt.WA_TransparentForMouseEvents)
        self.setMinimumHeight(150)
        self.t0 = QtCore.QElapsedTimer()
        self.t0.start()
        self.state = "busy"             # busy / done / failed
        self.since = 0.0                # when it became done / failed (s)
        self.held = 0.0                 # how far apart the rings were then (0 on each other .. 1 touching)
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self.update)
        self.timer.start(16)

    @classmethod
    def apart(cls, t):
        import math
        return 0.5 + 0.5 * math.cos(t / cls.PERIOD * math.tau)     # 1 touching .. 0 one on the other .. 1

    def finish(self, ok):
        self.state = "done" if ok else "failed"
        self.since = self.t0.elapsed() / 1000.0
        self.held = self.apart(self.since)

    def paintEvent(self, _e):
        import math
        t = self.t0.elapsed() / 1000.0
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        cx, cy = self.width() / 2, self.height() / 2
        # the logo's units (installer/make_installer_icon.py): rings of 250, 64 wide, centres 130 from the middle,
        # 12 teeth reaching 46 beyond the ring
        R, W, TIP, TEETH, OFF = 250, 64, 250 + 32 + 46, 12, 130
        k = min(self.height() * 0.92 / (2 * TIP), self.width() * 0.9 / (2 * (OFF + TIP)), 0.6)
        colour = QtGui.QColor(229, 122, 122) if self.state == "failed" else QtGui.QColor(214, 170, 92)
        speed = math.radians(40)                        # rad/s
        if self.state == "busy":
            turn = t * speed
        elif self.state == "done":                      # slows down to standing in a second
            s = min(1.0, t - self.since)
            turn = self.since * speed + speed * (s - s * s / 2)
        else:
            turn = self.since * speed
        centres = [(cx - OFF * k, cy), (cx + OFF * k, cy)]
        inner, root, tip = (R - W / 2) * k, (R + W / 2) * k, TIP * k
        step = 2 * math.pi / TEETH
        p.setPen(QtCore.Qt.NoPen)
        p.setBrush(colour)
        for g, (gx, gy) in enumerate(centres):
            ox, oy = centres[1 - g]
            angle = turn if g == 0 else -turn + step / 2    # left clockwise, right against it (teeth between)
            path = QtGui.QPainterPath()
            path.addEllipse(QtCore.QPointF(gx, gy), root, root)
            for i in range(TEETH):
                a = angle + i * step
                if math.dist((gx + tip * math.cos(a), gy + tip * math.sin(a)), (ox, oy)) < tip + 14 * k:
                    continue                            # it would reach into the other gear
                tooth = QtGui.QPolygonF([QtCore.QPointF(gx + rad * math.cos(a + f * step),
                                                        gy + rad * math.sin(a + f * step))
                                         for f, rad in ((-0.32, root - 4 * k), (-0.17, tip), (0.17, tip),
                                                        (0.32, root - 4 * k))])
                tp = QtGui.QPainterPath()
                tp.addPolygon(tooth)
                path = path.united(tp)
            hole = QtGui.QPainterPath()
            hole.addEllipse(QtCore.QPointF(gx, gy), inner, inner)
            p.drawPath(path.subtracted(hole))
        p.end()


CARD = (860, 560)                   # Build & Play's window: the build's card and a margin


def card_rect(area):
    """The card's place in the middle of `area` (the game's picture, or the screen)."""
    w, h = min(CARD[0], area.width()), min(CARD[1], area.height())
    return QtCore.QRect(area.x() + (area.width() - w) // 2, area.y() + (area.height() - h) // 2, w, h)


class BuildWindow(QtWidgets.QWidget):
    def __init__(self, title, on_close=None, stages=None, verb="building", done_text="The quest is in the game",
                 curtain=False):
        # over the game, not over every program (07.10.: over YouTube - "übergriffig"): topmost only while the game
        # or Conjunction is in front (05.10.: an ordinary window stayed behind the running game) - _keep_over_game
        # curtain (Build & Play, 07.10.): a frameless card in the middle of the game's picture, owned by the game's
        # window (Windows keeps it right above the game, other programs cover both) - _follow_game
        self.curtain = curtain
        flags = (QtCore.Qt.Window | QtCore.Qt.FramelessWindowHint | QtCore.Qt.Tool) if curtain else \
            (QtCore.Qt.Window | QtCore.Qt.WindowMinimizeButtonHint | QtCore.Qt.WindowCloseButtonHint)
        super().__init__(None, flags)
        self._over = None
        self._owner = 0
        self._z = QtCore.QTimer(self)
        self._z.timeout.connect(self._follow_game if curtain else self._keep_over_game)
        self._z.start(300 if curtain else 400)
        self.setWindowTitle(f"{APP_NAME} · {verb} {title}")
        self.stages, self.done_text = stages or STAGES, done_text
        self.setAttribute(QtCore.Qt.WA_DeleteOnClose)
        self.on_close = on_close
        self.resize(820, 520)
        self.setWindowIcon(theme.window_icon())
        box = QtWidgets.QWidget(self)
        self.box = box
        v = QtWidgets.QVBoxLayout(box)
        v.setContentsMargins(22, 14, 22, 16)
        v.setSpacing(8)
        self.spheres = Spheres()
        v.addWidget(self.spheres)
        self.head = QtWidgets.QLabel(title)
        self.head.setAlignment(QtCore.Qt.AlignCenter)
        self.head.setStyleSheet(f"color:{theme.BRIGHT};font-size:17px;font-weight:bold;background:transparent")
        self.stage = QtWidgets.QLabel("Starting...")
        self.stage.setAlignment(QtCore.Qt.AlignCenter)
        self.stage.setStyleSheet(f"color:{theme.DIM};font-size:13px;background:transparent")
        self.bar = QtWidgets.QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setTextVisible(False)
        self.bar.setFixedHeight(5)
        self._bar_colour(theme.GOLD)
        self.text = QtWidgets.QPlainTextEdit()
        self.text.setReadOnly(True)
        self.text.setFrameStyle(QtWidgets.QFrame.NoFrame)
        self.text.setStyleSheet(f"QPlainTextEdit{{font-family:Consolas,'Cascadia Mono',monospace;color:{theme.DIM};"
                                f"font-size:11px;background:{theme.SURFACE};border:1px solid {theme.LINE};"
                                "padding:6px}")
        self.text.setMaximumBlockCount(MAX_LINES)
        self.close_b = QtWidgets.QPushButton("Close")
        self.close_b.clicked.connect(self.close)
        self.close_b.hide()
        v.addWidget(self.head)
        v.addWidget(self.stage)
        v.addWidget(self.bar)
        v.addWidget(self.text, 1)
        row = QtWidgets.QHBoxLayout()
        row.addStretch(1)
        row.addWidget(self.close_b)
        v.addLayout(row)
        self.queue = []                 # signs still to type out (the newest line types itself)
        self.typing = QtCore.QTimer(self)
        self.typing.timeout.connect(self._type)
        self.typing.start(16)
        self.done = False
        self.progress = 0.0
        self.target = 0
        self.anim = QtCore.QTimer(self)
        self.anim.timeout.connect(self._ease)
        self.anim.start(30)


    def _keep_over_game(self):
        """Topmost while the game (witcher3.exe) or one of Conjunction's windows is in front, else not."""
        import ctypes
        import ctypes.wintypes as wt
        if not self.isVisible():
            return
        u, k = ctypes.windll.user32, ctypes.windll.kernel32
        fg = u.GetForegroundWindow()
        pid = wt.DWORD()
        u.GetWindowThreadProcessId(fg, ctypes.byref(pid))
        ours = pid.value == os.getpid()
        if not ours and pid.value:
            h = k.OpenProcess(0x1000, False, pid.value)          # PROCESS_QUERY_LIMITED_INFORMATION
            if h:
                buf = ctypes.create_unicode_buffer(260)
                n = wt.DWORD(260)
                if k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
                    ours = os.path.basename(buf.value).lower() == "witcher3.exe"
                k.CloseHandle(h)
        if ours != self._over:
            self._over = ours
            # HWND_TOPMOST / HWND_NOTOPMOST; no move, no size, no activation
            u.SetWindowPos(int(self.winId()), -1 if ours else -2, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)

    def _bar_colour(self, colour):
        self.bar.setStyleSheet(f"QProgressBar{{background:{theme.FIELD};border:none;border-radius:0}}"
                               f"QProgressBar::chunk{{background:{colour}}}")

    def resizeEvent(self, _e):
        if self.curtain:                        # the build's card in the middle of the curtain
            w, h = min(820, self.width() - 40), min(520, self.height() - 40)
            self.box.setGeometry((self.width() - w) // 2, (self.height() - h) // 2, w, h)
        else:
            self.box.setGeometry(self.rect())

    # --- the curtain: over the game's picture, coupled to the game's window
    def _follow_game(self):
        import ctypes
        try:
            from .cursor import client_rect_on_screen, game_window
            hwnd = game_window() or 0
        except Exception:                       # noqa: BLE001 - no game (restarting): it stays where it is
            hwnd = 0
        if hwnd:                                # a card in the middle of the game's picture (07.10.: no live
            x, y, w, h = client_rect_on_screen(hwnd)    # reload any more - the whole screen covered for nothing)
            if w > 100 and h > 100:
                r = card_rect(QtCore.QRect(x, y, w, h))
                if self.geometry() != r:
                    self.setGeometry(r)
        if hwnd != self._owner:
            self._set_owner(hwnd)
            if hwnd:                            # right above its owner (now: the game is in front)
                ctypes.windll.user32.SetWindowPos(int(self.winId()), 0, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)

    def _set_owner(self, hwnd):
        import ctypes
        self._owner = hwnd
        if not getattr(self, "_hwnd", 0):       # (kept: release() is called from the build's thread)
            self._hwnd = int(self.winId())
        ctypes.windll.user32.SetWindowLongPtrW(self._hwnd, -8, hwnd)      # GWLP_HWNDPARENT: the owner

    def release(self):
        """Before the game is closed (Build & Play's restart): no longer owned - Windows would take it with it."""
        if self.curtain and self._owner:
            self._set_owner(0)

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.fillRect(self.rect(), QtGui.QColor(theme.BG))
        if self.curtain:                        # the card's own frame on the curtain
            p.fillRect(self.box.geometry().adjusted(-1, -1, 1, 1), QtGui.QColor(theme.LINE))
            p.fillRect(self.box.geometry(), QtGui.QColor(theme.BG))
        p.end()

    # --- the build's lines
    def line(self, text):
        if text == "\0":
            return
        for key, pct, words in self.stages:
            if key in text and pct > self.target:
                self.target = pct
                self.stage.setText(words[:1].upper() + words[1:] + ("..." if pct < 100 else ""))
        if text.startswith("[failed]"):
            self.failed(text[9:].strip())
        short = text if len(text) < 160 else text[:157] + "..."
        self.queue.append(short + "\n")
        if text.startswith("[done]") and not self.done:
            self.done = True
            self.stage.setText(self.done_text)
            self.spheres.finish(True)
            QtCore.QTimer.singleShot(1800, self.close)

    def failed(self, reason):
        self.done = True
        self.stage.setText(f"Failed: {reason}")
        self.stage.setStyleSheet(f"color:{theme.RED};font-size:13px;background:transparent")
        self._bar_colour(theme.RED)
        self.spheres.finish(False)
        self.close_b.show()
        if not self.curtain:
            self.showNormal()
            self.raise_()

    def _type(self):
        if not self.queue:
            return
        # a long backlog flushes faster (the cook can log hundreds of lines at once)
        n = 4 if len(self.queue) < 3 else 40 if len(self.queue) < 30 else 10000
        chunk, rest = self.queue[0][:n], self.queue[0][n:]
        if rest:
            self.queue[0] = rest
        else:
            self.queue.pop(0)
        cur = self.text.textCursor()
        cur.movePosition(QtGui.QTextCursor.End)
        cur.insertText(chunk)
        self.text.verticalScrollBar().setValue(self.text.verticalScrollBar().maximum())

    def _ease(self):
        if self.progress < self.target:
            self.progress = min(self.target, self.progress + max(0.15, (self.target - self.progress) * 0.06))
            self.bar.setValue(int(self.progress))

    def closeEvent(self, e):
        for t in (self.typing, self.anim, self.spheres.timer):
            t.stop()
        if self.on_close:
            cb, self.on_close = self.on_close, None
            cb()
        super().closeEvent(e)
