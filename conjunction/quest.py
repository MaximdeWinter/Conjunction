"""Quest building blocks: a quest is a list of steps; each step becomes radish blocks (structure), journal objectives
and meta entities (trigger areas, map pins).

    quest:
      title: The bandit camp
      description: Villagers talk about bandits in the woods north of the city.
      steps:
        - goto: {place: camp, radius: 15, text: Find the bandit camp}     # map: pin | area, map_radius: 60
        - loot: {object: camp/strongbox, text: Search the strongbox}
        - show: {place: camp_after}
        - wait: {time: "00:00:30"}
        - fact: {name: bandits_done, value: 1}

A step type is a class with `name`, `generate(ctx, i, step)` -> StepOut (see below). Plugins add their own
(`api.add_block("play_scene", PlaySceneStep)`). Objects are referenced as `<place>/<object id>`; an object gets an
id in the editor (select it, name it) and becomes tagged `<quest id>_<place>_<object id>` in the game.
"""
import math
import re
import os

from .quest_nodes import (REPEATABLE, START, is_graph, links_from, migrate, order, path_fact, ports,  # noqa: F401
                          repeat_of, safe)

QUEST_TYPES = {"main": "MainQuest", "secondary": "SideQuest", "side": "SideQuest", "monsterhunt": "MonsterHunt",
               "treasurehunt": "TreasureHunt"}


class StepOut:
    """What one step adds: the blocks that run it (`first` is linked from the step before, `last` links onward)."""

    def __init__(self, blocks, first, last, objective=None, meta=None, scenes=None, branches=None, counter=None):
        self.blocks = blocks                # {"<type>.<name>": {...}} without the final `next` of `last`
        self.first, self.last = first, last
        self.objective = objective          # {"id", "caption", "mappins": [...]} for the journal, or None
        self.meta = meta or {}              # {world: {"areas": {...}, "mappins": {...}}}
        self.scenes = scenes or {}          # {name: radish scene definition} (dialogues)
        # outputs of `last` and where they lead: {socket: "continue" | "retry" | "fail"} (dialogue choices)
        self.branches = branches or {}
        # (fact, n): the objective counts - `last` is a wait for fact >= n, replaced by a chain of objectives
        self.counter = counter


ACTOR_CLASSES = {"CNewNPC", "W3MerchantNPC", "W3MonsterHuntNPC", "W3NPCBackground", "CGhost"}
_actor_class = {}


def template_class(template):
    """The entity class the catalog read from the template ('' when the catalog does not know it)."""
    t = template.lower()
    if t not in _actor_class:
        import sqlite3
        from .assets import DB
        try:
            con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
            r = con.execute("select class from templates where path = ?", (t,)).fetchone()
            con.close()
        except sqlite3.Error:
            r = None
        _actor_class[t] = (r[0] or "") if r else ""
    return _actor_class[t]


def is_actor(obj):
    """People, monsters and animals are not statics: they come as a community (spawned, standing at an action
    point, can be talked to or fought - Maxim 01.10.: a wolf placed for a Kill was 'not a creature'). The class
    decides (a merchant under living_world is a W3MerchantNPC), the path where the catalog does not know it."""
    if "actor" in obj:
        return bool(obj["actor"])
    cls = template_class(obj["template"])
    if cls:
        return cls in ACTOR_CLASSES
    from .catalog import kind_of
    return kind_of(obj["template"].lower()) in ("NPC", "Monster", "Animal")


SPOT_MARKER = "dlc\\bob\\data\\environment\\decorations\\gameplay\\flags_banners\\flag_racing_b.w2ent"


def has_statics(place):
    """A place gets a layer only for its things (its NPCs come as a community; spot markers only in the editor;
    trails mostly come with the clue step that shows them)."""
    return any(not is_actor(o) and not o.get("marker") and not o.get("trail") for o in place.get("objects", []))


def spot_rings(q, project, place):
    """[(position, radius, map radius or None)] of every Go to whose spot (or point) is in `place` - the editor
    draws them around the marker."""
    out = []

    def walk(x):
        if isinstance(x, dict):
            for k, v in x.items():
                if k == "goto" and isinstance(v, dict):
                    pos = None
                    if v.get("at"):
                        pl, _, oid = v["at"].partition("/")
                        o = next((o for o in project.places.get(pl, {}).get("objects", []) if o.get("id") == oid), None)
                        pos = o["pos"] if o and pl == place else None
                    elif v.get("pos") and v.get("place", place) == place:
                        pos = v["pos"]
                    if pos:
                        r = float(v.get("radius", 10))
                        out.append((pos, r, None if v.get("map") == "pin" else float(v.get("map_radius") or r)))
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(q)
    return out


def kill_targets(q):
    """{place/id} of everyone a Kill step targets (anywhere in the quest - also a goal among 'either' options)."""
    out = set()

    def walk(x):
        if isinstance(x, dict):
            k = x.get("kill")
            if isinstance(k, dict):
                out.update(r for r in (k.get("targets") or []) if r)
                if k.get("target"):
                    out.add(k["target"])
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(q or {})
    return out


def idle_action(template):
    t = template.lower()
    return "idle_woman/stand_mwdc_idle_jt" if any(w in t for w in ("woman", "female", "girl", "_f_")) \
        else "idle_man/stand_mwdc_idle_jt"


def idspace(qid):
    """The quest's own range of string ids (radish: 1000 per space; Conjunction's DLCs use 9998 / 9999)."""
    import zlib
    return 1000 + zlib.crc32(qid.encode("utf-8")) % 8000


class Ctx:
    def own_items(self):
        """The quest's own items {id: {name, ...}} (their names in the journal lines made from a step) - all the
        project's quests'."""
        return getattr(self, "_items", None) or (self.project.meta.get("quest") or {}).get("items") or {}

    def __init__(self, project, q=None):
        self.project = project
        self.qid = project.id
        self.names = display_names(project)     # what journal lines call people (their name above them)
        self.idspace = idspace(self.qid)
        self.next_string = 200              # 0..199: the journal; scenes take theirs from here on
        self.speech = []                    # own recordings of the dialogues: [{"id", "text", "source", "lang"}]
        self.extra_meta = {}                # meta entities steps add besides their own (scene points of comments)
        self.moved = {}                     # {place/id: (pos, yaw)} where a person stands after a step moved them
        self.characters = {}                # people's journal pages {id: {name, group, image, description}}
        self.rewards = {}                   # radish reward definitions {id: [items]} (reward steps)
        self.minigames = {}                 # gwent stand-ins {block name: {deck, difficulty}} (minigames.py)
        self.keyed = []                     # texts the game asks for by key (a notice's): [(id, key, text)]
        self.layers = {}                    # layers of the steps' own (a clue entry's trail, examine point): hidden first
        self.own_entities = {}              # entity templates built into the DLC (the examine point)
        self.trails_in_steps = set()        # trails a step shows (not part of their place's layer)
        self.descriptions = []              # journal paragraphs added by note steps [{id: text}]
        self.foes = {}                      # kill targets {reference: their own community} - spawned by their step
        q = q if q is not None else project.meta.get("quest") or {}
        self._items = q.get("items") or {}
        self.graph = is_graph(q)
        self.start_as = q.get("player") or "geralt"   # who is played when the quest starts (dialogue.PLAYERS)
        self.played = characters(q)                 # who is played at each step ('playas' switches)

    def character(self, s):
        """Who is played at the step with these arguments."""
        return self.played.get(id(s), self.start_as)

    def strings(self, n):
        """The first of n string ids for a scene (all scenes of a quest share its id space)."""
        start = self.next_string
        self.next_string += n
        if self.next_string > 1000:
            raise ValueError("The quest's dialogues have more than 800 lines. Please split it into two quests")
        return start

    def keyed_string(self, key, text):
        """A text the game finds by its key (GetLocStringByKeyExt: a notice board's notices) - into the quest's
        strings."""
        self.keyed.append((2110000000 + self.idspace * 1000 + self.strings(1), key, text))

    def place_world(self, place):
        p = self.project.places.get(place)
        if not p or not p.get("world"):
            raise ValueError(f"Location '{place}' is still empty (its world is unknown)")
        return p["world"]

    def place_center(self, place):
        objs = self.project.places.get(place, {}).get("objects", [])
        if not objs:
            raise ValueError(f"Location '{place}' has no objects. A Go to step needs a position")
        return [sum(o["pos"][i] for o in objs) / len(objs) for i in range(3)]

    def object(self, ref):
        place, _, oid = ref.partition("/")
        for o in self.project.places.get(place, {}).get("objects", []):
            if o.get("id") == oid:
                return o
        raise ValueError(f"Object '{ref}' not found. Select it in the editor and give it a name")

    def object_tag(self, ref):
        """`camp/strongbox` -> the tag its static (or NPC) gets (checked: the object exists)."""
        self.object(ref)
        place, _, oid = ref.partition("/")
        return f"{self.qid}_{place}_{oid}"


def _pin(ctx, i, refs, radius=3.0):
    """A map pin on objects of the step (the middle of several; the circle takes in all of them, creatures move)
    -> (meta, objective fields). Every step Geralt has to go somewhere for gets one - without it the map and the
    minimap show nothing and a player who walked away never finds the spot again."""
    objs = [ctx.object(r) for r in refs]
    world = ctx.place_world(refs[0].partition("/")[0])
    center = [round(sum(float(o["pos"][k]) for o in objs) / len(objs), 3) for k in range(3)]
    spread = max(math.dist(center[:2], [float(v) for v in o["pos"][:2]]) for o in objs)
    pin = f"{ctx.qid}_s{i}_pin"
    return ({world: {"mappins": {pin: center}}},
            {"mappins": [[pin, round(max(radius, spread + 5.0) if len(objs) > 1 else radius, 1)]],
             "world": world})


def _area(center, radius, height=6.0, corners=8):
    x, y, z = center
    return {"borderpoints": [[round(x + radius * math.cos(2 * math.pi * k / corners), 3),
                              round(y + radius * math.sin(2 * math.pi * k / corners), 3), round(z - 2.0, 3)]
                             for k in range(corners)], "height": height}


# go to only at a time of day: the hours [from, to)
WHEN = {"morning": (5, 10), "day": (7, 19), "evening": (18, 22), "night": (22, 5)}


def hours(when):
    """'night' / 'morning' / ... or '21-3' -> (from, to); nothing -> (0, 0): any time."""
    if not when:
        return 0, 0
    if when in WHEN:
        return WHEN[when]
    a, _, b = str(when).partition("-")
    return int(a) % 24, int(b or a) % 24


class Goto:
    """goto: {place | world + pos, radius, text, map: pin | area, map_radius,
              when: night | day | morning | evening | "21-3", stay: true}
    when: arriving counts only in those hours (early: wait there); stay: leaving again before that fails the quest."""
    name = "goto"

    def generate(self, ctx, i, s):
        mode = s.get("mode") or "arrive"
        if mode == "near":                              # near a person, wherever they are now (Keira test)
            if not s.get("who"):
                raise ValueError(f"step {i}: go to - near whom? (the card: who)")
            fact, run, wait = f"{ctx.qid}_s{i}_near", f"script.s{i}_near", f"waituntil.s{i}"
            blocks = {run: {"function": "CjNearTo", "parameter": [
                {"tag": f"cname_{ctx.object_tag(s['who'])}"}, {"radius": float(s.get("radius", 5))},
                {"fact": fact}], "next": [wait]},
                wait: {"factdb": [fact, "=", 1]}}
            return StepOut(blocks, run, wait, {"caption": s.get("text", "Go to them")})
        if mode == "look":                              # look at someone / something for some seconds (q104)
            if not s.get("who"):
                raise ValueError(f"step {i}: look at - whom or what? (the card: who)")
            fact, run, wait = f"{ctx.qid}_s{i}_look", f"script.s{i}_look", f"waituntil.s{i}"
            blocks = {run: {"function": "CjLookAt", "parameter": [
                {"tag": f"cname_{ctx.object_tag(s['who'])}"}, {"seconds": float(s.get("seconds", 3))},
                {"radius": float(s.get("radius", 20))}, {"fact": fact}], "next": [wait]},
                wait: {"factdb": [fact, "=", 1]}}
            return StepOut(blocks, run, wait, {"caption": s.get("text", "Watch them")})
        if s.get("at"):                                 # the spot marker: where it stands now
            place, _, oid = s["at"].partition("/")
            o = next((o for o in ctx.project.places.get(place, {}).get("objects", []) if o.get("id") == oid), None)
            if o is None:
                raise ValueError(f"step {i}: its spot ({s['at']}) is gone - set it again")
            s = dict(s, place=place, pos=o["pos"])
        if "place" in s:
            world, center = ctx.place_world(s["place"]), s.get("pos") or ctx.place_center(s["place"])
        else:
            world, center = s["world"], s["pos"]
        area, pin = f"{ctx.qid}_s{i}_area", f"{ctx.qid}_s{i}_pin"
        radius = float(s.get("radius", 10))
        meta = {world: {"areas": {area: _area(center, radius)}, "mappins": {pin: [round(v, 3) for v in center]}}}
        wait = f"waituntil.s{i}"
        # on the map: an exact pin (radius 0), or a search area - by default the circle that ends the step, or a
        # bigger one to search in ("somewhere around here")
        shown = 0.0 if s.get("map") == "pin" else float(s.get("map_radius") or radius)
        objective = {"caption": s.get("text", "Go there"), "mappins": [[pin, shown]], "world": world}
        if mode == "leave":                             # away from the spot: farther than the radius
            fact, run = f"{ctx.qid}_s{i}_away", f"script.s{i}_away"
            blocks = {run: {"function": "CjAwayFrom", "parameter": [
                {"x": float(center[0])}, {"y": float(center[1])}, {"z": float(center[2])}, {"radius": radius},
                {"fact": fact}], "next": [wait]},
                wait: {"factdb": [fact, "=", 1]}}
            del meta[world]["areas"]
            objective["caption"] = s.get("text", "Get away from there")
            return StepOut(blocks, run, wait, objective, meta)
        if s.get("when") or s.get("stay"):
            # the script watches distance and hour (conjunction_quest.ws CjGoAt) and says how it ended in a fact
            fr, to = hours(s.get("when"))
            fact, go = f"{ctx.qid}_s{i}_go", f"script.s{i}_go"
            del meta[world]["areas"]
            blocks = {go: {"function": "CjGoAt", "parameter": [
                {"x": float(center[0])}, {"y": float(center[1])}, {"z": float(center[2])}, {"radius": radius},
                {"fromHour": fr}, {"toHour": to}, {"stay": bool(s.get("stay"))}, {"fact": fact}]}}
            if not s.get("stay"):
                return StepOut(blocks, go, go, objective, meta)
            decide = f"waituntil.s{i}_go"
            blocks[go]["next"] = [decide]
            blocks[decide] = {"conditions": {"arrived": {"factdb": [fact, "=", 1]},
                                             "left": {"factdb": [fact, "=", 2]}}}
            return StepOut(blocks, go, decide, objective, meta, branches={"arrived": "continue", "left": "fail"})
        return StepOut({wait: {"entered": f"{world}/{area}"}}, wait, wait, objective, meta)


class Interact:
    """loot / examine / use an object of a place (containers are looted, clues examined, levers used)."""

    def __init__(self, name, condition, default_text):
        self.name, self.condition, self.default_text = name, condition, default_text

    def generate(self, ctx, i, s):
        tag = ctx.object_tag(s["object"])
        meta, where = _pin(ctx, i, [s["object"]])          # on the map: the thing to loot / examine / use
        if self.name == "use" and s.get("state") in ("on", "off"):
            # a lever / button: until it stands on (or off) - its real state
            b = f"script.s{i}_switch"
            return StepOut({b: {"function": "CjWaitSwitch", "parameter": [{"tag": f"cname_{tag}"},
                                                                          {"on": s["state"] == "on"}]}},
                           b, b, {"caption": _caption(ctx, "use", s),
                                  **where},
                           meta)
        if self.name == "use" and s.get("item"):
            # use an item on it (a key on a lock, a gear in a mechanism): first Geralt must carry it (the collect
            # check, repeated), then using the object takes the item
            count = int(s.get("count", 1))
            fact = f"{ctx.qid}_s{i}_have"
            check, decide, pause = f"script.s{i}_check", f"waituntil.s{i}_have", f"waituntil.s{i}_later"
            used, take = f"waituntil.s{i}", f"script.s{i}_take"
            blocks = {
                check: dict(item_call(ctx, "CjHasItems", s["item"], count=count, fact=fact), next=[decide]),
                decide: {"conditions": {"have": {"factdb": [fact, "=", 1]}, "notyet": {"factdb": [fact, "=", 0]}},
                         "next.notyet": [pause], "next.have": [used]},
                pause: {"elapsed": "00:02:00", "next": [check]},
                used: {"used": f"~{tag}", "next": [take]},
                take: item_call(ctx, "CjPlayerItem", s["item"], count=-count)}
            return StepOut(blocks, check, take,
                           {"caption": _caption(ctx, "use", s),
                            **where}, meta)
        template = ctx.object(s["object"]).get("template") or ""
        plain = (self.name == "examine" and not is_clue_template(template)) or             (self.name == "use" and not s.get("item") and s.get("state") not in ("on", "off")
             and not usable(template)) or             (self.name == "loot" and not s.get("item") and not lootable(template))
        if plain:
            # nothing in it answers "examined" / "used" / "looted" (a crate to examine, a barrel to use, a statue to
            # loot) - waited for forever (02.10. in the game: E opened the crate's loot). An examine point beside it,
            # as a clue of Find clues has
            out = Clues().generate(ctx, i, {"clues": [{"object": s["object"], "how": s.get("how")}]})
            out.objective = {"caption": _caption(ctx, self.name, s), **where}
            out.meta = meta
            return out
        if self.name == "loot" and s.get("item"):
            # take this item out of it (it is put in once, at the start): done when Geralt carries it - the
            # collect check, so a saved game resumes it
            out = Collect().generate(ctx, i, {"item": s["item"], "count": s.get("count", 1),
                                              "more_items": s.get("more_items") or [],
                                              "keep_in": s["object"]})
            out.objective = {"caption": _caption(ctx, "loot", s), **where}
            out.meta = meta
            return out
        wait = f"waituntil.s{i}"
        return StepOut({wait: {self.condition: f"~{tag}"}}, wait, wait,
                       {"caption": s.get("text", self.default_text), **where}, meta)


