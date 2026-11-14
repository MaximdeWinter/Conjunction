-- Selecting by the objects' real size (picking.py): every placed object is a box, turned as it stands; a click is a
-- ray from the camera. Of the boxes the ray goes through the nearest wins, unless a smaller one lies in it along the
-- ray (a cup on a table). Boxes: Documents\Conjunction\data\bounds.json, the app's cache (template -> box or null).
local J = require("conjunction.json")
local PYS = require("conjunction.pystr")   -- (Python's str.lower: umlauts too)
local Y = require("conjunction.yaml")
local PATHS = require("conjunction.paths")
local PK = {}
PK.CACHE = PATHS.DATA .. "\\bounds.json"
PK.PERSON = {-0.35, -0.35, 0.0, 0.35, 0.35, 1.85}
PK.SMALL = {-0.25, -0.25, 0.0, 0.25, 0.25, 0.5}
local cache

local function load()
  if cache == nil then
    local ok, d = pcall(J.read, PK.CACHE)
    cache = (ok and Y.is_map(d)) and d or Y.map()
  end
  return cache
end
function PK.reload() cache = nil end

-- a point turned as the game turns things: roll around y, pitch around x, yaw around z (degrees)
function PK.turn(x, y, z, roll, pitch, yaw)
  local cy, sy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
  local cp, sp = math.cos(math.rad(pitch)), math.sin(math.rad(pitch))
  local cr, sr = math.cos(math.rad(roll)), math.sin(math.rad(roll))
  x, z = x * cr + z * sr, -x * sr + z * cr
  y, z = y * cp - z * sp, y * sp + z * cp
  x, y = x * cy - y * sy, x * sy + y * cy
  return x, y, z
end
function PK.unturn(x, y, z, roll, pitch, yaw)
  local cy, sy = math.cos(math.rad(-yaw)), math.sin(math.rad(-yaw))
  local cp, sp = math.cos(math.rad(-pitch)), math.sin(math.rad(-pitch))
  local cr, sr = math.cos(math.rad(-roll)), math.sin(math.rad(-roll))
  x, y = x * cy - y * sy, x * sy + y * cy
  y, z = y * cp - z * sp, y * sp + z * cp
  x, z = x * cr + z * sr, -x * sr + z * cr
  return x, y, z
end

-- the box of a placed object in its own axes (known, or the stand-in)
function PK.box_of(o, actor)
  if actor then return PK.PERSON end
  local t = PYS.lower(o.template)
  local b = load()[t]
  if type(b) == "table" and b ~= Y.null then return b end
  if b == Y.null and (t:find("npc_entities", 1, true) or t:find("\\monsters\\", 1, true) or t:find("\\animals\\", 1, true)) then
    return PK.PERSON
  end
  return PK.SMALL
end

-- the boxes of templates not known yet: the app reads them from the game's files; in the game the editor sets this
PK.prepare = function(_templates) end

-- (entry, exit) distances of the ray through the object's turned box, or nil
function PK.ray_box(origin, dir, o, box)
  local rot = o.rot or {0, 0, 0}
  local p = o.pos
  local ox, oy, oz = PK.unturn(origin[1] - p[1], origin[2] - p[2], origin[3] - p[3], rot[1], rot[2], rot[3])
  local dx, dy, dz = PK.unturn(dir[1], dir[2], dir[3], rot[1], rot[2], rot[3])
  local t0, t1 = -math.huge, math.huge
  for _, axis in ipairs({{ox, dx, box[1], box[4]}, {oy, dy, box[2], box[5]}, {oz, dz, box[3], box[6]}}) do
    local s, d, lo, hi = axis[1], axis[2], axis[3], axis[4]
    if math.abs(d) < 1e-9 then
      if s < lo or s > hi then return nil end
    else
      local a, b = (lo - s) / d, (hi - s) / d
      t0, t1 = math.max(t0, math.min(a, b)), math.min(t1, math.max(a, b))
      if t0 > t1 then return nil end
    end
  end
  if t1 < 0 then return nil end
  return math.max(t0, 0.0), t1
end

-- Python's tuple order of (entry, exit, volume, pos): the hits sorted as hits.sort() does
local function less(a, b)
  for i = 1, 3 do if a[i] ~= b[i] then return a[i] < b[i] end end
  for i = 1, math.max(#a[4], #b[4]) do
    local x, y = a[4][i], b[4][i]
    if x == nil then return true end
    if y == nil then return false end
    if x ~= y then return x < y end
  end
  return false
end

-- the position of the object the ray selects, or nil
function PK.pick(origin, dir, objects, is_actor)
  local hits = {}
  for _, o in ipairs(objects) do
    local box = PK.box_of(o, is_actor(o))
    local r0, r1 = PK.ray_box(origin, dir, o, box)
    if r0 then
      local vol = (box[4] - box[1]) * (box[5] - box[2]) * (box[6] - box[3])
      hits[#hits + 1] = {r0, r1, vol, o.pos}
    end
  end
  if #hits == 0 then return nil end
  table.sort(hits, less)        -- (stable enough: equal tuples are equal positions)
  local near = hits[1]
  local best
  for _, h in ipairs(hits) do
    if h[1] <= near[2] then
      if best == nil or h[3] < best[3] or (h[3] == best[3] and h[1] < best[1]) then best = h end
    end
  end
  return best[4]
end
return PK
