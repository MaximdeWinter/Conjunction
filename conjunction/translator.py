"""The translator (Maxim 05.10.: "ziel ist das jede vanilla quest nun in unserem node graph based system funktioniert
und sachen die nicht unsere vorlagen sind programmable blocks werden"): where blocks of a quest graph are wired the
way a template is inside, the graph shows them as that template's block - one block, its values on its card; a double
click shows its own blocks again. The game's phases are custom blocks already; what no template matches stays the
game's block. Only the view: the file is not touched.

A template is found when its inside is a row Input -> b1 -> ... -> bk -> Output and a graph has blocks of the same
kinds wired one to the next by the same sockets (a scene's: any - they are its file's), each holding the same
conditions (spawn sets: one at least). Folded, no link is hidden: the template's block has the first
block's inputs, the last block's outputs, and a port of its own for each other link into or out of a block between.

    shapes(depot) -> [shape]        the templates one can find
    find(g, shapes) -> [match]      match = {"shape", "blocks": [n, ...]}; no block in two
    fold(g, matches) -> Graph       a copy of g: each match one block (n its first block's; .folded, .shape)
    resolve(tree, match, field)     an exposed field of a match: (object, name), like custom_blocks.resolve
    links_of(folded graph)          the file's links again, from what is drawn (nothing lost: the tests)
    coverage(depot) -> stats        how much of the game's quests reads as templates (python -m conjunction.translator)

    shape = {"tpl": template, "kinds", "puts" (b1..bk), "outs" (b1..bk), "sig" (array sizes), "inside" (index of
             b_i inside the template: an exposed field's "block")}
"""
import copy
import os

from . import custom_blocks as CB

ARRAYS = ("array:2,0,ptr:", "array:2,0,handle:")
_SHAPES = {}


def _sig(tree, n):
    """What a block holds, in counts: (conditions 1, spawnsets 2 ...)."""
    return tuple(sorted((p.name, len(p.value)) for p in tree.obj(n).props or []
                        if p.type.startswith(ARRAYS) and isinstance(p.value, list)))


def _norm(s):
    return "" if not s or not s.strip() else s


def shape_of(depot, tpl):
    """The row a template's inside is, or None (not a row: branches, more than one way in or out)."""
    from .vanilla_graph import QuestFile
    try:
        data = open(tpl["file"], "rb").read()
    except OSError:
        return None
    qf = QuestFile(depot, tpl["file"], data)
    n = CB.template_block(data)
    order = CB.inside(qf.tree, n)
    g = qf.graph(qf.tree.obj(n).get("embeddedGraph"))
    outs = {}
    for a, s, b, p in g.links:
        outs.setdefault(a, []).append((s, b, p))
    ins = [k for k in order if g.blocks[k].cls == "CQuestPhaseInputBlock"]
    if len(ins) != 1 or len(outs.get(ins[0], [])) != 1:
        return None
    cur, row, puts, out_s = ins[0], [], [], []
    _s, nxt, put = outs[cur][0]
    while g.blocks[nxt].cls != "CQuestPhaseOutputBlock":
        if nxt in row or len(outs.get(nxt, [])) != 1:
            return None
        row.append(nxt)
        puts.append(_norm(put))
        s, nxt2, put = outs[nxt][0]
        out_s.append(_norm(s))
        nxt = nxt2
    if not row or len(g.blocks) != len(row) + 2:
        return None
    return {"tpl": tpl, "kinds": [g.blocks[k].kind.id for k in row], "puts": puts, "outs": out_s,
            "sig": [_sig(qf.tree, k) for k in row], "inside": [order.index(k) for k in row]}


def shapes(depot):
    """Every template that is a row of at least two blocks - the longest first (a match takes its blocks first)."""
    out = []
    for t in CB.templates():
        try:
            key = (t["file"], os.path.getmtime(t["file"]))
        except OSError:
            continue
        if key not in _SHAPES:
            try:
                _SHAPES[key] = shape_of(depot, t)
            except Exception:                           # noqa: BLE001 - a broken template is not found, that is all
                _SHAPES[key] = None
        s = _SHAPES[key]
        if s and len(s["kinds"]) >= 2:
            out.append(s)
    return sorted(out, key=lambda s: -len(s["kinds"]))


FREE = {"scene", "talk", "context_talk"}         # (their sockets are the scene file's: any name)
STRICT = {"conditions"}                         # (a wait with two conditions is another wait; three spawn sets: more)


