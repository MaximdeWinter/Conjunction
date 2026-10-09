"""Drawing a path in the world - one tool for every way (Follow, Patrol, Walk, a trail, a camera move; Maxim 01.10.:
"wie malt man pfade ... all diese dinge müssen richtig sitzen").

While it is on, the overlay draws the path over the game (dots numbered from the start, the lines between, the end
marked), and a click into the world:
  - on empty ground: a point at the end of the path,
  - on a line between two points: a point there, in between,
  - on a point: picks it up - the next click puts it down there;
a right click on a point takes it out. Every point is kept the moment it is set (`on_change`; Maxim 02.10.: he clicked,
did not know Enter was still needed, and nothing was placed) - Enter and Esc only end drawing, Backspace takes the last
point (or the one picked up) out. The ground under each click comes from the game (cj_cursor_hit).
"""
import math

from PySide6 import QtCore, QtGui

NEAR_POINT = 13          # px: a click this close to a dot is on it
NEAR_LINE = 8            # px: this close to a line, between its ends
COLOUR = "#e3c65f"
PICKED = "#ffffff"


def _seg_dist(p, a, b):
    """Screen distance of p to the segment a-b, and where along it (0..1)."""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    ll = dx * dx + dy * dy
    t = 0.0 if ll == 0 else max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / ll))
    return math.hypot(p[0] - (ax + t * dx), p[1] - (ay + t * dy)), t


class PathTool:
    def __init__(self, ed, points, on_done, label="Path", closed=False, on_cancel=None, min_points=1,
                 on_change=None):
        self.ed = ed
        self.on_change = on_change      # (points) after every point set, moved or taken out
        self.points = [list(map(float, p[:3])) for p in points or []]
        self.original = [list(p) for p in self.points]
        self.on_done, self.on_cancel = on_done, on_cancel
        self.label, self.closed, self.min_points = label, closed, min_points
        self.picked = None              # the index of a point picked up (the next click puts it down)
        self.pending = None             # ("add" | "insert" | "move", index) while the game finds the ground

    # --- on / off
    def start(self):
        self.ed.path_tool = self
        if hasattr(self.ed, "set_mode"):
            self.ed.set_mode("look")    # a click is a point, nothing gets selected
        self._show()

    def finish(self):
        if len(self.points) < self.min_points:
            return self.cancel()
        self._end()
        self.on_done([[round(v, 3) for v in p] for p in self.points])

    def cancel(self):
        """Esc: the points stay (each was kept when set) - drawing ends; too few for a way: as it was."""
        if len(self.points) >= self.min_points and self.points != self.original:
            return self.finish()
        self._end()
        if self.on_cancel:
            self.on_cancel([list(p) for p in self.original])

    def _changed(self):
        self._show()
        if self.on_change and len(self.points) >= self.min_points:
            self.on_change([[round(v, 3) for v in p] for p in self.points])

    def _end(self):
        if getattr(self.ed, "path_tool", None) is self:
            self.ed.path_tool = None
        self._show()

    def _show(self):
        hud = getattr(self.ed, "hud", None)
        if hud is not None:
            hud.sync()
            hud.update()

    # --- input (the editor hands it on: screen px in the game's picture)
    def _screen(self):
        w, h = self.ed.hud.width(), self.ed.hud.height()
        return [self.ed.cam.project(p, w, h) for p in self.points]

    def click(self, x, y, ask_ground):
        """A left click at x, y: what it means, then the ground under it asked of the game (`ask_ground()`)."""
        scr = self._screen()
        if self.picked is not None:
            self.pending = ("move", self.picked)
        else:
            near = [(math.hypot(x - s[0], y - s[1]), i) for i, s in enumerate(scr) if s]
            d, i = min(near) if near else (1e9, None)
            if d <= NEAR_POINT:
                self.picked = i                 # picked up: the next click puts it down
                self._show()
                return
            best = None
            pairs = list(zip(range(len(scr)), scr, scr[1:])) + \
                ([(len(scr) - 1, scr[-1], scr[0])] if self.closed and len(scr) > 2 else [])
            for k, a, b in pairs:
                if a and b:
                    dist, t = _seg_dist((x, y), a, b)
                    if dist <= NEAR_LINE and 0.05 < t < 0.95 and (best is None or dist < best[0]):
                        best = (dist, k + 1)
            self.pending = ("insert", best[1]) if best else ("add", len(self.points))
        ask_ground()

    def right_click(self, x, y):
        """A right click on a point takes it out."""
        for i, s in enumerate(self._screen()):
            if s and math.hypot(x - s[0], y - s[1]) <= NEAR_POINT:
                self.points.pop(i)
                self.picked = None
                break
        self._changed()

    def ground(self, pos):
        """The game's answer: the ground point under the click (None: nothing hit)."""
        what, self.pending = self.pending, None
        if what is None or pos is None:
            return
        p = [round(float(v), 3) for v in pos[:3]]
        kind, i = what
        if kind == "move" and i < len(self.points):
            self.points[i] = p
            self.picked = None
        elif kind == "insert":
            self.points.insert(i, p)
        else:
            self.points.append(p)
        self._changed()

    def back(self):
        """Backspace: the point picked up, else the last one, out."""
        if self.picked is not None and self.picked < len(self.points):
            self.points.pop(self.picked)
            self.picked = None
        elif self.points:
            self.points.pop()
        self._changed()

    def doing(self):
        n = len(self.points)
        if self.picked is not None:
            return f"{self.label} · point {self.picked + 1} picked up - click where it goes",                 ["Click: put down", "Backspace: remove"]
        return f"{self.label} · {n} point{'s' * (n != 1)} · click in the world to add",             ["Enter: done", "Backspace: last out", "Right click: remove"]

    # --- drawn by the overlay
    def draw(self, p, w, h):
        scr = [self.ed.cam.project(q, w, h) for q in self.points]
        col = QtGui.QColor(COLOUR)
        pairs = list(zip(scr, scr[1:])) + ([(scr[-1], scr[0])] if self.closed and len(scr) > 2 else [])
        for a, b in pairs:
            if a and b:
                p.setPen(QtGui.QPen(QtGui.QColor(0, 0, 0, 170), 6))
                p.drawLine(QtCore.QPointF(*a), QtCore.QPointF(*b))
                p.setPen(QtGui.QPen(col, 3))
                p.drawLine(QtCore.QPointF(*a), QtCore.QPointF(*b))
        f = p.font()
        f.setPixelSize(11)
        f.setBold(True)
        p.setFont(f)
        for i, s in enumerate(scr):
            if not s:
                continue
            picked = i == self.picked
            r = 10 if picked else 8
            p.setPen(QtGui.QPen(QtGui.QColor(0, 0, 0, 200), 2))
            p.setBrush(QtGui.QColor(PICKED if picked else COLOUR))
            if i == len(scr) - 1 and not self.closed and len(scr) > 1:
                p.drawRect(QtCore.QRectF(s[0] - r, s[1] - r, 2 * r, 2 * r))      # the end: a square
            else:
                p.drawEllipse(QtCore.QPointF(*s), r, r)
            p.setPen(QtGui.QColor("#1a1a1a"))
            p.drawText(QtCore.QRectF(s[0] - r, s[1] - r, 2 * r, 2 * r), QtCore.Qt.AlignCenter, str(i + 1))
