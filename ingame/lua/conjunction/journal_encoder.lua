-- Our own journal encoder (journal_encoder.py): journals.yml (radish's format, the generator writes it) into the
-- journal files the game reads - the quest group, the quest with its phases, objectives, map pins and descriptions -
-- and the texts with their string ids, as radish wrote them.
--   JE.encode(journals, ctx) -> files (Y.map {journal depot path = bytes}), strings {{string id, key, text}}
--   JE.Ctx(quest id, dlc, id space, first id, template bytes)
-- String ids: the id space's range from the first id on, in the order: the group's title, the objectives (file
-- order), the descriptions (name order), the quest's title.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local TR = require("conjunction.cr2w_tree")
local GEN = require("conjunction.questgen")
local JE = {}

JE.FLAGS = 8192
JE.TYPES = {SideQuest = "Side", MainQuest = "Chapter", MonsterHunt = "MonsterHunt", TreasureHunt = "TreasureHunt",
            Side = "Side", Chapter = "Chapter"}
JE.WORLD = {novigrad = 1, skellige = 2, kaer_morhen = 3, kaermorhen = 3, prologue = 4, vizima = 5, isle_of_mists = 6,
            spiral = 7, prologue_winter = 8, velen = 9, toussaint = 11, bob = 11}
local S = P.str
local CHILDREN = "array:2,0,ptr:CJournalContainerEntry"

-- pins_off: map pins a switch turns on - off at the objective's start
function JE.Ctx(quest, dlc, idspace, first, template, pins_off)
  local off = {}
  for _, p in ipairs(pins_off or {}) do off[p] = true end
  return {quest = quest, dlc = dlc, idspace = GEN.int(idspace), first = GEN.int(first or 0), template = template,
          pins_off = off}
end

-- str(uuid.UUID(bytes_le=g))
function JE.uuid(g)
  local b = g.b
  local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
  return hex(b:sub(1, 4):reverse()) .. "-" .. hex(b:sub(5, 6):reverse()) .. "-" .. hex(b:sub(7, 8):reverse()) .. "-" ..
         hex(b:sub(9, 10)) .. "-" .. hex(b:sub(11, 16))
end

-- q.get(k, default) as Python has it (a null is None, str() of it "None")
local function raw(d, k, default)
  if type(d) ~= "table" or d == Y.null then return default end
  local v = d[k]
  if v == nil then return default end
  return v
end
local function items(d)                         -- d.items() of a mapping, nothing for anything else
  local out = {}
  if Y.is_map(d) then for k, v in pairs(d) do out[#out + 1] = {k, v} end end
  return out
end
local function by_name(list)                    -- sorted(list, key=lambda x: x[1]) (stable)
  for i, x in ipairs(list) do x.at = i end
  table.sort(list, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a.at < b.at
  end)
  return list
end

local Enc = {}
Enc.__index = Enc

function JE.Encoder(ctx)
  return setmetatable({ctx = ctx, next_id = ctx.first, strings = {}}, Enc)
end

function Enc:text(s, key)
  local sid = 2110000000 + self.ctx.idspace * 1000 + self.next_id
  self.next_id = self.next_id + 1
  self.strings[#self.strings + 1] = {sid, key or "", S(s)}
  return TR.Loc(sid)
end

function Enc:tree()
  local t = TR.Tree(self.ctx.template)
  t.objects, t.f.imports, t.f.buffers = {}, {}, {}
  return t
end

local function add(t, cls, parent, props)
  local list = {}
  for k, p in ipairs(props) do list[k] = TR.Prop(p[1], p[2], p[3]) end
  t.objects[#t.objects + 1] = TR.Obj(cls, JE.FLAGS, parent, 0, list)
  return #t.objects
end

function Enc:group()
  local t = self:tree()
  local g = TR.new_guid()
  local res = add(t, "CJournalResource", 0, {{"entry", "ptr:CJournalBase", 2}})
  local name = "questgroup_" .. S(self.ctx.quest)
  add(t, "CJournalQuestGroup", res, {
    {"guid", "CGUID", g}, {"baseName", "String", name},
    {"uniqueScriptIdentifier", "CName", name .. "_" .. JE.uuid(g)},
    {"title", "LocalizedString", self:text("MOD " .. name .. " Quests")}})
  return t, g
end

function Enc:quest(key, q, group_guid)
  local t = self:tree()
  local qg = TR.new_guid()
  local res = add(t, "CJournalResource", 0, {{"entry", "ptr:CJournalBase", 2}})
  local quest = add(t, "CJournalQuest", res, {})
  local world = JE.WORLD[S(raw(q, "world", "")):lower()]
  local children = {}
  for _, ph in ipairs(items(P.or_(raw(q, "instructions"), Y.map()))) do
    local phase_name, objectives = ph[1], ph[2]
    local pg = TR.new_guid()
    local phase = add(t, "CJournalQuestPhase", quest, {
      {"guid", "CGUID", pg}, {"baseName", "String", S(phase_name)}, {"parentGuid", "CGUID", qg},
      {"children", CHILDREN, TR.Array({})}})
    children[#children + 1] = phase
    local listed = {}
    for k, item in ipairs(P.T(objectives) and objectives or {}) do
      for _, ob in ipairs(items(item)) do
        listed[#listed + 1] = {S(ob[1]), k - 1, P.T(ob[2]) and ob[2] or Y.map()}
      end
    end
    local kids = {}
    for _, l in ipairs(by_name(listed)) do
      local oname, k, body = l[1], l[2], l[3]
      local og = TR.new_guid()
      local obj = add(t, "CJournalQuestObjective", phase, {
        {"guid", "CGUID", og}, {"baseName", "String", oname}, {"order", "Uint32", k}, {"parentGuid", "CGUID", pg},
        {"index", "Uint8", k}})
      local pins = {}
      local mappins = raw(body, "mappins")
      for n, pin in ipairs(P.T(mappins) and mappins or {}) do
        local pname, radius
        if type(pin) == "table" and pin ~= Y.null and not Y.is_map(pin) then pname, radius = pin[1], pin[2]
        else pname, radius = pin, 1.0 end
        local mp = S(self.ctx.quest) .. "_" .. S(raw(q, "world")) .. "_" .. S(pname) .. "_mp"
        local pg_ = TR.new_guid()
        -- (as the game's pins: a script name of its own and its place - q304's race pins, which its switches turn on
        -- and off, have both; without them no switch turned one on)
        local hx = (pg_.b:gsub(".", function(c) return string.format("%02X", c:byte()) end))
        local script_id = mp .. " " .. hx:sub(1, 8) .. "-" .. hx:sub(9, 16) .. "-" .. hx:sub(17, 24) .. "-" .. hx:sub(25, 32)
        local props = {
          {"guid", "CGUID", pg_}, {"baseName", "String", mp}, {"order", "Uint32", n - 1},
          {"uniqueScriptIdentifier", "CName", script_id}, {"parentGuid", "CGUID", og}, {"index", "Uint8", n - 1},
          {"radius", "Float", GEN.float(radius)}, {"mapPinID", "CName", mp}}
        if (self.ctx.pins_off or {})[S(pname)] then props[#props + 1] = {"enabledAtStartup", "Bool", false} end
        pins[#pins + 1] = add(t, "CJournalQuestMapPin", obj, props)
      end
      local o = t:obj(obj)
      if #pins > 0 then o.props[#o.props + 1] = TR.Prop("children", CHILDREN, TR.Array(pins)) end
      o.props[#o.props + 1] = TR.Prop("title", "LocalizedString", self:text(raw(body, "caption", "")))
      if world ~= nil then o.props[#o.props + 1] = TR.Prop("world", "Uint32", world + 1) end
      kids[#kids + 1] = obj
    end
    t:obj(phase):set("children", TR.Array(kids))
  end
  local descriptions = raw(q, "description")
  if P.T(descriptions) then
    local dg = TR.new_guid()
    local group = add(t, "CJournalQuestDescriptionGroup", quest, {
      {"guid", "CGUID", dg}, {"baseName", "String", S(key) .. "_description_" .. JE.uuid(dg)},
      {"parentGuid", "CGUID", qg}, {"children", CHILDREN, TR.Array({})}})
    local listed = {}
    for k, item in ipairs(descriptions) do
      for _, d in ipairs(items(item)) do listed[#listed + 1] = {S(d[1]), k - 1, d[2]} end
    end
    local entries = {}
    for _, l in ipairs(by_name(listed)) do
      local ename, k, text = l[1], l[2], l[3]
      local props = {{"guid", "CGUID", TR.new_guid()}, {"baseName", "String", ename}, {"order", "Uint32", k},
                     {"parentGuid", "CGUID", dg}}
      if k ~= 0 then props[#props + 1] = {"index", "Uint8", k} end    -- (radish writes it from the second entry on)
      props[#props + 1] = {"description", "LocalizedString", self:text(text)}
      entries[#entries + 1] = add(t, "CJournalQuestDescriptionEntry", group, props)
    end
    t:obj(group):set("children", TR.Array(entries))
    children[#children + 1] = group
  end
  local props = {{"guid", "CGUID", qg}, {"baseName", "String", S(self.ctx.quest) .. "_" .. S(key)},
                 {"uniqueScriptIdentifier", "CName", "quest_" .. JE.uuid(qg)}, {"parentGuid", "CGUID", group_guid},
                 {"children", CHILDREN, TR.Array(children)},
                 {"type", "eQuestType", JE.TYPES[S(raw(q, "type"))] or "Side"}}
  if world ~= nil then props[#props + 1] = {"world", "Uint32", world} end
  props[#props + 1] = {"title", "LocalizedString", self:text(raw(q, "title", key))}
  local list = {}
  for k, p in ipairs(props) do list[k] = TR.Prop(p[1], p[2], p[3]) end
  t:obj(quest).props = list
  return t
end

function JE.encode(journals, ctx)
  local e = JE.Encoder(ctx)
  -- radish numbers the characters' texts first (each one's descriptions, then its name - the person's page of the
  -- journal, which radish still writes): the quests' come after them
  local chars = P.or_(raw(P.or_(raw(journals, "journals"), Y.map()), "characters"), Y.map())
  for _, kv in ipairs(items(chars)) do
    e.next_id = e.next_id + #P.list(raw(P.or_(kv[2], Y.map()), "description")) + 1
  end
  local files = Y.map()
  local base = "dlc/" .. S(ctx.dlc) .. "/journal/quests"
  local gt, gg = e:group()
  files[base .. "/questgroup_" .. S(ctx.quest) .. ".journal"] = gt:to_bytes()
  local quests = P.or_(raw(P.or_(raw(journals, "journals"), Y.map()), "quests"), Y.map())
  for _, kv in ipairs(items(quests)) do
    files[base .. "/" .. S(kv[1]) .. ".journal"] = e:quest(kv[1], kv[2], gg):to_bytes()
  end
  return files, e.strings
end

return JE