def _fits(sig, want):
    """A block's counts against the template's: conditions the same, the rest (spawn sets ...) one at least."""
    a, b = dict(sig), dict(want)
    return set(a) >= set(b) and all(a[k] == v if k in STRICT else a[k] >= min(v, 1) for k, v in b.items())


def find(g, shapes_):
    """The places of graph g wired as a template is inside (see the module's words). -> [match]"""
    tree = g.qf.tree
    ins, outs = {}, {}
    for a, s, b, p in g.links:
        outs.setdefault(a, []).append((_norm(s), b, _norm(p)))
        ins.setdefault(b, []).append((a, _norm(s), _norm(p)))

    def kind(n):
        k = getattr(g.blocks[n], "kind", None)
        return k.id if k is not None else None
    taken, found = set(), []
    for sh in shapes_:
        k = len(sh["kinds"])
        for n in sorted(g.blocks):
            if n in taken or kind(n) != sh["kinds"][0]:
                continue
            row = [n]
            for i in range(1, k):
                free_out, free_in = sh["kinds"][i - 1] in FREE, sh["kinds"][i] in FREE
                nxt = [b for s, b, p in outs.get(row[-1], [])
                       if (free_out or s == sh["outs"][i - 1]) and (free_in or p == sh["puts"][i])
                       and kind(b) == sh["kinds"][i] and b not in row and b not in taken]
                if len(nxt) != 1:
                    break
                row.append(nxt[0])
            if len(row) != k or not all(_fits(_sig(tree, x), w) for x, w in zip(row, sh["sig"])):
                continue
            if sum(1 for i in range(k - 1) for _s, b, _p in outs.get(row[i], []) if b == row[i + 1]) != k - 1:
                continue                                # (one link between neighbours: the row's own)
            taken.update(row)
            found.append({"shape": sh, "blocks": row})
    return found


def resolve(tree, match, field):
    """An exposed field of the template, in the blocks of a match: (object, name) - None when it is not there."""
    sh = match["shape"]
    if field.get("block") not in sh["inside"]:
        return None
    n = match["blocks"][sh["inside"].index(field["block"])]
    return CB.walk(tree, n, field)


def mirror(editor, guids, shape, field):
    """custom_blocks.mirror for a match: a field that sets more than one place, its value written into the others
    (the match's blocks by their GUIDs - numbers move as a journal path is put in)."""
    if not field.get("also"):
        return

    def where(f):
        if f.get("block") not in shape["inside"]:
            return None
        want = guids[shape["inside"].index(f["block"])]
        n = next((k for k, o in enumerate(editor.tree.objects, 1) if o.props and o.get("guid") is not None
                  and bytes(o.get("guid")) == want), None)
        return CB.walk(editor.tree, n, f) if n else None
    for other in field["also"]:
        here, there = where(field), where(dict(other, label=field.get("label")))
        if here is None or there is None:
            continue
        p = editor.tree.obj(here[0]).prop(here[1])
        if p is None:
            continue
        if p.type == "handle:CJournalPath":
            if isinstance(p.value, int) and p.value > 0:
                editor.set_journal(there[0], there[1], editor.tree.to_bytes(), p.value)
        else:
            editor.set_field(there[0], there[1], copy.deepcopy(p.value), p.type)


def value_text(g, match, field):
    """An exposed field's value in a few words (the line on the template's block)."""
    tree = g.qf.tree
    where = resolve(tree, match, field)
    if where is None:
        return ""
    obj, name = where
    p = tree.obj(obj).prop(name)
    if p is None:
        return "(default)"
    if p.type == "handle:CJournalPath":                 # the block's own line names it: its last part
        b = g.blocks.get(match["blocks"][match["shape"]["inside"].index(field["block"])])
        line = (b.lines or [""])[0] if b is not None else ""
        return line.split(" / ")[-1]
    if p.type.startswith(("soft:", "handle:")):
        path = g.qf.import_path(p.value) if p.value else ""
        return os.path.splitext(os.path.basename(path))[0] if path else "(none)"
    v = p.value
    if isinstance(v, list):
        return ", ".join(str(x).split("\\")[-1] for x in v)
    return str(v)


def _short(g, n):
    b = g.blocks[n]
    k = getattr(b, "kind", None)
    return (k.label if k is not None else b.title).split(":")[0]