class Talk:
    """talk to an NPC of a place: a dialogue tree (dialogue.py: lines, choices, voices, gestures, moods), then onward;
    answers that end it may let the quest go on, come back later, fail or lead into a path.

        - talk: {npc: village/elder, text: Talk to the elder, dialogue: [{who: npc, text: Witcher!}, ...],
                 start: interact | near | calls, radius: 6, call: [{who: npc, text: "Witcher! Over here!"}]}

    start interact: the player presses E at the NPC; near: the talk starts by itself when Geralt comes within
    `radius`; calls: then the NPC calls out (subtitles, the game goes on) and waits for E; now: right away when the
    step comes (a cutscene - no objective)."""
    name = "talk"

    @staticmethod
    def scene(ctx, i, name, lines, npc, tag, fact, extras=(), gameplay=False, character=None, poses=None, cams=None,
              stands=None, placement="PLAYER", cam_defaults=None, marks=None, props=None):
        """The radish scene of a dialogue -> (scene, ways out); its lines' audio goes to ctx.speech."""
        from . import dialogue
        from .speech import text_timing
        own = len(dialogue.custom_voiced(lines))
        first_own = ctx.strings(own) if own else 0
        own_ids = iter(2110000000 + ctx.idspace * 1000 + first_own + k for k in range(own))
        new_speech = []
        scene, ends = dialogue.to_scene(lines, npc["template"] if npc else None, tag, i, ctx.idspace,
                                        ctx.strings(dialogue.string_count(lines)), fact, own_ids, new_speech,
                                        extras=extras, own_item=lambda item: own_item(ctx, item),
                                        character=character or ctx.start_as, qid=ctx.qid, poses=poses,
                                        gameplay=gameplay, cams=cams, stands=stands, placement=placement,
                                        cam_defaults=cam_defaults, marks=marks, props=props)
        # lines without a voice: as long as radish times their phonemes (the mouth moves to the text)
        timing = text_timing([e for e in new_speech if not e["source"]])
        for e in new_speech:
            if e["id"] in timing:
                e["dur"] = timing[e["id"]]
        _put_durations(scene, timing)
        dialogue.fit_gestures(scene)            # a gesture longer than its line ends with it, blended out
        ctx.speech += new_speech
        if gameplay:                            # lines as subtitles, no cameras: the player keeps control
            scene["production"]["gameplay"] = True
            scene["production"]["assets"].pop("cameras", None)
            scene["storyboard"].pop("defaults", None)
        return scene, ends

    def generate(self, ctx, i, s):
        from . import dialogue
        ref = s["npc"] if s.get("npc") else None
        if not ref:
            raise ValueError(f"step {i}: talk - to whom? (Pick, Search or Create on the card)")
        npc = ctx.object(ref)
        if ref in getattr(ctx, "moved", {}):
            # a step before moved them (Follow, Walk to, Stands): the talk where they are then - the trigger area,
            # the scene point, the pin (02.10.: 'near' waited at the blacksmith's first spot, he stood at the way's end)
            pos, yaw = ctx.moved[ref]
            npc = dict(npc, pos=[float(v) for v in pos[:3]], rot=[0.0, 0.0, float(yaw)])
        place, _, _oid = ref.partition("/")
        world, tag = ctx.place_world(place), ctx.object_tag(ref)
        name = f"{ctx.qid}_s{i}"
        fact = f"{ctx.qid}_s{i}_choice"
        lines = dialogue.from_step(s) or [{"who": "npc", "text": "..."}]
        extras = [(w["who"], ctx.object(w["who"])["template"], ctx.object_tag(w["who"]), w.get("joins", "start"))
                  for w in s.get("with") or []]
        start = s.get("start", "interact")
        if start == "overhear" and any("choice" in x for x in lines):
            raise ValueError(f"step {i}: an overheard talk has no choices - only lines")
        poses = dict(s.get("poses") or {})
        # (from the person's own action - sits, kneels - once poses work in the game: 01.10. a posed person was
        # gone in the first section and stood in the next, _scratch/marathon/kt_sheet.png; until then: as chosen)
        if AUTO_POSE and "npc" not in poses and pose_of_action(npc.get("action")):
            poses["npc"] = pose_of_action(npc.get("action"))     # as they are where they stand (sits, kneels)
        # the talk's own cameras, set in the world: in the scene's space (it is placed at the person, turned as they
        # look - the scene point below)
        space = lambda c: dialogue.scene_space(c, npc["pos"], float(npc["rot"][2]))     # noqa: E731
        cams = {k: space(c) for k, c in (s.get("cams") or {}).items()}
        stands = {k: space(c) for k, c in (s.get("spots") or {}).items()}     # where the player stands
        marks = {k: space(c) for k, c in (s.get("marks") or {}).items()}      # where lines put people
        sp = f"{name}_sp"
        # the scene placed at the person's scene point (its entity's tag as radish makes it): they stay where they
        # are, the player comes to them - with PLAYER the person was moved to the player (02.10., Keira left her
        # bath); an overheard talk (a gameplay scene) moves nobody
        placement = "PLAYER" if start == "overhear" else f"{ctx.qid}_{world}_{sp}_sp"
        scene, ends = self.scene(ctx, i, name, lines, npc, tag, fact, extras, character=ctx.character(s),
                                 poses=poses, cams=cams, stands=stands, placement=placement,
                                 cam_defaults=s.get("cam_defaults"), marks=marks, props=s.get("props"),
                                 gameplay=start == "overhear")
        scenes = {name: scene}
        x, y, z = npc["pos"]
        pin = f"{name}_pin"
        meta = {world: {"scenepoints": {sp: [x, y, z, float(npc["rot"][2])]}, "mappins": {pin: [x, y, z]}}}
        path = f"dlc/dlc{ctx.qid}/data/scenes/{name}.w2scene"      # radish: only [a-z/._0-9]
        blocks = {}
        if start == "now":
            # a cutscene: the scene plays the moment the step before is done
            first = block = f"scene.s{i}"
            blocks[block] = {"scene": path, "placement": f"{world}/{sp}"}
        elif start in ("near", "overhear"):
            # the talk starts by itself when the player comes near (overheard: they talk among themselves) - near
            # the person, wherever they are, also when the player is there already (03.10.: an area's 'entered'
            # waited for a step in; Maxim had followed the blacksmith in and stood inside)
            first, block = f"script.s{i}_near", f"scene.s{i}"
            blocks[first] = {"function": "CjWaitNear", "parameter": [
                {"tag": f"cname_{tag}"}, {"radius": float(s.get("radius", 6))}, {"x": float(x)}, {"y": float(y)},
                {"z": float(z)}], "next": [block]}
            blocks[block] = {"scene": path, "placement": f"{world}/{sp}"}
        else:
            block = f"interaction.s{i}"
            blocks[block] = {"scene": path, "placement": f"{world}/{sp}", "actor": [tag]}
            first = block
            if start == "calls":
                # the NPC calls out when Geralt comes near (once), the talk waits for E meanwhile
                call_lines = s.get("call") or [{"who": "npc", "text": "Witcher! Over here!"}]
                call, _ = self.scene(ctx, 900 + int(i), f"{name}_call", call_lines, npc, tag, f"{fact}_call",
                                     character=ctx.character(s),
                                     gameplay=True)
                scenes[f"{name}_call"] = call
                area = f"{name}_call"
                meta[world]["areas"] = {area: _area([x, y, z], float(s.get("radius", 10)))}
                first = f"addfact.s{i}_calls"
                blocks[first] = {"value": [f"{ctx.qid}_s{i}_calls", 1], "next": [f"waituntil.s{i}_call", block]}
                blocks[f"waituntil.s{i}_call"] = {"entered": f"{world}/{area}", "next": [f"scene.s{i}_call"]}
                blocks[f"scene.s{i}_call"] = {"scene": f"dlc/dlc{ctx.qid}/data/scenes/{name}_call.w2scene",
                                              "placement": f"{world}/{sp}"}
        again_path = None
        again = dialogue.again_lines(s) if repeat_of(s) is not None and start != "now" else None
        if again:                                       # talked to again: what one may ask again (again_lines)
            scene_again, _e = self.scene(ctx, 700 + int(i), f"{name}_again", again, npc, tag, fact, extras,
                                         character=ctx.character(s), poses=poses, cams=cams, stands=stands,
                                         placement=placement, cam_defaults=s.get("cam_defaults"), marks=marks,
                                         props=s.get("props"), gameplay=start == "overhear")
            scenes[f"{name}_again"] = scene_again
            again_path = f"dlc/dlc{ctx.qid}/data/scenes/{name}_again.w2scene"
        last, branches = block, {}
        if len(ends) > 1:
            last = f"waituntil.s{i}_choice"
            blocks[block]["next"] = [last]
            code = dialogue.codes(ends)
            blocks[last] = {"conditions": {dialogue.socket(e): {"factdb": [fact, "=", code[e]]} for e in sorted(ends)}}
            branches = {dialogue.socket(e): e for e in sorted(ends)}      # (a set: sorted - the same numbers every build)
        elif ends != {"continue"}:
            # only one way out that is not "goes on" (e.g. every answer fails): the quest follows it
            only = next(iter(ends))
            branches = {"": only}
        if start == "now":
            meta[world].pop("mappins")
            return StepOut(blocks, first, last, None, meta, scenes, branches)
        caption = s.get("text", "Listen in" if start == "overhear" else "Talk to them")
        out = StepOut(blocks, first, last, {"caption": caption, "mappins": [[pin, 3.0]],
                                            "world": world}, meta, scenes, branches)
        out.again_scene = (path, again_path) if again_path else None
        return out


AUTO_POSE = False


def pose_of_action(action):
    """A placed person's action (npc_actions: group/job) -> the pose a talk with them starts in, or None (standing)."""
    job = str(action or "").split("/")[-1]
    if not job:
        return None
    if job.startswith("sit") and any(w in job for w in ("ground", "bath", "floor")):
        return "sit_ground"
    if job.startswith("sit"):
        return "sit"
    if job.startswith("kneel"):
        return "kneel"
    if job.startswith(("lie", "lying", "sleep")):
        return "lie"
    if "lean" in job:
        return "lean"
    return None


def _put_durations(x, timing):
    """"[@<id>]" in the scene's lines -> "[<seconds>]" ("[@<id>><hold>]": at least <hold> seconds)."""
    if isinstance(x, dict):
        for k, v in x.items():
            x[k] = _put_durations(v, timing)
    elif isinstance(x, list):
        return [_put_durations(v, timing) for v in x]
    elif isinstance(x, str) and x.startswith("[@"):
        sid, rest = x[2:].split("]", 1)
        sid, _, hold = sid.partition(">")
        return f"[{max(timing.get(int(sid), 2.0), float(hold or 0)):.3f}]{rest}"
    elif isinstance(x, str) and x.startswith("@rest "):  # a line's own length: the pause after its mouth
        _r, sid, hold = x.split()
        return round(max(0.05, float(hold) - timing.get(int(sid), 2.0)), 3)
    return x


def first_wins(s):
    """An either of the graph's newer form: ways wired to goals (the first goal done wins), not options in it."""
    return isinstance(s, dict) and "ways" in s and not s.get("options")


def _embed(blocks, out, then):
    """A goal inside an either / all of these: its whole chain (an examine point shown first, a loot's carry check, a
    kill of several - 02.10.: only its first block was taken), its last block leading to `then` -> its first."""
    for name, b in out.blocks.items():
        blocks[name] = dict(b)
    blocks[out.last] = dict(blocks[out.last], next=[then])
    return out.first


class Either:
    """either: the first of several goals the player does decides how it goes on (a path each, or on).

        - either: {text: Deal with the bandit, options: [{goal: {kill: {target: camp/bandit}}, path: fought},
                                                        {goal: {goto: {place: town, radius: 8}}, path: let_go}]}

    Every option waits on its own (go to, loot, examine, use, kill); the one fulfilled first sets its fact, a decider
    waits on those facts and leads on."""
    name = "either"
    KINDS = ("goto", "loot", "examine", "use", "kill")

    def generate(self, ctx, i, s):
        if first_wins(s):
            # (a graph's: its ways are wired to goals of their own - build_graph starts them side by side, the first
            # done cuts the others; Maxim 02.10.: "any number of outputs, to anything")
            fork = f"addfact.s{i}_either"
            return StepOut({fork: {"value": [f"{ctx.qid}_s{i}_either", 1]}}, fork, fork, None)
        opts = s.get("options") or []
        if len(opts) < 2:
            raise ValueError(f"step {i}: an either needs two options or more")
        blocks, meta, pins, conditions, branches, scenes = {}, {}, [], {}, {}, {}
        fork = f"addfact.s{i}_either"
        waiters = []
        for k, o in enumerate(opts, 1):
            kind, args = step_type(o["goal"])
            if kind == "goto":
                args = {k: v for k, v in (args or {}).items() if k not in ("when", "stay")}
            if kind not in self.KINDS:
                raise ValueError(f"step {i}: an either option can be {', '.join(self.KINDS)} - not {kind}")
            out = BLOCKS[kind].generate(ctx, f"{i}_{k}", args or {})
            fact = f"{ctx.qid}_s{i}_o{k}"
            done = f"addfact.s{i}_o{k}"
            waiters.append(_embed(blocks, out, done))
            blocks[done] = {"value": [fact, 1]}
            scenes.update(out.scenes)
            for w, m in out.meta.items():
                for key, v in m.items():
                    meta.setdefault(w, {}).setdefault(key, {}).update(v)
            if out.objective:
                pins += out.objective.get("mappins") or []
            conditions[f"o{k}"] = {"factdb": [fact, ">=", 1]}
            branches[f"o{k}"] = f"path:{o['path']}" if o.get("path") else "continue"
        decide = f"waituntil.s{i}_decide"
        blocks[decide] = {"conditions": conditions}
        blocks[fork] = {"value": [f"{ctx.qid}_s{i}_either", 1], "next": waiters + [decide]}
        return StepOut(blocks, fork, decide, {"caption": s.get("text", "Decide"), "mappins": pins}, meta, scenes,
                       branches=branches)


class AllOf:
    """all: {text: Search the camp, options: [{goal: {loot: {object: camp/chest}}}, {goal: {kill: {target: ...}}}]}
    Several goals in any order; the step is done when every one is (the journal counts them: 1/3). The goals wait
    side by side (go to, loot, examine, use, kill), each adds one to the count."""
    name = "all"

    def generate(self, ctx, i, s):
        opts = s.get("options") or []
        if len(opts) < 2:
            raise ValueError(f"step {i}: all of these - two goals or more")
        count = f"{ctx.qid}_s{i}_all"
        blocks, meta, pins, waiters, scenes = {}, {}, [], [], {}
        for k, o in enumerate(opts, 1):
            kind, args = step_type(o["goal"])
            if kind == "goto":
                args = {kk: v for kk, v in (args or {}).items() if kk not in ("when", "stay")}
            if kind not in Either.KINDS:
                raise ValueError(f"step {i}: all of these can wait for {', '.join(Either.KINDS)} - not {kind}")
            out = BLOCKS[kind].generate(ctx, f"{i}_{k}", args or {})
            done = f"addfact.s{i}_a{k}"
            waiters.append(_embed(blocks, out, done))
            blocks[done] = {"value": [count, 1]}
            scenes.update(out.scenes)
            for w, m in out.meta.items():
                for key, v in m.items():
                    meta.setdefault(w, {}).setdefault(key, {}).update(v)
            if out.objective:
                pins += out.objective.get("mappins") or []
        fork, last = f"addfact.s{i}_all_on", f"waituntil.s{i}_all"
        blocks[last] = {"factdb": [count, ">=", len(opts)]}
        blocks[fork] = {"value": [f"{ctx.qid}_s{i}_all_on", 1], "next": waiters + [last]}
        return StepOut(blocks, fork, last, {"caption": s.get("text", "Do all of these"), "mappins": pins}, meta,
                       scenes, counter=(count, len(opts)))


class Clues:
    """clues: find clues with the witcher senses - each switched on when its turn comes, waited for, commented.

        - clues: {text: Search the camp, in_order: true,
                  clues: [{object: camp/blood, says: {text: "Blood. Still fresh."}},
                          {trail: camp/tracks, says: {text: "Nekkers. Five of them."}},
                          {object: camp/body, how: body, dialogue: [...]}, ...]}

    An entry examines `object` (any object: one that is no clue of the game gets an examine point beside it; `how`:
    ground | eye | body | high - how Geralt bends to it) or follows `trail` (a trail drawn in the editor, trails.py:
    seen in the witcher senses, nothing to press). After it: `says` (a line, the game goes on) or `dialogue` (a talk
    with himself, choices like 'the arm', 'the head' - only on an examined object).
    trail on an object entry (older form): the pieces leading to it, each lit before it.
    in_order: an entry comes when the one before was done; else all at once."""
    name = "clues"
    HOW = {"ground": 1, "eye": 2, "body": 3, "high": 4}

    def generate(self, ctx, i, s):
        items = [c for c in s.get("clues") or [] if c.get("object") or c.get("trail")]
        if not items:
            raise ValueError(f"step {i}: find clues - which? (add clues on the card)")
        found = f"{ctx.qid}_s{i}_found"
        fork = f"addfact.s{i}_clues"
        blocks, scenes, firsts, points = {}, {}, [], []
        world = None
        in_order, tail = bool(s.get("in_order")), None
        for k, c in enumerate(items, 1):
            ref = c.get("object") or c.get("trail")
            o = ctx.object(ref)
            place = ref.partition("/")[0]
            world = ctx.place_world(place)
            tag = ctx.object_tag(ref)
            layer = f"{ctx.qid}_s{i}_c{k}"
            count = f"addfact.s{i}_c{k}"
            blocks[count] = {"value": [found, 1]}
            entry = None
            if c.get("trail") and not c.get("object"):
                # a trail: its pieces come with its layer, lit, and it is done when Geralt has seen one
                pcs = o.get("pieces") or []
                if not pcs:
                    raise ValueError(f"step {i}: trail {ref} has no pieces (draw it again)")
                ctx.layers[layer] = {"world": world, "statics": {
                    f"p{n:02d}": {"template": p[4], "pos": [float(v) for v in p[:3]], "rot": [0.0, 0.0, float(p[3])],
                                  "tags": [tag]}
                    for n, p in enumerate(pcs)}}
                ctx.trails_in_steps.add(ref)
                points += [p[:3] for p in pcs]
                on, seen = f"script.s{i}_c{k}_on", f"script.s{i}_c{k}_seen"
                blocks[on] = {"function": "CjClueGroupOn", "parameter": [{"tag": f"cname_{tag}"}], "next": [seen]}
                blocks[seen] = {"function": "CjClueGroupSeen", "parameter": [{"tag": f"cname_{tag}"}],
                                "next": [count]}
                entry = on
                spot = pcs[0][:3]
            else:
                # something to examine: the object itself if it is one of the game's clues, else a point beside it
                wait_tag = tag
                if not is_clue_template(o["template"]):
                    wait_tag = f"{tag}_examine"
                    ctx.own_entities["cj_examine_point"] = EXAMINE_POINT
                    x, y, z = (float(v) for v in o["pos"])
                    ctx.layers[layer] = {"world": world, "statics": {"examine": {
                        "template": f"dlc\\dlc{ctx.qid}\\data\\entities\\cj_examine_point.w2ent",
                        "pos": [x, y, z + 0.2], "rot": [0.0, 0.0, 0.0], "tags": [wait_tag]}}}
                points.append(o["pos"])
                wait = f"script.s{i}_c{k}"
                # a line said while the game goes on comes as Geralt goes down (CjClueSays); a talk with himself
                # waits until he is done kneeling (its scene would cut the animation off)
                said = c.get("says") or {}
                says_early = bool(said.get("text") or said.get("voice") or said.get("voice_pack")) and \
                    not c.get("dialogue")
                blocks[wait] = {"function": "CjClueSays" if says_early else "CjClueAs", "parameter": [
                    {"tag": f"cname_{wait_tag}"}, {"how": self.HOW.get(c.get("how") or "", 0)}], "next": [count]}
                entry = wait
                # the trail to it (older form): each piece lit (in a row), then the clue itself
                for j, t in reversed(list(enumerate([t for t in c.get("trail") or [] if t], 1))):
                    piece = f"script.s{i}_c{k}_t{j}"
                    blocks[piece] = {"function": "CjClueOn", "parameter": [{"tag": f"cname_{ctx.object_tag(t)}"}],
                                     "next": [entry]}
                    points.append(ctx.object(t)["pos"])
                    entry = piece
                spot = o["pos"]
            if layer in ctx.layers:                     # its layer shown first (hidden from the quest's start)
                show = f"changelayers.s{i}_c{k}"
                blocks[show] = {"world": world, "show": [layer], "next": [entry]}
                entry = show
            if in_order and tail:
                blocks[tail]["next"] = [entry]          # the entry before, done (and commented), opens this one
            else:
                firsts.append(entry)
            tail = count
            # after it: a talk with himself (an examined object) or a line said while the game goes on
            says = c.get("says") or {}
            talk = c.get("dialogue") if c.get("object") else None
            if talk or says.get("text") or says.get("voice") or says.get("voice_pack"):
                name = f"{ctx.qid}_s{i}_c{k}"
                sp = f"{name}_sp"
                x, y, z = spot
                lines = talk or [dict(says, who="player")]
                sc, _ends = Talk.scene(ctx, 700 + 10 * int(i) + k, name, lines, None, None, f"{name}_f",
                                       gameplay=not talk, character=ctx.character(s))
                scenes[name] = sc
                ctx.extra_meta.setdefault(world, {}).setdefault("scenepoints", {})[sp] = [x, y, z, 0.0]
                blocks[count]["next"] = [f"scene.s{i}_c{k}"]
                blocks[f"scene.s{i}_c{k}"] = {"scene": f"dlc/dlc{ctx.qid}/data/scenes/{name}.w2scene",
                                              "placement": f"{world}/{sp}"}
                tail = f"scene.s{i}_c{k}"
        done = f"waituntil.s{i}"
        blocks[done] = {"factdb": [found, ">=", len(items)]}
        blocks[fork] = {"value": [f"{ctx.qid}_s{i}_clues", 1], "next": firsts + [done]}
        # the search area on the map: a circle around all clues and trails
        cx, cy, cz = (sum(p[n] for p in points) / len(points) for n in range(3))
        radius = max(8.0, max(((p[0] - cx) ** 2 + (p[1] - cy) ** 2) ** 0.5 for p in points) + 5.0)
        pin = f"{ctx.qid}_s{i}_pin"
        meta = {world: {"mappins": {pin: [round(cx, 3), round(cy, 3), round(cz, 3)]}}}
        return StepOut(blocks, fork, done, {"caption": s.get("text", "Search for clues with your witcher senses"),
                                            "mappins": [[pin, round(radius, 1)]], "world": world}, meta, scenes,
                       counter=(found, len(items)) if len(items) > 1 else None)


# an examine point: a clue of the game's own kind without a mesh, beside an object that is no clue itself (a body, a
# barrel, a letter on a table) - E there: Geralt bends to it (the game's contracts give every clue this interaction)
EXAMINE_POINT = {"entityObject": {
    ".type": "W3MonsterClue", "isInteractive": True, "isVisible": True, "isAvailable": True, "isReusable": False,
    "interactionAnim": "PEA_ExamineGround", "maxDetectionDistance": 4.0, "components": {
        "InteractiveClue": {".type": "CInteractionComponent", "actionName": "Examine", "rangeMax": 1.5,
                            "reportToScript": True},
        "focus": {".type": "CFocusActionComponent", "actionName": "Examine"}}}}
CLUE_CLASSES = ("W3MonsterClue", "W3ClueCorpse", "W3ClueStash", "W3DestroyableClue", "W3MonsterClueAnimated",
                "W3MonsterClueScent")
_clue_class = {}


def is_clue_template(template):
    """Is it one of the game's witcher-sense clues (examined by itself)? Read once from the game's files; unknown (no
    game to look in): yes - as before."""
    key = template.lower()
    if key not in _clue_class:
        try:
            from .bundles import Depot
            from .cr2w import CR2W
            global _depot
            _depot = globals().get("_depot") or Depot()
            if not _depot.exists(key):
                _clue_class[key] = True
            else:
                _clue_class[key] = any(e[0] in CLUE_CLASSES for e in CR2W(_depot.read(key)).exports[:4])
        except Exception:                               # noqa: BLE001 - no game: as before
            _clue_class[key] = True
    return _clue_class[key]


USABLE = ("Door", "Switch", "Lever", "Elevator", "Gate", "Mechanism", "Lock", "Interaction", "Bed", "Boat",
          "Fireplace", "Lamp", "Torch", "Board", "Altar")


def usable(template):
    """Does using it mean something to the game (a door, a lever, a switch ...: its own interaction)? By the class
    the catalog read; unknown: yes - as before."""
    cls = template_class(template)
    return not cls or any(w.lower() in cls.lower() for w in USABLE)


# what has an inventory but is no loot (07.10., the demo: a quest's ring went into Geralt's stash - E opens his own
# storage, the ring is never seen): the reason, in the UI's words
NOT_LOOT = {"W3Stash": "Geralt's stash (it opens his own storage, quest items stay out of it). Take a chest"}


def not_loot(template):
    """Why it can not hold a quest's items (the reason) or None."""
    return NOT_LOOT.get(template_class(template))


def lootable(template):
    """Is it something to loot (a container, a body, a person)? Unknown: yes. Geralt's stash: no (NOT_LOOT)."""
    cls = template_class(template)
    if cls in NOT_LOOT:
        return False
    return not cls or "container" in cls.lower() or "stash" in cls.lower() or is_actor({"template": template})


_own_talk = {}


def has_own_talk(template):
    """Does the template bring a talk of its own (a CStorySceneComponent: a merchant's shop, a smith's crafting)?
    Read once from the game's files; no game: no."""
    key = template.lower()
    if key not in _own_talk:
        try:
            from .bundles import Depot
            from .cr2w import CR2W
            global _depot
            _depot = globals().get("_depot") or Depot()
            _own_talk[key] = _depot.exists(key) and any(
                e[0] == "CStorySceneComponent" for e in CR2W(_depot.read(key)).exports[:12])
        except Exception:                               # noqa: BLE001 - no game to look in
            _own_talk[key] = False
    return _own_talk[key]


