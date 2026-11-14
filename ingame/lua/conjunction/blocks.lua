-- blocks.py: the kinds of blocks the quest graph offers - one graph for every quest, the simple blocks first, the
-- game's own blocks beside them. A simple block is one game block with a plain name and a plain explanation (over all
-- 177 233 blocks of the game's quests these kinds cover about 85 %); what is not among them is a game block, its card
-- made from the catalog.
--   BL.kind_of(tree, n) -> kind          the kind of block object n
--   BL.KINDS, BL.GROUPS                  the sidebar: groups in order, the kinds of each
--   BL.summary(qf, n, kind) -> lines     what a block does with which values (nil: the plain property list)
-- A kind: id, label (the node's title), group, text (what it does: the sidebar and the card), cls, and for a wait /
-- an if its condition classes (cond), for a script block its functions (fn).
local P = require("conjunction.py")
local S = require("conjunction.pystr")
local V = require("conjunction.vanilla_graph")
local BL = {}

local function K(t)
  t.cond, t.fn, t.ai = t.cond or {}, t.fn or {}, t.ai or {}
  if t.simple == nil then t.simple = true end
  t.extra = t.extra or {}
  return t
end
BL.Kind = K

BL.GROUPS = {
  {"flow", "Story flow"}, {"wait", "Wait until"}, {"check", "Check"}, {"facts", "Facts"}, {"journal", "Journal"},
  {"talk", "Talks and scenes"}, {"people", "People"}, {"world", "World"}, {"fx", "Effects and sound"},
  {"items", "Items and rewards"}, {"notes", "Notes"}, {"game", "Game blocks"},
}
BL.GROUP_COLOUR = {flow = "#7d8fa8", wait = "#d9a441", check = "#e0b85a", facts = "#5cb85c", journal = "#4fb3bf",
                   talk = "#a779d9", people = "#e08a4f", world = "#6f9bd1", fx = "#c97fb0", items = "#c9b458",
                   notes = "#8c8c70", game = "#6a6a74"}

local ACTOR = "CQuestActorCondition"
local PHASE, W, I, SCRIPT, AI = "CQuestPhaseBlock", "CQuestPauseConditionBlock", "CQuestConditionBlock",
  "CQuestScriptBlock", "CQuestScriptedActionsBlock"
BL.ACTOR, BL.W, BL.I, BL.S = ACTOR, W, I, SCRIPT
BL.KINDS = {
  -- story flow
  K{id = "phase", label = "Custom block", group = "flow", cls = PHASE,
    text = "A block with its own graph inside (the game calls it a phase): double click to open it and build " ..
      "with the game's blocks; its Input and Output blocks inside are its ways in and out. Kept as a " ..
      "template, it is a block of the sidebar."},
  K{id = "input", label = "Input", group = "flow", cls = "CQuestPhaseInputBlock",
    text = "A way into the custom block it is in (its name: the input's name outside)."},
  K{id = "output", label = "Output", group = "flow", cls = "CQuestPhaseOutputBlock",
    text = "A way out of the custom block it is in (its name: the output's name outside)."},
  K{id = "start", label = "Quest start", group = "flow", cls = "CQuestStartBlock",
    text = "The quest begins here."},
  K{id = "end", label = "Quest end", group = "flow", cls = "CQuestEndBlock",
    text = "The quest is over here."},
  K{id = "all", label = "All of these", group = "flow", cls = "CQuestAndBlock",
    text = "Goes on once every link into it has arrived."},
  K{id = "first", label = "Whichever first", group = "flow", cls = "CQuestXorBlock",
    text = "Goes on with the first link that arrives."},
  K{id = "random", label = "At random", group = "flow", cls = "CQuestRandomBlock",
    text = "Goes on along one of its outputs, picked at random."},
  K{id = "checkpoint", label = "Checkpoint", group = "flow", cls = "CQuestCheckpointBlock",
    text = "A point the game saves and loads back to."},
  K{id = "stop", label = "Stop branches", group = "flow", cls = "CQuestCutControlBlock",
    text = "Stops the blocks wired to its Thunder output (into their Cut input)."},
  -- wait until
  K{id = "wait_fact", label = "Wait for a fact", group = "wait", cls = W,
    cond = {"CQuestFactsDBCondition", "CQuestFactsDBExCondition"},
    text = "Waits until a fact has a value (set by a talk, a script, a block)."},
  K{id = "wait_area", label = "Wait: player in area", group = "wait", cls = W,
    cond = {"CQuestInsideTriggerCondition"},
    text = "Waits until someone (the player) is inside a trigger area - or outside, when 'is inside' is off."},
  K{id = "wait_enter", label = "Wait: enters area", group = "wait", cls = W,
    cond = {"CQuestEnterTriggerCondition"},
    text = "Waits until someone enters a trigger area."},
  K{id = "wait_time", label = "Wait some time", group = "wait", cls = W,
    cond = {"CQuestHiResRealtimeDelayCondition", "CQuestRealtimeDelayCondition"},
    text = "Waits a number of real seconds."},
  K{id = "wait_gametime", label = "Wait for game time", group = "wait", cls = W,
    cond = {"CQuestTimePeriodCondition"},
    text = "Waits until the game's clock is between two hours."},
  K{id = "wait_present", label = "Wait: someone is there", group = "wait", cls = W,
    cond = {"CQuestTagsPresenceCondition"},
    text = "Waits until people with these tags are spawned."},
  K{id = "wait_near", label = "Wait: someone near", group = "wait", cls = W,
    cond = {"CQuestActorCondition/CQCDistanceTo"},
    text = "Waits until a person is near (or far from) someone or a place."},
  K{id = "wait_alive", label = "Wait: alive or dead", group = "wait", cls = W,
    cond = {"CQuestActorCondition/CQCIsAlive"},
    text = "Waits until a person is dead (or alive)."},
  K{id = "wait_actor", label = "Wait: a person's state", group = "wait", cls = W,
    cond = {"CQuestActorCondition/CQCAnimationState", "CQuestActorCondition"},
    text = "Waits for a person: an animation, an attitude, a menu open ..."},
  K{id = "wait_fight", label = "Wait for a fight", group = "wait", cls = W,
    cond = {"CQuestFightCondition", "CQuestInCombatCondition"},
    text = "Waits until a fight starts or is over (its enemies dead)."},
  K{id = "wait_used", label = "Wait: used (E)", group = "wait", cls = W,
    cond = {"CQuestInteractionCondition"},
    text = "Waits until the player uses an object (its interaction: loot, use, examine ...)."},
  K{id = "wait_clue", label = "Wait: clue examined", group = "wait", cls = W,
    cond = {"W3QuestCond_ReusableClueUsed", "W3QuestCond_UsedFocus"},
    text = "Waits until the player examines a clue (witcher senses)."},
  K{id = "wait_item", label = "Wait: player has item", group = "wait", cls = W,
    cond = {"CQuestActorCondition/CQCHasItem", "W3QuestCond_IsItemQuantityMet", "CQCHasItem", "CQCItemQuantity",
            "CQuestActorCondition/CQCItemQuantity", "CQuestActorCondition/CQCHasItemGE"},
    text = "Waits until the player carries an item (or enough of it)."},
  K{id = "wait_gone", label = "Wait: someone is gone", group = "wait", cls = W,
    cond = {"W3QuestCond_ActorIsDespawned"},
    text = "Waits until a person has despawned."},
  K{id = "wait_book", label = "Wait: book read", group = "wait", cls = W,
    cond = {"W3QuestCond_BookHasBeenRead", "W3QuestCond_BookHasBeenReadExt"},
    text = "Waits until the player has read a book or note."},
  K{id = "wait_world", label = "Wait: in a world", group = "wait", cls = W,
    cond = {"W3QuestCond_World"},
    text = "Waits until the player is in a world / area."},
  K{id = "wait_quest", label = "Wait: quest state", group = "wait", cls = W,
    cond = {"CQuestJournalStatusCondition"},
    text = "Waits until a quest or objective is active, done or failed."},
  K{id = "wait_all", label = "Wait for several things", group = "wait", cls = W,
    cond = {"CQuestLogicOperationCondition"},
    text = "Waits until conditions combined with and / or hold."},
  -- check
  K{id = "if_fact", label = "If fact", group = "check", cls = I,
    cond = {"CQuestFactsDBCondition", "CQuestFactsDBExCondition"},
    text = "Goes on along True or False: has a fact this value?"},
  K{id = "if_quest", label = "If quest state", group = "check", cls = I,
    cond = {"CQuestJournalStatusCondition"},
    text = "True or False: is a quest or objective active, done, failed?"},
  K{id = "if_area", label = "If in area", group = "check", cls = I,
    cond = {"CQuestInsideTriggerCondition"},
    text = "True or False: is someone inside a trigger area?"},
  K{id = "if_near", label = "If someone near", group = "check", cls = I,
    cond = {"CQuestActorCondition/CQCDistanceTo"},
    text = "True or False: is a person near someone or a place?"},
  K{id = "if_actor", label = "If a person's state", group = "check", cls = I,
    cond = {"CQuestActorCondition/CQCIsAlive", "CQuestActorCondition"},
    text = "True or False: a person alive, an animation, a menu open ...?"},
  K{id = "if_item", label = "If player has item", group = "check", cls = I,
    cond = {"CQuestActorCondition/CQCHasItem", "W3QuestCond_IsItemQuantityMet", "CQCHasItem",
            "CQuestActorCondition/CQCItemQuantity", "CQuestActorCondition/CQCHasItemGE"},
    text = "True or False: does the player carry it?"},
  K{id = "if_all", label = "If several things", group = "check", cls = I,
    cond = {"CQuestLogicOperationCondition"},
    text = "True or False: conditions combined with and / or."},
  -- facts
  K{id = "set_fact", label = "Set fact", group = "facts", cls = "CQuestFactsDBChangingBlock",
    text = "Adds a value to a fact - what talks, waits and ifs look at."},
  K{id = "remove_fact", label = "Remove fact", group = "facts", cls = SCRIPT,
    fn = {"RemoveFactQuest"},
    text = "Takes a fact away again."},
  -- journal
  K{id = "objective", label = "Objective", group = "journal", cls = "CJournalQuestBlock",
    text = "A quest's objective in the journal: wired into Activate it shows, into Success it is ticked off, " ..
      "Failure failed, Deactivate gone."},
  K{id = "journal", label = "Journal entry", group = "journal", cls = "CJournalBlock",
    text = "Shows a journal entry: a quest's description, a person, a monster."},
  K{id = "mappin", label = "Map pin", group = "journal", cls = "CJournalQuestMappinStateBlock",
    text = "Switches an objective's map pin on or off."},
  K{id = "counter", label = "Objective counter", group = "journal", cls = "CJournalQuestObjectiveCounterGraphBlock",
    text = "Counts an objective up (3 of 5 ...)."},
  K{id = "track", label = "Track quest", group = "journal", cls = "CJournalQuestTrackBlock",
    text = "Makes a quest the one the player follows."},
  K{id = "pin_status", label = "Map pin status", group = "journal", cls = SCRIPT,
    fn = {"SetMapPinStatus", "EnableDynamicMappin"},
    text = "Turns a map pin of the world on or off."},
  -- talks and scenes
  K{id = "scene", label = "Play scene", group = "talk", cls = "CQuestSceneBlock",
    text = "Plays a scene (a talk, a cutscene) and goes on from its outputs."},
  K{id = "talk", label = "Talk (on E)", group = "talk", cls = "CQuestInteractionDialogBlock",
    text = "A talk that starts when the player talks to someone (E)."},
  K{id = "context_talk", label = "Talk option", group = "talk", cls = "CQuestContextDialogBlock",
    text = "Adds a choice to someone's talk while it runs."},
  -- people
  K{id = "spawn", label = "People appear", group = "people", cls = "CQuestStoryPhaseSetterBlock",
    text = "Spawns or removes people: a community's story phase."},
  K{id = "ai", label = "Make someone act", group = "people", cls = AI,
    text = "Tells a person what to do: walk a path, go somewhere, follow, play an animation, fight ..."},
  K{id = "ai_stop", label = "Let someone go", group = "people", cls = "CQuestResetScriptedActionsBlock",
    text = "Ends what an earlier 'make someone act' started."},
  K{id = "ai_poke", label = "Nudge an action", group = "people", cls = "CQuestPokeScriptedActionsBlock",
    text = "Sends a signal to a running action."},
  K{id = "anim", label = "Play animation", group = "people", cls = "CQuestPlayAnimationBlock",
    text = "A person plays an animation."},
  K{id = "attitude", label = "Friend or foe", group = "people", cls = SCRIPT,
    fn = {"SetGroupAttitudeQuest", "AssignNPCGroupAttitudeQuest"},
    text = "Makes a group friendly, neutral or hostile to another."},
  K{id = "immortal", label = "Immortal", group = "people", cls = SCRIPT,
    fn = {"SetImmortalQuest"},
    text = "Makes someone immortal or unkillable - or not any more."},
  K{id = "health", label = "Set health", group = "people", cls = SCRIPT,
    fn = {"SetHealthQuest"},
    text = "Sets someone's health."},
  K{id = "look", label = "Change look", group = "people", cls = SCRIPT,
    fn = {"AppearanceChange"},
    text = "Gives someone another appearance."},
  K{id = "weapon", label = "Draw weapon", group = "people", cls = SCRIPT,
    fn = {"DrawWeaponQuest"},
    text = "Someone draws or sheathes a weapon."},
  K{id = "npc_state", label = "Person's state", group = "people", cls = SCRIPT,
    fn = {"ChangeNPCStateQuest"},
    text = "Changes a person's state (calm, alert ...)."},
  K{id = "no_talk", label = "No talking", group = "people", cls = SCRIPT,
    fn = {"DisableNPCInteractivness"},
    text = "Someone can not be talked to - or can again."},
  -- world
  K{id = "layers", label = "Show / hide place", group = "world", cls = "CQuestLayersHiderBlock",
    text = "Shows or hides layers of the world: a place's objects."},
  K{id = "teleport", label = "Teleport", group = "world", cls = "CQuestTeleportBlock",
    text = "Moves the player or people to a place (a tag)."},
  K{id = "time", label = "Time of day", group = "world", cls = "CQuestTimeManagementBlock",
    text = "Sets, stops or speeds up the game's clock."},
  K{id = "weather", label = "Weather", group = "world", cls = SCRIPT,
    fn = {"ChangeWeatherQuest"},
    text = "Changes the weather."},
  K{id = "door", label = "Door", group = "world", cls = SCRIPT,
    fn = {"DoorChangeState"},
    text = "Opens, closes, locks or unlocks a door."},
  K{id = "lights", label = "Lights", group = "world", cls = SCRIPT,
    fn = {"SetLights"},
    text = "Switches lights with a tag on or off."},
  K{id = "containers", label = "Containers", group = "world", cls = SCRIPT,
    fn = {"EnableOrDisableContainers"},
    text = "Makes containers searchable or not."},
  K{id = "encounters", label = "Creatures nearby", group = "world", cls = "CQuestEncounterManagerBlock",
    text = "Turns the world's encounters (monsters, bandits) on or off."},
  K{id = "world", label = "Change world", group = "world", cls = "CQuestChangeWorldBlock",
    text = "Travels to another world (Skellige, Toussaint ...)."},
  K{id = "fast_travel", label = "Fast travel", group = "world", cls = "CQuestManageFastTravelBlock",
    text = "Allows or forbids fast travel, shows signposts."},
  K{id = "travel_points", label = "Travel point", group = "world", cls = SCRIPT,
    fn = {"ManageTeleport"},
    text = "Moves the player to a point through a loading screen."},
  K{id = "component", label = "Switch part of an object", group = "world", cls = SCRIPT,
    fn = {"EntityComponentQuest"},
    text = "Turns a part of an object on or off (a light, an interaction, a trigger)."},
  -- effects and sound
  K{id = "effect", label = "Effect", group = "fx", cls = SCRIPT,
    fn = {"PlayEffectQuest"},
    text = "Plays or stops an effect on an object or person (fire, smoke, glow ...)."},
  K{id = "sound", label = "Sound", group = "fx", cls = SCRIPT,
    fn = {"SoundEventQuest", "SoundEventOnActorQuest"},
    text = "Plays a sound event, in the world or on a person."},
  K{id = "fade", label = "Fade", group = "fx", cls = SCRIPT,
    fn = {"FadeOutQuest", "FadeInQuest"},
    text = "Fades the screen out to black or back in."},
  K{id = "clue", label = "Witcher senses clue", group = "fx", cls = SCRIPT,
    fn = {"FocusClueManager", "FocusSetHighlight", "FocusEffect", "FocusSoundClueManager"},
    text = "Makes objects clues for the witcher senses (highlighted, examined)."},
  K{id = "block_gameplay", label = "Block controls", group = "fx", cls = SCRIPT,
    fn = {"BlockGameplayFunctionality"},
    text = "Blocks things the player can do (run, fight, meditate ...)."},
  K{id = "tutorial", label = "Tutorial", group = "fx", cls = SCRIPT,
    fn = {"TutorialMessage", "TutorialHintHide"},
    text = "Shows or hides a tutorial hint."},
  K{id = "timelapse", label = "Time passes", group = "fx", cls = SCRIPT,
    fn = {"ShowTimeLapse"},
    text = "Shows a 'time passes' screen."},
  -- items and rewards
  K{id = "reward", label = "Reward", group = "items", cls = "CQuestRewardBlock",
    text = "Gives a reward: experience, money, items (a reward of the rewards file)."},
  K{id = "give", label = "Give item", group = "items", cls = SCRIPT,
    fn = {"AddItemQuest", "AddItemQuestExt"},
    text = "Gives the player items."},
  K{id = "take", label = "Take item", group = "items", cls = SCRIPT,
    fn = {"RemoveItemQuest"},
    text = "Takes items from the player."},
  K{id = "equip", label = "Equip item", group = "items", cls = SCRIPT,
    fn = {"EquipItemQuest"},
    text = "Equips an item on someone."},
  K{id = "quest_item", label = "Quest item off", group = "items", cls = SCRIPT,
    fn = {"QuestItemDisable"},
    text = "Turns a quest item off (it can be dropped / sold again)."},
  K{id = "minigame", label = "Gwent / fist fight", group = "items", cls = "CQuestGraphMinigameBlock",
    text = "A game of Gwent or a fist fight; goes on from won or lost."},
  -- notes
  K{id = "comment", label = "Comment", group = "notes", cls = "CCommentGraphBlock",
    text = "A note in the graph; does nothing in the game."},
  K{id = "description", label = "Description", group = "notes", cls = "CDescriptionGraphBlock",
    text = "A longer note in the graph; does nothing in the game."},
}
BL.BY_ID = {}
for _, k in ipairs(BL.KINDS) do BL.BY_ID[k.id] = k end
BL.GAME_WAIT = K{id = "wait_game", label = "Wait until", group = "wait", text = "Waits for a condition of the game.",
                 cls = W, simple = false}
BL.GAME_IF = K{id = "if_game", label = "If", group = "check", text = "True or False: a condition of the game.", cls = I,
               simple = false}
BL.GAME_SCRIPT = K{id = "game_function", label = "Game function", group = "game",
                   text = "Calls one of the game's quest functions.", cls = SCRIPT, simple = false}

local obj_ref, ival, truth, or_, str = V.obj_ref, V.ival, V.truth, V.or_, V.str
local function has(list, x)
  for _, y in ipairs(list) do if y == x then return true end end
  return false
end

-- a wait's / an if's condition classes; a person's condition with what it checks: CQuestActorCondition/CQCIsAlive
local function cond_classes(tree, o)
  local out = {}
  local list = o.cls == W and (or_(o:get("conditions"), {})) or {o:get("questCondition")}
  for i = 1, (o.cls == W and #list or 1) do
    local c = list[i]
    if obj_ref(c) then
      local co = tree:obj(ival(c))
      local t = co.cls == ACTOR and co:get("checkType") or nil
      out[#out + 1] = obj_ref(t) and (ACTOR .. "/" .. tree:obj(ival(t)).cls) or co.cls
    end
  end
  return out
end
BL.cond_classes = cond_classes

-- every condition one of the kind's: exactly (2), or a person's condition by its class alone (1); 0: not
local function cond_match(cs, k)
  if #cs == 0 then return 0 end
  local all = true
  for _, c in ipairs(cs) do if not has(k.cond, c) then all = false break end end
  if all then return 2 end
  for _, c in ipairs(cs) do
    if not has(k.cond, (c:match("^[^/]*"))) then return 0 end
  end
  return 1
end

-- the kind of block object n: a simple one where it matches, else the game block's own
function BL.kind_of(tree, n)
  local o = tree:obj(n)
  local cs = (o.cls == W or o.cls == I) and cond_classes(tree, o) or {}
  local best
  for _, k in ipairs(BL.KINDS) do
    if k.cls == o.cls then
      if #k.cond > 0 then
        local m = cond_match(cs, k)
        if m == 2 then return k end
        if m == 1 and best == nil then best = k end
      elseif not (#k.fn > 0 and not has(k.fn, str(o:get("functionName")))) then
        return k
      end
    end
  end
  if best ~= nil then return best end
  if o.cls == W then return BL.GAME_WAIT end
  if o.cls == I then return BL.GAME_IF end
  if o.cls == SCRIPT then return BL.GAME_SCRIPT end
  return K{id = o.cls, label = V.NAMES[o.cls] or V.short(o.cls), group = "game", text = "One of the game's own blocks.",
           cls = o.cls, simple = false}
end

-- an objective's title by what leads into it (inputs: a set of socket names): shown, done, failed, gone
function BL.objective_label(inputs)
  local words = {Activate = "show", Success = "done", Failure = "failed", Deactivate = "hide"}
  local got = {}
  for _, i in ipairs({"Activate", "Success", "Failure", "Deactivate"}) do
    if inputs and inputs[i] then got[#got + 1] = words[i] end
  end
  return "Objective" .. (#got > 0 and (": " .. table.concat(got, " / ")) or "")
end

-- a quest function's parameter type as the scripts write it -> as the quest file's value holds it:
-- array<name> -> array:2,0,CName, CEntityTemplate -> handle:CEntityTemplate
BL.SCRIPT_TYPES = {name = "CName", bool = "Bool", float = "Float", int = "Int32", string = "String", Vector = "Vector",
                   GameTimeWrapper = "GameTimeWrapper"}
function BL.script_type(t)
  t = P.replace(t, " ", "")
  if P.startswith(t, "array<") and P.endswith(t, ">") then return "array:2,0," .. BL.script_type(t:sub(7, -2)) end
  if BL.SCRIPT_TYPES[t] then return BL.SCRIPT_TYPES[t] end
  if t:sub(1, 1) == "C" and t:sub(2, 2):match("^%u$") then return "handle:" .. t end
  return t
end

-- what a new block of a kind starts with (a block made new has the class's own values - for a wait for a fact that
-- is "the fact is 0", true at once - so the kinds give the start one means): {kind: {{where, field, value}}};
-- where: "block", "cond" (its first condition), "check" (what that condition checks)
BL.STARTS = {
  wait_fact = {{"cond", "compareFunc", "CF_GreaterEqual"}, {"cond", "value", 1}},
  if_fact = {{"cond", "compareFunc", "CF_GreaterEqual"}, {"cond", "value", 1}},
  set_fact = {{"block", "value", 1}},
  wait_time = {{"cond", "seconds", 1}},
  wait_item = {{"check", "quantity", 1}, {"check", "compareFunc", "CF_GreaterEqual"}},
  if_item = {{"check", "quantity", 1}, {"check", "compareFunc", "CF_GreaterEqual"}},
  wait_near = {{"check", "distance", 5.0}, {"check", "compareFunc", "CF_Less"}},
  if_near = {{"check", "distance", 5.0}, {"check", "compareFunc", "CF_Less"}},
  wait_alive = {{"check", "inverted", true}},
}

local function catalog_or(catalog)
  if catalog == nil then catalog = require("conjunction.game_catalog").load() or {} end
  return catalog
end

local function start(editor, n, kind, catalog)
  local list = BL.STARTS[kind.id]
  if not list then return end
  catalog = catalog_or(catalog)
  local o = editor.tree:obj(n)
  local cond
  if o.cls == W then cond = (or_(o:get("conditions"), {}))[1]
  elseif o.cls == I then cond = o:get("questCondition") end
  for _, s in ipairs(list) do
    local where, field, value = s[1], s[2], s[3]
    local target = where == "block" and n or where == "cond" and cond or nil
    if where == "check" and truth(cond) then target = editor.tree:obj(cond):get("checkType") end
    if obj_ref(target) then
      local cls = editor.tree:obj(target).cls
      local c = P.get(P.get(catalog, "classes") or {}, cls) or {}
      local f = P.get(P.get(c, "fields") or {}, field) or {}
      local typ = P.get(f, "type")
      if P.T(typ) then editor:set_field(target, field, value, typ) end
    end
  end
end

-- a new phase: an empty graph inside with a start and an end
local function empty_phase(editor, n)
  local emb = editor.tree:obj(n):get("embeddedGraph")
  if not obj_ref(emb) then return end
  local old = {}
  for _, b in ipairs(or_(editor.tree:obj(emb):get("graphBlocks"), {})) do
    if obj_ref(b) then old[#old + 1] = b end
  end
  if #old > 0 then editor:remove_blocks(emb, old) end
  emb = editor.tree:obj(n):get("embeddedGraph")
  local a = editor:add_block(emb, "CQuestPhaseInputBlock")
  local b = editor:add_block(emb, "CQuestPhaseOutputBlock")
  editor:connect(a, "", b, "")
end

local function create(editor, graph, kind, catalog)
  if #kind.cond > 0 then
    local base, check = kind.cond[1]:match("^([^/]*)/?(.*)$")
    local n
    if kind.cls == W then
      n = editor:add_wait(graph, base)
    else
      n = editor:add_block(graph, I)
      editor:add_condition(n, base)
    end
    if check ~= "" then                                -- a person's condition: what it checks
      local o = editor.tree:obj(n)
      local c = kind.cls == W and (or_(o:get("conditions"), {}))[1] or o:get("questCondition")
      editor:set_check(c, check)
    end
    return n
  end
  if #kind.fn > 0 then return editor:add_function(graph, kind.fn[1], BL.function_params(kind.fn[1], catalog)) end
  return editor:add_block(graph, kind.cls)
end

-- a new block of `kind` in graph object `graph` (a copy of one the game has made new, its links cleared, what the
-- kind starts with set) -> its number
function BL.create(editor, graph, kind, catalog)
  local n = create(editor, graph, kind, catalog)
  start(editor, n, kind, catalog)
  if kind.id == "phase" then empty_phase(editor, n) end
  return n
end

-- {{name, script type, value}} of a game function from the catalog: its signature, each value the one the game
-- uses most (nil when none)
function BL.function_params(name, catalog)
  catalog = catalog_or(catalog)
  local NUM = require("conjunction.pynum")
  local f = P.get(P.get(catalog, "functions") or {}, name) or {}
  local conv = {
    Int32 = function(x)
      local v = NUM.float(x)
      return math.tointeger(v >= 0 and math.floor(v) or math.ceil(v))
    end,
    Float = function(x) return NUM.float(x) end,
    Bool = function(x) return x == "yes" end,
    CName = function(x) return P.str(x) end, String = function(x) return P.str(x) end,
  }
  local out = {}
  for _, p in ipairs(P.get(f, "params") or {}) do
    local typ = P.get(p, "file_type")
    if not P.T(typ) then typ = BL.script_type(P.get(p, "type") or "name") end
    local vals = P.get(p, "values") or {}
    local v = #vals > 0 and vals[1][1] or nil
    if v == require("conjunction.yaml").null then v = nil end
    if not conv[typ] and not (typ:sub(1, 1) == "E" and typ:sub(2, 2):match("^%u$")) then
      v = nil                                           -- (a list, a struct, a file: empty to start)
    end
    if v ~= nil and v ~= "" then
      local ok, x = pcall(conv[typ] or P.str, v)
      v = ok and x or nil
    else
      v = nil
    end
    out[#out + 1] = {p.name, typ, v}
  end
  return out
end

-- --- what a block does, in a line or three (the node's body)
BL.CMP = {CF_Equal = "=", CF_NotEqual = "is not", CF_Less = "<", CF_LessEqual = "<=", CF_Greater = ">",
          CF_GreaterEqual = ">=", CO_Equal = "=", CO_NotEqual = "is not", CO_Lesser = "<", CO_LesserEq = "<=",
          CO_Greater = ">", CO_GreaterEq = ">="}
local CMP = BL.CMP

local function fact(c)
  local f = str(or_(c:get("factId"), c:get("factId1"), "?"))
  if c.cls == "CQuestFactsDBExCondition" then
    return f .. " " .. (CMP[c:get("compareFunc")] or "?") .. " " .. str(c:get("factId2"))
  end
  local cmp, value = CMP[c:get("compareFunc", "CF_Equal")] or "=", c:get("value", 0)    -- (the class's own: = 0)
  if cmp == ">=" and ival(value) == 1 then return f .. " is set" end
  if cmp == "<" and ival(value) == 1 then return f .. " is not set" end
  return f .. " " .. cmp .. " " .. str(value)
end

local function seconds(c)
  if c.cls == "CQuestHiResRealtimeDelayCondition" then
    local s = ival(or_(c:get("hours"), 0)) * 3600 + ival(or_(c:get("minutes"), 0)) * 60 +
              ival(or_(c:get("seconds"), 0)) + ival(or_(c:get("miliseconds"), 0)) / 1000
    return V.g(s) .. " s"
  end
  return "a while"
end

local function who(tag)
  local s = str(or_(tag, "PLAYER"))
  return s == "PLAYER" and "the player" or str(tag)
end

local journal

-- a condition, said plainly
function BL.condition_text(qf, n)
  local c = qf.tree:obj(n)
  local k = c.cls
  if k == "CQuestFactsDBCondition" or k == "CQuestFactsDBExCondition" then return fact(c) end
  if k == "CQuestInsideTriggerCondition" then
    return who(c:get("tag")) .. " " .. (truth(c:get("isInside", true)) and "inside" or "outside") .. " " ..
           str(c:get("triggerTag"))
  end
  if k == "CQuestEnterTriggerCondition" then
    return who(c:get("tag")) .. " " .. (truth(c:get("onAreaEntry", true)) and "enters" or "leaves") .. " " ..
           str(c:get("triggerTag"))
  end
  if k == "CQuestHiResRealtimeDelayCondition" or k == "CQuestRealtimeDelayCondition" then return seconds(c) end
  if k == "CQuestTagsPresenceCondition" then return qf:text(c:get("tags")) .. " there" end
  if k == "CQuestInteractionCondition" then
    return "'" .. str(c:get("interactionName")) .. "' on " .. qf:text(c:get("ownerTags"))
  end
  if k == "W3QuestCond_ReusableClueUsed" then return "clue " .. str(c:get("clueTag")) .. " examined" end
  if k == "W3QuestCond_ActorIsDespawned" then return str(c:get("actorTag")) .. " gone" end
  if k == "W3QuestCond_BookHasBeenRead" then return str(c:get("bookName")) .. " read" end
  if k == "W3QuestCond_IsItemQuantityMet" then
    return who(c:get("entityTag")) .. " has " .. str(or_(c:get("itemName"), c:get("itemTag"), c:get("itemCategory")))
           .. " " .. (CMP[c:get("comparator")] or ">=") .. " " .. str(c:get("count", 0))
  end
  if k == "CQCHasItem" or k == "CQCItemQuantity" then
    return "has " .. str(or_(c:get("item"), c:get("itemTag"), c:get("itemCategory"))) .. " " ..
           (CMP[c:get("compareFunc")] or ">=") .. " " .. str(c:get("quantity", 1))
  end
  if k == "CQuestJournalStatusCondition" then
    local st = S.lower(P.replace(str(or_(c:get("status"), "JS_Inactive")), "JS_", ""))
    return journal(qf, c:get("entry")) .. " " .. (truth(c:get("inverted")) and "not " or "") .. st
  end
  if k == "CQuestLogicOperationCondition" then
    local op = c:get("logicOperation") == "LO_Or" and " or " or " and "
    local parts = {}
    for _, x in ipairs(or_(c:get("conditions"), {})) do
      if obj_ref(x) then parts[#parts + 1] = BL.condition_text(qf, ival(x)) end
    end
    local s = table.concat(parts, op)
    return s ~= "" and s or "(nothing)"
  end
  if k == ACTOR then
    local t = c:get("checkType")
    return who(c:get("actorTag")) .. " " .. (obj_ref(t) and BL.check_text(qf, ival(t)) or "state")
  end
  if k == "CQuestFightCondition" then return "fight with " .. str(c:get("tag")) end
  if k == "W3QuestCond_World" then return P.replace(str(or_(c:get("currentArea"), "")), "AN_", "") end
  return qf:object_text(n)
end

-- what a person's condition checks: near, alive, has an item ...
function BL.check_text(qf, n)
  local c = qf.tree:obj(n)
  local k, inv = c.cls, truth(c:get("inverted"))
  if k == "CQCDistanceTo" then
    local cmp = CMP[c:get("compareFunc")] or "<"
    local near = cmp == "<" or cmp == "<="
    near = near ~= inv
    return (near and "within" or "farther than") .. " " .. V.g(c:get("distance", 0)) .. " m of " ..
           who(c:get("targetNodeTag"))
  end
  if k == "CQCIsAlive" then return inv and "dead" or "alive" end
  if k == "CQCHasItem" or k == "CQCItemQuantity" or k == "CQCHasItemGE" then
    local what = or_(c:get("item"), c:get("itemTag"), c:get("itemCategory"))
    return (inv and "has not" or "has") .. " " .. str(what) .. " " .. (CMP[c:get("compareFunc")] or ">=") .. " " ..
           str(c:get("quantity", 1))
  end
  if k == "CQCAnimationState" then return "plays " .. str(c:get("animationName")) end
  if k == "CQCIsOpenedMenu" then return "opened " .. str(c:get("menuToBeOpened")) end
  if k == "CQCHasAbility" then return "has ability " .. str(c:get("ability")) end
  return BL.short_cls(k)
end

function BL.short_cls(cls) return P.replace(V.short(cls), "QC", "") end

local NAMES = setmetatable({}, {__mode = "k"})   -- {depot: journal_index.Names}
-- {journal entry GUID hex: its text} of an own quest open in the graph (its journal is no game file)
BL.OWN_CAPTIONS = {}

-- a journal path's entry: "quest / phase / objective" as the journal files name them (else the deepest file)
function journal(qf, h)
  local JI = require("conjunction.journal_index")
  local t = qf.tree
  if not obj_ref(h) then return "journal" end
  local ch = JI.chain(t, ival(h))
  if #ch > 0 and BL.OWN_CAPTIONS[ch[#ch][2]] then return BL.OWN_CAPTIONS[ch[#ch][2]] end
  local key = qf.depot or NAMES
  local names = NAMES[key]
  if names == nil then
    names = JI.Names(qf.depot)
    NAMES[key] = names
  end
  local ok, label = pcall(function() return (names:label(ch)) end)
  if ok and label and label ~= "" and label ~= "?" then return label end
  local files = {}
  for _, c in ipairs(ch) do
    if c[1] ~= "" then files[#files + 1] = (V.basename(c[1]):gsub("%.journal", "")) end
  end
  return #files > 0 and files[#files] or "journal"
end
BL.journal = journal

local function base(qf, h, ext)
  if not truth(h) then return "" end
  local p = V.basename(qf:import_path(h) or "")
  if ext ~= "" then p = P.replace(p, ext, "") end
  return p
end

-- the node's lines for a block of a kind: what it does with which values (nil: the plain property list)
function BL.summary(qf, n, kind)
  local o = qf.tree:obj(n)
  local k = kind.id
  if kind.cls == W or kind.cls == I then
    local list = o.cls == W and or_(o:get("conditions"), {}) or {o:get("questCondition")}
    local out = {}
    for i = 1, (o.cls == W and #list or 1) do
      local x = list[i]
      if obj_ref(x) and #out < 3 then out[#out + 1] = BL.condition_text(qf, ival(x)) end
    end
    return #out > 0 and out or {"(nothing yet)"}
  end
  if k == "set_fact" then
    return {str(o:get("factID")) .. " " .. (truth(o:get("setExactValue")) and "= " or "+") .. str(o:get("value", 0))}
  end
  if k == "objective" or k == "journal" or k == "mappin" or k == "counter" or k == "track" then
    local e = or_(o:get("questEntry"), o:get("entry"), o:get("mappinEntry"), o:get("manualObjective"))
    return {journal(qf, e)}
  end
  if k == "scene" or k == "talk" or k == "context_talk" then
    local s = base(qf, o:get("scene"), ".w2scene")
    local line = {s ~= "" and s or "no scene"}
    if k == "talk" and truth(o:get("actorTags")) then line[#line + 1] = "with " .. qf:text(o:get("actorTags")) end
    return line
  end
  if k == "spawn" then
    local out = {}
    for _, s in ipairs(or_(o:get("spawnsets"), {})) do
      if obj_ref(s) then
        local so = qf.tree:obj(ival(s))
        local comm = base(qf, or_(so:get("spawnset"), so:get("community")), ".w2comm")
        if comm == "" then comm = "?" end
        if #out < 3 then
          out[#out + 1] = so.cls:find("Deactivate", 1, true) and (comm .. " gone") or
                          (comm .. ": " .. str(or_(so:get("phase"), "default")))
        end
      end
    end
    return #out > 0 and out or {"(none)"}
  end
  if k == "layers" then
    local out = {}
    for _, kw in ipairs({{"layersToShow", "show"}, {"layersToHide", "hide"}}) do
      local list = o:get(kw[1])
      if truth(list) then
        local names = {}
        for i, x in ipairs(list) do
          local s = P.replace(str(x), "/", "\\")
          names[i] = s:match("([^\\]*)$")
        end
        out[#out + 1] = kw[2] .. " " .. table.concat(names, ", ")
      end
    end
    return #out > 0 and out or {"(nothing)"}
  end
  if k == "teleport" then return {qf:text(o:get("actorsTags")) .. " to " .. qf:text(o:get("locationTag"))} end
  if k == "reward" then return {str(or_(o:get("rewardName"), "?"))} end
  if k == "ai" or k == "ai_stop" or k == "ai_poke" then
    local a = o:get("ai")
    local what
    if obj_ref(a) then
      what = P.replace(P.replace(BL.short_cls(qf.tree:obj(ival(a)).cls), "AI", ""), "Action", "")
    else
      what = k == "ai_poke" and str(o:get("pokeEvent")) or ""
    end
    return {str(or_(o:get("npcTag"), "PLAYER")) .. (what ~= "" and (": " .. what) or "")}
  end
  if k == "anim" then return {str(o:get("entityTag")) .. ": " .. str(o:get("animationName"))} end
  if k == "encounters" then
    return {str(o:get("encounterTag")) .. " " .. (truth(o:get("enableEncounter", true)) and "on" or "off")}
  end
  if k == "input" or k == "output" then
    local s = S.strip(str(or_(o:get("socketID"), "")))
    return {s ~= "" and s or "(the phase's own)"}
  end
  if k == "phase" then
    local ph, emb = o:get("phase"), o:get("embeddedGraph")
    if truth(ph) and (not V.isint(ph) or ival(ph) < 0) then return {base(qf, ph, "")} end
    if obj_ref(emb) then
      return {#(or_(qf.tree:obj(ival(emb)):get("graphBlocks"), {})) .. " blocks inside"}
    end
    return {}
  end
  if kind.cls == SCRIPT then                            -- a game function: its values
    local lines = {}
    for _, p in ipairs(or_(o:get("parameters"), {})) do
      if #lines < 3 then lines[#lines + 1] = str(V.sget(p, "name")) .. ": " .. qf:text(V.sget(p, "value")) end
    end
    return lines
  end
  return nil
end

return BL
