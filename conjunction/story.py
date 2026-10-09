"""The game's story as a map (Maxim 05.10.: "einen graphen der alle WIRKLICH ALLE quests zeigt ... wann welche quest
passiert, welche dadurch freigeschaltet wird ... dort kann man neue einhängen"): every quest of the game, where in
the story it lies (act, region), what it waits for, and which quest sets that - read from the game's own quest
graphs, nothing guessed.

A quest is a journal quest (CJournalQuest): every one a quest graph of the game shows (story_index reads all 1056
quest graph files). What it waits for, in this order of trust:
  its journal status   a CQuestJournalStatusCondition on its way in: "after quest X is done"
  a fact               a fact waited for on its way in (in its own graph or the structure's graphs above it) that
                       another quest's graph, script blocks or scenes set
  the story's order    the quests the structure passes before it (quests\\witcher3_structure.w2phase and the
                       expansions' roots: Prologue, Part 1, ... )
  shown within         shown inside another quest's graph
Many quests wait for nothing of another quest: a note picked up, a notice board read, a place reached - their
"areas", "items", "boards".

    build(depot) -> {"version": 2, "quests": [...]}       walked once (about half a minute), kept in story.json
    load() -> the same, from story.json
    placed(data) -> the quests with their place on the map ("x" in levels, "lane", "kind", "unlocks")

A quest: {"id" (its journal file), "file" (the graph file that shows it first), "files", "title", "type", "world",
"level", "code", "game", "path" [the parts and regions above it], "gates" [facts waited for], "areas", "items",
"boards", "by" [quests it waits for], "why" {quest: the reason}, "sets" [facts its graphs set]}.
"""
import json
import os
import re

from . import config

CACHE = os.path.join(os.path.dirname(config.PATH), "story.json")
ROOT = r"quests\witcher3_structure.w2phase"
# the story's roots: the base game and the two expansions (each its own graph the game starts beside the others)
ROOTS = [("The Witcher 3", ROOT), ("Hearts of Stone", r"dlc\ep1\data\quests\cyrograf_structure.w2phase"),
         ("Blood and Wine", r"dlc\bob\data\quests\bob_phase.w2phase")]
LEVELS = [r"gameplay\globals\quest_levels.csv", r"dlc\ep1\data\gameplay\globals\quest_levels.csv",
          r"dlc\bob\data\gameplay\globals\quest_levels.csv"]
INPUTS = ("CQuestPhaseInputBlock", "CQuestStartBlock")
# a phase that is a quest (its file or its name): q101, sq202, mq1001, cg100, th1003, ard..., ep1 ...
QUEST_NAME = re.compile(r"(^|[\\ _-])(q|sq|mq|cg|th|ard|ms|nml|lw|ff)\d{2,}", re.I)


def _facts_in(f, value, seen=None):
    """Every factId named in a decoded value - conditions nested in other conditions too (LogicOperation)."""
    from .cr2w_props import decode
    seen = seen if seen is not None else set()
    out = []
    if isinstance(value, tuple) and value and value[0] == "export":
        i = value[1]
        if i in seen or not (0 < i <= len(f.exports)):
            return out
        seen.add(i)
        return _facts_in(f, decode(f, f.exports[i - 1][4]), seen)
    if isinstance(value, dict):
        for k, v in value.items():
            if k in ("factId", "factId1", "factId2") and isinstance(v, str) and v:
                out.append(v)
            else:
                out += _facts_in(f, v, seen)
    elif isinstance(value, list):
        for v in value:
            out += _facts_in(f, v, seen)
    return out


def quest_like(name, path):
    return bool(QUEST_NAME.search(os.path.basename(path or "")) or QUEST_NAME.search(name or "")
                or (name or "").upper().startswith("QUEST"))


