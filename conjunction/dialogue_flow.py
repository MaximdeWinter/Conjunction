"""A talk's dialogue laid out to be read at a glance (dialogue_view draws it) - the way the game's talks go:

    down the middle     what is always said: the lines one after the other, a block per run of lines
    a choice            its answers in one box; what each does decides where its way is drawn:
      goes on           under the choice, side by side, and together again below (a choice of tone; the main
                        answer that takes the talk on)
      question          to the right; a dashed way back into the choice (asked, answered, choose again)
      ends the talk     to the right, under the questions, with its end: the quest goes on / talk again later /
                        the quest fails
    an if / at random   its ways side by side, together again below unless a way ends the talk

Pure data, no Qt: layout(dialogue, names) -> Flow (boxes, wires, pills in pixels, top left at 0, 0). A box keeps
what it shows (`ref`): the lines (list, first, last index), a choice / if / random (list, index), an answer (the
answer dict), so a click finds it.
"""
from dataclasses import dataclass, field

from . import dialogue as D

W = 380                     # a block down the middle
LANE = 300                  # a way beside
GAP = 28                    # between two boxes, one under the other
SIDE = 70                   # between a choice and the ways to its right
HEAD = 26                   # a box's title row
LINE = 17                   # a line of text
ROW = 24                    # an answer's row
PILL_W, PILL_H = 170, 26
CHARS = 44                  # characters to a line of text in a block (LANE: fewer)

MAIN = "#e3c65f"            # the game's yellow: the answer that takes the talk on
COLOUR = {"on": "#d8d8e0", "back": "#9aa0b0", "up": "#9aa0b0", "continue": "#22c55e", "retry": "#d9a45b",
          "fail": "#ef4444"}
WORD = {"on": "", "back": "back to choice", "up": "back to previous choice", "continue": "end: continue",
        "retry": "end: repeatable", "fail": "end: fail quest"}
PILL = {"continue": "CONTINUE QUEST", "retry": "REPEATABLE", "fail": "FAIL QUEST"}


def answer_kind(c):
    """An answer's kind; one whose lines end with an if / at random whose ways all go back is a question."""
    sub = c.get("lines") or []
    if sub and ("if" in sub[-1] or "random" in sub[-1]) and all(
            e in ("back", "up") for _l, e in D.ways(sub[-1])):
        return "back"
    return kind(c.get("end"))


def kind(end):
    """What an answer's end is, in the look's words: on, back, up, continue, retry, fail (a path or a scene's exit
    ends the talk and goes on)."""
    e = str(end or "continue")
    return "continue" if e.startswith(("path:", "out:")) else e if e in COLOUR else "continue"


@dataclass
class Box:
    kind: str                   # start | lines | choice | if | random | script | pill
    x: float
    y: float
    w: float
    h: float
    title: str = ""
    rows: list = field(default_factory=list)     # lines: [(who key, NAME, [text lines])]; choice: [answer rows]
    colour: str = ""
    ref: tuple = None
    ports: list = field(default_factory=list)    # a choice's rows: the y of each (their port on the right edge)


@dataclass
class Talk:
    """Who is who in the talk: names {who: name}, the player's name, colour(who) -> a speaker's colour."""
    names: dict
    player: str = "Geralt"
    colour: object = D.color


@dataclass
class Wire:
    points: list
    colour: str = "#808090"
    dashed: bool = False
    arrow: bool = True


@dataclass
class Flow:
    boxes: list = field(default_factory=list)
    wires: list = field(default_factory=list)
    w: float = 0
    h: float = 0
    exits: list = field(default_factory=list)    # open ends at the bottom: where the talk goes on from here

    def move(self, dx, dy):
        for b in self.boxes:
            b.x += dx
            b.y += dy
        for wi in self.wires:
            wi.points = [(x + dx, y + dy) for x, y in wi.points]
        self.exits = [(x + dx, y + dy) for x, y in self.exits]
        return self

    def take(self, other):
        self.boxes += other.boxes
        self.wires += other.wires


def wrap(text, width):
    words, lines, cur = str(text or "").split(), [], ""
    for w in words:
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}".strip()
    return lines + [cur] if cur else lines or [""]


