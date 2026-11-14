-- Our own layer encoder (layer_encoder.py): layers.yml (radish's format, the generator writes it) into the layer files
-- the game reads - a place's objects (static.w2l) and per world the quest's meta layer: action points, trigger areas,
-- scene points and map pins, as radish wrote them (its own debug layer left out - the game does not read it).
--   LE.encode(layers, ctx) -> Y.map {layer depot path = bytes}
--   LE.Ctx(quest id, dlc, template bytes, repo dir)   radish's repository: worlds.repo.yml, all.actions.repo.yml
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local TR = require("conjunction.cr2w_tree")
local GEN = require("conjunction.questgen")
local LE = {}

LE.LAYER, LE.STATIC = 8192, 0
local LAYER, STATIC = LE.LAYER, LE.STATIC
LE.META_FILES = {{"actionpoints", "actionpoints.w2l"}, {"areas", "areas.w2l"}, {"mappins", "mappins.w2l"},
                 {"scenepoints", "scenepoints.w2l"}}
LE.SUFFIX = {actionpoints = "ap", areas = "ar", mappins = "mp", scenepoints = "sp"}
LE.KIND = {actionpoints = "layer_actionpoint", areas = "layer_area", mappins = "layer_mappin",
           scenepoints = "layer_scenepoint"}
local S, Prop, Struct = P.str, TR.Prop, TR.Struct

local function f32(x) return (string.unpack("<f", string.pack("<f", GEN.float(x)))) end
LE.f32 = f32

-- a mean as radish computes it: summed up in float32, divided in float32
local function mean32(values)
  local total = 0.0
  for _, v in ipairs(values) do total = f32(total + f32(v)) end
  return f32(total / f32(#values))
end

local function vec(x, y, z, w)
  return Struct({Prop("X", "Float", f32(x)), Prop("Y", "Float", f32(y)), Prop("Z", "Float", f32(z)),
                 Prop("W", "Float", f32(w or 1.0))})
end

local function dbg(pairs_)
  local out = {}
  for k, p in ipairs(pairs_) do out[k] = Struct({Prop("type", "String", p[1]), Prop("s", "String", S(p[2]))}) end
  return TR.Array(out)
end

local function rot(r)
  if not P.T(r) then r = {0, 0, 0} end
  local out, any = {}, false
  for k, x in ipairs(r) do
    out[k] = GEN.float(x)
    if out[k] ~= 0 then any = true end
  end
  return any and out or nil
end

local function floats(list, n)
  local out = {}
  for k = 1, n or #list do out[k] = GEN.float(list[k]) end
  return out
end

-- q.get(k, default) as Python has it (a null stays None)
local function raw(d, k, default)
  if type(d) ~= "table" or d == Y.null then return default end
  local v = d[k]
  if v == nil then return default end
  return v
end
local need = GEN.need
local function items(d)
  local out = {}
  if Y.is_map(d) then for k, v in pairs(d) do out[#out + 1] = {k, v} end end
  return out
end

function LE.Ctx(quest, dlc, template, repo)
  local worlds = Y.read(repo .. "\\worlds.repo.yml")
  local acts = Y.read(repo .. "\\all.actions.repo.yml")
  return {quest = quest, dlc = dlc, template = template, worlds = worlds.repository.worlds,
          actions = acts.repository.actions}
end

local Enc = {}
Enc.__index = Enc
function LE.Encoder(ctx) return setmetatable({ctx = ctx}, Enc) end

function Enc:tree()
  local t = TR.Tree(self.ctx.template)
  t.objects, t.f.imports, t.f.buffers = {}, {}, {}
  return t
end

local function add(t, cls, flags, parent, props, template, rest)
  local list = {}
  for k, p in ipairs(props) do list[k] = Prop(p[1], p[2], p[3]) end
  t.objects[#t.objects + 1] = TR.Obj(cls, flags, parent, template or 0, list, nil, rest or "")
  return #t.objects
end

local function imp(t, path, cls)
  for k, im in ipairs(t.f.imports) do
    if im[1] == path and im[2] == cls then return k end
  end
  t.f.imports[#t.f.imports + 1] = {path, cls, 0}
  return #t.f.imports
end

function Enc:folder(world, layer)
  local w = (world ~= nil and world ~= Y.null) and raw(self.ctx.worlds, world) or nil
  local level = S(P.get(w, "level", "levels/" .. S(world) .. "/")):gsub("/", "\\")
  level = level:gsub("^\\+", ""):gsub("\\+$", "")
  return "dlc\\" .. S(self.ctx.dlc) .. "\\" .. level .. "\\" .. S(self.ctx.quest) .. "\\" .. S(layer)
end

function Enc:layer_tag(layer) return "radish_layer_" .. S(self.ctx.quest) .. "_" .. S(layer) end

-- a place's objects
function Enc:statics(name, layer)
  local t = self:tree()
  local root = add(t, "CLayer", LAYER, 0, {{"entities", "array:32,0,ptr:CEntity", TR.Array({})}})
  local made = {}
  for _, kv in ipairs(items(P.or_(raw(layer, "statics"), Y.map()))) do
    local oid, o = kv[1], kv[2]
    local template = S(need(o, "template"))
    local k = imp(t, template, "CEntityTemplate")
    local tags = {}
    for _, x in ipairs(P.T(raw(o, "tags")) and o.tags or {}) do tags[#tags + 1] = S(x) end
    tags[#tags + 1] = self:layer_tag(name)
    made[#made + 1] = add(t, "CEntity", STATIC, root, {
      {"template", "handle:CEntityTemplate", -k},
      {"transform", "EngineTransform", TR.Transform(floats(need(o, "pos")), rot(raw(o, "rot")), nil)},
      {"tags", "TagList", TR.Tags(tags)},
      {"dbgInfo", "array:2,0,SDbgInfo", dbg({{"preset", ".entity"}, {"type", "layer_static"}, {"id", oid},
                                             {"questid", self.ctx.quest}, {"layername", name}, {"class", "CEntity"},
                                             {"template", template}})}},
      (-k) & 0xFFFFFFFF, string.rep("\0", 14))
  end
  t:obj(root):set("entities", TR.Array(made))
  return t:to_bytes()
end

-- an entity's data after its properties: 8 zero bytes, its components (a count, a handle each), 2 zero bytes
local function t_rest(t, n, component)
  t:obj(n).rest = string.rep("\0", 8) .. "\1" .. string.pack("<i4", component) .. "\0\0"
end

-- the quest's meta layer of a world: one file per kind
function Enc:meta(name, layer, kind)
  local world = need(layer, "world")
  local t = self:tree()
  local root = add(t, "CLayer", LAYER, 0, {{"entities", "array:32,0,ptr:CEntity", TR.Array({})}})
  local made = {}
  for _, kv in ipairs(items(P.or_(raw(layer, kind), Y.map()))) do
    local oid, spec = kv[1], kv[2]
    local tag = S(self.ctx.quest) .. "_" .. S(world) .. "_" .. S(oid) .. "_" .. LE.SUFFIX[kind]
    local d = {{"type", LE.KIND[kind]}, {"id", oid}, {"questid", self.ctx.quest}, {"layername", name}}
    local cls, comp = "CEntity", nil
    local pos, r, pts, cx, cy, cz, a
    if kind == "areas" then
      pts = {}
      for i, p in ipairs(need(spec, "borderpoints")) do
        local q = {}
        for j, v in ipairs(p) do q[j] = f32(v) end
        pts[i] = q
      end
      local cols = {{}, {}, {}}
      for _, p in ipairs(pts) do for i = 1, 3 do cols[i][#cols[i] + 1] = p[i] end end
      cx, cy, cz = mean32(cols[1]), mean32(cols[2]), mean32(cols[3])
      pos, r = {cx, cy, cz}, nil
    elseif kind == "actionpoints" then
      pos, r = floats(need(spec, "pos")), rot(raw(spec, "rot"))
      local action = S(need(spec, "action"))
      local slash = action:find("/", 1, true)
      local cat, act = action, ""
      if slash then cat, act = action:sub(1, slash - 1), action:sub(slash + 1) end
      a = P.or_(raw(P.or_(raw(self.ctx.actions, cat), Y.map()), act), Y.map())
      d[#d + 1] = {"action", act}
      d[#d + 1] = {"category", cat}
      cls = "CActionPoint"
    elseif kind == "scenepoints" then
      pos, r = floats(spec, 3), rot(#spec > 3 and {0, 0, spec[4]} or nil)
    else                                          -- mappins
      pos, r = floats(spec, 3), nil
      cls = "CGameplayEntity"
    end
    local props = {{"tags", "TagList", TR.Tags({tag, self:layer_tag(name)})},
                   {"transform", "EngineTransform", TR.Transform(pos, r, nil)},
                   {"guid", "CGUID", TR.new_guid()}, {"streamingDistance", "Uint8", 0},
                   {"dbgInfo", "array:2,0,SDbgInfo", dbg(d)}}
    if kind == "actionpoints" or kind == "mappins" then
      props[#props + 1] = {"idTag", "IdTag", TR.Raw("\0" .. TR.new_guid().b)}
    end
    local n = add(t, cls, LAYER, root, props)
    local c = n + 1                               -- its one component, right after it
    t_rest(t, n, c)
    if kind == "areas" then
      local xs, ys, zs = {}, {}, {}
      for i, p in ipairs(pts) do xs[i], ys[i], zs[i] = p[1], p[2], p[3] end
      local height = GEN.float(raw(spec, "height", 2.0))
      local locals, worlds = {}, {}
      for i, p in ipairs(pts) do
        locals[i] = vec(f32(p[1] - cx), f32(p[2] - cy), f32(p[3] - cz))
        worlds[i] = vec(p[1], p[2], p[3], p[4])
      end
      comp = add(t, "CTriggerAreaComponent", LAYER, n, {
        {"transform", "EngineTransform", TR.Transform(nil, nil, {1.0, 1.0, 1.0})},
        {"guid", "CGUID", TR.new_guid()}, {"name", "String", S(oid)},
        {"boundingBox", "Box", Struct({Prop("Min", "Vector", vec(math.min(table.unpack(xs)), math.min(table.unpack(ys)),
                                                                     math.min(table.unpack(zs)))),
                                       Prop("Max", "Vector", vec(math.max(table.unpack(xs)), math.max(table.unpack(ys)),
                                                                     math.max(table.unpack(zs)) + height))})},
        {"height", "Float", height},
        {"localPoints", "array:2,0,Vector", TR.Array(locals)},
        {"worldPoints", "array:2,0,Vector", TR.Array(worlds)}}, 0, string.rep("\0", 12))
    elseif kind == "actionpoints" then
      local job = S(P.get(a, "file", "")):gsub("/", "\\")
      comp = add(t, "CActionPointComponent", LAYER, n, {
        {"guid", "CGUID", TR.new_guid()}, {"name", "String", S(P.get(a, "place", ""))},
        {"jobTreeRes", "handle:CJobTree", -imp(t, job, "CJobTree")}}, 0, string.rep("\0", 8))
    elseif kind == "scenepoints" then
      comp = add(t, "CStorySceneWaypointComponent", LAYER, n, {
        {"guid", "CGUID", TR.new_guid()}, {"name", "String", S(oid)}}, 0, string.rep("\0", 8))
    else
      comp = add(t, "CWayPointComponent", LAYER, n, {
        {"guid", "CGUID", TR.new_guid()}, {"name", "String", S(oid)}}, 0, string.rep("\0", 8))
    end
    assert(comp == c)
    made[#made + 1] = n
  end
  t:obj(root):set("entities", TR.Array(made))
  return t:to_bytes()
end

function LE.encode(layers, ctx)
  local e = LE.Encoder(ctx)
  local out = Y.map()
  for _, kv in ipairs(items(P.or_(raw(P.or_(layers, Y.map()), "layers"), Y.map()))) do
    local name, layer = kv[1], kv[2]
    local world = raw(layer, "world")
    if P.T(raw(layer, "statics")) then out[e:folder(world, name) .. "\\static.w2l"] = e:statics(name, layer) end
    for _, mf in ipairs(LE.META_FILES) do
      if P.T(raw(layer, mf[1])) then out[e:folder(world, name) .. "\\" .. mf[2]] = e:meta(name, layer, mf[1]) end
    end
  end
  return out
end

return LE