class Walker:
    def __init__(self, depot, setters):
        self.depot, self.setters = depot, setters        # setters: fact -> [quest file paths that set it]
        self.quests, self.parts, self.seen_files = {}, [], set()

    def walk_file(self, path, where, gates, after):
        if path in self.seen_files or not self.depot.exists(path):
            return
        self.seen_files.add(path)
        from .questread import open_graph
        g, f = open_graph(self.depot, path)
        self.walk_graph(g, f, path, where, gates, after)

    def walk_graph(self, g, f, origin, where, gates, after):
        """Through a graph from its inputs: the facts waited for on the way, the quests passed - each block's first
        way (the earliest) counts."""
        from .questread import Graph
        start = [i for i, (cls, _bp, _o) in g.blocks.items() if cls in INPUTS] or sorted(g.blocks)[:1]
        state = {i: (frozenset(gates), frozenset(after)) for i in start}
        queue = list(start)
        while queue:
            i = queue.pop(0)
            cls, bp, outs = g.blocks[i]
            gs, af = state[i]
            mine = None
            if cls == "CQuestPauseConditionBlock":
                gs = gs | set(_facts_in(f, bp.get("conditions")))
            elif cls == "CQuestPhaseBlock":
                name = bp.get("name") or ""
                ph, emb = bp.get("phase"), bp.get("embeddedGraph")
                file = ph[1] if isinstance(ph, tuple) and ph[0] == "import" else None
                if quest_like(name, file):
                    mine = file or f"{origin}#{i}"
                    if mine not in self.quests:
                        self.quests[mine] = {"id": mine, "name": name or os.path.basename(file or ""),
                                             "path": list(where), "gates": sorted(gs), "after": sorted(af)}
                elif file:
                    self.parts.append({"name": name, "path": list(where), "file": file})
                    self.walk_file(file, where + [name or os.path.basename(file)], gs, af)
                elif isinstance(emb, tuple) and emb[0] == "export":
                    self.parts.append({"name": name, "path": list(where), "file": f"{origin}#{i}"})
                    self.walk_graph(Graph(f, emb[1]), f, origin, where + [name or "phase"], gs, af)
            for socket, target, _ts in outs:
                if target not in g.blocks or target in state:
                    continue
                g2 = gs
                if cls == "CQuestConditionBlock" and not any(s == "False" and t in g.blocks for s, t, _ts in outs):
                    g2 = gs | set(_facts_in(f, bp.get("questCondition")))     # (with a way on when false: a branch)
                state[target] = (frozenset(g2), frozenset(af | {mine}) if mine else af)
                queue.append(target)


def _imports_in(f, value, seen=None):
    """Every imported file named in a decoded value (a journal path's resource and its children's)."""
    from .cr2w_props import decode
    seen = seen if seen is not None else set()
    out = []
    if isinstance(value, tuple) and value:
        if value[0] == "import":
            out.append(value[1])
        elif value[0] == "export" and value[1] not in seen and 0 < value[1] <= len(f.exports):
            seen.add(value[1])
            out += _imports_in(f, decode(f, f.exports[value[1] - 1][4]), seen)
    elif isinstance(value, dict):
        for v in value.values():
            out += _imports_in(f, v, seen)
    elif isinstance(value, list):
        for v in value:
            out += _imports_in(f, v, seen)
    return out


def code_of(qid):
    """The quest's code from its file or name: q103, sq303, mq1036, cg100 ... (None: none)."""
    m = QUEST_NAME.search(os.path.basename(qid.partition("#")[0]))
    if not m:
        return None
    return m.group(0).strip("\\ _-").lower()


def journal_of(depot, path, texts):
    """A quest's journal entry: {"title", "type", "world", "base"} (None: no such file)."""
    from .assets import _cr2w_parts
    from .cr2w_props import decode
    if not path or not depot.exists(path):
        return None
    f = _cr2w_parts(depot.read(path))[0]
    for cls, _fl, _p, _t, chunk in f.exports:
        if cls == "CJournalQuest":
            v = decode(f, chunk)
            title = v.get("title")
            sid = title[1] if isinstance(title, tuple) and title and title[0] == "string" else None
            return {"title": texts.get(sid) or v.get("baseName") or "", "type": v.get("type") or "Side",
                    "world": v.get("world"), "base": v.get("baseName") or ""}
    return None


def _levels(depot):
    out = {}
    for path in LEVELS:
        if depot.exists(path):
            for line in depot.read(path).decode("utf-8", "replace").splitlines()[1:]:
                name, _, level = line.rpartition(";")
                if name and level.strip().isdigit():
                    out[name.strip().lower()] = int(level)
    return out


def _texts():
    from . import config as cfgmod, w3strings
    path = os.path.join(cfgmod.load()["game"], "content", "content0", "en.w3strings")
    try:
        return w3strings.read(open(path, "rb").read(), "en")[2]
    except OSError:
        return {}


