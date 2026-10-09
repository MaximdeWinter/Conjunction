"""Every quest graph of the game read once, journal first (Maxim 05.10.: "versuch wirklich alle zu finden mit allen
mitteln. muss man ja nur einmal machen"). The quests are the journal's: every CJournalQuest a quest graph shows.
For each quest graph file:

  journals   the journal quests its CJournalQuestBlocks show, in order (a journal path's deepest .journal file)
  sets       the facts it sets - its FactsDB blocks, its fact scripts (TryToAddUniqueFact, ModifyFactValueQuest)
             and the AddFact_S scripts of the scenes it plays
  gates      what it waits for before it first shows a journal quest: facts, the journal status of other quests
             (CQuestJournalStatusCondition: quest -> quest, the strongest link), the world area, the player's
             level, a notice board visited, an item had or a book read
  children   the phase files it plays (their facts are its quest's too)

    index(depot, log) -> {"files": {path: info}, "journals": {journal file: {"title", "type", "world", "base"}}}
"""
import struct

from .story import INPUTS, _imports_in, game_file

FACT_SCRIPTS = {"TryToAddUniqueFact": "uniqueFactName", "ModifyFactValueQuest": "fact"}
SCENE_FACT_SCRIPTS = ("AddFact_S",)


def _journal_file(f, value):
    found = [x for x in _imports_in(f, value) if x.endswith(".journal")]
    return found[-1] if found else None


def _str(data, i):
    """A CR2W string value at i: its first byte - ascii flag 0x80, more-bytes flag 0x40, 6 bits of the length; each
    further byte 7 bits more while its 0x80 is set."""
    b = data[i]
    n, shift, more, i = b & 0x3F, 6, b & 0x40, i + 1
    while more:
        b = data[i]
        n |= (b & 0x7F) << shift
        shift, more, i = shift + 7, b & 0x80, i + 1
    raw = data[i:i + n]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def _scene_facts(f):
    """The facts a scene's AddFact_S scripts set: their parameters follow the script's properties as (name, type,
    size, value) entries - a String or a CName named factName / factId."""
    out = []
    for cls, _fl, _p, _t, chunk in f.exports:
        if cls != "CStorySceneScript":
            continue
        props = f.props(chunk)
        fn = next((struct.unpack_from("<H", chunk, o)[0] for n, _t, o, _s in props if n == "functionName"), None)
        if fn is None or f.names[fn] not in SCENE_FACT_SCRIPTS:
            continue
        i = ((props[-1][2] + props[-1][3]) if props else 1) + 2     # (after the properties' closing 0)
        while i + 8 <= len(chunk):
            nm, tp = struct.unpack_from("<HH", chunk, i)
            if nm == 0 or nm >= len(f.names) or tp >= len(f.names):
                break
            size = struct.unpack_from("<I", chunk, i + 4)[0]
            vstart = i + 8
            if f.names[nm] in ("factName", "factId") and size > 4:
                if f.names[tp] == "String":
                    out.append(_str(chunk, vstart))
                elif f.names[tp] == "CName":
                    out.append(f.names[struct.unpack_from("<H", chunk, vstart)[0]])
            if size < 4:
                break
            i = vstart + size - 4
    return [x for x in out if x]


def _gate(f, value, gates):
    """The start conditions in a condition tree that say when a quest can begin (not delays, triggers, fights)."""
    from .cr2w_props import decode
    if isinstance(value, tuple) and value and value[0] == "export" and 0 < value[1] <= len(f.exports):
        cls, _fl, _p, _t, chunk = f.exports[value[1] - 1]
        v = decode(f, chunk)
        if cls in ("CQuestFactsDBCondition", "CQuestFactsDBExCondition"):
            for k in ("factId", "factId1"):
                if v.get(k):
                    gates["facts"].add(v[k])
        elif cls == "CQuestJournalStatusCondition":
            j = _journal_file(f, v.get("entry"))
            if j:
                gates["quests"].add((j, v.get("status") or "JS_Active"))
        elif cls == "W3QuestCond_World":
            if v.get("currentArea"):
                gates["areas"].add(v["currentArea"])
        elif cls == "W3QuestCond_PlayerLevel":
            if v.get("level"):
                gates["level"] = max(gates.get("level") or 0, int(v["level"]))
        elif cls == "W3QuestCond_WasNoticeboardVisited":
            if v.get("entityName"):
                gates["boards"].add(v["entityName"])
        elif cls in ("CQCHasItem", "W3QuestCond_IsItemQuantityMet", "CQCHasItemGE"):
            item = v.get("item") or v.get("itemName")
            if isinstance(item, str):
                gates["items"].add(item)
        elif cls in ("W3QuestCond_BookHasBeenRead", "W3QuestCond_BookHasBeenReadExt"):
            book = v.get("bookName")
            book = book.get("itemName") if isinstance(book, dict) else book
            if isinstance(book, str):
                gates["items"].add(book)
        for k, x in v.items():
            if k in ("conditions", "condition", "checkType"):
                _gate(f, x, gates)
    elif isinstance(value, list):
        for x in value:
            _gate(f, x, gates)


