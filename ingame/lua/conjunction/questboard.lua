-- questboard.py without its widgets: the step kinds the Quest tab offers (goals, actions, their groups), what a step
-- still needs (missing), a branch's colour. The tab itself: ui/quest_board.lua.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local QB = {}

-- goals: what the player does (the objective waits for it) - {kind, label, its field}
QB.GOALS = {{"talk", "Talk", "npc"}, {"goto", "Go to", "place"}, {"loot", "Loot", "object"},
  {"examine", "Examine", "object"}, {"use", "Use", "object"}, {"kill", "Kill", "target"},
  {"defeat", "Defeat", "target"}, {"gwent", "Gwent", "deck"}, {"fistfight", "Fist fight", "targets"},
  {"deliver", "Deliver", "npc"}, {"read", "Read", "item"}, {"notice", "Notice", "board"},
  {"collect", "Collect", "item"}, {"equip", "Equip", "item"}, {"clues", "Find clues", "clues"},
  {"follow", "Follow", "who"}, {"wait", "Wait", "time"}, {"waitfact", "Wait until", "fact"},
  {"waitfor", "Wait for", "what"}, {"race", "Race", "path"}, {"either", "Either / or", "options"},
  {"all", "All of these", "options"}}
-- actions: what happens (no objective of their own)
QB.ACTIONS = {{"say", "Says", "text"}, {"show", "Show place", "place"}, {"hide", "Hide place", "place"},
  {"reward", "Reward", "reward"}, {"item", "Item", "item"}, {"note", "Journal note", "text"},
  {"hostile", "Hostile", "target"}, {"immortal", "Immortal", "target"}, {"door", "Door", "target"},
  {"switch", "Switch", "target"}, {"lock", "Lock", "target"},
  {"effect", "Effect", "target"}, {"sound", "Sound", "event"}, {"fade", "Fade", "fade"},
  {"shake", "Camera shake", "strength"}, {"weather", "Weather", "weather"}, {"time", "Time of day", "at"},
  {"teleport", "Teleport", "pos"}, {"travel", "Travel", "pos"}, {"playas", "Play as", "as"},
  {"portal", "Portal", "a"}, {"lights", "Lights", "target"}, {"presence", "Hide object", "target"},
  {"encounters", "Creatures nearby", "pos"},
  {"message", "Message", "text"}, {"autosave", "Autosave", "none"},
  {"person", "Journal entry", "who"}, {"walk", "Walk to", "who"}, {"patrol", "Patrol", "who"},
  {"stands", "Stands", "who"}, {"meanwhile", "Parallel track", "path"}, {"stop", "Stop track", "path"},
  {"random", "At random", "ways"},
  {"tutorial", "Tutorial", "text"}, {"game", "Game function", "function"},
  {"fact", "Set fact", "fact"}, {"worldchange", "Change world", "change"},
  {"goaway", "Goes away", "who"}, {"health", "Health", "who"}, {"target", "Attacks", "who"},
  {"notalk", "No talking", "who"}, {"look", "Change look", "who"}, {"shop", "Merchant", "who"},
  {"bossbar", "Boss health bar", "who"}, {"weapon", "Draw weapon", "weapon"},
  {"controls", "Block controls", "what"}, {"timelapse", "Time passes", "text"},
  {"highlight", "Highlight", "target"}, {"forget", "Forget fact", "name"},
  {"state", "Person's state", "who"}, {"containers", "Containers", "target"},
  {"questitem", "Quest item off", "item"}, {"mappin", "Map pin", "target"},
  {"clue", "Clue (senses)", "target"}, {"part", "Part on/off", "target"}, {"thinglook", "Look of a thing", "target"},
  {"thinganim", "Move a thing", "target"}}
QB.WAIT_FOR = {{"combat", "a fight starts"}, {"peace", "the fight is over"}, {"senses", "the witcher senses"},
               {"health", "the player's health is down to"}}
