"""Can the quest graph rebuild the game's quests? (docs/SESSION_PLAN_0510.md, step 8 - Maxim 05.10.: "teste indem du
diese quests nachbaust und checkst ob sie gleich sind zu vanilla"). A graph of a game quest is emptied and built
again block by block with only what the editor offers a person: a block from the sidebar, its fields on the card
(block_card.editable_type: yes/no, numbers, words, choices, tags, lists of names, files; a game function's values;
a wait's conditions and what a person's condition checks), the links drawn. Then each block is compared with the
game's, value for value: what differs is what the editor can not do yet - the list of gaps to close.

    report = check(depot, path, graph=None, deep=True)
        {"blocks": n, "same": n, "links_same": bool, "gaps": Counter("<class>.<field> (<type>)"), "diffs": [...]}
    python -m conjunction.rebuild_check [path ...]       a report per file, the gaps summed
"""
import collections

from . import blocks
from .block_card import QUIET as CARD_QUIET
from .block_card import editable_type, object_type, struct_simple
from .cr2w_tree import Guid, Soft, Struct, Tags, Variant
from .vanilla_edit import Editor

STRUCTURE = {"guid", "cachedConnections", "graphBlocks", "embeddedGraph", "parent"}
FILE_CLASS = {"CStoryScene", "CQuestPhase", "CCommunity", "CEntityTemplate", "CBehTree", "CEnvironmentDefinition"}


def canon(tree, v, typ="", depth=0):
    """A value as plain data to compare: objects under handles followed, imports by path, block GUIDs left out."""
    if isinstance(v, Soft):
        k = int(v)
        return ("file", tree.f.imports[k - 1][0] if 0 < k <= len(tree.f.imports) else None)
    if typ.startswith(("handle:", "ptr:", "#")) and isinstance(v, int) and not isinstance(v, bool):
        if v < 0:
            return ("file", tree.f.imports[-v - 1][0] if -v <= len(tree.f.imports) else None)
        if v == 0 or depth > 8:
            return None
        return obj_canon(tree, v, depth + 1)
    if isinstance(v, Variant):
        return ("variant", v.type, canon(tree, v.value, v.type, depth))
    if isinstance(v, Struct):
        return tuple((p.name, canon(tree, p.value, p.type, depth)) for p in v)
    if isinstance(v, Tags):
        return ("tags", tuple(v))
    if isinstance(v, list):
        inner = typ.split(",", 2)[2] if typ.startswith("array:") else ""
        return tuple(canon(tree, x, inner, depth) for x in v)
    if isinstance(v, Guid):
        return bytes(v).hex()
    if isinstance(v, float):
        return round(v, 5)
    return v


def obj_canon(tree, n, depth=0):
    o = tree.obj(n)
    keep_guid = o.cls == "CJournalPath"
    props = tuple(sorted((p.name, canon(tree, p.value, p.type, depth)) for p in o.props or []
                         if (p.name not in STRUCTURE or (keep_guid and p.name == "guid"))))
    emb = o.get("embeddedGraph")                        # (a phase: a graph inside, or a file - not both)
    if isinstance(emb, int) and emb > 0:
        props += (("(a graph inside)", True),)
    args = tuple((p.name, canon(tree, p.value, p.type, depth)) for p in o.args or [])
    return (o.cls, props, args)


