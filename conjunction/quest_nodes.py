"""A quest as a graph of its own: nodes where they were put, wires where they were drawn (Maxim 30.09.: every node
has an input and outputs that are dragged, connected and removed; nothing hangs on anything by itself).

    quest:
      nodes:
        start: {step: {start: {}}, x: 0, y: 0}
        n1:    {step: {talk: {...}}, x: 0, y: 120}
        n2:    {step: {end: {how: fail}}, x: 400, y: 200}
      links:
        - [start, next, n1]                 # [from node, its output, to node]
        - [n1, fail, n2]

A node's step is the same dict a step always was (its card edits it). Its outputs (ports(step)): "next", or one per
way when the step can go more than one way - a talk's ends, an either's options, won / lost, yes / no ... An output
may lead to several nodes (they run side by side), an input may be reached from several outputs. An output leads
nowhere until it is wired (the quest waits there).

The older form (steps: a list; paths: lists a way leads into) becomes this once (migrate) - where it was drawn,
every way it went; a path's first node keeps its fact (`remember`), so what depends on the way taken still works.
"""
from . import dialogue as D

START = "start"


def safe(name):
    """A name as the game takes it in facts and block names: [a-zA-Z0-9_] (a path named after 'Ja natürlich ...')."""
    import re
    return re.sub(r"[^a-zA-Z0-9_]", "_", str(name))


def path_fact(qid, pid):
    """The fact that says a path was taken (If, 'Only after')."""
    return f"{qid}_path_{safe(pid)}"


def is_graph(q):
    return isinstance((q or {}).get("nodes"), dict)


def step_kind(step):
    return next(iter(step.items())) if isinstance(step, dict) and len(step) == 1 else ("", {})


def new_quest(title=""):
    """A new quest: its start and an end, not wired (Maxim: 'quest starts is wired to quest done and I cannot part
    them')."""
    return {"title": title, "type": "secondary", "description": "",
            "nodes": {START: {"step": {"start": {}}, "x": 0, "y": 0},
                      "done": {"step": {"end": {"how": "success"}}, "x": 0, "y": 360}},
            "links": []}


def _end_label(e, quest=None):
    e = str(e or "continue")
    if e.startswith("path:"):
        return label_of(quest, e[5:])
    if e.startswith("out:"):
        return e[4:].replace("_", " ")
    return {"continue": "continue", "retry": "repeatable", "fail": "fail"}.get(e, e)


def label_of(quest, pid):
    """The words of a named way (an older path's label, an output named after an answer)."""
    quest = quest or {}
    return (quest.get("outcomes") or {}).get(pid) or ((quest.get("paths") or {}).get(pid) or {}).get("label") \
        or str(pid).replace("_", " ")


REPEATABLE = ("goto", "waitfact", "wait", "talk")    # goals that can be 'every time' (quest.py: again)


def repeat_of(a):
    """A goal's 'every time': {} or {"until": fact | node, ...} when it repeats, None when not."""
    r = (a or {}).get("repeat")
    if isinstance(r, dict):
        return r
    return {} if r else None


def ports(step, quest=None):
    """[(output, label)] of a node's step - the outputs the build knows it by (quest.py: a step's branches); a goal
    'every time' has one more: what runs each time it is done (quest.py: again)."""
    kind, a = step_kind(step)
    a = a or {}
    if repeat_of(a) is not None and kind in REPEATABLE:
        return _ports(kind, a, quest) + [("__every", "every time")]
    return _ports(kind, a, quest)


def _ports(kind, a, quest):
    if kind == "end":
        return []
    if kind == "talk":
        ends = sorted(D.outcomes(D.from_step(a)))
        if len(ends) > 1:
            return [(D.socket(e), _end_label(e, quest)) for e in ends]
        return [("next", "")]
    if kind == "either" and "ways" in a and not a.get("options"):
        return [(f"way{k}", f"way {k}") for k, _w in enumerate(a.get("ways") or [], 1)] or [("next", "")]
    if kind == "either":
        out = []
        for k, o in enumerate(a.get("options") or [], 1):
            gk, ga = step_kind(o.get("goal") or {"goto": {}})
            out.append((f"o{k}", gk.replace("_", " ")))
        return out or [("next", "")]
    if kind == "random":
        return [(f"way{k}", f"outcome {k}") for k, _w in enumerate(a.get("ways") or [], 1)] or [("next", "")]
    if kind == "if":
        return [("yes", "yes"), ("no", "no")]
    if kind in ("fistfight", "gwent"):
        return [("Success", "won"), ("Failure", "lost")]
    if kind == "race":
        return [("won", "won"), ("lost", "lost")]
    if kind == "goto" and a.get("stay") and (a.get("pos") or a.get("at")):
        return [("arrived", "arrived"), ("left", "left")]
    if kind == "meanwhile":
        return [("next", ""), ("__lane", "meanwhile")]
    return [("next", "")]


