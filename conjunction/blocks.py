"""The kinds of blocks the quest graph offers (docs/SESSION_PLAN_0510.md): one graph for every quest, the simple
blocks first, the game's own blocks beside them. A simple block here is one game block with a plain name and a
plain explanation - measured over all 177 233 blocks of the game's quests (_scratch/pattern_mine.py), these kinds
cover about 85 % of them; what is not among them is a game block, its card made from the catalog.

    kind_of(tree, n, inputs) -> Kind      the kind of block object n (inputs: the socket names leading into it)
    KINDS, GROUPS                        the sidebar: groups in order, the kinds of each
    create(editor, graph, kind) -> n     a new block of a kind in graph object `graph`

A kind: id, label (the node's title), group, what it does (one sentence, the sidebar and the card), and how it
is known: the block class, and for a wait / an if its condition class, for a script block its function, for an
AI block its action class.
"""
from dataclasses import dataclass, field


@dataclass
class Kind:
    id: str
    label: str
    group: str
    text: str
    cls: str
    cond: tuple = ()                    # a wait's / an if's condition classes (any of them)
    fn: tuple = ()                      # a script block's functions
    ai: tuple = ()                      # an AI block's action classes
    simple: bool = True
    extra: dict = field(default_factory=dict)


GROUPS = [
    ("flow", "Story flow"), ("wait", "Wait until"), ("check", "Check"), ("facts", "Facts"), ("journal", "Journal"),
    ("talk", "Talks and scenes"), ("people", "People"), ("world", "World"), ("fx", "Effects and sound"),
    ("items", "Items and rewards"), ("notes", "Notes"), ("game", "Game blocks"),
]
GROUP_COLOUR = {"flow": "#7d8fa8", "wait": "#d9a441", "check": "#e0b85a", "facts": "#5cb85c", "journal": "#4fb3bf",
                "talk": "#a779d9", "people": "#e08a4f", "world": "#6f9bd1", "fx": "#c97fb0", "items": "#c9b458",
                "notes": "#8c8c70", "game": "#6a6a74"}

ACTOR = "CQuestActorCondition"
P, W, I, S, A = "CQuestPhaseBlock", "CQuestPauseConditionBlock", "CQuestConditionBlock", "CQuestScriptBlock", \
    "CQuestScriptedActionsBlock"
