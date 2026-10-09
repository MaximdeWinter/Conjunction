"""Real examples of every kind of block (docs/SESSION_PLAN_0510.md, step 6 - Maxim 05.10.: "exzellente dokumentation
die anhand von echten ingame beispielen zeigt wie diese blöcke funktionieren und was sie bewirken"): for each kind
the places the game's own quests use it - which quest, which phase, the designer's name for the block, what it
does there, what leads into it and where it goes on. The card shows them ("How the game uses it"), a click opens
the place in the graph; docs/QUEST_BLOCKS.md is written from them.

    build(depot) -> examples        a few minutes; kept in %APPDATA%\\conjunction\\block_examples.json
    load() / get(depot)
    examples = {kind id: {"count": n, "files": n, "examples": [{"file", "trail": [phase GUIDs], "guid", "quest",
                "where", "name", "lines", "before", "after"}]}}
    write_docs(examples, path)      the handbook
"""
import collections
import json
import os

from . import blocks, config

CACHE = os.path.join(os.path.dirname(config.PATH), "block_examples.json")
PER_KIND = 6


def _guid(tree, n):
    g = tree.obj(n).get("guid")
    return bytes(g).hex() if g is not None else None


def trail(tree, graph):
    """The phase blocks (their GUIDs, outermost first) one steps into from the file's main graph to reach graph
    object `graph`."""
    holder = {}
    for k, o in enumerate(tree.objects, 1):
        emb = o.get("embeddedGraph") if o.props else None
        if isinstance(emb, int) and emb > 0:
            holder[emb] = k
    out, g, seen = [], graph, set()
    while g in holder and g not in seen:
        seen.add(g)
        b = holder[g]
        out.append(_guid(tree, b))
        g = tree.obj(b).parent
    return list(reversed(out))


def _score(path, name):
    """Main story first, then side quests; named blocks first."""
    p = path.lower().replace(os.sep, "/").replace("\\", "/")
    if p.startswith(("quests/part_", "quests/prologue")):
        main = 0
    elif p.startswith("dlc/") and "/quests/" in p and ("main" in p or "/q" in p):
        main = 1
    elif p.startswith(("quests/secondary", "quests/minor", "quests/sidequests")):
        main = 2
    else:
        main = 3
    return (main, 0 if name else 1)


def build(depot=None, log=print):
    from . import story
    from .bundles import Depot
    from .vanilla_graph import QuestFile
    depot = depot or Depot()
    files = sorted(p for p in depot.where if p.endswith((".w2phase", ".w2quest")) and story.game_file(p))
    count, in_files, cands = collections.Counter(), collections.defaultdict(set), collections.defaultdict(list)
    for path in files:
        try:
            qf = QuestFile(depot, path)
        except Exception:                               # noqa: BLE001
            continue
        t = qf.tree
        for gn, go in enumerate(t.objects, 1):
            if go.cls != "CQuestGraph":
                continue
            try:
                g = qf.graph(gn)
            except Exception:                           # noqa: BLE001
                continue
            ins, outs = collections.defaultdict(list), collections.defaultdict(list)
            for a, s, b, p in g.links:
                outs[a].append(b)
                ins[b].append(a)
            for n, b in g.blocks.items():
                k = b.kind
                count[k.id] += 1
                in_files[k.id].add(path)
                c = cands[k.id]
                if len(c) >= 60 and _score(path, b.name) >= c[-1][0]:
                    continue
                ex = {"file": path, "graph": gn, "n": n, "name": b.name, "lines": b.lines[:3],
                      "before": [g.blocks[x].title for x in ins[n][:3] if x in g.blocks],
                      "after": [g.blocks[x].title for x in outs[n][:3] if x in g.blocks]}
                c.append((_score(path, b.name), ex))
                c.sort(key=lambda x: x[0])
                del c[60:]
    out = {}
    names = {}
    for kid, c in cands.items():
        chosen, quests = [], set()
        for _s, ex in c:                                # one example per quest file
            if ex["file"] in quests:
                continue
            quests.add(ex["file"])
            chosen.append(ex)
            if len(chosen) >= PER_KIND:
                break
        for ex in chosen:                               # where: the quest and the phases in, and GUIDs to go there
            qf = QuestFile(depot, ex["file"])
            ex["trail"] = trail(qf.tree, ex.pop("graph"))
            ex["guid"] = _guid(qf.tree, ex.pop("n"))
            ex["quest"] = os.path.splitext(os.path.basename(ex["file"]))[0]
            if ex["file"] not in names:
                names[ex["file"]] = {_guid(qf.tree, k): (o.get("name") or "") for k, o in
                                     enumerate(qf.tree.objects, 1) if o.cls == "CQuestPhaseBlock"}
            ex["where"] = " > ".join(names[ex["file"]].get(g) or "phase" for g in ex["trail"])
        out[kid] = {"count": count[kid], "files": len(in_files[kid]), "examples": chosen}
    tmp = CACHE + ".tmp"
    json.dump(out, open(tmp, "w", encoding="utf-8"), indent=1)
    os.replace(tmp, CACHE)
    log(f"[examples] {sum(len(v['examples']) for v in out.values())} examples of {len(out)} kinds")
    return out


