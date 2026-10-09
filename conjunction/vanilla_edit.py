"""Editing a game quest file (docs/VANILLA_EDITING_PLAN.md, step 3): every change on the lossless tree, undone and
redone, kept in the project under the game's own path - the build puts it into the project's mod bundle, where it
replaces the game's file.

    e = Editor(depot, path, project_dir)    the project's copy when it has one, else the game's file
    e.set(n, ["parameters", 0, "value"], 12) a value anywhere in an object (property, struct field, array item)
    e.connect(a, "Out", b, "In"), e.disconnect(...)
    e.add_block(graph, cls) / e.duplicate(graph, n) / e.remove_block(graph, n)
    e.add_item(n, path) / e.remove_item(n, path)        an array's item (a copy of its last, or of the game's)
    e.set_ref(n, path, file, cls)            a reference to another file (its import found or added)
    e.undo(), e.redo(), e.save(), e.revert()            save: into <project>\\game_files\\<path>
    e.qf                                    the QuestFile now (re-read after each change)
    e.changed_guids()                       the blocks a save made inside this quest may not find again

Socket names as the game writes them: "In", "Cut", "Input", "Activate" ...; a block's single unnamed output is " "
(Start, phase inputs) or has no name at all (a pause) - written the way the class has it (SOCKETS).
"""
import copy as _copy
import json
import os

from . import config
from .cr2w_tree import Guid, Prop, Soft, Struct, Tags, Tree
from .vanilla_graph import SOCKETS, QuestFile, sockets

GAME_FILES = "game_files"
TEMPLATES = os.path.join(os.path.dirname(config.PATH), "block_templates.json")


def _templates():
    """{class: (game file, object number)}: a block of every class the game has (socket_survey.py writes it);
    built here when missing (a minute)."""
    if os.path.exists(TEMPLATES):
        return json.load(open(TEMPLATES, encoding="utf-8"))["samples"]
    from .bundles import Depot
    from .story import game_file
    d, out = Depot(), {}
    for path in sorted(p for p in d.where if p.endswith((".w2phase", ".w2quest")) and game_file(p)):
        t = Tree(d.read(path))
        for o in t.objects:
            if o.cls == "CQuestGraph":
                for b in o.get("graphBlocks") or []:
                    if isinstance(b, int) and b > 0:
                        out.setdefault(t.obj(b).cls, (path, b))
    json.dump({"samples": out}, open(TEMPLATES, "w", encoding="utf-8"))
    return out


def block_classes():
    return sorted(_templates())


OBJECT_SAMPLES = os.path.join(os.path.dirname(config.PATH), "object_samples.json")


def object_samples():
    """{class: (game file, object number)} for every class the game's quest graphs hold - conditions, AI actions,
    time functions too: what a new one is copied from. Built once (a minute), kept in object_samples.json."""
    if os.path.exists(OBJECT_SAMPLES):
        return json.load(open(OBJECT_SAMPLES, encoding="utf-8"))
    from .bundles import Depot
    from .story import game_file
    d, out = Depot(), {}
    for path in sorted(p for p in d.where if p.endswith((".w2phase", ".w2quest")) and game_file(p)):
        t = Tree(d.read(path))
        for k, o in enumerate(t.objects, 1):
            if o.cls not in out and o.props is not None:
                out[o.cls] = (path, k)
    tmp = OBJECT_SAMPLES + ".tmp"
    json.dump(out, open(tmp, "w", encoding="utf-8"))
    os.replace(tmp, OBJECT_SAMPLES)
    return out


_SAMPLES = {}


def _sample_tree(depot, path):
    """A game file new blocks are copied from, read once (copying leaves it as it is)."""
    if path not in _SAMPLES:
        if len(_SAMPLES) > 64:
            _SAMPLES.clear()
        _SAMPLES[path] = Tree(depot.read(path))
    return _SAMPLES[path]


# a script parameter's type in the scripts -> its type in the quest file, and an empty value of it
SCRIPT_TYPE = {"int": ("Int32", 0), "float": ("Float", 0.0), "bool": ("Bool", False), "name": ("CName", ""),
               "string": ("String", ""), "Int32": ("Int32", 0), "Float": ("Float", 0.0), "Bool": ("Bool", False),
               "CName": ("CName", ""), "String": ("String", "")}


