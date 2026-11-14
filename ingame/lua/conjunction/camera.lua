-- The editor camera (editor.py: Camera, Editor.cursor_ray): its pose comes from the game (cam|x|y|z|pitch|yaw|fx|fy|fz|
-- fov); the heading convention is the one of six that matches the forward vector the game reports.
--
--   local cam = CAM.new()
--   cam:from_game({x, y, z, pitch, yaw, fx, fy, fz, fov})   -- numbers or the line's strings
--   local p = cam:project({x, y, z}, w, h)                   -- {sx, sy} in pixels, nil behind the camera
--   local origin, dir = cam:cursor_ray(mx, my, w, h)
local CAM = {}
CAM.__index = CAM

-- Python's sum() of floats (3.12+): the first term as it is, then Neumaier's compensated sum; the compensation added at
-- the end when it is finite and not 0. editor.py's dot products are sums.
local function psum(xs)
  local f, c = xs[1] + 0.0, 0.0
  for i = 2, #xs do
    local x = xs[i]
    local t = f + x
    if math.abs(f) >= math.abs(x) then c = c + ((f - t) + x) else c = c + ((x - t) + f) end
    f = t
  end
  if c ~= 0 and c == c and c ~= math.huge and c ~= -math.huge then f = f + c end
  return f
end
CAM.psum = psum

local function h1(a) return -math.sin(a), math.cos(a) end
local CANDS = {h1, function(a) return math.sin(a), math.cos(a) end, function(a) return math.cos(a), math.sin(a) end,
               function(a) return -math.cos(a), -math.sin(a) end, function(a) return math.sin(a), -math.cos(a) end,
               function(a) return -math.sin(a), -math.cos(a) end}

function CAM.new()
  return setmetatable({pos = {0.0, 0.0, 0.0}, pitch = 0.0, yaw = 0.0, fov = 60.0, heading = h1, ready = false}, CAM)
end

function CAM:from_game(parts)
  local v = {}
  for i = 1, 9 do v[i] = tonumber(parts[i]) + 0.0 end
  local x, y, z, pitch, yaw, fx, fy, _, fov = table.unpack(v)
  self.pos, self.pitch, self.yaw, self.fov = {x, y, z}, pitch, yaw, fov
  local n = math.sqrt(fx * fx + fy * fy)
  if n == 0 then n = 1.0 end
  -- max(cands, key=...): the first of the best
  local best, best_v
  for _, h in ipairs(CANDS) do
    local hx, hy = h(math.rad(yaw))
    local s = hx * fx / n + hy * fy / n
    if best_v == nil or s > best_v then best, best_v = h, s end
  end
  self.heading = best
  self.ready = true
end

function CAM:axes()
  local p = math.rad(self.pitch)
  local hx, hy = self.heading(math.rad(self.yaw))
  local f = {hx * math.cos(p), hy * math.cos(p), math.sin(p)}
  local rx, ry = self.heading(math.rad(self.yaw - 90))
  local r = {rx, ry, 0.0}
  local u = {r[2] * f[3] - r[3] * f[2], r[3] * f[1] - r[1] * f[3], r[1] * f[2] - r[2] * f[1]}
  return f, r, u
end

-- world point -> window pixels (nil behind the camera)
function CAM:project(p, w, h)
  local f, r, u = self:axes()
  local d = {p[1] - self.pos[1], p[2] - self.pos[2], p[3] - self.pos[3]}
  local zc = psum({d[1] * f[1], d[2] * f[2], d[3] * f[3]})
  if zc <= 0.05 then return nil end
  local tv = math.tan(math.rad(self.fov) / 2)
  local th = tv * w / h
  local sx = (psum({d[1] * r[1], d[2] * r[2], d[3] * r[3]}) / zc / th + 1) / 2
  local sy = (1 - psum({d[1] * u[1], d[2] * u[2], d[3] * u[3]}) / zc / tv) / 2
  return {sx * w, sy * h}
end

-- (camera position, direction) of the ray through a window pixel
function CAM:cursor_ray(mx, my, w, h)
  local f, r, u = self:axes()
  local tv = math.tan(math.rad(self.fov) / 2)
  local th = tv * w / h
  local a, b = (2 * mx / w - 1) * th, (1 - 2 * my / h) * tv
  local d = {f[1] + r[1] * a + u[1] * b, f[2] + r[2] * a + u[2] * b, f[3] + r[3] * a + u[3] * b}
  local n = math.sqrt(psum({d[1] * d[1], d[2] * d[2], d[3] * d[3]}))
  if n == 0 then n = 1.0 end
  return {self.pos[1], self.pos[2], self.pos[3]}, {d[1] / n, d[2] / n, d[3] / n}
end

return CAM
