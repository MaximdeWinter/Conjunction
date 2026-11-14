-- The world's shape for an agent that cannot look well (MaximdeWinter 01.11.: "ohne visuelles, schlechtes Bild gut Sachen
-- platzieren, die auch richtig stehen"): what is around a point, what stands near, whether a person stands right,
-- whether a box fits - measured with the game's own rays and heights (w3.world.trace / ground / nav_z / water /
-- safe_spot, w3.near). The app adds the sizes of templates (conjunction/agent.py: world_objects, world_fit).
--   commands: world_probe, world_entities, world_person, world_fit, scene_check
local WS = {}

local DIRS = 16
local CHEST, HEAD = 1.2, 1.75

local function V(x, y, z) return {X = x, Y = y, Z = z, W = 1} end
local function r2(v) return v and math.floor(v * 100 + 0.5) / 100 or nil end

-- the heading of a yaw as the game turns things (VecFromHeading): yaw 0 looks north (+y), it grows anticlockwise
local function heading(yaw)
  local a = math.rad(yaw or 0)
  return -math.sin(a), math.cos(a)
end
WS.heading = heading

local function compass(dx, dy)
  local names = {"north", "north-west", "west", "south-west", "south", "south-east", "east", "north-east"}
  local a = math.deg(math.atan(-dx, dy)) % 360          -- (anticlockwise from north, as yaw)
  return names[math.floor((a + 22.5) / 45) % 8 + 1]
end

local function trace(a, b)
  local ok, hit, pos, normal = pcall(w3.world.trace, a, b)
  if ok and hit and pos then return pos, normal end
  return nil
end

local function ground(x, y, z)
  local ok, g = pcall(w3.world.ground, V(x, y, z + 1.0))
  if ok and g then return g end
  local p = trace(V(x, y, z + 2.0), V(x, y, z - 30.0))
  return p and p.Z or nil
end

local function pos_of(a)
  if a.x and a.y then
    local z = a.z
    if not z then
      local pl = w3.player():GetWorldPosition()
      z = ground(a.x, a.y, pl.Z + 20) or pl.Z
    end
    return a.x, a.y, z
  end
  local p = w3.player():GetWorldPosition()
  return p.X, p.Y, p.Z
end

