"""Editor sessions (docs/VANILLA_EDITING_PLAN.md, step 4): the game played from files, never from a save. A new
session is the game's own new game with a game definition (.redgame, CWitcherGameResource: its worlds - the first
is where it starts -, the starting point there, the main quest), asked for by script: theGame.RequestNewGame(path)
(exec cj_new_session). Facts it starts with: put on the game object before (cj_session_fact - the game object
lives on from session to session), set by our main quest at its start (the game's own initial facts,
AddInitialFact, did not come over into a session asked for in game: measured 05.10.).

Seen in the game 05.10.: CDPR's endgame_review.redgame started a fresh session in Skellige at its starting point,
its main quest set its facts and played CDPR's debug scene for the story's state.

The game ships 185 definitions: the story's parts and hubs reviewed (game\\game_parts_definitions,
game\\hub_definitions) and a test start for many quests (Blood and Wine has one for nearly each).

    definitions()           every definition: path, name, world, start, main quest, the quest files it starts and
                            the story's quests among them (kept in %APPDATA%\\conjunction\\sessions.json)
    for_quest(q, defs)      the definitions that start the story map's quest q
    story_starts(defs)      the ones that start a part of the story (many quests at once)
    start(link, path)       a fresh session from one of the game's definitions
    jump(link, world, entry, facts)  a fresh session of ours: a world, the story's entry, facts
"""
import json
import os

from . import config

CACHE = os.path.join(os.path.dirname(config.PATH), "sessions.json")
NOT_STARTS = ("engine\\", "\\demo_files\\", "_freecam", "\\test\\", "performance")
MANY = 6                        # a definition starting this many quests starts a part of the story


def _phase_files(depot, path):
    """The quest graph files a main quest plays: those it names, and those the phases it names name (one deep)."""
    from .cr2w_tree import Tree
    seen, out = set(), []
    todo = [(path, 0)]
    while todo:
        p, depth = todo.pop(0)
        if p in seen or not depot.exists(p):
            continue
        seen.add(p)
        try:
            t = Tree(depot.read(p))
        except Exception:                               # noqa: BLE001 - a broken test file
            continue
        for imp, _cls, _fl in t.f.imports:
            if imp.endswith((".w2phase", ".w2quest")) and imp not in out:
                out.append(imp)
                if depth < 1:
                    todo.append((imp, depth + 1))
    return out


def definitions(depot=None, story_data=None, rebuild=False):
    if not rebuild and os.path.exists(CACHE):
        try:
            return json.load(open(CACHE, encoding="utf-8"))
        except (OSError, ValueError):
            pass
    from . import story
    from .bundles import Depot
    from .cr2w_tree import Tree
    depot = depot or Depot()
    data = story_data or story.load() or {"quests": []}
    owner, by_id = {}, {q["id"]: q for q in data["quests"]}
    for q in data["quests"]:
        for f in q.get("files") or [q.get("file")]:
            owner.setdefault(f, set()).add(q["id"])
    containers = {story.ROOT, r"quests\witcher3_quest.w2quest"}
    out = []
    for path in sorted(p for p in depot.where if p.endswith(".redgame") and story.game_file(p)):
        if any(w in path.lower() for w in NOT_STARTS):
            continue
        try:
            t = Tree(depot.read(path))
        except Exception:                               # noqa: BLE001
            continue
        o = t.obj(1)
        if o.cls != "CWitcherGameResource":
            continue
        imps = t.f.imports

        def imp(k):
            return imps[k - 1][0] if isinstance(k, int) and 0 < k <= len(imps) else None
        worlds = [imp(w.get("world")) for w in o.get("worlds") or []]
        sp = o.get("startingPoint")
        main = imp(o.get("mainQuest"))
        files = _phase_files(depot, main) if main else []
        quests = sorted({j for f in files if f not in containers for j in owner.get(f, ())})
        name = os.path.splitext(os.path.basename(path))[0]
        # its quest by the code in its name (mq7002_knight: mq7002) - a test start plays common phases too (a
        # Gwent phase in nearly every Blood and Wine one)
        code = story.code_of(name)
        if code:
            mine = [j for j in quests if by_id[j].get("code") == code] or \
                [q["id"] for q in data["quests"] if q.get("code") == code]
            quests = sorted(mine)
        out.append({"path": path, "name": name, "world": worlds[0] if worlds else None,
                    "worlds": [w for w in worlds if w], "start": list(sp.position) if sp and sp.position else None,
                    "quest": main, "files": files, "quests": quests,
                    "story": path.lower().startswith("game\\") or (not code and len(quests) >= MANY)})
    tmp = CACHE + ".tmp"
    json.dump(out, open(tmp, "w", encoding="utf-8"), indent=1)
    os.replace(tmp, CACHE)
    return out


def for_quest(q, defs):
    """The definitions that start quest q itself (not a whole part of the story)."""
    return [d for d in defs if q["id"] in d["quests"] and not d["story"]]