class Rebuilder:
    """Builds blocks of a source quest file into a target editor with the editor's own operations; notes what it
    could not set."""

    def __init__(self, src_tree, target, catalog=None):
        self.src, self.t = src_tree, target
        self.gaps = collections.Counter()
        self.catalog = catalog
        self.target_graph = None                        # (the graph rebuilt, its number after the emptying)
        self.pairs = []                                 # (source graph, target graph) of it and the phases in it

    # --- a block, as the sidebar makes it
    def block(self, graph, n):
        o = self.src.obj(n)
        e = self.t
        if o.cls == blocks.W:
            conds = [c for c in o.get("conditions") or [] if isinstance(c, int) and c > 0]
            new = e.add_wait(graph, self.src.obj(conds[0]).cls) if conds else e.add_block(graph, o.cls)
            if not conds:
                self._clear_conditions(new)
            for k, c in enumerate(conds):               # one after the other: a change may move the numbers after
                m = (e.tree.obj(new).get("conditions") or [None])[0] if k == 0 else \
                    e.add_condition(new, self.src.obj(c).cls)
                self.fields(c, m)
            order = list(o.get("conditions") or [])
            if any(isinstance(v, int) and v <= 0 for v in order):     # (empty places, where the game has them)
                made = iter(list(e.tree.obj(new).get("conditions") or []))
                e.set_field(new, "conditions", [next(made) if isinstance(v, int) and v > 0 else 0 for v in order],
                            "array:2,0,ptr:IQuestCondition")
        elif o.cls == blocks.I:
            c = o.get("questCondition")
            new = e.add_block(graph, o.cls)
            if isinstance(c, int) and c > 0:
                m = e.add_condition(new, self.src.obj(c).cls)
                self.fields(c, m)
            else:                                       # (none: the card's "Kind: (none)")
                e.set_object(new, "questCondition", None, "ptr:IQuestCondition")
        elif o.cls == blocks.S:
            params = []
            for p in o.get("parameters") or []:
                v = p.get("value")
                params.append((p.get("name"), v.type if isinstance(v, Variant) else "CName",
                               v.value if isinstance(v, Variant) else v))
            new = e.add_function(graph, str(o.get("functionName") or ""), params)
        elif o.cls == blocks.A:
            a = o.get("ai")
            new = e.add_ai(graph, self.src.obj(a).cls) if isinstance(a, int) and a > 0 else e.add_block(graph, o.cls)
            if isinstance(a, int) and a > 0:
                self.fields(a, e.tree.obj(new).get("ai"))
            else:                                       # (no action yet: the card's "Kind: (none)")
                e.set_object(new, "ai", None, "handle:IAIActionTree")
        else:
            new = e.add_block(graph, o.cls)
            emb = o.get("embeddedGraph")
            if o.cls == blocks.P and not (isinstance(emb, int) and emb > 0):
                e.phase_from_file(new, None)            # (the card: "a phase file", the file then picked)
        self.fields(n, new, top=True)
        return new

    def _clear_conditions(self, n):
        def fn(t):
            o = t.obj(n)
            for c in list(o.get("conditions") or []):
                if isinstance(c, int) and c > 0:
                    t.remove(c)
            o.props[:] = [p for p in o.props if p.name != "conditions"]
        self.t.change(fn)

    # --- the card's fields
    def fields(self, sn, tn, top=False):
        """Every value of source object sn set on target object tn the way the card sets it; the rest noted."""
        so, e = self.src.obj(sn), self.t
        made = {blocks.W: ("conditions",), blocks.I: ("questCondition",), blocks.A: ("ai",),
                blocks.S: ("parameters", "functionName")}.get(so.cls, ()) if top else ()
        for p in so.props or []:
            if p.name in STRUCTURE or p.name in made:     # (made with the block itself)
                continue
            to = e.tree.obj(tn)
            have = to.prop(p.name)
            if have is not None and canon(e.tree, have.value, have.type) == canon(self.src, p.value, p.type):
                continue
            if p.type.startswith(("handle:", "soft:")) and (isinstance(p.value, Soft) or (
                    isinstance(p.value, int) and not isinstance(p.value, bool) and p.value < 0)):
                path = self._path(p.value)                # a file of the game: its path typed / picked
                cls = p.type.split(":", 1)[1]

                def fn(ed, p=p, path=path, cls=cls):
                    if ed.tree.obj(tn).prop(p.name) is None:
                        ed.set_field(tn, p.name, Soft(0) if p.type.startswith("soft:") else 0, p.type)
                    ed.set_ref(tn, [p.name], path, cls)
                e.batch(fn)
                continue
            if p.name not in CARD_QUIET and (isinstance(p.value, Struct) and struct_simple(p.value) or (
                    p.type.startswith("array:2,0,") and isinstance(p.value, list) and p.value and
                    all(isinstance(x, Struct) and struct_simple(x) for x in p.value))):
                e.set_field(tn, p.name, p.value, p.type)  # (its parts typed in; a list's items added)
                continue
            if p.type == "handle:CJournalPath":         # the journal picker: the entry the game's quests name
                self._journal(sn, tn, p)
                continue
            if object_type(p.type):                     # an object it is built of: its kind chosen, then its fields
                if p.type.startswith("array:"):
                    for item in [v for v in p.value or [] if isinstance(v, int)]:
                        if item <= 0:                   # (an empty place in the list)
                            e.add_object_item(tn, p.name, None, p.type)
                            continue
                        m = e.add_object_item(tn, p.name, self.src.obj(item).cls, p.type)
                        self.fields(item, m)
                elif isinstance(p.value, int) and p.value > 0:
                    m = e.set_object(tn, p.name, self.src.obj(p.value).cls, p.type)
                    self.fields(p.value, m)
                continue
            if p.name in ("name", "comment") or (p.name not in CARD_QUIET and editable_type(p.type)):
                if p.type.startswith(("soft:", "handle:")):
                    path = self._path(p.value)
                    cls = p.type.split(":", 1)[1]

                    def fn(ed, p=p, path=path, cls=cls):
                        if ed.tree.obj(tn).prop(p.name) is None:
                            ed.set_field(tn, p.name, Soft(0) if p.type.startswith("soft:") else 0, p.type)
                        ed.set_ref(tn, [p.name], path, cls)
                    e.batch(fn)
                else:
                    e.set_field(tn, p.name, p.value, p.type)
                continue
            self.gaps[f"{so.cls}.{p.name} ({p.type})"] += 1
        # what the target has that the source leaves out (the template's): an object - its "Kind: (none)"
        for p in list(e.tree.obj(tn).props or []):
            if p.name in STRUCTURE or so.prop(p.name) is not None:
                continue
            if top and so.cls in (blocks.W, blocks.I, blocks.A, blocks.S) and p.name in (
                    "conditions", "questCondition", "ai", "parameters", "functionName"):
                continue
            if object_type(p.type):
                e.set_object(tn, p.name, None, p.type)
                continue
            self.gaps[f"{so.cls}.{p.name} (left in from the template)"] += 1

    def _journal(self, sn, tn, p):
        from . import journal_index as J
        if not (isinstance(p.value, int) and p.value > 0):
            return
        if not hasattr(self, "_jix"):
            self._jix = J.by_key(J.get(self.t.depot))
        e = self._jix.get(J.key_of(J.chain(self.src, p.value)))
        if e is None:
            self.gaps[f"{self.src.obj(sn).cls}.{p.name} (a journal entry no quest names)"] += 1
            return
        from .vanilla_edit import _sample_tree
        self.t.set_journal(tn, p.name, _sample_tree(self.t.depot, e["file"]), e["obj"])

    def _path(self, v):
        k = int(v) if isinstance(v, Soft) else -v if isinstance(v, int) and v < 0 else 0
        return self.src.f.imports[k - 1][0] if 0 < k <= len(self.src.f.imports) else ""

    # --- a graph
    def graph(self, sg, tg, deep=True):
        """Source graph object sg rebuilt into target graph object tg (emptied first). -> {source n: target n}"""
        e = self.t
        old = [b for b in e.tree.obj(tg).get("graphBlocks") or [] if isinstance(b, int) and b > 0]
        if old:
            gone = set()
            for b in old:
                gone |= {b, *e.tree.under(b)}
            e.remove_blocks(tg, old)
            tg -= sum(1 for k in gone if k < tg)        # (the numbers before it moved down)
        if not hasattr(self, "target_graph") or self.target_graph is None:
            self.target_graph = tg
        self.pairs.append((sg, tg))
        m, level = {}, []
        for b in self.src.obj(sg).get("graphBlocks") or []:
            if not (isinstance(b, int) and b > 0):
                continue
            m[b] = self.block(tg, b)
            level.append(b)
            emb = self.src.obj(b).get("embeddedGraph")
            if deep and isinstance(emb, int) and emb > 0:     # a phase: its inside rebuilt the same way
                temb = e.tree.obj(m[b]).get("embeddedGraph")
                if isinstance(temb, int) and temb > 0:
                    m.update(self.graph(emb, temb, deep))
        for b in level:
            nb = m[b]
            for c in self.src.obj(b).get("cachedConnections") or []:
                sock = c.get("socketId") or ""
                for dsc in c.get("blocks") or []:
                    to = dsc.get("ock")
                    if to in level:
                        e.connect(nb, sock, m[to], dsc.get("putName") or "")
        return m