def links_from(q, nid, port=None):
    return [ln for ln in q.get("links") or [] if ln[0] == nid and (port is None or ln[1] == port)]


def links_to(q, nid):
    return [ln for ln in q.get("links") or [] if ln[2] == nid]


def order(q):
    """The node ids in story order: from the start along each node's first wired output (the story), what the other
    outputs lead to after it (the ways off it, as the older form's paths came after the story), then those nothing
    leads to."""
    from collections import deque
    seen, out, queue = set(), [], deque([START])
    links = q.get("links") or []
    while queue:
        nid = queue.popleft()
        if nid in seen or nid not in q["nodes"]:
            continue
        seen.add(nid)
        out.append(nid)
        wired = [p for p, _l in ports(q["nodes"][nid]["step"], q) if any(ln[0] == nid and ln[1] == p for ln in links)]
        main = wired[0] if wired else None
        firsts = [ln[2] for ln in links if ln[0] == nid and ln[1] == main]
        rest = [ln[2] for ln in links if ln[0] == nid and ln[1] != main]
        queue.extendleft(reversed(firsts))              # the story goes on first
        queue.extend(rest)
    return out + [nid for nid in q["nodes"] if nid not in seen]


def new_id(q, base="n"):
    k = len(q["nodes"]) + 1
    while f"{base}{k}" in q["nodes"]:
        k += 1
    return f"{base}{k}"


