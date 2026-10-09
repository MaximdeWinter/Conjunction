"""A quest as a graph: nodes and wires, the look of PathView (github.com/pathsim/pathview, MIT, by milanofthe).

Pure data, no Qt: graph_layout places it, graph_route draws its wires, graph_view shows it.

Every step is one node - a block. Six kinds of blocks (BLOCKS, the sidebar): a Goal (what the player does, its
journal line), an Action (what happens), a Choice (the quest splits: Either / or, At random, If), Meanwhile (a lane
beside the story), a Chapter heading and an End (the quest ends: success or failed). A block dropped in is one of
these; what exactly it does is chosen on it (KINDS_OF).

The story runs down one column from "Quest starts" to "Quest done". A node whose quest can go more than one way has
one exit per way on its right side, labelled (a talk's answers, a choice's ways, a lost game); an exit leads on down
(the next node), into a path (a column of its own to the right), or fails the quest right there (a mark at the exit,
FAIL_MARK wide). At its end a path goes back to
the story, into the step after the one that forked.

    build(quest) -> Graph

A kind not listed in KINDS gets a plain node from the board's names and goes on - a new step kind shows up without
a line here. A kind whose quest can go several ways registers its exits (Kind.exits).
"""
from dataclasses import dataclass, field

from . import questboard as QB

# colour of a kind's family (the node's title and, selected, its border)
FAMILY = {"people": "#5aa9e6", "place": "#8fd07a", "things": "#e3c65f", "fight": "#e57a7a",
          "choice": "#b99be6", "time": "#9aa0b0", "story": "#c8c8d0", "action": "#5fcbb9", "lane": "#e07fae",
          "open": "#808090"}
SUCCESS, FAIL, MUTED = "#22c55e", "#ef4444", "#808090"
FAIL_MARK = 48                  # px: the mark beside an exit that fails the quest

# the sidebar: (block, label, its kinds). A block dropped in is its placeholder kind (the same name) until one of
# its kinds is chosen; Chapter and End have one kind and are it at once.
GOAL_KINDS = [k for k, _l, _f in QB.GOALS if k != "either"]
ACTION_KINDS = [k for k, _l, _f in QB.ACTIONS if k not in ("meanwhile", "stop", "random")]
BLOCKS = [("goal", "Goal", GOAL_KINDS), ("action", "Action", ACTION_KINDS),
          ("choice", "Choice", ["either", "random", "if"]), ("parallel", "Meanwhile", ["meanwhile", "stop"]),
          ("chapter", "Chapter", ["chapter"]), ("end", "End", ["end"])]
KINDS_OF = {b: kinds for b, _l, kinds in BLOCKS}
PLACEHOLDERS = {"goal", "action", "choice", "parallel"}
LABEL = dict(QB.LABEL, **{"if": "If", "end": "End", "goal": "Goal", "action": "Action", "choice": "Choice",
                          "parallel": "Meanwhile", "chapter": "Chapter"})


def block_of(kind):
    """Which block of the sidebar a step kind belongs to."""
    if kind in KINDS_OF:
        return kind
    for b, kinds in KINDS_OF.items():
        if kind in kinds:
            return b
    return "goal" if kind in QB.GOAL_KINDS else "action"


@dataclass
class Exit:
    """One way out of a node: its label (in the node, next to its port) and where it leads."""
    label: str
    to: str                     # "next" (on down) | "retry" | "fail" | "path:<id>"; an answer: how it ends
    style: str = "branch"       # "branch" | "lane"
    set: object = None          # (to) -> None: lead it elsewhere ("next", "fail", "path:<id>"); None: fixed
    can_fail: bool = False      # it may end the quest as failed
    wired: bool = False         # (a graph of its own: an output with a wire)


@dataclass
class Kind:
    family: str = "story"
    subject: object = None      # (args, quest) -> who / what the step is about ("" for none)
    exits: object = None        # (args, quest) -> [Exit]
    text: object = None         # (args, quest) -> the line under the title (else the objective)


