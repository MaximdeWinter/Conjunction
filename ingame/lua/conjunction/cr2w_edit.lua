-- Changes to encoded quest files, as the app makes them: graph_edit.py's pieces (a property's bytes, a name, links,
-- blocks put in after another), cr2w_props.py's generic decoder, pathfollow.py (a path's curve into its entity, the
-- follow and race blocks) and minigames.py (gwent, fist fights, stopped lanes made the game's own blocks).
--   CE.apply_data(data, spec) -> data, names     CE.apply(folder, spec) -> names     CE.patch_paths(uncooked, spec)
local CR = require("conjunction.cr2w")
local P = require("conjunction.py")
local CE = {}
local pack = string.pack

-- --- graph_edit.py
CE.BLOCK_FLAGS, CE.CONDITION_FLAGS = 8192, 8200
function CE.idx(f, n) return f:add_name(n) end
function CE.prop(f, name, typ, value) return pack("<I2I2I4", f:add_name(name), f:add_name(typ), 4 + #value) .. value end
function CE.cname(f, n) return pack("<I2", f:add_name(n)) end
local prop, cname, idx = CE.prop, CE.cname, CE.idx

-- a String as the game's files hold an 8-bit one (latin-1)
function CE.string(s)
  local b = s
  if s:find("[\128-\255]") then
    local out = {}
    for _, c in utf8.codes(s) do
      if c > 255 then error("UnicodeEncodeError: 'latin-1' codec can't encode", 0) end
      out[#out + 1] = string.char(c)
    end
    b = table.concat(out)
  end
  local n = #b
  if n < 64 then return string.char(0x80 | n) .. b end
  return string.char(0x80 | 0x40 | (n & 0x3F), n >> 6) .. b
end

-- cachedConnections: {{socket, {{target export, input name}}}}
function CE.connections(f, conns)
  local out = {pack("<I4", #conns)}
  for _, c in ipairs(conns) do
    local socket, targets = c[1], c[2]
    local blocks = {pack("<I4", #targets)}
    for _, t in ipairs(targets) do
      blocks[#blocks + 1] = "\0" .. prop(f, "ock", "ptr:CQuestGraphBlock", pack("<i4", t[1])) ..
                            prop(f, "putName", "CName", cname(f, t[2])) .. "\0\0"
    end
    local sid = socket ~= nil and prop(f, "socketId", "CName", cname(f, socket)) or ""
    out[#out + 1] = "\0" .. sid .. prop(f, "blocks", "array:2,0,SBlockDesc", table.concat(blocks)) .. "\0\0"
  end
  return table.concat(out)
end

-- the chunk with the property `name` set to `value` (added before the end marker if it was not there)
function CE.replace_prop(f, chunk, name, typ, value)
  for _, p in ipairs(f:props(chunk)) do
    if p[1] == name then
      local head = p[3] - 8
      return chunk:sub(1, head) .. prop(f, name, typ, value) .. chunk:sub(p[3] + p[4] + 1)
    end
  end
  local props = f:props(chunk)
  local e = #props > 0 and (props[#props][3] + props[#props][4]) or 1
  return chunk:sub(1, e) .. prop(f, name, typ, value) .. chunk:sub(e + 1)
end

-- --- cr2w_props.py: properties decoded generically
local SIMPLE = {Bool = {"B", 1}, Int8 = {"<i1", 1}, Uint8 = {"<I1", 1}, Int16 = {"<i2", 2}, Uint16 = {"<I2", 2},
                Int32 = {"<i4", 4}, Uint32 = {"<I4", 4}, Int64 = {"<i8", 8}, Uint64 = {"<I8", 8}, Float = {"<f", 4},
                Double = {"<d", 8}}
local function latin1(b)
  return (b:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end))
end
local function utf16_replace(b)
  local out, i = {}, 1
  while i + 1 <= #b do
    local u = string.unpack("<I2", b, i)
    i = i + 2
    if u >= 0xD800 and u <= 0xDBFF and i + 1 <= #b then
      local l = string.unpack("<I2", b, i)
      if l >= 0xDC00 and l <= 0xDFFF then
        i = i + 2
        out[#out + 1] = utf8.char(0x10000 + ((u - 0xD800) << 10) + (l - 0xDC00))
      else
        out[#out + 1] = "\u{FFFD}"
      end
    elseif u >= 0xD800 and u <= 0xDFFF then
      out[#out + 1] = "\u{FFFD}"
    else
      out[#out + 1] = utf8.char(u)
    end
  end
  if i <= #b then out[#out + 1] = "\u{FFFD}" end
  return table.concat(out)
end
local function dstring(v)
  if v == "" then return "" end
  local b = v:byte(1)
  local n, i = b & 0x3F, 1
  if b & 0x40 ~= 0 then
    n = n + ((v:byte(2) or 0) << 6)
    i = 2
  end
  if b & 0x80 ~= 0 then return latin1(v:sub(i + 1, i + n)) end
  return utf16_replace(v:sub(i + 1, i + 2 * n))
end
local function ref(f, h)
  if h > 0 then return {"export", h} end
  if h < 0 and -h - 1 < #f.imports then return {"import", f.imports[-h][1]} end
  return nil
end
local struct_at
-- (CE.decode_ordered: the props' order kept - ORDER[struct] its names - and bytes not read as {bytes = ...}, as
-- Python tells bytes from str)
local TAG = false
local ORDER = setmetatable({}, {__mode = "k"})
CE.BYTES = {}
local function raw_bytes(v)
  if TAG then return setmetatable({bytes = v}, CE.BYTES) end
  return v
end
-- (an array's None: CE.NONE in its place - decode_ordered's lists keep their length)
CE.NONE = setmetatable({}, {__tostring = function() return "None" end})
local function keep_none(x)
  if x == nil and TAG then return CE.NONE end
  return x
end
local function value(f, typ, v)
  local s = SIMPLE[typ]
  if s then
    if #v < s[2] then return nil end
    if typ == "Bool" then return v:byte(1) ~= 0 end
    return (string.unpack(s[1], v))
  end
  if typ == "CName" then
    local k = #v >= 2 and string.unpack("<I2", v) or 0
    return f.names[k + 1]
  end
  if typ == "String" or typ == "StringAnsi" then return dstring(v) end
  if typ == "CVariant" then
    if #v < 6 then return nil end
    local t, sz = string.unpack("<I2I4", v)
    if t >= #f.names then return nil end
    return value(f, f.names[t + 1], v:sub(7, 2 + sz))
  end
  if typ == "LocalizedString" then return #v >= 4 and {"string", (string.unpack("<I4", v))} or nil end
  if typ:sub(1, 4) == "ptr:" or typ:sub(1, 7) == "handle:" then
    return #v >= 4 and ref(f, (string.unpack("<i4", v))) or nil
  end
  if typ:sub(1, 5) == "soft:" then
    local k = #v >= 2 and string.unpack("<I2", v) or 0
    return (k > 0 and k <= #f.imports) and {"import", f.imports[k][1]} or nil
  end
  if typ:sub(1, 6) == "array:" then
    local inner = typ:match("^array:[^,]*,[^,]*,(.*)$")
    local n = string.unpack("<I4", v)
    local out, i = {}, 4
    local si = SIMPLE[inner]
    if si then
      for k = 0, n - 1 do
        local x = string.unpack(si[1], v, 4 + k * si[2] + 1)
        if inner == "Bool" then x = x ~= 0 end
        out[#out + 1] = x
      end
      return out
    end
    if inner == "CName" or inner:sub(1, 5) == "soft:" then
      for k = 0, n - 1 do out[#out + 1] = keep_none(value(f, inner, v:sub(4 + 2 * k + 1, 6 + 2 * k))) end
      return out
    end
    if inner:sub(1, 4) == "ptr:" or inner:sub(1, 7) == "handle:" then
      for k = 0, n - 1 do out[#out + 1] = keep_none(value(f, inner, v:sub(4 + 4 * k + 1, 8 + 4 * k))) end
      return out
    end
    if inner == "String" then
      for _ = 1, n do
        local s2 = dstring(v:sub(i + 1))
        local b = v:byte(i + 1)
        local ln = (b & 0x3F) + ((b & 0x40 ~= 0) and (v:byte(i + 2) << 6) or 0)
        i = i + ((b & 0x40 ~= 0) and 2 or 1) + ((b & 0x80 ~= 0) and ln or 2 * ln)
        out[#out + 1] = s2
      end
      return out
    end
    for _ = 1, n do
      if i >= #v then break end
      local item
      item, i = struct_at(f, v, i)
      out[#out + 1] = item
    end
    return out
  end
  if #v == 2 and v:sub(1, 1) ~= "\0" then
    local k = string.unpack("<I2", v)
    return f.names[k + 1] or k
  end
  if v:sub(1, 1) == "\0" then
    local ok, r = pcall(function() return (struct_at(f, v, 0)) end)
    if ok then return r end
    return raw_bytes(v)
  end
  return raw_bytes(v)
end
-- a serialized struct at v[i] (0-based) -> {name = value}, the offset after it
struct_at = function(f, v, i)
  local out = {}
  local names = TAG and {} or nil
  if names then ORDER[out] = names end
  i = i + 1
  while i + 2 <= #v do
    local nm = string.unpack("<I2", v, i + 1)
    if nm == 0 then return out, i + 2 end
    local tp, sz = string.unpack("<I2I4", v, i + 3)
    local key = f.names[nm + 1]
    if names and out[key] == nil then
      local seen = false
      for _, k in ipairs(names) do if k == key then seen = true break end end
      if not seen then names[#names + 1] = key end
    end
    out[key] = value(f, f.names[tp + 1], v:sub(i + 9, i + 4 + sz))
    i = i + 4 + sz
  end
  return out, i
end
CE.value, CE.struct_at, CE.dstring = value, struct_at, dstring

-- {name = value} of an object's properties
function CE.decode(f, chunk)
  local out = {}
  for _, p in ipairs(f:props(chunk)) do
    local raw = chunk:sub(p[3] + 1, p[3] + p[4])
    local ok, v = pcall(value, f, p[2], raw)
    out[p[1]] = ok and v or raw
  end
  return out
end

-- CE.decode as cr2w_props.decode is to Python: its names in order (CE.keys), a struct a table with its own order (a
-- dict - CE.is_dict), bytes it could not read {bytes = ...} (CE.BYTES)
function CE.decode_ordered(f, chunk)
  TAG = true
  local ok, out = pcall(function()
    local d, names = {}, {}
    ORDER[d] = names
    for _, p in ipairs(f:props(chunk)) do
      local raw = chunk:sub(p[3] + 1, p[3] + p[4])
      local ok2, v = pcall(value, f, p[2], raw)
      local seen = false
      for _, k in ipairs(names) do if k == p[1] then seen = true break end end
      if not seen then names[#names + 1] = p[1] end
      if ok2 then d[p[1]] = v else d[p[1]] = raw_bytes(raw) end      -- (a False or None stays one)
    end
    return d
  end)
  TAG = false
  if not ok then error(out, 0) end
  return out
end
-- the names of a dict decode_ordered made, in order (only those it has: Python's None values are not there)
function CE.keys(d)
  local out = {}
  for _, k in ipairs(ORDER[d] or {}) do if d[k] ~= nil then out[#out + 1] = k end end
  return out
end
-- the names in order, None ones too
function CE.all_keys(d) return ORDER[d] or {} end
function CE.is_dict(d) return ORDER[d] ~= nil end

-- {{socket, {{target, input name}}}} of a block (export index)
function CE.links(f, block)
  local d = CE.decode(f, f.exports[block][5])
  local out = {}
  for _, c in ipairs(type(d.cachedConnections) == "table" and d.cachedConnections or {}) do
    local targets = {}
    for _, b in ipairs(type(c.blocks) == "table" and c.blocks or {}) do
      if type(b.ock) == "table" and b.ock[1] ~= nil then targets[#targets + 1] = {b.ock[2], b.putName or "In"} end
    end
    out[#out + 1] = {c.socketId, targets}
  end
  return out
end

-- 16 random bytes (a new block's GUID: os.urandom; the checks put a sequence of their own in)
function CE.random16()
  local hex = require("conjunction.marks").uuid4_hex()
  return (hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- a new block of class `cls` after `block` on `socket`: it leads where `block` led. props(new) -> its own properties
-- (after guid and links); children {{class, data}}: exports owned by it (conditions) -> the new export's index
function CE.insert(f, block, socket, cls, props, out_socket, children)
  children = children or {}
  local e = f.exports[block]
  local graph, chunk = e[3], e[5]
  local conns = CE.links(f, block)
  local after
  for _, c in ipairs(conns) do if c[1] == socket then after = c[2] break end end
  if after == nil then
    local have = {}
    for _, c in ipairs(conns) do have[#have + 1] = P.repr(c[1]) end
    error("ValueError: block " .. block .. " has no output " .. P.repr(socket) .. " (it has [" ..
          table.concat(have, ", ") .. "])", 0)
  end
  local new = #f.exports + 1
  idx(f, cls)                                   -- (class names too: the writer's own hash source lacks quest classes)
  for _, c in ipairs(children) do idx(f, c[1]) end
  local data = "\0" .. prop(f, "guid", "CGUID", CE.random16()) ..
               prop(f, "cachedConnections", "array:2,0,SCachedConnections", CE.connections(f, {{out_socket, after}})) ..
               props(new) .. "\0\0"
  f.exports[#f.exports + 1] = {cls, CE.BLOCK_FLAGS, graph, 0, data}
  for _, c in ipairs(children) do f.exports[#f.exports + 1] = {c[1], CE.CONDITION_FLAGS, new, 0, c[2]} end
  -- the block before leads to the new one now
  local now = {}
  for i, c in ipairs(conns) do now[i] = {c[1], c[1] == socket and {{new, "In"}} or c[2]} end
  e[5] = CE.replace_prop(f, chunk, "cachedConnections", "array:2,0,SCachedConnections", CE.connections(f, now))
  -- and the graph holds it
  local g = f.exports[graph]
  local blocks = {}
  for _, h in ipairs(type(CE.decode(f, g[5]).graphBlocks) == "table" and CE.decode(f, g[5]).graphBlocks or {}) do
    if type(h) == "table" and h[1] ~= nil then blocks[#blocks + 1] = h[2] end
  end
  blocks[#blocks + 1] = new
  local packed = {pack("<I4", #blocks)}
  for _, b in ipairs(blocks) do packed[#packed + 1] = pack("<i4", b) end
  g[5] = CE.replace_prop(f, g[5], "graphBlocks", "array:2,0,ptr:CGraphBlock", table.concat(packed))
  return new
end

-- a 'set fact' block after `block` on `socket` -> its export index
function CE.insert_fact_after(f, block, socket, fact, value)
  value = value or 1
  return CE.insert(f, block, socket, "CQuestFactsDBChangingBlock", function()
    return prop(f, "factID", "String", CE.string(fact)) .. prop(f, "value", "Int32", pack("<i4", value))
  end, "Out")
end

-- a 'wait until the fact is there' block after `block` on `socket` (as the game's own: QF_DoesExist >= 1; its output
-- has no name, like every pause block of the game's) -> its export index
function CE.insert_wait_after(f, block, socket, fact)
  local cond = "\0" .. prop(f, "factId", "String", CE.string(fact)) ..
               prop(f, "queryFact", "EQueryFact", cname(f, "QF_DoesExist")) ..
               prop(f, "value", "Int32", pack("<i4", 1)) ..
               prop(f, "compareFunc", "ECompareFunc", cname(f, "CF_GreaterEqual")) .. "\0\0"
  return CE.insert(f, block, socket, "CQuestPauseConditionBlock", function(new)
    return prop(f, "conditions", "array:2,0,ptr:IQuestCondition", pack("<I4i4", 1, new + 1))
  end, nil, {{"CQuestFactsDBCondition", cond}})
end

-- own content put into a game quest after `block`: it sets `start_fact` (a conjunction quest starts on it) and waits
-- until `resume_fact` (the conjunction quest sets it at its end), then goes on as before -> fact block, wait block
function CE.insert_hook(f, block, socket, start_fact, resume_fact)
  local wait = CE.insert_wait_after(f, block, socket, resume_fact)
  local fact = CE.insert_fact_after(f, block, socket, start_fact)
  return fact, wait
end

-- --- pathfollow.py
CE.TREE = [[gameplay\trees\scripted_actions\move_along_path_companion.w2behtree]]
CE.STEER = [[gameplay\behaviors\npc\steering\action\manual_pathfollow\manual_pathfollow.w2steer]]
CE.RACE_TREE = [[gameplay\trees\scripted_actions\move_along_path.w2behtree]]
CE.RACE_STEER = [[gameplay\behaviors\npc\steering\action\manual_pathfollow\manual_pathfollow_racing.w2steer]]
CE.LEAD_TREE = [[gameplay\trees\scripted_actions\follow.w2behtree]]
local TANGENT = {-0.1, 0.0, 0.1, 0.0}
local function st(props) return "\0" .. props .. "\0\0" end

-- the path's SMultiCurve (its value bytes) through points (relative to the entity)
function CE.curve(f, points)
  local N = require("conjunction.pynum")
  local function fl(name, v) return prop(f, name, "Float", pack("<f", v + 0.0)) end
  local lengths = {0.0}
  for k = 2, #points do
    local a, b = points[k - 1], points[k]
    lengths[k] = lengths[k - 1] + N.hypot(b[1] - a[1], b[2] - a[2], b[3] - a[3])
  end
  local total = lengths[#lengths]
  if total == 0 then total = 1.0 end
  local times = {}
  for k, d in ipairs(lengths) do times[k] = d / total end
  local vec = st(fl("X", TANGENT[1]) .. fl("Y", TANGENT[2]) .. fl("Z", TANGENT[3]) .. fl("W", TANGENT[4]))
  local datas = {}
  for axis = 1, 3 do
    local entries = {}
    for k, p in ipairs(points) do
      local t = times[k]
      entries[#entries + 1] = st((t > 0 and fl("me", t) or "") .. prop(f, "ntrolPoint", "Vector", vec) .. fl("lue", p[axis]) ..
                                 prop(f, "rveTypeL", "Uint16", pack("<I2", 1)) .. prop(f, "rveTypeR", "Uint16", pack("<I2", 1)))
    end
    local values = prop(f, "Curve Values", "array:147,0,SCurveDataEntry", pack("<I4", #points) .. table.concat(entries))
    datas[#datas + 1] = st(values .. prop(f, "value type", "ECurveValueType", cname(f, "CVT_Float")) ..
                           prop(f, "type", "ECurveBaseType", cname(f, "CT_Smooth")))
  end
  return st(prop(f, "type", "ECurveType", cname(f, "ECurveType_Vector")) ..
            prop(f, "enableAutomaticTimeByDistanceRecalculation", "Bool", "\1") ..
            prop(f, "curves", "array:2,0,SCurveData", pack("<I4", 3) .. table.concat(datas)))
end

local function add_props(f, export, extra)
  local e = f.exports[export]
  local chunk = e[5]
  local props = f:props(chunk)
  if #props > 0 then
    local en = props[#props][3] + props[#props][4]
    e[5] = chunk:sub(1, en) .. extra .. chunk:sub(en + 1)
  else
    e[5] = "\0" .. extra .. chunk:sub(2)
  end
end

local function repr_list(list)
  local parts = {}
  for i, s in ipairs(list) do parts[i] = "'" .. s .. "'" end
  return "[" .. table.concat(parts, ", ") .. "]"
end

local function walk_files(dir, fn)
  for _, e in ipairs(w3.fs.list(dir) or {}) do
    local p = dir .. "\\" .. e.name
    if e.dir then walk_files(p, fn) else fn(p, e.name) end
  end
end

-- the curves into the path entities radish encoded -> the names done
function CE.patch_paths(uncooked, spec)
  local done, have = {}, {}
  walk_files(uncooked, function(path, n)
    local name = n:match("^(.*)%.w2ent$")
    if name and spec[name] then
      local f = CR.parse(assert(w3.fs.read(path)))
      local comp
      for i, e in ipairs(f.exports) do if e[1] == "CPathComponent" then comp = i break end end
      if not comp then error(require("conjunction.questgen").ValueError(n .. ": no path component to put the way into"), 0) end
      add_props(f, comp, prop(f, "curve", "SMultiCurve", CE.curve(f, spec[name].points)))
      local data = f:save()
      if CR.parse(data):save() ~= data then error("RuntimeError: " .. n .. " does not read back after its way was written", 0) end
      assert(w3.fs.write(path, data))
      done[#done + 1] = name
      have[name] = true
    end
  end)
  local missing = {}
  for k in pairs(spec) do if not have[k] then missing[#missing + 1] = k end end
  table.sort(missing)
  if #missing > 0 then
    error(require("conjunction.questgen").ValueError("the encoded DLC has no path entity for " .. repr_list(missing)), 0)
  end
  return done
end

local function chunk_parts(f, chunk, keep_names)
  local props = f:props(chunk)
  local head = chunk:sub(1, props[1][3] - 8)
  local tail = chunk:sub(props[#props][3] + props[#props][4] + 1)
  local keep = {}
  for _, p in ipairs(props) do
    if keep_names(p[1]) then keep[#keep + 1] = chunk:sub(p[3] - 8 + 1, p[3] + p[4]) end
  end
  return head, table.concat(keep), tail
end

local function imported(f, path, cls)
  local low = path:lower()
  for k, im in ipairs(f.imports) do if im[1]:lower() == low then return -k end end
  idx(f, cls)
  f.imports[#f.imports + 1] = {path, cls, 0}
  return -#f.imports
end

-- walking or running; m.pace: metres a second, as the game's slowest walks have it (mq7024: MT_AbsSpeed with
-- moveSpeed 1.2 or 1.5, walking to the path's start)
local function move_type(m)
  if P.T(P.get(m, "pace")) then return "MT_AbsSpeed" end
  return P.T(P.get(m, "run")) and "MT_Run" or "MT_Walk"
end
local function move_before(m) return P.T(P.get(m, "pace")) and "MT_Walk" or move_type(m) end
local function pace_prop(f, m)
  if not P.T(P.get(m, "pace")) then return "" end
  return prop(f, "moveSpeed", "Float", pack("<f", tonumber(m.pace) + 0.0))
end

local function scripted(f, block, m, classes, tree_path, steer_path, params_props, priority)
  local e = f.exports[block]
  local head, keep, tail = chunk_parts(f, e[5], function(n) return n == "name" or n == "guid" or n == "cachedConnections" end)
  for _, c in ipairs(classes) do idx(f, c) end
  local tree, steer = imported(f, tree_path, "CBehTree"), imported(f, steer_path, "CMoveSteeringBehavior")
  local action = #f.exports + 1
  local params = action + 1
  e[1] = "CQuestScriptedActionsBlock"
  e[5] = head .. keep .. prop(f, "npcTag", "CName", cname(f, m.npc)) ..
         prop(f, "actionsPriority", "ETopLevelAIPriorities", cname(f, priority)) ..
         prop(f, "ai", "handle:IAIActionTree", pack("<i4", action)) .. tail
  local p = params_props(steer)
  f.exports[#f.exports + 1] = {classes[2], CE.CONDITION_FLAGS, block, 0, "\0" .. prop(f, "tree", "handle:CBehTree", pack("<i4", tree)) ..
                               prop(f, "params", "handle:CAIMoveAlongPathParams", pack("<i4", params)) .. "\0\0"}
  f.exports[#f.exports + 1] = {classes[3], CE.CONDITION_FLAGS, action, 0, "\0" .. p .. "\0\0"}
end

-- a racer runs the path as Becca runs against Geralt in q201's race ('Becca Runs'): CAIMoveAlongPathAction with
-- CAIMoveAlongPathParams, sprinting before and on the path, manual_pathfollow steering, explorations used, not
-- navigable-bound, on from where the racer stands
function CE.race_block(f, block, m)
  local pace = P.or_(P.get(m, "pace"), "MT_Sprint")
  scripted(f, block, m, {"CQuestScriptedActionsBlock", "CAIMoveAlongPathAction", "CAIMoveAlongPathParams"},
           CE.RACE_TREE, CE.STEER, function(steer)
    return prop(f, "pathTag", "CName", cname(f, m.path)) .. prop(f, "fromBeginning", "Bool", "\0") ..
           prop(f, "moveTypeBeforePath", "EMoveType", cname(f, pace)) ..
           prop(f, "moveType", "EMoveType", cname(f, pace)) ..
           prop(f, "steeringGraph", "handle:CMoveSteeringBehavior", pack("<i4", steer)) ..
           prop(f, "rotateAfterReachStart", "Bool", "\0") .. prop(f, "useExplorations", "Bool", "\1") ..
           prop(f, "dontCareAboutNavigable", "Bool", "\1")
  end, "AIP_AboveEmergency")
end

-- the person follows the player (Geralt leads) - CAIFollowAction with its params, as 180 blocks of the game's quests
-- (q505: the boy from the hut); it ends when the quest cuts it (a cut control block)
function CE.lead_block(f, block, m)
  local e = f.exports[block]
  local head, keep, tail = chunk_parts(f, e[5], function(n) return n == "name" or n == "guid" or n == "cachedConnections" end)
  for _, c in ipairs({"CQuestScriptedActionsBlock", "CAIFollowAction", "CAIFollowParams"}) do idx(f, c) end
  local tree = imported(f, CE.LEAD_TREE, "CBehTree")
  local action = #f.exports + 1
  local params = action + 1
  e[1] = "CQuestScriptedActionsBlock"
  e[5] = head .. keep .. prop(f, "npcTag", "CName", cname(f, m.npc)) ..
         prop(f, "actionsPriority", "ETopLevelAIPriorities", cname(f, "AIP_AboveEmergency")) ..
         prop(f, "ai", "handle:IAIActionTree", pack("<i4", action)) .. tail
  local p = prop(f, "moveType", "EMoveType", cname(f, P.T(P.get(m, "run")) and "MT_Run" or "MT_Walk")) ..
            prop(f, "followDistance", "Float", pack("<f", tonumber(P.get(m, "distance", 3.0)) + 0.0)) ..
            prop(f, "rotateToWhenAtTarget", "Bool", "\0")
  f.exports[#f.exports + 1] = {"CAIFollowAction", CE.CONDITION_FLAGS, block, 0, "\0" ..
                               prop(f, "tree", "handle:CBehTree", pack("<i4", tree)) ..
                               prop(f, "params", "handle:CAIFollowParams", pack("<i4", params)) .. "\0\0"}
  f.exports[#f.exports + 1] = {"CAIFollowParams", CE.CONDITION_FLAGS, action, 0, "\0" .. p .. "\0\0"}
end

-- the person walks the path (a tag) alone - CAIMoveAlongPathAction with its plain params (a phase change of his
-- community and every script move left Dijkstra standing, the scripted actions block walked him up the stairs)
function CE.walk_block(f, block, m)
  scripted(f, block, m, {"CQuestScriptedActionsBlock", "CAIMoveAlongPathAction", "CAIMoveAlongPathParams"},
           CE.RACE_TREE, CE.STEER, function(steer)
    return prop(f, "pathTag", "CName", cname(f, m.path)) .. prop(f, "fromBeginning", "Bool", "\1") ..
           prop(f, "pathMargin", "Float", pack("<f", 0.5)) ..
           prop(f, "moveTypeBeforePath", "EMoveType", cname(f, move_before(m))) ..
           prop(f, "moveType", "EMoveType", cname(f, move_type(m))) .. pace_prop(f, m) ..
           prop(f, "steeringGraph", "handle:CMoveSteeringBehavior", pack("<i4", steer)) ..
           prop(f, "rotateAfterReachStart", "Bool", "\0") .. prop(f, "useExplorations", "Bool", "\1") ..
           prop(f, "dontCareAboutNavigable", "Bool", "\1") .. prop(f, "tolerance", "Float", pack("<f", 1.0))
  end, "AIP_AboveEmergency")
end

-- the person walks the path with the player as companion
function CE.follow_block(f, block, m)
  local move = move_type(m)
  local function num(v, d) if v == nil then return d end return tonumber(v) + 0.0 end
  scripted(f, block, m, {"CQuestScriptedActionsBlock", "CAIMoveAlongPathWithCompanionAction", "CAIMoveAlongPathWithCompanionParams"},
           CE.TREE, CE.STEER, function(steer)
    return prop(f, "pathTag", "CName", cname(f, m.path)) ..
           prop(f, "moveTypeBeforePath", "EMoveType", cname(f, move_before(m))) ..
           prop(f, "moveType", "EMoveType", cname(f, move)) .. pace_prop(f, m) ..
           prop(f, "steeringGraph", "handle:CMoveSteeringBehavior", pack("<i4", steer)) ..
           prop(f, "rotateAfterReachStart", "Bool", "\0") .. prop(f, "useExplorations", "Bool", "\1") ..
           prop(f, "dontCareAboutNavigable", "Bool", "\1") .. prop(f, "tolerance", "Float", pack("<f", 1.0)) ..
           prop(f, "maxDistance", "Float", pack("<f", num(m.max, 10.0))) ..
           prop(f, "minDistance", "Float", pack("<f", num(m.min, 4.0))) ..
           prop(f, "progressWhenCompanionIsAhead", "Bool", "\1")
  end, P.get(m, "priority", "AIP_AboveEmergency"))
end

-- --- minigames.py
CE.DIFFICULTY = {medium = "EGDM_Medium", hard = "EGDM_Hard"}
CE.AGGRESSION = {normal = "EGAM_Normal", aggressive = "EGAM_Aggressive", ["very aggressive"] = "EGAM_VeryAggressive",
                 ["all it has"] = "EGAM_AllIHave"}
CE.CLASSES = {waituntil = "CQuestPauseConditionBlock", interaction = "CQuestInteractionDialogBlock",
              objective = "CJournalQuestBlock", script = "CQuestScriptBlock", changelayers = "CQuestLayersHiderBlock",
              reward = "CQuestRewardBlock", addfact = "CQuestFactsDBChangingBlock", spawn = "CQuestStoryPhaseSetterBlock",
              journal = "CJournalBlock", scene = "CQuestSceneBlock", randomize = "CQuestRandomBlock"}

local function replace(f, block, m)
  local e = f.exports[block]
  local head, keep, tail = chunk_parts(f, e[5], function(n) return n ~= "randomOutputs" end)
  local new = #f.exports + 1
  local cls = P.get(m, "game") == "fistfight" and "CFistfightMinigame" or "CGwintMinigame"
  for _, c in ipairs({"CQuestGraphMinigameBlock", cls}) do idx(f, c) end
  e[1] = "CQuestGraphMinigameBlock"
  e[5] = head .. keep .. prop(f, "minigame", "ptr:CMinigame", pack("<i4", new)) .. tail
  local game
  if cls == "CFistfightMinigame" then
    local en = {pack("<I4", #m.enemies)}
    for _, t in ipairs(m.enemies) do en[#en + 1] = "\0" .. prop(f, "npcTag", "CName", cname(f, t)) .. "\0\0" end
    game = "\0" .. prop(f, "fightAreaTag", "CName", cname(f, m.area)) ..
           prop(f, "enemies", "array:2,0,CFistfightOpponent", table.concat(en)) .. "\0\0"
  else
    game = "\0" .. prop(f, "deckName", "CName", cname(f, m.deck)) ..
           prop(f, "difficulty", "EGwintDifficultyMode", cname(f, CE.DIFFICULTY[P.get(m, "difficulty")] or "EGDM_Medium")) ..
           prop(f, "aggression", "EGwintAggressionMode", cname(f, CE.AGGRESSION[P.get(m, "aggression")] or "EGAM_Normal")) .. "\0\0"
  end
  f.exports[#f.exports + 1] = {cls, CE.CONDITION_FLAGS, block, 0, game}
end

-- the stand-in (a fact block) made the game's cut control block: Out as before, Thunder to the input Cut of every
-- block of the lane
local function cut(f, block, m, named)
  local targets = {}
  for _, key in ipairs(m.blocks or {}) do
    local kind, name = key:match("^([^.]*)%.?(.*)$")
    if not key:find(".", 1, true) then kind, name = key, "" end
    local found = {}
    for _, nm in ipairs(named) do
      if nm[3] == name and (nm[2] == CE.CLASSES[kind] or CE.CLASSES[kind] == nil) then found[#found + 1] = nm[1] end
    end
    if #found == 1 then targets[#targets + 1] = {found[1], "Cut"} end
  end
  if #targets == 0 then
    error(require("conjunction.questgen").ValueError("stop lane: none of the lane's blocks is in the encoded quest (" ..
                                                     tostring(m.lane) .. ")"), 0)
  end
  local e = f.exports[block]
  local head, keep, tail = chunk_parts(f, e[5], function(n) return n == "name" or n == "guid" end)
  local out
  for _, l in ipairs(CE.links(f, block)) do if l[1] == "Out" and out == nil then out = l[2] end end
  idx(f, "CQuestCutControlBlock")
  e[1] = "CQuestCutControlBlock"
  local conns = {{"Out", out or {}}, {"Thunder", targets}}
  local c = CE.connections(f, conns)
  e[5] = head .. keep .. pack("<I2I2I4", idx(f, "cachedConnections"), idx(f, "array:2,0,SCachedConnections"), 4 + #c) ..
         CE.connections(f, conns) .. tail
end

-- the stand-ins of spec in one encoded quest file (its bytes) -> the new bytes, the names replaced
function CE.apply_data(data, spec)
  local any = false
  for n in pairs(spec or {}) do if data:find(n, 1, true) then any = true break end end
  if not any then return data, {} end
  local f = CR.parse(data)
  local named = {}
  for i, e in ipairs(f.exports) do
    if e[1]:find("Block", 1, true) then named[#named + 1] = {i, e[1], CE.decode(f, e[5]).name} end
  end
  local mine = {}
  for _, nm in ipairs(named) do
    if nm[3] ~= nil and spec[nm[3]] ~= nil and (nm[2] == "CQuestRandomBlock" or nm[2] == "CQuestFactsDBChangingBlock") then
      mine[#mine + 1] = {nm[1], nm[3]}
    end
  end
  for _, im in ipairs(mine) do
    local m = spec[im[2]]
    local game = P.get(m, "game")
    if game == "cut" then cut(f, im[1], m, named)
    elseif game == "follow" then CE.follow_block(f, im[1], m)
    elseif game == "lead" then CE.lead_block(f, im[1], m)
    elseif game == "walkpath" then CE.walk_block(f, im[1], m)
    elseif game == "race" then CE.race_block(f, im[1], m)
    else replace(f, im[1], m) end
  end
  local names = {}
  for _, im in ipairs(mine) do names[#names + 1] = im[2] end
  return (#mine > 0 and f:save() or data), names
end

function CE.apply(folder, spec)
  local done = {}
  if not spec or next(spec) == nil then return done end
  local files = {}
  walk_files(folder, function(p, n) if n:match("%.w2quest$") or n:match("%.w2phase$") then files[#files + 1] = p end end)
  table.sort(files)
  local have = {}
  for _, fn in ipairs(files) do
    local data = assert(w3.fs.read(fn))
    local new, mine = CE.apply_data(data, spec)
    if #mine > 0 then
      assert(w3.fs.write(fn, new))
      for _, n in ipairs(mine) do done[#done + 1] = n have[n] = true end
    end
  end
  local missing = {}
  for k in pairs(spec) do if not have[k] then missing[#missing + 1] = k end end
  table.sort(missing)
  if #missing > 0 then
    error(require("conjunction.questgen").ValueError("the encoded quest has no stand-in for " .. repr_list(missing)), 0)
  end
  return done
end

return CE