def load():
    return json.load(open(CACHE, encoding="utf-8")) if os.path.exists(CACHE) else None


def get(depot=None):
    return load() or build(depot)


# --- the handbook
INTRO = """# Quest blocks: what each one does, and where the game uses it

Every quest of The Witcher 3 is a graph of blocks; the quest graph in Conjunction shows the game's own quests and
yours the same way. This page lists every kind of block the sidebar offers, in its groups, with what it does and
real places in the game's quests that use it (open them in the quest graph: Story map > a quest > Quest graph, or
from a block's card: "How the game uses it").

How to read a graph: a block runs when a link reaches one of its inputs (left), then goes on along its outputs
(right). A wait holds the story until its condition is true. An "If" goes on along True or False. A custom block
(the game: a phase) has a graph inside: double click to step in; its "Input" and "Output" blocks are its ways in and
out. Facts are the quest's memory: talks, scripts and blocks set them, waits and ifs read them.

Counts: how many blocks of the kind the game's quests have, in how many quest files.
"""


def kind_fields(kind, most=7):
    """The fields one sets on a kind's card, the most used first: 'fact ID', 'compare (default =)' ..."""
    from . import game_catalog
    from .block_card import QUIET, editable_type, human
    cat = game_catalog.load() or {}
    if kind.fn:
        f = (cat.get("functions") or {}).get(kind.fn[0]) or {}
        return [human(p["name"]) for p in f.get("params") or []][:most]
    cls = kind.cond[0].split("/")[-1] if kind.cond else kind.cls
    c = (cat.get("classes") or {}).get(cls) or {}
    out = []
    for name, f in sorted((c.get("fields") or {}).items(), key=lambda kv: -(kv[1].get("count") or 0)):
        if name in QUIET or not editable_type(f.get("type") or ""):
            continue
        d = game_catalog.default_of(cat, cls, name)
        shown = "yes" if d is True else "no" if d is False else d
        out.append(human(name) + (f" (default {shown})" if shown not in (None, "") else ""))
    return out[:most]


def write_docs(examples, path):
    lines = [INTRO]
    for gid, gname in blocks.GROUPS:
        kinds = [k for k in blocks.KINDS if k.group == gid]
        if not kinds:
            continue
        lines.append(f"\n## {gname}\n")
        for k in kinds:
            e = examples.get(k.id) or {}
            lines.append(f"### {k.label}\n")
            lines.append(f"{k.text}\n")
            fields = kind_fields(k)
            if fields:
                lines.append("Fields: " + ", ".join(fields) + "\n")
            if k.id in blocks.STARTS:                   # (what a new one from the sidebar starts with)
                from .block_card import human
                lines.append("A new one starts with: " + ", ".join(
                    f"{human(field)} {value}" for (_where, field), value in blocks.STARTS[k.id].items()) + "\n")
            if e.get("count"):
                lines.append(f"*In the game: {e['count']} blocks in {e['files']} quest files.*\n")
            for ex in (e.get("examples") or [])[:4]:
                where = f"{ex['quest']}" + (f" > {ex['where']}" if ex.get("where") else "")
                name = f" \"{ex['name']}\"" if ex.get("name") else ""
                what = "; ".join(ex.get("lines") or [])
                lines.append(f"- **{where}**{name}: {what}" +
                             (f" - after {', '.join(ex['before'])}" if ex.get("before") else "") +
                             (f", then {', '.join(ex['after'])}" if ex.get("after") else ""))
            lines.append("")
    rest = {k: v for k, v in examples.items() if k not in blocks.BY_ID}
    if rest:
        lines.append("\n## The game's other blocks\n")
        lines.append("Every block class, condition, quest function and action of the game is in the sidebar under "
                     "\"Game blocks\"; its card is made from the game's own scripts and files. The most used:\n")
        for k, v in sorted(rest.items(), key=lambda kv: -kv[1]["count"])[:40]:
            ex = (v.get("examples") or [{}])[0]
            lines.append(f"- **{k}** ({v['count']} blocks): e.g. {ex.get('quest', '')} - "
                         f"{'; '.join(ex.get('lines') or [])}")
    open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    return path