def chips(c):
    """The small tags of an answer: what it costs, needs, does."""
    out = []
    if c.get("emphasize"):
        out.append("main")
    if c.get("once"):
        out.append("once")
    if c.get("pay"):
        out.append(f"{c['pay']} crowns")
    if c.get("axii"):
        out.append("Axii" + (f" {c['axii']}" if c["axii"] is not True and c["axii"] != 1 else ""))
    conds = D.conditions(c)
    if D.AFTER_ALL in conds:
        out.append("after all others")
    if any(isinstance(x, str) and x.startswith("@") and x != D.AFTER_ALL for x in conds):
        out.append("after option")
    if any(not (isinstance(x, str) and x.startswith("@")) for x in conds):
        out.append("condition")
    if isinstance(c.get("needs"), dict):
        out.append("has none" if c["needs"].get("none") else "player has item")
    if isinstance(c.get("give"), dict):
        out.append("gives item")
    if isinstance(c.get("receive"), dict):
        out.append("receives")
    if c.get("icon") and c["icon"] != "exit":
        out.append(c["icon"])
    return out


def layout(lines, names, player="Geralt", colour=None, monologue=False):
    """The whole talk: TALK STARTS, its flow, and QUEST GOES ON where its lines run out. `colour(who)`: a
    speaker's colour (the talk's: dialogue.color(who, step))."""
    t = Talk(names, player, colour or D.color)
    root = Flow()
    start = Box("start", 0, 0, W, 30, "MONOLOGUE START" if monologue else "DIALOGUE START", colour="#808090",
                rows=[] if monologue else [names.get("npc", "NPC")], ref=("start", lines))
    root.boxes.append(start)
    body = flow(lines, W, t).move(0, 30 + GAP)
    root.wires.append(Wire([(W / 2, 30), (W / 2, 30 + GAP)]))
    root.take(body)
    y = max([30 + GAP + body.h] + [b.y + b.h for b in root.boxes if b.x < W])
    if body.exits:
        pill = Box("pill", W / 2 - PILL_W / 2, y + GAP, PILL_W, PILL_H, PILL["continue"], colour=COLOUR["continue"],
                   ref=("end", lines, "continue"))
        _join(root, body.exits, W / 2, y + GAP, COLOUR["continue"])
        root.boxes.append(pill)
    left = min(b.x for b in root.boxes)
    if left < 0:
        root.move(-left, 0)
    root.w = max(b.x + b.w for b in root.boxes)
    root.h = max(b.y + b.h for b in root.boxes)
    return root


def _join(f, exits, cx, y, colour="#808090"):
    """Wires from the open ends down into (cx, y): straight when one is right above, else across just above."""
    for x, y0 in exits:
        if abs(x - cx) < 1:
            f.wires.append(Wire([(x, y0), (cx, y)], colour))
        else:
            mid = y - 12
            f.wires.append(Wire([(x, y0), (x, mid), (cx, mid), (cx, y)], colour, arrow=True))


def flow(ls, w, t, entry=True):
    """A list of lines in a column `w` wide from (0, 0): its boxes, and where it goes on at its bottom."""
    f = Flow(w=w)
    cx = w / 2
    y = 0.0
    exits = [(cx, 0.0)] if entry else []
    chars = CHARS if w >= W else CHARS - 10
    k = 0
    first = True
    while k < len(ls):
        x = ls[k]
        if any(s in x for s in D.SPLITS):
            sub = split(ls, k, w, t)
            sub.move(0, y + (0 if first else GAP))
            top = y + (0 if first else GAP)
            if exits and not first:
                _join(f, exits, cx, top)
            f.take(sub)
            f.w = max(f.w, sub.w)
            exits = sub.exits
            y = top + sub.h
            k += 1
            first = False
            continue
        if "script" in x:
            box = Box("script", 0, 0, w, 24, "SCRIPT", rows=[(x["script"] or {}).get("function") or ""],
                      colour="#9fb0ff", ref=("script", ls, k))
            j = k + 1
        else:
            j = k
            rows = []
            while j < len(ls) and "who" in ls[j]:
                who = ls[j].get("who") or "npc"
                name = (t.player if D.is_player(who) else t.names.get(who) or D._label(who) or "NPC").upper()
                rows.append((who, name, wrap(ls[j].get("text") or "...", chars), bool(ls[j].get("voice")),
                             t.colour(who)))
                j += 1
            if j == k:                          # (something else: shown as nothing, skipped)
                k += 1
                continue
            h = 8 + sum(LINE * len(r[2]) + 5 for r in rows) + 4
            box = Box("lines", 0, 0, w, h, rows=rows, ref=("lines", ls, k, j - 1))
        top = y + (0 if first else GAP)
        box.x, box.y = 0, top
        if exits and not first:
            _join(f, exits, cx, top)
        f.boxes.append(box)
        exits = [(cx, top + box.h)]
        y = top + box.h
        k = j
        first = False
    f.h = y
    f.exits = exits
    return f


