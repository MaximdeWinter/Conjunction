"""Snap to side for Conjunction's windows over the game (Maxim 05.10.: "wenn ich ein fenster öffne schwebt es frei im
bild ich kann jedoch mit der maus es an den rand ziehen und dann geht es da auf. und klebt an der seite. das geht
mit alle 4 seiten ... auch soll man snap to side sachen breiter ziehen können").

A window floats where it was put. Dragged by its header to within SNAP px of an edge of the game's window, a gold
frame shows where it would go (the overlay draws it); let go there, it fills that side - left / right the whole
height under the bar, top / bottom the whole width. Docked, only its inner edge resizes it (its width, or its height
at the top / bottom). Dragged away by its header, it floats again at its old size. Windows docked on the same side
share it. Side and size are kept (config "docks": {key: {"side", "size"}}).

    d = Docker(window, "panel", editor)
    d.drag_moved(global_pos) / d.drag_released(global_pos)     from the window's own header drag
    d.inner_edge() -> "left" | "right" | "top" | "bottom" | None   the one border that resizes a docked window
    d.resized()                                                after the user resized it (its size kept)
    d.apply()                                                  placed again (the game's window moved / resized)
"""
from PySide6 import QtCore

from . import config

SNAP = 36                   # px from an edge of the game where a dragged window docks
SIDES = ("left", "right", "top", "bottom")
INNER = {"left": "right", "right": "left", "top": "bottom", "bottom": "top"}
MIN = 260                   # px: a docked window never thinner
_all = []                   # every docker (windows on one side share it)


def insets():
    """How far the docked windows reach in from each side of the game: {side: px} (the overlay keeps its strip and
    hints clear of them)."""
    out = {side: 0 for side in SIDES}
    for d in _all:
        if d.side is not None and d.win.isVisible():
            g = d.win.geometry()
            out[d.side] = max(out[d.side], g.width() if d.side in ("left", "right") else g.height())
    return out


def _game_rect(ed):
    """The game's window on the screen, under the bar: (x, y, w, h)."""
    from .cursor import client_rect_on_screen
    from .hud import BAR_H
    hwnd = getattr(ed, "hwnd", None)
    if not hwnd:
        return None
    x, y, w, h = client_rect_on_screen(hwnd)
    return x, y + BAR_H, w, h - BAR_H


