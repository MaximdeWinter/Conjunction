"""The start of the app (Maxim 06.10.): a conjunction inside the app's window, simple and clean. Two flat gold discs
come in from the sides, collide and burst; out of the burst the logo comes free (its two rings on the dark disc);
then logo and cover fade and the app is there. The window's own background, nothing else; all drawn, about two
seconds, a click skips it. The logo's own measures (_scratch/make_icon.py: rings of radius 250 and width 64, their
centres 130 from the middle, on a disc of 488, all of 1024).

    play(window)        the window shown, the animation over its content until it has faded
"""
import math
import random

from PySide6 import QtCore, QtGui, QtWidgets

from . import theme

GOLD = QtGui.QColor(214, 170, 92)
DISC = QtGui.QColor(24, 22, 28)
SIZE = 300                      # px: the logo in big
MS = 1760                       # (2.2 s, then 20 % faster - Maxim 06.10.)
MEET = 0.36                     # the discs collide
BURST = 0.30                    # how long the burst lasts (share of the time)
FADE = 0.74                     # logo and cover start to fade
PIECES = 90


def _ease_in(x):
    return x ** 2.4


def _ease_out(x):
    return 1 - (1 - x) ** 3


def _clamp(x):
    return 0.0 if x < 0 else 1.0 if x > 1 else x


def _col(c, a):
    q = QtGui.QColor(c)
    q.setAlphaF(_clamp(a))
    return q


class Splash(QtWidgets.QWidget):
    """A cover over the whole window, the animation drawn on it."""

    def __init__(self, window):
        super().__init__(window)
        self.window_ = window
        self.t = 0.0
        self.setGeometry(window.rect())
        window.installEventFilter(self)
        rnd = random.Random(1024)
        # the burst's pieces: direction, how far, size
        self.pieces = [(rnd.uniform(0, math.tau), rnd.uniform(0.25, 1.0), rnd.uniform(2.0, 7.0))
                       for _ in range(PIECES)]
        self.anim = QtCore.QVariantAnimation(self, startValue=0.0, endValue=1.0, duration=MS)
        self.anim.valueChanged.connect(self._tick)
        self.anim.finished.connect(self._done)

    def eventFilter(self, obj, ev):
        if obj is self.window_ and ev.type() == QtCore.QEvent.Resize:
            self.setGeometry(self.window_.rect())
        return False

    def play(self):
        self.raise_()
        self.show()
        self.anim.start()

    def _tick(self, v):
        self.t = float(v)
        self.update()

    def _done(self):
        self.window_.removeEventFilter(self)
        self.hide()
        self.deleteLater()

    def mousePressEvent(self, _e):
        self.anim.stop()
        self._done()

    def paintEvent(self, _e):
        k = SIZE / 1024.0
        t = self.t
        fade = 1.0 if t < FADE else max(0.0, 1 - (t - FADE) / (1 - FADE))
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.Antialiasing)
        p.fillRect(self.rect(), _col(QtGui.QColor(theme.BG), fade))   # the app under it shows as this fades
        cx, cy = self.width() / 2, self.height() / 2
        p.setPen(QtCore.Qt.NoPen)
        r_disc = 250 * k                                # as big as the logo's rings (their outer edge)
        if t < MEET:                                    # two discs, faster and faster, from the sides
            a = _ease_in(t / MEET)
            far = self.width() / 2 + r_disc
            p.setBrush(GOLD)
            for side in (-1, 1):
                x = cx + side * (r_disc + (far - r_disc) * (1 - a))
                p.drawEllipse(QtCore.QPointF(x, cy), r_disc, r_disc)
            p.end()
            return
        s = _clamp((t - MEET) / BURST)                  # 0 .. 1 over the burst
        # the logo, under the burst: it comes free as the burst clears
        logo = _clamp((s - 0.15) / 0.5)
        if logo > 0:
            p.setBrush(_col(DISC, logo * fade))
            r = 488 * k * (0.9 + 0.1 * _ease_out(logo))
            p.drawEllipse(QtCore.QPointF(cx, cy), r, r)
            p.setBrush(QtCore.Qt.NoBrush)
            p.setPen(QtGui.QPen(_col(GOLD, fade), 64 * k))
            ring = (250 - 32) * k
            for side in (-1, 1):
                p.drawEllipse(QtCore.QPointF(cx + side * 130 * k, cy), ring, ring)
            p.setPen(QtCore.Qt.NoPen)
        if s < 1:
            # the burst: one gold disc that swells and opens from the middle (a ring that thins out)
            outer = r_disc * 1.6 + _ease_out(s) * 560 * k
            inner = _ease_out(_clamp(s * 1.6)) * outer
            path = QtGui.QPainterPath()
            path.addEllipse(QtCore.QPointF(cx, cy), outer, outer)
            hole = QtGui.QPainterPath()
            hole.addEllipse(QtCore.QPointF(cx, cy), inner, inner)
            p.setBrush(_col(GOLD, (1 - s) * fade))
            p.drawPath(path.subtracted(hole))
            # and the pieces flying out
            for ang, far, size in self.pieces:
                d = (r_disc + _ease_out(s) * far * 720 * k)
                p.setBrush(_col(GOLD, (1 - s) * fade))
                p.drawEllipse(QtCore.QPointF(cx + math.cos(ang) * d, cy + math.sin(ang) * d), size * (1 - s * 0.6),
                              size * (1 - s * 0.6))
        p.end()


def play(window):
    window.show()
    s = Splash(window)
    s.play()
    return s