def split(ls, k, w, t):
    """A choice / if / random at the top of a column `w` wide."""
    x = ls[k]
    f = Flow(w=w)
    cx = w / 2
    if "choice" in x:
        answers = x["choice"]
        rows, ports = [], []
        for j, c in enumerate(answers):
            e = answer_kind(c)
            rows.append({"text": c.get("text") or "...", "kind": e, "chips": chips(c), "ref": c,
                         "main": bool(c.get("emphasize"))})
            ports.append(HEAD + j * ROW + ROW / 2)
        box = Box("choice", 0, 0, w, HEAD + len(answers) * ROW + 6, "CHOICE", rows=rows,
                  colour="#b99be6", ref=("choice", ls, k), ports=ports)
        ways = [(c, answer_kind(c), c.get("lines") or []) for c in answers]
    else:
        brs = [(x.get("then") or {}, "then"), (x.get("else") or {}, "otherwise")] if "if" in x else \
            [(br, f"outcome {j + 1}") for j, br in enumerate(x.get("random") or [])]
        c_ = x.get("if") or {}
        title = f"IF  {c_.get('fact') or '...'} {c_.get('op', '>=')} {c_.get('value', 1)}" if "if" in x \
            else "AT RANDOM"
        box = Box("if" if "if" in x else "random", 0, 0, w, 30, title, colour="#d9a45b", ref=("split", ls, k))
        ways = [(br, kind(br.get("end") or "on"), br.get("lines") or [], label) for br, label in brs]
        ways = [(br, e, sub) for br, e, sub, _l in ways]
    f.boxes.append(box)
    below = box.h
    # the ways that go on: side by side under it, together again at the bottom. None of them: the main answer
    # that ends the talk (the game's yellow one) goes down the middle
    ons = [(c, sub) for c, e, sub in ways if e == "on"]
    middle = None
    if not ons and "choice" in x:
        middle = next((j for j, (c, e, sub) in enumerate(ways) if c.get("emphasize") and sub
                       and e not in ("back", "up")), None)
    lanes = []
    for c, sub in ons:
        lane = flow(sub, LANE, t) if sub else None
        lanes.append((c, lane))
    widths = [(ln.w if ln else 0) for _c, ln in lanes]
    total = sum(widths) + GAP * max(0, len([x_ for x_ in widths if x_]) - 1)
    x0 = cx - total / 2
    top = below + GAP
    exits, bottom = [], below
    named = "choice" in x and len(lanes) > 1
    if named:
        top += 18                               # room for the answer's words over its way
    for (c, lane), lw in zip(lanes, widths):
        if lane is None:
            exits.append((cx, below))           # no lines of its own: straight on
            continue
        lane.move(x0, top)
        lcx = x0 + lw / 2 if lw <= LANE else x0 + LANE / 2
        f.wires.append(Wire([(cx, below), (cx, below + 12), (lcx, below + 12), (lcx, top)], "#b99be6"))
        if named or "choice" not in x:
            label = c.get("text") if "choice" in x else None
            f.boxes.append(Box("label", x0, top - 18, min(lw, LANE), 16, label or "", colour="#b99be6",
                               ref=("answer", c)))
        f.take(lane)
        exits += lane.exits
        bottom = max(bottom, max([b.y + b.h for b in lane.boxes] + [top]))
        x0 += lw + GAP
    if any(lane is None for _c, lane in lanes) and len(lanes) > 1:
        exits = [(cx, below)] + [e for e in exits if e != (cx, below)]
    if middle is not None:                      # the main way down the middle, its end below it
        c, e, sub = ways[middle]
        lane = flow(sub, w, t).move(0, below + GAP)
        f.wires.append(Wire([(cx, below), (cx, below + GAP)], MAIN))
        f.take(lane)
        ly = max(b.y + b.h for b in lane.boxes)
        bottom = ly
        if lane.exits:
            pill = Box("pill", cx - PILL_W / 2, ly + GAP, PILL_W, PILL_H, _pill(c, e), colour=COLOUR[e],
                       ref=("end", c, e))
            _join(f, lane.exits, cx, pill.y, COLOUR[e])
            f.boxes.append(pill)
            bottom = pill.y + pill.h
    # the others: to the right of all that - questions (a way back) first, then those that end the talk; their wires
    # turn down only just before them (nothing in the middle is crossed)
    right = max(w, max((b.x + b.w for b in f.boxes), default=w)) + SIDE
    ry = 0.0
    bus = right - 14
    order = sorted([(j, c, e, sub) for j, (c, e, sub) in enumerate(ways) if e != "on" and j != middle],
                   key=lambda t: t[2] not in ("back", "up"))
    backs = []
    for j, c, e, sub in order:
        py = box.ports[j] if box.ports else box.h / 2
        colour = COLOUR[e]
        if sub:
            lane = flow(sub, LANE, t).move(right, ry)
            turn = right - SIDE + 18 + 6 * (j % 5)
            f.wires.append(Wire([(w, py), (turn, py), (turn, ry + 14), (right, ry + 14)], colour, arrow=True))
            f.take(lane)
            ly = max(b.y + b.h for b in lane.boxes)
            if e in ("back", "up"):
                if e == "back" and "choice" in x:
                    backs.append(ly - 10)
                    f.wires.append(Wire([(right, ly - 10), (bus, ly - 10)], colour, dashed=True, arrow=False))
                else:
                    pill = Box("pill", right + LANE / 2 - PILL_W / 2, ly + GAP / 2, PILL_W, PILL_H,
                               "BACK TO THE CHOICE ABOVE" if e == "up" or "choice" in x else "BACK TO THE CHOICES",
                               colour=colour, ref=("end", sub, e))
                    f.wires.append(Wire([(right + LANE / 2, ly), (right + LANE / 2, pill.y)], colour, dashed=True))
                    f.boxes.append(pill)
                    ly = pill.y + pill.h
            elif lane.exits:
                pill = Box("pill", right + LANE / 2 - PILL_W / 2, ly + GAP / 2, PILL_W, PILL_H, _pill(c, e),
                           colour=colour, ref=("end", c, e))
                _join(f, lane.exits, right + LANE / 2, pill.y, colour)
                f.boxes.append(pill)
                ly = pill.y + pill.h
            ry = ly + GAP
        else:
            if e == "back":
                continue                        # a question with no answer: nothing to draw beside it
            pill = Box("pill", right, max(ry, py - PILL_H / 2), PILL_W, PILL_H,
                       _pill(c, e) if e != "up" else "BACK TO THE CHOICE ABOVE", colour=colour, ref=("end", c, e))
            turn = right - SIDE + 18 + 6 * (j % 5)
            f.wires.append(Wire([(w, py), (turn, py), (turn, pill.y + PILL_H / 2), (right, pill.y + PILL_H / 2)],
                                colour, dashed=e == "up"))
            f.boxes.append(pill)
            ry = pill.y + PILL_H + GAP
    if backs:                                   # the questions' way back: one dashed line into the choice
        into = box.h - 8
        f.wires.append(Wire([(bus, max(backs)), (bus, into), (w, into)], COLOUR["back"], dashed=True))
    f.w = max([w] + [b.x + b.w for b in f.boxes])
    f.h = max([bottom] + [b.y + b.h for b in f.boxes])
    f.exits = exits
    return f


def _pill(c, e):
    end = str(c.get("end") or "")
    if end.startswith("out:"):
        return ("CONTINUE AT: " + end[4:].replace("_", " "))[:26].upper()
    return PILL.get(e, e.upper())
