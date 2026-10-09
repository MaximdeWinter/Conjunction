"""A game quest graph as the editor shows it (docs/VANILLA_EDITING_PLAN.md, step 2): read from the lossless tree
(cr2w_tree), each block with what it does in a line or three, its named inputs and outputs, its links - and where
it stands, laid out left to right (the game's cooked files keep no positions: CQuestGraph.sourceDataRemoved).

    qf = QuestFile(depot, path)         a .w2phase / .w2quest: its tree, its main graph (qf.root)
    g = qf.graph(n)                     the graph object n -> Graph: blocks {n: Block}, links
    place(g)                            x, y, w, h of every block; g.wires: the ways the links run

A Block: n (its object number), cls, name, family (its colour), title, lines (what it does), inputs, outputs (socket
names in order), opens (a phase: ("graph", n) inside this file or ("file", path)). A link: (from n, output, to n,
input). Socket names are the file's; a block's single unnamed socket shows as "".
"""
import math
import os

from .cr2w_tree import Guid, Loc, Raw, Soft, Struct, Tags, Transform, Tree, Variant

FAMILY = {
    "flow": "#7d8fa8", "wait": "#d9a441", "if": "#e0b85a", "facts": "#5cb85c", "scene": "#a779d9",
    "journal": "#4fb3bf", "script": "#e08a4f", "world": "#6f9bd1", "note": "#8c8c70",
    # the groups of blocks.py (the kinds the graph shows)
    "check": "#e0b85a", "talk": "#a779d9", "people": "#e08a4f", "fx": "#c97fb0", "items": "#c9b458",
    "notes": "#8c8c70", "game": "#6a6a74",
    "template": "#9b8cff",                              # a template's block the translator shows (translator.py)
}
CLASS_FAMILY = {
    "CQuestPhaseInputBlock": "flow", "CQuestPhaseOutputBlock": "flow", "CQuestStartBlock": "flow",
    "CQuestEndBlock": "flow", "CQuestAndBlock": "flow", "CQuestXorBlock": "flow", "CQuestRandomBlock": "flow",
    "CQuestCheckpointBlock": "flow", "CQuestPhaseBlock": "flow", "CQuestCutControlBlock": "flow",
    "CQuestPauseConditionBlock": "wait", "CQuestConditionBlock": "if", "CQuestFactsDBChangingBlock": "facts",
    "CQuestSceneBlock": "scene", "CQuestInteractionDialogBlock": "scene", "CQuestContextDialogBlock": "scene",
    "CQuestScenePrepareBlock": "scene", "CQuestScriptBlock": "script", "CQuestScriptedActionsBlock": "script",
    "CQuestPokeScriptedActionsBlock": "script", "CQuestResetScriptedActionsBlock": "script",
    "CQuestRiderScriptedActionsBlock": "script", "CQuestPlayAnimationBlock": "script",
    "CQuestLookAtBlock": "script", "CCommentGraphBlock": "note", "CDescriptionGraphBlock": "note",
}
NAMES = {"CQuestPhaseInputBlock": "Input", "CQuestPhaseOutputBlock": "Output", "CQuestStartBlock": "Start",
         "CQuestEndBlock": "End", "CQuestAndBlock": "All of", "CQuestXorBlock": "First of",
         "CQuestRandomBlock": "Random", "CQuestCheckpointBlock": "Checkpoint", "CQuestPhaseBlock": "Phase",
         "CQuestPauseConditionBlock": "Wait", "CQuestConditionBlock": "If", "CQuestFactsDBChangingBlock": "Fact",
         "CQuestSceneBlock": "Scene", "CQuestInteractionDialogBlock": "Talk", "CQuestScriptBlock": "Script",
         "CJournalQuestBlock": "Journal", "CJournalQuestMappinStateBlock": "Map pin",
         "CQuestCutControlBlock": "Cut control", "CCommentGraphBlock": "Comment",
         "CDescriptionGraphBlock": "Description", "CQuestStoryPhaseSetterBlock": "Spawn sets",
         "CQuestLayersHiderBlock": "Layers", "CQuestTeleportBlock": "Teleport", "CQuestRewardBlock": "Reward",
         "CQuestTimeManagementBlock": "Time", "CQuestScriptedActionsBlock": "AI actions",
         "CQuestDeletionMarkerBlock": "Deleted", "CQuestEncounterManagerBlock": "Encounters"}
