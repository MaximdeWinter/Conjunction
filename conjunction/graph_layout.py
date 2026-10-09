"""Where the nodes of a quest graph stand (quest_graph.build -> place(g)).

On PathView's grid of 10 px: every node, every port lies on it. The story runs down its column; the columns a node
forks into stand to its right, the first one level with the exit, the others under it. A column that goes back to
the story pushes the story's next node below its own end, so the wire back runs down and left. A chapter starts
under everything before it. A column that would overlap one placed earlier moves one column further right.

    place(g)            sets x, y, w, h of every node (pixels, top left)
    port(node, which)   the point of a port: "in" (top), "left", "next" (bottom), or an exit's index (right side)
"""
GRID = 10
NODE_W = 230
COL = NODE_W + 90               # a column and the gap for its wires
GAP = 40                        # between two nodes of a column
HEAD = 30                       # the title row
LINE = 16                       # one line of text
EXIT = 20                       # one exit row (its port at its middle)
PAD = 8
CHARS = 34                      # about this many characters fit one line of a node


def snap(v):
    return int(-(-v // GRID) * GRID)


def wrap(text, width=CHARS, most=2):
    """The text in lines of about `width` characters, at most `most` (the last one cut with an ellipsis)."""
    words, lines, cur = str(text or "").split(), [], ""
    for w in words:
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}".strip()
    if cur:
        lines.append(cur)
    if len(lines) > most:
        lines = lines[:most]
        lines[-1] = lines[-1][:width - 1].rstrip() + "…"
    return [ln if len(ln) <= width else ln[:width - 1] + "…" for ln in lines]


ENDS = ("done", "success", "fail", "runs_out", "end")


def body(node):
    """The rows of a node under its title: (kind, text) - its text (an action's in one line), what is missing."""
    out = [("text", t) for t in wrap(node.text, CHARS, 1 if node.block == "action" else 2)]
    if node.missing:
        out += [("missing", t) for t in wrap("Missing: " + ", ".join(node.missing), CHARS, 2)]
    return out


def size(node):
    if node.kind in ENDS:
        return 170, 30                                  # an end: a pill
    rows = body(node)
    h = HEAD + len(rows) * LINE
    if node.exits:
        h = snap(h) + len(node.exits) * EXIT
    elif rows:
        h += PAD
    return NODE_W, max(40, snap(h + 2))


def exits_top(node):
    """y of the first exit row, relative to the node."""
    return node.h - len(node.exits) * EXIT


def port(node, which):
    if which == "in":
        return node.x + node.w // 2 // GRID * GRID, node.y
    if which == "left":
        return node.x, node.y + 20
    if which in ("next", "bottom"):
        return node.x + node.w // 2 // GRID * GRID, node.y + node.h
    return node.x + node.w, node.y + exits_top(node) + which * EXIT + EXIT // 2


class _Placer:
    def __init__(self, g):
        self.g = g
        self.rects = []                                 # (x0, y0, x1, y1) of every node placed
        self.done = set()

    def free(self, x0, y0, x1, y1):
        return all(x1 <= a or x0 >= c or y1 <= b or y0 >= d for a, b, c, d in self.rects)

    def extent(self, col, x, y):
        """The rectangles a column's own nodes take, laid out from (x, y) (its forks not counted)."""
        out, cy = [], y
        for nid in col.nodes:
            n = self.g.nodes[nid]
            out.append((x, cy - GAP // 2, x + NODE_W, cy + n.h + GAP // 2))
            cy += n.h + GAP
        return out

    def column(self, col, x, y):
        """Places the column (and its forks) with its head at (x, y); returns the bottom of its last node."""
        if id(col) in self.done:
            return y
        self.done.add(id(col))
        cy = y
        for nid in col.nodes:
            n = self.g.nodes[nid]
            if n.kind == "chapter":                     # a chapter starts under everything before it
                cy = max([cy] + [r[3] + GAP // 2 for r in self.rects])
            n.x, n.y = x + (NODE_W - n.w) // 2 // GRID * GRID, snap(cy)
            self.rects.append((x, n.y - GAP // 2, x + NODE_W, n.y + n.h + GAP // 2))
            cy = n.y + n.h + GAP
            below = n.y
            for k, sub in col.forks.get(nid, []):
                if id(sub) in self.done:
                    continue
                py = port(n, k)[1]
                sy = max(snap(py - 20), below)
                sx = x + COL
                while not all(self.free(*r) for r in self.extent(sub, sx, sy)):
                    sx += COL
                bottom = self.column(sub, sx, sy)
                below = bottom + GAP + (GRID * 2 if sub.then in ("join", "back") else 0)   # room for its wire back
                if sub.then == "join":                  # its wire back comes into the next node from above
                    cy = max(cy, bottom + GAP + GRID * 2)
        return cy - GAP


def place(g):
    for n in g.nodes.values():
        n.w, n.h = size(n)
    p = _Placer(g)
    bottom = p.column(g.main, 0, 0)
    x = COL
    for sub in g.loose:                                 # paths nothing leads to: beside the story, at the top
        while not all(p.free(*r) for r in p.extent(sub, x, 0)):
            x += COL
        p.column(sub, x, 0)
    return bottom
