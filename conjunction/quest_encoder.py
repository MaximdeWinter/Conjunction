"""Our own quest encoder (docs/VANILLA_EDITING_PLAN.md, R1 - radish's w2quest.exe replaced): the quest structure our
generator writes (definition.quest\\structure*.yml, radish's format) into the quest file the game reads, through
the lossless model (cr2w_tree). Each block type as radish wrote it (measured over every project's build:
_scratch/radish_reference.py, _scratch/radish_schema.py) - and the forms our build used to put back afterwards
written at once (a script block's parameters beside its arguments, the minigame blocks).

    encode(defdir, journals, ctx) -> the .w2quest bytes
        defdir      definition.quest (structure*.yml)
        journals    {journal file depot path: its bytes} - where objectives point (their entries' GUIDs)
        ctx         Ctx(quest id, dlc id, functions {name: [(param, type)]})

Block types (radish's names): start, end, waituntil (factdb / conditions / entered / looted / elapsed), objective,
questoutcome, journal, addfact, script, interaction, scene, changelayers, spawn, despawn, reward, randomize (a
stand-in our generator turns into a minigame: fistfight / gwent) - and the general ones (game blocks, any class
of the catalog) once they come.

Naming, as radish has it: an area's trigger tag <quest>_<world>_<area>_ar, a layer DLC\\<dlc>\\<quest>\\<layer>, a
spawn phase <quest>_<spawnset>_<phase>_ph, a reward <quest>_<reward>.
"""
import os
import re
import uuid

import yaml

from .cr2w_tree import Guid, Obj, Prop, Soft, Struct, Tags, Tree, Variant, Wide

BLOCK, CHILD, PATH = 8192, 8200, 0                  # export flags radish writes
CONN = "array:2,0,SCachedConnections"
WORLDS = {"velen": r"levels\novigrad\novigrad.w2w", "novigrad": r"levels\novigrad\novigrad.w2w",
          "skellige": r"levels\skellige\skellige.w2w", "kaer_morhen": r"levels\kaer_morhen\kaer_morhen.w2w",
          "kaermorhen": r"levels\kaer_morhen\kaer_morhen.w2w",
          "prologue": r"levels\prolog_village\prolog_village.w2w",
          "prologue_winter": r"levels\prolog_village_winter\prolog_village.w2w",
          "vizima": r"levels\wyzima_castle\wyzima_castle.w2w", "isle_of_mists": r"levels\island_of_mist\island_of_mist.w2w",
          "spiral": r"levels\the_spiral\spiral.w2w", "toussaint": r"dlc\bob\data\levels\bob\bob.w2w",
          "bob": r"dlc\bob\data\levels\bob\bob.w2w"}
# the game's world numbers (EAreaName) as radish writes them into a changeworld block (measured 05.10. with radish
# for every world it knows; Toussaint as the game's own blocks have it)
WORLD_IDS = {"novigrad": 1, "skellige": 2, "kaer_morhen": 3, "kaermorhen": 3, "prologue": 4, "vizima": 5,
             "isle_of_mists": 6, "spiral": 7, "prologue_winter": 8, "velen": 9, "toussaint": 11, "bob": 11}
COMPARE = {"=": "CF_Equal", "==": "CF_Equal", "!=": "CF_NotEqual", "<": "CF_Less", "<=": "CF_LessEqual",
           ">": "CF_Greater", ">=": "CF_GreaterEqual"}
# a link's input when the next list does not name one: what radish writes into each class
DEFAULT_PUT = {"CQuestSceneBlock": "Input", "CQuestInteractionDialogBlock": "Input", "CJournalQuestBlock": "Activate",
               "CJournalBlock": "Activate", "CQuestEndBlock": " ", "CQuestPhaseOutputBlock": " "}
SCRIPT_TYPES = {"int": "Int32", "float": "Float", "bool": "Bool", "name": "CName", "string": "String",
                "Int32": "Int32", "Float": "Float", "Bool": "Bool", "CName": "CName", "String": "String"}