# what a block's lines leave out (shown in the properties)
QUIET = {"guid", "cachedConnections", "name", "comment", "caption", "embeddedGraph", "phase", "size"}


def short(cls):
    for p in ("CQuest", "CJournal", "CStoryScene", "W3QuestCond_", "CQC", "C"):
        if cls.startswith(p) and len(cls) > len(p):
            cls = cls[len(p):]
            break
    return cls.replace("Block", "").replace("Condition", "")


def family_of(cls):
    if cls in CLASS_FAMILY:
        return CLASS_FAMILY[cls]
    if cls.startswith("CJournal"):
        return "journal"
    return "world"


class QuestFile:
    def __init__(self, depot, path, data=None):
        self.depot, self.path = depot, path
        self.tree = Tree(data if data is not None else depot.read(path))
        top = self.tree.obj(1)
        g = top.get("graph")
        self.root = g if isinstance(g, int) and g > 0 else next(
            k for k, o in enumerate(self.tree.objects, 1) if o.cls == "CQuestGraph")
        self._graphs = {}

    # --- values as text
    def import_path(self, h):
        """A handle's import (-n) or a soft handle's (Soft(n)) -> its path."""
        k = -h if not isinstance(h, Soft) else h
        imps = self.tree.f.imports
        return imps[k - 1][0] if 0 < k <= len(imps) else None

    def text(self, v, typ="", depth=0):
        """A value, short: objects under a handle followed (conditions), imports by file name."""
        if isinstance(v, Raw):
            return f"<{len(v)} bytes>"
        if isinstance(v, Soft):
            p = self.import_path(v)
            return os.path.basename(p) if p else "none"
        if typ.startswith(("handle:", "ptr:", "#")) and isinstance(v, int):
            if v < 0:
                p = self.import_path(v)
                return os.path.basename(p) if p else "?"
            if v == 0:
                return "none"
            if depth > 2:
                return short(self.tree.obj(v).cls)
            return self.object_text(v, depth + 1)
        if isinstance(v, Guid):
            return v.hex()[:8]
        if isinstance(v, Loc):
            return f"text {int(v)}"
        if isinstance(v, Tags):
            return ", ".join(v) or "no tags"
        if isinstance(v, Variant):
            return self.text(v.value, v.type, depth)
        if isinstance(v, Transform):
            return " ".join(f"{k}=({', '.join(f'{x:g}' for x in part)})"
                            for k, part in (("at", v.position), ("rot", v.rotation), ("scale", v.scale)) if part)
        if isinstance(v, Struct):
            return "{" + ", ".join(f"{p.name}={self.text(p.value, p.type, depth)}" for p in v
                                   if p.value not in ("", None, [])) + "}"
        if isinstance(v, list):
            inner = typ.split(",", 2)[2] if typ.startswith("array:") else ""
            items = [self.text(x, inner, depth) for x in v[:6]]
            return "[" + ", ".join(items) + (" ..." if len(v) > 6 else "") + "]"
        if isinstance(v, float):
            return f"{v:g}"
        if isinstance(v, bool):
            return "yes" if v else "no"
        return str(v)

    def object_text(self, n, depth=0):
        """An object under a handle (a condition, an AI action ...): Class(prop=value, ...)."""
        o = self.tree.obj(n)
        if o.cls == "CQuestFactsDBCondition":
            return fact_test(o)
        if o.cls == "CQuestLogicOperationCondition":
            op = " and " if o.get("logicOperation", "LO_And") in ("LO_And",) else " or "
            return "(" + op.join(self.text(c, "handle:x", depth) for c in o.get("conditions") or [] if c) + ")"
        parts = [f"{p.name}={self.text(p.value, p.type, depth)}" for p in o.props or []
                 if p.name not in QUIET and p.value not in ("", None, [], 0)]
        return f"{short(o.cls)}({', '.join(parts)})" if parts else short(o.cls)

    # --- graphs
    def graph(self, n=None):
        n = n or self.root
        if n not in self._graphs:
            self._graphs[n] = Graph(self, n)
        return self._graphs[n]