class Follow:
    """follow: {who: village/elder, path: [[x, y, z], ...], lead: false, run: false, wait: 10, text: ...,
    talks: [{talk: {at: 2, dialogue: [...]}}, ...]}
    Geralt follows: the NPC walks the path and waits when Geralt falls behind `wait` m; done at its end.
    lead: Geralt leads - the NPC follows him; done when both are at the path's last point.
    talks: they talk on the way - when the NPC reaches point `at` (1 = the first) its lines play as a gameplay scene
    (subtitles, the player keeps walking)."""
    name = "follow"

    def generate(self, ctx, i, s):
        if not s.get("who"):
            raise ValueError(f"step {i}: follow - who? (Pick on the card)")
        path = [p for p in s.get("path") or [] if p and len(p) >= 3]
        if not path:
            raise ValueError(f"step {i}: follow - the path has no points (+ point on the card)")
        place = s["who"].partition("/")[0]
        world = ctx.place_world(place)
        block = f"script.s{i}_escort"
        if not s.get("lead") and hasattr(ctx, "moved"):
            ctx.moved[s["who"]] = (path[-1], _heading(path[-2] if len(path) > 1 else ctx.object(s["who"])["pos"],
                                                      path[-1]))
        text = ";".join(",".join(f"{float(v):.2f}" for v in p[:3]) for p in path)
        pin = f"{ctx.qid}_s{i}_pin"
        meta = {world: {"mappins": {pin: [round(float(v), 3) for v in path[-1][:3]]}}}
        progress = f"{ctx.qid}_s{i}_at"
        phases = getattr(ctx, "walk_phases", {}).get(id(s))
        stuck = bool(phases and len(phases) > 2 and phases[2])
        if phases and not s.get("lead") and not stuck and s.get("smooth", True) and hasattr(ctx, "minigames"):
            # the game's way (pathfollow.py, as q704's "Regis follows us"): his phase at the way's end, then he walks
            # the path as one, the player his companion - no stand at every point (02.10.)
            meta[world]["mappins"][pin] = [round(float(v), 3) for v in ctx.object(s["who"])["pos"][:3]]
            blocks, block, last = self.along_path(ctx, i, s, phases, path, world, progress, pin, text)
        elif phases and not s.get("lead"):
            # he walks by his community's phases, point after point; CjArrive waits for him and for the player and
            # puts the pin on him (the one to follow, not the end of the way - Maxim 02.10.)
            meta[world]["mappins"][pin] = [round(float(v), 3) for v in ctx.object(s["who"])["pos"][:3]]
            blocks, block, last = walk_chain(ctx, i, s["who"], phases, float(s.get("wait", 10)), progress, pin)
        else:
            blocks = {block: {"function": "CjEscort", "parameter": [
                {"tag": f"cname_{ctx.object_tag(s['who'])}"}, {"path": text}, {"lead": bool(s.get("lead"))},
                {"run": bool(s.get("run"))}, {"waitDist": float(s.get("wait", 10))}, {"progress": progress}]}}
            last = block
        first, scenes = block, {}
        talks = [t.get("talk") or {} for t in s.get("talks") or [] if (t.get("talk") or {}).get("dialogue")]
        if talks and not s.get("lead"):
            # the talks: each waits beside the walk for its point, then plays (gameplay: the player walks on)
            first = f"addfact.s{i}_walk"
            starts = [block]
            npc, tag = ctx.object(s["who"]), ctx.object_tag(s["who"])
            for j, t in enumerate(talks):
                at = max(1, min(len(path), int(t.get("at", 1))))
                name = f"{ctx.qid}_s{i}_t{j}"
                scene, _ends = Talk.scene(ctx, 400 + (10 * int(i) + j) % 100, name, t["dialogue"], npc, tag,
                                          f"{name}_x", character=ctx.character(s), gameplay=True)
                scenes[name] = scene
                sp = f"{name}_sp"
                meta[world].setdefault("scenepoints", {})[sp] = [float(v) for v in path[at - 1][:3]] + [0.0]
                wait, play = f"waituntil.s{i}_t{j}", f"scene.s{i}_t{j}"
                blocks[wait] = {"factdb": [progress, ">=", at], "next": [play]}
                blocks[play] = {"scene": f"dlc/dlc{ctx.qid}/data/scenes/{name}.w2scene", "placement": f"{world}/{sp}"}
                starts.append(wait)
            blocks[first] = {"value": [f"{ctx.qid}_s{i}_walking", 1], "next": starts}
        return StepOut(blocks, first, last, {"caption": _caption(ctx, "follow", s),
                                              "mappins": [[pin, 0.0]],
                                              "world": world}, meta, scenes)


    @staticmethod
    def along_path(ctx, i, s, phases, path, world, progress, pin, text):
        """The blocks of a follow the game's way -> (blocks, first, last): the path entity's layer shown, his phase
        at the way's end, then side by side the scripted action (a stand-in fact block, minigames.apply makes it
        the game's) and the watch of his progress (CjFollowTrack, done at the end)."""
        comm, names = phases[0], phases[1]
        tag = ctx.object_tag(s["who"])
        ent, path_tag, layer = f"cj_path_s{i}", f"{ctx.qid}_s{i}_path", f"{ctx.qid}_s{i}_path"
        origin = [float(v) for v in path[0][:3]]
        ctx.own_entities[ent] = {"entityObject": {".type": "CEntity", "components": {
            "path": {".type": "CPathComponent"}}}}
        ctx.layers[layer] = {"world": world, "statics": {"path": {
            "template": "\\".join(["dlc", f"dlc{ctx.qid}", "data", "entities", ent + ".w2ent"]), "pos": origin,
            "rot": [0.0, 0.0, 0.0],
            "tags": [path_tag]}}}
        ctx.minigames[f"path_s{i}"] = {"game": "path", "entity": ent,
                                      "points": [[round(float(p[k]) - origin[k], 3) for k in range(3)] for p in path]}
        wait = float(s.get("wait", 10))
        ctx.minigames[f"follow_s{i}"] = {"game": "follow", "npc": tag, "path": path_tag, "max": wait,
                                        "min": min(4.0, wait * 0.4), "run": bool(s.get("run"))}
        show, phase, fork = f"changelayers.s{i}_path", f"spawn.s{i}_end", f"addfact.s{i}_go"
        action, track = f"addfact.follow_s{i}", f"script.s{i}_track"
        # (the phase at the way's end only when he is there: set before, his community pulled him and the path's
        # action took turns - 24 s standing at one point, 03.10.; the action alone walks him off his action point)
        blocks = {
            show: {"world": world, "show": [layer], "next": [fork]},
            fork: {"value": [f"{ctx.qid}_s{i}_go", 1], "next": [action, track]},
            action: {"value": [f"{ctx.qid}_follow_s{i}", 1], "next": ["waituntil.forever"]},
            track: {"function": "CjFollowTrack", "parameter": [
                {"tag": f"cname_{tag}"}, {"path": text}, {"progress": progress}, {"pin": f"cname_{pin}"}],
                "next": [phase]},
            phase: {"spawnsets": [comm], "phase": names[-1][0]}}
        return blocks, show, phase


class Race:
    """race: {path: [[x, y, z], ...], racers: [village/runner, ...], pace: easy | normal | hard, radius: 6, text}
    A race on foot as the game's races are made (hr201 Ferlund, Maxim 05.10.): the course a path, its points the
    checkpoints (the first the start, the last the goal); when the player is at the start the racers are put there,
    the game counts down (DisplayRaceStart), they run the path with the game's race AI (CAIMoveAlongPathAction, its
    CAIRaceAlongPathParams - pathfollow.race_block), the player passes every checkpoint in order. Who is in the goal
    first decides: won (the player, through all checkpoints) or lost (a racer)."""
    name = "race"
    PACE = {"easy": "MT_Run", "normal": "MT_FastRun", "hard": "MT_Sprint"}

    def generate(self, ctx, i, s):
        path = [p for p in s.get("path") or [] if p and len(p) >= 3]
        if len(path) < 2:
            raise ValueError(f"step {i}: race - the course needs a start and a goal (+ point on the card)")
        racers = [r for r in s.get("racers") or [] if r]
        if not racers:
            raise ValueError(f"step {i}: race - against whom? (+ who on the card)")
        world = ctx.place_world(racers[0].partition("/")[0])
        radius = float(s.get("radius", 6))
        meta = {world: {"areas": {}, "mappins": {}}}
        areas = []
        for k, p in enumerate(path):
            area = f"{ctx.qid}_s{i}_cp{k}"
            meta[world]["areas"][area] = _area([float(v) for v in p[:3]], radius)
            areas.append(f"{world}/{area}")
        pin = f"{ctx.qid}_s{i}_pin"
        meta[world]["mappins"][pin] = [round(float(v), 3) for v in path[-1][:3]]
        # the course: a path entity of the quest (as Follow's, pathfollow.patch_paths puts the curve in)
        ent, path_tag, layer = f"cj_race_s{i}", f"{ctx.qid}_s{i}_race", f"{ctx.qid}_s{i}_race"
        origin = [float(v) for v in path[0][:3]]
        ctx.own_entities[ent] = {"entityObject": {".type": "CEntity", "components": {
            "path": {".type": "CPathComponent"}}}}
        ctx.layers[layer] = {"world": world, "statics": {"path": {
            "template": "\\".join(["dlc", f"dlc{ctx.qid}", "data", "entities", ent + ".w2ent"]), "pos": origin,
            "rot": [0.0, 0.0, 0.0], "tags": [path_tag]}}}
        ctx.minigames[f"path_s{i}"] = {"game": "path", "entity": ent,
                                      "points": [[round(float(p[k]) - origin[k], 3) for k in range(3)] for p in path]}
        start, show, count, go = (f"waituntil.s{i}_start", f"changelayers.s{i}_course", f"script.s{i}_count",
                                  f"addfact.s{i}_go")
        won, decide = f"addfact.s{i}_won", f"waituntil.s{i}_finish"
        won_fact = f"{ctx.qid}_s{i}_won"
        blocks = {start: {"entered": areas[0], "next": [show]}, show: {"world": world, "show": [layer]}}
        # the racers at the start, beside each other (across the course's first stretch)
        dx, dy = path[1][0] - path[0][0], path[1][1] - path[0][1]
        n = math.hypot(dx, dy) or 1.0
        side = (-dy / n * 1.5, dx / n * 1.5)
        yaw = _heading(path[0], path[1])
        before = show
        tags = []
        for k, r in enumerate(racers, 1):
            tag = ctx.object_tag(r)
            tags.append(tag)
            put = f"script.s{i}_put{k}"
            blocks[put] = {"function": "CjPutAt", "parameter": [
                {"tag": f"cname_{tag}"}, {"x": float(path[0][0] + side[0] * k)}, {"y": float(path[0][1] + side[1] * k)},
                {"z": float(path[0][2])}, {"yaw": float(yaw)}]}
            blocks[before]["next"] = [put]
            before = put
        blocks[before]["next"] = [count]
        blocks[count] = {"function": "DisplayRaceStart", "parameter": [{"countDownSecondsNumber": 3}], "next": [go]}
        runs = []
        for k, tag in enumerate(tags, 1):              # (stand-ins: minigames.apply makes them the race AI)
            name = f"race_s{i}_{k}"
            ctx.minigames[name] = {"game": "race", "npc": tag, "path": path_tag,
                                   "pace": self.PACE.get(s.get("pace") or "normal", "MT_FastRun")}
            blocks[f"addfact.{name}"] = {"value": [f"{ctx.qid}_{name}", 1], "next": ["waituntil.forever"]}
            runs.append(f"addfact.{name}")
        # the player: every checkpoint in order, then the goal
        checks = [f"waituntil.s{i}_cp{k}" for k in range(1, len(path))]
        for k, c in enumerate(checks, 1):
            blocks[c] = {"entered": areas[k], "next": [checks[k] if k < len(checks) else won]}
        blocks[won] = {"value": [won_fact, 1]}
        lost = [{"inside": areas[-1], "who": t} for t in tags]
        blocks[decide] = {"conditions": {"won": {"factdb": [won_fact, ">=", 1]},
                                         "lost": lost[0] if len(lost) == 1 else {"any": lost}}}
        blocks[go] = {"value": [f"{ctx.qid}_s{i}_go", 1], "next": runs + [checks[0], decide]}
        return StepOut(blocks, start, decide, {"caption": s.get("text", "Win the race"), "mappins": [[pin, radius]],
                                               "world": world}, meta, branches={"won": "continue", "lost": "fail"})


class Patrol:
    """patrol: {who: camp/guard, path: [[x, y, z], ...], run: false} - the NPC walks the way on and on (a branch of
    its own: the quest goes on at once)."""
    name = "patrol"

    def generate(self, ctx, i, s):
        path = [p for p in s.get("path") or [] if p and len(p) >= 3]
        if not path:
            raise ValueError(f"step {i}: patrol - the way has no points (+ point on the card)")
        fork, walk, on = f"addfact.s{i}_patrol", f"script.s{i}_patrol", f"addfact.s{i}_patrol_on"
        phases = getattr(ctx, "walk_phases", {}).get(id(s))
        if phases:                                  # his community's phases in a loop (the old way: an AI walk)
            loop, walk, last = walk_chain(ctx, i, s["who"], phases, 0.0, "")
            loop[last]["next"] = [f"spawn.s{i}_p1"]                # (round and round; a fade only at the start)
            blocks = dict(loop)
        else:
            text = ";".join(",".join(f"{float(v):.2f}" for v in p[:3]) for p in path)
            blocks = {walk: {"function": "CjPatrol", "parameter": [{"tag": _tag(ctx, s, "who")}, {"path": text},
                                                                     {"run": bool(s.get("run"))}]}}
        blocks.update({fork: {"value": [f"{ctx.qid}_s{i}_patrol", 1], "next": [walk, on]},
                       on: {"value": [f"{ctx.qid}_s{i}_patrol_on", 1]}})
        return StepOut(blocks, fork, on, None)


class Defeat:
    """defeat: {target: camp/bandit, below: 20} - a fight until he yields: he cannot die, attacks, and when his
    health is down to `below` percent the fight stops (he stays alive - a talk can follow)."""
    name = "defeat"

    def generate(self, ctx, i, s):
        if not s.get("target"):
            raise ValueError(f"step {i}: defeat - who? (Pick, Search or Create on the card)")
        tag = f"cname_{ctx.object_tag(s['target'])}"
        b = [f"script.s{i}_immortal", f"script.s{i}_fight", f"script.s{i}_yield", f"script.s{i}_peace"]
        blocks = {b[0]: {"function": "CjImmortal", "parameter": [{"tag": tag}, {"mode": "immortal"}], "next": [b[1]]},
                  b[1]: {"function": "CjHostileQ", "parameter": [{"qid": ctx.qid}, {"tag": tag}, {"hostile": True}],
                         "next": [b[2]]},
                  b[2]: {"function": "CjWaitDefeated", "parameter": [{"tag": tag}, {"percent": int(s.get("below", 20))}],
                         "next": [b[3]]},
                  b[3]: {"function": "CjHostileQ", "parameter": [{"qid": ctx.qid}, {"tag": tag}, {"hostile": False}]}}
        meta, where = _pin(ctx, i, [s["target"]], radius=8.0)
        return StepOut(blocks, b[0], b[3], {"caption": s.get("text", "Defeat him"), **where}, meta)


class Read:
    """read: {item: "Notice: Missing daughter"} - waits until Geralt has read that book / letter / notice (give it to
    him first, or put it into a container / on a notice board)."""
    name = "read"

    def generate(self, ctx, i, s):
        if not s.get("item"):
            raise ValueError(f"step {i}: read - which letter or book?")
        b = f"script.s{i}_read"
        return StepOut({b: item_call(ctx, "CjWaitRead", s["item"])}, b, b,
                       {"caption": s.get("text", f"Read {s['item']}")})


class WaitFor:
    """waitfor: {what: combat | peace | senses | health, percent: 30, text} - a goal that waits for something of the
    game: a fight starts, the fight is over, the witcher senses are on, the player's health is down to `percent`."""
    name = "waitfor"
    WHAT = {"combat": 1, "peace": 2, "senses": 3, "health": 4}
    CAPTION = {"combat": "Fight", "peace": "Win the fight", "senses": "Use your witcher senses",
               "health": "Survive"}

    def generate(self, ctx, i, s):
        what = s.get("what") or "senses"
        if what not in self.WHAT:
            raise ValueError(f"step {i}: wait for - what? ({', '.join(self.WHAT)})")
        b = f"script.s{i}_waitfor"
        return StepOut({b: {"function": "CjWaitGame", "parameter": [{"what": self.WHAT[what]},
                                                                    {"percent": int(s.get("percent", 30))}]}},
                       b, b, {"caption": s.get("text") or self.CAPTION[what]})


class Kill:
    """kill: {targets: [camp/ghoul, camp/ghoul_2], text: Kill the ghouls} (or `target: camp/ghoul`) - the game itself
    sets the fact actor_<tag>_was_killed when a tagged creature dies (behavior tree death task)."""
    name = "kill"

    def generate(self, ctx, i, s):
        refs = [r for r in s.get("targets") or [] if r] or ([s["target"]] if s.get("target") else [])
        if not refs:
            raise ValueError(f"step {i}: kill - who? (Pick, Search or Create on the card)")
        out = self._kill(ctx, i, s, refs)
        spawnsets = sorted({ctx.foes[r] for r in refs if r in ctx.foes})
        if spawnsets:                                   # they come now (not with the quest's start)
            sp = f"spawn.s{i}_foes"
            out.blocks[sp] = {"phase": "main", "spawnsets": spawnsets, "next": [out.first]}
            out.fork, out.first = out.first, sp       # (the counter of several hangs on the fork, not on the spawn)
        return out

    def _kill(self, ctx, i, s, refs):
        wait = f"waituntil.s{i}"
        meta, where = _pin(ctx, i, refs, radius=8.0)      # on the map: where they are (a circle - they move)
        if len(refs) == 1:
            return StepOut({wait: {"factdb": [f"actor_{ctx.object_tag(refs[0])}_was_killed", ">=", 1]}}, wait, wait,
                           {"caption": s.get("text", "Kill them"), **where}, meta)
        # several: each death counts (the objective shows 1/3, 2/3, ...)
        dead, fork = f"{ctx.qid}_s{i}_dead", f"addfact.s{i}_kill"
        blocks, waits = {}, []
        for k, r in enumerate(refs, 1):
            w, a = f"waituntil.s{i}_k{k}", f"addfact.s{i}_k{k}"
            blocks[w] = {"factdb": [f"actor_{ctx.object_tag(r)}_was_killed", ">=", 1], "next": [a]}
            blocks[a] = {"value": [dead, 1]}
            waits.append(w)
        blocks[wait] = {"factdb": [dead, ">=", len(refs)]}
        blocks[fork] = {"value": [f"{ctx.qid}_s{i}_kill", 1], "next": waits + [wait]}
        return StepOut(blocks, fork, wait, {"caption": s.get("text", "Kill them"), **where}, meta,
                       counter=(dead, len(refs)))


class Collect:
    """collect: {item: Ruby, count: 3, text: Bring three rubies} - a check (quest function CjHasItems of Conjunction's
    mod) that waits until the player carries them, a look every second; its block stays active, so a saved game
    resumes it (the graph's own pause between checks stays as a fallback - it took up to two minutes)."""
    name = "collect"
    function = "CjHasItems"

    def generate(self, ctx, i, s):
        items = step_items(s)
        blocks = {}
        # one check per item, in a row: each waits until the player carries it, then the next (the last goes on)
        # (radish 2020: several outputs only with factdb conditions -> the pause is a block of its own)
        for k, it in enumerate(items):
            sfx = "" if k == 0 else f"_{k + 1}"
            fact = f"{ctx.qid}_s{i}_have{sfx}"
            check, wait, pause = f"script.s{i}_check{sfx}", f"waituntil.s{i}{sfx}", f"waituntil.s{i}_later{sfx}"
            if s.get("keep_in"):                # a loot step's item: kept in its container until taken (CjKeepIn)
                call = item_call(ctx, "CjHasItemsFrom", it["item"], count=it["count"], fact=fact,
                                 tag=f"cname_{ctx.object_tag(s['keep_in'])}")
            else:
                call = item_call(ctx, self.function, it["item"], count=it["count"], fact=fact)
            blocks[check] = dict(call, next=[wait])
            blocks[wait] = {"conditions": {"have": {"factdb": [fact, "=", 1]}, "notyet": {"factdb": [fact, "=", 0]}},
                            "next.notyet": [pause]}
            blocks[pause] = {"elapsed": "00:02:00", "next": [check]}
            if k + 1 < len(items):
                blocks[wait]["next.have"] = [f"script.s{i}_check_{k + 2}"]
        first, last = f"script.s{i}_check", (f"waituntil.s{i}_{len(items)}" if len(items) > 1 else f"waituntil.s{i}")
        caption = _caption(ctx, self.name, s) if self.name != "collect" else \
            f"Get {s.get('count', 1)} {s['item']}" if len(items) == 1 else f"Get {len(items)} items"
        objective, meta = {"caption": s.get("text", caption)}, None
        if s.get("in") and s.get("from") in ("container", "person"):
            meta, where = _pin(ctx, i, [s["in"]])          # on the map: the chest / the person that has it
            objective.update(where)
        return StepOut(blocks, first, last, objective, meta, branches={"have": "continue"})


class Equip(Collect):
    """equip: {item, more_items} - the player wears / holds them (Maxim, 01.10.: put on a specific armour): a check per
    item (CjEquipped of Conjunction's mod), each until it sits in one of the player's slots."""
    name = "equip"
    function = "CjEquipped"


class Note:
    """note: {text: "Geralt found the strongbox empty..."} - a paragraph that joins the quest's journal entry."""
    name = "note"

    def generate(self, ctx, i, s):
        did = f"s{i}"
        ctx.descriptions.append({did: s["text"]})
        block = f"journal.s{i}"
        return StepOut({block: {"entry": f"quests/{ctx.qid}/{did}"}}, block, block, None)


class Wait:
    """wait: {time: "01:00:00"} game time passes - or {until: "22:00"} until that time of day. An objective only with
    a text (as Wait until)."""
    name = "wait"

    def generate(self, ctx, i, s):
        objective = {"caption": s["text"]} if s.get("text") else None
        if s.get("until"):
            h, m = (int(v) for v in str(s["until"]).split(":")[:2])
            b = f"script.s{i}_until"
            return StepOut({b: {"function": "CjWaitHour", "parameter": [{"hour": h}, {"minute": m}]}}, b, b,
                           objective)
        wait = f"waituntil.s{i}"
        return StepOut({wait: {"elapsed": str(s.get("time", "00:00:10"))}}, wait, wait, objective)