KINDS = [
    # --- story flow
    Kind("phase", "Custom block", "flow", "A block with its own graph inside (the game calls it a phase): double "
         "click to open it and build with the game's blocks; its Input and Output blocks inside are its ways in and "
         "out. Kept as a template, it is a block of the sidebar.", P),
    Kind("input", "Input", "flow", "A way into the custom block it is in (its name: the input's name outside).",
         "CQuestPhaseInputBlock"),
    Kind("output", "Output", "flow", "A way out of the custom block it is in (its name: the output's name outside).",
         "CQuestPhaseOutputBlock"),
    Kind("start", "Quest start", "flow", "The quest begins here.", "CQuestStartBlock"),
    Kind("end", "Quest end", "flow", "The quest is over here.", "CQuestEndBlock"),
    Kind("all", "All of these", "flow", "Goes on once every link into it has arrived.", "CQuestAndBlock"),
    Kind("first", "Whichever first", "flow", "Goes on with the first link that arrives.", "CQuestXorBlock"),
    Kind("random", "At random", "flow", "Goes on along one of its outputs, picked at random.", "CQuestRandomBlock"),
    Kind("checkpoint", "Checkpoint", "flow", "A point the game saves and loads back to.", "CQuestCheckpointBlock"),
    Kind("stop", "Stop branches", "flow", "Stops the blocks wired to its Thunder output (into their Cut input).",
         "CQuestCutControlBlock"),
    # --- wait until
    Kind("wait_fact", "Wait for a fact", "wait", "Waits until a fact has a value (set by a talk, a script, a block).",
         W, cond=("CQuestFactsDBCondition", "CQuestFactsDBExCondition")),
    Kind("wait_area", "Wait: player in area", "wait", "Waits until someone (the player) is inside a trigger area - or "
         "outside, when 'is inside' is off.", W, cond=("CQuestInsideTriggerCondition",)),
    Kind("wait_enter", "Wait: enters area", "wait", "Waits until someone enters a trigger area.", W,
         cond=("CQuestEnterTriggerCondition",)),
    Kind("wait_time", "Wait some time", "wait", "Waits a number of real seconds.", W,
         cond=("CQuestHiResRealtimeDelayCondition", "CQuestRealtimeDelayCondition")),
    Kind("wait_gametime", "Wait for game time", "wait", "Waits until the game's clock is between two hours.", W,
         cond=("CQuestTimePeriodCondition",)),
    Kind("wait_present", "Wait: someone is there", "wait", "Waits until people with these tags are spawned.", W,
         cond=("CQuestTagsPresenceCondition",)),
    Kind("wait_near", "Wait: someone near", "wait", "Waits until a person is near (or far from) someone or a place.",
         W, cond=("CQuestActorCondition/CQCDistanceTo",)),
    Kind("wait_alive", "Wait: alive or dead", "wait", "Waits until a person is dead (or alive).", W,
         cond=("CQuestActorCondition/CQCIsAlive",)),
    Kind("wait_actor", "Wait: a person's state", "wait", "Waits for a person: an animation, an attitude, a menu "
         "open ...", W, cond=("CQuestActorCondition/CQCAnimationState", "CQuestActorCondition")),
    Kind("wait_fight", "Wait for a fight", "wait", "Waits until a fight starts or is over (its enemies dead).", W,
         cond=("CQuestFightCondition", "CQuestInCombatCondition")),
    Kind("wait_used", "Wait: used (E)", "wait", "Waits until the player uses an object (its interaction: loot, use, "
         "examine ...).", W, cond=("CQuestInteractionCondition",)),
    Kind("wait_clue", "Wait: clue examined", "wait", "Waits until the player examines a clue (witcher senses).", W,
         cond=("W3QuestCond_ReusableClueUsed", "W3QuestCond_UsedFocus")),
    Kind("wait_item", "Wait: player has item", "wait", "Waits until the player carries an item (or enough of it).", W,
         cond=("CQuestActorCondition/CQCHasItem", "W3QuestCond_IsItemQuantityMet", "CQCHasItem", "CQCItemQuantity",
               "CQuestActorCondition/CQCItemQuantity", "CQuestActorCondition/CQCHasItemGE")),
    Kind("wait_gone", "Wait: someone is gone", "wait", "Waits until a person has despawned.", W,
         cond=("W3QuestCond_ActorIsDespawned",)),
    Kind("wait_book", "Wait: book read", "wait", "Waits until the player has read a book or note.", W,
         cond=("W3QuestCond_BookHasBeenRead", "W3QuestCond_BookHasBeenReadExt")),
    Kind("wait_world", "Wait: in a world", "wait", "Waits until the player is in a world / area.", W,
         cond=("W3QuestCond_World",)),
    Kind("wait_quest", "Wait: quest state", "wait", "Waits until a quest or objective is active, done or failed.", W,
         cond=("CQuestJournalStatusCondition",)),
    Kind("wait_all", "Wait for several things", "wait", "Waits until conditions combined with and / or hold.", W,
         cond=("CQuestLogicOperationCondition",)),
    # --- check
    Kind("if_fact", "If fact", "check", "Goes on along True or False: has a fact this value?", I,
         cond=("CQuestFactsDBCondition", "CQuestFactsDBExCondition")),
    Kind("if_quest", "If quest state", "check", "True or False: is a quest or objective active, done, failed?", I,
         cond=("CQuestJournalStatusCondition",)),
    Kind("if_area", "If in area", "check", "True or False: is someone inside a trigger area?", I,
         cond=("CQuestInsideTriggerCondition",)),
    Kind("if_near", "If someone near", "check", "True or False: is a person near someone or a place?", I,
         cond=("CQuestActorCondition/CQCDistanceTo",)),
    Kind("if_actor", "If a person's state", "check", "True or False: a person alive, an animation, a menu open ...?",
         I, cond=("CQuestActorCondition/CQCIsAlive", "CQuestActorCondition")),
    Kind("if_item", "If player has item", "check", "True or False: does the player carry it?", I,
         cond=("CQuestActorCondition/CQCHasItem", "W3QuestCond_IsItemQuantityMet", "CQCHasItem",
               "CQuestActorCondition/CQCItemQuantity", "CQuestActorCondition/CQCHasItemGE")),
    Kind("if_all", "If several things", "check", "True or False: conditions combined with and / or.", I,
         cond=("CQuestLogicOperationCondition",)),
    # --- facts
    Kind("set_fact", "Set fact", "facts", "Adds a value to a fact - what talks, waits and ifs look at.",
         "CQuestFactsDBChangingBlock"),
    Kind("remove_fact", "Remove fact", "facts", "Takes a fact away again.", S, fn=("RemoveFactQuest",)),
    # --- journal
    Kind("objective", "Objective", "journal", "A quest's objective in the journal: wired into Activate it shows, "
         "into Success it is ticked off, Failure failed, Deactivate gone.", "CJournalQuestBlock"),
    Kind("journal", "Journal entry", "journal", "Shows a journal entry: a quest's description, a person, a monster.",
         "CJournalBlock"),
    Kind("mappin", "Map pin", "journal", "Switches an objective's map pin on or off.", "CJournalQuestMappinStateBlock"),
    Kind("counter", "Objective counter", "journal", "Counts an objective up (3 of 5 ...).",
         "CJournalQuestObjectiveCounterGraphBlock"),
    Kind("track", "Track quest", "journal", "Makes a quest the one the player follows.", "CJournalQuestTrackBlock"),
    Kind("pin_status", "Map pin status", "journal", "Turns a map pin of the world on or off.", S,
         fn=("SetMapPinStatus", "EnableDynamicMappin")),
    # --- talks and scenes
    Kind("scene", "Play scene", "talk", "Plays a scene (a talk, a cutscene) and goes on from its outputs.",
         "CQuestSceneBlock"),
    Kind("talk", "Talk (on E)", "talk", "A talk that starts when the player talks to someone (E).",
         "CQuestInteractionDialogBlock"),
    Kind("context_talk", "Talk option", "talk", "Adds a choice to someone's talk while it runs.",
         "CQuestContextDialogBlock"),
    # --- people
    Kind("spawn", "People appear", "people", "Spawns or removes people: a community's story phase.",
         "CQuestStoryPhaseSetterBlock"),
    Kind("ai", "Make someone act", "people", "Tells a person what to do: walk a path, go somewhere, follow, play an "
         "animation, fight ...", A),
    Kind("ai_stop", "Let someone go", "people", "Ends what an earlier 'make someone act' started.",
         "CQuestResetScriptedActionsBlock"),
    Kind("ai_poke", "Nudge an action", "people", "Sends a signal to a running action.", "CQuestPokeScriptedActionsBlock"),
    Kind("anim", "Play animation", "people", "A person plays an animation.", "CQuestPlayAnimationBlock"),
    Kind("attitude", "Friend or foe", "people", "Makes a group friendly, neutral or hostile to another.", S,
         fn=("SetGroupAttitudeQuest", "AssignNPCGroupAttitudeQuest")),
    Kind("immortal", "Immortal", "people", "Makes someone immortal or unkillable - or not any more.", S,
         fn=("SetImmortalQuest",)),
    Kind("health", "Set health", "people", "Sets someone's health.", S, fn=("SetHealthQuest",)),
    Kind("look", "Change look", "people", "Gives someone another appearance.", S, fn=("AppearanceChange",)),
    Kind("weapon", "Draw weapon", "people", "Someone draws or sheathes a weapon.", S, fn=("DrawWeaponQuest",)),
    Kind("npc_state", "Person's state", "people", "Changes a person's state (calm, alert ...).", S,
         fn=("ChangeNPCStateQuest",)),
    Kind("no_talk", "No talking", "people", "Someone can not be talked to - or can again.", S,
         fn=("DisableNPCInteractivness",)),
    # --- world
    Kind("layers", "Show / hide place", "world", "Shows or hides layers of the world: a place's objects.",
         "CQuestLayersHiderBlock"),
    Kind("teleport", "Teleport", "world", "Moves the player or people to a place (a tag).", "CQuestTeleportBlock"),
    Kind("time", "Time of day", "world", "Sets, stops or speeds up the game's clock.", "CQuestTimeManagementBlock"),
    Kind("weather", "Weather", "world", "Changes the weather.", S, fn=("ChangeWeatherQuest",)),
    Kind("door", "Door", "world", "Opens, closes, locks or unlocks a door.", S, fn=("DoorChangeState",)),
    Kind("lights", "Lights", "world", "Switches lights with a tag on or off.", S, fn=("SetLights",)),
    Kind("containers", "Containers", "world", "Makes containers searchable or not.", S,
         fn=("EnableOrDisableContainers",)),
    Kind("encounters", "Creatures nearby", "world", "Turns the world's encounters (monsters, bandits) on or off.",
         "CQuestEncounterManagerBlock"),
    Kind("world", "Change world", "world", "Travels to another world (Skellige, Toussaint ...).", "CQuestChangeWorldBlock"),
    Kind("fast_travel", "Fast travel", "world", "Allows or forbids fast travel, shows signposts.",
         "CQuestManageFastTravelBlock"),
    Kind("travel_points", "Travel point", "world", "Moves the player to a point through a loading screen.", S,
         fn=("ManageTeleport",)),
    Kind("component", "Switch part of an object", "world", "Turns a part of an object on or off (a light, an "
         "interaction, a trigger).", S, fn=("EntityComponentQuest",)),
    # --- effects and sound
    Kind("effect", "Effect", "fx", "Plays or stops an effect on an object or person (fire, smoke, glow ...).", S,
         fn=("PlayEffectQuest",)),
    Kind("sound", "Sound", "fx", "Plays a sound event, in the world or on a person.", S,
         fn=("SoundEventQuest", "SoundEventOnActorQuest")),
    Kind("fade", "Fade", "fx", "Fades the screen out to black or back in.", S, fn=("FadeOutQuest", "FadeInQuest")),
    Kind("clue", "Witcher senses clue", "fx", "Makes objects clues for the witcher senses (highlighted, examined).", S,
         fn=("FocusClueManager", "FocusSetHighlight", "FocusEffect", "FocusSoundClueManager")),
    Kind("block_gameplay", "Block controls", "fx", "Blocks things the player can do (run, fight, meditate ...).", S,
         fn=("BlockGameplayFunctionality",)),
    Kind("tutorial", "Tutorial", "fx", "Shows or hides a tutorial hint.", S, fn=("TutorialMessage", "TutorialHintHide")),
    Kind("timelapse", "Time passes", "fx", "Shows a 'time passes' screen.", S, fn=("ShowTimeLapse",)),
    # --- items and rewards
    Kind("reward", "Reward", "items", "Gives a reward: experience, money, items (a reward of the rewards file).",
         "CQuestRewardBlock"),
    Kind("give", "Give item", "items", "Gives the player items.", S, fn=("AddItemQuest", "AddItemQuestExt")),
    Kind("take", "Take item", "items", "Takes items from the player.", S, fn=("RemoveItemQuest",)),
    Kind("equip", "Equip item", "items", "Equips an item on someone.", S, fn=("EquipItemQuest",)),
    Kind("quest_item", "Quest item off", "items", "Turns a quest item off (it can be dropped / sold again).", S,
         fn=("QuestItemDisable",)),
    Kind("minigame", "Gwent / fist fight", "items", "A game of Gwent or a fist fight; goes on from won or lost.",
         "CQuestGraphMinigameBlock"),
    # --- notes
    Kind("comment", "Comment", "notes", "A note in the graph; does nothing in the game.", "CCommentGraphBlock"),
    Kind("description", "Description", "notes", "A longer note in the graph; does nothing in the game.",
         "CDescriptionGraphBlock"),
]
BY_ID = {k.id: k for k in KINDS}
GAME_WAIT = Kind("wait_game", "Wait until", "wait", "Waits for a condition of the game.", W, simple=False)
GAME_IF = Kind("if_game", "If", "check", "True or False: a condition of the game.", I, simple=False)
GAME_SCRIPT = Kind("game_function", "Game function", "game", "Calls one of the game's quest functions.", S,
                   simple=False)