def fact_test(o):
    fact = o.get("factId") or "?"
    cmp = {"CF_Equal": "=", "CF_NotEqual": "!=", "CF_Less": "<", "CF_LessEqual": "<=", "CF_Greater": ">",
           "CF_GreaterEqual": ">="}.get(o.get("compareFunc"), "?")
    value = o.get("value", 0)
    if o.get("queryFact") in ("QF_DoesExist", None) and cmp == ">=" and value == 1:
        return f"{fact}"
    return f"{fact} {cmp} {value}"


class Block:
    def __init__(self, n, cls):
        self.n, self.cls = n, cls
        self.name, self.title, self.lines = "", "", []
        self.inputs, self.outputs, self.opens = [], [], None
        self.family = family_of(cls)
        self.x = self.y = self.w = self.h = 0
        self.comment = ""


class Graph:
    def __init__(self, qf, n):
        self.qf, self.n = qf, n
        t = qf.tree
        self.blocks, self.links = {}, []
        for b in t.obj(n).get("graphBlocks") or []:
            if isinstance(b, int) and b > 0:
                self.blocks[b] = self._block(b)
        for b in self.blocks.values():                  # the sockets its class has, then any others it uses
            ins, outs = sockets(b.cls)
            b.inputs = [s.strip() for s in ins]
            b.outputs = [s.strip() for s in outs]
        for b in self.blocks.values():
            o = t.obj(b.n)
            for c in o.get("cachedConnections") or []:
                sock = c.get("socketId") or ""
                if sock.strip() == "":
                    sock = ""
                if sock not in b.outputs:
                    b.outputs.append(sock)
                for d in c.get("blocks") or []:
                    to, put = d.get("ock"), d.get("putName") or ""
                    if isinstance(to, int) and to in self.blocks:
                        put = "" if put.strip() == "" else put
                        self.links.append((b.n, sock, to, put))
                        if put not in self.blocks[to].inputs:
                            self.blocks[to].inputs.append(put)
        for b in self.blocks.values():                  # the sockets a block has by its kind
            for s in self._sockets_in(b):
                if s not in b.inputs:
                    b.inputs.append(s)
            for s in self._sockets_out(b):
                if s not in b.outputs:
                    b.outputs.append(s)
            # "Cut" (where a 'Stop branches' block stops it) only where something is wired into it: a wire from a
            # Thunder output dropped onto the block goes there (vanilla_view)
            b.inputs = [s for s in b.inputs if s != "Cut" or "Cut" in self._sockets_in(b)
                        or any(link[2] == b.n and link[3] == "Cut" for link in self.links)]
        from .blocks import objective_label
        ins = {}
        for a, sk, to, put in self.links:
            ins.setdefault(to, set()).add(put)
        for b in self.blocks.values():                  # an objective says what it does: show, done, failed
            if getattr(b, "kind", None) is not None and b.kind.id == "objective":
                b.title = objective_label(ins.get(b.n))
        self.wires = []

    def _sockets_in(self, b):
        if b.cls == "CQuestPhaseBlock" and b.opens and b.opens[0] == "graph":
            sub = self.qf.graph(b.opens[1])                # (its unnamed input is the phase's "In")
            return [x.name or "In" for x in sub.blocks.values() if x.cls == "CQuestPhaseInputBlock"]
        return []

    def _sockets_out(self, b):
        if b.cls == "CQuestConditionBlock":
            return ["True", "False"]
        if b.cls == "CQuestPhaseBlock" and b.opens and b.opens[0] == "graph":
            sub = self.qf.graph(b.opens[1])
            return [x.name or "Out" for x in sub.blocks.values() if x.cls == "CQuestPhaseOutputBlock"]
        return []

    def _block(self, n):
        qf = self.qf
        o = qf.tree.obj(n)
        b = Block(n, o.cls)
        b.name = (o.get("name") or "").strip()
        b.comment = (o.get("comment") or "").strip()
        if o.cls in ("CQuestPhaseInputBlock", "CQuestPhaseOutputBlock"):
            b.name = (o.get("socketID") or b.name or "").strip()
        from . import blocks
        b.kind = kind = blocks.kind_of(qf.tree, n)
        b.family = kind.group
        label = kind.label
        if kind is blocks.GAME_SCRIPT:
            from .game_catalog import label as fn_label
            label = fn_label(str(o.get("functionName") or "")) or label
        b.title = label
        lines = blocks.summary(qf, n, kind)
        b.lines = lines if lines is not None else self._lines(o)
        if o.cls == "CQuestPhaseBlock":
            emb, ph = o.get("embeddedGraph"), o.get("phase")
            if isinstance(emb, int) and emb > 0:
                b.opens = ("graph", emb)
            elif isinstance(ph, int) and ph < 0 or isinstance(ph, Soft) and ph:
                b.opens = ("file", qf.import_path(ph))
        return b

    def _lines(self, o):
        qf, c = self.qf, o.cls
        if c in ("CQuestPhaseInputBlock", "CQuestPhaseOutputBlock"):
            return [o.get("socketID") or "(the phase's own)"]
        if c == "CQuestFactsDBChangingBlock":
            return [f"{o.get('factID')} {'+' if (o.get('value', 1) or 0) >= 0 else ''}{o.get('value', 1)}"]
        if c == "CQuestPauseConditionBlock":
            return [qf.text(x, "handle:x") for x in o.get("conditions") or [] if x][:3] or ["(nothing)"]
        if c == "CQuestConditionBlock":
            return [qf.text(o.get("questCondition"), "handle:x")]
        if c in ("CQuestSceneBlock", "CQuestInteractionDialogBlock", "CQuestContextDialogBlock"):
            s = o.get("scene") or o.get("targetScene")
            return [qf.text(s) if isinstance(s, Soft) else str(s)]
        if c == "CQuestScriptBlock":
            args = ", ".join(f"{p.get('name')}={qf.text(p.get('value'))}" for p in o.get("parameters") or [])
            return [f"{o.get('functionName')}({args})"]
        if c == "CQuestPhaseBlock":
            ph = o.get("phase")
            if isinstance(ph, int) and ph < 0 or isinstance(ph, Soft) and ph:
                return [os.path.basename(qf.import_path(ph) or "")]
            emb = o.get("embeddedGraph")
            return [f"inside, {len(qf.tree.obj(emb).get('graphBlocks') or [])} blocks"] if emb else []
        if c in ("CJournalQuestBlock", "CJournalQuestMappinStateBlock", "CJournalBlock"):
            entry = o.get("questEntry") or o.get("mappinEntry") or o.get("entry")
            return [self.journal_text(entry)] + ([str(o.get("enableMapPin"))] if False else [])
        if c in ("CCommentGraphBlock", "CDescriptionGraphBlock"):
            text = (o.get("descriptionText") or o.get("comment") or "").strip()
            cap = (o.get("caption") or "").strip()
            return [x for x in (cap, text) if x]
        parts = [f"{p.name}={qf.text(p.value, p.type)}" for p in o.props or []
                 if p.name not in QUIET and p.value not in ("", None, [], 0)]
        return parts[:3]

    def journal_text(self, h):
        """A journal path (an object chain resource -> child ...) -> its deepest file and entry."""
        t = self.qf.tree
        if not (isinstance(h, int) and h > 0):
            return "none"
        o = t.obj(h)
        names = []
        while o is not None and o.cls == "CJournalPath":
            res = o.get("resource")
            if isinstance(res, Soft) and res:
                names.append(os.path.basename(self.qf.import_path(res) or "").replace(".journal", ""))
            child = o.get("child")
            o = t.obj(child) if isinstance(child, int) and child > 0 else None
        return " / ".join(names[-2:]) or "journal"