QB.WEATHERS = {"WT_Clear", "WT_Light_Clouds", "WT_Mid_Clouds", "WT_Mid_Clouds_Dark", "WT_Heavy_Clouds",
               "WT_Heavy_Clouds_Dark", "WT_Rain_Storm", "WT_Fog", "WT_Snow", "WT_Blizzard", "WT_Wild_Hunt"}
QB.GOAL_GROUPS = {{"People", {"talk", "deliver", "follow"}}, {"Places", {"goto", "wait", "waitfact", "waitfor"}},
  {"Things", {"loot", "examine", "use", "collect", "equip", "read", "notice", "clues"}},
  {"Fights and games", {"kill", "defeat", "fistfight", "gwent", "race"}}, {"Combined", {"all"}}}
QB.ACTION_GROUPS = {
  {"Player", {"say", "reward", "item", "teleport", "travel", "playas", "portal", "weapon", "controls", "questitem"}},
  {"People", {"hostile", "immortal", "walk", "stands", "patrol", "person", "presence", "goaway",
              "health", "target", "notalk", "look", "shop", "bossbar", "state"}},
  {"World", {"show", "hide", "door", "lock", "switch", "lights", "effect", "clue", "part", "thinglook", "thinganim", "sound",
             "encounters", "worldchange", "highlight", "containers", "mappin"}},
  {"Mood", {"fade", "shake", "weather", "time"}},
  {"Screen", {"note", "message", "tutorial", "autosave", "timelapse"}},
  {"Advanced", {"random", "meanwhile", "stop", "fact", "forget", "game"}}}
QB.GOAL_KINDS = {}                                  -- (deliver makes a talk)
for _, g in ipairs(QB.GOALS) do if g[1] ~= "deliver" then QB.GOAL_KINDS[g[1]] = true end end
QB.LABEL = {}
for _, g in ipairs(QB.GOALS) do QB.LABEL[g[1]] = g[2] end
for _, g in ipairs(QB.ACTIONS) do QB.LABEL[g[1]] = g[2] end
QB.PERSON_ACTIONS = {"goaway", "health", "target", "notalk", "look", "shop", "bossbar", "state"}
QB.EITHER_KINDS = {{"goto", "Go to"}, {"loot", "Loot"}, {"examine", "Examine"}, {"use", "Use"}, {"kill", "Kill"}}
QB.QUEST_TYPES = {{"main", "Main quest"}, {"secondary", "Side quest"}, {"monsterhunt", "Contract"},
                  {"treasurehunt", "Treasure hunt"}}
QB.TALK_STARTS = {{"interact", "On interaction (E)"}, {"near", "When the player is near"},
                  {"overhear", "Overheard (the player listens)"},
                  {"calls", "NPC calls out"}, {"now", "Immediately (cutscene)"}}
QB.QUEST_STARTS = {{"at_once", "Immediately"}, {"after_first", "After step 1"}}
QB.IMMORTAL = {{"immortal", "Immortal"}, {"unconscious", "Knocked out, not killed"}, {"off", "Mortal"}}
QB.DOOR = {{"open", "opens"}, {"close", "closes"}, {"lock", "locks"}, {"unlock", "unlocks"}}
QB.SWITCH = {{"on", "on"}, {"off", "off"}, {"lock", "locked"}, {"unlock", "unlocked"}}
QB.LIGHTS = {{"on", "on"}, {"off", "off"}}
QB.THING_ANIM = {{"once", "once"}, {"back", "back"}, {"loop", "again and again"}, {"stop", "stop"}}
QB.PRESENCE = {{"hide", "hidden"}, {"show", "shown again"}}
QB.ENCOUNTERS = {{"off", "off"}, {"on", "back on"}}
QB.WORLDCHANGE = {{"on", "from here on"}, {"off", "ends here"}}
QB.FADE_COLORS = {{"black", "black"}, {"white", "white"}}
-- actions on one placed thing or person: what the card misses while it is empty
QB.TARGET_ACTIONS = {hostile = "character", immortal = "character", presence = "object", door = "object",
                     switch = "object", lights = "object", lock = "object", effect = "object", clue = "object",
                     part = "object", thinglook = "object", thinganim = "object"}