def story_starts(defs):
    return [d for d in defs if d["story"]]


def world_name(path):
    names = {"kaer_morhen": "Kaer Morhen", "novigrad": "Velen and Novigrad", "prolog_village": "White Orchard",
             "prolog_village_winter": "White Orchard (winter)", "skellige": "Skellige", "bob": "Toussaint",
             "wyzima_castle": "Vizima", "island_of_mist": "Isle of Mists", "spiral": "The Spiral"}
    if not path:
        return ""
    parts = path.lower().split("\\")
    key = parts[-2] if len(parts) > 1 else parts[-1]
    return names.get(key, key.replace("_", " "))


def start(link, path):
    """A fresh session from one of the game's definitions (the running game's state is gone - nothing is saved);
    no session facts left over for it."""
    link.exec("cj_session_clear()")
    link.exec(f'cj_new_session("{path.replace(chr(92), "/")}")')


# --- our own starts: a definition for each world, one main quest that goes where the session's facts say
JUMP = r"conjunction\sessions\jump.w2quest"
MOD = "modConjunctionSessions"
MAIN = r"quests\witcher3_quest.w2quest"
IF_FACT = (r"quests\witcher3_structure.w2phase", "part1_skellige_start")    # a condition block on a fact: the model
# each world's definition: the game's definition it is made from, the one whose starting point it takes
WORLD_DEFS = {
    "kaer_morhen": (r"game\witcher3.redgame", r"game\witcher3.redgame"),
    "novigrad": (r"game\witcher3.redgame", r"game\hub_definitions\novigrad_part1.redgame"),
    "prolog_village": (r"game\witcher3.redgame",
                       r"quests\prologue\quest_files\q001_beggining\q001_after_nightmare.redgame"),
    "skellige": (r"game\witcher3.redgame", r"game\game_parts_definitions\endgame_review.redgame"),
    "bob": (r"dlc\bob\data\quests\bob_toussaint_tech_def.redgame",
            r"dlc\bob\data\quests\bob_toussaint_tech_def.redgame"),
}


def entry_fact(entry):
    return "cj_entry_" + "".join(c if c.isalnum() else "_" for c in entry.lower()).strip("_")


def world_def(world):
    return rf"conjunction\sessions\{world}.redgame"


def entries(depot):
    """The story structure's inputs (prologue, part 1, ... endgame, epilogues): where a jump can go in."""
    from .story import ROOT
    from .vanilla_graph import QuestFile
    g = QuestFile(depot, ROOT).graph()
    return [b.name for b in sorted(g.blocks.values(), key=lambda b: b.n) if b.cls == "CQuestPhaseInputBlock"
            and b.name]


def jump_quest(depot):
    """The main quest of our starts: at its start the session's facts set (the quest function CjSessionFacts:
    what Conjunction put on the game object before asking for the session), then a fact test per story entry
    (cj_entry_<entry>) - true: into the structure there; none true: no story at all (the world alone). -> the
    file's bytes."""
    from .cr2w_tree import Tree
    from .vanilla_edit import Editor
    e = Editor(depot, MAIN)
    src_path, src_fact = IF_FACT
    src = Tree(depot.read(src_path))
    model = next(k for k, o in enumerate(src.objects, 1) if o.cls == "CQuestConditionBlock"
                 and src.obj(o.get("questCondition")).get("factId") == src_fact)
    g = e.qf.graph()
    start = next(b.n for b in g.blocks.values() if b.cls == "CQuestStartBlock")
    phase = next(b.n for b in g.blocks.values() if b.cls == "CQuestPhaseBlock")
    graph = e.qf.root
    for a, s, b, p in list(g.links):
        e.disconnect(a, s, b, p)
    names = entries(depot)

    def add_tests(t):
        made = []
        for name in names:
            n = t.adopt(src, model, parent=graph)
            o = t.obj(n)
            o.set("name", f"If {entry_fact(name)}")
            for c in o.get("cachedConnections") or []:
                next(x for x in c if x.name == "blocks").value[:] = []
            t.obj(o.get("questCondition")).set("factId", entry_fact(name))
            t.obj(graph).get("graphBlocks").append(n)
            made.append(n)
        return made
    tests = e.change(add_tests)

    def add_script(t):                                  # (a script block of the structure's: its function ours)
        model_script = next(k for k, o in enumerate(src.objects, 1) if o.cls == "CQuestScriptBlock")
        n = t.adopt(src, model_script, parent=graph)
        o = t.obj(n)
        o.set("functionName", "CjSessionFacts")
        o.set("parameters", [])
        o.args = []
        for p in o.props:
            if p.name in ("comment", "caption"):
                p.value = "session facts"
        for c in o.get("cachedConnections") or []:
            next(x for x in c if x.name == "blocks").value[:] = []
        t.obj(graph).get("graphBlocks").append(n)
        return n
    script = e.change(add_script)
    e.connect(start, "", script, "In")
    e.connect(script, "Out", tests[0], "In")
    for k, (n, name) in enumerate(zip(tests, names)):
        e.connect(n, "True", phase, name)
        if k + 1 < len(tests):
            e.connect(n, "False", tests[k + 1], "In")
    return e.data