def _cond_classes(tree, o):
    """A wait's / an if's condition classes; a person's condition with what it checks: CQuestActorCondition/CQCIsAlive."""
    out = []
    for c in (o.get("conditions") or []) if o.cls == W else [o.get("questCondition")]:
        if isinstance(c, int) and c > 0:
            co = tree.obj(c)
            t = co.get("checkType") if co.cls == ACTOR else None
            out.append(f"{ACTOR}/{tree.obj(t).cls}" if isinstance(t, int) and t > 0 else co.cls)
    return out


def _cond_match(cs, k):
    """Every condition one of the kind's: exactly (2), or a person's condition by its class alone (1); 0: not."""
    if not cs:
        return 0
    if all(c in k.cond for c in cs):
        return 2
    return 1 if all(c.split("/")[0] in k.cond for c in cs) else 0


def kind_of(tree, n):
    """The kind of block object n: a simple one where it matches, else the game block's own."""
    o = tree.obj(n)
    cs = _cond_classes(tree, o) if o.cls in (W, I) else []
    best = None
    for k in KINDS:
        if k.cls != o.cls:
            continue
        if k.cond:
            m = _cond_match(cs, k)
            if m == 2:
                return k
            if m == 1 and best is None:
                best = k
            continue
        if k.fn and str(o.get("functionName")) not in k.fn:
            continue
        return k
    if best is not None:
        return best
    if o.cls == W:
        return GAME_WAIT
    if o.cls == I:
        return GAME_IF
    if o.cls == S:
        return GAME_SCRIPT
    from .vanilla_graph import NAMES, short
    return Kind(o.cls, NAMES.get(o.cls, short(o.cls)), "game", "One of the game's own blocks.", o.cls, simple=False)