@dataclass
class Node:
    id: str
    kind: str                   # a step kind, or start / done / success / fail / runs_out / path
    title: str                  # TALK, GO TO, PATH, ...
    block: str = ""             # goal / action / choice / parallel / chapter / end ("" for the graph's own)
    subject: str = ""           # who / what, beside the title
    text: str = ""              # the objective, the action, the path's name, the chapter's title
    missing: list = field(default_factory=list)
    exits: list = field(default_factory=list)       # [Exit]
    colour: str = ""            # the title's colour
    lane: str = ""              # the path colour of the column it stands in ("" in the story)
    path: str = ""              # the path it stands in ("" in the story)
    number: int = 0             # goals are numbered in each list, as the journal shows them
    card: tuple = None          # (steps, index) - its step; (steps, None) for a column's head
    insert: tuple = None        # (steps, index) where a block dropped on it goes (after it)
    goes_on: bool = True
    hidden: bool = False        # its eye shut: its ways and circles in the world only while its card is open
    x: int = 0
    y: int = 0
    w: int = 0
    h: int = 0


@dataclass
class Column:
    """A list of nodes one under the other: the story, a path, a lane, or one end reached by an answer."""
    nodes: list                 # node ids, top down
    then: str = "join"          # join | success | fail | lane | done
    colour: str = ""
    steps: list = None          # the step list it shows
    forks: dict = field(default_factory=dict)       # node id -> [(exit index, Column)]
    parent: tuple = None        # (column, index of the node that forked)


@dataclass
class Wire:
    src: str
    dst: str
    port: object                # "next" (bottom) or the index of the source's exit (right side)
    enter: str = "top"          # "top" | "left"
    style: str = "next"         # next | branch | lane | join
    colour: str = ""
    insert: tuple = None        # (steps, index): a block dropped on the wire goes there
    points: list = field(default_factory=list)      # the routed corners (graph_route)


@dataclass
class Graph:
    nodes: dict = field(default_factory=dict)
    wires: list = field(default_factory=list)
    main: Column = None
    chapters: list = field(default_factory=list)    # node ids of chapter headings
    loose: list = field(default_factory=list)       # columns of paths nothing leads to
    columns: dict = field(default_factory=dict)     # path id -> its column

    def add(self, node):
        self.nodes[node.id] = node
        return node.id


def fails_here(e):
    """An exit that fails the quest right at the node (a mark beside it, no wire)."""
    return e.to == "fail" and e.style != "port"


def _name(ref, quest=None):
    """A reference's words: "place/fisher_2" -> "fisher 2", own items by their name."""
    ref = str(ref or "")
    if ref.startswith("own:"):
        from .quest import _item_name
        return _item_name(ref, (quest or {}).get("items"))
    return ref.split("/")[-1].replace("_", " ")


def _first(*keys):
    def subject(a, quest):
        for k in keys:
            v = a.get(k)
            if isinstance(v, list):
                v = ", ".join(_name(x, quest) for x in v if x)
            elif v:
                v = _name(v, quest)
            if v:
                return v
        return ""
    return subject


def _count(items, word):
    n = len(items or [])
    return f"{n} {word}{'s' * (n != 1)}"


def _setter(d, key, fmt):
    """Leads an exit elsewhere by setting d[key]: fmt "end" (a talk answer: continue / fail / path:x), "path" (a
    bare path id, gone for on down), "way" (path:x / fail, gone for on down)."""
    def set_(to):
        if fmt == "end":
            d[key] = "continue" if to == "next" else to
        elif fmt == "path":
            if to.startswith("path:"):
                d[key] = to[5:]
            else:
                d.pop(key, None)
        elif to == "next":
            d.pop(key, None)
        else:
            d[key] = to
    return set_


def _to(value, fmt):
    """Where a stored value leads, in exit words."""
    if fmt == "path":
        return f"path:{value}" if value else "next"
    v = str(value or "continue")
    return {"continue": "next"}.get(v, v)


def _hands_over(a):
    from . import dialogue as D
    return any("give" in x for x in D.walk(D.from_step(a)))