class Travel:
    """travel: {pos: [x, y, z], yaw: 0, world: skellige} - Geralt is taken there, into that world, with a loading
    screen (also within the same world: then it is a long teleport with a loading screen)."""
    name = "travel"

    def generate(self, ctx, i, s):
        if not s.get("pos"):
            raise ValueError(f"step {i}: travel - where to? (a point clicked in the world)")
        world = s.get("world") or (ctx.place_world(s["place"]) if s.get("place") else None)
        if not world:
            raise ValueError(f"step {i}: travel - the point's world is unknown; pick it again")
        wp = f"s{i}_travel"
        x, y, z = (float(v) for v in s["pos"])
        b = f"changeworld.s{i}"
        return StepOut({b: {"destination": f"{world}/{wp}"}}, b, b, None,
                       {world: {"waypoints": {wp: {"pos": [x, y, z], "rot": [0.0, 0.0, float(s.get("yaw", 0.0))]}}}})


class Chapter:
    """chapter: {title: The baron's tale, journal: {text: "...", mode: add | replace}} - a heading on the board; with
    a journal text (Maxim 07.10.) a paragraph of the quest's journal entry from here on: added below the others, or in
    their place (the runtime's CjJournalOnly sets the others inactive - the journal shows what is not). No text: builds
    nothing."""
    name = "chapter"

    def generate(self, ctx, i, s):
        j = s.get("journal") if isinstance(s.get("journal"), dict) else {}
        text = str(j.get("text") or "").strip()
        if not text:
            return StepOut({}, None, None)
        did = f"s{i}"
        ctx.descriptions.append({did: text})
        block = f"journal.s{i}"
        blocks = {block: {"entry": f"quests/{ctx.qid}/{did}"}}
        from . import features
        if j.get("mode") != "replace" or not features.experimental():  # (replace: not yet right in the game)
            return StepOut(blocks, block, block, None)
        only = f"script.s{i}_only"
        blocks[block]["next"] = [only]
        blocks[only] = {"function": "CjJournalOnly",
                        "parameter": [{"journalQuest": f"{ctx.qid}_{ctx.qid}"}, {"keep": did}]}
        return StepOut(blocks, block, only, None)


class Random:
    """random: {ways: [{path: ambush}, {path: quiet}, {}]} - one of the ways, chosen at random, each as likely; a way
    without a path goes on in the story. Its own output per way (the game's randomize block)."""
    name = "random"

    def generate(self, ctx, i, s):
        ways = s.get("ways") or []
        if len(ways) < 2:
            raise ValueError(f"step {i}: at random - two ways at least")
        if not ctx.graph and not any(w.get("path") for w in ways):
            raise ValueError(f"step {i}: at random - every way goes on; give one a path")
        b = f"randomize.s{i}"
        branches = {f"way{k}": f"path:{w['path']}" if w.get("path") else "continue" for k, w in enumerate(ways, 1)}
        return StepOut({b: {}}, b, b, None, branches=branches)


class Gwent:
    """gwent: {deck: Zoltan, difficulty: medium | hard, lost: continue | retry | fail | path:<id>, text} - a game of
    gwent starts at once; won goes on, lost as `lost` says. A stand-in block radish can encode (a randomize block
    with the outputs Success and Failure), made the game's minigame block after encoding (minigames.py)."""
    name = "gwent"

    def generate(self, ctx, i, s):
        from .minigames import DECKS
        if s.get("deck") not in DECKS:
            raise ValueError(f"step {i}: gwent - against which deck?")
        b = f"randomize.gwent_s{i}"
        ctx.minigames[f"gwent_s{i}"] = {"deck": s["deck"], "difficulty": s.get("difficulty", "medium")}
        lost = s.get("lost") or "continue"
        return StepOut({b: {}}, b, b, {"caption": s.get("text") or "Win a game of gwent"},
                       branches={"Success": "continue", "Failure": lost})


class Fistfight:
    """fistfight: {targets: [camp/brawler, ...], radius: 10, lost: continue | retry | fail | path:<id>, text} - a fist
    fight with these people starts at once, inside a circle around them (the game's fight area, by its tag); won goes
    on, lost as `lost` says. A stand-in like Gwent's, made the game's fist fight block after encoding."""
    name = "fistfight"

    def generate(self, ctx, i, s):
        refs = [t for t in s.get("targets") or [] if t]
        if not refs:
            raise ValueError(f"step {i}: fist fight - with whom?")
        objs = [ctx.object(r) for r in refs]
        if not all(is_actor(o) for o in objs):
            raise ValueError(f"step {i}: fist fight - only people can fight with fists")
        world = ctx.place_world(refs[0].partition("/")[0])
        # where they stand by then (a Follow / Walk to / Stands before it led them away - 03.10.: the ring lay at
        # the blacksmith's first spot, 25 m from him and the player, and no fight began)
        moved = getattr(ctx, "moved", {})
        spots = [moved[r][0] if r in moved else o["pos"] for r, o in zip(refs, objs)]
        center = [sum(float(p_[k]) for p_ in spots) / len(spots) for k in range(3)]
        area = f"{ctx.qid}_s{i}_ring"
        b = f"randomize.fistfight_s{i}"
        ctx.minigames[f"fistfight_s{i}"] = {"game": "fistfight", "area": f"{ctx.qid}_{world}_{area}_ar",
                                            "enemies": [ctx.object_tag(r) for r in refs]}
        return StepOut({b: {}}, b, b, {"caption": s.get("text") or "Win the fist fight"},
                       {world: {"areas": {area: _area(center, float(s.get("radius", 10)))}}},
                       branches={"Success": "continue", "Failure": s.get("lost") or "continue"})


class StopLane:
    """stop: {path: timer} - a lane (a path a Meanwhile started) stops where it is. A stand-in radish can encode (a fact
    block), made the game's cut control block after encoding: its output Thunder leads to the input Cut of every
    block of the lane (minigames.py; the game's own: mq1035 - whichever wait comes first cuts the other)."""
    name = "stop"

    def generate(self, ctx, i, s):
        if not s.get("path"):
            raise ValueError(f"step {i}: stop lane - which lane?")
        b = f"addfact.cut_s{i}"
        ctx.minigames[f"cut_s{i}"] = {"game": "cut", "lane": s["path"]}
        return StepOut({b: {"value": [f"{ctx.qid}_cut_s{i}", 1]}}, b, b, None)


class Meanwhile:
    """meanwhile: {path: timer} - the path runs beside the main story from here (the story goes on at once); its end
    is quiet (it waits forever instead of ending the quest)."""
    name = "meanwhile"

    def generate(self, ctx, i, s):
        if not s.get("path"):
            raise ValueError(f"step {i}: meanwhile - which lane? (a path)")
        b = f"addfact.s{i}_meanwhile"
        return StepOut({b: {"value": [f"{ctx.qid}_s{i}_lane", 1]}}, b, b, None, branches={"__lane": s["path"]})


class Stands:
    """stands: {who: village/elder, pos: [x, y, z], yaw: 90, action: ...} - from now on the person stands there (a
    phase of the place's community, made in generate(); this step switches to it)."""
    name = "stands"

    def generate(self, ctx, i, s):
        comm, phase = getattr(ctx, "stand_phases", {}).get(id(s), (None, None))
        if not comm:
            raise ValueError(f"step {i}: stands - who, and where? (a person, a point in the world)")
        if s.get("pos") and hasattr(ctx, "moved"):
            ctx.moved[s["who"]] = (s["pos"], float(s.get("yaw", 0.0)))
        b = f"spawn.s{i}_stands"
        return StepOut({b: {"spawnsets": [comm], "phase": phase}}, b, b, None)


class Notice:
    """notice: {board: "village/board" (a notice board the quest placed) or "tag:<a board's tag>" (the game's own),
    title, body, item, key} - a notice on the board (the game's menu shows its title and body); taking it goes on and
    gives `item` (a readable one to read again, as the game's notices do: an own item or one of the game's). `key`:
    one of the game's notices instead of title and body (its string key: item_name_mq1043_notice)."""
    name = "notice"

    def generate(self, ctx, i, s):
        board = str(s.get("board") or "")
        if not board:
            raise ValueError(f"step {i}: notice - on which notice board?")
        tag = board[4:] if board.startswith("tag:") else ctx.object_tag(board)
        key = str(s.get("key") or "")              # one of the game's notices (its text in every language)
        if not key:
            key = f"{ctx.qid}_notice_s{i}".lower()
            ctx.keyed_string(key, s.get("title") or "Notice")
            ctx.keyed_string(key + "_text", s.get("body") or "")
        fact = f"{ctx.qid}_s{i}_taken"
        put, wait = f"script.s{i}_notice", f"waituntil.s{i}_taken"
        call = {"function": "CjNotice", "parameter": [{"board": f"cname_{tag}"}, {"key": key}, {"fact": fact}]}
        if s.get("item"):
            item = own_item(ctx, s["item"]) or str(s["item"])
            call = {"function": "CjNoticeN", "parameter": call["parameter"] + [{"item": f"cname_{item}"}]}
        blocks = {put: dict(call, next=[wait]),
                  wait: {"factdb": [fact, ">=", 1]}}
        meta, objective = ({}, {})
        if not board.startswith("tag:"):
            meta, objective = _pin(ctx, i, [board])
        objective["caption"] = s.get("text") or DEFAULT_TEXT["notice"]
        return StepOut(blocks, put, wait, objective, meta)


class WaitFact:
    """waitfact: {fact: q103_baron_met, value: 1, text: "..."} - goes on when the fact is at least `value` (a fact of
    this quest, of another one, or a moment of one of the game's quests); or {conditions: [...], any} as If has them
    (no item: that is Collect). An objective only with a text."""
    name = "waitfact"

    def generate(self, ctx, i, s):
        wait = f"waituntil.s{i}_fact"
        objective = {"caption": s["text"]} if s.get("text") else None
        if s.get("conditions"):                         # the game's conditions (conditions()), all or one of them
            meta = {}
            yes, _no = conditions(ctx, i, s, meta, [], waiting=True)
            return StepOut({wait: dict(yes)}, wait, wait, objective, meta)
        if not s.get("fact"):
            raise ValueError(f"step {i}: wait until - which fact?")
        return StepOut({wait: {"factdb": [str(s["fact"]), ">=", int(s.get("value", 1))]}}, wait, wait, objective)


class Layers:
    """show / hide a place (a place that is not visible from the start comes with a step)."""

    def __init__(self, name):
        self.name = name

    def generate(self, ctx, i, s):
        place = s["place"]
        block = f"changelayers.s{i}"
        return StepOut({block: {"world": ctx.place_world(place), self.name: [place]}}, block, block, None)


class Reward:
    """reward: {money: 100, xp: 50, items: [item names]} - crowns and experience through Conjunction's script mod,
    items as a radish reward."""
    name = "reward"

    def generate(self, ctx, i, s):
        blocks, chain = {}, []
        money, xp = int(s.get("money", 0)), int(s.get("xp", 0))
        if money or xp:
            b = f"script.s{i}_give"
            blocks[b] = {"function": "CjGive", "parameter": [{"money": money}, {"xp": xp}]}
            chain.append(b)
        items = [it for it in s.get("items") or [] if it]
        game = [it for it in items if not str(it).startswith("own:")]
        if game:
            b = f"reward.s{i}_items"
            blocks[b] = {"reward": f"{ctx.qid}_s{i}"}
            ctx.rewards[f"{ctx.qid}_s{i}"] = [f"~{it}" for it in game]
            chain.append(b)
        for k, it in enumerate(x for x in items if str(x).startswith("own:")):
            b = f"script.s{i}_own{k}"                   # the quest's own items: the script gives them
            blocks[b] = item_call(ctx, "CjPlayerItem", it, count=1)
            chain.append(b)
        if not chain:
            raise ValueError(f"step {i}: a reward needs money, xp or items")
        for a, b in zip(chain, chain[1:]):
            blocks[a]["next"] = [b]
        return StepOut(blocks, chain[0], chain[-1])


class Lock:
    """lock: {target: camp/chest, state: lock | unlock, key: Rusty key | own:cellar_key, key_goes: false} - a chest
    (anything lockable) locked with a key item, or unlocked."""
    name = "lock"

    def generate(self, ctx, i, s):
        block = f"script.s{i}_lock"
        lock = s.get("state", "lock") == "lock"
        key = str(s.get("key") or "") if lock else ""
        if own_item(ctx, key):
            call = {"function": "CjLockNQ", "parameter": [{"qid": ctx.qid}, {"tag": _tag(ctx, s)}, {"lock": lock},
                                                           {"keyName": f"cname_{own_item(ctx, key)}"},
                                                           {"keyGoes": bool(s.get("key_goes"))}]}
        else:
            call = {"function": "CjLockQ", "parameter": [{"qid": ctx.qid}, {"tag": _tag(ctx, s)}, {"lock": lock},
                                                          {"key": key},
                                                          {"keyGoes": bool(s.get("key_goes"))}]}
        return StepOut({block: call}, block, block, None)


class Hostile:
    """hostile: {target: camp/bandit} - the NPC attacks the player (friendly: true - stops again)."""
    name = "hostile"

    def generate(self, ctx, i, s):
        block = f"script.s{i}_hostile"
        return StepOut({block: {"function": "CjHostileQ", "parameter": [{"qid": ctx.qid},
            {"tag": f"cname_{ctx.object_tag(s['target'])}"}, {"hostile": not s.get("friendly", False)}]}},
            block, block, None)


class Call:
    """An action that calls one of the mod's quest functions: `params(ctx, s)` -> its parameter list."""

    def __init__(self, name, function, params):
        self.name, self.function, self.params = name, function, params

    def generate(self, ctx, i, s):
        block = f"script.s{i}_{self.name}"
        more = [t for t in s.get("more_targets") or [] if t] if s.get("target") else []
        if not more:
            return StepOut({block: {"function": self.function, "parameter": self.params(ctx, s)}}, block, block, None)
        # several things at once (Keira's four candles): a call each, one after the other
        names = [block] + [f"{block}_{k}" for k in range(1, len(more) + 1)]
        blocks = {}
        for k, (name, target) in enumerate(zip(names, [s["target"]] + more)):
            blocks[name] = {"function": self.function, "parameter": self.params(ctx, dict(s, target=target))}
            if k + 1 < len(names):
                blocks[name]["next"] = [names[k + 1]]
        return StepOut(blocks, names[0], names[-1], None)


def own_item(ctx, item):
    """The game's name of the quest's own item ("own:<id>"), or None for the game's items."""
    item = str(item or "")
    if not item.startswith("own:"):
        return None
    iid = item[4:]
    if iid not in (ctx.project.meta.get("quest") or {}).get("items", {}):
        raise ValueError(f"The quest has no own item '{iid}'")
    return f"{ctx.qid}_own_{iid}"


def step_items(a):
    """A loot / collect step's items: the first ('item', 'count') and the ones added to it ('more_items' - Maxim,
    01.10.: a whole armour set to loot)."""
    out = [{"item": a["item"], "count": int(a.get("count", 1))}] if a.get("item") else []
    return out + [{"item": x["item"], "count": int(x.get("count", 1))} for x in a.get("more_items") or []
                  if x.get("item")]


def _pack_item(ctx, item):
    """Does the item come from a mod (not the game)? (content.py; cached on the context)"""
    if not hasattr(ctx, "_origins"):
        from . import content
        try:
            ctx._origins = content.Origins()
        except OSError:
            ctx._origins = None
    o = ctx._origins
    return bool(o) and (o.item(item) or "game") not in ("game", "suite")


def item_call(ctx, function, item, **rest):
    """A script call with an item: the game's items by text (looked up in the mod), own items by name."""
    own = own_item(ctx, item)
    if own:
        return {"function": function + "N", "parameter": [{"itemName": f"cname_{own}"}] +
                [{k: v} for k, v in rest.items()]}
    if re.fullmatch(r"[a-z0-9_]+", str(item)) and _pack_item(ctx, item):
        # a content pack's item: by its name straight away (the player's item table may not know the pack yet)
        return {"function": function + "N", "parameter": [{"itemName": f"cname_{item}"}] +
                [{k: v} for k, v in rest.items()]}
    return {"function": function, "parameter": [{"item": str(item)}] + [{k: v} for k, v in rest.items()]}


def _point(s):
    if not s.get("pos"):
        raise ValueError("Walk to: where? (Pick a point on the card, then click in the world)")
    return [{"x": float(s["pos"][0])}, {"y": float(s["pos"][1])}, {"z": float(s["pos"][2])}]


def _tag(ctx, s, key="target"):
    if not s.get(key):
        raise ValueError(f"{key}: which one? (Pick, Search or Create on the card)")
    return f"cname_{ctx.object_tag(s[key])}"


CALLS = [
    Call("effect", "CjFx", lambda ctx, s: [{"tag": _tag(ctx, s)}, {"effect": f"cname_{s.get('effect', '')}"},
                                            {"on": not s.get("off", False)}]),
    Call("sound", "CjSound", lambda ctx, s: [{"soundEvent": str(s.get("event", ""))}]),
    Call("fade", "CjFadeColor", lambda ctx, s: [{"fadeOut": s.get("to", "black") == "black"},
                                                {"seconds": float(s.get("seconds", 1.0))},
                                                {"white": s.get("color") == "white"}]),
    Call("lights", "CjLights", lambda ctx, s: [{"tag": _tag(ctx, s)}, {"on": s.get("state", "on") == "on"},
                                               {"fade": bool(s.get("slow"))}]),
    Call("presence", "CjPresenceQ", lambda ctx, s: [{"qid": ctx.qid}, {"tag": _tag(ctx, s)},
                                                   {"show": s.get("state") == "show"}]),   # (noted: the fixer)
    Call("shake", "CjShake", lambda ctx, s: [{"strength": float(s.get("strength", 0.5))}]),
    Call("weather", "CjWeather", lambda ctx, s: [{"weather": f"cname_{s.get('weather', 'WT_Clear').lower()}"},
                                                 {"blend": float(s.get("seconds", 10.0))}]),
    Call("time", "CjSetTime", lambda ctx, s: [{"hour": int(str(s.get("at", "12:00")).split(":")[0])},
                                              {"minute": int(str(s.get("at", "12:00")).split(":")[1])}]),
    Call("teleport", "CjTeleport", lambda ctx, s: [{"x": float(s["pos"][0])}, {"y": float(s["pos"][1])},
                                                   {"z": float(s["pos"][2])}, {"yaw": float(s.get("yaw", 0.0))}]),
    Call("message", "CjMessage", lambda ctx, s: [{"text": str(s.get("text", ""))}]),
    Call("autosave", "CjAutosave", lambda ctx, s: []),
    Call("door", "CjDoor", lambda ctx, s: [{"tag": _tag(ctx, s)}, {"doorState": s.get("state", "open")},
                                           {"key": str(s.get("key", ""))}]),
    Call("switch", "CjSwitch", lambda ctx, s: [{"tag": _tag(ctx, s)}, {"how": s.get("state", "on")}]),
    Call("tutorial", "CjTutorial", lambda ctx, s: [{"title": str(s.get("title", ""))}, {"text": str(s.get("text", ""))},
                                                   {"seconds": float(s.get("seconds", 8))}]),

    Call("immortal", "CjImmortal", lambda ctx, s: [{"tag": _tag(ctx, s)}, {"mode": s.get("mode", "immortal")}]),
]


class Walk:
    """walk: {who: camp/bandit, pos: [x, y, z], wait: false, run: false} - the person goes there and stays; wait: the
    quest goes on when he has arrived. A person of a place goes by his community's phase (as the game's quests move
    people - an AI move does nothing to someone at his action point); others by an AI move."""
    name = "walk"

    def generate(self, ctx, i, s):
        phases = getattr(ctx, "walk_phases", {}).get(id(s))
        if not phases:
            block = f"script.s{i}_walk"
            return StepOut({block: {"function": "CjWalkTo", "parameter": [{"tag": _tag(ctx, s, "who")}] + _point(s) +
                                    [{"run": bool(s.get("run"))}, {"waitThere": bool(s.get("wait"))}]}},
                           block, block, None)
        if s.get("pos") and hasattr(ctx, "moved"):
            ctx.moved[s["who"]] = (s["pos"], _heading(ctx.object(s["who"])["pos"], s["pos"]))
        comm, names, *rest = phases
        if not s.get("wait") and not (rest and rest[0]):
            b = f"spawn.s{i}_p1"
            return StepOut({b: {"spawnsets": [comm], "phase": names[0][0]}}, b, b, None)
        blocks, first, last = walk_chain(ctx, i, s["who"], phases, 0.0, "")
        return StepOut(blocks, first, last, None)


def _heading(a, b):
    """The game's yaw of looking from a to b (0: +y, as an object's rot[2])."""
    return round(math.degrees(math.atan2(-(float(b[0]) - float(a[0])), float(b[1]) - float(a[1]))), 1)


def walk_chain(ctx, i, who, phases, wait, progress, pin=""):
    """The blocks of a walk by phases: for each point the phase that sends him there, then CjArrive (he is there,
    the player within `wait` m - 0: no waiting for the player; `progress`: the fact counting the points; `pin`: the
    step's map pin, kept on him) -> (blocks, the first block, the last block)."""
    comm, names, *rest = phases
    tag = f"cname_{ctx.object_tag(who)}"
    blocks, prev = {}, None
    if rest and rest[0]:
        # he is tied up / lying: fade out, his community away and back in the first point's phase, fade in
        out, away = f"script.s{i}_fadeout", f"despawn.s{i}_free"
        blocks[out] = {"function": "CjFadeColor", "parameter": [{"fadeOut": True}, {"seconds": 1.0},
                                                                 {"white": False}], "next": [away]}
        blocks[away] = {"spawnsets": [comm], "next": [f"spawn.s{i}_p1"]}
        prev = None
    for j, (phase, pos) in enumerate(names, 1):
        sp, ar = f"spawn.s{i}_p{j}", f"script.s{i}_at{j}"
        blocks[sp] = {"spawnsets": [comm], "phase": phase, "next": [ar]}
        blocks[ar] = {"function": "CjArrive", "parameter": [
            {"tag": tag}, {"x": pos[0]}, {"y": pos[1]}, {"z": pos[2]}, {"point": j}, {"progress": progress},
            {"waitDist": float(wait)}, {"pin": f"cname_{pin or 'cj_nopin'}"}]}
        if prev:
            blocks[prev]["next"] = [sp]
        prev = ar
    if rest and rest[0]:
        back = f"script.s{i}_fadein"
        blocks[back] = {"function": "CjFadeColor", "parameter": [{"fadeOut": False}, {"seconds": 1.0},
                                                                  {"white": False}], "next": [f"script.s{i}_at1"]}
        blocks[f"spawn.s{i}_p1"]["next"] = [back]
        return blocks, f"script.s{i}_fadeout", prev
    return blocks, f"spawn.s{i}_p1", prev