def objective_label(inputs):
    """An objective's title by what leads into it: shown, done, failed, gone."""
    words = {"Activate": "show", "Success": "done", "Failure": "failed", "Deactivate": "hide"}
    got = [words[i] for i in ("Activate", "Success", "Failure", "Deactivate") if i in (inputs or ())]
    return "Objective" + (": " + " / ".join(got) if got else "")


# what a new block of a kind starts with (a block made new has the class's own values - for a wait for a fact that
# is "the fact is 0", true at once - so the kinds give the start one means): {kind: {(where, field): value}};
# where: "block", "cond" (its first condition), "check" (what that condition checks)
STARTS = {
    "wait_fact": {("cond", "compareFunc"): "CF_GreaterEqual", ("cond", "value"): 1},
    "if_fact": {("cond", "compareFunc"): "CF_GreaterEqual", ("cond", "value"): 1},
    "set_fact": {("block", "value"): 1},
    "wait_time": {("cond", "seconds"): 1},
    "wait_item": {("check", "quantity"): 1, ("check", "compareFunc"): "CF_GreaterEqual"},
    "if_item": {("check", "quantity"): 1, ("check", "compareFunc"): "CF_GreaterEqual"},
    "wait_near": {("check", "distance"): 5.0, ("check", "compareFunc"): "CF_Less"},
    "if_near": {("check", "distance"): 5.0, ("check", "compareFunc"): "CF_Less"},
    "wait_alive": {("check", "inverted"): True},
}


