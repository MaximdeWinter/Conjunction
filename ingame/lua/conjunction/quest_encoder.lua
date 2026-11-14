-- Our own quest encoder (quest_encoder.py): the quest structure the generator writes (definition.quest\structure*.yml,
-- radish's format) into the quest file the game reads, through the lossless model (cr2w_tree.lua) - each block type as
-- radish wrote it, and the forms the build used to put back afterwards written at once (a script block's parameters
-- beside its arguments, the minigame blocks).
--   QE.encode(defdir, journals, ctx) -> the .w2quest bytes      journals {depot path = bytes}
--   QE.Ctx(quest id, dlc id, functions {name = {{param, type}}}, template bytes)
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local TR = require("conjunction.cr2w_tree")
local QE = {}
local Prop, Struct, Tags, Soft, Variant, Wide = TR.Prop, TR.Struct, TR.Tags, TR.Soft, TR.Variant, TR.Wide
local is = TR.is

QE.BLOCK, QE.CHILD, QE.PATH = 8192, 8200, 0
local BLOCK, CHILD, PATH = QE.BLOCK, QE.CHILD, QE.PATH
local CONN = "array:2,0,SCachedConnections"
QE.WORLDS = {velen = [[levels\novigrad\novigrad.w2w]], novigrad = [[levels\novigrad\novigrad.w2w]],
             skellige = [[levels\skellige\skellige.w2w]], kaer_morhen = [[levels\kaer_morhen\kaer_morhen.w2w]],
             kaermorhen = [[levels\kaer_morhen\kaer_morhen.w2w]], prologue = [[levels\prolog_village\prolog_village.w2w]],
             prologue_winter = [[levels\prolog_village_winter\prolog_village.w2w]],
             vizima = [[levels\wyzima_castle\wyzima_castle.w2w]], isle_of_mists = [[levels\island_of_mist\island_of_mist.w2w]],
             spiral = [[levels\the_spiral\spiral.w2w]], toussaint = [[dlc\bob\data\levels\bob\bob.w2w]],
             bob = [[dlc\bob\data\levels\bob\bob.w2w]]}
QE.WORLD_IDS = {novigrad = 1, skellige = 2, kaer_morhen = 3, kaermorhen = 3, prologue = 4, vizima = 5, isle_of_mists = 6,
                spiral = 7, prologue_winter = 8, velen = 9, toussaint = 11, bob = 11}
QE.COMPARE = {["="] = "CF_Equal", ["=="] = "CF_Equal", ["!="] = "CF_NotEqual", ["<"] = "CF_Less", ["<="] = "CF_LessEqual",
              [">"] = "CF_Greater", [">="] = "CF_GreaterEqual"}
QE.DEFAULT_PUT = {CQuestSceneBlock = "Input", CQuestInteractionDialogBlock = "Input", CJournalQuestBlock = "Activate",
                  CJournalBlock = "Activate", CQuestEndBlock = " ", CQuestPhaseOutputBlock = " ",
                  -- a map pin switch: Enable or Disable (q304's race; a link naming 'Disable' turns its pin off)
                  CJournalQuestMappinStateBlock = "Enable"}
QE.SCRIPT_TYPES = {int = "Int32", float = "Float", bool = "Bool", name = "CName", string = "String", Int32 = "Int32",
                   Float = "Float", Bool = "Bool", CName = "CName", String = "String"}
QE.TEMPLATE = [[quests\witcher3_quest.w2quest]]

local function S(v) return P.str(v) end

-- the game's groups of characters (journal_index) - kept here for a PC whose index is not built yet
local GROUPS = {e7d9397c31c37b44b409b4585da7c909 = [[gameplay\journal\characters\maincharacters.journal]],
                ["8efa62e10a415b499608256195453836"] = [[gameplay\journal\characters\sceondarycharacters.journal]],
                ["148cc843a5fe6a42982318bd508a6984"] = [[dlc\ep1\journal\characters\ep1.journal]],
                bf6b9116c6d19e449a5a7f6ba61a2677 = [[dlc\bob\journal\characters\ep2.journal]]}
local indexed = false

-- the game's journal file of a group of characters by its GUID (journal_index: the first link of a person's path),
-- nil when the index does not know it
function QE.character_group_file(guid_hex)
  local PYS = require("conjunction.pystr")
  guid_hex = PYS.lower(guid_hex)
  if GROUPS[guid_hex] == nil and not indexed then
    indexed = true
    local ok, idx = pcall(function() return require("conjunction.journal_index").load() end)
    for _, ent in ipairs(ok and idx and P.list(P.get(idx, "entries")) or {}) do
      local chain = P.list(P.get(ent, "chain"))
      if #chain > 0 and PYS.lower(S(chain[1][1])):find("journal\\characters\\", 1, true) then
        local key = PYS.lower(S(chain[1][2]))
        if GROUPS[key] == nil then GROUPS[key] = chain[1][1] end
      end
    end
  end
  return GROUPS[guid_hex]
end
local function err(msg) error(require("conjunction.questgen").ValueError(msg), 0) end
local function guid() return TR.new_guid() end
local function int(v) return require("conjunction.questgen").int(v) end

function QE.Ctx(quest, dlc, functions, template)
  return {quest = quest, dlc = dlc, functions = functions or {}, template = template}
end

-- a next list -> {{block name, input or nil}}
local function items(nxt)
  if nxt == nil or nxt == Y.null then return {} end
  if type(nxt) == "string" then nxt = {nxt} end
  local out = {}
  for _, x in ipairs(nxt) do
    if Y.is_map(x) then
      for k, v in pairs(x) do out[#out + 1] = {k, v ~= Y.null and v or nil} end
    elseif x ~= nil and x ~= Y.null then
      out[#out + 1] = {S(x), nil}
    end
  end
  return out
end

local Enc = {}
Enc.__index = Enc

function QE.Encoder(ctx, journals)
  local self = setmetatable({ctx = ctx, journals = journals, jcache = {}}, Enc)
  self.t = TR.Tree(ctx.template)
  self.t.objects = {}
  self.t.f.imports = {}
  return self
end

-- props: {{name, type, value}}
function Enc:add(cls, flags, parent, props)
  local list = {}
  for k, p in ipairs(props) do list[k] = Prop(p[1], p[2], p[3]) end
  return self.t:add(TR.Obj(cls, flags, parent, 0, list))
end

function Enc:imp(path, cls, flags)
  flags = flags or 4
  for k, im in ipairs(self.t.f.imports) do
    if im[1] == path and im[2] == cls then return k end
  end
  self.t.f.imports[#self.t.f.imports + 1] = {path, cls, flags}
  return #self.t.f.imports
end

local function journal_data(self, path)
  return self.journals[path] or self.journals[(path:gsub("/", "\\"))]
end

-- the quest's journal file: "quest" (its quest; a project's quest k: quest) or "group"
function Enc:journal_file(kind, quest)
  local name = kind == "quest" and (quest or self.ctx.quest) or ("questgroup_" .. self.ctx.quest)
  local path = "dlc/" .. self.ctx.dlc .. "/journal/quests/" .. name .. ".journal"
  if quest and kind == "quest" and not journal_data(self, path) then return self:journal_file(kind) end
  return path
end

-- {baseName = {guid, class, parent guid}} of a journal file
function Enc:journal_entries(path)
  if self.jcache[path] == nil then
    local data = journal_data(self, path)
    local entries = {}
    if data then
      local jt = TR.Tree(data)
      for _, o in ipairs(jt.objects) do
        local g = o.props and o:get("guid") or nil
        if is(g, TR.GUID) then
          local base = o:get("baseName")
          local key = (base ~= nil and base ~= "") and base or o.cls
          if entries[key] == nil then entries[key] = {g, o.cls, o:get("parentGuid")} end
          if entries["@" .. o.cls] == nil then entries["@" .. o.cls] = {g, o.cls, o:get("parentGuid")} end
        end
      end
    end
    self.jcache[path] = entries
  end
  return self.jcache[path]
end

-- CJournalPath objects (no parent): steps {{guid, resource path or nil}} -> the first one's number
function Enc:path_chain(steps)
  local first, prev
  for _, st in ipairs(steps) do
    local props = {{"guid", "CGUID", st[1]}}
    if st[2] then props[#props + 1] = {"resource", "soft:CResource", Soft(self:imp(st[2], "CJournalResource"))} end
    local n = self:add("CJournalPath", PATH, 0, props)
    if prev ~= nil then
      local o = self.t:obj(prev)
      o.props[#o.props + 1] = Prop("child", "handle:CJournalPath", n)
    end
    first = first or n
    prev = n
  end
  return first
end

local function split(ref)
  local parts = {}
  for p in (S(ref) .. "/"):gmatch("([^/]*)/") do parts[#parts + 1] = p end
  return parts
end

-- e.get(k, (_guid(),)) as Python has it: the GUID made whether the entry is there or not (the count stays the same)
local function entry_or_new(e, k)
  local fresh = {guid()}
  return (e[k] or fresh)[1]
end

-- 'quest/phase/objective' or 'quest' -> a CJournalPath chain
function Enc:objective_path(ref)
  local parts = split(ref)
  local jf = self:journal_file("quest", parts[1])
  local e = self:journal_entries(jf)
  local quest = entry_or_new(e, "@CJournalQuest")
  local steps = {{quest, jf}}
  if #parts >= 2 then steps[#steps + 1] = {entry_or_new(e, parts[2]), nil} end
  if #parts >= 3 then steps[#steps + 1] = {entry_or_new(e, parts[3]), nil} end
  return self:path_chain(steps)
end

-- an objective's map pin ('quest/phase/objective' and the pin's name as the quest names it) -> the chain: the quest
-- group, the quest, its phase, the objective, the pin (the journal's <quest>_<world>_<pin>_mp) - from the quest group
-- on, as the game's switches have it (q201)
function Enc:mappin_path(ref, pin)
  local parts = split(ref)
  local jf = self:journal_file("quest", parts[1])
  local e = self:journal_entries(jf)
  local gf = self:journal_file("group")
  local steps = {{entry_or_new(self:journal_entries(gf), "@CJournalQuestGroup"), gf},
                 {entry_or_new(e, "@CJournalQuest"), jf}}
  for k = 2, math.min(3, #parts) do steps[#steps + 1] = {entry_or_new(e, parts[k]), nil} end
  local mine
  local suffix = "_" .. S(pin) .. "_mp"
  for k, v in pairs(e) do
    if type(k) == "string" and #k >= #suffix and k:sub(-#suffix) == suffix then mine = v break end
  end
  steps[#steps + 1] = {(mine or {guid()})[1], nil}
  return self:path_chain(steps)
end

-- a person's journal page as the game's quests name one (journal_index: sceondarycharacters.journal|group >
-- anabelle.journal|person > |paragraph): the game's group (by the person's parentGuid), the person's file of the DLC,
-- the paragraph
function Enc:character_path(parts, root)
  local cf = "dlc/" .. self.ctx.dlc .. "/journal/characters/" .. parts[2] .. ".journal"
  local e = self:journal_entries(cf)
  local person = e["@CJournalCharacter"]
  local steps = {}
  if root and person and is(person[3], TR.GUID) then
    local hex = (person[3].b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    local gfile = QE.character_group_file(hex)
    if gfile then steps[#steps + 1] = {person[3], gfile} end
  end
  steps[#steps + 1] = {(person or {guid()})[1], cf}
  if #parts >= 3 then steps[#steps + 1] = {(e[parts[#parts]] or {guid()})[1], nil} end
  return self:path_chain(steps)
end

-- a journal block's entry 'quests/<quest>/<entry>' -> the chain (the quest group when the root is activated too, the
-- quest, its description group, the entry); 'characters/<person>/<entry>': the game's group of characters, the person,
-- the paragraph
function Enc:entry_path(ref, root)
  local parts = split(ref)
  if parts[1] == "characters" and #parts >= 2 then return self:character_path(parts, root) end
  local gf = self:journal_file("group")
  local jf = self:journal_file("quest", #parts >= 3 and parts[2] or nil)
  local g, e = self:journal_entries(gf), self:journal_entries(jf)
  local steps = {}
  if root then steps[1] = {entry_or_new(g, "@CJournalQuestGroup"), gf} end
  steps[#steps + 1] = {entry_or_new(e, "@CJournalQuest"), jf}
  if #parts >= 3 then
    local entry = e[parts[#parts]]
    local group = e["@CJournalQuestDescriptionGroup"]
    if group then steps[#steps + 1] = {group[1], nil} end
    steps[#steps + 1] = {(entry or {guid()})[1], nil}
  end
  return self:path_chain(steps)
end

function Enc:layer(name) return "DLC\\" .. self.ctx.dlc .. "\\" .. self.ctx.quest .. "\\" .. S(name) end
function Enc:world(name)
  local low = require("conjunction.pystr").lower(S(name))
  return QE.WORLDS[low] or S(name)
end
function Enc:area_tag(ref)
  local world, _, area = require("conjunction.questgen").partition(S(ref), "/")
  return self.ctx.quest .. "_" .. world .. "_" .. area .. "_ar"
end

-- a journal entry of the game's quests: its path copied from where a quest file names it -> the path's first object
function Enc:game_path(where, parent)
  local depot = require("conjunction.depot").open(require("conjunction.config").load().game)
  local src = TR.Tree(depot:read(where.file))
  local chain, seen, k = {}, {}, int(where.obj)
  while math.type(k) == "integer" and k > 0 and src:obj(k).cls == "CJournalPath" and not seen[k] do
    chain[#chain + 1] = k
    seen[k] = true
    k = src:obj(k):get("child")
  end
  if #chain == 0 then err("no journal path at " .. P.repr(where)) end
  return self.t:adopt_many(src, chain, parent)[1]
end

local function concat(a, b)
  local out = {}
  for _, x in ipairs(a) do out[#out + 1] = x end
  for _, x in ipairs(b) do out[#out + 1] = x end
  return out
end

-- one condition under a wait block -> its number
function Enc:condition(parent, spec, name)
  local props = name and {{"name", "CName", name}} or {}
  local has = function(k) return P.has(spec, k) end
  if has("factdb") then
    local fact, op, value = spec.factdb[1], spec.factdb[2], spec.factdb[3]
    return self:add("CQuestFactsDBCondition", CHILD, parent, concat(props, {
      {"factId", "String", S(fact)}, {"value", "Int32", int(value)}, {"compareFunc", "ECompareFunc", QE.COMPARE[S(op)] or "CF_Equal"}}))
  end
  if has("entered") then
    return self:add("CQuestEnterTriggerCondition", CHILD, parent, concat(props, {{"triggerTag", "CName", self:area_tag(spec.entered)}}))
  end
  if has("left") or has("outside") then
    local ref = P.or_(P.get(spec, "left"), P.get(spec, "outside"))
    return self:add("CQuestInsideTriggerCondition", CHILD, parent, concat(props, {
      {"triggerTag", "CName", self:area_tag(ref)}, {"isInside", "Bool", false}}))
  end
  if has("inside") then
    local more = {{"triggerTag", "CName", self:area_tag(spec.inside)}}
    if P.T(P.get(spec, "who")) then more[#more + 1] = {"tag", "CName", S(spec.who)} end
    return self:add("CQuestInsideTriggerCondition", CHILD, parent, concat(props, more))
  end
  if has("journal") then
    local more = {{"entry", "handle:CJournalPath", 0}, {"status", "EJournalStatus", S(P.or_(P.get(spec, "status"), "JS_Success"))}}
    if P.T(P.get(spec, "inverted")) then more[#more + 1] = {"inverted", "Bool", true} end
    local n = self:add("CQuestJournalStatusCondition", CHILD, parent, concat(props, more))
    self.t:obj(n):set("entry", self:game_path(spec.journal, n), "handle:CJournalPath")
    return n
  end
  if has("period") then
    local fr, to = spec.period[1], spec.period[2]
    return self:add("CQuestTimePeriodCondition", CHILD, parent, concat(props, {
      {"fromTime", "GameTime", Struct({Prop("m_seconds", "Int32", int(fr))})},
      {"toTime", "GameTime", Struct({Prop("m_seconds", "Int32", int(to))})}}))
  end
  if has("present") then
    local tags = Tags({})
    for _, t in ipairs(spec.present) do tags[#tags + 1] = S(t) end
    return self:add("CQuestTagsPresenceCondition", CHILD, parent, concat(props, {{"tags", "TagList", tags}}))
  end
  if has("actor") then                           -- a check of a person: the game's actor condition, the check in it
    local n = self:add("CQuestActorCondition", CHILD, parent, concat(props, {
      {"actorTag", "CName", S(spec.actor)}, {"checkType", "ptr:IActorConditionType", 0}}))
    local more = {}
    for _, x in ipairs(P.list(P.get(spec, "props"))) do more[#more + 1] = {x[1], x[2], x[3]} end
    local check = self:add(S(spec.check), CHILD, n, more)
    self.t:obj(n):set("checkType", check, "ptr:IActorConditionType")
    return n
  end
  if has("scripted") then                        -- a condition of the game's scripts by itself (W3QuestCond_...)
    local more = {}
    for _, x in ipairs(P.list(P.get(spec, "props"))) do more[#more + 1] = {x[1], x[2], x[3]} end
    return self:add(S(spec.scripted), CHILD, parent, concat(props, more))
  end
  if has("combat") then
    return self:add("CQuestInCombatCondition", CHILD, parent, concat(props, P.T(spec.combat) and {} or {{"isInCombat", "Bool", false}}))
  end
  for _, ko in ipairs({{"all", nil}, {"any", "LO_Or"}, {"nor", "LO_Nor"}}) do
    if has(ko[1]) then
      local more = ko[2] and {{"logicOperation", "ELogicOperation", ko[2]}} or {}
      more[#more + 1] = {"conditions", "array:2,0,ptr:IQuestCondition", TR.Array({})}
      local n = self:add("CQuestLogicOperationCondition", CHILD, parent, concat(props, more))
      local made = TR.Array({})
      for _, x in ipairs(spec[ko[1]]) do made[#made + 1] = self:condition(n, x) end
      self.t:obj(n):set("conditions", made)
      return n
    end
  end
  -- (the player used one of its interactions: `action` names it - a thing of the world's own, world_pick
  -- interaction_for - else the plain one of the kind)
  for _, k in ipairs({{"looted", "Loot"}, {"used", "use"}, {"examined", "examine"}}) do   -- (as radish wrote them)
    if has(k[1]) then
      local act = spec.action ~= nil and S(spec.action) or k[2]
      return self:add("CQuestInteractionCondition", CHILD, parent, concat(props, {
        {"interactionName", "String", act}, {"ownerTags", "TagList", Tags({(S(spec[k[1]]):gsub("^~+", ""))})}}))
    end
  end
  if has("elapsed") then
    local parts = {}
    for x in (S(spec.elapsed) .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = x end
    if #parts ~= 3 then err("not enough values to unpack: " .. S(spec.elapsed)) end
    return self:add("CQuestHiResRealtimeDelayCondition", CHILD, parent, concat(props, {
      {"hours", "Uint32", int(parts[1])}, {"minutes", "Uint32", int(parts[2])}, {"seconds", "Uint32", int(parts[3])}}))
  end
  err("a condition this encoder does not know: " .. P.repr(spec))
end

local function guess_type(value)
  if type(value) == "boolean" then return "Bool" end
  if math.type(value) == "integer" then return "Int32" end
  if math.type(value) == "float" then return "Float" end
  return "String"
end
local function typed(typ, value)
  if typ == "Int32" then return int(value) end
  if typ == "Float" then return require("conjunction.questgen").float(value) end
  if typ == "Bool" then return P.T(value) end
  if typ == "String" then
    local s = S(value)
    for _, c in utf8.codes(s) do if c >= 256 then return Wide(s) end end
    return s
  end
  return S(value)
end

function Enc:script(graph, named, conn, body)
  local fn = S(body["function"])
  local sig = {}
  for _, pt in ipairs(self.ctx.functions[fn] or {}) do sig[pt[1]] = pt[2] end
  local params, args = TR.Array({}), {}
  for _, it in ipairs(P.list(P.get(body, "parameter"))) do
    if Y.is_map(it) then
      for pname, value in pairs(it) do
        if value == Y.null then value = nil end
        local typ
        if type(value) == "string" and value:sub(1, 6) == "cname_" then
          typ, value = "CName", value:sub(7)
        elseif type(value) == "string" and value:sub(1, 5) == "enum:" then
          local _e, t, v = value:match("^([^:]*):([^:]*):(.*)$")
          typ, value = t, v
        else
          typ = QE.SCRIPT_TYPES[sig[pname]] or guess_type(value)
        end
        local v = typed(typ, value)
        params[#params + 1] = Struct({Prop("name", "CName", S(pname)), Prop("value", "CVariant", Variant(typ, v))})
        args[#args + 1] = Prop(S(pname), typ, v)
      end
    end
  end
  local n = self:add("CQuestScriptBlock", BLOCK, graph, concat(concat(named, {{"guid", "CGUID", guid()}}), concat(conn, {
    {"functionName", "CName", fn}, {"parameters", "array:2,0,QuestScriptParam", params}})))
  self.t:obj(n).args = args
  return n
end

function Enc:block(graph, name, body)
  local kind, _, short = require("conjunction.questgen").partition(name, ".")
  body = (body ~= nil and body ~= Y.null) and body or Y.map()
  local named = short ~= "" and {{"name", "String", short}} or {}
  local conn = {{"cachedConnections", CONN, TR.Array({})}}
  local function base(more)
    return concat(concat(named, {{"guid", "CGUID", guid()}}), concat(conn, more or {}))
  end
  if kind == "start" then return self:add("CQuestStartBlock", BLOCK, graph, concat({{"guid", "CGUID", guid()}}, conn)) end
  if kind == "end" then return self:add("CQuestEndBlock", BLOCK, graph, {{"guid", "CGUID", guid()}}) end
  if kind == "waituntil" then
    local n = self:add("CQuestPauseConditionBlock", BLOCK, graph, base({{"conditions", "array:2,0,ptr:IQuestCondition", TR.Array({})}}))
    local conds = P.get(body, "conditions")
    local made = TR.Array({})
    if P.T(conds) then
      for k, v in pairs(conds) do made[#made + 1] = self:condition(n, v, S(k)) end
    else
      made[1] = self:condition(n, body)
    end
    self.t:obj(n):set("conditions", made)
    return n
  end
  if kind == "objective" or kind == "questoutcome" then
    local ref = P.or_(P.get(body, "objective"), P.get(body, "quest"))
    local path = self:objective_path(kind == "objective" and ref or split(ref)[1])
    local props = base({{"questEntry", "handle:CJournalPath", path}, {"showInfoOnScreen", "Bool", true}})
    if kind == "objective" then props[#props + 1] = {"track", "Bool", P.T(P.get(body, "track"))} end
    return self:add("CJournalQuestBlock", BLOCK, graph, props)
  end
  if kind == "journal" then
    local g = guid()
    local entry = self:entry_path(require("conjunction.questgen").need(body, "entry"), P.T(P.get(body, "activate_root")))
    return self:add("CJournalBlock", BLOCK, graph, concat(concat(named, {{"guid", "CGUID", g}}), concat(conn, {
      {"entry", "handle:CJournalPath", entry}, {"showInfoOnScreen", "Bool", true}})))
  end
  if kind == "addfact" and P.T(P.get(body, "mappin")) and P.T(P.get(body, "objective")) then
    -- one map pin of an objective on, its others off (the game's 'Map pin' block)
    local g = guid()                               -- (the block's GUID before its path's, as the app takes them)
    local props = concat(concat(named, {{"guid", "CGUID", g}}), concat(conn, {
      {"mappinEntry", "handle:CJournalPath", self:mappin_path(body.objective, body.mappin)}}))
    if P.T(P.get(body, "only")) then props[#props + 1] = {"disableAllOtherMapPins", "Bool", true} end
    return self:add("CJournalQuestMappinStateBlock", BLOCK, graph, props)
  end
  if kind == "addfact" then
    local v = require("conjunction.questgen").need(body, "value")
    return self:add("CQuestFactsDBChangingBlock", BLOCK, graph, base({{"factID", "String", S(v[1])}, {"value", "Int32", int(v[2])}}))
  end
  if kind == "script" then return self:script(graph, named, conn, body) end
  if kind == "interaction" then
    local tags = Tags({})
    for _, a in ipairs(P.list(P.get(body, "actor"))) do tags[#tags + 1] = S(a) end
    local g = guid()
    return self:add("CQuestInteractionDialogBlock", BLOCK, graph, concat(concat(named, {{"guid", "CGUID", g}}), concat(conn, {
      {"scene", "soft:CStoryScene", Soft(self:imp(body.scene, "CStoryScene"))}, {"actorTags", "TagList", tags},
      {"interrupt", "Bool", true}})))
  end
  if kind == "scene" then
    local g = guid()
    return self:add("CQuestSceneBlock", BLOCK, graph, concat(concat(named, {{"guid", "CGUID", g}}), concat(conn, {
      {"scene", "soft:CStoryScene", Soft(self:imp(body.scene, "CStoryScene"))}, {"interrupt", "Bool", true},
      {"shouldFadeOnLoading", "Bool", false}})))
  end
  if kind == "changelayers" then
    local props = base()
    if P.T(P.get(body, "world")) then props[#props + 1] = {"world", "String", self:world(body.world)} end
    if P.T(P.get(body, "show")) then
      local l = TR.Array({})
      for _, x in ipairs(body.show) do l[#l + 1] = self:layer(x) end
      props[#props + 1] = {"layersToShow", "array:2,0,String", l}
    end
    if P.T(P.get(body, "hide")) then
      local l = TR.Array({})
      for _, x in ipairs(body.hide) do l[#l + 1] = self:layer(x) end
      props[#props + 1] = {"layersToHide", "array:2,0,String", l}
    end
    return self:add("CQuestLayersHiderBlock", BLOCK, graph, props)
  end
  if kind == "spawn" or kind == "despawn" then
    local n = self:add("CQuestStoryPhaseSetterBlock", BLOCK, graph, base({{"spawnsets", "array:2,0,ptr:IQuestSpawnsetAction", TR.Array({})}}))
    local made = TR.Array({})
    for _, s in ipairs(P.list(P.get(body, "spawnsets"))) do
      local comm = "dlc/" .. self.ctx.dlc .. "/data/spawnsets/" .. S(s) .. ".w2comm"
      if kind == "spawn" then
        made[#made + 1] = self:add("CActivateStoryPhase", CHILD, n, {
          {"spawnset", "soft:CCommunity", Soft(self:imp(comm, "CCommunity"))},
          {"phase", "CName", self.ctx.quest .. "_" .. S(s) .. "_" .. S(P.get(body, "phase", "main")) .. "_ph"}})
      else
        -- people gone as the game's quests make them go: their community to a phase it has no entry for (q105
        -- "dspn anna witches") - a deactivated spawnset left them standing
        made[#made + 1] = self:add("CActivateStoryPhase", CHILD, n, {
          {"spawnset", "soft:CCommunity", Soft(self:imp(comm, "CCommunity"))},
          {"phase", "CName", self.ctx.quest .. "_" .. S(s) .. "_gone_ph"}})
      end
    end
    self.t:obj(n):set("spawnsets", made)
    return n
  end
  if kind == "reward" then
    return self:add("CQuestRewardBlock", BLOCK, graph, base({{"rewardName", "CName", self.ctx.quest .. "_" .. S(body.reward)}}))
  end
  if kind == "randomize" then
    -- its outputs by name: the game draws one of randomOutputs and activates that output - without the list it reads
    -- an empty array and the game crashes when the block comes
    local outs = TR.Array({})
    for _, k in ipairs(Y.keys(body)) do if k:sub(1, 5) == "next." then outs[#outs + 1] = k:sub(6) end end
    return self:add("CQuestRandomBlock", BLOCK, graph, base({{"randomOutputs", "array:2,0,CName", outs}}))
  end
  if kind == "changeworld" then
    local world, _, wp = require("conjunction.questgen").partition(S(body.destination), "/")
    local key = require("conjunction.pystr").lower(world)
    if not QE.WORLD_IDS[key] then err("travel into a world the game does not know: " .. world) end
    return self:add("CQuestChangeWorldBlock", BLOCK, graph, base({
      {"worldFilePath", "String", self:world(world)}, {"newWorld", "Int32", QE.WORLD_IDS[key]},
      {"targetTag", "TagList", Tags({self.ctx.quest .. "_" .. world .. "_" .. wp .. "_wp"})}}))
  end
  err("a block this encoder does not know: " .. name)
end

local function default_out(cls)
  if cls == "CQuestPauseConditionBlock" then return nil end
  if cls == "CQuestStartBlock" or cls == "CQuestPhaseInputBlock" then return " " end
  return "Out"
end

-- the block's next lists into its cachedConnections
function Enc:link(graph_blocks, _name, body, n)
  local o = self.t:obj(n)
  local conns = TR.Array({})
  for key, nxt in pairs((body ~= nil and body ~= Y.null) and body or Y.map()) do
    if key == "next" or key:sub(1, 5) == "next." then
      local socket = key:sub(1, 5) == "next." and key:sub(6) or default_out(o.cls)
      local blocks = TR.Array({})
      for _, tp in ipairs(items(nxt)) do
        local target, put = tp[1], tp[2]
        if target:sub(1, 1) ~= "." then
          local to = graph_blocks[target]
          if to ~= nil then
            local cls = self.t:obj(to).cls
            blocks[#blocks + 1] = Struct({Prop("ock", "ptr:CQuestGraphBlock", to),
                                          Prop("putName", "CName", put ~= nil and S(put) or (QE.DEFAULT_PUT[cls] or "In"))})
          end
        end
      end
      if #blocks > 0 then
        local st = Struct({})
        if socket ~= nil then st[#st + 1] = Prop("socketId", "CName", socket) end
        st[#st + 1] = Prop("blocks", "array:2,0,SBlockDesc", blocks)
        conns[#conns + 1] = st
      end
    end
  end
  if #conns > 0 then
    o:set("cachedConnections", conns)
  else
    local keep = {}
    for _, p in ipairs(o.props) do if p.name ~= "cachedConnections" then keep[#keep + 1] = p end end
    o.props = keep
  end
end

function Enc:encode(structure)
  local quest = self:add("CQuest", BLOCK, 0, {{"graph", "ptr:CQuestGraph", 0}})
  local graph = self:add("CQuestGraph", BLOCK, quest, {{"graphBlocks", "array:2,0,ptr:CGraphBlock", TR.Array({})},
                                                        {"sourceDataRemoved", "Bool", true}})
  self.t:obj(quest):set("graph", graph)
  local blocks, bodies, order = {}, {}, {}
  for _, seg in pairs(P.get(structure, "structure") or Y.map()) do
    for name, body in pairs(P.get(seg or Y.map(), "blocks") or Y.map()) do
      if blocks[name] == nil then order[#order + 1] = name end
      blocks[name] = self:block(graph, name, body)
      bodies[name] = body
    end
  end
  for _, name in ipairs(order) do self:link(blocks, name, bodies[name], blocks[name]) end
  local list = TR.Array({})
  for _, name in ipairs(order) do list[#list + 1] = blocks[name] end
  self.t:obj(graph):set("graphBlocks", list)
  return self.t:to_bytes()
end

-- {quest function name = {{param, type}}} from the scripts under the roots (game_catalog.parse_scripts' functions)
local FUNC
function QE.script_functions(roots)
  local R = require("conjunction.pyre")
  local WS = require("conjunction.w3strings")
  FUNC = FUNC or R.compile([[^\s*(latent\s+)?quest\s+function\s+(\w+)\s*\(([^)]*)\)\s*(?::\s*([\w<>]+))?]], R.M)
  local PARAM = R.compile([[((?:optional|out|inout)\s+)*(\w+)\s*:\s*(.+)$]])
  local out = {}
  local function files(dir, acc)
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local p = dir .. "\\" .. e.name
      if e.dir then files(p, acc) elseif e.name:lower():match("%.ws$") then acc[#acc + 1] = p end
    end
    return acc
  end
  local since = os.clock()
  for _, root in ipairs(roots) do
    if w3.fs.isdir(root) then
      local funcs = {}
      for _, path in ipairs(files(root, {})) do
        if os.clock() - since > 0.015 and coroutine.isyieldable() then   -- (in a build's job: the game's frame
          coroutine.yield()                                              -- between the files - 22.10., 8 s hang)
          since = os.clock()
        end
        local raw = w3.fs.read(path)
        if raw and raw:find("quest%s+function") then
          local text = WS.decode_replace(raw):gsub("\r\n", "\n"):gsub("\r", "\n")
          for _, m in ipairs(FUNC:findall(text)) do
            local params = {}
            for part in (m[3] .. ","):gmatch("([^,]*),") do
              local p = require("conjunction.pystr").strip(part)
              if p ~= "" then
                local pm = PARAM:match(p)
                if pm then params[#params + 1] = {pm:group(2), require("conjunction.pystr").strip(pm:group(3))} end
              end
            end
            funcs[m[2]] = params
          end
        end
      end
      for name, ps in pairs(funcs) do out[name] = ps end
    end
  end
  return out
end

-- the quest file of a definition: its structure encoded, then the stand-ins (gwent, fist fights, stopped lanes)
-- made the game's blocks
function QE.encode(defdir, journals, ctx)
  local structure = Y.map({"structure", Y.map()})
  local names = {}
  for _, e in ipairs(w3.fs.list(defdir) or {}) do
    if not e.dir and e.name:match("^structure.*%.yml$") then names[#names + 1] = e.name end
  end
  table.sort(names)
  for _, f in ipairs(names) do
    local d = Y.read(defdir .. "\\" .. f) or Y.map()
    for k, v in pairs(P.get(d, "structure") or Y.map()) do structure.structure[k] = v end
  end
  local data = QE.Encoder(ctx, journals):encode(structure)
  local spec_file = defdir:gsub("[\\/][^\\/]*$", "") .. "\\definition.minigames.yml"
  if w3.fs.exists(spec_file) then
    local spec = Y.read(spec_file) or Y.map()
    local games = Y.map()
    for k, v in pairs(spec) do if P.get(v, "game") ~= "path" then games[k] = v end end
    data = require("conjunction.cr2w_edit").apply_data(data, games)
  end
  return data
end

return QE