# --- the older form becomes the graph
def migrate(q, layout=True):
    """A quest of step lists (steps, paths) as a graph: in place; returns it. Nodes where the old graph drew them
    (layout: for the editor - a build does not need where they stand)."""
    if is_graph(q):
        return q
    positions = _old_positions(q) if layout else {}
    paths = q.get("paths") or {}
    nodes, links = {START: {"step": {"start": {}}, "x": 0, "y": 0}}, []
    firsts = {}                                         # path id -> the node its way goes into
    ends = {}                                           # success / fail -> an End node (made when needed)
    pos = positions.get("start")
    if pos:
        nodes[START]["x"], nodes[START]["y"] = pos
    right = max([p[0] for p in positions.values()] + [0]) + 340
    counter = [0]

    def node(step, where=None, nid=None):
        if nid is None:                                 # steps: n1, n2 ... in the order of the older form's numbers
            counter[0] += 1
            nid = f"n{counter[0]}"
        x, y = positions.get(id(step), where or (right, 60 * counter[0]))
        nodes[nid] = {"step": step, "x": x, "y": y}
        return nid

    def end_node(how):
        if how not in ends:
            where = positions.get(f"end:{how}") or (right, 40 + 90 * len(ends))
            ends[how] = node({"end": {"how": how}}, where, "done" if how == "success" else "failed")
        return ends[how]

    def target(then, after, me):
        """The node a way leads to: `after` (on), the step itself (again), a path's first, an end."""
        then = str(then or "continue")
        if then == "continue":
            return after()
        if then == "retry":
            return me
        if then in ("fail", "success"):
            return end_node(then)
        if then.startswith("path:"):
            return path_first(then[5:], after)
        return after()

    def path_first(pid, after, remember=True):
        if pid in firsts:
            return firsts[pid]
        p = paths.get(pid)
        if p is None:
            return None
        firsts[pid] = None                              # being made (a path that leads to itself)
        then = p.get("then") or "join"
        steps = p.get("steps") or []
        if then == "lane":
            tail = lambda: None                         # noqa: E731 - a lane runs out
        elif then in ("success", "fail"):
            tail = lambda: end_node(then)               # noqa: E731
        else:
            tail = after
        first = column(steps, tail)
        if first is None or first in firsts.values() or first in ends.values():
            # no step of its own (or it leads straight on): a node that only remembers the way was taken
            head = node({"remember": {}}, positions.get(f"path:{pid}"), f"way_{pid}")
            if first is not None:
                links.append([head, "next", first])
            first = head
        if remember:                                    # (a lane beside the story is no decision)
            nodes[first]["remember"] = pid
        firsts[pid] = first
        return first

    def column(steps, tail):
        """The nodes of a list, wired in order; the last goes to tail(). Returns the first node (or tail's)."""
        ids = [node(st) for st in steps]
        for k, (st, nid) in enumerate(zip(steps, ids)):
            nxt = (lambda k=k: ids[k + 1]) if k + 1 < len(ids) else tail
            wire(st, nid, nxt)
        return ids[0] if ids else tail()

    def wire(st, nid, nxt):
        kind, a = step_kind(st)
        a = a or {}
        outs = []                                       # (port, then)
        if kind == "end":
            return
        if kind == "talk":
            ends_ = sorted(D.outcomes(D.from_step(a)))
            outs = [(D.socket(e) if len(ends_) > 1 else "next", e) for e in ends_]
        elif kind == "either":
            outs = [(f"o{k}", f"path:{o['path']}" if o.get("path") else "continue")
                    for k, o in enumerate(a.get("options") or [], 1)]
        elif kind == "random":
            outs = [(f"way{k}", f"path:{w['path']}" if w.get("path") else "continue")
                    for k, w in enumerate(a.get("ways") or [], 1)]
        elif kind == "if":
            outs = [("yes", a.get("yes") or "continue"), ("no", a.get("no") or "continue")]
        elif kind in ("fistfight", "gwent"):
            outs = [("Success", "continue"), ("Failure", a.get("lost") or "continue")]
        elif kind == "goto" and a.get("stay") and (a.get("pos") or a.get("at")):
            outs = [("arrived", "continue"), ("left", "fail")]
        elif kind == "meanwhile":
            outs = [("next", "continue")]
            if a.get("path"):
                lane = path_first(a["path"], lambda: None, remember=False)
                if lane is not None:
                    links.append([nid, "__lane", lane])
        else:
            outs = [("next", "continue")]
        for port, then in outs or [("next", "continue")]:
            to = target(then, nxt, nid)
            if to is not None:
                links.append([nid, port, to])

    first = column(list(q.get("steps") or []), lambda: end_node("success"))
    links.append([START, "next", first])
    for pid in paths:                                   # paths nothing led to: loose, still there
        path_first(pid, lambda: None)
    # (the older form's fields go: the graph is the quest now)
    q.pop("steps", None)
    if paths:                                           # their names stay: the outputs they were are named so
        q["outcomes"] = dict({pid: p.get("label") or pid for pid, p in paths.items()}, **(q.get("outcomes") or {}))
    q.pop("paths", None)
    q["nodes"], q["links"] = nodes, _unique(links)
    for st_ref in (s for n in nodes.values() for s in [n["step"]]):
        _drop_routing(st_ref)
    return q


def _unique(links):
    out = []
    for ln in links:
        if ln not in out:
            out.append(ln)
    return out


def _drop_routing(step):
    """Where a way led is the wires' now: the step's own fields for it go (a talk's answers keep their end - it says
    which output they leave by)."""
    kind, a = step_kind(step)
    if not isinstance(a, dict):
        return
    if kind in ("either",):
        for o in a.get("options") or []:
            o.pop("path", None)
    elif kind == "random":
        for w in a.get("ways") or []:
            w.pop("path", None)
    elif kind == "if":
        a.pop("yes", None)
        a.pop("no", None)
    elif kind in ("fistfight", "gwent"):
        a.pop("lost", None)


def _old_positions(q):
    """{id(step dict) / 'start' / 'end:success' / 'end:fail' / 'path:<id>': (x, y)} where the old graph drew them."""
    import copy
    from . import graph_layout as L
    from . import quest_graph as QG
    out = {}
    try:
        g = QG.build(q)
        L.place(g)
    except Exception:                                   # noqa: BLE001 - positions are a nicety
        return out
    for n in g.nodes.values():
        if n.kind == "start":
            out["start"] = (n.x, n.y)
        elif n.kind in ("done", "success"):
            out.setdefault("end:success", (n.x, n.y))
        elif n.kind == "fail":
            out.setdefault("end:fail", (n.x, n.y))
        elif n.kind == "path" and n.path:
            out[f"path:{n.path}"] = (n.x, n.y)
        elif n.card is not None and n.card[1] is not None:
            out[id(n.card[0][n.card[1]])] = (n.x, n.y)
    _ = copy
    return out
