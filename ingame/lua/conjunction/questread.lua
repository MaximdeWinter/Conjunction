-- questread.py: the game's own quests, readable - a quest graph's blocks (class, properties as cr2w_props.decode has
-- them, where each leads) and a block in a line (Graph:describe), as the windows that pick a point of a game quest
-- show them.
--   QR.short(cls)  QR.fmt(v, f, depth)  QR.Graph(f, graph_export)  g:describe(i)  QR.open_graph(depot, path) -> g, f
local CR = require("conjunction.cr2w")
local CE = require("conjunction.cr2w_edit")
local P = require("conjunction.py")
local PS = require("conjunction.pysort")
local QR = {}

local SKIP = {guid = true, cachedConnections = true, name = true}
QR.SKIP = SKIP

function QR.short(cls)
  for _, p in ipairs({"CQuest", "CJournal", "CStoryScene", "C"}) do
    if cls:sub(1, #p) == p then
      cls = cls:sub(#p + 1)
      break
    end
  end
  return (cls:gsub("Block", ""):gsub("Condition", "?"))
end

local function is_bytes(v) return getmetatable(v) == CE.BYTES end
local function is_ref(v, kind)
  return type(v) == "table" and not is_bytes(v) and not CE.is_dict(v) and v[1] == kind and #v == 2
end
QR.is_ref = is_ref

-- for x in v: a list's items, bytes' numbers, a dict's keys (Python's iteration of what decode gives)
local function iter(v)
  if is_bytes(v) then
    local out = {}
    for k = 1, #v.bytes do out[k] = v.bytes:byte(k) end
    return out
  end
  if type(v) == "table" and CE.is_dict(v) then return CE.all_keys(v) end
  if type(v) == "table" then return v end
  return {}
end
QR.iter = iter

-- p.get(...) on what is not a dict: Python's AttributeError
local function need_dict(p)
  if CE.is_dict(p) then return end
  local t = is_bytes(p) and "bytes" or type(p) == "table" and "list" or math.type(p) == "float" and "float" or
            type(p) == "number" and "int" or type(p) == "boolean" and "bool" or type(p) == "string" and "str" or
            "NoneType"
  error("AttributeError: '" .. t .. "' object has no attribute 'get'", 0)
end
QR.need_dict = need_dict

-- x in (None, "", [], {})
local function empty(x)
  if x == nil or x == "" or x == CE.NONE then return true end
  if type(x) == "table" and not is_bytes(x) then
    if CE.is_dict(x) then return #CE.all_keys(x) == 0 end
    return next(x) == nil
  end
  return false
end
QR.empty = empty

-- str(v) of what decode gives (int, float, bool, str, None, a LocalizedString's ('string', id))
local function str(v)
  if v == nil or v == CE.NONE then return "None" end
  if v == true then return "True" end
  if v == false then return "False" end
  if math.type(v) == "float" then return P.str(v) end
  if is_ref(v, "string") then return "('string', " .. tostring(v[2]) .. ")" end
  return tostring(v)
end

-- f"{v:g}"
local function g_fmt(v)
  if v ~= v then return "nan" end
  if v == math.huge then return "inf" end
  if v == -math.huge then return "-inf" end
  return string.format("%g", v)
end

-- a value, compact: handles to other objects of the file followed one level (a condition, a journal entry); imports
-- by their file name (questread._fmt)
function QR.fmt(v, f, depth)
  depth = depth or 0
  if v == CE.NONE then return "None" end
  if is_ref(v, "import") then return (v[2]:match("([^\\]*)$")) end
  if is_ref(v, "export") then
    if depth > 1 or not (v[2] > 0 and v[2] <= #f.exports) then return "#" .. v[2] end
    local e = f.exports[v[2]]
    local d = CE.decode_ordered(f, e[5])
    local parts = {}
    for _, k in ipairs(CE.keys(d)) do
      if not SKIP[k] and not empty(d[k]) then parts[#parts + 1] = k .. "=" .. QR.fmt(d[k], f, depth + 1) end
    end
    local inner = table.concat(parts, ", ")
    return inner ~= "" and (QR.short(e[1]) .. "(" .. inner .. ")") or QR.short(e[1])
  end
  if is_bytes(v) then return "<" .. #v.bytes .. " bytes>" end
  if type(v) == "table" and CE.is_dict(v) then
    local parts = {}
    for _, k in ipairs(CE.keys(v)) do
      if not empty(v[k]) then parts[#parts + 1] = k .. "=" .. QR.fmt(v[k], f, depth) end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  if type(v) == "table" and not is_ref(v, "string") then
    local parts = {}
    for k = 1, math.min(8, #v) do parts[#parts + 1] = QR.fmt(v[k], f, depth) end
    return "[" .. table.concat(parts, ", ") .. (#v > 8 and " ..." or "") .. "]"
  end
  if math.type(v) == "float" then return g_fmt(v) end
  return str(v)
end

local function truthy(v)
  if v == nil or v == false or v == "" or v == 0 or v == CE.NONE then return false end
  if type(v) == "table" and not is_bytes(v) then return not empty(v) end
  if is_bytes(v) then return v.bytes ~= "" end
  return true
end

-- the blocks of a quest graph (in one file): blocks {export index: {cls, props, outs}}, outs {{socket, target,
-- target socket}}; order: the indices sorted; ins: in the order the graph lists them (Python's dict)
local Graph = {}
Graph.__index = Graph

function QR.Graph(f, graph_export)
  local g = setmetatable({f = f, n = graph_export, blocks = {}, order = {}, ins = {}}, Graph)
  local props = CE.decode_ordered(f, f.exports[graph_export][5])
  local refs = props.graphBlocks
  for _, ref in ipairs(truthy(refs) and iter(refs) or {}) do
    if is_ref(ref, "export") then
      local i = ref[2]
      local e = f.exports[i]
      local bp = CE.decode_ordered(f, e[5])
      local outs = {}
      local conns = bp.cachedConnections
      for _, c in ipairs(truthy(conns) and iter(conns) or {}) do
        need_dict(c)
        local blocks = c.blocks
        for _, b in ipairs(truthy(blocks) and iter(blocks) or {}) do
          need_dict(b)
          local t = b.ock
          if is_ref(t, "export") then
            outs[#outs + 1] = {P.T(c.socketId) and c.socketId or "Out", t[2], P.T(b.putName) and b.putName or "In"}
          end
        end
      end
      if g.blocks[i] == nil then g.order[#g.order + 1] = i end
      g.blocks[i] = {e[1], bp, outs}
    end
  end
  for k, i in ipairs(g.order) do g.ins[k] = i end      -- (ins: as Python's dict has them - graphBlocks' order)
  table.sort(g.order)
  return g
end


function Graph:describe(i)
  local b = self.blocks[i]
  local cls, bp = b[1], b[2]
  local name = truthy(bp.name) and bp.name or ""
  local f = self.f
  if cls == "CQuestScriptBlock" then
    local args = {}
    local params = truthy(bp.parameters) and iter(bp.parameters) or {}
    for _, p in ipairs(params) do
      need_dict(p)
      args[#args + 1] = str(p.name) .. "=" .. QR.fmt(p.value, f)
    end
    return "do " .. str(bp.functionName) .. "(" .. table.concat(args, ", ") .. ")"
  end
  if cls == "CQuestPauseConditionBlock" then
    local cs = {}
    for _, c in ipairs(truthy(bp.conditions) and iter(bp.conditions) or {}) do cs[#cs + 1] = QR.fmt(c, f) end
    return "wait " .. P.repr(str(name)) .. ": " .. table.concat(cs, " & ")
  end
  if cls == "CQuestSceneBlock" or cls == "CQuestInteractionDialogBlock" then
    return (cls == "CQuestSceneBlock" and "scene" or "talk") .. " " .. QR.fmt(bp.scene, f)
  end
  if cls == "CQuestPhaseBlock" then
    local inner = truthy(bp.phase) and bp.phase or bp.embeddedGraph
    return "phase " .. P.repr(str(name)) .. " -> " .. QR.fmt(inner, f, 2)
  end
  local rest = {}
  for _, k in ipairs(CE.keys(bp)) do
    if not SKIP[k] and not empty(bp[k]) then rest[#rest + 1] = k .. "=" .. QR.fmt(bp[k], f) end
  end
  local out = QR.short(cls) .. " " .. P.repr(str(name)) .. " " .. table.concat(rest, ", ")
  return (out:gsub("%s+$", ""))
end

-- (Graph of the file's main graph, CR2W) of a .w2phase / .w2quest
function QR.open_graph(depot, path)
  local f = CR.parse(depot:read(path))
  local top = CE.decode_ordered(f, f.exports[1][5])
  local g = top.graph
  local n = is_ref(g, "export") and g[2] or nil
  if n == nil then
    for k, e in ipairs(f.exports) do
      if e[1] == "CQuestGraph" then n = k break end
    end
  end
  return QR.Graph(f, n), f
end

return QR