class Docker:
    def __init__(self, win, key, ed, default_size=420):
        self.win, self.key, self.ed = win, key, ed
        kept = (config.load().get("docks") or {}).get(key) or {}
        self.side = kept.get("side") if kept.get("side") in SIDES else None
        self.size = int(kept.get("size") or default_size)
        self.float_size = None          # the size it had floating (back to it when undocked)
        self.extra = lambda: 0          # px the window is wider for now (the panel's inspector: it comes out at the
                                        # side, the list keeps its width - Maxim 06.10.)
        self.candidate = None           # the side the current drag would dock to
        _all.append(self)

    # --- kept
    def _keep(self):
        cfg = config.load()
        docks = dict(cfg.get("docks") or {})
        docks[self.key] = {"side": self.side, "size": self.size}
        cfg["docks"] = docks
        config.save(cfg)

    # --- where
    def side_at(self, gp):
        """The side of the game a screen point is near enough to dock to, or None."""
        r = _game_rect(self.ed)
        if r is None:
            return None
        x, y, w, h = r
        px, py = gp.x(), gp.y()
        if not (x - SNAP <= px <= x + w + SNAP and y - SNAP <= py <= y + h + SNAP):
            return None
        near = {"left": px - x, "right": x + w - px, "top": py - y, "bottom": y + h - py}
        side = min(near, key=near.get)
        return side if near[side] <= SNAP else None

    def rect(self, side=None):
        """The screen rectangle of this window docked on `side` (its share of the side when others are there)."""
        side = side or self.side
        r = _game_rect(self.ed)
        if r is None or side is None:
            return None
        x, y, w, h = r
        mates = [d for d in _all if d.side == side and d.win.isVisible() and d is not self]
        n = len(mates) + 1
        k = sum(1 for d in mates if _all.index(d) < _all.index(self))
        across = w if side in ("left", "right") else h
        least = self.win.minimumSizeHint()
        least = max(self.win.minimumWidth(), least.width()) if side in ("left", "right") else \
            max(self.win.minimumHeight(), least.height())
        # (a window wider than its side - its minimum size - grows inwards, not over the game's edge: docked right,
        # the Asset Browser reached into the other screen - Maxim 05.10.)
        size = min(max(MIN, self.size + (self.extra() if side in ("left", "right") else 0), least), across - 120)
        # left / right: beside what is docked at the top / bottom is not taken into account (the sides run the
        # whole height); the top / bottom ones leave the left / right ones their room
        lefts = [d.size for d in _all if d.side == "left" and d.win.isVisible()]
        rights = [d.size for d in _all if d.side == "right" and d.win.isVisible()]
        if side in ("left", "right"):
            part = h // n
            top = y + k * part
            left = x if side == "left" else x + w - size
            return QtCore.QRect(left, top, size, part if k < n - 1 else h - k * part)
        x0 = x + (max(lefts) if lefts else 0)
        x1 = x + w - (max(rights) if rights else 0)
        part = (x1 - x0) // n
        top = y if side == "top" else y + h - size
        return QtCore.QRect(x0 + k * part, top, part if k < n - 1 else (x1 - x0) - k * part, size)

    # --- the drag (from the window's header)
    def drag_moved(self, gp):
        """While the header is dragged: undocked at the first move (back to its floating size, under the mouse),
        the gold frame where it would dock."""
        if self.side is not None:
            self.side = None
            g = self.win.geometry()
            fw, fh = self.float_size or (max(MIN, min(g.width(), 520)), max(MIN, min(g.height(), 640)))
            self.win.setGeometry(gp.x() - fw // 2, gp.y() - 12, fw, fh)
            self._keep()
            self._others()
        self.candidate = self.side_at(gp)
        self._preview(self.rect(self.candidate) if self.candidate else None)

    def drag_released(self, gp):
        side, self.candidate = self.side_at(gp), None
        self._preview(None)
        if side:
            self.dock(side)
        return side

    def dock(self, side):
        if self.side is None:
            g = self.win.geometry()
            self.float_size = (g.width(), g.height())
        self.side = side
        self._keep()
        self.apply()
        self._others()

    def _others(self):
        """The other windows on the same sides take their new share; the overlay keeps its strip clear of them."""
        for d in _all:
            if d is not self and d.side is not None and d.win.isVisible():
                d.apply()
        hud = getattr(self.ed, "hud", None)
        if hud is not None and hasattr(hud, "sync"):
            hud.sync()

    def _preview(self, rect):
        hud = getattr(self.ed, "hud", None)
        if hud is not None:
            hud.dock_preview = rect
            hud.update()

    # --- docked
    def inner_edge(self):
        return INNER.get(self.side)

    def resized(self):
        """The user resized the docked window at its inner edge: its new width (height) kept."""
        if self.side is None:
            return
        g = self.win.geometry()
        self.size = max(MIN, g.width() - self.extra() if self.side in ("left", "right") else g.height())
        self._keep()
        self.apply()
        self._others()

    def apply(self):
        r = self.rect()
        if r is not None and self.win.geometry() != r:
            self.win.setGeometry(r)
        return r is not None


class Mover(QtCore.QObject):
    """Moving by a header, resizing at the border, docking - for a window of Conjunction that has no such code of its
    own (the panel has it built in). Docked, only the inner border resizes; a floating window's rectangle is kept
    in the config as "<key>_rect".

        Mover(window, frame, header, "projects", editor)
    """
    EDGE = 7

    def __init__(self, win, frame, header, key, ed, min_size=(360, 240)):
        super().__init__(win)
        self.win, self.frame, self.header, self.key = win, frame, header, key
        self.min_w, self.min_h = min_size
        self.docker = Docker(win, key, ed)
        self.drag = self.resize = None
        for w in (frame, header):
            w.installEventFilter(self)
            w.setMouseTracking(True)
        header.setCursor(QtCore.Qt.SizeAllCursor)

    def kept_rect(self):
        r = config.load().get(self.key + "_rect")
        return QtCore.QRect(*r) if r else None

    def _keep_rect(self):
        g = self.win.geometry()
        cfg = config.load()
        cfg[self.key + "_rect"] = [g.x(), g.y(), g.width(), g.height()]
        config.save(cfg)

    def edges(self, pos):
        r, e = self.frame.rect(), self.EDGE
        found = (pos.x() < e, pos.y() < e, pos.x() > r.width() - e, pos.y() > r.height() - e)
        inner = self.docker.inner_edge()
        if inner is None:
            return found
        keep = ("left", "top", "right", "bottom").index(inner)
        return tuple(v if i == keep else False for i, v in enumerate(found))

    def eventFilter(self, obj, ev):
        t = ev.type()
        if t not in (QtCore.QEvent.MouseButtonPress, QtCore.QEvent.MouseMove, QtCore.QEvent.MouseButtonRelease):
            return False
        gp = ev.globalPosition().toPoint()
        if t == QtCore.QEvent.MouseButtonPress and ev.button() == QtCore.Qt.LeftButton:
            if obj is self.header:
                self.drag = (gp, self.win.geometry())
                return True
            e = self.edges(ev.position().toPoint())
            if any(e):
                self.resize = (gp, self.win.geometry(), e)
                return True
        elif t == QtCore.QEvent.MouseMove:
            if self.drag:
                start, g = self.drag
                if (gp - start).manhattanLength() < 4:
                    return True
                was = self.docker.side
                if was is None:
                    self.win.move(g.topLeft() + gp - start)
                self.docker.drag_moved(gp)
                if was is not None:
                    self.drag = (gp, self.win.geometry())
                return True
            if self.resize:
                start, g, (el, et, er, eb) = self.resize
                d, r = gp - start, QtCore.QRect(g)
                if el:
                    r.setLeft(min(g.left() + d.x(), g.right() - self.min_w))
                if er:
                    r.setRight(max(g.right() + d.x(), g.left() + self.min_w))
                if et:
                    r.setTop(min(g.top() + d.y(), g.bottom() - self.min_h))
                if eb:
                    r.setBottom(max(g.bottom() + d.y(), g.top() + self.min_h))
                self.win.setGeometry(r)
                return True
            if obj is self.frame:
                el, et, er, eb = self.edges(ev.position().toPoint())
                shape = (QtCore.Qt.SizeFDiagCursor if (el and et) or (er and eb) else
                         QtCore.Qt.SizeBDiagCursor if (er and et) or (el and eb) else
                         QtCore.Qt.SizeHorCursor if el or er else QtCore.Qt.SizeVerCursor if et or eb else None)
                self.frame.unsetCursor() if shape is None else self.frame.setCursor(shape)
        elif t == QtCore.QEvent.MouseButtonRelease and (self.drag or self.resize):
            dragged, self.drag, self.resize = self.drag, None, None
            if dragged and self.docker.drag_released(gp):
                return True
            if not dragged and self.docker.side is not None:
                self.docker.resized()
                return True
            self._keep_rect()
            return True
        return False