def _start(editor, n, kind, catalog):
    if kind.id not in STARTS:
        return
    if catalog is None:
        from . import game_catalog
        catalog = game_catalog.load() or {}
    o = editor.tree.obj(n)
    cond = (o.get("conditions") or [None])[0] if o.cls == W else o.get("questCondition") if o.cls == I else None
    for (where, field), value in STARTS[kind.id].items():
        target = {"block": n, "cond": cond}.get(where)
        if where == "check" and cond:
            target = editor.tree.obj(cond).get("checkType")
        if not (isinstance(target, int) and target > 0):
            continue
        cls = editor.tree.obj(target).cls
        typ = (((catalog.get("classes") or {}).get(cls) or {}).get("fields") or {}).get(field, {}).get("type")
        if typ:
            editor.set_field(target, field, value, typ)


def create(editor, graph, kind, catalog=None):
    """A new block of `kind` in graph object `graph` (a copy of one the game has made new, its links cleared, what
    the kind starts with set). -> its number."""
    n = _create(editor, graph, kind, catalog)
    _start(editor, n, kind, catalog)
    if kind.id == "phase":
        _empty_phase(editor, n)
    return n


def _empty_phase(editor, n):
    """A new phase: an empty graph inside with a start and an end."""
    emb = editor.tree.obj(n).get("embeddedGraph")
    if not (isinstance(emb, int) and emb > 0):
        return
    old = [b for b in editor.tree.obj(emb).get("graphBlocks") or [] if isinstance(b, int) and b > 0]
    if old:
        editor.remove_blocks(emb, old)
    emb = editor.tree.obj(n).get("embeddedGraph")
    a = editor.add_block(emb, "CQuestPhaseInputBlock")
    b = editor.add_block(emb, "CQuestPhaseOutputBlock")
    editor.connect(a, "", b, "")