# each class's sockets, as the game's graphs use them (measured over all 1041 files: _scratch/socket_survey.py)
SOCKETS = {
    "CQuestPhaseInputBlock": ([], [" "]), "CQuestStartBlock": ([], [" "]),
    "CQuestPhaseOutputBlock": ([" "], []), "CQuestEndBlock": ([" "], []),
    "CQuestPauseConditionBlock": (["In", "Cut"], [""]), "CQuestConditionBlock": (["In"], ["True", "False"]),
    "CQuestAndBlock": (["In 0", "In 1"], ["Out"]), "CQuestXorBlock": (["In 0", "In 1"], ["Out"]),
    "CQuestRandomBlock": (["In"], ["Random 1", "Random 2"]), "CQuestCutControlBlock": (["In"], ["Out", "Thunder"]),
    "CQuestSceneBlock": (["Input", "Cut"], ["Output"]), "CQuestInteractionDialogBlock": (["Input", "Cut"], ["Output"]),
    "CJournalQuestBlock": (["Activate", "Success", "Failure", "Deactivate"], ["Out"]),
    "CQuestPhaseBlock": (["In", "Cut"], ["Out"]), "CQuestScriptBlock": (["In", "Cut"], ["Out"]),
    "CCommentGraphBlock": ([], []), "CDescriptionGraphBlock": ([], []),
}
DEFAULT_SOCKETS = (["In"], ["Out"])