-- the space around a point: its ground, the walls around at chest height, the ceiling, water, the slope, a sentence
function WS.probe(x, y, z, radius)
  radius = radius or 8
  local g = ground(x, y, z) or z
  local okn, nav = pcall(w3.world.nav_z, V(x, y, g), 1.5, 1.5)
  local okw, wl, wd = pcall(w3.world.water, V(x, y, g))
  local _, normal = trace(V(x, y, g + 1.0), V(x, y, g - 1.0))
  local slope = normal and math.deg(math.acos(math.max(-1, math.min(1, normal.Z)))) or nil
  local up = trace(V(x, y, g + 0.3), V(x, y, g + 40))
  local walls, hits = {}, 0
  for k = 0, DIRS - 1 do
    local a = math.rad(k * 360 / DIRS)
    local dx, dy = -math.sin(a), math.cos(a)
    local function dist(h)
      local p = trace(V(x, y, g + h), V(x + dx * radius, y + dy * radius, g + h))
      return p and math.sqrt((p.X - x) ^ 2 + (p.Y - y) ^ 2) or nil
    end
    local knee, chest, head = dist(0.4), dist(CHEST), dist(1.9)
    local d = math.min(knee or 1e9, chest or 1e9, head or 1e9)
    local w = {dir = compass(dx, dy), deg = k * 360 / DIRS}
    if d < 1e9 then
      -- what it is: the ground a little behind where the ray hit, and the heights it hits at
      local gb = ground(x + dx * (d + 0.35), y + dy * (d + 0.35), g + 2.5)
      local rise = gb and gb - g or nil
      w.dist = r2(d)
      if head and chest and math.abs(head - chest) < 0.6 and (not rise or rise > 1.6 or rise < 0.2) then
        w.kind, w.wall = "wall", r2(d)
        hits = hits + 1
      elseif rise and rise >= 0.15 and rise <= 1.6 then
        w.kind, w.rise = "steps up", r2(rise)
      elseif knee and not chest then
        w.kind = "low (a step, a crate, a fence)"
      else
        w.kind, w.wall = "wall", r2(d)
        hits = hits + 1
      end
    end
    walls[#walls + 1] = w
  end
  local function d_at(deg)
    for _, w in ipairs(walls) do if w.deg == deg then return w.wall end end
  end
  local ceiling = up and r2(up.Z - g) or nil
  local inside = ceiling ~= nil and ceiling < 8 and hits >= DIRS * 0.75
  local out = {at = {r2(x), r2(y), r2(g)}, ground = r2(g), navmesh = okn and nav ~= nil and math.abs(nav - g) < 0.75,
               ceiling = ceiling,
               slope = slope and r2(slope) or nil, water = okw and wd and wd > 0.05 and r2(wd) or nil, walls = walls,
               inside = inside}
  local say = {}
  if inside then
    local ns, ew = (d_at(0) or radius) + (d_at(180) or radius), (d_at(90) or radius) + (d_at(270) or radius)
    out.room = {north_south = r2(ns), east_west = r2(ew)}
    say[#say + 1] = string.format("inside a room about %.1f m (north-south) by %.1f m (east-west), ceiling %.1f m",
                                  ns, ew, ceiling)
  elseif ceiling then
    say[#say + 1] = string.format("under a roof or a beam %.1f m up", ceiling)
  else
    say[#say + 1] = "outside, open sky"
  end
  local near, steps
  for _, w in ipairs(walls) do
    if w.wall and (not near or w.wall < near.wall) then near = w end
    if w.kind == "steps up" and (not steps or w.dist < steps.dist) then steps = w end
  end
  if near then say[#say + 1] = string.format("nearest wall %.1f m %s", near.wall, near.dir) end
  if steps then say[#say + 1] = string.format("steps up %.1f m %s (%.1f m higher)", steps.dist, steps.dir, steps.rise) end
  if out.water then say[#say + 1] = string.format("water %.1f m deep", out.water) end
  if out.slope and out.slope > 20 then say[#say + 1] = string.format("steep ground (%.0f degrees)", out.slope) end
  say[#say + 1] = out.navmesh and "people can walk here" or "people cannot walk here (no navmesh)"
  out.say = table.concat(say, "; ")
  return out
end

-- the template an entity was made from (nil: one the world's layers hold, without a template of its own)
local function template_of(e)
  local ok, path = pcall(function() return e:GetTemplatePathAndAppearance("", "") end)
  if ok and type(path) == "string" and path ~= "" then return path end
  return nil
end

function WS.entities(x, y, z, radius, limit)
  local okn, list = pcall(w3.near, V(x, y, z), radius or 10)
  local out = {}
  for _, e in ipairs(okn and list or {}) do
    local ok, p, r = pcall(function() return e:GetWorldPosition(), e:GetWorldRotation() end)
    if ok and p then
      local name
      pcall(function() name = e:GetDisplayName() end)
      if not name or name == "" then pcall(function() name = tostring(e:GetReadableName()) end) end
      local tags
      pcall(function() tags = e:GetTags() end)
      out[#out + 1] = {class = w3.classof and w3.classof(e) or nil, name = name, template = template_of(e),
                       tags = type(tags) == "table" and tags or nil,
                       pos = {r2(p.X), r2(p.Y), r2(p.Z)}, rot = {r2(r.Roll or 0), r2(r.Pitch or 0), r2(r.Yaw or 0)},
                       dist = r2(math.sqrt((p.X - x) ^ 2 + (p.Y - y) ^ 2 + (p.Z - z) ^ 2))}
    end
  end
  table.sort(out, function(a, b) return a.dist < b.dist end)
  while #out > (limit or 60) do table.remove(out) end
  return out
end

-- does a person stand right: upright, on the ground (not floating, not sunk), out of walls and ceilings, turned
-- towards `toward` ({x, y}) -> {ok, problems = {...}, ...}
function WS.person(e, toward)
  local p, r = e:GetWorldPosition(), e:GetWorldRotation()
  local out = {pos = {r2(p.X), r2(p.Y), r2(p.Z)}, yaw = r2(r.Yaw or 0), problems = {}}
  local function bad(s) out.problems[#out.problems + 1] = s end
  local tilt = math.max(math.abs(r.Pitch or 0), math.abs(r.Roll or 0))
  out.tilt = r2(tilt)
  if tilt > 8 then bad(string.format("tilted %.0f degrees (pitch %.0f, roll %.0f)", tilt, r.Pitch or 0, r.Roll or 0)) end
  local g = ground(p.X, p.Y, p.Z)
  out.ground = r2(g)
  if g then
    local gap = p.Z - g
    out.gap = r2(gap)
    if gap > 0.15 then bad(string.format("floats %.2f m above the ground", gap)) end
    if gap < -0.15 then bad(string.format("stands %.2f m in the ground", -gap)) end
  end
  local okn, nav = pcall(w3.world.nav_z, p, 1.0, 1.0)
  out.navmesh = okn and nav ~= nil and math.abs(nav - p.Z) < 0.75
  local closest, cd
  for k = 0, 7 do                               -- (the side it is nearest to: where it sticks in)
    local a = math.rad(k * 45)
    local dx, dy = -math.sin(a), math.cos(a)
    local hp = trace(V(p.X, p.Y, p.Z + CHEST), V(p.X + dx * 0.28, p.Y + dy * 0.28, p.Z + CHEST))
    local d = hp and math.sqrt((hp.X - p.X) ^ 2 + (hp.Y - p.Y) ^ 2)
    if d and (not cd or d < cd) then closest, cd = compass(dx, dy), d end
  end
  if closest then bad("in a wall or an object (" .. closest .. ")") end
  local through = trace(V(p.X, p.Y, p.Z + HEAD), V(p.X, p.Y, p.Z + 0.4))
  if through then bad(string.format("something goes through them at %.1f m", through.Z - p.Z)) end
  local top = trace(V(p.X, p.Y, p.Z + 1.0), V(p.X, p.Y, p.Z + 2.0))
  if top then bad(string.format("the head is in a ceiling (%.2f m up)", top.Z - p.Z)) end
  if toward then
    local hx, hy = heading(r.Yaw)
    local dx, dy = toward[1] - p.X, toward[2] - p.Y
    local n = math.sqrt(dx * dx + dy * dy)
    if n > 0.01 then
      local ang = math.deg(math.acos(math.max(-1, math.min(1, (hx * dx + hy * dy) / n))))
      out.facing_off = r2(ang)
      if ang > 35 then bad(string.format("looks %.0f degrees away from where it should", ang)) end
    end
  end
  out.ok = #out.problems == 0
  return out
end

-- does a box fit at a place: box = {min = {x, y, z}, max = {x, y, z}} in the thing's own axes, turned by yaw -> does it
-- rest on the ground (its corners), does it cut into the world (its edges), a free spot near when it does not
function WS.fit(x, y, z, yaw, box, no_search)
  local mn, mx = box.min, box.max
  local c, s = math.cos(math.rad(yaw or 0)), math.sin(math.rad(yaw or 0))
  local function at(lx, ly, lz) return V(x + lx * c - ly * s, y + lx * s + ly * c, z + lz) end
  local out = {problems = {}}
  local function bad(t) out.problems[#out.problems + 1] = t end
  local under = {}
  for _, q in ipairs({{mn[1], mn[2]}, {mx[1], mn[2]}, {mx[1], mx[2]}, {mn[1], mx[2]}}) do
    local p = at(q[1], q[2], mn[3])
    local g = ground(p.X, p.Y, p.Z + 0.5)
    under[#under + 1] = g and r2(p.Z - g) or nil
  end
  out.corners_above_ground = under
  local hi, lo = -1e9, 1e9
  for _, u in ipairs(under) do if u then hi, lo = math.max(hi, u), math.min(lo, u) end end
  if hi > 0.12 then bad(string.format("a corner floats %.2f m above the ground", hi)) end
  if lo < -0.25 then bad(string.format("a corner is %.2f m in the ground", -lo)) end
  local mid = (mn[3] + mx[3]) / 2
  local lift = math.min(0.25, (mx[3] - mn[3]) / 3)     -- (edges a little above the floor: the ground itself is no wall)
  local cuts = {}
  local corners = {{mn[1], mn[2]}, {mx[1], mn[2]}, {mx[1], mx[2]}, {mn[1], mx[2]}}
  for _, h in ipairs({mn[3] + lift, mid, mx[3] - 0.02}) do
    for k = 1, 4 do
      local a, b = corners[k], corners[k % 4 + 1]
      local p = trace(at(a[1], a[2], h), at(b[1], b[2], h))
      if p then cuts[#cuts + 1] = {r2(p.X), r2(p.Y), r2(p.Z)} end
    end
  end
  for _, d in ipairs({{corners[1], corners[3]}, {corners[2], corners[4]}}) do
    local p = trace(at(d[1][1], d[1][2], mid), at(d[2][1], d[2][2], mid))
    if p then cuts[#cuts + 1] = {r2(p.X), r2(p.Y), r2(p.Z)} end
  end
  if #cuts > 0 then
    out.cuts = cuts
    bad(string.format("cuts into the world at %d place(s), first at (%.2f, %.2f, %.2f)", #cuts, cuts[1][1], cuts[1][2],
                      cuts[1][3]))
  end
  out.ok = #out.problems == 0
  if not out.ok and not no_search then
    -- the nearest spot where it fits, by the same test: rings around the point (0.5 m apart), turned as asked
    for ring = 1, 8 do
      local rr = ring * 0.5
      local n = math.max(8, ring * 6)
      for k = 0, n - 1 do
        local a = 2 * math.pi * k / n
        local cx, cy = x + math.cos(a) * rr, y + math.sin(a) * rr
        local cz = ground(cx, cy, z + 1.5)
        if cz and math.abs(cz - z) < 2.0 then
          local f = WS.fit(cx, cy, cz, yaw, box, true)
          if f.ok then
            out.free_spot = {r2(cx), r2(cy), r2(cz)}
            return out
          end
        end
      end
    end
  end
  return out
end

-- the surface of a thing as rays from above find it: a grid over its box (n x n, in its own axes, turned by yaw) ->
-- heights above the floor, the main surface (the height most of its middle has: a seat, a mattress, a table top), how
-- much of it is flat at that height, and its extent there
function WS.surface(x, y, z, yaw, box, n)
  n = n or 7
  local mn, mx = box.min, box.max
  local c, s = math.cos(math.rad(yaw or 0)), math.sin(math.rad(yaw or 0))
  local top = z + mx[3] + 0.4
  local floor = z + mn[3]                      -- (furniture stands on the floor: its mesh's bottom; the ground under
                                               -- its middle would be its own seat)
  local grid, hs = {}, {}
  for i = 0, n - 1 do
    local row = {}
    for j = 0, n - 1 do
      local lx = mn[1] + (mx[1] - mn[1]) * (i + 0.5) / n
      local ly = mn[2] + (mx[2] - mn[2]) * (j + 0.5) / n
      local wx, wy = x + lx * c - ly * s, y + lx * s + ly * c
      local hit = trace(V(wx, wy, top), V(wx, wy, floor - 0.2))
      local h = hit and r2(hit.Z - floor) or nil
      row[#row + 1] = h or false
      if h and h > 0.12 then hs[#hs + 1] = {h = h, lx = lx, ly = ly} end
    end
    grid[#grid + 1] = row
  end
  local out = {floor = r2(floor), grid = grid}
  if #hs == 0 then return out end
  -- the main surface: the height with the most points within 6 cm, the middle counting double
  local best, bestn
  for _, a in ipairs(hs) do
    local k = 0
    for _, b in ipairs(hs) do if math.abs(a.h - b.h) <= 0.06 then k = k + 1 end end
    if not bestn or k > bestn or (k == bestn and a.h < best) then best, bestn = a.h, k end
  end
  local x0, x1, y0, y1 = 1e9, -1e9, 1e9, -1e9
  for _, a in ipairs(hs) do
    if math.abs(a.h - best) <= 0.06 then
      x0, x1 = math.min(x0, a.lx), math.max(x1, a.lx)
      y0, y1 = math.min(y0, a.ly), math.max(y1, a.ly)
    end
  end
  local cell_x, cell_y = (mx[1] - mn[1]) / n, (mx[2] - mn[2]) / n
  out.surface = {height = r2(best), share = r2(bestn / (n * n)),
                 min = {r2(x0 - cell_x / 2), r2(y0 - cell_y / 2)}, max = {r2(x1 + cell_x / 2), r2(y1 + cell_y / 2)},
                 size = {r2(x1 - x0 + cell_x), r2(y1 - y0 + cell_y)}}
  return out
end

-- free floor near a point where a rectangle (w x d metres) lies flat and nothing stands in it up to `height`: rings
-- around the point, each spot turned by yaw -> {{x, y, z}} nearest first (at most `limit`)
function WS.floor(x, y, z, w, d, height, yaw, radius, limit)
  local box = {min = {-w / 2, -d / 2, 0}, max = {w / 2, d / 2, height or 1.8}}
  local out = {}
  local function try(cx, cy)
    local cz = ground(cx, cy, z + 1.5)
    if cz and math.abs(cz - z) < 1.5 then
      local f = WS.fit(cx, cy, cz, yaw or 0, box, true)
      if f.ok then out[#out + 1] = {r2(cx), r2(cy), r2(cz)} end
    end
  end
  try(x, y)
  for ring = 1, math.floor((radius or 6) / 0.75) do
    if #out >= (limit or 6) then break end
    local rr = ring * 0.75
    local n = math.max(8, ring * 6)
    for k = 0, n - 1 do
      if #out >= (limit or 6) then break end
      local a = 2 * math.pi * k / n
      try(x + math.cos(a) * rr, y + math.sin(a) * rr)
    end
  end
  return out
end

-- the shape of an animation, measured on a figure (w3.anim.sample at a few times): where its body is relative to the
-- figure's own origin (x right, y forward, z up) - pelvis and head heights, the lowest point of the body, the extent
-- on the floor - and the posture that follows from them. nil, "" while its data streams in.
WS.BODY = {"pelvis", "torso", "torso2", "torso3", "neck", "head", "l_thigh", "r_thigh", "l_shin", "r_shin", "l_foot",
           "r_foot", "l_shoulder", "r_shoulder", "l_forearm", "r_forearm", "l_hand", "r_hand"}
-- how fast a walk or run cycle goes: the foot on the ground moves back at the speed the body goes forward (the bones
-- are in the figure's own space, the root stays) -> {speed (m/s), forward = {x, y} (the way it goes in its space), length}
function WS.anim_gait(e, name, length)
  -- its length as the figure has it (02.11.: the depot's list keeps one length per name, and the same name in another
  -- animation set gave the slow walk 5.33 s instead of 1.23 s - a fifth of its speed); the given one only without
  do
    local ok, p, why = pcall(w3.anim.sample, e, name, 0.0)
    if not ok then return nil, tostring(p) end
    if not p then return nil, why or "" end
    length = tonumber(p.duration) or length or 1.2
  end
  local fps = 30
  local feet = {l_foot = {}, r_foot = {}}
  local traj, pel = {}, {}                      -- (the game's walk cycles carry their way in the Trajectory bone)
  for k = 0, math.floor(length * fps) do
    local ok, p, why = pcall(w3.anim.sample, e, name, math.min(length, k / fps))
    if not ok then return nil, tostring(p) end
    if not p then return nil, why or "" end
    for _, b in ipairs(p.bones or {}) do
      if feet[b.name] then feet[b.name][#feet[b.name] + 1] = {b.x, b.y, b.z} end
      if b.name == "Trajectory" then traj[#traj + 1] = {b.x, b.y, b.z} end
      if b.name == "pelvis" then pel[#pel + 1] = {b.x, b.y, b.z} end
    end
  end
  -- up: from the Trajectory to the pelvis. The walk cycles have it along z; the run cycles come with their frame
  -- turned (02.11.: up along -y, the way along +z), so the way and the feet's height are taken along that up
  local up = {0, 0, 1}
  if #pel == #traj and #traj > 0 then
    local s = {0, 0, 0}
    for k = 1, #traj do for i = 1, 3 do s[i] = s[i] + pel[k][i] - traj[k][i] end end
    local n = math.sqrt(s[1] ^ 2 + s[2] ^ 2 + s[3] ^ 2)
    if n > 0.3 then up = {s[1] / n, s[2] / n, s[3] / n} end
  end
  local turned = up[3] < 0.9
  local function height(p) return p[1] * up[1] + p[2] * up[2] + p[3] * up[3] end
  local function flat(dx, dy, dz)               -- (a move without its part along up)
    local h = dx * up[1] + dy * up[2] + dz * up[3]
    return dx - h * up[1], dy - h * up[2], dz - h * up[3]
  end
  if #traj > 2 then
    local dx, dy, dz = flat(traj[#traj][1] - traj[1][1], traj[#traj][2] - traj[1][2], traj[#traj][3] - traj[1][3])
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d > 0.2 then                             -- (carried: the cycle moves the figure itself)
      local g = {speed = r2(d / ((#traj - 1) / fps)), forward = turned and {0, 1} or {r2(dx / d), r2(dy / d)},
                 length = length, carried = true, slip = {}}
      if turned then g.up = {r2(up[1]), r2(up[2]), r2(up[3])} end
      -- (how fast each foot on the ground still moves in the cycle itself, as scene_measure takes it: frames within
      -- 3 cm of its lowest, the middle speed - 02.11.: the jog's right foot slides 0.3 m/s as the game made it)
      for foot, track in pairs(feet) do
        local low, sp = 1e9, {}
        for _, f in ipairs(track) do low = math.min(low, height(f)) end
        for k = 2, #track do
          local a, b = track[k - 1], track[k]
          if height(a) < low + 0.03 and height(b) < low + 0.03 then
            local mx, my, mz = flat(b[1] - a[1], b[2] - a[2], b[3] - a[3])
            sp[#sp + 1] = math.sqrt(mx * mx + my * my + mz * mz) * fps
          end
        end
        table.sort(sp)
        if #sp > 0 then g.slip[foot] = r2(sp[math.ceil(#sp / 2)]) end
      end
      return g
    end
  end
  local speeds, fx, fy = {}, 0, 0
  for _, track in pairs(feet) do
    local low = 1e9
    for _, f in ipairs(track) do low = math.min(low, height(f)) end
    for k = 2, #track do
      local a, b = track[k - 1], track[k]
      if height(a) < low + 0.04 and height(b) < low + 0.04 then          -- (both frames on the ground)
        local dx, dy = b[1] - a[1], b[2] - a[2]
        speeds[#speeds + 1] = math.sqrt(dx * dx + dy * dy) * fps
        fx, fy = fx - dx, fy - dy
      end
    end
  end
  if #speeds < 4 then return nil, "no foot stays on the ground long enough: not a walk or run cycle?" end
  table.sort(speeds)
  local n = math.sqrt(fx * fx + fy * fy)
  return {speed = r2(speeds[math.ceil(#speeds / 2)]), forward = {r2(n > 0 and fx / n or 0), r2(n > 0 and fy / n or 1)},
          length = length}
end

function WS.anim_shape(e, name, length)
  length = length or 4
  local want = {}
  for _, b in ipairs(WS.BODY) do want[b] = true end
  local samples = {}
  for _, f in ipairs({0.02, 0.25, 0.5, 0.75, 0.98}) do
    local ok, p, why = pcall(w3.anim.sample, e, name, length * f)
    if not ok then return nil, tostring(p) end
    if not p then return nil, why or "" end
    samples[#samples + 1] = p
  end
  local pel, head, low, low_body = {}, {}, 1e9, 1e9
  local px, py, knee = {}, {}, {}
  local x0, x1, y0, y1 = 1e9, -1e9, 1e9, -1e9
  local seen = {}
  for _, p in ipairs(samples) do
    for _, b in ipairs(p.bones or {}) do
      local nm = b.name or ""
      if want[nm] then
        seen[nm] = true
        x0, x1, y0, y1 = math.min(x0, b.x), math.max(x1, b.x), math.min(y0, b.y), math.max(y1, b.y)
        low = math.min(low, b.z)
        if nm ~= "l_foot" and nm ~= "r_foot" and nm ~= "l_shin" and nm ~= "r_shin" then low_body = math.min(low_body, b.z) end
        if nm == "pelvis" then pel[#pel + 1], px[#px + 1], py[#py + 1] = b.z, b.x, b.y end
        if nm == "l_shin" or nm == "r_shin" then knee[#knee + 1] = b.z end     -- (a shin starts at its knee)
        if nm == "head" then head[#head + 1] = b.z end
      end
    end
  end
  if not next(seen) then return nil, "the figure's skeleton has none of the body's bones" end
  local function mean(t) local s = 0 for _, v in ipairs(t) do s = s + v end return #t > 0 and s / #t or nil end
  local pz, hz, kz = mean(pel), mean(head), mean(knee)
  local out = {pelvis = r2(pz), pelvis_at = {r2(mean(px)), r2(mean(py))}, head = r2(hz), knees = r2(kz),
               lowest = r2(low),
               lowest_body = r2(low_body),
               extent = {min = {r2(x0), r2(y0)}, max = {r2(x1), r2(y1)}, size = {r2(x1 - x0), r2(y1 - y0)}}}
  -- the posture (heights of a 1.8 m figure): standing head high; sitting pelvis at a seat's height, head between;
  -- kneeling pelvis low, head up; lying head low
  local posture
  if hz and hz > 1.35 then posture = "standing"
  elseif hz and hz < 0.75 then posture = "lying"
  elseif kz and kz < 0.22 then posture = "kneeling"          -- (knees on the floor: kneeling, on the heels too)
  elseif pz and pz >= 0.35 and pz <= 0.8 and (hz or 0) <= 1.35 then posture = "sitting"
  else posture = "kneeling" end
  out.posture = posture
  -- what it needs under it: a body that stays above the floor needs something to sit or lie on at that height
  if low > 0.2 and posture ~= "kneeling" then
    out.needs = {surface = r2(low - 0.08), why = "its whole body stays above the floor"}
  elseif posture == "sitting" and pz then
    out.needs = {seat = r2(pz - 0.1), why = "it sits: a seat at about the pelvis's height"}
  else
    out.needs = {floor = true}
  end
  return out
end

-- the things near a point as the world holds them: every mesh (furniture is mostly a mesh of a layer, without a template
-- of its own) with its box (the mesh's boundingBox, scaled as its component is) and where it stands; the action points
-- - the game's own places where people sit, sleep, lean, work - with their name and heading
WS.MESHES = {CStaticMeshComponent = true, CMeshComponent = true, CRigidMeshComponent = true}
function WS.things(x, y, z, radius, min_size, max_size)
  radius = radius or 8
  -- (a layer's entity holds many meshes, each placed on its own: the entities far around, each mesh by its own place)
  local okn, list = pcall(w3.near, V(x, y, z), radius + 40)
  local meshes, points = {}, {}
  for _, e in ipairs(okn and list or {}) do
    local okc, comps = pcall(function() return e.components end)
    for _, c in ipairs(okc and comps or {}) do
      local cl = w3.classof(c)
      if WS.MESHES[cl] then
        local ok, info = pcall(function()
          local bb = c.mesh.boundingBox
          local p, r = c:GetWorldPosition(), c:GetWorldRotation()
          local sc = c.transform and c.transform.scale or {X = 1, Y = 1, Z = 1}
          local mn = {bb.Min.X * (sc.X or 1), bb.Min.Y * (sc.Y or 1), bb.Min.Z * (sc.Z or 1)}
          local mx = {bb.Max.X * (sc.X or 1), bb.Max.Y * (sc.Y or 1), bb.Max.Z * (sc.Z or 1)}
          return {pos = {r2(p.X), r2(p.Y), r2(p.Z)}, rot = {r2(r.Roll or 0), r2(r.Pitch or 0), r2(r.Yaw or 0)},
                  box = {min = {r2(mn[1]), r2(mn[2]), r2(mn[3])}, max = {r2(mx[1]), r2(mx[2]), r2(mx[3])}},
                  size = {r2(mx[1] - mn[1]), r2(mx[2] - mn[2]), r2(mx[3] - mn[3])},
                  dist = r2(math.sqrt((p.X - x) ^ 2 + (p.Y - y) ^ 2 + (p.Z - z) ^ 2))}
        end)
        if ok and info and info.dist <= radius then
          local big = math.max(info.size[1], info.size[2], info.size[3])
          if big >= (min_size or 0.3) and big <= (max_size or 5.0) then meshes[#meshes + 1] = info end
        end
      elseif cl == "CActionPointComponent" then
        local ok, info = pcall(function()
          local p, r = c:GetWorldPosition(), c:GetWorldRotation()
          return {name = tostring(c.name or ""), pos = {r2(p.X), r2(p.Y), r2(p.Z)}, yaw = r2(r.Yaw or 0),
                  precise = tostring(c.placementImportance) == "WPI_Precise",
                  dist = r2(math.sqrt((p.X - x) ^ 2 + (p.Y - y) ^ 2 + (p.Z - z) ^ 2))}
        end)
        if ok and info and info.dist <= radius then points[#points + 1] = info end
      end
    end
  end
  table.sort(meshes, function(a, b) return a.dist < b.dist end)
  table.sort(points, function(a, b) return a.dist < b.dist end)
  return {meshes = meshes, points = points}
end

-- the room as a height map: rays straight down on a grid around a point (size metres square, step apart), from
-- `from` metres above its floor (below an upper storey) -> {floor, step, n, heights = {row by row, cm above the floor;
-- false: nothing hit}} - the app finds the flat places in it (room_sense.surfaces)
function WS.heightmap(x, y, z, size, step, from)
  size, step, from = size or 8, step or 0.15, from or 2.2
  local floor = ground(x, y, z) or z
  local n = math.floor(size / step) + 1
  local x0, y0 = x - size / 2, y - size / 2
  local hs = {}
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      local wx, wy = x0 + i * step, y0 + j * step
      local hit = trace(V(wx, wy, floor + from), V(wx, wy, floor - 1.0))
      hs[#hs + 1] = hit and math.floor((hit.Z - floor) * 100 + 0.5) or false
    end
  end
  return {floor = r2(floor), step = step, n = n, x0 = r2(x0), y0 = r2(y0), heights = hs}
end

function WS.register(C, DOC, body)
  DOC.world_probe = "The space around a point (x, y, z; default the player): ground, navmesh, ceiling, slope, water, " ..
                    "the walls in 16 directions at chest height (radius, default 8 m), a room's size, a sentence (say)"
  function C.world_probe(a)
    local x, y, z = pos_of(a)
    return WS.probe(x, y, z, a.radius)
  end

  DOC.world_entities = "What stands near a point (x, y, z; default the player), nearest first: class, name, " ..
                       "template, tags, pos, rot, dist (radius, default 10 m; limit)"
  function C.world_entities(a)
    local x, y, z = pos_of(a)
    return WS.entities(x, y, z, a.radius, a.limit)
  end

  local function figure(a)
    if a.actor and body then
      local okb, b = pcall(body)
      local e = okb and b and b.w and b.w:figure_of(a.actor)
      if e then return e end
    end
    if a.tag then
      local ok, e = pcall(function() return w3.global("theGame"):GetEntityByTag(a.tag) end)
      if ok and e then return e end
    end
    if a.player or not (a.actor or a.tag) then return w3.player() end
    error("nobody with " .. tostring(a.actor or a.tag) .. " here", 0)
  end

  DOC.world_person = "Does a person stand right (actor of the open scene, tag, or the player): upright, on the " ..
                     "ground, out of walls and ceilings, turned toward = {x, y} -> {ok, problems, pos, yaw, gap, tilt}"
  function C.world_person(a)
    local t = a.toward
    return WS.person(figure(a), t and {t.x or t[1], t.y or t[2]} or nil)
  end

  DOC.world_fit = "Does a box fit at x, y, z turned by yaw: box = {min = {x, y, z}, max = {x, y, z}} in its own axes " ..
                  "(the app's world_fit takes a template) -> {ok, problems, corners_above_ground, cuts, free_spot}"
  function C.world_fit(a)
    if not (a.box and a.box.min and a.box.max) then error("a box {min, max} is needed", 0) end
    local x, y, z = pos_of(a)
    return WS.fit(x, y, z, a.yaw or 0, a.box)
  end

  DOC.world_things = "The things near a point as the world holds them: meshes (furniture, walls' parts ...) with their " ..
                     "box, position and turn - sizes from min_size to max_size (default 0.3 - 5 m) - and the game's " ..
                     "action points (name: what people do there, ap_sitting_..., heading, precise)"
  function C.world_things(a)
    local x, y, z = pos_of(a)
    return WS.things(x, y, z, a.radius, a.min_size, a.max_size)
  end

  DOC.world_heightmap = "The room as a height map: rays down on a grid around a point (size, default 8 m square; step, " ..
                        "default 0.15 m; from: metres above the floor they start) -> heights in cm above the floor"
  function C.world_heightmap(a)
    local x, y, z = pos_of(a)
    return WS.heightmap(x, y, z, a.size, a.step, a.from)
  end

  DOC.world_sight = "Free sight from a point to others: from = {x, y, z}, to = {{x, y, z} ...} -> for each: clear, " ..
                    "and where the world is in the way"
  function C.world_sight(a)
    local f = a.from
    local fx, fy, fz = f.x or f[1], f.y or f[2], f.z or f[3]
    local out = {}
    for _, t in ipairs(a.to or {}) do
      local tx, ty, tz = t.x or t[1], t.y or t[2], t.z or t[3]
      -- (a little short of the point: a person's head is no wall)
      local dx, dy, dz = tx - fx, ty - fy, tz - fz
      local n = math.sqrt(dx * dx + dy * dy + dz * dz)
      local k = n > 0.4 and (n - 0.3) / n or 1
      local hit = trace(V(fx, fy, fz), V(fx + dx * k, fy + dy * k, fz + dz * k))
      out[#out + 1] = hit and {clear = false, at = {r2(hit.X), r2(hit.Y), r2(hit.Z)}} or {clear = true}
    end
    return out
  end

  DOC.world_surface = "The surface of a thing as rays from above find it: x, y, z, yaw and its box {min, max} (the " ..
                      "app's world_room gives them) -> the main surface's height above the floor, its share, extent, " ..
                      "and the height grid"
  function C.world_surface(a)
    if not (a.box and a.box.min and a.box.max) then error("a box {min, max} is needed", 0) end
    local x, y, z = pos_of(a)
    return WS.surface(x, y, z, a.yaw or 0, a.box, a.n)
  end

  DOC.world_floor = "Free floor near a point where a w x d rectangle lies flat and nothing stands in it up to height " ..
                    "(yaw, radius, limit) -> spots {x, y, z} nearest first"
  function C.world_floor(a)
    local x, y, z = pos_of(a)
    return WS.floor(x, y, z, a.w or 1.0, a.d or 2.0, a.height, a.yaw, a.radius, a.limit)
  end

  DOC.anim_shape = "The shape of an animation measured on a person of the open scene (actor; else the player): " ..
                   "posture, pelvis and head heights, the lowest point, its extent on the floor around the figure's " ..
                   "origin, what it needs under it (floor, a seat at a height, a surface at a height); length (s)"
  function C.anim_shape(a)
    local e = figure(a)
    local len = a.length
    if not len and body then
      local okb, b = pcall(body)
      if okb and b and b.w then len = require("conjunction.scene_work").animation_length(b.w.depot, a.anim) end
    end
    local shape, why = WS.anim_shape(e, a.anim, len)
    if not shape then
      if why == "" then error("its data is still streaming in: ask again in a moment", 0) end
      error(tostring(why), 0)
    end
    shape.anim, shape.length = a.anim, len
    return shape
  end

  DOC.anim_gait = "How fast a walk or run cycle goes, measured on a person of the open scene (actor; else the " ..
                  "player): speed (m/s, from the foot on the ground), forward (its way in the figure's space), length"
  function C.anim_gait(a)
    local e = figure(a)
    local len = a.length
    if not len and body then
      local okb, b = pcall(body)
      if okb and b and b.w then len = require("conjunction.scene_work").animation_length(b.w.depot, a.anim) end
    end
    local g, why = WS.anim_gait(e, a.anim, len)
    if not g then
      if why == "" then error("its data is still streaming in: ask again in a moment", 0) end
      error(tostring(why), 0)
    end
    g.anim = a.anim
    return g
  end

  DOC.scene_check = "The open scene's people as they stand now: each one's world_person check (turned toward the " ..
                    "others), how far apart they are, whether the camera shows them -> {ok, people, pairs}"
  function C.scene_check()
    local b = body()
    if not b.w then error("no scene is open (scene_open first)", 0) end
    local SW = require("conjunction.scene_work")
    local people = {}
    for _, act in ipairs(b.w.s:actors()) do
      local e = b.w:figure_of(act.id)
      if e then people[#people + 1] = {actor = act.id, e = e, p = e:GetWorldPosition()} end
    end
    local out, pairs_ = {ok = true, people = {}}, {}
    for i, pr in ipairs(people) do
      local other
      for j, q in ipairs(people) do if j ~= i then other = q break end end
      local chk = WS.person(pr.e, other and {other.p.X, other.p.Y} or nil)
      local fu, fv = SW.ratio(pr.p)
      local hu, hv = SW.ratio(V(pr.p.X, pr.p.Y, pr.p.Z + HEAD))
      chk.in_picture = (hu and hu >= 0 and hu <= 1 and hv >= 0 and hv <= 1) or
                       (fu and fu >= 0 and fu <= 1 and fv >= 0 and fv <= 1) or false
      if not chk.in_picture then chk.problems[#chk.problems + 1] = "the camera does not show them" chk.ok = false end
      chk.actor = pr.actor
      out.people[#out.people + 1] = chk
      out.ok = out.ok and chk.ok
      for j = i + 1, #people do
        local q = people[j]
        pairs_[#pairs_ + 1] = {pr.actor, q.actor, r2(math.sqrt((pr.p.X - q.p.X) ^ 2 + (pr.p.Y - q.p.Y) ^ 2))}
      end
    end
    out.pairs = pairs_
    return out
  end
end

return WS