def _talk_exits(a, quest):
    """Every answer of the talk's choices that ends it: its own exit (on down, again later, into a path, the quest
    fails); the answers that go on in the talk or back to its choices stay inside it. A talk that also ends when its
    lines are over has an exit for that too."""
    from . import dialogue as D
    lines = D.from_step(a)
    out = []
    for x in D.walk(lines):
        if "who" in x or "text" not in x:
            continue                                    # a line, not an answer
        to = _to(x.get("end"), "end")
        if to in ("back", "up", "on"):
            continue                                    # inside the talk
        out.append(Exit(x.get("text") or "...", to, set=_setter(x, "end", "end"), can_fail=True))
    if out and "continue" in D.outcomes(lines) and not any(e.to == "next" for e in out):
        out.insert(0, Exit("dialogue ends", "next"))
    return out


def _either_exits(a, quest):
    if "ways" in a and not a.get("options"):          # (ways wired to goals: the first done wins)
        return [Exit(f"way {k}", _to(w.get("path"), "path"), set=_setter(w, "path", "path"))
                for k, w in enumerate(a["ways"], 1)]
    out = []
    for o in a.get("options") or []:
        gk, ga = QB.step_kind(o.get("goal") or {"goto": {}})
        what = _first("object", "target")(ga, quest)
        out.append(Exit(QB.LABEL.get(gk, gk) + (f" {what}" if what else ""), _to(o.get("path"), "path"),
                        set=_setter(o, "path", "path")))
    return out


def _random_exits(a, quest):
    return [Exit(f"outcome {k}", _to(w.get("path"), "path"), set=_setter(w, "path", "path"))
            for k, w in enumerate(a.get("ways") or [], 1)]


def _lost_exits(a, quest):
    return [Exit("won", "next"), Exit("lost", _to(a.get("lost"), "way"), set=_setter(a, "lost", "way"),
                                     can_fail=True)]


def _if_exits(a, quest):
    return [Exit(side, _to(a.get(side), "way"), set=_setter(a, side, "way"), can_fail=True) for side in ("yes", "no")]


def _if_subject(a, quest):
    if a.get("conditions"):
        from .quest import conditions_text
        return conditions_text(a)
    if a.get("path"):
        return f"'{_path_label(a['path'], quest)}' was taken"
    if a.get("fact"):
        return f"{a['fact']} {a.get('op') or '>='} {a.get('value', 1)}"
    return ""


def _meanwhile_exits(a, quest):
    return [Exit("meanwhile", _to(a.get("path"), "path"), "lane", set=_setter(a, "path", "path"))]


def _path_label(pid, quest):
    return ((quest.get("paths") or {}).get(pid) or {}).get("label") or pid or ""


KINDS = {
    "talk": Kind("people", _first("npc"), _talk_exits),
    "deliver": Kind("people", _first("npc")),
    "follow": Kind("people", _first("who")),
    "goto": Kind("place", lambda a, q: _first("who")(a, q) if a.get("mode") in ("near", "look") else
                 "a spot" if a.get("pos") or a.get("at") else ""),
    "wait": Kind("time", lambda a, q: str(a.get("time") or "")),
    "waitfact": Kind("time", lambda a, q: _if_subject(a, q) if a.get("conditions") else _first("fact")(a, q)),
    "waitfor": Kind("time", lambda a, q: {"combat": "a fight", "peace": "the fight over", "senses": "witcher senses",
                                          "health": f"health {a.get('percent', 30)} %"}.get(a.get("what") or "senses",
                                                                                         "")),
    "loot": Kind("things", _first("object")),
    "examine": Kind("things", _first("object")),
    "use": Kind("things", _first("object")),
    "collect": Kind("things", _first("item")),
    "equip": Kind("things", _first("item")),
    "read": Kind("things", _first("item")),
    "notice": Kind("things", lambda a, q: str(a.get("title") or "")),
    "clues": Kind("things", lambda a, q: _count(a.get("clues"), "clue")),
    "kill": Kind("fight", _first("targets", "target")),
    "defeat": Kind("fight", _first("target")),
    "fistfight": Kind("fight", _first("targets"), _lost_exits),
    "race": Kind("fight", _first("racers")),
    "gwent": Kind("fight", _first("deck"), _lost_exits),
    "all": Kind("choice", lambda a, q: _count(a.get("options"), "goal")),
    "either": Kind("choice", lambda a, q: _count(a.get("options") or a.get("ways"), "way"), _either_exits),
    "random": Kind("choice", lambda a, q: _count(a.get("ways"), "way"), _random_exits, lambda a, q: ""),
    "if": Kind("choice", None, _if_exits, _if_subject),
    "meanwhile": Kind("lane", None, _meanwhile_exits, lambda a, q: _path_label(a.get("path"), q)),
    "stop": Kind("lane", None, None, lambda a, q: _path_label(a.get("path"), q)),
    "chapter": Kind("story"),
    "portal": Kind("action", _first("a")),
}


