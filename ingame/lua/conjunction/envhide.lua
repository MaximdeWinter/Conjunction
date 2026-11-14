-- Areas where the game's own terrain, foliage or water is not drawn (envhide.py): the place object a hide area is.
--   EH.area_object(world_points, height, foliage, terrain, water, oid) -> the object (a yaml map)
local Y = require("conjunction.yaml")
local NUM = require("conjunction.pynum")
local EH = {}

EH.TEMPLATE = "cj_envhide"        -- what a hide area object names as its template until the build makes its entity

-- a place object from an outline drawn in the world ({x, y, z} points): placed at their centre, on the lowest of
-- them, the outline kept relative to it
function EH.area_object(world_points, height, foliage, terrain, water, oid)
  if #world_points < 3 then error("A hide area needs at least three points") end
  local xs, ys = {}, {}
  local z
  for i, p in ipairs(world_points) do
    xs[i], ys[i] = p[1], p[2]
    if z == nil or p[3] < z then z = p[3] end
  end
  local cx, cy = NUM.sum(xs) / #world_points, NUM.sum(ys) / #world_points
  local pts = Y.list()
  for i, p in ipairs(world_points) do pts[i] = Y.list({NUM.round(p[1] - cx, 3), NUM.round(p[2] - cy, 3)}) end
  local o = Y.map({"envhide", Y.map({"points", pts, "height", (height or 20.0) + 0.0, "foliage", foliage ~= false,
                                     "terrain", terrain == true, "water", water == true}),
                   "pos", Y.list({NUM.round(cx, 3), NUM.round(cy, 3), NUM.round(z - 1.0, 3)}),
                   "rot", Y.list({0.0, 0.0, 0.0}), "template", EH.TEMPLATE, "actor", false})
  if oid and oid ~= Y.null and oid ~= "" then o.id = oid end
  return o
end

return EH
