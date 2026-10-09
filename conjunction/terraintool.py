"""The terrain brush in the world - the editor's Terrain mode (Maxim 04.10.: "ein höhen tool ... größere und
kleinere pinsel etc. volles set an möglichkeiten").

The ground under the cursor comes from the terrain's own heights (terrain.py), the strokes already painted
included - not from the game, whose ground stays as it was until the next start. Over the game the overlay draws the
brush (its circle or square on the ground, the inner line where it is at half strength) and a net over the ground
the strokes changed, in its new height: gold where it went up, blue where it went down.

  left button held     paint (a dab every third of the radius); Shift: the other way (raise <-> lower);
                       Ctrl: smooth. Ramp: press at its start, let go at its end. Flatten / set: to the height
                       where the drag began, or to the height set in the brush panel.
  mouse wheel          the brush's size; Shift + wheel: its strength
  Ctrl+Z               the last drag taken back

Each drag is kept in the project at once (terrain.yml, one entry per drag); Build & Play puts the changed tiles and
their collision into the quest's mod (the game reads them when it starts).
"""
import math
import threading

from PySide6 import QtCore, QtGui

from . import config, terrain

TOOLS = [("raise", "Raise"), ("lower", "Lower"), ("smooth", "Smooth"), ("flatten", "Flatten"),
         ("set", "Set height"), ("ramp", "Ramp"), ("noise", "Roughen"), ("terrace", "Terrace")]
LABEL = dict(TOOLS)
DEFAULTS = {"op": "raise", "radius": 6.0, "strength": 0.3, "falloff": "smooth", "shape": "circle",
            "height": None, "step": 1.0, "scale": 4.0}
RADIUS = (0.5, 60.0)
STRENGTH = {"raise": (0.02, 5.0), "lower": (0.02, 5.0), "noise": (0.05, 5.0)}    # metres; the rest 0..1
SPACING = 0.33                  # a dab every third of the radius
NET = 34                        # lines of the net each way at most
UP, DOWN = QtGui.QColor(227, 198, 95), QtGui.QColor(110, 170, 230)

_depot, _depot_lock = None, threading.Lock()


def depot():
    """The game's files by path (read once: it lists every bundle - seconds)."""
    global _depot
    with _depot_lock:
        if _depot is None:
            from .bundles import Depot
            _depot = Depot()
        return _depot