def kind(k):
    return KINDS.get(k) or Kind("action" if block_of(k) == "action" else "story")


def action_text(k, a, quest):
    """What an action does, in a few words (the node's line under its title)."""
    if k == "say":
        return a.get("text") or "..."
    if k == "reward":
        parts = [f"{a['money']} crowns" if a.get("money") else "", f"{a['xp']} XP" if a.get("xp") else "",
                 _count(a.get("items"), "item") if a.get("items") else ""]
        return ", ".join(p for p in parts if p)
    if k in ("note", "message", "tutorial"):
        return a.get("text") or ""
    if k == "playas":
        if not a.get("as"):
            return ""
        from .dialogue import PLAYERS
        who = (PLAYERS.get(a.get("as")) or {}).get("label") or a.get("as")
        look = dict(QB.CIRI_LOOKS).get(a.get("look") or "", "") if a.get("as") == "ciri" else ""
        return who + (f", {look}" if look else "")
    if k == "fact":
        return f"{a.get('name') or '?'} = {a.get('value', 1)}"
    return _first("who", "target", "object", "item", "place", "function", "weather", "at")(a, quest)


def build(quest, names=None):
    """The quest's graph: nodes, columns, wires (not placed yet - graph_layout). names: people's shown names."""
    from .quest import default_text
    g = Graph()
    paths = quest.get("paths") or {}
    columns = g.columns

    def step_node(steps, i, colour, prefix, number):
        k, a = QB.step_kind(steps[i])
        spec = kind(k)
        b = block_of(k)
        nid = f"{prefix}{id(steps[i])}"
        common = dict(block=b, lane=colour, path=prefix[:-1], card=(steps, i), insert=(steps, i + 1))
        if k in PLACEHOLDERS:
            return Node(nid, k, LABEL[k].upper(), missing=["what it does"],
                        colour=FAMILY["open"], **common)
        if k == "chapter":
            return Node(nid, "chapter", "CHAPTER", text=a.get("title") or "Chapter", colour=FAMILY["story"],
                        **common)
        if k == "end":
            fail = a.get("how") == "fail"
            return Node(nid, "end", "QUEST ENDS: FAILED" if fail else "QUEST ENDS: SUCCESS",
                        colour=FAIL if fail else SUCCESS, goes_on=False, **common)
        exits = spec.exits(a, quest) if spec.exits else []
        if spec.text:
            text = a.get("text") or spec.text(a, quest)
        elif b == "goal" or k == "either":
            text = a.get("text") or default_text(k, a, quest.get("items"), names)
        else:
            text = action_text(k, a, quest)
        # on down: when some way leads on (or there are no ways, or only a lane beside)
        goes_on = not exits or any(e.to == "next" for e in exits) or all(e.style == "lane" for e in exits)
        title = (LABEL.get(k) or QB.LABEL.get(k, k)).upper()
        if k == "talk" and _hands_over(a):
            title = "DELIVER"                           # a talk that takes an item: what it was dropped as
        return Node(nid, k, title, subject=spec.subject(a, quest) if spec.subject else "",
                    text=text, missing=QB.missing(k, a), exits=exits, colour=FAMILY[spec.family],
                    number=number, goes_on=goes_on, **common)

    def column(steps, colour, then, head, prefix=""):
        col = Column([], then, colour, steps)
        col.nodes.append(g.add(head))
        number = 0
        for i, st in enumerate(steps):
            k, _a = QB.step_kind(st)
            counted = (block_of(k) == "goal" or k == "either") and k not in PLACEHOLDERS
            number += counted
            n = step_node(steps, i, colour, prefix, number if counted else 0)
            col.nodes.append(g.add(n))
            if k == "chapter":
                g.chapters.append(n.id)
        last = g.nodes[col.nodes[-1]]
        end = {"join": None, "lane": ("runs_out", "RUNS OUT", MUTED), "done": ("done", "QUEST DONE", SUCCESS),
               "success": ("success", "QUEST ENDS: SUCCESS", SUCCESS),
               "fail": ("fail", "QUEST ENDS: FAILED", FAIL)}[then]
        if end and last.kind != "end":              # (a column that ends in an End block needs no end of its own)
            col.nodes.append(g.add(Node(f"{prefix}{id(steps)}.end", end[0], end[1], colour=end[2], lane=colour,
                                        path=prefix[:-1], insert=(steps, len(steps)))))
        for i, nid in enumerate(col.nodes):
            for k, ex in enumerate(g.nodes[nid].exits):
                sub = reach(ex, nid)
                if sub is not None:
                    col.forks.setdefault(nid, []).append((k, sub))
                    if sub.parent is None:
                        sub.parent = (col, i)
        return col

    def reach(ex, src):
        # a way that fails the quest ends right at its exit (a small mark there, no wire - graph_view)
        if not ex.to.startswith("path:"):
            return None
        pid = ex.to[5:]
        if pid not in paths:
            return None
        if pid in columns:
            return columns[pid]                     # reached again: one more wire into it (None while built)
        columns[pid] = None                         # being built: a path that leads to itself stops here
        p = paths[pid]
        lane = ex.style == "lane"
        colour = FAMILY["lane"] if lane else QB.path_color(pid)     # lanes: the colour of Meanwhile
        steps = p.setdefault("steps", [])
        head = Node(f"path.{pid}", "path", "LANE" if lane else "PATH", text=p.get("label") or pid,
                    colour=colour, lane=colour, path=pid, card=(steps, None), insert=(steps, 0))
        columns[pid] = column(steps, colour, "lane" if lane else (p.get("then") or "join"), head, prefix=f"{pid}:")
        return columns[pid]

    steps = quest.get("steps") if quest.get("steps") is not None else []
    start = Node("start", "start", "QUEST STARTS", text=quest.get("title") or "", colour=MUTED,
                 card=(steps, None), insert=(steps, 0))
    g.main = column(steps, "", "done", start)
    # paths nothing leads to (yet): beside the story, so they are not lost
    for pid in paths:
        if pid not in columns:
            sub = reach(Exit("", "path:" + pid), "loose")
            if sub is not None:
                g.nodes[sub.nodes[0]].missing = ["nothing leads here yet"]
                g.loose.append(sub)
    _wire(g)
    return g