def check(depot, path, graph=None, deep=False):
    """One graph of a game quest file rebuilt and compared (see the module's text)."""
    src = Editor(depot, path)
    s = src.tree
    gn = graph or src.qf.root
    tgt = Editor(depot, path)
    tgt.fast = True
    r = Rebuilder(s, tgt)
    m = r.graph(gn, gn, deep)
    tgt.flush()
    t = tgt.tree
    same, diffs = 0, []
    for sn, tn in m.items():
        a, b = obj_canon(s, sn), obj_canon(t, tn)
        if a == b:
            same += 1
        else:
            da, db = dict(a[1]), dict(b[1])
            keys = sorted(k for k in set(da) | set(db) if da.get(k) != db.get(k))
            diffs.append((s.obj(sn).cls, keys[:6], a[2] != b[2]))
    inv = {v: k for k, v in m.items()}
    nl = [0, 0]
    links_same = True
    for sg, tg in r.pairs:                              # every graph: its links the same
        sl = {(a, x, b, p) for a, x, b, p in src.qf.graph(sg).links}
        tl = {(inv.get(a), x, inv.get(b), p) for a, x, b, p in tgt.qf.graph(tg).links}
        nl[0] += len(sl)
        nl[1] += len(tl)
        links_same &= sl == tl
    return {"blocks": len(m), "same": same, "links_same": links_same, "links": tuple(nl), "graphs": len(r.pairs),
            "gaps": r.gaps, "diffs": diffs}