def sockets(cls):
    return SOCKETS.get(cls, DEFAULT_SOCKETS)


# --- where the blocks stand: layers left to right along the links
NODE_W, HEAD, LINE, ROW, PAD = 240, 22, 15, 17, 6
GAP_X, GAP_Y = 90, 18
CHARS = 38


def shows_name(b):
    """Has the block a name line? (a phase's input / output: its name is its socket, its line already)"""
    return bool(b.name) and b.cls not in ("CQuestPhaseInputBlock", "CQuestPhaseOutputBlock")


def text_rows(b):
    """The rows of text under a block's title: its name (the designer's words for it), then what it does."""
    return (1 if shows_name(b) else 0) + min(len(b.lines), 3 if b.family not in ("note", "notes") else 8)


def size(b):
    rows = max(len(b.inputs), len(b.outputs), 0)
    return NODE_W, HEAD + text_rows(b) * LINE + rows * ROW + PAD


def place(g):
    blocks = g.blocks
    succ = {n: [] for n in blocks}
    pred = {n: [] for n in blocks}
    for a, _s, b, _p in g.links:
        if a != b:
            succ[a].append(b)
    # back links (a loop) left out of the layering: depth-first from the inputs, then from the rest
    order = sorted(blocks, key=lambda n: (blocks[n].cls not in ("CQuestPhaseInputBlock", "CQuestStartBlock"), n))
    state, back = {}, set()

    def dfs(start):
        stack = [(start, iter(succ[start]))]
        state[start] = 1
        while stack:
            n, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                state[n] = 2
                stack.pop()
            elif state.get(nxt) == 1:
                back.add((n, nxt))
            elif nxt not in state:
                state[nxt] = 1
                stack.append((nxt, iter(succ[nxt])))
    for n in order:
        if n not in state:
            dfs(n)
    for a in blocks:
        for b in succ[a]:
            if (a, b) not in back:
                pred[b].append(a)
    layer = {}

    def depth(n, seen=()):
        if n in layer:
            return layer[n]
        layer[n] = 0                                    # (guards a loop the back links missed)
        layer[n] = max((depth(p) + 1 for p in pred[n]), default=0)
        return layer[n]
    notes = [n for n in blocks if blocks[n].family in ("note", "notes") and not pred[n] and not succ[n]]
    for n in blocks:
        if n not in notes:
            depth(n)
    cols = {}
    for n, k in layer.items():
        cols.setdefault(k, []).append(n)
    for k in cols:
        cols[k].sort()
    for b in blocks.values():
        b.w, b.h = size(b)
    # order inside a column: by the mean place of what leads to it (a few sweeps), then stacked near that place
    pos = {n: i for k in cols for i, n in enumerate(cols[k])}
    for _sweep in range(4):
        for k in sorted(cols)[1:]:
            def key(n):
                ps = [pos[p] for p in pred[n] if p in pos]
                return sum(ps) / len(ps) if ps else pos[n]
            cols[k].sort(key=key)
            for i, n in enumerate(cols[k]):
                pos[n] = i
    y_of = {}
    top = 0
    if notes:                                           # the notes above the graph, in a row
        x = 0
        for n in sorted(notes):
            b = blocks[n]
            b.x, b.y = x, 0
            x += b.w + GAP_Y
            top = max(top, b.h + GAP_Y * 2)
    for k in sorted(cols):
        y = top
        for n in cols[k]:
            b = blocks[n]
            ps = [y_of[p] for p in pred[n] if p in y_of]
            want = sum(ps) / len(ps) if ps else y
            b.y = max(y, int(want))
            b.x = k * (NODE_W + GAP_X)
            y_of[n] = b.y
            y = b.y + b.h + GAP_Y
    wrap(g, cols, top)
    g.back = back
    route(g)