def _after(col, i):
    """The node the story goes on with after node i of a column: the next one, or where the column goes."""
    if i + 1 < len(col.nodes):
        return col.nodes[i + 1]
    if col.then == "join" and col.parent is not None:
        return _after(*col.parent)
    return None


def _wire(g):
    seen = set()

    def walk(col):
        if id(col) in seen:
            return
        seen.add(id(col))
        for i, nid in enumerate(col.nodes):
            n = g.nodes[nid]
            nxt = _after(col, i)
            if nxt is not None and n.goes_on:
                inside = i + 1 < len(col.nodes)
                g.wires.append(Wire(nid, nxt, "next", "top", "next" if inside else "join", col.colour,
                                    insert=n.insert))
            for k, sub in col.forks.get(nid, []):
                ex = n.exits[k]
                head = g.nodes[sub.nodes[0]]
                g.wires.append(Wire(nid, sub.nodes[0], k, "left", ex.style, sub.colour or FAIL,
                                    insert=head.insert))
                walk(sub)

    walk(g.main)
    for sub in g.loose:
        walk(sub)


# --- the quest as a graph of its own (quest_nodes): nodes where they stand, wires where they were drawn
class Slot(list):
    """A node's step as a list of one: the cards edit a step at (list, index) - putting another step there (another
    kind) puts it into the node."""

    def __init__(self, quest, nid):
        super().__init__([quest["nodes"][nid]["step"]])
        self.quest, self.nid = quest, nid

    def __setitem__(self, i, value):
        super().__setitem__(i, value)
        self.quest["nodes"][self.nid]["step"] = value