def own_quest(project_dir):
    """The project's own quest as the quest graph edits it: (its path in the DLC, the file the last build encoded)
    - (None, None) before the first build. The graph's changes are kept under game_files\\<that path> like a game
    file's; the build puts them into the DLC in place of what it encoded from the quest board."""
    if not project_dir:
        return None, None
    try:
        from .build import production_id
        qid = production_id(os.path.join(project_dir, "build", "definition.quest"))
    except (OSError, RuntimeError):
        return None, None
    rel = os.path.join("dlc", f"dlc{qid}", "data", f"{qid}.w2quest")
    f = os.path.join(project_dir, "build", "uncooked", rel)
    if not os.path.exists(f):
        return None, None
    enc = os.path.join(project_dir, "build", ENCODED)   # the build put the graph's version there: the board's
    return rel, enc if os.path.exists(enc) else f


ENCODED = "own_quest.encoded.w2quest"   # in build: the quest as the board made it, when the graph's replaced it


OWN_FILE, OWN_META = "own_quest.w2quest", "own_quest.json"     # in game_files: the own quest as the graph left it


def own_quest_data(project_dir):
    """The own quest's graph version for this build: (path in the DLC, its data or None when the graph never changed
    it, what the build encoded). The kept file was made for an earlier run of Build & Play (<id>r<n>: each run a new
    quest to the game): its names and journal GUIDs are moved to this run's."""
    rel, built = own_quest(project_dir)
    if not rel:
        return None, None, None
    base = open(built, "rb").read()
    keep = os.path.join(project_dir, GAME_FILES, OWN_FILE)
    if not os.path.exists(keep):
        return rel, None, base
    data = open(keep, "rb").read()
    try:
        meta = json.load(open(os.path.join(project_dir, GAME_FILES, OWN_META), encoding="utf-8"))
    except (OSError, ValueError):
        meta = {}
    old = meta.get("qid")
    qid = os.path.splitext(os.path.basename(rel))[0]
    guids = {}
    if meta.get("journal"):                             # the journal entries it names, found again by their names
        from .journal_index import own_journal_names
        now = {v: k for k, v in own_journal_names(project_dir).items()}
        guids = {bytes.fromhex(g): bytes.fromhex(now[key]) for g, key in meta["journal"].items()
                 if key in now and now[key] != g}
    elif old and old != qid:                            # (kept before the names were: the runs' GUID keys)
        from .stable_ids import translation
        dlc_dir = os.path.join(project_dir, "build", "uncooked", os.path.dirname(os.path.dirname(rel)))
        from .build import _mark_seed
        guids = translation(dlc_dir, old, qid, seed=_mark_seed(project_dir))
    if (old and old != qid) or guids:
        data = retarget(data, old or qid, qid, guids)
    return rel, data, base


def retarget(data, old, new, guids):
    """A quest file made for quest id `old` moved to `new`: every name, text and file path with the id in it, and the
    GUIDs it points at (guids: {old bytes: new bytes})."""
    from .cr2w_tree import Variant
    t = Tree(data)

    def fix(v):
        if isinstance(v, Tags):
            return Tags(x.replace(old, new) for x in v)
        if isinstance(v, str):
            return type(v)(v.replace(old, new)) if old in v else v
        if isinstance(v, Guid):
            b = bytes(v)
            return Guid(guids[b]) if b in guids else v
        if isinstance(v, Variant):
            return Variant(v.type, fix(v.value))
        if isinstance(v, Struct):
            for p in v:
                p.value = fix(p.value)
            return v
        if isinstance(v, list):
            v[:] = [fix(x) for x in v]
            return v
        return v
    for o in t.objects:
        for props in (o.props or [], o.args or []):
            for p in props:
                p.value = fix(p.value)
    for imp in t.f.imports:
        imp[0] = imp[0].replace(old, new)
    return t.to_bytes()