GAME_DLC = re.compile(r"^dlc\\(ep1|bob|dlc\d+)\\", re.I)
GAMES = [("dlc\\ep1\\", "Hearts of Stone"), ("dlc\\bob\\", "Blood and Wine"), ("dlc\\", "Free DLC")]
TESTS = ("demo_files", "\\test", "testing")


def game_file(path):
    """A file of the game itself: the base game, the expansions, the free DLCs - not a DLC a mod (or this Conjunction's
    test runs) put into the game, not Conjunction's own (conjunction\\: its sessions' quest)."""
    low = path.lower()
    if low.startswith("conjunction\\"):
        return False
    return not low.startswith("dlc\\") or bool(GAME_DLC.match(path))


def game_of(path):
    low = path.lower()
    return next((g for prefix, g in GAMES if low.startswith(prefix)), "The Witcher 3")


def build(depot=None, log=print):
    """Every journal quest of the game: its files, where it lies in the story's structure, what it waits for and
    who sets that, what it sets. Walked once (about half a minute), kept in story.json."""
    from . import story_index
    from .bundles import Depot
    depot = depot or Depot()
    idx = story_index.index(depot, log)
    files = {p: v for p, v in idx["files"].items() if game_file(p)}
    journals = {j: v for j, v in idx["journals"].items() if game_file(j)}
    # the story's structure: where each file sits (Prologue, Part 1 ...), the facts waited for on the way to it in
    # the graphs above it, the quests passed before it
    w = Walker(depot, {})
    for game, root in ROOTS:
        if depot.exists(root):
            w.walk_file(root, [game], [], [])
    where = {p["file"]: p["path"] + [p["name"]] for p in w.parts}
    where.update({q["id"]: q["path"] for q in w.quests.values()})
    # the structure's own files (part_1.w2phase ...) show a journal entry now and then - never a quest's files
    containers = {p["file"] for p in w.parts if "#" not in p["file"]} | {r for _g, r in ROOTS} \
        | {r"quests\witcher3_quest.w2quest"}
    parents = {}
    for p, info in files.items():
        for c in info["children"]:
            parents.setdefault(c, set()).add(p)
    owners = {}
    for p, info in files.items():
        for k, j in enumerate(info["journals"]):
            owners.setdefault(j, []).append((k, p))

    def firsts(j):
        mine = owners.get(j, [])
        return [p for k, p in mine if k == 0] or [p for _k, p in mine]

    reps = {j: min(firsts(j), key=lambda p: (p in containers, "bugfix" in p.lower(),
                                             r"\quest_files" "\\" in p or r"\phases" "\\" in p, p.count("\\"), p))
            for j in journals if owners.get(j)}
    memo = {}

    def plain(js):
        """A file's own quests: its journal quests, the chapters played as Ciri left out while there are others
        (q305_blanka shows "Ciri's Story: Breakneck Speed" before The Play's the Thing)."""
        out = [x for x in js if "replacer" not in x.lower()
               and not (journals.get(x) or {}).get("title", "").startswith("Ciri's Story")]
        return out or list(js)

    def primary(p):
        """A file's own quest: of its own ones the first it is the main file of (q305_blanka: The Play's the Thing,
        not A Poet Under Pressure, whose main file is q305_ambush), else its first."""
        js = plain(files[p]["journals"])
        return next((j for j in js if reps.get(j) == p), js[0])

    def quest_of(p, depth=0):
        """The journal quest a file belongs to: its own first one, else the nearest file above it that has one."""
        if p in memo:
            return memo[p]
        memo[p] = None                                  # (a loop, a container: none)
        info = files.get(p)
        if p in containers:
            pass
        elif info and info["journals"]:
            memo[p] = primary(p)
        elif depth < 8:
            above = sorted(filter(None, (quest_of(x, depth + 1) for x in parents.get(p, ()))))
            memo[p] = above[0] if above else None
        return memo[p]

    def where_of(p, depth=0):
        if p in where or depth > 8:
            return where.get(p)
        return next(filter(None, (where_of(x, depth + 1) for x in sorted(parents.get(p, ())))), None)

    setters = {}
    for p, info in files.items():
        if any(t in p.lower() for t in TESTS):
            continue
        for fact in info["sets"]:
            q = quest_of(p)
            if q:
                setters.setdefault(fact, set()).add(q)
    levels = _levels(depot)
    codes = {j: code_of(p) or code_of(j) for j, p in reps.items()}

    def setters_of(fact, j):
        """The quests that set a fact - of those, the one its name begins with (q302_completed: q302) when there
        is one; a fact many quests set (a fix, a counter) is no quest's."""
        who = setters.get(fact, set()) - {j}
        m = QUEST_NAME.match(fact)
        if m:
            named = {s for s in who if (codes.get(s) or "") == m.group(0).strip("\\ _-").lower()}
            who = named or who
        return sorted(who) if len(who) <= 3 else []

    quests = []
    for j, jj in journals.items():
        if j not in reps:
            continue
        mine, first, rep = owners[j], firsts(j), reps[j]
        gates = {"facts": set(), "quests": set(), "areas": set(), "boards": set(), "items": set(), "level": None}
        for p in first:
            g = files[p]["gates"]
            for key in ("facts", "areas", "boards", "items"):
                gates[key] |= set(g[key])
            gates["quests"] |= {tuple(x) for x in g["quests"]}
            if g["level"]:
                gates["level"] = max(gates["level"] or 0, g["level"])
            gates["facts"] |= set((w.quests.get(p) or {}).get("gates") or [])
        why = {}
        for fact in sorted(gates["facts"]):
            if j in setters.get(fact, ()):              # its own fact (set on another of its ways): no other quest's
                continue
            for s in setters_of(fact, j):
                why.setdefault(s, f"sets {fact}")
        for other, status in sorted(gates["quests"]):
            if other != j and other in journals:
                why[other] = f"its journal entry {status[3:].lower()}"
        if not why:
            for p in first:                             # the story's order: the quests passed on the way to it
                for a in (w.quests.get(p) or {}).get("after") or []:
                    s = quest_of(a)
                    if s and s != j:
                        why.setdefault(s, "comes before it in the story")
        if not why:                                     # shown inside another quest's graph: after that quest
            for k, p in mine:
                if k > 0 and p not in containers and files[p]["journals"][0] != j:
                    why.setdefault(files[p]["journals"][0], "shown within it")
                    break
        sets = sorted({f for p, info in files.items() if quest_of(p) == j for f in info["sets"]})
        quests.append({
            "id": j, "file": rep, "files": sorted({p for _k, p in mine}), "title": jj["title"], "type": jj["type"],
            "world": jj["world"], "base": jj["base"], "level": levels.get((jj["base"] or "").lower()),
            "code": codes[j], "game": game_of(rep), "path": where_of(rep) or [game_of(rep)],
            "gates": sorted(gates["facts"]), "areas": sorted(gates["areas"]), "boards": sorted(gates["boards"]),
            "items": sorted(gates["items"]), "min_level": gates["level"], "by": sorted(why), "why": why,
            "sets": sets})
    data = {"version": 2, "quests": sorted(quests, key=lambda q: q["id"])}
    with open(CACHE, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1)
    linked = sum(1 for q in quests if q["by"])
    log(f"[story] {len(quests)} quests, {linked} after another one, from {len(files)} quest files")
    return data