def _create(editor, graph, kind, catalog=None):
    if kind.cond:
        base, _, check = kind.cond[0].partition("/")
        if kind.cls == W:
            n = editor.add_wait(graph, base)
        else:
            n = editor.add_block(graph, I)
            editor.add_condition(n, base)
        if check:                                       # a person's condition: what it checks
            o = editor.tree.obj(n)
            c = (o.get("conditions") or [None])[0] if kind.cls == W else o.get("questCondition")
            editor.set_check(c, check)
        return n
    if kind.fn:
        return editor.add_function(graph, kind.fn[0], function_params(kind.fn[0], catalog))
    return editor.add_block(graph, kind.cls)


SCRIPT_TYPES = {"name": "CName", "bool": "Bool", "float": "Float", "int": "Int32", "string": "String",
                "Vector": "Vector", "GameTimeWrapper": "GameTimeWrapper"}


def script_type(t):
    """A quest function's parameter type as the scripts write it -> as the quest file's value holds it:
    array<name> -> array:2,0,CName, CEntityTemplate -> handle:CEntityTemplate."""
    t = t.replace(" ", "")
    if t.startswith("array<") and t.endswith(">"):
        return "array:2,0," + script_type(t[6:-1])
    if t in SCRIPT_TYPES:
        return SCRIPT_TYPES[t]
    if t.startswith("C") and t[1:2].isupper():
        return "handle:" + t
    return t


def function_params(name, catalog=None):
    """[(name, script type, value)] of a game function from the catalog: its signature, each value the one the game
    uses most (empty when none)."""
    if catalog is None:
        from . import game_catalog
        catalog = game_catalog.load() or {}
    f = (catalog.get("functions") or {}).get(name) or {}
    out = []
    for p in f.get("params") or []:
        typ = p.get("file_type") or script_type(p.get("type") or "name")
        vals = p.get("values") or []
        v = vals[0][0] if vals else None
        conv = {"Int32": lambda x: int(float(x)), "Float": float, "Bool": lambda x: x == "yes", "CName": str,
                "String": str}
        if typ not in conv and not (typ.startswith("E") and typ[1:2].isupper()):
            v = None                                    # (a list, a struct, a file: empty to start)
        try:
            v = conv.get(typ, str)(v) if v not in (None, "") else None
        except ValueError:
            v = None
        out.append((p["name"], typ, v))
    return out


# --- what a block does, in a line or three (the node's body)
CMP = {"CF_Equal": "=", "CF_NotEqual": "is not", "CF_Less": "<", "CF_LessEqual": "<=", "CF_Greater": ">",
       "CF_GreaterEqual": ">=", "CO_Equal": "=", "CO_NotEqual": "is not", "CO_Lesser": "<", "CO_LesserEq": "<=",
       "CO_Greater": ">", "CO_GreaterEq": ">="}


def _fact(c):
    fact = c.get("factId") or c.get("factId1") or "?"
    if c.cls == "CQuestFactsDBExCondition":
        return f"{fact} {CMP.get(c.get('compareFunc'), '?')} {c.get('factId2')}"
    cmp, value = CMP.get(c.get("compareFunc", "CF_Equal"), "="), c.get("value", 0)     # (the class's own: = 0)
    if cmp == ">=" and value == 1:
        return f"{fact} is set"
    if cmp == "<" and value == 1:
        return f"{fact} is not set"
    return f"{fact} {cmp} {value}"


def _seconds(c):
    if c.cls == "CQuestHiResRealtimeDelayCondition":
        s = (c.get("hours") or 0) * 3600 + (c.get("minutes") or 0) * 60 + (c.get("seconds") or 0) + \
            (c.get("miliseconds") or 0) / 1000
        return f"{s:g} s"
    return "a while"


def _who(tag):
    return "the player" if str(tag or "PLAYER") == "PLAYER" else str(tag)