class Editor:
    def __init__(self, depot, path, project_dir=None, base=None, data=None, own=None):
        """base: the file to start from and go back to (an own quest's: what the build encoded) - else the game's.
        data: the file now (else the project's copy or base). own: where the project keeps it (else
        game_files\\<path>); a meta file beside it remembers the quest id it was made for."""
        self.depot, self.path, self.project_dir = depot, path, project_dir
        self._own = own
        if data is not None:
            self.base = base if base is not None else depot.read(path)
            self.saved = data
            self.history, self.future = [], []
            self._load(data)
            return
        own = self.own_path()
        self.base = base if base is not None else depot.read(path)     # what "revert" goes back to
        data = open(own, "rb").read() if own and os.path.exists(own) else self.base
        self.saved = data
        self.history, self.future = [], []
        self._load(data)

    def own_path(self):
        if self._own:
            return self._own
        return os.path.join(self.project_dir, GAME_FILES, self.path) if self.project_dir else None

    def _load(self, data):
        self.data = data
        self.qf = QuestFile(self.depot, self.path, data)
        self.tree = self.qf.tree

    @property
    def dirty(self):
        return self.data != self.saved

    @property
    def changed(self):
        """Changed from the game's file (saved or not)."""
        return self.data != self.base

    fast = False        # many edits in a row (a rebuild): on the tree itself, no undo; flush() writes the bytes

    def flush(self):
        if self.fast:
            self._load(self.tree.to_bytes())

    def change(self, fn):
        """One edit: fn(tree) changes it; undo goes back to before. -> fn's result."""
        if self.fast:
            result = fn(self.tree)
            self.qf._graphs = {}
            return result
        before = self.data
        tree = Tree(before)
        result = fn(tree)
        after = tree.to_bytes()
        if after != before:
            self.history.append(before)
            self.future.clear()
            self._load(after)
        return result

    def batch(self, fn):
        """Several edits as one: fn(editor) makes them; one undo takes them all back. -> fn's result."""
        if self.fast:
            return fn(self)
        k, start = len(self.history), self.data
        result = fn(self)
        if len(self.history) > k:
            del self.history[k:]
            self.history.append(start)
        return result

    def undo(self):
        if self.history:
            self.future.append(self.data)
            self._load(self.history.pop())

    def redo(self):
        if self.future:
            self.history.append(self.data)
            self._load(self.future.pop())

    def save(self):
        own = self.own_path()
        if not own:
            raise ValueError("No project to keep the change in")
        if not self._own and self.data != self.base:   # a game quest's file changed: experimental (features.py)
            from . import features
            features.require("Changing a game quest file")
        os.makedirs(os.path.dirname(own), exist_ok=True)
        if self.data == self.base:                      # back to the game's file: nothing of ours
            if os.path.exists(own):
                os.remove(own)
        else:
            tmp = own + ".tmp"
            open(tmp, "wb").write(self.data)
            os.replace(tmp, own)
            if self._own:                               # the quest id it was made for, its journal entries by name
                from .journal_index import own_journal_names
                names = own_journal_names(self.project_dir)
                used = {bytes(o.get("guid")).hex() for o in self.tree.objects
                        if o.cls == "CJournalPath" and isinstance(o.get("guid"), Guid)}
                meta = os.path.join(os.path.dirname(own), OWN_META)
                json.dump({"qid": os.path.splitext(os.path.basename(self.path))[0],
                           "journal": {g: names[g] for g in sorted(used) if g in names}}, open(meta + ".tmp", "w"))
                os.replace(meta + ".tmp", meta)
        self.saved = self.data

    def revert(self):
        """Back to the game's file (undo can bring the change back)."""
        if self.data != self.base:
            self.history.append(self.data)
            self.future.clear()
            self._load(self.base)

    # --- values
    def set(self, n, path, value):
        def fn(t):
            holder, key = _locate(t.obj(n).props, path)
            if isinstance(key, int):
                holder[key] = value
            else:
                holder.value = value
        self.change(fn)

    def set_field(self, n, name, value, typ):
        """A property of object n, added when the object lacks it (the game's files leave out what is at its
        default)."""
        self.change(lambda t: t.obj(n).set(name, value, typ))

    def set_param(self, n, name, value):
        """A game function's parameter (a script block): its value in the parameters and in the arguments after
        them, the same type as before."""
        from .cr2w_tree import Variant

        def fn(t):
            o = t.obj(n)
            for p in o.get("parameters") or []:
                if p.get("name") == name:
                    v = p.get("value")
                    holder = next(x for x in p if x.name == "value")
                    holder.value = Variant(v.type, value) if isinstance(v, Variant) else value
                    break
            else:
                raise KeyError(name)
            for a in o.args or []:
                if a.name == name:
                    a.value = value
        self.change(fn)

    def set_ref(self, n, path, file, cls="CResource"):
        """A reference to another file (a scene, a phase, a journal entry): the import found or added. An empty
        path: none."""
        def fn(t):
            holder, key = _locate(t.obj(n).props, path)
            old = holder[key] if isinstance(key, int) else holder.value
            k = 0
            if file:
                k = next((i for i, (p, c, _f) in enumerate(t.f.imports, 1) if p == file), 0)
                if not k:
                    t.f.imports.append([file, cls, 0])
                    k = len(t.f.imports)
            value = Soft(k) if isinstance(old, Soft) else -k
            if isinstance(key, int):
                holder[key] = value
            else:
                holder.value = value
        self.change(fn)

    def add_item(self, n, path):
        """An item more in the array at `path`: a copy of its last item (new GUIDs inside), else of the same array
        in the class's template block."""
        def fn(t):
            holder, key = _locate(t.obj(n).props, path)
            arr = holder[key] if isinstance(key, int) else holder.value
            if arr:
                arr.append(_fresh(_copy.deepcopy(arr[-1])))
            else:
                src = self._template_array(t.obj(n).cls, path)
                if src is None:
                    raise ValueError("Nothing to copy an item from")
                arr.append(src)
            return len(arr) - 1
        return self.change(fn)

    def remove_item(self, n, path):
        def fn(t):
            holder, key = _locate(t.obj(n).props, path[:-1])
            arr = holder[key] if isinstance(key, int) else holder.value
            del arr[path[-1]]
        self.change(fn)

    def _template_array(self, cls, path):
        tpl = _templates().get(cls)
        if not tpl:
            return None
        t = Tree(self.depot.read(tpl[0]))
        try:
            holder, key = _locate(t.obj(tpl[1]).props, path)
        except (KeyError, IndexError):
            return None
        arr = holder[key] if isinstance(key, int) else holder.value
        return _fresh(_copy.deepcopy(arr[0])) if arr else None

    # --- links
    def connect(self, a, out, b, put):
        """A link from block a's output `out` to block b's input `put` (socket names as shown: "" for an unnamed
        one)."""
        def fn(t):
            conns = _conns(t, a)
            want = out.strip()
            c = next((c for c in conns if (c.get("socketId") or "").strip() == want), None)
            if c is None:
                # the class's own name for it (" " for a start's), else as given - an unnamed output stays unnamed
                # (a phase's own output: "" - not "Out", which it does not have)
                raw = next((s for s in sockets(t.obj(a).cls)[1] if s.strip() == want), out)
                c = Struct(([Prop("socketId", "CName", raw)] if raw else []) +
                           [Prop("blocks", "array:2,0,SBlockDesc", [])])
                conns.append(c)
            bp = next((p for p in c if p.name == "blocks"), None)
            if bp is None:                              # (a connection the game left without its list)
                bp = Prop("blocks", "array:2,0,SBlockDesc", [])
                c.append(bp)
            blocks = bp.value
            raw_put = next((s for s in sockets(t.obj(b).cls)[0] if s.strip() == put.strip()), put or "In")
            for d in blocks:
                if d.get("ock") == b and (d.get("putName") or "").strip() == put.strip():
                    return
            blocks.append(Struct([Prop("ock", "ptr:CQuestGraphBlock", b), Prop("putName", "CName", raw_put)]))
        self.change(fn)

    def disconnect(self, a, out, b, put):
        def fn(t):
            for c in _conns(t, a):
                if (c.get("socketId") or "").strip() != out.strip():
                    continue
                blocks = next(p for p in c if p.name == "blocks").value
                blocks[:] = [d for d in blocks if not (d.get("ock") == b and
                                                       (d.get("putName") or "").strip() == put.strip())]
        self.change(fn)

    # --- blocks
    def add_block(self, graph, cls):
        """A block of class `cls` in graph object `graph`: a copy of one the game has (its values a start), its
        links cleared, a new GUID. -> its number."""
        tpl = _templates().get(cls)
        if not tpl:
            raise ValueError(f"the game has no {cls}")
        src = _sample_tree(self.depot, tpl[0])

        def fn(t):
            n = t.adopt(src, tpl[1], parent=graph)
            _clear_links(t.obj(n))
            _blank(t, n)
            emb = t.obj(n).get("embeddedGraph")         # a phase: its inside empty (not the sample's blocks)
            if isinstance(emb, int) and emb > 0:
                inner = [b for b in t.obj(emb).get("graphBlocks") or [] if isinstance(b, int) and b > 0]
                for b in sorted(inner, reverse=True):
                    t.remove(b)
                t.obj(emb).get("graphBlocks")[:] = []
            t.obj(graph).get("graphBlocks").append(n)
            return n
        return self.change(fn)

    def phase_inside(self, n):
        """A phase block that plays a graph of its own (empty: a start and an end) in place of a phase file."""
        tpl = _templates().get("CQuestPhaseBlock")
        src = _sample_tree(self.depot, tpl[0])
        emb_src = src.obj(tpl[1]).get("embeddedGraph")

        def fn(t):
            o = t.obj(n)
            if isinstance(o.get("embeddedGraph"), int) and o.get("embeddedGraph") > 0:
                return
            g = t.adopt(src, emb_src, parent=n)
            for b in sorted([b for b in t.obj(g).get("graphBlocks") or [] if isinstance(b, int) and b > 0],
                            reverse=True):
                t.remove(b)
            t.obj(g).get("graphBlocks")[:] = []
            o.set("embeddedGraph", g, "ptr:CQuestGraph")
            o.props[:] = [p for p in o.props if p.name != "phase"]
        self.change(fn)
        g = self.tree.obj(n).get("embeddedGraph")
        a = self.add_block(g, "CQuestPhaseInputBlock")
        b = self.add_block(g, "CQuestPhaseOutputBlock")
        self.connect(a, "", b, "")

    def phase_from_file(self, n, path):
        """A phase block that plays a phase file (path) in place of a graph of its own (the inside goes)."""
        def fn(t):
            o = t.obj(n)
            emb = o.get("embeddedGraph")
            if isinstance(emb, int) and emb > 0:
                o.set("embeddedGraph", 0, "ptr:CQuestGraph")
                o.props[:] = [p for p in o.props if p.name != "embeddedGraph"]
                t.remove(emb)
            if o.prop("phase") is None:
                o.props.append(Prop("phase", "handle:CQuestPhase", 0))
        self.change(fn)
        if path:
            self.set_ref(n, ["phase"], path, "CQuestPhase")

    def duplicate(self, graph, n):
        def fn(t):
            k = t.copy(n, parent=graph)
            _clear_links(t.obj(k))
            t.obj(graph).get("graphBlocks").append(k)
            return k
        return self.change(fn)

    def paste(self, graph, src, ns):
        """Blocks ns of another quest file (src: its bytes - or this one's) copied into graph object `graph`, with
        what they hold (conditions, a phase's inside), the files they name, and the links among them; links to
        blocks not copied are left out. New GUIDs. -> their new numbers, in order."""
        def fn(t):
            other = Tree(src)
            new = t.adopt_many(other, ns, parent=graph)
            mine = set(new)
            for k in new:
                for c in _conns(t, k):
                    blocks = next((p for p in c if p.name == "blocks"), None)
                    if blocks is not None:
                        blocks.value[:] = [d for d in blocks.value if d.get("ock") in mine]
                t.obj(graph).get("graphBlocks").append(k)
            return new
        return self.change(fn)

    def remove_blocks(self, graph, ns):
        """Several blocks gone at once (one undo)."""
        return self.batch(lambda e: [e.remove_block(graph, n) for n in sorted(ns, reverse=True)])

    def remove_block(self, graph, n):
        """Block n gone: the links into it too, and what it holds (its conditions ...)."""
        def fn(t):
            for b in t.obj(graph).get("graphBlocks") or []:
                if isinstance(b, int) and b > 0 and b != n:
                    for c in _conns(t, b):
                        blocks = next((p for p in c if p.name == "blocks"), None)
                        if blocks is not None:
                            blocks.value[:] = [d for d in blocks.value if d.get("ock") != n]
            gb = t.obj(graph).get("graphBlocks")
            gb[:] = [b for b in gb if b != n]
            t.remove(n)
        self.change(fn)

    # --- the general blocks: any condition, any game function, any AI action
    def _adopt_sample(self, t, cls, parent):
        sample = object_samples().get(cls)
        if not sample:
            raise ValueError(f"the game has no {cls} to copy")
        n = t.adopt(_sample_tree(self.depot, sample[0]), sample[1], parent=parent)
        _blank(t, n)
        return n

    def add_condition(self, block, cls):
        """A condition of class `cls` (a copy of one the game has) under a wait block (its conditions: all must
        hold) or as an if block's condition (the one it had goes). -> its number."""
        def fn(t):
            o = t.obj(block)
            n = self._adopt_sample(t, cls, block)
            if o.cls == "CQuestConditionBlock":
                old = o.get("questCondition")
                o.set("questCondition", n, "ptr:IQuestCondition")
                if isinstance(old, int) and old > 0:
                    n -= sum(1 for k in (old, *t.under(old)) if k < n)
                    t.remove(old)
            else:
                p = o.prop("conditions")
                if p is None:
                    o.props.append(Prop("conditions", "array:2,0,ptr:IQuestCondition", [n]))
                else:
                    p.value.append(n)
            return n
        return self.change(fn)

    def remove_condition(self, block, cond):
        def fn(t):
            o = t.obj(block)
            p = o.prop("conditions")
            if p is not None:
                p.value[:] = [c for c in p.value if c != cond]
            t.remove(cond)
        self.change(fn)

    # --- objects a block is built of: a time function, a minigame, spawn set actions, conditions under and / or
    def set_object(self, n, field, cls, typ):
        """The object under field `field` of object n made one of class `cls` (a copy of one the game has, made
        new); cls None: none. -> its number."""
        def fn(t):
            o = t.obj(n)
            old = o.get(field)
            if cls is None:                             # none: the field left out, as the game's files do
                o.props[:] = [p for p in o.props if p.name != field]
                new = 0
            else:
                new = self._adopt_sample(t, cls, n)
                o.set(field, new, typ)
            if isinstance(old, int) and old > 0:
                new -= sum(1 for k in (old, *t.under(old)) if k < new) if new else 0
                t.remove(old)
            return new
        return self.change(fn)

    def add_object_item(self, n, field, cls, typ):
        """An object of class `cls` more in the list field `field` of object n (created when missing). -> its
        number."""
        def fn(t):
            new = self._adopt_sample(t, cls, n) if cls else 0      # (None: an empty place, as the game has some)
            o = t.obj(n)
            p = o.prop(field)
            if p is None:
                o.props.append(Prop(field, typ, [new]))
            else:
                p.value.append(new)
            return new
        return self.change(fn)

    def remove_object_item(self, n, field, index):
        def fn(t):
            p = t.obj(n).prop(field)
            old = p.value.pop(index)
            if isinstance(old, int) and old > 0:
                t.remove(old)
        self.change(fn)

    def set_journal(self, n, field, src, src_obj):
        """The journal entry field `field` of object n names: the path copied from object src_obj of quest file
        bytes src (journal_index: where the game names that entry) - as the game wrote it. -> its number."""
        def links(tree, k):                             # (a path's parts are not its children: along `child`)
            out = []
            while isinstance(k, int) and k > 0 and tree.obj(k).cls == "CJournalPath" and k not in out:
                out.append(k)
                k = tree.obj(k).get("child")
            return out

        def fn(t):
            o = t.obj(n)
            old = links(t, o.get(field))
            other = src if isinstance(src, Tree) else Tree(src)
            new = t.adopt_many(other, links(other, src_obj), parent=n)[0]
            o.set(field, new, "handle:CJournalPath")
            for k in sorted(old, reverse=True):         # the old path's parts (each block has its own)
                new -= 1 if k < new else 0
                t.remove(k)
            return new
        return self.change(fn)

    def set_journal_entry(self, n, field, src, src_obj, guid):
        """The journal entry field `field` of object n names: a path shaped like the one at src_obj (an objective of
        the same quest), its last part pointed at the entry `guid` (bytes) - an objective made in the quest graph."""
        new = self.set_journal(n, field, src, src_obj)

        def fn(t):
            k, last = new, new
            while isinstance(k, int) and k > 0 and t.obj(k).cls == "CJournalPath":
                last = k
                k = t.obj(k).get("child")
            t.obj(last).set("guid", Guid(guid), "CGUID")
        self.change(fn)
        return new

    def set_check(self, cond, cls):
        """What a person's condition (CQuestActorCondition) checks: an object of class `cls` (a copy of one the
        game has: CQCDistanceTo, CQCIsAlive, CQCHasItem ...) in place of the one it had. -> its number."""
        def fn(t):
            o = t.obj(cond)
            old = o.get("checkType")
            if isinstance(old, int) and old > 0 and t.obj(old).cls == cls:
                return old
            n = self._adopt_sample(t, cls, cond)
            o.set("checkType", n, "ptr:IActorConditionType")
            if isinstance(old, int) and old > 0:
                n -= sum(1 for k in (old, *t.under(old)) if k < n)
                t.remove(old)
            return n
        return self.change(fn)

    def add_wait(self, graph, cls):
        """A wait block that waits for one condition of class `cls`. -> the block's number."""
        n = self.add_block(graph, "CQuestPauseConditionBlock")

        def clear(t):
            o = t.obj(n)
            for c in list(o.get("conditions") or []):
                if isinstance(c, int) and c > 0:
                    t.remove(c)
            o.set("conditions", [], "array:2,0,ptr:IQuestCondition")
            o.props[:] = [p for p in o.props if p.name != "name"]      # (a new block: no name yet)
        self.change(clear)
        self.add_condition(n, cls)
        return n

    def add_function(self, graph, fn_name, params=None):
        """A script block calling the game function `fn_name` with its parameters [(name, script type, value)]
        (the signature's; value None: empty) - as the game writes them: the parameters, then the arguments.
        -> the block's number."""
        from .cr2w_tree import Variant
        n = self.add_block(graph, "CQuestScriptBlock")

        def fn(t):
            o = t.obj(n)
            plist, args = [], []
            for pname, ptype, value in params or []:
                typ, empty = SCRIPT_TYPE.get(ptype, (ptype if ptype[:1].isupper() or ptype[:1] == "#" or ":" in ptype
                                                     else "CName", ""))
                if typ.startswith("array:"):
                    empty = []
                elif typ.startswith(("handle:", "ptr:", "#")):
                    empty = 0
                elif typ == "Vector":
                    empty = Struct([Prop(k, "Float", 0.0) for k in "XYZW"])
                v = empty if value is None else value
                item = [Prop("name", "CName", pname), Prop("value", "CVariant", Variant(typ, v))]
                if typ.startswith("soft:"):                 # (a file: the game marks it so)
                    item.append(Prop("softHandle", "Bool", True))
                plist.append(Struct(item))
                args.append(Prop(pname, typ, v))
            o.props[:] = [p for p in o.props if p.name not in ("functionName", "parameters")]
            if fn_name:                                 # (the game's files leave out what is empty)
                o.set("functionName", fn_name, "CName")
            if plist:
                o.set("parameters", plist, "array:2,0,QuestScriptParam")
            o.set("caption", f"Script [{fn_name}]", "String")       # (what the game's editor writes)
            o.args = args
        self.change(fn)
        return n

    def add_ai(self, graph, cls):
        """An AI actions block whose action is of class `cls` (a copy of one the game has). -> the block's number."""
        n = self.add_block(graph, "CQuestScriptedActionsBlock")

        def fn(t):
            o = t.obj(n)
            old = o.get("ai")
            a = self._adopt_sample(t, cls, n)
            o.set("ai", a, "handle:IAIActionTree")
            if isinstance(old, int) and old > 0:
                t.remove(old)
        self.change(fn)
        return n

    def changed_guids(self):
        """GUIDs of the game's blocks that are gone or new here: a save made inside this quest remembers blocks by
        GUID, these it may not find."""
        def guids(data):
            t = Tree(data)
            return {o.get("guid") for o in t.objects if isinstance(o.get("guid"), Guid)}
        before, now = guids(self.base), guids(self.data)
        return {"gone": len(before - now), "new": len(now - before)}