def rebuild(depot, path, deep=True):
    """A game quest file built again with the editor's own operations (every phase inside too). -> (its bytes, the
    report of check)."""
    src = Editor(depot, path)
    tgt = Editor(depot, path)
    tgt.fast = True
    r = Rebuilder(src.tree, tgt)
    r.graph(src.qf.root, src.qf.root, deep)
    tgt.flush()
    return tgt.data


def main(paths):
    from .bundles import Depot
    d = Depot()
    total = collections.Counter()
    nb = ns = 0
    for p in paths:
        try:
            rep = check(d, p, deep=True)                # (the whole file: every phase inside it too)
        except Exception as ex:                         # noqa: BLE001 - the report goes on
            print(f"{p}: FAILED {type(ex).__name__} {ex}")
            continue
        nb += rep["blocks"]
        ns += rep["same"]
        total.update(rep["gaps"])
        print(f"{p}: {rep['same']}/{rep['blocks']} blocks in {rep['graphs']} graphs the same, links "
              f"{'the same' if rep['links_same'] else 'DIFFER ' + str(rep['links'])}")
    print(f"\nall: {ns}/{nb} blocks the same ({100 * ns / max(nb, 1):.1f} %)")
    for g, c in total.most_common(40):
        print(f"{c:6}  {g}")
    return ns, nb, total


if __name__ == "__main__":
    import sys
    main(sys.argv[1:])
