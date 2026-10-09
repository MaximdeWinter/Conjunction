"""The wires of a quest graph: orthogonal, around the nodes - PathView's router (src/lib/routing, MIT, by
milanofthe) in Python.

A* on the 10 px grid: a step costs 1, a turn 2 more, a step through a node's margin 6 more; no turning back. A node's
inside cannot be crossed (only its own ports). A wire already laid makes the cells along it dearer for wires to
other targets, so wires keep apart where they can and merge where they lead to the same port.

    route(g)        sets wire.points (pixel corners, source port first) of every wire of the graph
"""
import heapq

from .graph_layout import GRID, port
from .quest_graph import FAIL_MARK, fails_here

TURN_COST = 2
SOFT_COST = 6
CROWD_COST = 3
STRAIGHT = 3                # cells a wire runs straight down out of a node before it may turn
WINDOWS = ((16, 20_000), (64, 60_000))  # (cells around start and end, most cells tried) - small ones first
MAX_EXPANSIONS = 200_000
# the last try, over the whole graph (a wire far back up into a path placed earlier): PathView's weighted search -
# the heuristic counts more, far fewer cells are tried, the way found is at most a little longer than the best
WIDE_WEIGHT = 2.0
WIDE_EXPANSIONS = 400_000
FAR = 120                   # cells apart: a wire this long tries the whole graph at once
DX = (1, -1, 0, 0)          # right, left, down, up
DY = (0, 0, 1, -1)
OPPOSITE = (1, 0, 3, 2)
RIGHT, LEFT, DOWN, UP = 0, 1, 2, 3


class Obstacles:
    def __init__(self):
        self.hard = set()
        self.soft = set()
        self.box = [0, 0, 0, 0]

    def add(self, x0, y0, x1, y1):
        """A node's rectangle (pixels): its cells hard, one cell around it soft."""
        a, b, c, d = x0 // GRID, y0 // GRID, -(-x1 // GRID), -(-y1 // GRID)
        for gy in range(b - 1, d + 2):
            for gx in range(a - 1, c + 2):
                (self.hard if a <= gx <= c and b <= gy <= d else self.soft).add((gx, gy))
        self.box = [min(self.box[0], a), min(self.box[1], b), max(self.box[2], c), max(self.box[3], d)]


def _turns(dx, dy, d):
    ahead = dx if d == RIGHT else -dx if d == LEFT else dy if d == DOWN else -dy
    side = dy if d in (RIGHT, LEFT) else dx
    if side == 0:
        return 0 if ahead >= 0 else 2
    return 1 if ahead >= 0 else 2


def _h(gx, gy, d, end):
    dx, dy = end[0] - gx, end[1] - gy
    return abs(dx) + abs(dy) + TURN_COST * _turns(dx, dy, d)


def search(obs, start, start_dir, end, end_dir, forced, crowd=None, dst=None):
    """The cheapest path of grid corners from start (leaving in start_dir) to end (arriving in end_dir), or None."""
    far = abs(start[0] - end[0]) + abs(start[1] - end[1]) > FAR
    for pad, most in ((None, WIDE_EXPANSIONS),) if far else WINDOWS + ((None, WIDE_EXPANSIONS),):
        if pad is None:
            b = obs.box
            win = (min(b[0], start[0], end[0]) - 16, min(b[1], start[1], end[1]) - 16,
                   max(b[2], start[0], end[0]) + 16, max(b[3], start[1], end[1]) + 16)
        else:
            win = (min(start[0], end[0]) - pad, min(start[1], end[1]) - pad,
                   max(start[0], end[0]) + pad, max(start[1], end[1]) + pad)
        found = _search(obs, start, start_dir, end, end_dir, forced, win, crowd, dst,
                        WIDE_WEIGHT if pad is None else 1.0, most)
        if found:
            return found
    return None


def _search(obs, start, sd, end, ed, forced, win, crowd, dst, weight=1.0, most=MAX_EXPANSIONS):
    # (the hot loop of the graph: names bound locally, the heuristic inlined - about twice as fast as calling _h)
    ex, ey = end
    hard, soft = obs.hard, obs.soft
    wx0, wy0, wx1, wy1 = win
    push, pop = heapq.heappush, heapq.heappop
    INF = 1 << 30

    def h(x, y, d):
        dx, dy = ex - x, ey - y
        if d == 0:
            ahead, side = dx, dy
        elif d == 1:
            ahead, side = -dx, dy
        elif d == 2:
            ahead, side = dy, dx
        else:
            ahead, side = -dy, dx
        t = (0 if ahead >= 0 else 2) if side == 0 else (1 if ahead >= 0 else 2)
        return (dx if dx >= 0 else -dx) + (dy if dy >= 0 else -dy) + TURN_COST * t
    s0 = (start[0], start[1], sd)
    g = {s0: 0}
    parent = {s0: None}
    heap = [(weight * h(start[0], start[1], sd), 0, start[0], start[1], sd)]
    closed = set()
    expanded = 0
    while heap:
        _f, cost, x, y, d = pop(heap)
        s = (x, y, d)
        if s in closed:
            continue
        closed.add(s)
        expanded += 1
        if expanded > most:
            return None
        if x == ex and y == ey:
            return _corners(parent, s)
        first = parent[s] is None
        back = OPPOSITE[d]
        for nd in (0, 1, 2, 3):
            if nd == back or (first and nd != d):
                continue
            nx, ny = x + DX[nd], y + DY[nd]
            if nx < wx0 or nx > wx1 or ny < wy0 or ny > wy1:
                continue
            cell = (nx, ny)
            free = cell in forced
            if not free and cell in hard:
                continue
            c = cost + 1 + (0 if nd == d else TURN_COST)
            if not free and cell in soft:
                c += SOFT_COST
            if crowd is not None:
                others = crowd.get((nx, ny, nd < 2))
                if others and (len(others) > 1 or dst not in others):
                    c += CROWD_COST
            if nx == ex and ny == ey and nd != ed:
                c += TURN_COST * 4
            ns = (nx, ny, nd)
            if ns in closed or g.get(ns, INF) <= c:
                continue
            g[ns] = c
            parent[ns] = s
            push(heap, (c + weight * h(nx, ny, nd), c, nx, ny, nd))
    return None