PORT_COLOUR = {"fail": FAIL, "Failure": FAIL, "left": FAIL, "retry": "#e3c65f"}


def look(step, quest, names=None):
    """How a step's node looks: (kind, block, title, subject, text, missing, colour)."""
    from .quest import default_text
    k, a = QB.step_kind(step)
    a = a or {}
    b = block_of(k)
    if k in PLACEHOLDERS:
        return k, b, LABEL[k].upper(), "", "", ["what it does"], FAMILY["open"]
    if k == "chapter":
        return k, "chapter", "CHAPTER", "", a.get("title") or "Chapter", [], FAMILY["story"]
    if k == "end":
        fail = a.get("how") == "fail"
        return k, "end", "QUEST ENDS: FAILED" if fail else "QUEST ENDS: SUCCESS", "", "", [], FAIL if fail else SUCCESS
    spec = kind(k)
    if spec.text:
        text = a.get("text") or spec.text(a, quest)
    elif b == "goal" or k == "either":
        text = a.get("text") or default_text(k, a, quest.get("items"), names)
    else:
        text = action_text(k, a, quest)
    title = (LABEL.get(k) or QB.LABEL.get(k, k)).upper()
    if k == "talk" and _hands_over(a):
        title = "DELIVER"
    return (k, b, title, spec.subject(a, quest) if spec.subject else "", text, QB.missing(k, a),
            FAMILY[spec.family])


def build_nodes(quest, names=None):
    """The quest's graph as it was drawn: a node per node (where it stands, its outputs - one at its bottom, or one
    per way at its right side), a wire per link. `Graph.free`: nodes are moved, wires drawn by hand."""
    from . import quest_nodes as QN
    g = Graph()
    g.free = True
    nodes, links = quest["nodes"], quest.get("links") or []
    wired = {(a, p) for a, p, _b in links}
    number = 0
    for nid in QN.order(quest):
        n = nodes[nid]
        step = n["step"]
        k0, _a0 = QN.step_kind(step)
        if k0 == "start":
            node = Node(nid, "start", "QUEST STARTS", text=quest.get("title") or "", colour=MUTED,
                        card=(Slot(quest, nid), None))
        elif k0 == "remember":
            label = QN.label_of(quest, n.get("remember") or "")
            node = Node(nid, "remember", "BRANCH TAKEN", text=label, block="", colour=FAMILY["story"],
                        card=(Slot(quest, nid), 0))
        else:
            k, b, title, subject, text, missing, colour = look(step, quest, names)
            counted = (b == "goal" or k == "either") and k not in PLACEHOLDERS
            number += counted
            node = Node(nid, k, title, block=b, subject=subject, text=text, missing=list(missing), colour=colour,
                        number=number if counted else 0, card=(Slot(quest, nid), 0))
        ps = QN.ports(step, quest)
        node.goes_on = ("next", "") in ps or any(p == "next" for p, _l in ps)
        node.exits = [Exit(label or p, p, "port") for p, label in ps if p != "next"]
        for e in node.exits:
            e.wired = (nid, e.to) in wired
        node.next_wired = (nid, "next") in wired
        if n.get("remember") and k0 != "remember":
            node.subject = (node.subject + "  " if node.subject else "") + "(remembered)"
        # ('later' and 'fails' need no wire: talk again, the quest fails)
        open_ = [e.label for e in node.exits if not e.wired and e.to not in ("retry", "fail")] + (
            ["output"] if node.goes_on and not node.next_wired and node.kind != "start" else [])
        if open_ and node.kind not in ("start",):
            node.missing.append(", ".join(open_) + " not wired")
        node.x, node.y = n.get("x", 0), n.get("y", 0)
        node.hidden = bool(n.get("hidden"))
        g.add(node)
        if k0 == "chapter":
            g.chapters.append(nid)
    for a, p, b in links:
        if a not in g.nodes or b not in g.nodes:
            continue
        src = g.nodes[a]
        port = "next" if p == "next" else next((i for i, e in enumerate(src.exits) if e.to == p), None)
        if port is None:
            continue
        w = Wire(a, b, port, "top", "next" if port == "next" else "branch", PORT_COLOUR.get(p, ""))
        w.link = [a, p, b]
        g.wires.append(w)
    return g