ROW_GAP = 160           # between the rows of a long graph wrapped like text


def wrap(g, cols, top):
    """A long chain (a race, a fight: dozens of steps one after the other) in rows like lines of text, so the whole
    graph fits a screen about 16:9: the columns 0..R-1 the first row, R.. the next below."""
    if not cols:
        return
    layers = max(cols) + 1
    band = max((b.y + b.h for b in g.blocks.values()), default=0) - top
    col_w = NODE_W + GAP_X
    per_row = max(4, int(math.ceil(math.sqrt(layers * (band + ROW_GAP) * 16 / 9 / col_w))))
    if per_row >= layers:
        return
    for k, ns in cols.items():
        row, col = divmod(k, per_row)
        for n in ns:
            b = g.blocks[n]
            b.x = col * col_w
            b.y += row * (band + ROW_GAP)


def in_port(b, name):
    k = b.inputs.index(name) if name in b.inputs else 0
    return b.x, b.y + HEAD + text_rows(b) * LINE + k * ROW + ROW // 2


def out_port(b, name):
    k = b.outputs.index(name) if name in b.outputs else 0
    return b.x + b.w, b.y + HEAD + text_rows(b) * LINE + k * ROW + ROW // 2


def route(g):
    """The ways the links run, square: out to the right, along the gap before the target, into it from the left;
    a link back (a loop) under both blocks. Links sharing a gap get lanes of their own."""
    lanes = {}
    g.wires = []
    for a, s, b, p in g.links:
        ba, bb = g.blocks[a], g.blocks[b]
        x0, y0 = out_port(ba, s)
        x1, y1 = in_port(bb, p)
        if x1 > x0 + 20:
            gap = x1 - GAP_X
            k = lanes.get(gap, 0)
            lanes[gap] = k + 1
            mx = x1 - GAP_X // 2 - 24 + (k % 8) * 6
            pts = [(x0, y0), (mx, y0), (mx, y1), (x1, y1)]
        else:                                           # back: right of a, under both, left of b
            below = max(ba.y + ba.h, bb.y + bb.h) + 14 + (len(g.wires) % 6) * 5
            pts = [(x0, y0), (x0 + 16, y0), (x0 + 16, below), (x1 - 16, below), (x1 - 16, y1), (x1, y1)]
        g.wires.append(((a, s, b, p), pts))
