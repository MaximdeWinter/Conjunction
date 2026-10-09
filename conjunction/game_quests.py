"""The game's quests as moments a conjunction quest can hang on (hooks: nothing of the game's quest is changed, saves
keep working): each quest file of the game with the facts its graph sets, in the order they come - "mq1060_hook_done",
"q103_baron_told_about_wife" - read with questread. Kept in %APPDATA%\\conjunction\\game_quests.json.

    index() -> [{"path", "name", "facts": [...]}]   (built once, a few minutes)
"""
import json
import os
import re

from . import config

CACHE = os.path.join(os.path.dirname(config.PATH), "game_quests.json")
_index = None


def quest_files(depot):
    """The game's quests: the phase / quest files a quest starts from (not the sub phases in quest_files folders)."""
    out = []
    for p in depot.where:
        if not p.endswith((".w2phase", ".w2quest")) or "\\quests\\" not in "\\" + p:
            continue
        low = p.lower()
        if "\\quest_files\\" in low or "\\phases\\" in low or "test" in low.rsplit("\\", 1)[-1]:
            continue
        out.append(p)
    return sorted(out)


def name_of(path):
    """'quests\\part_1\\q103_daughter.w2phase' -> 'q103 daughter'."""
    return re.sub(r"\.w2(phase|quest)$", "", path.rsplit("\\", 1)[-1]).replace("_", " ")


def facts_set(depot, path, seen=None):
    """The facts a quest's graph sets (value above 0), in the order of its blocks, through its sub phases."""
    from .questread import Graph, open_graph
    seen = seen if seen is not None else set()
    if path in seen or not depot.exists(path):
        return []
    seen.add(path)
    out = []
    try:
        g, f = open_graph(depot, path)
    except Exception:                                   # noqa: BLE001 - a file the reader does not know
        return out
    stack = [g]
    while stack:
        gr = stack.pop(0)
        for i in sorted(gr.blocks):
            cls, bp, _outs = gr.blocks[i]
            if cls == "CQuestFactsDBChangingBlock" and bp.get("factID") and (bp.get("value", 1) or 0) > 0:
                if bp["factID"] not in out:
                    out.append(bp["factID"])
            if cls == "CQuestPhaseBlock":
                emb, ph = bp.get("embeddedGraph"), bp.get("phase")
                if isinstance(emb, tuple) and emb[0] == "export":
                    stack.append(Graph(f, emb[1]))
                elif isinstance(ph, tuple) and ph[0] == "import":
                    out += [x for x in facts_set(depot, ph[1], seen) if x not in out]
    return out


def build(log=print):
    from .bundles import Depot
    d = Depot()
    files = quest_files(d)
    out = []
    for k, p in enumerate(files, 1):
        facts = facts_set(d, p)
        if facts:
            out.append({"path": p, "name": name_of(p), "facts": facts})
        if k % 50 == 0:
            log(f"[game quests] {k} / {len(files)}")
    json.dump(out, open(CACHE, "w", encoding="utf-8"))
    return out


def index():
    global _index
    if _index is None:
        try:
            _index = json.load(open(CACHE, encoding="utf-8"))
        except (OSError, ValueError):
            _index = build(log=lambda s: None)
    return _index


if __name__ == "__main__":
    idx = build()
    print(len(idx), "quests,", sum(len(q["facts"]) for q in idx), "facts")
    for q in idx[:5]:
        print(q["name"], q["facts"][:6])