class GameAction:
    """game: {function: DoorChangeState, args: {tag: camp/door | a tag, newState: DQS_Open, ...}} - any of the game's
    quest functions (game_functions.py); enum values go through the mod's wrapper as names, tags of placed objects
    become their quest tags."""
    name = "game"

    def generate(self, ctx, i, s):
        from . import game_functions as G
        fn = s.get("function")
        if not fn:
            raise ValueError(f"step {i}: game action - which one?")
        info = G.functions().get(fn)
        if not info or not G.usable(fn):
            raise ValueError(f"step {i}: the game has no quest function {fn} conjunction can call")
        args, params = s.get("args") or {}, []
        for n, t, optional in info["params"]:
            v = args.get(n)
            if v in (None, ""):
                if optional:
                    continue
                if G.kind(t) in ("name", "string"):
                    raise ValueError(f"step {i}: {G.label(fn)} needs {n}")
                v = G.default(t)
            k = G.kind(t)
            if k == "name" and "/" in str(v):
                params.append({n: f"cname_{ctx.object_tag(v)}"})       # a placed object: its quest tag
            elif k == "enum":
                if v not in G.enums().get(t, []):
                    raise ValueError(f"step {i}: {G.label(fn)}: {n} cannot be {v} (one of {', '.join(G.enums()[t][:6])} ...)")
                params.append({n: f"cname_{v}"})                        # the wrapper takes the value's name
            else:
                params.append({n: G.radish_value(t, v)})
        block = f"script.s{i}_game"
        return StepOut({block: {"function": G.called(fn), "parameter": params}}, block, block, None)


class Item:
    """item: {item: Ruby | own:letter, count: 1, take: false} - Geralt gets (or loses) an item."""
    name = "item"

    def generate(self, ctx, i, s):
        if not s.get("item"):
            raise ValueError(f"step {i}: item - which?")
        block = f"script.s{i}_item"
        return StepOut({block: item_call(ctx, "CjPlayerItem", s["item"],
                                         count=int(s.get("count", 1)) * (-1 if s.get("take") else 1))},
                       block, block, None)


class Say:
    """say: {text, voice | voice_pack, who: village/elder, gesture: bow, mood: happy} - Geralt (or a placed person:
    who) says a line, with a gesture and a mood (subtitles, the game goes on). A gesture alone (no text) is a
    movement without words."""
    name = "say"

    def generate(self, ctx, i, s):
        if s.get("who"):
            return self.person(ctx, i, s)
        if not (s.get("text") or s.get("voice") or s.get("voice_pack")):
            raise ValueError(f"step {i}: the player says - what?")
        place = next((n for n, p in ctx.project.places.items() if p.get("world") and p.get("objects")), None)
        if place is None:
            raise ValueError(f"step {i}: the player says - place something first (the line needs a world)")
        world = ctx.place_world(place)
        x, y, z = ctx.place_center(place)
        name = f"{ctx.qid}_s{i}_say"
        sp = f"{name}_sp"
        sc, _ends = Talk.scene(ctx, 800 + int(i), name, [dict(s, who="player")], None, None, f"{name}_f",
                               gameplay=True, character=ctx.character(s))
        ctx.extra_meta.setdefault(world, {}).setdefault("scenepoints", {})[sp] = [x, y, z, 0.0]
        block = f"scene.s{i}_say"
        return StepOut({block: {"scene": f"dlc/dlc{ctx.qid}/data/scenes/{name}.w2scene",
                                "placement": f"{world}/{sp}"}}, block, block, None, scenes={name: sc})

    def person(self, ctx, i, s):
        """A placed person says it (or only moves: a gesture without text) where they stand."""
        if not (s.get("text") or s.get("voice") or s.get("voice_pack") or s.get("gesture")):
            raise ValueError(f"step {i}: says - what? (a line or a gesture)")
        o = ctx.object(s["who"])
        world = ctx.place_world(s["who"].partition("/")[0])
        x, y, z = o["pos"]
        name = f"{ctx.qid}_s{i}_says"
        sp = f"{name}_sp"
        line = {k: v for k, v in s.items() if k != "who"}
        line["who"] = "npc"
        line.setdefault("text", "...")                  # a gesture alone: the line is a pause
        sc, _ends = Talk.scene(ctx, 850 + int(i), name, [line], o, ctx.object_tag(s["who"]), f"{name}_f",
                               gameplay=True, character=ctx.character(s))
        ctx.extra_meta.setdefault(world, {}).setdefault("scenepoints", {})[sp] = [x, y, z, 0.0]
        block = f"scene.s{i}_says"
        return StepOut({block: {"scene": f"dlc/dlc{ctx.qid}/data/scenes/{name}.w2scene",
                                "placement": f"{world}/{sp}"}}, block, block, None, scenes={name: sc})


class Person:
    """person: {who: village/elder, name: Old Tomas, image: journal_grandma.png, text: "...", main: false} - the
    person's page in the journal (characters), with this paragraph."""
    name = "person"

    def generate(self, ctx, i, s):
        if not s.get("who"):
            raise ValueError(f"step {i}: journal person - who?")
        cid = "".join(c if c.isalnum() else "_" for c in f"{ctx.qid}_{s['who']}".lower())
        page = ctx.characters.setdefault(cid, {
            "name": s.get("name") or s["who"].split("/")[-1].replace("_", " ").capitalize(),
            "group": "main" if s.get("main") else "secondary",
            "image": s.get("image") or "journal_grandma.png", "description": []})
        entry = f"e{i}"
        page["description"].append({entry: s.get("text") or "..."})
        block = f"journal.s{i}_person"
        return StepOut({block: {"entry": f"characters/{cid}/{entry}", "activate_root": True}}, block, block, None)


class Portal:
    """portal: {a: place/obj, b: place/obj, b_exit: [x, y, z], b_yaw, a_exit: [x, y, z], a_yaw, two_way, white,
    effect, radius} - stepping into A takes the player to B's exit, into B (two-way) back to A's exit; a fade between
    (white like a mage's portal); the effect plays on both (open). It runs beside the story from this step on - the
    quest goes on at once (Keira's hut and her bath, q104)."""
    name = "portal"

    def generate(self, ctx, i, s):
        if not s.get("a") or not s.get("b_exit"):
            raise ValueError(f"step {i}: portal - which object, and where it leads? (the card: From, To)")
        two = bool(s.get("two_way") and s.get("b") and s.get("a_exit"))
        a_exit = s.get("a_exit") or [0.0, 0.0, 0.0]
        fork, run, on = f"addfact.s{i}_portal", f"script.s{i}_portal", f"addfact.s{i}_portal_on"
        effect = str(s.get("effect") or "none").lower()
        blocks = {
            fork: {"value": [f"{ctx.qid}_s{i}_portal", 1], "next": [run, on]},
            run: {"function": "CjPortal", "parameter": [
                {"tagA": f"cname_{ctx.object_tag(s['a'])}"},
                {"tagB": f"cname_{ctx.object_tag(s['b'])}" if s.get("b") else "cname_none"},
                {"ax": float(a_exit[0])}, {"ay": float(a_exit[1])}, {"az": float(a_exit[2])},
                {"ayaw": float(s.get("a_yaw", 0.0))},
                {"bx": float(s["b_exit"][0])}, {"by": float(s["b_exit"][1])}, {"bz": float(s["b_exit"][2])},
                {"byaw": float(s.get("b_yaw", 0.0))}, {"radius": float(s.get("radius", 1.3))},
                {"twoWay": two}, {"white": s.get("white", True) is not False}, {"effect": f"cname_{effect}"}]},
            on: {"value": [f"{ctx.qid}_s{i}_portal_on", 1]}}
        return StepOut(blocks, fork, on)


def step_world(ctx, s):
    """The world a step with a point is in: picked with it, else its place's, else the project's first."""
    if s.get("world"):
        return s["world"]
    if s.get("place") and s["place"] in ctx.project.places:
        return ctx.place_world(s["place"])
    return next((p.get("world") for p in ctx.project.places.values() if p.get("world")), "velen")


class Encounters:
    """encounters: {pos, radius, state: off | on, world} - the game's own creatures of the area (its encounters:
    wolves, drowners) stop and go, or come back. The game finds an encounter only by its tag: those within the
    radius are looked up in the world's index (encounters.py), a call each."""
    name = "encounters"

    def generate(self, ctx, i, s):
        from . import encounters
        if not s.get("pos"):
            raise ValueError(f"step {i}: creatures nearby - where? (the card: around, pick a point)")
        world = step_world(ctx, s)
        tags = [t for t, _d in encounters.near(world, s["pos"], float(s.get("radius", 60)))]
        if not tags:
            raise ValueError(f"step {i}: creatures nearby - the game has none within {s.get('radius', 60)} m there")
        on = s.get("state") == "on"
        names = [f"script.s{i}_encounters" + (f"_{k}" if k else "") for k in range(len(tags))]
        blocks = {}
        for k, (name, tag) in enumerate(zip(names, tags)):
            blocks[name] = {"function": "CjEncounterQ", "parameter": [{"qid": ctx.qid}, {"tag": f"cname_{tag}"},
                                                                       {"enable": on}]}
            if k + 1 < len(names):
                blocks[name]["next"] = [names[k + 1]]
        return StepOut(blocks, names[0], names[-1], None)


class Fact:
    name = "fact"

    def generate(self, ctx, i, s):
        block = f"addfact.s{i}"
        return StepOut({block: {"value": [s["name"], int(s.get("value", 1))]}}, block, block, None)


class WorldChange:
    """worldchange: {change: <id in world.yml>, state: on | off} - from here on a change to an object the game placed
    holds (on) or no longer holds (off): the fact the script extender asks (worldchanges.py)."""
    name = "worldchange"

    def generate(self, ctx, i, s):
        from .worldchanges import facts
        if not s.get("change"):
            raise ValueError(f"step {i}: change the world - which change? (make one on an object in the editor)")
        on, off = facts(ctx.qid, int(s["change"]))
        block = f"addfact.s{i}_world"
        return StepOut({block: {"value": [on if s.get("state", "on") == "on" else off, 1]}}, block, block, None)


class PlayAs:
    """playas: {as: ciri | geralt, look: wounded | winter | naked, pos: [x, y, z], yaw} - from here on the player is
    someone else, as the game's own quests do it (ChangePlayerQuest: the Baron's story told as Ciri). pos: taken
    there first, behind a black screen. Talks after it are played with that character (its face, voice, lines)."""
    name = "playas"

    def generate(self, ctx, i, s):
        from .dialogue import PLAYERS
        who = s.get("as")
        if who not in PLAYERS:
            raise ValueError(f"step {i}: play as - whom?")
        pos = s.get("pos") or [0.0, 0.0, 0.0]
        b = f"script.s{i}_playas"
        return StepOut({b: {"function": "CjPlayAs", "parameter": [
            {"who": who}, {"look": str(s.get("look") or "")}, {"x": float(pos[0])}, {"y": float(pos[1])},
            {"z": float(pos[2])}, {"yaw": float(s.get("yaw", 0.0))}, {"move": bool(s.get("pos"))}]}}, b, b, None)


class End:
    """end: {how: success | fail} - the quest ends here (the graph's End block: anywhere, in the story or a path)."""
    name = "end"

    def generate(self, ctx, i, s):
        b = f"addfact.s{i}_end"
        how = "fail" if s.get("how") == "fail" else "success"
        return StepOut({b: {"value": [f"{ctx.qid}_end_s{i}", 1]}}, b, b, None, branches={"": how})


IF_OPS = {"=": "!=", "!=": "=", ">=": "<", "<": ">=", ">": "<=", "<=": ">"}


class If:
    """if: {conditions: [{kind: fact | path | area | item | quest | time | present | combat, ..., not}], any} - or the
    older {path: <id>} / {fact, op, value}; yes / no: path:<id> or empty (goes on) - the quest goes one way or the
    other (a waituntil whose two conditions exclude each other: one holds at once; conditions())."""
    name = "if"

    def generate(self, ctx, i, s):
        if not conditions_of(s):
            raise ValueError(f"step {i}: if - what? (a path taken before, a fact, an area, an item ...)")
        meta, pre = {}, []
        yes, no = conditions(ctx, i, s, meta, pre)
        b = f"waituntil.s{i}_if"
        blocks = {b: {"conditions": {"yes": yes, "no": no}}}
        first = b
        for name, block in reversed(pre):               # (an item counted first)
            blocks[name] = dict(block, next=[first])
            first = name
        return StepOut(blocks, first, b, None, meta,
                       branches={"yes": s.get("yes") or "continue", "no": s.get("no") or "continue"})


# --- "every time" (Maxim 05.10.: "kein while-block, eine option jedes mal an einem ziel, bis ..."): a goal that
# repeats. Done, the story goes on once (its objective ticked off once); what its output "every time" leads to runs,
# then the goal is made ready again and waits once more - as the game's quests loop (talk -> short wait -> talk 706
# times; wait for a fact -> remove it -> wait 52; in the area -> outside -> in the area again). "until": a fact, a
# step reached, or the quest's end; the loop is cut there (the game's cut control block, as Stop lane).
def again(ctx, i, kind, s, out):
    """A goal that repeats: the block it comes in by again, and the blocks that make it ready first, in order
    -> (entry, [(name, block)])."""
    def clear(fact, name):
        return (f"script.s{i}_{name}", {"function": "RemoveFactQuest", "parameter": [{"factId": f"cname_{fact}"}]})
    if kind == "goto":
        b = out.blocks.get(out.first) or {}
        if "entered" in b:                              # in the area again: first out of it
            return out.first, [(f"waituntil.s{i}_left", {"left": b["entered"]})]
        last = out.blocks.get(out.last) or {}
        if "factdb" in last and not s.get("stay"):      # near someone, looking, away: the script's fact cleared
            return out.first, [clear(last["factdb"][0], "again")]
        raise ValueError(f"step {i}: go to - 'every time' works for arriving in an area, near someone, looking, "
                         f"getting away (not with a time of day or 'stay')")
    if kind == "waitfact":
        if s.get("conditions"):
            conds = conditions_of(s)
            if any(cond_kind(c) != "fact" or c.get("not") for c in conds):
                raise ValueError(f"step {i}: wait until - 'every time' works with facts (they are removed and "
                                 f"waited for again), not with an area, a quest, the time ...")
            return out.first, [clear(c["fact"], f"again{k}") for k, c in enumerate(conds)]
        fact = (out.blocks.get(out.first) or {}).get("factdb", [s.get("fact")])[0]
        return out.first, [clear(fact, "again")]       # (the game's quests: remove the fact, wait for it again)
    if kind == "wait":
        if s.get("until"):
            raise ValueError(f"step {i}: wait - 'every time' works with a time that passes, not with 'until'")
        return out.first, []
    if kind == "talk":
        start = s.get("start", "interact")
        if start == "now":
            raise ValueError(f"step {i}: talk - a cutscene ('immediately') plays once; 'every time' needs E or near")
        entry = f"interaction.s{i}" if start in ("interact", "calls") else out.first
        made = []
        choice = out.blocks.get(f"waituntil.s{i}_choice")
        if choice:                                      # the answer's fact of the time before: away
            fact = next(iter(choice["conditions"].values()))["factdb"][0]
            made.append(clear(fact, "again"))
        made.append((f"waituntil.s{i}_again", {"elapsed": "00:00:02"}))     # (as the game: a breath before)
        return entry, made
    raise ValueError(f"step {i}: '{kind}' cannot repeat - 'every time' is for Go to, Wait until, Wait, Talk")


def _chain(blocks, entry):
    """The names of a step's blocks reached from `entry` along their links (only the step's own)."""
    seen, todo = [], [entry]
    while todo:
        n = todo.pop(0)
        if n in seen or n not in blocks:
            continue
        seen.append(n)
        for key, targets in blocks[n].items():
            if key.startswith("next") and isinstance(targets, list):
                todo += [next(iter(t)) if isinstance(t, dict) else t for t in targets]
    return seen


def _renamed(targets, names):
    """A copy's links: those to the step's own blocks to their copies, the others left out."""
    out = []
    for t in targets:
        if isinstance(t, dict):
            (k, sock), = t.items()
            if k in names:
                out.append({names[k]: sock})
        elif t in names:
            out.append(names[t])
    return out


# --- conditions of If and Wait until (Maxim 05.10.: "fehlen conditions?"): what the game's own Ifs and waits check,
# counted over its quests - a fact (5102 Ifs), a quest's state (781), the player in an area (557), has an item (594),
# the time of day (119), someone there (106), fighting (97); several: all of them or one of them, each one or 'not'.
# Each the game's own condition class (quest_encoder.py), its 'no' the game's own reverse (the comparison turned,
# isInside off, inverted, the hours swapped - the game's periods run past midnight 146 times of 266).
COND_KINDS = [("fact", "a fact"), ("path", "a branch was taken"), ("area", "the player is in an area"),
              ("item", "the player has an item"), ("quest", "a quest's state"), ("time", "the time of day"),
              ("present", "someone is there"), ("combat", "the player is fighting")]
WAIT_KINDS = [k for k, _l in COND_KINDS if k != "item"]     # (waiting for an item: Collect)
QUEST_STATES = [("active", "is running", "JS_Active"), ("done", "is done", "JS_Success"),
                ("failed", "has failed", "JS_Failed")]


def conditions_of(s):
    """A step's conditions: its list - or the older If / Wait until (a fact, a branch) as one."""
    if s.get("conditions"):
        return list(s["conditions"])
    if s.get("path"):
        return [{"kind": "path", "path": s["path"]}]
    if s.get("fact"):
        return [{"kind": "fact", "fact": s["fact"], "op": s.get("op") or ">=", "value": s.get("value", 1)}]
    return []


def cond_kind(c):
    return c.get("kind") or next((k for k, _l in COND_KINDS if k in c), "fact")


def _seconds(text):
    h, m = (int(v) for v in str(text).split(":")[:2])
    return (h % 24) * 3600 + m * 60


def condition(ctx, i, k, c, meta, pre, waiting=False):
    """One condition -> (holds, holds not): conditions of the game's wait block (quest_encoder.condition). An item
    is counted by a script first (`pre` gets its block); an area is a trigger area of the quest (`meta`)."""
    kind = cond_kind(c)
    where = f"step {i}, condition {k + 1}"
    if kind == "fact":
        if not c.get("fact"):
            raise ValueError(f"{where}: which fact?")
        op = str(c.get("op") or ">=")
        if op not in IF_OPS:
            raise ValueError(f"{where}: unknown comparison '{op}'")
        value = int(c.get("value", 1))
        yes, no = {"factdb": [str(c["fact"]), op, value]}, {"factdb": [str(c["fact"]), IF_OPS[op], value]}
    elif kind == "path":
        if not c.get("path"):
            raise ValueError(f"{where}: which branch?")
        fact = path_fact(ctx.qid, c["path"])
        yes, no = {"factdb": [fact, ">=", 1]}, {"factdb": [fact, "<", 1]}
    elif kind == "area":
        if c.get("at"):
            place, _, oid = c["at"].partition("/")
            o = next((o for o in ctx.project.places.get(place, {}).get("objects", []) if o.get("id") == oid), None)
            if o is None:
                raise ValueError(f"{where}: its spot ({c['at']}) is gone. Please set it again")
            world, center = ctx.place_world(place), o["pos"]
        elif c.get("place"):
            world, center = ctx.place_world(c["place"]), c.get("pos") or ctx.place_center(c["place"])
        elif c.get("world") and c.get("pos"):
            world, center = c["world"], c["pos"]
        else:
            raise ValueError(f"{where}: in which area? (a spot)")
        area = f"{ctx.qid}_s{i}_c{k + 1}_area"
        meta.setdefault(world, {}).setdefault("areas", {})[area] = _area(center, float(c.get("radius", 10)))
        yes, no = {"inside": f"{world}/{area}"}, {"outside": f"{world}/{area}"}
    elif kind == "item":
        if waiting:
            raise ValueError(f"{where}: for waiting until the player has an item, use Collect")
        if not c.get("item"):
            raise ValueError(f"{where}: which item?")
        fact = f"{ctx.qid}_s{i}_c{k + 1}_has"
        pre.append((f"script.s{i}_c{k + 1}_has", item_call(ctx, "CjHasItemsNow", c["item"],
                                                           count=int(c.get("count", 1)), fact=fact)))
        yes, no = {"factdb": [fact, "=", 1]}, {"factdb": [fact, "=", 2]}
    elif kind == "quest":
        q = c.get("quest") or {}
        if not (q.get("file") and q.get("obj")):
            raise ValueError(f"{where}: which quest (or objective)?")
        status = {k_: s_ for k_, _l, s_ in QUEST_STATES}.get(c.get("state") or "done")
        if not status:
            raise ValueError(f"{where}: unknown quest state '{c.get('state')}'")
        entry = {"file": q["file"], "obj": int(q["obj"])}
        yes = {"journal": entry, "status": status}
        no = {"journal": entry, "status": status, "inverted": True}
    elif kind == "time":
        try:
            fr, to = _seconds(c.get("from") or "20:00"), _seconds(c.get("to") or "06:00")
        except ValueError:
            raise ValueError(f"{where}: time of day from and to as hh:mm") from None
        yes, no = {"period": [fr, to]}, {"period": [to, fr]}
    elif kind == "present":
        tag = ctx.object_tag(c["who"]) if c.get("who") else c.get("tag")
        if not tag:
            raise ValueError(f"{where}: who?")
        yes = {"present": [str(tag)]}
        no = {"nor": [{"present": [str(tag)]}]}
    elif kind == "combat":
        yes, no = {"combat": True}, {"combat": False}
    else:
        raise ValueError(f"{where}: unknown condition '{kind}'")
    return (no, yes) if c.get("not") else (yes, no)