def load():
    """story.json (None: not built yet, or by an older suite)."""
    if not os.path.exists(CACHE):
        return None
    data = json.load(open(CACHE, encoding="utf-8"))
    return data if data.get("version") == 2 else None


_reading = []


def journal_entry(journal):
    """A quest of the game (its journal file, a story quest's id) as a quest block names it: {"file", "obj"} - a
    path to its journal quest, copied from where a quest graph of the game names it (journal_index), for the wait on
    its state (quest.game_quest). None while the journal index is still being read: that starts once, in the
    background (about a minute)."""
    from . import journal_index as J
    index = J.load()
    if index is None:
        if not _reading:
            import threading
            _reading.append(threading.Thread(target=lambda: J.build(log=lambda *_a: None), daemon=True))
            _reading[0].start()
        return None
    for e in index.get("entries") or []:
        if e.get("kind") == "quest" and e["chain"][-1][0].lower() == str(journal).lower():
            return {"file": e["file"], "obj": e["obj"]}
    return None


if __name__ == "__main__":
    build()


# --- the map: where each quest lies on the story's way (its level, never before what unlocks it) and in which lane
LANES = [("story", "Main story"), (4, "White Orchard"), (9, "Velen"), (1, "Novigrad"), (2, "Skellige"),
         (3, "Kaer Morhen"), (11, "Toussaint"), ("other", "Elsewhere")]