def condition_text(qf, n):
    """A condition, said plainly."""
    c = qf.tree.obj(n)
    k = c.cls
    if k in ("CQuestFactsDBCondition", "CQuestFactsDBExCondition"):
        return _fact(c)
    if k == "CQuestInsideTriggerCondition":
        return f"{_who(c.get('tag'))} {'inside' if c.get('isInside', True) else 'outside'} {c.get('triggerTag')}"
    if k == "CQuestEnterTriggerCondition":
        return f"{_who(c.get('tag'))} {'enters' if c.get('onAreaEntry', True) else 'leaves'} {c.get('triggerTag')}"
    if k in ("CQuestHiResRealtimeDelayCondition", "CQuestRealtimeDelayCondition"):
        return _seconds(c)
    if k == "CQuestTagsPresenceCondition":
        return f"{qf.text(c.get('tags'))} there"
    if k == "CQuestInteractionCondition":
        return f"'{c.get('interactionName')}' on {qf.text(c.get('ownerTags'))}"
    if k == "W3QuestCond_ReusableClueUsed":
        return f"clue {c.get('clueTag')} examined"
    if k == "W3QuestCond_ActorIsDespawned":
        return f"{c.get('actorTag')} gone"
    if k == "W3QuestCond_BookHasBeenRead":
        return f"{c.get('bookName')} read"
    if k == "W3QuestCond_IsItemQuantityMet":
        return f"{_who(c.get('entityTag'))} has {c.get('itemName') or c.get('itemTag') or c.get('itemCategory')} " \
               f"{CMP.get(c.get('comparator'), '>=')} {c.get('count', 0)}"
    if k in ("CQCHasItem", "CQCItemQuantity"):
        return f"has {c.get('item') or c.get('itemTag') or c.get('itemCategory')} " \
               f"{CMP.get(c.get('compareFunc'), '>=')} {c.get('quantity', 1)}"
    if k == "CQuestJournalStatusCondition":
        st = str(c.get("status") or "JS_Inactive").replace("JS_", "").lower()
        return f"{_journal(qf, c.get('entry'))} {'not ' if c.get('inverted') else ''}{st}"
    if k == "CQuestLogicOperationCondition":
        op = " or " if c.get("logicOperation") == "LO_Or" else " and "
        parts = [condition_text(qf, x) for x in c.get("conditions") or [] if isinstance(x, int) and x > 0]
        return op.join(parts) or "(nothing)"
    if k == ACTOR:
        t = c.get("checkType")
        return f"{_who(c.get('actorTag'))} {check_text(qf, t) if isinstance(t, int) and t > 0 else 'state'}"
    if k == "CQuestFightCondition":
        return f"fight with {c.get('tag')}"
    if k == "W3QuestCond_World":
        return str(c.get("currentArea") or "").replace("AN_", "")
    return qf.object_text(n)


def check_text(qf, n):
    """What a person's condition checks: near, alive, has an item ..."""
    c = qf.tree.obj(n)
    k, inv = c.cls, bool(c.get("inverted"))
    if k == "CQCDistanceTo":
        cmp = CMP.get(c.get("compareFunc"), "<")
        near = cmp in ("<", "<=")
        near = near != inv
        return f"{'within' if near else 'farther than'} {c.get('distance', 0):g} m of {_who(c.get('targetNodeTag'))}"
    if k == "CQCIsAlive":
        return "dead" if inv else "alive"
    if k in ("CQCHasItem", "CQCItemQuantity", "CQCHasItemGE"):
        what = c.get("item") or c.get("itemTag") or c.get("itemCategory")
        return f"{'has not' if inv else 'has'} {what} {CMP.get(c.get('compareFunc'), '>=')} {c.get('quantity', 1)}"
    if k == "CQCAnimationState":
        return f"plays {c.get('animationName')}"
    if k == "CQCIsOpenedMenu":
        return f"opened {c.get('menuToBeOpened')}"
    if k == "CQCHasAbility":
        return f"has ability {c.get('ability')}"
    return short_cls(k)


def short_cls(cls):
    from .vanilla_graph import short
    return short(cls).replace("QC", "")


_NAMES = {}
OWN_CAPTIONS = {}       # {journal entry GUID hex: its text} of an own quest open in the graph (its journal is no game file)