def conditions_text(s):
    """A step's conditions in a few words (the node's line): 'met_baron >= 1 or 22:00-04:00'."""
    words = []
    for c in conditions_of(s):
        kind = cond_kind(c)
        if kind == "fact":
            w = f"{c.get('fact') or '?'} {c.get('op') or '>='} {c.get('value', 1)}"
        elif kind == "path":
            w = f"'{c.get('path') or '?'}' taken"
        elif kind == "area":
            w = "in the area" + (f" ({c['place']})" if c.get("place") else "")
        elif kind == "item":
            w = f"has {c.get('count', 1)} {str(c.get('item') or '?').replace('own:', '')}"
        elif kind == "quest":
            label = ((c.get("quest") or {}).get("label") or "a quest").split(" / ")[-1]
            w = f"{label} {dict((k, x) for k, x, _s in QUEST_STATES).get(c.get('state') or 'done', '')}"
        elif kind == "time":
            w = f"{c.get('from') or '20:00'}-{c.get('to') or '06:00'}"
        elif kind == "present":
            w = f"{str(c.get('who') or c.get('tag') or '?').split('/')[-1]} there"
        else:
            w = "fighting"
        words.append(("not " if c.get("not") else "") + w)
    return (" or " if s.get("any") else " and ").join(words)


def conditions(ctx, i, s, meta, pre, waiting=False):
    """A step's conditions together -> (holds, holds not): all of them (or one of them: `any`) - and the reverse."""
    conds = conditions_of(s)
    if not conds:
        raise ValueError(f"step {i}: {'wait until' if waiting else 'if'} - what? (a condition)")
    pairs = [condition(ctx, i, k, c, meta, pre, waiting) for k, c in enumerate(conds)]
    if len(pairs) == 1:
        return pairs[0]
    yes, no = [p[0] for p in pairs], [p[1] for p in pairs]
    if s.get("any"):
        return {"any": yes}, {"all": no}
    return {"all": yes}, {"any": no}


# --- the game's common actions as nodes of their own (Maxim 05.10.; counted in its quests: controls blocked 734,
# a target forced 484, health 420, talking off 279, a weapon drawn 263, a look changed 208, a time lapse 182, a boss's
# health bar 163, a merchant on / off 119, the witcher senses' highlight 626) - each the game's quest function with
# readable fields (GameAction does the typing: tags of placed people, enums through Conjunction's wrappers)
CONTROLS = [("all", "everything"), ("fastTravel", "fast travel"), ("meditation", "meditation"),
            ("callHorse", "calling the horse"), ("mount", "riding"), ("runAndSprint", "running"),
            ("drawWeapon", "drawing weapons"), ("signs", "signs"), ("openMap", "the map"),
            ("openInventory", "the inventory"), ("interactions", "interacting")]
WEAPONS = [("steel", "steel sword", "EDWQT_Steel"), ("silver", "silver sword", "EDWQT_Silver"),
           ("fists", "fists", "EDWQT_Fists"), ("none", "sheathed", "EDWQT_NoWeapon")]
LAPSES = [("cinematic_text_some_time_later", "Some time later"), ("cinematic_text_few_hours_later",
                                                                  "A few hours later"),
          ("cinematic_text_while_later", "A while later"), ("cinematic_text_day_later", "A day later")]
HIGHLIGHTS = [("clue", "as a clue (red)", "FMV_Clue"), ("interactive", "as something to use (yellow)",
                                                           "FMV_Interactive"), ("none", "not", "FMV_None")]


def _who(ctx, s, key="who"):
    """A person of a place (its quest tag), or the player."""
    return s[key] if s.get(key) else "PLAYER"


class Preset:
    """An action that is one of the game's quest functions: `args(ctx, i, s)` -> its arguments (GameAction)."""

    def __init__(self, name, function, args, needs=()):
        self.name, self.function, self.args, self.needs = name, function, args, needs

    def generate(self, ctx, i, s):
        for key in self.needs:
            if not s.get(key):
                raise ValueError(f"step {i}: {self.name} - {key}?")
        out = GameAction().generate(ctx, i, {"function": self.function, "args": self.args(ctx, i, s)})
        b = out.first                                   # (named after the action, not 'game')
        name = f"script.s{i}_{self.name}"
        out.blocks = {name: out.blocks[b]}
        out.first = out.last = name
        return out


class Highlight:
    """highlight: {target: camp/chest, how: clue | interactive | none} - the witcher senses show it (FocusSetHighlight;
    latent with an enum: written as the game writes it, the enum's value by name - no wrapper)."""
    name = "highlight"

    def generate(self, ctx, i, s):
        if not s.get("target"):
            raise ValueError(f"step {i}: highlight - what?")
        how = {k: e for k, _l, e in HIGHLIGHTS}.get(s.get("how") or "clue", "FMV_Clue")
        b = f"script.s{i}_highlight"
        return StepOut({b: {"function": "FocusSetHighlight", "parameter": [
            {"tag": f"cname_{ctx.object_tag(s['target'])}"}, {"highlightType": f"enum:EFocusModeVisibility:{how}"},
            {"overrideCustomLogic": False}]}}, b, b, None)


class GoAway:
    """goaway: {who: village/elder} - the person goes from the world (their community despawned: a person who is
    asked to go has one of their own, as those who walk)."""
    name = "goaway"

    def generate(self, ctx, i, s):
        if not s.get("who"):
            raise ValueError(f"step {i}: goes away - who?")
        comm = getattr(ctx, "person_comm", {}).get(s["who"]) or getattr(ctx, "foes", {}).get(s["who"])
        if not comm:
            raise ValueError(f"step {i}: goes away - {s['who']} is no person placed in a place")
        b = f"despawn.s{i}_goaway"
        return StepOut({b: {"spawnsets": [comm]}}, b, b, None)


def _controls(ctx, i, s):
    what = set(s.get("what") or ["all"])
    return dict({k: k in what for k, _l in CONTROLS}, lock=not s.get("unlock"),
                sourceName=f"{ctx.qid}_controls")


PRESETS = [
    Preset("controls", "BlockGameplayFunctionality", _controls),
    Preset("health", "SetHealthQuest", lambda ctx, i, s: {"targetTag": _who(ctx, s), "healthPerc":
                                                          int(s.get("percent", 100)), "relative": False}),
    Preset("target", "ForceTargetQuest", lambda ctx, i, s: {"npcTag": s["who"], "targetTag": _who(ctx, s, "at"),
                                                            "unforce": bool(s.get("stop"))}, needs=("who",)),
    Preset("notalk", "DisableNPCInteractivness", lambda ctx, i, s: {
        "npcTag": s["who"], "disableTalking": not s.get("again"), "disableOnliners": not s.get("again"),
        "disableLookats": False}, needs=("who",)),
    Preset("weapon", "DrawWeaponQuest", lambda ctx, i, s: {"weapon": {k: e for k, _l, e in WEAPONS}.get(
        s.get("weapon") or "steel"), "dontIgnoreDrawActionLock": False}),
    Preset("look", "AppearanceChange", lambda ctx, i, s: {"npcsTag": _who(ctx, s), "appearanceName":
                                                          str(s.get("appearance") or "")}, needs=("appearance",)),
    Preset("timelapse", "ShowTimeLapse", lambda ctx, i, s: {"showTime": float(s.get("seconds", 5)),
                                                            "timeLapseMessageKey": s.get("text") or LAPSES[0][0]}),
    Preset("bossbar", "ShowBossFightIndicator", lambda ctx, i, s: {"enable": not s.get("off"), "bossTag": s["who"]},
           needs=("who",)),
    Preset("shop", "EnableShopkeeper", lambda ctx, i, s: {"tag": s["who"], "enable": not s.get("off")},
           needs=("who",)),
]

# the graph's blocks dropped but not yet told what they do
PLACEHOLDERS = {"goal": "what the player does", "action": "what happens", "choice": "which choice",
                "parallel": "Meanwhile or Stop lane"}


BLOCKS = {b.name: b for b in (Goto(), Interact("loot", "looted", "Search it"),
                              Interact("examine", "examined", "Examine it"), Interact("use", "used", "Use it"),
                              Talk(), Kill(), Collect(), Equip(), Note(), Wait(), Layers("show"), Layers("hide"), Fact(), Reward(),
                              Either(), Hostile(), Clues(), Say(), Defeat(), Read(), Person(), Item(), Follow(),
                              Patrol(), AllOf(), Lock(), GameAction(), WaitFact(), Stands(), Meanwhile(), StopLane(), Walk(),
                              Random(), Gwent(), Fistfight(), Chapter(), Travel(), PlayAs(), End(), If(), Portal(),
                              Encounters(), Notice(), WaitFor(), WorldChange(), Highlight(), GoAway(), Race(),
                              *CALLS, *PRESETS)}


# steps that change the world (a test that starts later still gets them)
WORLD_ACTIONS = {"show", "hide", "fact", "hostile", "immortal", "door", "switch", "lock", "item", "weather", "time",
                 "stands",
                 "walk",
                 "patrol", "portal", "lights", "presence", "encounters", "worldchange"}


def carried(step):
    """What the player would carry after a step a test skips (Play from here): the items a loot / collect step has
    him take, a reward's items - given as Item steps (Maxim 02.10.: from the hand-over on, the boots were missing)."""
    kind, a = step_type(step)
    a = a or {}
    if kind in ("loot", "collect"):
        got = ([{"item": a["item"], "count": a.get("count", 1)}] if a.get("item") else []) + \
            [x for x in a.get("more_items") or [] if x.get("item")]
    elif kind == "reward":
        got = [x if isinstance(x, dict) else {"item": x} for x in a.get("items") or []]
    else:
        got = []
    return [{"item": {"item": x["item"], "count": int(x.get("count", 1))}} for x in got if x.get("item")]


# the journal's objective when the author wrote none (the board shows the same as a hint)
DEFAULT_TEXT = {"talk": "Talk to {who}", "goto": "Go to {where}", "loot": "Search {what}", "examine": "Examine {what}",
                "use": "Use {what}", "kill": "Kill {what}", "collect": "Collect {what}", "wait": "Wait",
                "either": "Decide", "all": "Do all of these", "clues": "Look for clues with your witcher senses", "defeat": "Defeat {who}",
                "read": "Read {what}", "follow": "Follow {who}", "gwent": "Win a game of gwent",
                "fistfight": "Beat {who} in a fist fight", "notice": "Check the notice board"}


def _item_name(ref, items=None):
    """What an item is called in a line: an own item by its name, a game item by its (readable) id."""
    ref = str(ref or "")
    if ref.startswith("own:"):
        return str(((items or {}).get(ref[4:]) or {}).get("name") or ref[4:].replace("_", " "))
    return ref.replace("_", " ")


def _which(kind, args, q, ctx):
    """Which step an error is about, in the graph's words: its journal line, or its kind (the graph numbers only goals,
    and those in each path anew - the build's step numbers are not to be found there)."""
    from .questboard import LABEL
    line = (args or {}).get("text") or default_text(kind, args or {}, q.get("items"), getattr(ctx, "names", None))
    return f" - the {LABEL.get(kind, kind)} step" + (f" '{line}'" if line else "")


def _caption(ctx, kind, s):
    """A step's journal line: its own, or the one made from it."""
    return s.get("text") or default_text(kind, s, ctx.own_items(), getattr(ctx, "names", None))


def display_names(project):
    """{place/id: the name shown above a person} - what journal lines made from a step call them."""
    return {f"{place}/{o['id']}": o["display"] for place, p in project.places.items()
            for o in p.get("objects", []) if o.get("id") and o.get("display")}


def default_text(kind, a, items=None, names=None):
    """The journal line of a step made from it (its author left it empty); `items`: the quest's own items; `names`:
    display_names() - a person with a name shown above them is called by it."""
    def call(ref):
        ref = str(ref or "")
        return (names or {}).get(ref) or ref.split("/")[-1].replace("_", " ")
    if kind == "follow" and a.get("lead"):
        who = call(a.get("who")) or "them"
        return f"Lead {who} to safety"
    if kind == "use" and (a.get("item") or a.get("state")):
        where = str(a.get("object") or "").split("/")[-1].replace("_", " ") or "it"
        if a.get("state") in ("on", "off"):
            return f"Switch the {where} {a['state']}"
        return f"Use the {_item_name(a['item'], items)} on the {where}"
    if kind in ("loot", "collect") and len(step_items(a)) > 1:
        many = step_items(a)
        what = f"the {_item_name(many[0]['item'], items)} and the {_item_name(many[1]['item'], items)}" \
            if len(many) == 2 else f"the {_item_name(many[0]['item'], items)} and {len(many) - 1} more items"
        where = str(a.get("object") or "").split("/")[-1].replace("_", " ") if kind == "loot" else ""
        return ("Take " if kind == "loot" else "Get ") + what + (f" from the {where}" if where else "")
    if kind == "equip" and step_items(a):
        many = step_items(a)
        return f"Equip the {_item_name(many[0]['item'], items)}" + (
            f" and the {_item_name(many[1]['item'], items)}" if len(many) == 2 else
            f" and {len(many) - 1} more items" if len(many) > 2 else "")
    if kind == "loot" and a.get("item"):
        where = str(a.get("object") or "").split("/")[-1].replace("_", " ")
        return f"Take the {_item_name(a['item'], items)}" + (f" from the {where}" if where else "")
    if kind == "talk":
        # a talk whose answer hands something over (a Deliver): what to bring, and to whom
        from . import dialogue as D
        give = next((x["give"].get("item") for x in D.walk(D.from_step(a)) if (x.get("give") or {}).get("item")), None)
        if give:
            who = call(a.get("npc"))
            return f"Bring {_item_name(give, items)}" + (f" to {who}" if who else "")
    if kind == "goto" and (a.get("pos") or a.get("at")) and not a.get("text"):
        return "Go to the marked place"
    what = (a.get("npc") or a.get("who") or a.get("object") or a.get("target") or ((a.get("targets") or [""])[0]) or a.get("item")
            or a.get("place") or "")
    what = _item_name(what, items) if str(what).startswith("own:") else call(what)
    return DEFAULT_TEXT.get(kind, "").format(who=what or "someone", where=what or "a place", what=what or "it")


def speaking_people(q):
    """The object references of everyone who speaks: talk partners, people who join a talk or speak in it, says."""
    from . import dialogue as D
    out = set()
    for st in all_steps(q):
        kind, a = step_type(st)
        a = a or {}
        if kind == "talk":
            out.add(a.get("npc"))
            out.update(w.get("who") for w in a.get("with") or [])
            for x in D.walk(D.from_step(a)):
                if "/" in str(x.get("who", "")):
                    out.add(x["who"])
        elif kind == "say" and a.get("who"):
            out.add(a["who"])
    return {r for r in out if r}


def characters(q):
    """{id of a step's arguments (and of everything inside them): who is played there}. The quest starts as
    q['player'] (Geralt when not set); a 'playas' step changes it for what follows (along the wires of a graph; in
    the older form a path is played as whoever goes into it, the first step that names it)."""
    from .dialogue import PLAYERS
    start = q.get("player") or "geralt"
    if is_graph(q):
        out, who_at, queue = {}, {START: start}, [START]

        def mark_all(x, who):
            if isinstance(x, dict):
                out[id(x)] = who
                for v in x.values():
                    mark_all(v, who)
            elif isinstance(x, list):
                for v in x:
                    mark_all(v, who)
        while queue:
            nid = queue.pop(0)
            node = q["nodes"].get(nid)
            if node is None:
                continue
            who = who_at[nid]
            mark_all(node["step"], who)
            kind, args = step_type(node["step"])
            if kind == "playas" and (args or {}).get("as") in PLAYERS:
                who = args["as"]
            for _a, _p, b in links_from(q, nid):
                if b not in who_at:
                    who_at[b] = who
                    queue.append(b)
        for nid, node in q["nodes"].items():             # nothing leads there: as the quest starts
            if nid not in who_at:
                mark_all(node["step"], start)
        return out
    paths = q.get("paths") or {}
    out, entry = {}, {}

    def mark(x, who):
        if isinstance(x, dict):
            out[id(x)] = who
            for v in x.values():
                mark(v, who)
        elif isinstance(x, list):
            for v in x:
                mark(v, who)
        elif isinstance(x, str):
            pid = x[5:] if x.startswith("path:") else x
            if pid in paths:
                entry.setdefault(pid, who)

    def run(steps, who):
        for st in steps or []:
            mark(st, who)
            if isinstance(st, dict) and len(st) == 1:
                kind, args = next(iter(st.items()))
                if kind == "playas" and (args or {}).get("as") in PLAYERS:
                    who = args["as"]
        return who

    run(q.get("steps"), start)
    done = set()
    while True:
        todo = [pid for pid in paths if pid not in done and pid in entry]
        if not todo:
            break
        for pid in todo:
            done.add(pid)
            run(paths[pid].get("steps"), entry[pid])
    for pid, p in paths.items():
        if pid not in done:
            run(p.get("steps"), start)
    return out


def all_steps(q):
    """Every step of the quest (its graph's nodes; the older form: the story and its paths)."""
    if is_graph(q):
        return [n["step"] for n in q["nodes"].values() if step_type(n["step"])[0] not in ("start", "remember")]
    out = list(q.get("steps") or [])
    for p in (q.get("paths") or {}).values():
        out += p.get("steps") or []
    return out


def reach(q, starts):
    """The node ids reachable from these along the wires (them too)."""
    seen, todo = set(), list(starts)
    while todo:
        nid = todo.pop()
        if nid in seen:
            continue
        seen.add(nid)
        todo += [b for _a, _p, b in links_from(q, nid)]
    return seen


def ancestors(q, nid):
    """The node ids from which the wires lead to `nid`."""
    back = {}
    for a, _p, b in q.get("links") or []:
        back.setdefault(b, []).append(a)
    seen, todo = set(), list(back.get(nid, []))
    while todo:
        x = todo.pop()
        if x in seen:
            continue
        seen.add(x)
        todo += back.get(x, [])
    return seen




def meta_layer(qid, world):
    return f"{qid}_meta_{world}"


def inside_facts(qid):
    """(the fact the game's quest sets where a conjunction quest is put into it, the fact it waits for to go on)."""
    return f"{qid}_inside", f"{qid}_over"


def step_type(step):
    if not isinstance(step, dict) or len(step) != 1:
        raise ValueError(f"a step is one entry like '- goto: {{...}}', found: {step}")
    return next(iter(step.items()))


def has_quest(q):
    """Is there a quest to build: a step besides its start and its ends (else: only places, scene swaps ...)?"""
    if is_graph(q):
        return any(step_type(n["step"])[0] not in ("start", "end") for n in q["nodes"].values())
    return bool(q.get("steps") or q.get("paths"))


def _drop_unreached(structure):
    """Blocks nothing leads to from the start (a talk with a choice leaves its plain 'done' objective behind - the
    radish author read it in the example, 04.10.) taken out. A block counts as reached once its name stands anywhere
    in a reached block, not only in its next lists."""
    def names(v):
        if isinstance(v, str):
            if v in structure:
                yield v
        elif isinstance(v, dict):
            for k, x in v.items():
                yield from names(k)
                yield from names(x)
        elif isinstance(v, (list, tuple)):
            for x in v:
                yield from names(x)
    seen, todo = {"start"}, ["start"]
    while todo:
        for n in names(structure[todo.pop()]):
            if n not in seen:
                seen.add(n)
                todo.append(n)
    for k in [k for k in structure if k not in seen]:
        del structure[k]