TEMPLATE = r"quests\witcher3_quest.w2quest"        # a game quest file: the header our files start from


class Ctx:
    def __init__(self, quest, dlc, functions=None, template=None):
        self.quest, self.dlc = quest, dlc
        self.functions = functions or {}            # name -> [(param, script type)]
        self.template = template                    # bytes of a game quest file (its header)


def _guid():
    return Guid(uuid.uuid4().bytes)


def _items(nxt):
    """A next list -> [(block name, input or None)]."""
    if nxt is None:
        return []
    if isinstance(nxt, str):
        nxt = [nxt]
    out = []
    for x in nxt:
        if isinstance(x, dict):
            for k, v in x.items():
                out.append((k, v))
        elif x is not None:
            out.append((str(x), None))
    return out


class Encoder:
    def __init__(self, ctx, journals):
        self.ctx = ctx
        self.journals = journals
        self._jcache = {}
        self.t = Tree(ctx.template)
        self.t.objects = []
        self.t.f.imports = []

    # --- objects and values
    def add(self, cls, flags, parent, props):
        self.t.objects.append(Obj(cls, flags, parent, 0, [Prop(n, ty, v) for n, ty, v in props]))
        return len(self.t.objects)

    def imp(self, path, cls, flags=4):
        for k, (p, c, _f) in enumerate(self.t.f.imports, 1):
            if p == path and c == cls:
                return k
        self.t.f.imports.append([path, cls, flags])
        return len(self.t.f.imports)

    def journal_file(self, kind, quest=None):
        """The quest's journal file: 'quest' (its quest - a project's quest k: `quest`, <id>q<k>) or 'group' (its
        quest group)."""
        name = (quest or self.ctx.quest) if kind == "quest" else f"questgroup_{self.ctx.quest}"
        path = f"dlc/{self.ctx.dlc}/journal/quests/{name}.journal"
        if quest and kind == "quest" and not (self.journals.get(path) or self.journals.get(path.replace("/", "\\"))):
            return self.journal_file(kind)              # (no journal of its own: the project's)
        return path

    def journal_entries(self, path):
        """{baseName: (guid, class, parent guid)} of a journal file, read with the lossless model."""
        if path not in self._jcache:
            data = self.journals.get(path) or self.journals.get(path.replace("/", "\\"))
            entries = {}
            if data:
                jt = Tree(data)
                for o in jt.objects:
                    g = o.get("guid") if o.props else None
                    if isinstance(g, Guid):
                        entries.setdefault(o.get("baseName") or o.cls, (g, o.cls, o.get("parentGuid")))
                        entries.setdefault("@" + o.cls, (g, o.cls, o.get("parentGuid")))
            self._jcache[path] = entries
        return self._jcache[path]

    def path_chain(self, steps):
        """CJournalPath objects (no parent, as radish writes them): steps [(guid, resource path or None)]. -> the
        first one's number."""
        first = prev = None
        for g, res in steps:
            props = [("guid", "CGUID", g)]
            if res:
                props.append(("resource", "soft:CResource", Soft(self.imp(res, "CJournalResource"))))
            n = self.add("CJournalPath", PATH, 0, props)
            if prev is not None:
                self.t.obj(prev).props.append(Prop("child", "handle:CJournalPath", n))
            first = first or n
            prev = n
        return first

    def objective_path(self, ref):
        """'quest/phase/objective' (an objective) or 'quest' (the quest) -> a CJournalPath chain."""
        parts = ref.split("/")
        jf = self.journal_file("quest", parts[0])
        e = self.journal_entries(jf)
        quest = e.get("@CJournalQuest", (_guid(), None, None))[0]
        steps = [(quest, jf)]
        if len(parts) >= 2:
            steps.append((e.get(parts[1], (_guid(),))[0], None))
        if len(parts) >= 3:
            steps.append((e.get(parts[2], (_guid(),))[0], None))
        return self.path_chain(steps)

    def entry_path(self, ref, root=False):
        """A journal block's entry 'quests/<quest>/<entry>' -> the chain: (the quest group, when the block activates
        the root too,) the quest, its description group, the entry."""
        parts = ref.split("/")
        gf, jf = self.journal_file("group"), self.journal_file("quest", parts[1] if len(parts) >= 3 else None)
        g, e = self.journal_entries(gf), self.journal_entries(jf)
        steps = [(g.get("@CJournalQuestGroup", (_guid(),))[0], gf)] if root else []
        steps.append((e.get("@CJournalQuest", (_guid(),))[0], jf))
        if len(parts) >= 3:
            entry = e.get(parts[-1])
            group = e.get("@CJournalQuestDescriptionGroup")
            if group:
                steps.append((group[0], None))
            steps.append(((entry or (_guid(),))[0], None))
        return self.path_chain(steps)

    def layer(self, name):
        return f"DLC\\{self.ctx.dlc}\\{self.ctx.quest}\\{name}"

    def world(self, name):
        return WORLDS.get(str(name).lower(), str(name))

    def area_tag(self, ref):
        world, _, area = str(ref).partition("/")
        return f"{self.ctx.quest}_{world}_{area}_ar"

    def game_path(self, where, parent):
        """A journal entry of the game's quests: its path copied from where a quest file names it (journal_index:
        {file, obj}) - as the game wrote it, its GUIDs kept -> the path's first object."""
        from .bundles import Depot
        src = Tree(Depot().read(where["file"]))
        chain, k = [], int(where["obj"])
        while isinstance(k, int) and k > 0 and src.obj(k).cls == "CJournalPath" and k not in chain:
            chain.append(k)
            k = src.obj(k).get("child")
        if not chain:
            raise ValueError(f"no journal path at {where}")
        return self.t.adopt_many(src, chain, parent=parent)[0]

    # --- conditions
    def condition(self, parent, spec, name=None):
        """One condition under a wait block: factdb / entered / left, outside / inside / looted / elapsed / journal /
        period / present / combat, or several (all / any / nor) -> its number."""
        props = [("name", "CName", name)] if name else []
        if "factdb" in spec:
            fact, op, value = spec["factdb"]
            return self.add("CQuestFactsDBCondition", CHILD, parent, props + [
                ("factId", "String", str(fact)), ("value", "Int32", int(value)),
                ("compareFunc", "ECompareFunc", COMPARE.get(str(op), "CF_Equal"))])
        if "entered" in spec:
            return self.add("CQuestEnterTriggerCondition", CHILD, parent,
                            props + [("triggerTag", "CName", self.area_tag(spec["entered"]))])
        if "left" in spec or "outside" in spec:         # (out of the area: inside it, no)
            ref = spec.get("left") or spec.get("outside")
            return self.add("CQuestInsideTriggerCondition", CHILD, parent,
                            props + [("triggerTag", "CName", self.area_tag(ref)), ("isInside", "Bool", False)])
        if "inside" in spec:                            # the player (or `who`) in the area - now, not only stepping in
            return self.add("CQuestInsideTriggerCondition", CHILD, parent,
                            props + [("triggerTag", "CName", self.area_tag(spec["inside"]))] +
                            ([("tag", "CName", str(spec["who"]))] if spec.get("who") else []))
        if "journal" in spec:                           # a quest's (an objective's) state: its path as the game has it
            n = self.add("CQuestJournalStatusCondition", CHILD, parent, props + [
                ("entry", "handle:CJournalPath", 0), ("status", "EJournalStatus", str(spec.get("status") or
                                                                                     "JS_Success"))]
                         + ([("inverted", "Bool", True)] if spec.get("inverted") else []))
            self.t.obj(n).set("entry", self.game_path(spec["journal"], n), "handle:CJournalPath")
            return n
        if "period" in spec:                            # the time of day, from - to (past midnight too)
            fr, to = spec["period"]
            return self.add("CQuestTimePeriodCondition", CHILD, parent, props + [
                ("fromTime", "GameTime", Struct([Prop("m_seconds", "Int32", int(fr))])),
                ("toTime", "GameTime", Struct([Prop("m_seconds", "Int32", int(to))]))])
        if "present" in spec:                           # someone with the tag is there (spawned)
            return self.add("CQuestTagsPresenceCondition", CHILD, parent,
                            props + [("tags", "TagList", Tags(str(t) for t in spec["present"]))])
        if "combat" in spec:                            # the player fighting (or not)
            return self.add("CQuestInCombatCondition", CHILD, parent,
                            props + ([] if spec["combat"] else [("isInCombat", "Bool", False)]))
        for key, op in (("all", None), ("any", "LO_Or"), ("nor", "LO_Nor")):
            if key in spec:                             # several: the game's logic condition
                n = self.add("CQuestLogicOperationCondition", CHILD, parent, props + (
                    [("logicOperation", "ELogicOperation", op)] if op else []) + [
                    ("conditions", "array:2,0,ptr:IQuestCondition", [])])
                self.t.obj(n).set("conditions", [self.condition(n, x) for x in spec[key]])
                return n
        if "looted" in spec:
            return self.add("CQuestInteractionCondition", CHILD, parent, props + [
                ("interactionName", "String", "Loot"), ("ownerTags", "TagList", Tags([str(spec["looted"]).lstrip("~")]))])
        if "elapsed" in spec:
            h, m, s = (int(x) for x in str(spec["elapsed"]).split(":"))
            return self.add("CQuestHiResRealtimeDelayCondition", CHILD, parent, props + [
                ("hours", "Uint32", h), ("minutes", "Uint32", m), ("seconds", "Uint32", s)])
        raise ValueError(f"a condition this encoder does not know: {spec}")

    # --- blocks
    def block(self, graph, name, body):
        kind, _, short = name.partition(".")
        body = body or {}
        named = [("name", "String", short)] if short else []
        conn = [("cachedConnections", CONN, [])]       # (filled when linking; dropped when empty)
        c = None
        if kind == "start":
            return self.add("CQuestStartBlock", BLOCK, graph, [("guid", "CGUID", _guid())] + conn)
        if kind == "end":
            return self.add("CQuestEndBlock", BLOCK, graph, [("guid", "CGUID", _guid())])
        if kind == "waituntil":
            n = self.add("CQuestPauseConditionBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn +
                         [("conditions", "array:2,0,ptr:IQuestCondition", [])])
            conds = body.get("conditions")
            made = [self.condition(n, v, str(k)) for k, v in conds.items()] if conds else [self.condition(n, body)]
            self.t.obj(n).set("conditions", made)
            return n
        if kind in ("objective", "questoutcome"):
            ref = body.get("objective") or body.get("quest")
            path = self.objective_path(ref if kind == "objective" else ref.split("/")[0])
            props = named + [("guid", "CGUID", _guid())] + conn + [
                ("questEntry", "handle:CJournalPath", path), ("showInfoOnScreen", "Bool", True)]
            if kind == "objective":
                props.append(("track", "Bool", bool(body.get("track"))))
            return self.add("CJournalQuestBlock", BLOCK, graph, props)
        if kind == "journal":
            return self.add("CJournalBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn + [
                ("entry", "handle:CJournalPath", self.entry_path(body["entry"], bool(body.get("activate_root")))), ("showInfoOnScreen", "Bool", True)])
        if kind == "addfact":
            fact, value = body["value"]
            return self.add("CQuestFactsDBChangingBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn + [
                ("factID", "String", str(fact)), ("value", "Int32", int(value))])
        if kind == "script":
            return self.script(graph, named, conn, body)
        if kind == "interaction":
            return self.add("CQuestInteractionDialogBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn +
                            [("scene", "soft:CStoryScene", Soft(self.imp(body["scene"], "CStoryScene"))),
                             ("actorTags", "TagList", Tags(str(a) for a in body.get("actor") or [])),
                             ("interrupt", "Bool", True)])
        if kind == "scene":
            return self.add("CQuestSceneBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn + [
                ("scene", "soft:CStoryScene", Soft(self.imp(body["scene"], "CStoryScene"))),
                ("interrupt", "Bool", True), ("shouldFadeOnLoading", "Bool", False)])
        if kind == "changelayers":
            props = named + [("guid", "CGUID", _guid())] + conn
            if body.get("world"):
                props.append(("world", "String", self.world(body["world"])))
            if body.get("show"):
                props.append(("layersToShow", "array:2,0,String", [self.layer(x) for x in body["show"]]))
            if body.get("hide"):
                props.append(("layersToHide", "array:2,0,String", [self.layer(x) for x in body["hide"]]))
            return self.add("CQuestLayersHiderBlock", BLOCK, graph, props)
        if kind in ("spawn", "despawn"):
            n = self.add("CQuestStoryPhaseSetterBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn +
                         [("spawnsets", "array:2,0,ptr:IQuestSpawnsetAction", [])])
            made = []
            for s in body.get("spawnsets") or []:
                comm = f"dlc/{self.ctx.dlc}/data/spawnsets/{s}.w2comm"
                if kind == "spawn":
                    made.append(self.add("CActivateStoryPhase", CHILD, n, [
                        ("spawnset", "soft:CCommunity", Soft(self.imp(comm, "CCommunity"))),
                        ("phase", "CName", f"{self.ctx.quest}_{s}_{body.get('phase', 'main')}_ph")]))
                else:
                    made.append(self.add("CDeactivateSpawnset", CHILD, n, [
                        ("spawnset", "handle:CCommunity", -self.imp(comm, "CCommunity"))]))
            self.t.obj(n).set("spawnsets", made)
            return n
        if kind == "reward":
            return self.add("CQuestRewardBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn + [
                ("rewardName", "CName", f"{self.ctx.quest}_{body['reward']}")])
        if kind == "randomize":
            return self.add("CQuestRandomBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn)
        if kind == "changeworld":                   # travel: into a world, onto the quest's waypoint there
            world, _, wp = str(body["destination"]).partition("/")
            key = world.lower()
            if key not in WORLD_IDS:
                raise ValueError(f"travel into a world the game does not know: {world}")
            return self.add("CQuestChangeWorldBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn + [
                ("worldFilePath", "String", self.world(world)), ("newWorld", "Int32", WORLD_IDS[key]),
                ("targetTag", "TagList", Tags([f"{self.ctx.quest}_{world}_{wp}_wp"]))])
        raise ValueError(f"a block this encoder does not know: {name}")

    def script(self, graph, named, conn, body):
        fn = str(body["function"])
        sig = dict(self.ctx.functions.get(fn) or [])
        params, args = [], []
        for item in body.get("parameter") or []:
            for pname, value in (item.items() if isinstance(item, dict) else []):
                if isinstance(value, str) and value.startswith("cname_"):     # (radish's way to say: a CName)
                    typ, value = "CName", value[len("cname_"):]
                elif isinstance(value, str) and value.startswith("enum:"):     # an enum by its value's name
                    _e, typ, value = value.split(":", 2)
                else:
                    typ = SCRIPT_TYPES.get(sig.get(pname), None) or _guess_type(value)
                v = _typed(typ, value)
                params.append(Struct([Prop("name", "CName", str(pname)), Prop("value", "CVariant", Variant(typ, v))]))
                args.append(Prop(str(pname), typ, v))
        n = self.add("CQuestScriptBlock", BLOCK, graph, named + [("guid", "CGUID", _guid())] + conn + [
            ("functionName", "CName", fn), ("parameters", "array:2,0,QuestScriptParam", params)])
        self.t.obj(n).args = args
        return n

    # --- links
    def link(self, graph_blocks, name, body, n):
        """The block's next lists into its cachedConnections: next (its single output) and next.<socket>."""
        o = self.t.obj(n)
        conns = []
        outs = [(k, v) for k, v in (body or {}).items() if k == "next" or k.startswith("next.")]
        for key, nxt in outs:
            socket = key[5:] if key.startswith("next.") else _default_out(o.cls)
            blocks = []
            for target, put in _items(nxt):
                if target.startswith("."):              # (".done": the quest's end - radish keeps no link)
                    continue
                to = graph_blocks.get(target)
                if to is None:
                    continue
                cls = self.t.obj(to).cls
                blocks.append(Struct([Prop("ock", "ptr:CQuestGraphBlock", to),
                                      Prop("putName", "CName", put if put is not None else
                                           DEFAULT_PUT.get(cls, "In"))]))
            if blocks:
                conns.append(Struct(([Prop("socketId", "CName", socket)] if socket is not None else []) +
                                    [Prop("blocks", "array:2,0,SBlockDesc", blocks)]))
        if conns:
            o.set("cachedConnections", conns)
        else:
            o.props = [p for p in o.props if p.name != "cachedConnections"]

    # --- the whole quest
    def encode(self, structure):
        quest = self.add("CQuest", BLOCK, 0, [("graph", "ptr:CQuestGraph", 0)])
        graph = self.add("CQuestGraph", BLOCK, quest, [("graphBlocks", "array:2,0,ptr:CGraphBlock", []),
                                                       ("sourceDataRemoved", "Bool", True)])
        self.t.obj(quest).set("graph", graph)
        blocks, bodies = {}, {}
        for _segment, seg in (structure.get("structure") or {}).items():
            for name, body in ((seg or {}).get("blocks") or {}).items():
                blocks[name] = self.block(graph, name, body)
                bodies[name] = body
        for name, n in blocks.items():
            self.link(blocks, name, bodies[name], n)
        self.t.obj(graph).set("graphBlocks", list(blocks.values()))
        return self.t.to_bytes()