MAIN_CODE = re.compile(r"^q\d{3}")              # a main quest: q001 ... q705 (the journal calls most of them Side)
KINDS = {"Chapter": "main", "Side": "side", "MonsterHunt": "contract", "TreasureHunt": "treasure"}
# the acts: where the game keeps the main quests (quests\part_2: Act II, after The Isle of Mists ...); an expansion is
# one act of its own, all its quests in it
ACT_DIRS = [("quests\\prologue\\", "Prologue"), ("quests\\part_1\\", "Act I"), ("quests\\part_2\\", "Act II"),
            ("quests\\part_3\\", "Act III"), ("quests\\epilogues\\", "Epilogue")]
EXPANSIONS = ("Hearts of Stone", "Blood and Wine")
ACTS = [name for _d, name in ACT_DIRS] + list(EXPANSIONS)


def is_main(q):
    return q.get("type") == "Chapter" or bool(MAIN_CODE.match(q.get("code") or ""))


def kind_of(q):
    return "main" if is_main(q) else KINDS.get(q.get("type"), "side")


def lane_of(q):
    if is_main(q):
        return "story"
    return q.get("world") if q.get("world") in (1, 2, 3, 4, 9, 11) else "other"


def act_of(q):
    """The act a quest belongs to: an expansion's quests its expansion, a main quest of the base game the act its
    folder names (None: a side quest of the base game - open whenever its region is)."""
    if q.get("game") in EXPANSIONS:
        return q["game"]
    if not is_main(q):
        return None
    low = (q.get("file") or "").lower()
    return next((name for prefix, name in ACT_DIRS if low.startswith(prefix)), None)


def placed(data):
    """The quests to show, each with "x" (its place on the way, in levels: its own level, never before a quest it
    waits for, an expansion's never before its story begins), "lane", "kind", "act" and "unlocks" [the quests that
    wait for it]."""
    quests = {q["id"]: dict(q, unlocks=[], lane=lane_of(q), kind=kind_of(q)) for q in data["quests"]}
    for q in quests.values():
        q["act"] = act_of(q)
        q["by"] = [b for b in q.get("by", []) if b in quests and b != q["id"]]
        for b in q["by"]:
            quests[b]["unlocks"].append(q["id"])
    # no level of its own (a gwent quest, a B&W one): the lowest level met in its lane of its game - not level 0,
    # before the whole story
    lowest = {}
    for q in quests.values():
        if q.get("level"):
            k = (q["game"], q["lane"])
            lowest[k] = min(lowest.get(k, 99), q["level"])
    for q in quests.values():
        if not q.get("level"):
            q["level_guess"] = lowest.get((q["game"], q["lane"])) or lowest.get((q["game"], "story"))

    def place(floor):
        memo, busy = {}, set()

        def x_of(qid):
            if qid in memo:
                return memo[qid]
            q = quests[qid]
            own = max(float(q.get("level") or q.get("level_guess") or 1), floor.get(q["act"], 0.0))
            if qid in busy:                             # (a loop of facts: its own level)
                return own
            busy.add(qid)
            memo[qid] = max([own] + [x_of(b) + 0.4 for b in q["by"]])
            busy.discard(qid)
            return memo[qid]
        for qid, q in quests.items():
            q["x"] = round(x_of(qid), 2)

    place({})
    # an expansion's quests no earlier than its story begins (B&W's gwent quests are level 1 in its table) - the
    # base game's acts push nothing: its folders are where the makers kept a quest, not when it can be played
    # (Carnal Sins lies in part_2 and waits only for The Play's the Thing)
    floor = {}
    for name in EXPANSIONS:
        xs = [q["x"] for q in quests.values() if q["act"] == name and q["lane"] == "story"]
        if xs:
            floor[name] = min(xs)
    place(floor)
    return list(quests.values())


def acts(quests):
    """Where each act begins on the way, for the ruler: [(name, x)] in the story's order - where most of its main
    quests begin (the first eighth of them left out: a few of every act can be played early)."""
    out, last = [], 0.0
    for name in ACTS:
        xs = sorted(q["x"] for q in quests if q.get("act") == name and q["lane"] == "story")
        if xs:
            if name in EXPANSIONS:                      # (they begin where their story does)
                x = xs[0]
            else:
                x = last = max(xs[len(xs) // 8], last)
            out.append((name, x))
    return out
