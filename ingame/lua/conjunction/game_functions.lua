-- game_functions.py: the game's quest functions a Game function step can call, as the app keeps them
-- (Documents\Conjunction\data\game_functions.json - the app reads the game's scripts once and writes it; without it
-- the list is empty here).
--   GF.functions() -> {name: {params = {{name, type, optional}}, latent, file}}
--   GF.kind(type) -> "name" | "string" | "int" | "float" | "bool" | "enum" | nil
local J = require("conjunction.json")
local PATHS = require("conjunction.paths")
local GF = {}
GF.CACHE = PATHS.DATA .. "\\game_functions.json"
GF.SIMPLE = {name = "name", cname = "name", string = "string", int = "int", float = "float", bool = "bool",
             Uint32 = "int", Int32 = "int", Uint8 = "int", Int8 = "int", Uint16 = "int"}
local data

local function load()
  if data == nil then
    local ok, d = pcall(J.read, GF.CACHE)
    data = (ok and type(d) == "table" and d.functions) and d or {functions = {}, enums = {}}
  end
  return data
end

function GF.functions() return load().functions end
function GF.enums() return load().enums or {} end

function GF.kind(typ)
  if GF.SIMPLE[typ] then return GF.SIMPLE[typ] end
  if GF.enums()[typ] ~= nil then return "enum" end
  return nil
end

local R = require("conjunction.pyre")
local S = require("conjunction.pystr")

-- radish can write every parameter (and a latent one needs no wrapper: only a quest block may call those)
function GF.usable(fn)
  local info = GF.functions()[fn]
  local enum = false
  for _, p in ipairs(info.params or {}) do
    local k = GF.kind(p[2])
    if not k then return false end
    if k == "enum" then enum = true end
  end
  return not (info.latent == true and enum)
end

-- 'DoorChangeState' -> 'Door change state' ('Quest' at the end dropped)
function GF.label(fn)
  local name = R.sub([[Quest$]], "", fn)
  if name == "" then name = fn end
  local words = S.split(R.sub([[(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])]], " ", name))
  if #words == 0 then return fn end
  local out = {words[1]}
  for k = 2, #words do out[k] = S.isupper(words[k]) and words[k] or S.lower(words[k]) end
  return table.concat(out, " ")
end

-- 'dontBlockInCombat' -> 'dont block in combat'
function GF.words(name) return S.lower(R.sub([[(?<=[a-z0-9])(?=[A-Z])]], " ", name)) end

-- a parameter's value as radish writes it (names as CNAME_, enums by their value's index)
function GF.radish_value(typ, value)
  local GEN = require("conjunction.questgen")
  local k = GF.kind(typ)
  if k == "name" then return "cname_" .. require("conjunction.py").str(value) end
  if k == "int" then return GEN.int(value) end
  if k == "float" then return GEN.float(value) end
  if k == "bool" then return require("conjunction.py").T(value) end
  if k == "enum" then
    for i, v in ipairs(GF.enums()[typ] or {}) do if v == value then return i - 1 end end
    return GEN.int(require("conjunction.py").or_(value, 0))
  end
  return require("conjunction.py").str(value)
end

-- the value a required parameter has before one is chosen
function GF.default(typ)
  local k = GF.kind(typ)
  if k == "int" then return 0 end
  if k == "float" then return 0.0 end
  if k == "bool" then return false end
  if k == "enum" then return (GF.enums()[typ] or {""})[1] or "" end
  return ""
end

GF.WRAP = "CjG_"
-- a function with enum parameters is called through a wrapper that takes their values as names
function GF.needs_wrapper(fn)
  if not GF.usable(fn) then return false end
  for _, p in ipairs(GF.functions()[fn].params or {}) do if GF.kind(p[2]) == "enum" then return true end end
  return false
end
function GF.called(fn) return GF.needs_wrapper(fn) and (GF.WRAP .. fn) or fn end

return GF