def world_definition(depot, world):
    """Our definition for a world: the game's (its worlds, the chosen one first), the starting point of a game
    definition that starts there, our main quest, no intro film. -> the file's bytes."""
    from .cr2w_tree import Tree
    base, starting = WORLD_DEFS[world]
    t = Tree(depot.read(base))
    o = t.obj(1)
    worlds = o.get("worlds") or []
    imps = t.f.imports
    first = next((w for w in worlds if w.get("world") and world in imps[w.get("world") - 1][0].lower().split("\\")),
                 None)
    if first is not None:
        worlds.remove(first)
        worlds.insert(0, first)
    sp = Tree(depot.read(starting)).obj(1).get("startingPoint")
    if sp is not None:
        o.set("startingPoint", sp, "EngineTransform")
    o.props = [p for p in o.props if p.name != "newGameLoadingVideo"]
    mq = o.get("mainQuest")
    imps[mq - 1][0] = JUMP
    return t.to_bytes()


def build_mod(depot, game_dir, log=print):
    """Our starts into the game: <game>\\Mods\\modConjunctionSessions (a bundle of the jump quest and a definition per
    world). The game reads it at its start."""
    import shutil
    import tempfile
    from . import metastore, packer
    tmp = tempfile.mkdtemp(prefix="cj_sessions_")
    try:
        files = {JUMP: jump_quest(depot)}
        for world in WORLD_DEFS:
            files[world_def(world)] = world_definition(depot, world)
        for path, data in files.items():
            dest = os.path.join(tmp, path)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            open(dest, "wb").write(data)
        content = os.path.join(game_dir, "Mods", MOD, "content")
        os.makedirs(content, exist_ok=True)
        bundle = packer.pack(tmp, content)
        with open(os.path.join(content, "metadata.store"), "wb") as f:
            f.write(metastore.build([(os.path.basename(bundle), bundle)]))
        log(f"[sessions] {len(files)} files -> {content}")
        return sorted(files)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


WORLD_OF = {1: "novigrad", 9: "novigrad", 4: "prolog_village", 2: "skellige", 3: "kaer_morhen", 11: "bob"}
ENTRY_OF_ACT = {"Prologue": "prologue", "Act I": "part 1", "Act II": "part 2", "Act III": "part 3 after novi",
                "Epilogue": "epilogues"}
DONE = ("complet", "done", "finish", "_end", "success")


def plan(q, quests):
    """Where a jump to the story map's quest q goes: (world, story entry or None, facts). The world its region's
    (an expansion's own); the entry its act's in the base game (an expansion's quests start beside the story);
    the facts what it and every quest before it wait for, and the facts those set that read as 'done'.
    quests: {id: placed quest}."""
    world = WORLD_OF.get(q.get("world")) or ("bob" if q.get("game") == "Blood and Wine" else "novigrad")
    act = q.get("act")
    if not act and q.get("game") in ("The Witcher 3", "Free DLC"):     # a side quest: its main quests' act
        acts = [quests[b].get("act") for b in q.get("by", []) if b in quests and quests[b].get("act")]
        order = list(ENTRY_OF_ACT)
        act = max(acts, key=order.index) if acts else "Act I"
    entry = ENTRY_OF_ACT.get(act) if q.get("game") in ("The Witcher 3", "Free DLC") else None
    facts, seen, todo = set(q.get("gates") or []), {q["id"]}, list(q.get("by") or [])
    while todo:
        b = todo.pop()
        if b in seen or b not in quests:
            continue
        seen.add(b)
        before = quests[b]
        facts |= set(before.get("gates") or [])
        facts |= {f for f in before.get("sets") or [] if any(w in f.lower() for w in DONE)}
        todo += before.get("by") or []
    # not its own (its inner triggers - set, they would skip a part of it), no debug ones, no bare words
    own = (q.get("code") or os.path.basename(q.get("file") or "~").split("_")[0] or "~").lower()
    facts = {f for f in facts if "_" in f.strip("_") and not f.startswith("_") and not f.lower().startswith(own)}
    return world, entry, sorted(facts)


def jump(link, world, entry=None, facts=()):
    """A fresh session in a world of ours: at the story's entry `entry` (None: no story), with `facts` set (put on
    the game object first; the session's main quest sets them)."""
    link.exec("cj_session_clear()")
    for f in list(facts) + ([entry_fact(entry)] if entry else []):
        link.exec(f'cj_session_fact("{f}")')
    link.exec(f'cj_new_session("{world_def(world).replace(chr(92), "/")}")')