def _journal(qf, h):
    """A journal path's entry: 'quest / phase / objective' as the journal files name them (else the deepest file)."""
    import os
    from . import journal_index as J
    t = qf.tree
    if not (isinstance(h, int) and h > 0):
        return "journal"
    ch = J.chain(t, h)
    if ch and ch[-1][1] in OWN_CAPTIONS:
        return OWN_CAPTIONS[ch[-1][1]]
    names = _NAMES.setdefault(id(qf.depot), J.Names(qf.depot))
    try:
        label, _kind = names.label(ch)
        if label and label != "?":
            return label
    except Exception:                                   # noqa: BLE001 - a journal file not found
        pass
    files = [os.path.basename(p).replace(".journal", "") for p, _g in ch if p]
    return files[-1] if files else "journal"


def _base(qf, h, ext):
    import os
    return os.path.basename(qf.import_path(h) or "").replace(ext, "") if h else ""


def summary(qf, n, kind):
    """The node's lines for a block of a kind: what it does with which values (None: the plain property list)."""
    o = qf.tree.obj(n)
    k = kind.id
    if kind.cls in (W, I):
        conds = [x for x in ((o.get("conditions") or []) if o.cls == W else [o.get("questCondition")])
                 if isinstance(x, int) and x > 0]
        return [condition_text(qf, x) for x in conds][:3] or ["(nothing yet)"]
    if k == "set_fact":
        return [f"{o.get('factID')} {'= ' if o.get('setExactValue') else '+'}{o.get('value', 0)}"]
    if k in ("objective", "journal", "mappin", "counter", "track"):
        e = o.get("questEntry") or o.get("entry") or o.get("mappinEntry") or o.get("manualObjective")
        return [_journal(qf, e)]
    if k in ("scene", "talk", "context_talk"):
        line = [_base(qf, o.get("scene"), ".w2scene") or "no scene"]
        if k == "talk" and o.get("actorTags"):
            line.append("with " + qf.text(o.get("actorTags")))
        return line
    if k == "spawn":
        out = []
        for s in o.get("spawnsets") or []:
            if isinstance(s, int) and s > 0:
                so = qf.tree.obj(s)
                comm = _base(qf, so.get("spawnset") or so.get("community"), ".w2comm") or "?"
                out.append(f"{comm} gone" if "Deactivate" in so.cls else f"{comm}: {so.get('phase') or 'default'}")
        return out[:3] or ["(none)"]
    if k == "layers":
        out = []
        for key, word in (("layersToShow", "show"), ("layersToHide", "hide")):
            if o.get(key):
                out.append(f"{word} {', '.join(str(x).replace('/', chr(92)).split(chr(92))[-1] for x in o.get(key))}")
        return out or ["(nothing)"]
    if k == "teleport":
        return [f"{qf.text(o.get('actorsTags'))} to {qf.text(o.get('locationTag'))}"]
    if k == "reward":
        return [str(o.get("rewardName") or "?")]
    if k in ("ai", "ai_stop", "ai_poke"):
        a = o.get("ai")
        what = short_cls(qf.tree.obj(a).cls).replace("AI", "").replace("Action", "") if \
            isinstance(a, int) and a > 0 else (str(o.get("pokeEvent")) if k == "ai_poke" else "")
        return [f"{o.get('npcTag') or 'PLAYER'}{': ' + what if what else ''}"]
    if k == "anim":
        return [f"{o.get('entityTag')}: {o.get('animationName')}"]
    if k == "encounters":
        return [f"{o.get('encounterTag')} {'on' if o.get('enableEncounter', True) else 'off'}"]
    if k in ("input", "output"):
        return [str(o.get("socketID") or "").strip() or "(the phase's own)"]
    if k == "phase":
        ph, emb = o.get("phase"), o.get("embeddedGraph")
        if ph and (not isinstance(ph, int) or ph < 0):
            return [_base(qf, ph, "")]
        if isinstance(emb, int) and emb > 0:
            return [f"{len(qf.tree.obj(emb).get('graphBlocks') or [])} blocks inside"]
        return []
    if kind.cls == S:                                   # a game function: its values
        lines = [f"{p.get('name')}: {qf.text(p.get('value'))}" for p in o.get("parameters") or []][:3]
        return lines
    return None