def _corners(parent, s):
    cells = []
    while s is not None:
        cells.append(s)
        s = parent[s]
    cells.reverse()
    out = [cells[0][:2]]
    for i in range(1, len(cells) - 1):
        if cells[i][2] != cells[i + 1][2]:
            out.append(cells[i][:2])
    out.append(cells[-1][:2])
    return out


def _cells(corners):
    """Every cell along the corners, with its axis (True: horizontal)."""
    for (x0, y0), (x1, y1) in zip(corners, corners[1:]):
        horizontal = y0 == y1
        n = max(abs(x1 - x0), abs(y1 - y0))
        for k in range(n + 1):
            yield x0 + k * ((x1 > x0) - (x1 < x0)), y0 + k * ((y1 > y0) - (y1 < y0)), horizontal


_last = {"key": None, "points": None}       # the last graph routed: the same again costs nothing
_ways = {}                                  # (start, its direction, end, its direction, port): the way found
_no_way = set()                             # (those ends, the nodes' cells): no way found - the costliest search


def _key(g):
    """What the wires depend on: the nodes' boxes and exits, the wires' ends."""
    nodes = tuple(sorted((n.id, n.x, n.y, n.w, n.h, tuple(fails_here(e) for e in n.exits))
                         for n in g.nodes.values()))
    wires = tuple((w.src, str(w.port), w.dst, w.enter) for w in g.wires)
    return nodes, wires


def route(g):
    # a board sync with the graph unchanged (a text typed on a card) routes nothing: the last points again
    # (01.10.: a 60-node quest took 1.5 s per sync - most of it A* for wires that had not moved)
    key = _key(g)
    if key == _last["key"]:
        for w, pts in zip(g.wires, _last["points"]):
            w.points = list(pts)
        return
    _route(g)
    _last["key"], _last["points"] = key, [list(w.points) for w in g.wires]


def _route(g):
    obs = Obstacles()
    for n in g.nodes.values():
        obs.add(n.x, n.y, n.x + n.w, n.y + n.h)
        for k, e in enumerate(n.exits):         # the FAILS mark beside an exit: wires go around it
            if fails_here(e):
                x, y = port(n, k)
                obs.add(x + 8, y - 7, x + 8 + FAIL_MARK, y + 7)
    sig = hash(frozenset(obs.hard))
    crowd = {}
    # straight wires first (they have one way), then the longer ones around them
    order = sorted(g.wires, key=lambda w: _length(g, w))
    for w in order:
        src, dst = g.nodes[w.src], g.nodes[w.dst]
        a = port(src, w.port)
        b = port(dst, {"top": "in"}.get(w.enter, w.enter))
        sd = DOWN if w.port == "next" else RIGHT
        ed = {"top": DOWN, "bottom": UP}.get(w.enter, RIGHT)     # (bottom: a dialogue's way back up into its choice)
        port0, end = (a[0] // GRID, a[1] // GRID), (b[0] // GRID, b[1] // GRID)
        # out of the bottom the wire runs straight a little first: the '+' under the node sits on it
        lead = STRAIGHT if sd == DOWN and end[1] - port0[1] > STRAIGHT else 0
        while lead and any((port0[0], port0[1] + k) in obs.hard or (port0[0], port0[1] + k) in obs.soft
                           for k in range(2, lead + 2)):
            lead -= 1                           # a node close below: turn earlier
        start = (port0[0], port0[1] + lead)
        forced = {port0, start, end, (start[0] + DX[sd], start[1] + DY[sd]), (end[0] - DX[ed], end[1] - DY[ed])}
        forced |= {(port0[0], port0[1] + k) for k in range(lead)}
        # the same ends as last time and its way still clear of every node: the old way again (moving one node
        # re-routed every wire - A* in Python, seconds on a big quest)
        wkey = (start, sd, end, ed, port0)
        old = _ways.get(wkey)
        if old is not None and not any((cx, cy) in obs.hard and (cx, cy) not in forced
                                       for cx, cy, _h in _cells(old)):
            corners = list(old)
        elif (wkey, sig) in _no_way:
            corners = None                      # no way around found with these nodes - not searched again
        else:
            corners = search(obs, start, sd, end, ed, forced, crowd, w.dst)
            if corners is not None:
                _ways[wkey] = list(corners)
            else:
                _no_way.add((wkey, sig))
        if corners is None:                     # no way around: a straight line says at least where it goes
            corners = [start, (start[0], end[1]), end] if start[0] != end[0] else [start, end]
        corners[0] = port0
        w.points = [(cx * GRID, cy * GRID) for cx, cy in corners]
        for c in _cells(corners):
            crowd.setdefault(c, set()).add(w.dst)


def _length(g, w):
    a = port(g.nodes[w.src], w.port)
    b = port(g.nodes[w.dst], {"top": "in"}.get(w.enter, w.enter))
    return abs(a[0] - b[0]) + abs(a[1] - b[1])