QB.CIRI_LOOKS = {{"", "Default"}, {"wounded", "wounded"}, {"winter", "winter clothes"}, {"naked", "naked"}}
QB.USE_HOW = {{"", "used"}, {"on", "switched on"}, {"off", "switched off"}, {"item", "item used on it"}}
QB.CARD_MENU = {{"test", "Play from here"}, {"copy", "Duplicate"}, {"clip", "Copy (Ctrl+C)"},
                {"paste", "Paste after this (Ctrl+V)"}, {"remove", "Remove"}}
-- a step's menu: a talk or a scene can be kept as a template too
function QB.card_menu_of(step)
  local kind = QB.step_kind(step)
  if kind ~= "talk" then return QB.CARD_MENU end
  local out = {}
  for _, e in ipairs(QB.CARD_MENU) do
    if e[1] == "remove" then out[#out + 1] = {"template", "Save as template"} end
    out[#out + 1] = e
  end
  return out
end
QB.PATH_ENDS = {{"join", "Rejoin story"}, {"success", "End quest: success"}, {"fail", "End quest: failure"}}
QB.UNDONE = {"quest", "swaps", "cutscene_swaps"}
QB.PATH_COLORS = {"#e0915f", "#8fa3e8", "#d9a45b", "#aebd5f", "#cdb28a", "#c98f86", "#7fb3c2", "#b0a8d8"}
QB.MISSING_RED = "#e57a7a"

-- (kind, args) of a step {kind: args}; args that are no dict become one (in the step)
function QB.step_kind(step)
  local kind = Y.keys(step)[1]
  local args = step[kind]
  if not Y.is_map(args) then
    args = Y.map()
    step[kind] = args
  end
  return kind, args
end

-- the label of a pair list's key ({{key, label}} - Python's dict(pairs).get(key))
function QB.label_in(pairs_, key, default)
  for _, p in ipairs(pairs_) do if p[1] == key then return p[2] end end
  return default
end

-- the paths a step leads into, in order
function QB.forks(step)
  local kind, a = QB.step_kind(step)
  local out = {}
  local function add(p) if not P.contains(out, p) then out[#out + 1] = p end end
  if kind == "talk" then
    local D = require("conjunction.dialogue")
    for _, x in ipairs(D.walk(D.from_step(a))) do
      local e = P.str(P.get(x, "end", ""))
      if not P.has(x, "who") and P.startswith(e, "path:") then add(e:sub(6)) end
    end
  elseif kind == "either" then
    for _, o in ipairs(P.list(P.get(a, "options"))) do
      if P.T(P.get(o, "path")) then add(o.path) end
    end
  elseif kind == "meanwhile" and P.T(P.get(a, "path")) then
    out[#out + 1] = a.path
  elseif kind == "random" then
    for _, w in ipairs(P.list(P.get(a, "ways"))) do
      if P.T(P.get(w, "path")) then add(w.path) end
    end
  elseif (kind == "gwent" or kind == "fistfight") and P.startswith(P.str(P.get(a, "lost", "")), "path:") then
    out[#out + 1] = a.lost:sub(6)
  end
  return out
end

local function any_true(list)
  for _, v in ipairs(P.iter(P.list(list))) do if P.T(v) then return true end end
  return false
end

-- what a step still needs before it can be built (nouns: the card shows them)
function QB.missing(kind, a)
  local out = {}
  local function add(s) out[#out + 1] = s end
  local g = function(k) return P.get(a, k) end
  local T = P.T
  if kind == "goal" or kind == "action" or kind == "choice" or kind == "parallel" then return {"step type"} end
  if kind == "if" and not (T(g("path")) or T(g("fact")) or T(g("conditions"))) then add("condition") end
  if (kind == "talk" or kind == "defeat") and not T(g(kind == "talk" and "npc" or "target")) then add("character") end
  if (kind == "loot" or kind == "examine" or kind == "use") and not T(g("object")) then add("object") end
  if kind == "kill" and not (any_true(g("targets")) or T(g("target"))) then add("character") end
  if kind == "goto" and (g("mode") == "near" or g("mode") == "look") then
    if not T(g("who")) then add("character") end
  elseif kind == "goto" and not (T(g("place")) or T(g("pos")) or T(g("at"))) then
    add("location")
  end
  if kind == "say" and P.has(a, "who") and not T(g("who")) then add("character") end
  if kind == "follow" and not T(g("who")) then add("character") end
  if kind == "portal" and not T(g("a")) then add("portal object") end
  if kind == "portal" and not T(g("b_exit")) then add("destination") end
  if kind == "portal" and T(g("two_way")) and not (T(g("b")) and T(g("a_exit"))) then add("way back") end
  if kind == "travel" and not T(g("pos")) then add("destination") end
  if QB.TARGET_ACTIONS[kind] and not T(g("target")) then add(QB.TARGET_ACTIONS[kind]) end
  if kind == "encounters" and not T(g("pos")) then add("location") end
  if kind == "playas" and not T(g("as")) then add("character") end
  if kind == "gwent" and not T(g("deck")) then add("deck") end
  if kind == "race" then
    local n = 0
    for _, p in ipairs(P.iter(P.list(g("path")))) do if T(p) then n = n + 1 end end
    if n < 2 then add("course") end
  end
  if kind == "race" and not any_true(g("racers")) then add("racers") end
  if kind == "fistfight" and not any_true(g("targets")) then add("opponent") end
  if (kind == "meanwhile" or kind == "stop") and not T(g("path")) then add("track") end
  if kind == "stands" and not T(g("who")) then add("character") end
  if kind == "stands" and not T(g("pos")) then add("location") end
  if kind == "waitfact" and not T(g("fact")) and not T(g("conditions")) then add("fact") end
  if kind == "game" then
    local GF = require("conjunction.game_functions")
    local fn = g("function")
    if not T(fn) then
      add("function")
    elseif GF.functions()[fn] ~= nil then
      local args = P.or_(g("args"), Y.map())
      for _, prm in ipairs(GF.functions()[fn].params) do
        local n, t, o = prm[1], prm[2], prm[3]
        local k = GF.kind(t)
        if not o and (k == "name" or k == "string") and not T(P.get(args, n)) then add(n) end
      end
    end
  end
  if kind == "follow" and not T(g("path")) then add("route") end
  if (kind == "collect" or kind == "read" or kind == "equip") and not T(g("item")) then add("item") end
  if kind == "notice" and not T(g("board")) then add("notice board") end
  if kind == "collect" and T(g("item")) and not T(g("from")) then add("item source") end
  if kind == "collect" and T(g("item")) and (g("from") == "container" or g("from") == "person") and
      not T(g("in")) then
    add(a.from == "container" and "container" or "carrier")
  end
  if kind == "clues" then
    local any = false
    for _, c in ipairs(P.list(g("clues"))) do
      if T(P.get(c, "object")) or T(P.get(c, "trail")) then any = true end
    end
    if not any then add("clues") end
  end
  if kind == "talk" then
    local D = require("conjunction.dialogue")
    for _, x in ipairs(D.walk(D.from_step(a))) do
      local give = P.or_(P.get(x, "give"), Y.map())
      if P.get(give, "item") == "" then
        add("item to hand over")
        break
      end
    end
  end
  if kind == "talk" and g("start") == "overhear" then
    local D = require("conjunction.dialogue")
    for _, x in ipairs(D.from_step(a)) do
      if P.has(x, "choice") then
        add("lines only, no choices")
        break
      end
    end
  end
  if kind == "either" or kind == "all" then
    for _, o in ipairs(P.list(g("options"))) do
      local gk, ga = QB.step_kind(P.or_(P.get(o, "goal"), Y.map({"goto", Y.map()})))
      local m = QB.missing(gk, ga)
      if #m > 0 then
        add("option " .. m[1])
        break
      end
    end
  end
  return out
end

function QB.path_color(pid)
  return QB.PATH_COLORS[P.crc32(pid) % #QB.PATH_COLORS + 1]
end

return QB