def _default_out(cls):
    if cls == "CQuestPauseConditionBlock":
        return None
    if cls in ("CQuestStartBlock", "CQuestPhaseInputBlock"):
        return " "
    return "Out"


def _guess_type(value):
    if isinstance(value, bool):
        return "Bool"
    if isinstance(value, int):
        return "Int32"
    if isinstance(value, float):
        return "Float"
    return "String"


def _typed(typ, value):
    if typ == "Int32":
        return int(value)
    if typ == "Float":
        return float(value)
    if typ == "Bool":
        return bool(value)
    if typ == "String":
        s = str(value)
        return s if all(ord(c) < 256 for c in s) else Wide(s)
    return str(value)


def script_functions(roots):
    """{quest function name: [(param, type)]} from the scripts under the roots (the game's, Conjunction's)."""
    from .game_catalog import parse_scripts
    out = {}
    for root in roots:
        if os.path.isdir(root):
            funcs, _classes, _enums = parse_scripts(root)
            for name, f in funcs.items():
                out[name] = [(p["name"], p["type"]) for p in f["params"]]
    return out


def encode(defdir, journals, ctx):
    """The quest file of a definition: its structure encoded, then the stand-ins our generator wrote (gwent, fist
    fights, stopped lanes, follow - definition.minigames.yml beside the definition) made the game's blocks."""
    structure = {"structure": {}}
    for f in sorted(os.listdir(defdir)):
        if re.match(r"structure.*\.yml$", f):
            d = yaml.safe_load(open(os.path.join(defdir, f), encoding="utf-8")) or {}
            structure["structure"].update(d.get("structure") or {})
    data = Encoder(ctx, journals).encode(structure)
    spec_file = os.path.join(os.path.dirname(os.path.abspath(defdir)), "definition.minigames.yml")
    if os.path.exists(spec_file):
        from . import minigames
        spec = yaml.safe_load(open(spec_file, encoding="utf-8")) or {}
        data, _done = minigames.apply_data(data, {k: v for k, v in spec.items() if v.get("game") != "path"})
    return data