def generate(project, blocks=None):
    """-> (structure blocks, journals dict or None, meta layers {world: {...}}, tags {(place, object id): tag},
    communities {name: definition}, scenes {name: definition}).
    Without a quest section: only show the places (and their NPCs) and keep running."""
    import copy
    blocks = dict(BLOCKS, **(blocks or {}))
    q = project.meta.get("quest") or {}
    copied = {}
    if not has_quest(q):
        # the Quest tab makes an empty quest as soon as it is opened: a project that only replaces game scenes or
        # cutscenes (or has nothing yet) has no quest of its own
        q = {}
    elif not is_graph(q):
        q = migrate(copy.deepcopy(q, copied), layout=False)           # the older form: built as its graph (the project stays)
    from . import quests as QS                  # a project's other quests: one graph, each its own numbers (quests.py)
    q, parts = QS.merge(project.meta, q)
    ctx = Ctx(project, q)
    qid = ctx.qid
    struct, meta, objectives, scenes = {}, {}, [], {}
    # NPCs of a place: one community per place, each NPC standing at an action point where it was placed; its look
    # fixed in the community (it stays after a respawn) - who speaks gets a look whose face can move its mouth
    communities, spawn_of = {}, {}
    speakers = speaking_people(q)
    project.notes = getattr(project, "notes", [])
    project.minigames = ctx.minigames        # written beside the definition; the build makes them gwent
    project.keyed_strings = ctx.keyed         # (as the minigames: the build adds them to the quest's strings)
    project.step_layers, project.step_entities = ctx.layers, ctx.own_entities      # (project.generate writes them)
    project.step_trails = ctx.trails_in_steps
    foes = kill_targets(q)
    # who moves (follow, patrol, walk, stands): a community of their own - a community has one phase for all its
    # people, so two who move at once would put each other back (02.10.)
    movers = {a["who"] for st in all_steps(q) for kind, a in [step_type(st)]
              if kind in ("follow", "patrol", "walk", "stands", "goaway") and isinstance(a, dict) and a.get("who")}
    movers |= {r for st in all_steps(q) for kind, a in [step_type(st)] if kind == "race" and isinstance(a, dict)
               for r in a.get("racers") or [] if r}     # (racers: one by one, off their action points)
    ctx.person_comm = {}
    ctx.communities = communities
    for name, p in project.places.items():
        ents, phase = {}, {}
        for k, o in enumerate(p.get("objects", [])):
            if not is_actor(o):
                continue
            oid = o.setdefault("id", f"npc{k}")
            if f"{name}/{oid}" in foes:
                # a kill target: a community of its own, spawned when its Kill step begins (as the game's quests do)
                ap = f"{qid}_{name}_{oid}_ap"
                c = f"{qid}_{name}_{oid}_foe"
                ent = {"template": o["template"], "tags": [f"{qid}_{name}_{oid}"]}
                if o.get("appearance"):
                    ent["appearances"] = [o["appearance"]]
                communities[c] = {"entities": {oid: ent}, "phases": {"main": {oid: f"{p['world']}/{ap}"}}}
                meta.setdefault(p["world"], {}).setdefault("actionpoints", {})[ap] = {
                    "pos": o["pos"], "rot": [0.0, 0.0, float(o["rot"][2])],
                    "action": o.get("action") or idle_action(o["template"])}
                ctx.foes[f"{name}/{oid}"] = c
                continue
            ap = f"{qid}_{name}_{oid}_ap"
            ents[oid] = {"template": o["template"], "tags": [f"{qid}_{name}_{oid}"]}
            look = o.get("appearance")
            if f"{name}/{oid}" in speakers:
                from .talking import look_for_speaker
                look, note = look_for_speaker(o["template"], look)
                if note:
                    project.notes.append(f"{name}/{oid}: {note}")
            if look:
                ents[oid]["appearances"] = [look]
            phase[oid] = f"{p['world']}/{ap}"
            meta.setdefault(p["world"], {}).setdefault("actionpoints", {})[ap] = {
                "pos": o["pos"], "rot": [0.0, 0.0, float(o["rot"][2])],
                "action": o.get("action") or idle_action(o["template"])}      # what they do there
        for oid in [o for o in ents if f"{name}/{o}" in movers]:
            c = f"{qid}_{name}_{oid}_c"
            communities[c] = {"entities": {oid: ents.pop(oid)}, "phases": {"main": {oid: phase.pop(oid)}}}
            spawn_of.setdefault(name, []).append(c)
            ctx.person_comm[f"{name}/{oid}"] = c
        if ents:
            communities[f"{qid}_{name}"] = {"entities": ents, "phases": {"main": phase}}
            spawn_of.setdefault(name, []).insert(0, f"{qid}_{name}")
    # schedules: each 'stands' makes a new phase of its place's community - the one before it with this person at
    # the new spot (in story order); the step switches to it
    latest, ctx.stand_phases, ctx.walk_phases = {}, {}, {}
    doing = {}                              # who -> the action at their spot now (a tied job has no way out)

    def action_of(who):
        if who not in doing:
            place, _, oid = who.partition("/")
            o = next((o for o in project.places.get(place, {}).get("objects", []) if o.get("id") == oid), {})
            doing[who] = o.get("action") or ""
        return doing[who]

    def new_phase(comm, place, oid, world, ap, pos, yaw, action, name_):
        o = next(o for o in project.places[place]["objects"] if o.get("id") == oid)
        meta.setdefault(world, {}).setdefault("actionpoints", {})[ap] = {
            "pos": [round(float(v), 3) for v in pos[:3]], "rot": [0.0, 0.0, round(float(yaw), 2)],
            "action": action or idle_action(o["template"])}
        communities[comm]["phases"][name_] = dict(communities[comm]["phases"][latest.get(comm, "main")],
                                                  **{oid: f"{world}/{ap}"})
        latest[comm] = name_

    for k, st in enumerate(all_steps(q), 1):
        kind, a = step_type(st)
        if kind in ("follow", "patrol", "walk") and (a or {}).get("who") and not a.get("lead"):
            # a person of a place walks by phases: one per point, an action point each (facing the next point)
            place, _, oid = a["who"].partition("/")
            comm = ctx.person_comm.get(a["who"])
            pts = [p for p in (a.get("path") or []) if p and len(p) >= 3] if kind != "walk" else \
                ([a["pos"]] if a.get("pos") else [])
            if not comm or oid not in communities[comm]["entities"] or not pts:
                continue                            # (not a person of a place: the old way)
            world = project.places[place]["world"]
            names, yaw = [], float(a.get("yaw", 0.0))
            for j, pt in enumerate(pts, 1):
                if j < len(pts):
                    nx, ny = float(pts[j][0]) - float(pt[0]), float(pts[j][1]) - float(pt[1])
                    yaw = math.degrees(math.atan2(-nx, ny)) % 360
                name_ = f"s{k}_p{j}"
                new_phase(comm, place, oid, world, f"{qid}_{place}_{oid}_ap{k}_{j}", pt, yaw, a.get("action"), name_)
                names.append((name_, [float(v) for v in pt[:3]]))
            # from a work without a way out (tied up, lying, asleep) he cannot walk off: taken away and brought back
            stuck = bool(re.search(r"tied|lying|_lie_|sleep|bound|chained|kneel_tied", action_of(a["who"])))
            doing[a["who"]] = a.get("action") or ""
            ctx.walk_phases[id(a)] = (comm, names, stuck)
            continue
        if kind != "stands" or not (a or {}).get("who") or not a.get("pos"):
            continue
        place, _, oid = a["who"].partition("/")
        comm = ctx.person_comm.get(a["who"])
        if not comm or oid not in communities[comm]["entities"]:
            raise ValueError(f"Stands: {a['who']} is not an NPC of a location")
        doing[a["who"]] = a.get("action") or ""
        world = project.places[place]["world"]
        ap = f"{qid}_{place}_{oid}_ap{k}"
        o = next(o for o in project.places[place]["objects"] if o.get("id") == oid)
        meta.setdefault(world, {}).setdefault("actionpoints", {})[ap] = {
            "pos": a["pos"], "rot": [0.0, 0.0, float(a.get("yaw", 0.0))],
            "action": a.get("action") or idle_action(o["template"])}
        phase = dict(communities[comm]["phases"][latest.get(comm, "main")], **{oid: f"{world}/{ap}"})
        name_ = f"s{k}"
        communities[comm]["phases"][name_] = phase
        latest[comm] = name_
        ctx.stand_phases[id(a)] = (comm, name_)
    start_worlds = {}
    for name, p in project.places.items():
        if has_statics(p) and p.get("visible", "start") == "start":
            start_worlds.setdefault(p["world"], []).append(name)
    paths = q.get("paths") or {}
    count = [0]                             # steps are numbered in the order they are made (main story, then paths)
    used = {"fail": False}
    graph_node = [None, set(), ""]          # the node being built, its outputs, its kind (a graph: wires say where)
    numbers = {}

    def node_number(nid):
        """A node's step number: n12 -> 12; other names (done, failed, way_x ...) from 500 on."""
        if nid[1:].isdigit() and nid[0] == "n":
            return int(nid[1:])
        return numbers.setdefault(nid, 500 + len(numbers))
    if is_graph(q):
        count[0] = 900                      # steps built outside the graph (a test build's world): from 901
    path_first, lane_first, lane_blocks = {}, {}, {}
    repeats = {}                            # node -> (its step's StepOut, number, kind, args): goals 'every time'

    def pieces(step, objective=True):
        """The blocks of one step -> [(first, last, branches, retry, objective)] (an objective wraps its goal)."""
        if graph_node[0] is not None:           # a node: its number stays when the wires change (saves keep)
            i = node_number(graph_node[0])
        else:
            count[0] += 1
            i = count[0]
        kind, args = step_type(step)
        if kind in PLACEHOLDERS:
            raise ValueError(f"step {i}: a block that does not know yet what it does - choose {PLACEHOLDERS[kind]}")
        if kind not in blocks:
            raise ValueError(f"step {i}: unknown step type '{kind}' (known: {', '.join(sorted(blocks))})")
        place = (args or {}).get("place")
        if kind in ("show", "hide") and not has_statics(project.places.get(place, {})):
            out = StepOut({}, None, None)               # only NPCs there: nothing to show, they spawn (below)
        else:
            try:
                out = blocks[kind].generate(ctx, i, args or {})
            except KeyError as ex:
                # an unfinished step (a card still missing something): said plainly, not as conjunction's own error
                raise ValueError(f"step {i} ({kind}): '{ex.args[0]}' is not set yet (or no longer there)"
                                 f"{_which(kind, args, q, ctx)}") from None
            except ValueError as ex:
                raise ValueError(f"{ex}{_which(kind, args, q, ctx)}") from None
        struct.update(out.blocks)
        scenes.update(out.scenes)
        if graph_node[0] is not None and repeat_of(args) is not None:
            repeats[graph_node[0]] = (out, i, kind, args)        # (its loop: made when every node is built)
        for w, m in out.meta.items():
            for k, v in m.items():
                meta.setdefault(w, {}).setdefault(k, {}).update(v)
        made = []
        made_text = default_text(kind, args or {}, q.get("items"), ctx.names)
        if out.objective and not (args or {}).get("text") and made_text:
            out.objective["caption"] = made_text
        if out.objective and objective and out.counter:
            # 0/n, 1/n, ...: one objective per count, each done when the count goes up
            # the step's fork starts the first objective instead of its own final wait; objective k waits for the
            # count k + 1, is done and starts the next; the last one waits with the step's own wait (count n)
            fact, n = out.counter
            caption = out.objective["caption"]
            ons, dones = [], []
            for k in range(n):
                oid = f"s{i}_{k}"
                objectives.append({oid: {kk: v for kk, v in dict(out.objective, caption=f"{caption} ({k}/{n})").items()
                                         if v}})
                ons.append(f"objective.{oid}_on")
                dones.append(f"objective.{oid}_done")
                struct[ons[k]] = {"objective": f"{qid}/main/{oid}", "track": True}
                struct[dones[k]] = {"objective": f"{qid}/main/{oid}"}
            for k in range(n - 1):
                wait = f"waituntil.s{i}_count{k + 1}"
                struct[ons[k]]["next"] = [wait]
                struct[wait] = {"factdb": [fact, ">=", k + 1], "next": [{dones[k]: "Success"}]}
                struct[dones[k]]["next"] = [ons[k + 1]]
            struct[ons[-1]]["next"] = [out.last]
            fork = getattr(out, "fork", out.first)
            struct[fork]["next"] = [x for x in struct[fork]["next"] if x != out.last] + [ons[0]]
            made += [(out.first, out.last, out.branches, out.first, f"s{i}_{n - 1}"),
                     ({dones[-1]: "Success"}, dones[-1], None, None, None)]
            return made
        if out.objective and objective:
            oid = f"s{i}"
            objectives.append({oid: {k: v for k, v in out.objective.items() if v}})
            on, done = f"objective.{oid}_on", f"objective.{oid}_done"
            struct[on] = {"objective": f"{qid}/main/{oid}", "track": True}
            struct[done] = {"objective": f"{qid}/main/{oid}"}
            made += [(on, on, None, None, None), (out.first, out.last, out.branches, on, oid),
                     ({done: "Success"}, done, None, None, None)]
        elif out.first:
            made.append((out.first, out.last, out.branches, out.first, None))
        # a place that comes or goes brings or takes its NPCs
        if kind in ("show", "hide") and place in spawn_of:
            b = f"{'spawn' if kind == 'show' else 'despawn'}.s{i}_npcs"
            struct[b] = {"spawnsets": list(spawn_of[place])}
            if kind == "show":
                struct[b]["phase"] = "main"
            made.append((b, b, None, b, None))
        return made

    def resolve(then, join, retry, objective):
        """Where a way out of a step leads: on (join), again (retry), a path, the quest's end."""
        if then == "continue":
            return join
        if then == "retry":
            return retry
        if then == "fail":
            used["fail"] = True
            return {"questoutcome.failed": "Failure"}
        if then == "success":
            return {"questoutcome.done": "Success"}
        if then.startswith("@"):                # an output of a node: where its wires lead (settled at the end)
            _e, src, port = then.split("@")
            ends = [step_type(q["nodes"][b]["step"]) for a, p_, b in q.get("links") or []
                    if a == src and p_ == port and b in q["nodes"]]
            if ends and all(k == "end" and (x or {}).get("how") == "fail" for k, x in ends):
                return then                     # the quest fails there: its objective is not done
            if objective:
                d = f"objective.{objective}_done_{then[1:].replace('@', '_')}"
                struct[d] = {"objective": f"{qid}/main/{objective}", "next": [then]}
                return {d: "Success"}
            return then
        if then.startswith("path:"):
            pid = then[5:]
            if pid not in paths:
                raise ValueError(f"A step leads to the branch '{pid}', which does not exist")
            if pid in lane_first:
                raise ValueError(f"The branch '{pid}' is a parallel track (Meanwhile). A choice needs a branch of "
                                 f"its own")
            if pid not in path_first:
                p = paths[pid]
                end = p.get("then", "join")
                after = resolve("continue" if end == "join" else end, join, retry, None)
                b = f"addfact.path_{safe(pid)}"        # remembered: later talks can depend on it
                path_first[pid] = b
                struct[b] = {"value": [path_fact(qid, pid), 1]}
                struct[b]["next"] = [build(p.get("steps") or [], after)]
            target = path_first[pid]
            if objective:                           # the step's objective is done on this way too
                d = f"objective.{objective}_done_{pid}"
                struct[d] = {"objective": f"{qid}/main/{objective}", "next": [target]}
                return {d: "Success"}
            return target
        raise ValueError(f"unknown way on: {then}")

    def build(steps, after, hidden_first=False):
        """The blocks of a list of steps, linked in order; the last leads to `after`. Returns the first.
        hidden_first: the first step has no objective and the quest enters the journal after it."""
        if hidden_first and steps:
            # the first real step (chapter headings before it build nothing)
            k = next((j for j, st in enumerate(steps) if step_type(st)[0] != "chapter"), 0)
            first_made = [p for st in steps[:k + 1] for p in pieces(st, objective=False)]
            made = first_made + [("journal.begin", "journal.begin", None, None, None)] + \
                [p for step in steps[k + 1:] for p in pieces(step)]
        else:
            made = [p for step in steps for p in pieces(step)]
        ref, beyond = after, after              # beyond: what follows the objective's "done" (where a path joins)
        for first, last, branches, retry, objective in reversed(made):
            if branches and "__lane" in branches and graph_node[0] is not None:
                # a graph's Meanwhile: on, and at once what its lane output is wired to
                struct[last]["next"] = [ref, f"@{graph_node[0]}@__lane"]
                ref, beyond = first, ref
                continue
            if branches and "__lane" in branches:
                # a lane beside the story: this block goes on to the story and starts the lane at once
                pid = branches["__lane"]
                if pid not in paths:
                    raise ValueError(f"Meanwhile: there is no branch '{pid}'")
                if pid in path_first or lane_first.get(pid) == "":
                    raise ValueError(f"Meanwhile: the branch '{pid}' belongs to a choice or starts on its own. A "
                                     f"parallel track needs a branch of its own")
                if pid not in lane_first:
                    lane_first[pid] = ""                    # being built
                    before = set(struct)
                    lane_first[pid] = build(paths[pid].get("steps") or [], "waituntil.forever")
                    lane_blocks[pid] = sorted(set(struct) - before)     # what 'Stop lane' cuts
                struct[last]["next"] = [ref, lane_first[pid]]
                ref, beyond = first, ref
                continue
            if branches and graph_node[0] is not None and graph_node[2] != "end":
                # a node's outputs: its "next" goes on as a step always did (its objective done first), the others
                # lead where their wires do
                for sock, then in branches.items():
                    port = sock if sock in graph_node[1] else "next"
                    if port == "next":
                        target = ref
                    elif port in ("retry", "fail") and not any(
                            a_ == graph_node[0] and p_ == port for a_, p_, _b in q.get("links") or []):
                        # not wired: 'later' talks again, 'fails' fails the quest - what the words say (night 01.10.)
                        target = resolve(port, ref, retry, None)
                    else:
                        target = resolve(f"@{graph_node[0]}@{port}", ref, retry, objective)
                    struct[last][f"next.{sock}" if sock else "next"] = [target]
            elif branches:
                for sock, then in branches.items():
                    if then.startswith("path:"):
                        # the path marks the objective done itself and joins after it
                        target = resolve(then, beyond if objective else ref, retry, objective)
                    else:
                        target = resolve(then, ref, retry, None)
                    struct[last][f"next.{sock}" if sock else "next"] = [target]
            else:
                struct[last]["next"] = [ref]
            ref, beyond = first, ref
        return ref

    def first_wins_ways(nodes, out_of, first_of, blocks_of):
        """An either whose ways are wired to goals: its block starts them all side by side; when one is done, on its
        way out a cut (the game's cut control block, as mq1035's 'whichever comes first') stops the others and their
        journal lines are taken away (Deactivate), then on where the winner leads."""
        for e, node in nodes.items():
            kind, a = step_type(node["step"])
            if kind != "either" or not first_wins(a) or e not in first_of:
                continue
            ways = len(a.get("ways") or [])
            groups = [[t for t in out_of.get((e, f"way{k}"), []) if t in nodes] for k in range(1, ways + 1)]
            fork = f"addfact.s{node_number(e)}_either"
            struct[fork]["next"] = [f"@{e}@way{k}" for k, g in enumerate(groups, 1) if g] or ["waituntil.forever"]
            for k, group in enumerate(groups, 1):
                losers = sorted(set().union(*[blocks_of[t] for j, g in enumerate(groups, 1) if j != k for t in g]))
                if not losers:
                    continue
                cut_these = [b for b in losers if not b.startswith(("objective.", "journal."))]
                lines_ = sorted({struct[b]["objective"] for b in losers
                                 if b.startswith("objective.") and b.endswith("_on")})
                exits = 0
                for t in group:
                    for b in sorted(blocks_of[t]):
                        for key, targets in list(struct[b].items()):
                            if not (key.startswith("next") and isinstance(targets, list)):
                                continue
                            for n_, tgt in enumerate(targets):
                                if not (isinstance(tgt, str) and tgt.startswith(f"@{t}@")):
                                    continue
                                exits += 1
                                name = f"cut_e{node_number(e)}_{k}_{exits}"
                                lane = f"__either_{name}"
                                lane_blocks[lane] = cut_these
                                ctx.minigames[name] = {"game": "cut", "lane": lane}
                                then = tgt
                                for m, ref in reversed(list(enumerate(lines_))):
                                    off = f"objective.{name}_off{m}"
                                    struct[off] = {"objective": ref, "next": [then]}
                                    then = {off: "Deactivate"}
                                struct[f"addfact.{name}"] = {"value": [f"{qid}_{name}", 1], "next": [then]}
                                targets[n_] = f"addfact.{name}"

    def repeat_loops(nodes, out_of, first_of, blocks_of):
        """Each goal 'every time': its blocks once more (a copy, without the journal), entered after what makes it
        ready again (again()); its output every time - and the copy, each time it is done - leads to what is wired
        to it, whose end comes back to that; 'until' cuts the loop."""
        for nid, (out, i, kind, a) in repeats.items():
            entry, ready = again(ctx, i, kind, a, out)
            own = _chain({k: struct[k] for k in out.blocks}, entry)
            swap = getattr(out, "again_scene", None)   # a talk: the times after the first, a scene of their own
            if swap:
                cut_at = next(k for k in own if struct[k].get("scene") == swap[0])
                own = own[:own.index(cut_at) + 1]
            names = {k: f"{k}_again" for k in own}
            for k in own:
                b = copy.deepcopy(struct[k])
                for key in [x for x in b if x.startswith("next")]:
                    b[key] = _renamed(b[key], names)
                if swap and k == own[-1]:
                    b["scene"] = swap[1]
                    for key in [x for x in b if x.startswith("next")]:
                        del b[key]
                struct[names[k]] = b
            every = f"@{nid}@__every"
            last, copy_last = out.last, names.get(out.last)
            if swap:
                copy_last = names[own[-1]]
            keys = [x for x in struct[last] if x.startswith("next")] or ["next"]
            for key in keys:
                struct[last].setdefault(key, []).append(every)
                if copy_last and not swap:
                    struct[copy_last][key] = [every]
            if swap:
                struct[copy_last]["next"] = [every]
            back = f"__again_{nid}"                     # (a stand-in node: where the loop's end leads)
            first = names.get(entry, entry)
            for name, b in reversed(ready):
                struct[name] = dict(b, next=[first])
                first = name
            first_of[back] = first
            # the end of what 'every time' leads to: back (only what the story itself does not reach)
            lane = reach(q, out_of.get((nid, "__every"), []))
            main = reach(q, [b for (x, p), bs in out_of.items() if x == nid and p != "__every" for b in bs])
            lane -= main
            if not out_of.get((nid, "__every")):
                out_of[(nid, "__every")] = [back]
            for x in lane:
                for p, _l in ports(nodes[x]["step"], q):
                    if not out_of.get((x, p)):
                        out_of[(x, p)] = [back]
            until = repeat_of(a)
            how = until.get("until") or "quest"
            if how == "quest":
                continue
            cut = f"cut_r{i}"
            loop = f"__every_{nid}"
            lane_blocks[loop] = sorted(set(names.values()) | {n for n, _b in ready} |
                                       set().union(*[blocks_of.get(x, set()) for x in lane]))
            ctx.minigames[cut] = {"game": "cut", "lane": loop}
            stand_in = f"addfact.{cut}"
            if how == "fact":
                if not until.get("fact"):
                    raise ValueError(f"step {i}: every time, until a fact - which fact?")
                w = f"waituntil.s{i}_until"
                struct[w] = {"factdb": [str(until["fact"]), ">=", int(until.get("value", 1))], "next": [stand_in]}
                struct[stand_in] = {"value": [f"{qid}_{cut}", 1]}
                for key in keys:
                    struct[last][key].append(w)
            elif how == "node":
                target = until.get("node")
                if target not in first_of:
                    raise ValueError(f"step {i}: every time, until a step is reached - which step?")
                struct[stand_in] = {"value": [f"{qid}_{cut}", 1], "next": [first_of[target]]}
                first_of[target] = stand_in             # (every way into that step cuts the loop first)
            else:
                raise ValueError(f"step {i}: every time, until '{how}'?")

    def build_graph(q, hidden, test_from, copied):
        """Every node on its own (the blocks of its step; a path's first also remembers the way was taken), then
        its outputs wired: to the first block of each node its links lead to - several: side by side; none: the quest
        waits there. Returns the quest's first block."""
        nodes = q["nodes"]
        out_of = {}
        for a, port, b in q.get("links") or []:
            out_of.setdefault((a, port), []).append(b)
        first_of, blocks_of = {}, {}
        starts = [b for b in out_of.get((START, "next"), []) if b in nodes]
        for nid in order(q):
            node = nodes[nid]
            kind, _a = step_type(node["step"])
            if kind == "start":
                continue
            before = set(struct)
            after = f"@{nid}@next"
            if kind == "remember":
                first = after
            else:
                graph_node[0], graph_node[1], graph_node[2] = nid, {p for p, _l in ports(node["step"], q)}, kind
                try:
                    first = build([node["step"]], after, hidden_first=hidden and nid == (starts or [None])[0])
                finally:
                    graph_node[0] = None
            if node.get("remember"):                    # the way into this node is remembered (If, Only after)
                b = f"addfact.path_{safe(node['remember'])}"
                struct[b] = {"value": [path_fact(qid, node["remember"]), 1], "next": [first]}
                first = b
            first_of[nid] = first
            blocks_of[nid] = set(struct) - before
        first_wins_ways(nodes, out_of, first_of, blocks_of)
        repeat_loops(nodes, out_of, first_of, blocks_of)

        def settle(targets, seen=()):
            """Placeholders -> the first blocks of the nodes wired there (a node without blocks of its own - a
            chapter heading - is its own output's placeholder: through it); none: the quest waits."""
            out = []
            for t in targets:
                if isinstance(t, str) and t.startswith("@"):
                    if t in seen:
                        continue                        # (a ring of nodes without blocks)
                    _e, nid, port = t.split("@")
                    got = settle([first_of[b] for b in out_of.get((nid, port), []) if b in first_of], seen + (t,))
                    out += got or ["waituntil.forever"]
                else:
                    out.append(t)
            return out
        for b in list(struct.values()):
            if isinstance(b, dict):
                for key in list(b):
                    if key.startswith("next") and isinstance(b[key], list):
                        b[key] = settle(b[key])
        # the lanes of Meanwhiles: the blocks only their lane reaches ('Stop lane' cuts them); a test build: only
        # those it gets to from where it starts
        start_at = (test_from[1] if test_from[0] == "node" else old_test_node(test_from, copied, q)) \
            if test_from else None
        runs = reach(q, [start_at]) if start_at else None
        for nid, node in nodes.items():
            kind, a = step_type(node["step"])
            if kind == "meanwhile" and (a or {}).get("path") and (runs is None or nid in runs):
                lane = reach(q, out_of.get((nid, "__lane"), []))
                main = reach(q, out_of.get((nid, "next"), []))
                lane_blocks[a["path"]] = sorted(set().union(*[blocks_of.get(x, set()) for x in lane - main]))
        first = settle([f"@{START}@next"])
        if test_from:
            # a test build: the quest starts at this node; before it only what changes the world happens
            nid = test_from[1] if test_from[0] == "node" else old_test_node(test_from, copied, q)
            if nid in first_of:
                before = [nodes[x]["step"] for x in order(q) if x in ancestors(q, nid)]
                world = [st for st in before if step_type(st)[0] in WORLD_ACTIONS] + \
                    [g for st in before for g in carried(st)]
                start = build(world, first_of[nid])
                # people a Follow before it led away stand where it ended (its last phase - 03.10.: after the
                # follow the blacksmith stood at his first spot, 21 m off, and his line was not heard)
                for k, st in enumerate(before):
                    kind, a = step_type(st)
                    phases = getattr(ctx, "walk_phases", {}).get(id(a)) if kind == "follow" else None
                    if phases and not (a or {}).get("lead"):
                        # his phase there, and put there at once (a phase alone let him walk from his first spot:
                        # the gwent after it was lost while he was 30 m away - 03.10.)
                        path = [p_ for p_ in a.get("path") or [] if p_ and len(p_) >= 3]
                        b, put = f"spawn.test_moved_{k}", f"script.test_put_{k}"
                        if path:
                            end = path[-1]
                            yaw = _heading(path[-2] if len(path) > 1 else ctx.object(a["who"])["pos"], end)
                            struct[put] = {"function": "CjPutAt", "parameter": [
                                {"tag": f"cname_{ctx.object_tag(a['who'])}"}, {"x": float(end[0])},
                                {"y": float(end[1])}, {"z": float(end[2])}, {"yaw": float(yaw)}], "next": [start]}
                            start = put
                        struct[b] = {"spawnsets": [phases[0]], "phase": phases[1][-1][0], "next": [start]}
                        start = b
                return start
        if len(first) == 1:
            return first[0]
        struct["addfact.started"] = {"value": [f"{qid}_started", 1], "next": first}     # side by side from the start
        return "addfact.started"

    def old_test_node(test_from, copied, q):
        """The node of the step a test build of the older form starts at ("main", index / path, id, index)."""
        orig = project.meta.get("quest") or {}
        where, k = test_from[0], int(test_from[-1])
        steps = orig.get("steps") if where == "main" else ((orig.get("paths") or {}).get(test_from[1]) or {}).get("steps")
        if not steps or k >= len(steps):
            return None
        step = copied.get(id(steps[k])) if copied else steps[k]
        return next((nid for nid, n in q["nodes"].items() if n["step"] is step), None)

    struct["waituntil.forever"] = {"factdb": [f"{qid}_never", "=", 1], "next": ["end"]}
    if q:
        struct["questoutcome.done"] = {"quest": qid, "next": ["addfact.done"]}
        struct["addfact.done"] = {"value": [f"{qid}_done", 1], "next": ["waituntil.forever"]}     # other quests: after
    story = []                              # (a quest is built as its graph: build_graph - a test build there too)
    test_from = getattr(project, "test_from", None)
    from . import features
    if not features.experimental():
        # the first release: every quest is in the journal from the game's start (Maxim 07.10.) - what a project
        # set about when and after what it starts waits for the update that brings it back
        q = dict(q)
        for k in ("start", "after", "after_game", "inside_game", "ends_game"):
            q.pop(k, None)
    hidden = q.get("start") == "after_first" and bool(q) and not test_from
    if hidden:
        struct["journal.begin"] = {"entry": f"quests/{qid}/start", "activate_root": True}
    if q:
        first_story = build_graph(q, hidden, test_from, copied)
    else:
        first_story = build(story, "waituntil.forever")
    # people who must survive: their death fails the quest (a watcher from the start)
    watchers = []
    for k, ref in enumerate(q.get("keep_alive") or [], 1):
        w = f"waituntil.alive_{k}"
        struct[w] = {"factdb": [f"actor_{ctx.object_tag(ref)}_was_killed", ">=", 1],
                     "next": [{"questoutcome.failed": "Failure"}]}
        watchers.append(w)
        used["fail"] = True
    # ends when one of the game's quests reaches a moment (hooked in: the game's quest unchanged)
    eg = q.get("ends_game") or {}
    if eg.get("fact"):
        fail = eg.get("how", "fail") == "fail"
        struct["waituntil.ends_game"] = {"factdb": [str(eg["fact"]), ">=", 1],
                                         "next": [{"questoutcome.failed": "Failure"} if fail
                                                  else {"questoutcome.done": "Success"}]}
        watchers.append("waituntil.ends_game")
        used["fail"] = used["fail"] or fail
    if used["fail"]:
        # a way that fails the quest: the journal says so, the places stay
        struct["questoutcome.failed"] = {"quest": qid, "next": ["addfact.failed"]}
        struct["addfact.failed"] = {"value": [f"{qid}_failed", 1], "next": ["waituntil.forever"]}
    if q:
        # the quest ends once: every way to an outcome passes a guard that looks at the other one's fact
        guards = {"questoutcome.done": ("waituntil.end_done", f"{qid}_failed", "Success"),
                  "questoutcome.failed": ("waituntil.end_failed", f"{qid}_done", "Failure")}
        QS.retarget_objectives(struct, parts, qid)      # (a project's quest k: its own journal entry, its own end)
        guards.update(QS.split_outcomes(struct, parts, qid))
        for b in list(struct.values()):
            if not isinstance(b, dict):
                continue
            for key, targets in b.items():
                if key.startswith("next") and isinstance(targets, list):
                    b[key] = [guards[next(iter(t))][0] if isinstance(t, dict) and len(t) == 1 and
                              next(iter(t)) in guards and next(iter(t)) in struct else t for t in targets]
        for outcome, (g, other, sock) in guards.items():
            if outcome in struct:
                struct[g] = {"conditions": {"on": {"factdb": [other, "=", 0]}, "over": {"factdb": [other, ">=", 1]}},
                             "next.on": [{outcome: sock}], "next.over": ["waituntil.forever"]}
    # after a game of gwent / a fist fight the picture stays black until the quest fades in - the game's own quests
    # call FadeInQuest(1.0) on both outputs (cg700_gwent_players); without it: a loading screen for ever (03.10.)
    for name, m in ctx.minigames.items():
        b = f"randomize.{name}"
        if m.get("game", "gwent") in ("gwent", "fistfight") and b in struct:
            for sock in ("Success", "Failure"):
                fade = f"script.{name}_fadein_{sock.lower()}"
                struct[fade] = {"function": "FadeInQuest", "parameter": [{"fadeTime": 1.0}],
                                "next": struct[b].get(f"next.{sock}") or ["waituntil.forever"]}
                struct[b][f"next.{sock}"] = [fade]
    # 'Stop lane': the blocks of that lane (the build makes the stand-in the game's cut control block)
    for name, m in list(ctx.minigames.items()):
        if m.get("game") == "cut":
            if m["lane"] not in lane_blocks:
                if test_from:                   # a test build: the Meanwhile was before where it starts - nothing runs
                    del ctx.minigames[name]     # (the stand-in stays a plain fact)
                    continue
                raise ValueError(f"Stop lane: '{m['lane']}' never runs (no Meanwhile starts it)")
            m["blocks"] = lane_blocks[m["lane"]]
    for w, m in ctx.extra_meta.items():
        for k, v in m.items():
            meta.setdefault(w, {}).setdefault(k, {}).update(v)
    # meta entities (areas, map pins) live in one layer per world, shown from the start like the places
    for w in meta:
        start_worlds.setdefault(w, []).append(meta_layer(qid, w))
    # layers of a quest DLC are visible from the start (seen in the game 28.09.): places a step shows are hidden first
    later = {}
    for name, p in project.places.items():
        if has_statics(p) and p.get("visible", "start") != "start":
            later.setdefault(p["world"], []).append(name)
    for name, lay in ctx.layers.items():                # a clue entry's own layer: shown when its turn comes
        later.setdefault(lay["world"], []).append(name)
    head = []
    for w in list(start_worlds) + [w for w in later if w not in start_worlds]:
        b = f"changelayers.show_{w}"
        struct[b] = {"world": w}
        if start_worlds.get(w):
            struct[b]["show"] = start_worlds[w]
        if later.get(w):
            struct[b]["hide"] = later[w]
        head.append(b)
    for name in spawn_of:
        if project.places[name].get("visible", "start") == "start":
            b = f"spawn.{name}_npcs"
            struct[b] = {"phase": "main", "spawnsets": list(spawn_of[name])}
            head.append(b)
    if q and not hidden:
        j = "journal.begin"
        struct[j] = {"entry": f"quests/{qid}/start", "activate_root": True}
        head.append(j)
    for a_, b_ in zip(head, head[1:] + [first_story]):
        struct[a_]["next"] = [b_]
    story_start = head[0] if head else first_story
    if (q.get("after_game") or {}).get("fact"):
        # hooked into one of the game's quests: starts when its graph has set this fact (the game's quest unchanged)
        struct["waituntil.after_game"] = {"factdb": [str(q["after_game"]["fact"]), ">=", 1], "next": [story_start]}
        story_start = "waituntil.after_game"
    gq = q.get("game_quest") or {}
    if gq.get("file") and gq.get("obj") is not None:
        # with or after a quest of the game (Maxim 07.10.), read from its journal: with = once it has started (running,
        # or already over in this save), after = once it is over (done or failed). Nothing of the game's changes.
        entry = {"file": gq["file"], "obj": int(gq["obj"])}
        states = ("JS_Active", "JS_Success", "JS_Failed") if gq.get("when") == "with" else ("JS_Success", "JS_Failed")
        struct["waituntil.game_quest"] = {"any": [{"journal": entry, "status": s_} for s_ in states],
                                          "next": [story_start]}
        story_start = "waituntil.game_quest"
    if (q.get("inside_game") or {}).get("phase"):
        # put into one of the game's quests: its graph sets the start fact there and waits for the end one
        start_fact, over_fact = inside_facts(qid)
        struct["waituntil.inside_game"] = {"factdb": [start_fact, ">=", 1], "next": [story_start]}
        story_start = "waituntil.inside_game"
        struct["addfact.over"] = {"value": [over_fact, 1], "next": ["waituntil.forever"]}
        for end in ("addfact.done", "addfact.failed"):
            if end in struct:
                struct[end]["next"] = ["addfact.over"]      # done or failed: the game's quest goes on
    if q.get("after"):
        # starts when another conjunction quest was done (its fact <quest id>_done)
        struct["waituntil.after"] = {"factdb": [f"{str(q['after']).lower()}_done", ">=", 1], "next": [story_start]}
        story_start = "waituntil.after"
    # a run left behind by Build & Play's live loading (TW3SE: the newer run comes into the running game, this one's
    # DLC stays in it until the next start): Conjunction sets <qid>_retired, the run hides its places and ends
    retire = []
    # its people first: they come from communities (spawn blocks), which neither a hidden layer nor the quest's end
    # takes away (03.10.: three blacksmiths, an old run's bandit still hostile)
    sets = list(dict.fromkeys(n for k, b in struct.items() if k.startswith(("spawn.", "despawn.")) and
                              isinstance(b, dict) for n in b.get("spawnsets") or []))
    if sets:
        retire.append("despawn.retired")
        struct["despawn.retired"] = {"spawnsets": sets}
    # ... and at once: a community lets its people go only when nobody looks (07.10.: two fathers side by side)
    for pname, p in project.places.items():
        for o in p.get("objects", []):
            if o.get("id") and is_actor(o):
                retire.append(f"script.retire_{pname}_{o['id']}")
                struct[retire[-1]] = {"function": "CjRunGone",
                                      "parameter": [{"tag": f"cname_{qid}_{pname}_{o['id']}"}]}
    for w in list(start_worlds) + [w for w in later if w not in start_worlds]:
        names = list(dict.fromkeys((start_worlds.get(w) or []) + (later.get(w) or [])))
        if names:
            retire.append(f"changelayers.retire_{w}")
            struct[retire[-1]] = {"world": w, "hide": names}
    for a_, b_ in zip(retire, retire[1:] + ["end"]):
        struct[a_]["next"] = [b_]
    # the run steps aside by itself when a newer run of the same project has started (its number in
    # <base>_run - in the save, whatever the console's timing) or when Conjunction sets <qid>_retired
    # (Build & Play's time - fresh_run keeps it as `stamp` - not the run's number: a fresh copy of a project
    # counts its runs from 1 again, a save knows the higher ones; the time only grows. The same project builds
    # the same: test_deterministic)
    base, run = project.base_id, int(project.meta.get("stamp") or 0)
    struct["script.retired"] = {"function": "CjRunRetired", "parameter": [
        {"base": base}, {"run": run}, {"retired": f"{qid}_retired"}], "next": [(retire or ["end"])[0]]}
    watchers.append("script.retired")
    struct["script.run_start"] = {"function": "CjRunStart", "parameter": [{"base": base}, {"run": run}],
                                  "next": [story_start]}
    story_start = "script.run_start"
    structure = {"start": {"next": [story_start] + watchers}}
    struct["end"] = {"next": ".done"}
    # objects set up in the inspector (inventory, appearance): a branch of their own from the start - each block
    # waits until its object is there (a place may be shown later), does it once and the branch then rests
    setups = []
    # a container to search that holds nothing: the game offers no search on an empty one (05.10. in the game: no
    # prompt at bandit_camp's strongbox) - a few crowns put in
    for st in all_steps(q):
        kind, args = step_type(st)
        a = args or {}
        if kind == "loot" and a.get("object") and not step_items(a):
            try:
                o = ctx.object(a["object"])
            except ValueError:                          # (said where the step is made)
                continue
            if not is_actor(o) and not o.get("inventory") and not o.get("loot"):
                o["inventory"] = [{"item": "Crowns", "count": 25}]
    for name, p in project.places.items():
        taken = {o.get("id") for o in p.get("objects", [])}
        for k, o in enumerate(p.get("objects", [])):
            # NPCs too: what they carry drops when they die (a loot table would empty their gear: not for them)
            actor = is_actor(o)
            if not (o.get("inventory") or o.get("appearance") or o.get("loot") or ("loot" in o and not actor)):
                continue
            if not o.get("id"):
                base = os.path.splitext(os.path.basename(o["template"].replace("\\", "/")))[0].lower()
                oid, n = base, 2
                while oid in taken:
                    oid, n = f"{base}_{n}", n + 1
                o["id"] = oid
                taken.add(oid)
            tag = f"cname_{qid}_{name}_{o['id']}"
            if o.get("appearance"):
                setups.append({"function": "CjSetupLook", "parameter": [{"tag": tag},
                                                                        {"appearance": o["appearance"]}]})
            if "loot" in o and not actor:           # before the items: it empties the container
                setups.append({"function": "CjSetupLoot", "parameter": [{"tag": tag}, {"loot": o["loot"] or ""}]})
            elif actor and o.get("loot"):           # a person / creature: the table added to what they carry
                setups.append({"function": "CjSetupDrops", "parameter": [{"tag": tag}, {"loot": o["loot"]}]})
            for e in o.get("inventory", []):
                # the item as text (radish takes names only as [a-z_0-9]; CjItemName looks it up in the game) -
                # the quest's own items by name
                call = item_call(ctx, "CjSetupItem", e["item"], count=int(e.get("count", 1)))
                call["parameter"].insert(0, {"tag": tag})
                setups.append(call)
    for st in all_steps(q):
        kind, args = step_type(st)
        a = args or {}
        holder = a.get("in") if kind == "collect" and a.get("from") in ("container", "person") else \
            a.get("object") if kind == "loot" else None
        if holder:
            # where the items are: the quest puts them into that container / that person (who drops them)
            for it in step_items(a):
                call = item_call(ctx, "CjSetupItem", it["item"], count=it["count"])
                call["parameter"].insert(0, {"tag": f"cname_{ctx.object_tag(holder)}"})
                setups.append(call)
        if kind == "clues":
            for c in (args or {}).get("clues") or []:
                if c.get("object"):
                    for ref in [r for r in [c["object"]] if is_clue_template(ctx.object(r)["template"])] + \
                            [t for t in c.get("trail") or [] if t]:
                        setups.append({"function": "CjClueOff", "parameter": [
                            {"tag": f"cname_{ctx.object_tag(ref)}"}]})
    # people with talks of their own in their template (a merchant, a blacksmith: his shop and crafting on E -
    # Maxim 02.10.): theirs switched off while the quest runs, each time they come (a watch beside the quest)
    k = 0
    for name, p in project.places.items():
        for o in p.get("objects", []):
            if is_actor(o) and o.get("id") and has_own_talk(o["template"]):
                k += 1
                struct[f"script.owntalk_{k}"] = {"function": "CjOwnTalkOff",
                                                 "parameter": [{"tag": f"cname_{qid}_{name}_{o['id']}"}]}
                structure["start"]["next"].append(f"script.owntalk_{k}")
    for k, s in enumerate(setups, 1):
        struct[f"script.setup_{k}"] = dict(s, next=[f"script.setup_{k + 1}" if k < len(setups) else "waituntil.setup_rest"])
    if setups:
        struct["waituntil.setup_rest"] = {"factdb": [f"{qid}_never", "=", 1], "next": ["end"]}
        structure["start"]["next"].append("script.setup_1")
    structure.update(struct)
    _drop_unreached(structure)
    journals = None
    if q:
        first_world = next(iter(start_worlds), None) or next(
            (p["world"] for p in project.places.values() if p.get("world")), None)

        def entry(qq, objs, k):
            """A quest's journal entry: its title, type, description, objectives (a project's quest k: its own)."""
            qtype = str(qq.get("type", "secondary")).lower()
            if qtype not in QUEST_TYPES:
                raise ValueError(f"quest type '{qtype}' - one of {', '.join(QUEST_TYPES)}")
            jq = {"title": qq.get("title", project.meta.get("name", qid)), "type": QUEST_TYPES[qtype],
                  **({"level": int(qq["level"])} if qq.get("level") else {}),
                  "description": [{"start": qq.get("description", "")}] + (ctx.descriptions if k == 1 else [])}
            worlds = {o.get("world") or first_world for ob in objs for o in ob.values()} | {first_world}
            worlds.discard(None)
            # radish: a quest in one world names it once; objectives name their world only in multi-world quests
            for ob in objs:
                for o in ob.values():
                    w = o.pop("world", None) or first_world
                    if len(worlds) > 1:
                        o["world"] = w
            if len(worlds) == 1:
                jq["world"] = first_world
            if first_world is None:
                # radish would take it for a quest of several worlds and ask every objective for its own
                raise ValueError("The quest is in no world yet. Please place something for it (an NPC, an "
                                 "object, a spot)")
            if not objs:
                # radish would say 'required "instructions" missing'
                raise ValueError(("the quest" if len(parts) < 2 else f"the quest '{qq.get('title') or k}'") +
                                 " has nothing for the journal yet. It needs a goal for the player (talk, go to, "
                                 "kill), or a Wait with its own line")
            jq["instructions"] = {"main": objs}
            return jq
        mine = QS.objectives_by_part(objectives, parts)
        journals = {"quests": {QS.journal_key(qid, k): entry(q if k == 1 else parts[k], mine.get(k) or [], k)
                               for k in sorted(parts)}}
        if ctx.characters:
            journals["characters"] = ctx.characters
    tags = {}
    for name, p in project.places.items():
        for o in p.get("objects", []):
            if o.get("id"):
                tags[(name, o["id"])] = f"{qid}_{name}_{o['id']}"
    ctx.items = {iid: {k: v for k, v in (("name", it.get("name") or iid), ("description", it.get("description", "")),
                                         ("text", it.get("text", ""))) if v}
                 for iid, it in (q.get("items") or {}).items()}
    for k, (sid, sw) in enumerate(sorted((project.meta.get("swaps") or {}).items()), 1):
        scenes[f"{qid}_swap_{sid}"] = swap_scene(ctx, k, sw)
    return structure, journals, meta, tags, communities, scenes, ctx.rewards, ctx.speech, ctx.items