def file_info(depot, path):
    from .questread import Graph, open_graph
    g, f = open_graph(depot, path)
    info = {"journals": [], "sets": set(), "scenes": set(), "children": set(),
            "gates": {"facts": set(), "quests": set(), "areas": set(), "boards": set(), "items": set(),
                      "level": None}}
    # facts set and scenes played: everywhere in the file (embedded graphs too)
    stack = [g]
    while stack:
        gr = stack.pop()
        for _i, (cls, bp, _o) in gr.blocks.items():
            if cls == "CQuestFactsDBChangingBlock":
                if bp.get("factID"):
                    info["sets"].add(bp["factID"])
            elif cls == "CQuestScriptBlock" and bp.get("functionName") in FACT_SCRIPTS:
                key = FACT_SCRIPTS[bp["functionName"]]
                for p in bp.get("parameters") or []:
                    if isinstance(p, dict) and p.get("name") == key and isinstance(p.get("value"), str):
                        info["sets"].add(p["value"])
            elif cls in ("CQuestSceneBlock", "CQuestInteractionDialogBlock", "CQuestContextDialogBlock"):
                for k in ("scene", "targetScene"):
                    s = bp.get(k)
                    if isinstance(s, tuple) and s and s[0] == "import":
                        info["scenes"].add(s[1])
            elif cls == "CJournalQuestBlock":
                j = _journal_file(f, bp.get("questEntry"))
                if j and j not in info["journals"]:
                    info["journals"].append(j)
            elif cls == "CQuestPhaseBlock":
                ph = bp.get("phase")
                if isinstance(ph, tuple) and ph and ph[0] == "import":
                    info["children"].add(ph[1])
            emb = bp.get("embeddedGraph")
            if isinstance(emb, tuple) and emb[0] == "export":
                stack.append(Graph(f, emb[1]))
    # the way in: from the inputs to the first journal quest block, the gates on the way (embedded graphs followed)
    todo, gating = [g], True
    while todo and gating:
        gr = todo.pop(0)
        start = [i for i, (cls, _bp, _o) in gr.blocks.items() if cls in INPUTS] or sorted(gr.blocks)[:1]
        seen, queue = set(start), list(start)
        while queue:
            i = queue.pop(0)
            cls, bp, outs = gr.blocks[i]
            if cls == "CJournalQuestBlock":
                gating = False
                break
            if cls == "CQuestPauseConditionBlock":
                _gate(f, bp.get("conditions"), info["gates"])
            elif cls == "CQuestPhaseBlock":
                emb = bp.get("embeddedGraph")
                if isinstance(emb, tuple) and emb[0] == "export":
                    todo.append(Graph(f, emb[1]))
            # a condition with a way on when false is a branch, not a gate: both ways followed, nothing gathered
            branch = cls == "CQuestConditionBlock" and any(s == "False" and t in gr.blocks for s, t, _ts in outs)
            if cls == "CQuestConditionBlock" and not branch:
                _gate(f, bp.get("questCondition"), info["gates"])
            for socket, target, _ts in outs:
                if target in gr.blocks and target not in seen:
                    seen.add(target)
                    queue.append(target)
    return info, f


def index(depot, log=print):
    from .assets import _cr2w_parts
    from .story import _texts, journal_of
    files = sorted(p for p in depot.where if p.endswith((".w2phase", ".w2quest")) and game_file(p))
    out, scene_cache = {}, {}
    for k, path in enumerate(files):
        try:
            info, _f = file_info(depot, path)
        except Exception as ex:                         # noqa: BLE001 - a broken / test file
            log(f"[story] {path}: {ex}")
            continue
        for s in info["scenes"]:
            if s not in scene_cache:
                try:
                    scene_cache[s] = _scene_facts(_cr2w_parts(depot.read(s))[0]) if depot.exists(s) else []
                except Exception:                       # noqa: BLE001
                    scene_cache[s] = []
            info["sets"] |= set(scene_cache[s])
        g = info["gates"]
        out[path] = {"journals": info["journals"], "sets": sorted(info["sets"]), "scenes": sorted(info["scenes"]),
                     "children": sorted(info["children"]),
                     "gates": {"facts": sorted(g["facts"]), "quests": sorted(map(list, g["quests"])),
                               "areas": sorted(g["areas"]), "boards": sorted(g["boards"]),
                               "items": sorted(g["items"]), "level": g["level"]}}
        if k % 100 == 0:
            log(f"[story] {k}/{len(files)} quest files read, {len(scene_cache)} scenes")
    texts = _texts()
    journals = {}
    for info in out.values():
        for j in info["journals"]:
            if j not in journals:
                journals[j] = journal_of(depot, j, texts)
        for j, _status in info["gates"]["quests"]:
            if j not in journals:
                journals[j] = journal_of(depot, j, texts)
    return {"files": out, "journals": {j: v for j, v in journals.items() if v}}