def _locate(props, path):
    """(holder, key) of the value at `path` in a property list: holder a Prop (key None) or a list (key an
    index). path: property / struct field names and list indices."""
    holder, cur = None, props
    for k, step in enumerate(path):
        if isinstance(step, int):
            if k == len(path) - 1:
                return cur, step
            item = cur[step]
            cur = item
            holder = None
            continue
        p = next((p for p in cur if isinstance(p, Prop) and p.name == step), None)
        if p is None:
            raise KeyError(step)
        holder = p
        cur = p.value
    return holder, None


def _conns(t, n):
    o = t.obj(n)
    p = o.prop("cachedConnections")
    if p is None:                                       # (where the game has it: after the GUID)
        at = next((k + 1 for k, x in enumerate(o.props) if x.name == "guid"), 0)
        o.props.insert(at, Prop("cachedConnections", "array:2,0,SCachedConnections", []))
        p = o.prop("cachedConnections")
    return p.value


KEEP = {"guid", "cachedConnections", "graphBlocks", "embeddedGraph", "questCondition", "ai", "checkType",
        "parameters", "functionName", "function", "minigame"}


def _blank(t, n):
    """A copy of the game's block or condition made new: only what makes it what it is stays (its GUID, links, the
    objects it is built of) - every value back to the class's own default, as a new block in the game's editor;
    the card then sets what the one making it wants. What only a dropped value held goes too."""
    o = t.obj(n)
    keep, drop = [], set()
    for p in o.props or []:
        single = p.type.startswith(("handle:", "ptr:")) and isinstance(p.value, int) and p.value > 0 and \
            t.obj(p.value).cls != "CJournalPath"        # (a journal entry is a value: the sample's goes)
        if p.name in KEEP or single:
            keep.append(p)
            continue
        if "ptr:" in p.type or "handle:" in p.type:
            vals = p.value if isinstance(p.value, list) else [p.value]
            drop |= {v for v in vals if isinstance(v, int) and not isinstance(v, bool) and v > 0}
    o.props[:] = keep
    drop = {c for c in t.with_parts(sorted(drop)) if c > n} if drop else set()
    for c in sorted(drop, reverse=True):
        if t.obj(c).parent == n or t.obj(c).cls == "CJournalPath":
            t.remove(c)
    for p in keep:                                      # the objects it is built of: new too
        child = p.type.startswith(("handle:", "ptr:")) and isinstance(p.value, int) and p.value > n
        if p.name not in ("conditions", "graphBlocks", "embeddedGraph") and child and t.obj(p.value).parent == n:
            _blank(t, p.value)


def _clear_links(o):
    p = o.prop("cachedConnections")
    if p is not None:
        for c in p.value:
            blocks = next((x for x in c if x.name == "blocks"), None)
            if blocks is not None:
                blocks.value[:] = []


def _fresh(v):
    """A copied value with new GUIDs inside (the same block twice would confuse saves)."""
    import uuid
    if isinstance(v, Struct):
        for p in v:
            if p.type == "CGUID":
                p.value = Guid(uuid.uuid4().bytes)
            else:
                p.value = _fresh(p.value)
    elif isinstance(v, list):
        v[:] = [_fresh(x) for x in v]
    return v


__all__ = ["Editor", "SOCKETS", "sockets", "block_classes", "Soft"]