def swap_scene(ctx, k, sw):
    """A game scene swapped (scene_swap.py): its radish scene, the lines' strings and speech as a talk's; `_target`:
    the game's path it is built to."""
    from . import dialogue, scene_swap
    from .speech import text_timing
    if not (sw.get("scene") and sw.get("outline")):
        raise ValueError(f"a scene swap without its game scene: {sw.get('name') or sw}")
    talks = [i.get("talk", i).get("dialogue") or [] for i in (sw.get("inputs") or {}).values()]
    own = sum(len(dialogue.custom_voiced(t)) for t in talks)
    first_own = ctx.strings(own) if own else 0
    own_ids = iter(2110000000 + ctx.idspace * 1000 + first_own + j for j in range(own))
    new_speech = []
    idstart = ctx.strings(sum(dialogue.string_count(t) for t in talks))
    scene, _n = scene_swap.scene(sw, 800 + k, ctx.idspace, idstart, new_speech, own_ids,
                                 own_item=lambda item: own_item(ctx, item))
    timing = text_timing([e for e in new_speech if not e["source"]])
    for e in new_speech:
        if e["id"] in timing:
            e["dur"] = timing[e["id"]]
    _put_durations(scene, timing)
    ctx.speech += new_speech
    scene["_target"] = sw["scene"]
    return scene
