-- game_catalog.py: what the game's quests are made of, as a catalog for the quest graph's general blocks - every
-- block class, condition, script function and AI action the game's quest graphs use, their fields with types, the
-- values the game gives them, CDPR's own descriptions and defaults. The app builds it (game_catalog.json, about a
-- minute over the scripts and all 1041 quest files); here it is read.
--   GC.load() -> catalog | nil      GC.label(name)      GC.enum_values(catalog, typ [, seen])
--   GC.default_of(catalog, cls, field)
local J = require("conjunction.json")
local P = require("conjunction.py")
local R = require("conjunction.pyre")
local S = require("conjunction.pystr")
local PATHS = require("conjunction.paths")
local GC = {}

GC.CACHE = PATHS.DATA .. "\\game_catalog.json"
GC.PREFIXES = {"W3QuestCond_", "CQuestCondition", "CQuest", "CJournalQuest", "CJournal", "CQC", "CAI", "CBehTree",
               "W3", "C"}
GC.SUFFIXES = {"Block", "Condition", "Action", "Params", "Quest"}
local WORDS = R.compile([[[A-Z]+(?=[A-Z][a-z]|\d|\b)|[A-Z]?[a-z]+|\d+|[A-Z]+]])

-- CQuestInsideTriggerCondition -> "Inside trigger", W3QuestCond_IsItemEquipped -> "Is item equipped"
function GC.label(name)
  local n = name
  for _, p in ipairs(GC.PREFIXES) do
    if P.startswith(n, p) and #n > #p then
      n = n:sub(#p + 1)
      break
    end
  end
  for _, s in ipairs(GC.SUFFIXES) do
    if P.endswith(n, s) and #n > #s then n = n:sub(1, #n - #s) end
  end
  n = P.replace(n, "_", " ")
  local words = WORDS:findall(n)
  local text = #words > 0 and table.concat(words, " ") or n
  if text == "" then return name end
  return S.upper(text:sub(1, 1)) .. S.lower(text:sub(2))
end

GC.NATIVE_ENUMS = {
  ECompareFunc = {"CF_Equal", "CF_NotEqual", "CF_Less", "CF_LessEqual", "CF_Greater", "CF_GreaterEqual"},
  EQueryFact = {"QF_Sum", "QF_SumSince", "QF_LatestValue", "QF_DoesExist"},
  ELogicOperation = {"LO_And", "LO_Or", "LO_Xor", "LO_Nand", "LO_Nor", "LO_Nxor"},
  EJournalStatus = {"JS_Inactive", "JS_Active", "JS_Success", "JS_Failed"},
}
GC.INT_TYPES = {Int8 = true, Uint8 = true, Int16 = true, Uint16 = true, Int32 = true, Uint32 = true, Int64 = true,
                Uint64 = true, Float = true, Double = true}

local function field_of(catalog, cls, field)
  local c = P.get(P.get(catalog, "classes") or {}, cls) or {}
  return P.get(P.get(c, "fields") or {}, field) or {}
end

-- the values a choice can have: the scripts' list, the engine's, else those the game's files use
function GC.enum_values(catalog, typ, seen)
  local got = P.get(P.get(catalog, "enums") or {}, typ)
  if not P.T(got) then got = GC.NATIVE_ENUMS[typ] end
  if not P.T(got) then got = seen or {} end
  local out = {}
  for i, v in ipairs(got) do out[i] = v end
  return out
end

local function strip_quotes(d)
  d = S.strip(d)
  return (d:gsub('^"+', ""):gsub('"+$', ""))
end

-- a field's value when a file leaves it out: the scripts' `default`, else read off the game's files (see the app's
-- game_catalog.default_of); nil: not known
function GC.default_of(catalog, cls, field)
  local f = field_of(catalog, cls, field)
  local typ = P.get(f, "type") or ""
  local seen = {}
  for _, vc in ipairs(P.get(f, "values") or {}) do seen[P.str(vc[1])] = true end
  local d = P.get(f, "default")
  if d ~= nil and d ~= "" then
    d = strip_quotes(P.str(d))
    if typ == "Bool" then
      local l = d:lower()
      return l == "true" or l == "yes" or l == "1"
    end
    if GC.INT_TYPES[typ] then
      local ok, x = pcall(require("conjunction.pynum").float, d)
      if not ok then return nil end
      if typ == "Float" or typ == "Double" then return x end
      return math.tointeger(x >= 0 and math.floor(x) or math.ceil(x))
    end
    return d
  end
  if typ == "Bool" then
    local only_no = seen["no"] == true          -- (only ever written as no: yes by default)
    for k in pairs(seen) do if k ~= "no" then only_no = false end end
    return only_no
  end
  if GC.INT_TYPES[typ] then
    local fl = typ == "Float" or typ == "Double"
    if next(seen) == nil then return nil end
    if not seen["0"] and not seen["0.0"] then return fl and 0.0 or 0 end
    if not seen["1"] and not seen["1.0"] then return fl and 1.0 or 1 end
    return nil
  end
  if typ == "String" or typ == "CName" or typ == "StringAnsi" then return "" end
  for _, o in ipairs(GC.enum_values(catalog, typ)) do
    if not seen[o] then return o end
  end
  return nil
end

local cached
function GC.load()
  if cached ~= nil then return cached or nil end
  local ok, v = pcall(J.read, GC.CACHE)
  cached = ok and v or false
  return cached or nil
end
function GC.reset() cached = nil end

return GC