class TerrainTool:
    def __init__(self, ed):
        self.ed = ed
        self.brush = dict(DEFAULTS, **config.load().get("terrain_brush", {}))
        self.groups = terrain.load(ed.project.path)
        self.terrain, self.world, self.loading = None, None, False
        self.cursor = None              # the ground under the mouse [x, y, z]
        self.drag = None                # {"op", "strokes", "start", "last", "height"} while the button is held
        self.net = None                 # [(points of a line)] cached until the strokes change
        self.at = None                  # (mx, my, cam pos, cam yaw/pitch) the cursor was worked out for

    # --- the terrain of the world being edited (built in the background: the depot and the tiles take seconds)
    def ready(self):
        world = self.ed.world
        if not world:
            return False
        if self.terrain is not None and self.world == world:
            return True
        if not self.loading:
            self.loading = True
            threading.Thread(target=self._load, args=(world,), daemon=True).start()
        return False

    def make(self, world):
        """A world's terrain as the game has it (a test gives a made-up one)."""
        return terrain.Terrain(world, depot())

    def _load(self, world):
        try:
            t = self.make(world)
            t.apply(terrain.strokes_of(self.groups, world))
            self.terrain, self.world, self.net = t, world, None
        except Exception as ex:                         # noqa: BLE001 - a world without terrain (an interior)
            print(f"[terrain] no terrain for {world}: {ex}", flush=True)
            self.world = world
        finally:
            self.loading = False

    def _rebuild(self):
        """The terrain again from the kept strokes (after an undo)."""
        t = self.make(self.world)
        t.apply(terrain.strokes_of(self.groups, self.world))
        self.terrain, self.net = t, None

    # --- the brush
    def set(self, key, value):
        self.brush[key] = value
        cfg = config.load()
        cfg["terrain_brush"] = self.brush
        config.save(cfg)
        self.ed.hud.sync()

    def resize(self, notches):
        lo, hi = RADIUS
        self.set("radius", round(max(lo, min(hi, self.brush["radius"] * 1.12 ** notches)), 2))

    def strengthen(self, notches):
        lo, hi = STRENGTH.get(self.brush["op"], (0.05, 1.0))
        self.set("strength", round(max(lo, min(hi, self.brush["strength"] * 1.15 ** notches)), 3))

    def _stroke(self, op, x, y, extra=None):
        b = self.brush
        s = {"op": op, "x": round(x, 2), "y": round(y, 2), "radius": b["radius"], "strength": b["strength"]}
        if b["falloff"] != "smooth":
            s["falloff"] = b["falloff"]
        if b["shape"] != "circle":
            s["shape"] = b["shape"]
        if op == "noise":
            s.update(scale=b["scale"], seed=len(self.groups))
        if op == "terrace":
            s["step"] = b["step"]
        if op in ("flatten", "set") and self.drag and self.drag.get("height") is not None:
            s["height"] = round(self.drag["height"], 3)
        if op in ("smooth", "flatten", "ramp", "terrace") and s["strength"] > 1:
            s["strength"] = 1.0
        s.update(extra or {})
        return s

    # --- input (from the editor's tick, the mouse over the world)
    def handle(self, edge, up, now, vk, mx, my, w, h, moved_cam):
        if not self.ready():
            return
        key = (round(mx), round(my), tuple(round(v, 3) for v in self.ed.cam.pos), self.ed.cam.yaw, self.ed.cam.pitch)
        if key != self.at or moved_cam:
            self.at = key
            origin, d = self.ed.cursor_ray(mx, my, w, h)
            self.cursor = self.terrain.ground(origin, d)
        c = self.cursor
        if edge[vk["LBUTTON"]] and c:
            op = self.brush["op"]
            if now[vk["CTRL"]]:
                op = "smooth"
            elif now[vk["SHIFT"]] and op in ("raise", "lower"):
                op = "lower" if op == "raise" else "raise"
            height = self.brush["height"] if self.brush["height"] is not None else c[2]
            self.drag = {"op": op, "strokes": [], "start": list(c), "last": None, "height": height}
            if op != "ramp":
                self._dab(c)
        elif self.drag and now[vk["LBUTTON"]] and c and self.drag["op"] != "ramp":
            last = self.drag["last"]
            if last is None or math.hypot(c[0] - last[0], c[1] - last[1]) >= self.brush["radius"] * SPACING:
                self._dab(c)
        if self.drag and up[vk["LBUTTON"]]:
            self._finish(c)

    def _dab(self, c):
        s = self._stroke(self.drag["op"], c[0], c[1])
        self.terrain.apply([s])
        self.drag["strokes"].append(s)
        self.drag["last"] = list(c)
        self.net = None

    def _finish(self, c):
        d, self.drag = self.drag, None
        if d["op"] == "ramp":
            if not c or math.hypot(c[0] - d["start"][0], c[1] - d["start"][1]) < 0.5:
                return
            s = self._stroke("ramp", d["start"][0], d["start"][1],
                             {"x2": round(c[0], 2), "y2": round(c[1], 2), "height": round(d["start"][2], 3),
                              "height2": round(c[2], 3)})
            self.terrain.apply([s])
            d["strokes"] = [s]
            self.net = None
        if not d["strokes"]:
            return
        self.groups.append({"world": self.world, "strokes": d["strokes"]})
        terrain.save(self.ed.project.path, self.groups)
        self.ed.undo.append(("terrain",))
        self.ed.hud.sync()

    def undo(self):
        """The last drag taken back (the editor's Ctrl+Z)."""
        if not self.groups:
            return
        self.groups.pop()
        terrain.save(self.ed.project.path, self.groups)
        if self.world:
            self._rebuild()
        self.ed.hud.sync()

    def undo_button(self):
        """The panel's Undo: the last drag, whatever else was changed since (its entry leaves the editor's list)."""
        for i in range(len(self.ed.undo) - 1, -1, -1):
            if self.ed.undo[i] == ("terrain",):
                del self.ed.undo[i]
                break
        self.undo()

    def clear(self):
        """Every stroke of this world gone (the panel's Reset)."""
        before = len(self.groups)
        self.groups = [g for g in self.groups if g["world"] != self.world]
        terrain.save(self.ed.project.path, self.groups)
        gone = before - len(self.groups)            # as many of the editor's terrain undo entries go (the newest)
        for i in range(len(self.ed.undo) - 1, -1, -1):
            if gone and self.ed.undo[i] == ("terrain",):
                del self.ed.undo[i]
                gone -= 1
        if self.world:
            self._rebuild()
        self.ed.hud.sync()

    def painted(self):
        return sum(1 for g in self.groups if g["world"] == self.world)

    def doing(self):
        b = self.brush
        if self.terrain is None:
            return ("Terrain · reading the ground ..." if self.ed.world else "Terrain"), []
        unit = "m" if b["op"] in STRENGTH else ""
        what = f"{LABEL[b['op']]} · {b['radius']:g} m · {b['strength']:g}{unit}"
        return f"Terrain · {what}", ["Shift", "Ctrl", "Wheel"]

    # --- drawing (the overlay's paintEvent)
    def draw(self, p, w, h):
        if self.terrain is None:
            return
        self._draw_net(p, w, h)
        c = self.cursor
        if not c:
            return
        b = self.brush
        if self.drag and self.drag["op"] == "ramp":
            a = self.ed.cam.project(self.drag["start"], w, h)
            e = self.ed.cam.project(c, w, h)
            if a and e:
                p.setPen(QtGui.QPen(QtGui.QColor(255, 255, 255, 220), 2, QtCore.Qt.DashLine))
                p.drawLine(QtCore.QPointF(*a), QtCore.QPointF(*e))
        inner = b["radius"] * (0.5 if b["falloff"] != "hard" else 1.0)
        for radius, pen in ((b["radius"], QtGui.QPen(QtGui.QColor(255, 255, 255, 230), 2)),
                            (inner, QtGui.QPen(QtGui.QColor(255, 255, 255, 120), 1, QtCore.Qt.DashLine))):
            if radius == b["radius"] or b["falloff"] != "hard":
                self._outline(p, c, radius, pen, w, h)
        dot = self.ed.cam.project(c, w, h)
        if dot:
            p.setPen(QtCore.Qt.NoPen)
            p.setBrush(QtGui.QColor(255, 255, 255, 230))
            p.drawEllipse(QtCore.QPointF(*dot), 3, 3)

    def _outline(self, p, c, radius, pen, w, h):
        """The brush's edge laid on the ground (circle or square)."""
        if self.brush["shape"] == "square":
            k = 12
            side = [(-1 + 2 * i / k, -1) for i in range(k)] + [(1, -1 + 2 * i / k) for i in range(k)] + \
                   [(1 - 2 * i / k, 1) for i in range(k)] + [(-1, 1 - 2 * i / k) for i in range(k + 1)]
            pts = [(c[0] + u * radius, c[1] + v * radius) for u, v in side]
        else:
            pts = [(c[0] + radius * math.cos(t * math.pi / 24), c[1] + radius * math.sin(t * math.pi / 24))
                   for t in range(49)]
        scr = [self.ed.cam.project([x, y, self.terrain.height(x, y) + 0.05], w, h) for x, y in pts]
        p.setPen(QtGui.QPen(QtGui.QColor(0, 0, 0, 110), pen.widthF() + 2))
        for a, b in zip(scr, scr[1:]):
            if a and b:
                p.drawLine(QtCore.QPointF(*a), QtCore.QPointF(*b))
        p.setPen(pen)
        for a, b in zip(scr, scr[1:]):
            if a and b:
                p.drawLine(QtCore.QPointF(*a), QtCore.QPointF(*b))

    def _make_net(self):
        """Lines over the ground the strokes changed, in its new height: [(colour, alpha, [points])]."""
        strokes = terrain.strokes_of(self.groups, self.world) + (self.drag["strokes"] if self.drag else [])
        if not strokes:
            return []
        xs = [s["x"] for s in strokes] + [s.get("x2", s["x"]) for s in strokes]
        ys = [s["y"] for s in strokes] + [s.get("y2", s["y"]) for s in strokes]
        r = max(s["radius"] for s in strokes)
        x0, x1, y0, y1 = min(xs) - r, max(xs) + r, min(ys) - r, max(ys) + r
        step = max(self.terrain.spacing * 2, max(x1 - x0, y1 - y0) / NET)
        nx, ny = int((x1 - x0) / step) + 1, int((y1 - y0) / step) + 1
        grid = [[(x0 + i * step, y0 + j * step) for i in range(nx)] for j in range(ny)]
        delta = [[self.terrain.change(x, y) for x, y in row] for row in grid]
        lines = []
        for rows, dl in ((grid, delta), (list(map(list, zip(*grid))), list(map(list, zip(*delta))))):
            for row, drow in zip(rows, dl):
                run = []
                for (x, y), dz in zip(row, drow):
                    if abs(dz) > 0.03:
                        run.append(([x, y, self.terrain.height(x, y) + 0.03], dz))
                    elif run:
                        lines.append(run)
                        run = []
                if run:
                    lines.append(run)
        return lines

    def _draw_net(self, p, w, h):
        if self.net is None:
            self.net = self._make_net()
        for run in self.net:
            scr = [(self.ed.cam.project(pt, w, h), dz) for pt, dz in run]
            for (a, dz), (b, _dz) in zip(scr, scr[1:]):
                if a and b:
                    col = QtGui.QColor(UP if dz > 0 else DOWN)
                    col.setAlpha(int(min(230, 90 + 60 * abs(dz))))
                    p.setPen(QtGui.QPen(col, 1.2))
                    p.drawLine(QtCore.QPointF(*a), QtCore.QPointF(*b))