def fold(g, matches):
    """Graph g as shown with templates: a shallow copy, each match one block (n: its first block's). Its inputs:
    the first block's, its outputs: the last block's; a link into or out of a block between gets a port of its own
    ("Wait > Out") - every link of the file is there. block.ports = {("in" | "out", port): (block, socket)}."""
    from .vanilla_graph import Block
    if not matches:
        return g
    out = copy.copy(g)
    out.blocks = dict(g.blocks)
    where = {}                                          # real block -> (its template's block, its place in the row)
    for m in matches:
        first, last = m["blocks"][0], m["blocks"][-1]
        tpl = m["shape"]["tpl"]
        v = Block(first, "template")
        v.family = "template"
        v.title = tpl["label"]
        v.name = next((g.blocks[x].name for x in m["blocks"] if g.blocks[x].name), "")
        v.lines = [f"{f['label']}: {value_text(g, m, f)}" for f in tpl.get("exposed") or []][:3]
        v.inputs = list(g.blocks[first].inputs)
        v.outputs = list(g.blocks[last].outputs)
        v.ports = {("in", s): (first, s) for s in v.inputs}
        v.ports.update({("out", s): (last, s) for s in v.outputs})
        v.opens = ("fold", first)
        v.kind = None
        v.folded, v.match, v.last = list(m["blocks"]), m, last
        v.comment = g.blocks[first].comment
        for i, x in enumerate(m["blocks"]):
            out.blocks.pop(x, None)
            where[x] = (first, i)
        out.blocks[first] = v
    links = []
    for a, s, b, p in g.links:
        wa, wb = where.get(a), where.get(b)
        if wa and wb and wa[0] == wb[0] and wb[1] == wa[1] + 1:
            continue                                    # (the row's own link: inside the template's block)
        if wa:
            v = out.blocks[wa[0]]
            if a != v.last:                             # out of a block between: a port of its own
                port = f"{_short(g, a)} > {s or 'Out'}"
                if ("out", port) not in v.ports:
                    v.outputs.append(port)
                    v.ports[("out", port)] = (a, s)
                s = port
            a = wa[0]
        if wb:
            v = out.blocks[wb[0]]
            if b != wb[0]:                              # into a block between
                port = f"> {_short(g, b)}" + (f" {p}" if p else "")
                if ("in", port) not in v.ports:
                    v.inputs.append(port)
                    v.ports[("in", port)] = (b, p)
                p = port
            b = wb[0]
        links.append((a, s, b, p))
    out.links = links
    out.wires = []
    return out


def links_of(gf):
    """The file's links from a folded graph: each drawn link through the ports it ends at, and each template's own
    links between its blocks (what fold left out) - the same as the graph's own, nothing lost (tests)."""
    out = []
    for a, s, b, p in gf.links:
        ba, bb = gf.blocks.get(a), gf.blocks.get(b)
        if getattr(ba, "ports", None):
            a, s = ba.ports[("out", s)]
        if getattr(bb, "ports", None):
            b, p = bb.ports[("in", p)]
        out.append((a, s, b, p))
    g = gf.qf.graph(gf.n)
    for v in gf.blocks.values():
        for x, y in zip(getattr(v, "folded", None) or [], (getattr(v, "folded", None) or [])[1:]):
            out.extend(link for link in g.links if link[0] == x and link[2] == y)
    return out


def coverage(depot=None, log=print):
    """How much of the game's quests reads as templates: blocks folded of all blocks, by template."""
    import collections
    from . import story
    from .bundles import Depot
    from .vanilla_graph import QuestFile
    depot = depot or Depot()
    sh = shapes(depot)
    files = sorted(p for p in depot.where if p.endswith((".w2phase", ".w2quest")) and story.game_file(p))
    total = folded = phases = 0
    by = collections.Counter()
    for path in files:
        try:
            qf = QuestFile(depot, path)
        except Exception:                               # noqa: BLE001
            continue
        for gn, go in enumerate(qf.tree.objects, 1):
            if go.cls != "CQuestGraph":
                continue
            try:
                g = qf.graph(gn)
            except Exception:                           # noqa: BLE001
                continue
            total += len(g.blocks)
            phases += sum(1 for b in g.blocks.values() if b.cls == "CQuestPhaseBlock")
            for m in find(g, sh):
                folded += len(m["blocks"])
                by[m["shape"]["tpl"]["id"]] += 1
    stats = {"files": len(files), "blocks": total, "folded": folded, "phases": phases, "by": dict(by)}
    log(f"[translator] {folded} of {total} blocks ({100 * folded / max(total, 1):.1f} %) read as "
        f"{sum(by.values())} template blocks; {phases} phases (custom blocks already)")
    for tid, c in by.most_common():
        log(f"    {c:6}  {tid}")
    return stats


if __name__ == "__main__":
    coverage()
