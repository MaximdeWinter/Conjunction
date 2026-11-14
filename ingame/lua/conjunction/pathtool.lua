-- Drawing a path in the world (pathtool.py) - one tool for every way (Follow, Patrol, Walk, a trail, a camera move,
-- a hide area's outline). While it is on, the overlay draws it (hud.lua: H:draw_path_tool), and a click into the
-- world:
--   - on empty ground: a point at the end of the path,
--   - on a line between two points: a point there, in between,
--   - on a point: picks it up - the next click puts it down there;
-- a right click on a point takes it out. Every point is kept the moment it is set (on_change) - Enter and Esc only end
-- drawing, Backspace takes the last point (or the one picked up) out. The ground under each click comes from the game
-- (cj_cursor_hit; the editor hands the answer to ground()).
--   PT.new(ed, points, on_done, {label, closed, on_cancel, min_points, on_change}):start()
local NUM = require("conjunction.pynum")
local PT = {}
PT.__index = PT

PT.NEAR_POINT = 13          -- px: a click this close to a dot is on it
PT.NEAR_LINE = 8            -- px: this close to a line, between its ends
PT.COLOUR = "#e3c65f"
PT.PICKED = "#ffffff"

-- screen distance of p to the segment a-b, and where along it (0..1)
local function seg_dist(p, a, b)
  local ax, ay = a[1], a[2]
  local dx, dy = b[1] - ax, b[2] - ay
  local ll = dx * dx + dy * dy
  local t = 0.0
  if ll ~= 0 then t = math.max(0.0, math.min(1.0, ((p[1] - ax) * dx + (p[2] - ay) * dy) / ll)) end
  return NUM.hypot(p[1] - (ax + t * dx), p[2] - (ay + t * dy)), t
end
PT.seg_dist = seg_dist

local function copy(points)
  local out = {}
  for i, p in ipairs(points or {}) do out[i] = {p[1] + 0.0, p[2] + 0.0, p[3] + 0.0} end
  return out
end
local function rounded(points)
  local out = {}
  for i, p in ipairs(points) do out[i] = {NUM.round(p[1], 3), NUM.round(p[2], 3), NUM.round(p[3], 3)} end
  return out
end
local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    for k = 1, 3 do if a[i][k] ~= b[i][k] then return false end end
  end
  return true
end

function PT.new(ed, points, on_done, opts)
  opts = opts or {}
  local self = setmetatable({ed = ed, on_done = on_done, on_cancel = opts.on_cancel, on_change = opts.on_change,
                             label = opts.label or "Path", closed = opts.closed or false,
                             min_points = opts.min_points or 1, picked = nil, pending = nil}, PT)
  self.points = copy(points)
  self.original = copy(self.points)
  return self
end

-- --- on / off
function PT:start()
  self.ed.path_tool = self
  if self.ed.set_mode then self.ed:set_mode("look") end      -- (a click is a point, nothing gets selected)
  self:show()
end
function PT:finish()
  if #self.points < self.min_points then return self:cancel() end
  self:_end()
  self.on_done(rounded(self.points))
end
-- Esc: the points stay (each was kept when set) - drawing ends; too few for a way: as it was
function PT:cancel()
  if #self.points >= self.min_points and not same(self.points, self.original) then return self:finish() end
  self:_end()
  if self.on_cancel then self.on_cancel(copy(self.original)) end
end
function PT:changed()
  self:show()
  if self.on_change and #self.points >= self.min_points then self.on_change(rounded(self.points)) end
end
function PT:_end()
  if self.ed.path_tool == self then self.ed.path_tool = nil end
  self:show()
end
function PT:show()
  local hud = self.ed.hud
  if hud and hud.sync then hud:sync() end
end

-- --- input (the editor hands it on: px in the game's picture)
function PT:screen()
  local _, _, w, h = self.ed.sys.client()
  local out = {}
  for i, p in ipairs(self.points) do out[i] = self.ed.cam:project(p, w, h) or false end
  return out
end

-- a left click at x, y: what it means, then the ground under it asked of the game (ask_ground())
function PT:click(x, y, ask_ground)
  local scr = self:screen()
  if self.picked ~= nil then
    self.pending = {"move", self.picked}
  else
    local d, i
    for k, s in ipairs(scr) do
      if s then
        local dk = NUM.hypot(x - s[1], y - s[2])
        if d == nil or dk < d then d, i = dk, k end              -- (min of (d, i): the first of equals)
      end
    end
    if d ~= nil and d <= PT.NEAR_POINT then
      self.picked = i                                           -- picked up: the next click puts it down
      self:show()
      return
    end
    local best
    local pairs_ = {}
    for k = 1, #scr - 1 do pairs_[#pairs_ + 1] = {k, scr[k], scr[k + 1]} end
    if self.closed and #scr > 2 then pairs_[#pairs_ + 1] = {#scr, scr[#scr], scr[1]} end
    for _, pr in ipairs(pairs_) do
      local k, a, b = pr[1], pr[2], pr[3]
      if a and b then
        local dist, t = seg_dist({x, y}, a, b)
        if dist <= PT.NEAR_LINE and 0.05 < t and t < 0.95 and (best == nil or dist < best[1]) then
          best = {dist, k + 1}
        end
      end
    end
    if best then self.pending = {"insert", best[2]} else self.pending = {"add", #self.points + 1} end
  end
  ask_ground()
end

-- a right click on a point takes it out
function PT:right_click(x, y)
  for i, s in ipairs(self:screen()) do
    if s and NUM.hypot(x - s[1], y - s[2]) <= PT.NEAR_POINT then
      table.remove(self.points, i)
      self.picked = nil
      break
    end
  end
  self:changed()
end

-- the game's answer: the ground point under the click (nil: nothing hit)
function PT:ground(pos)
  local what = self.pending
  self.pending = nil
  if what == nil or pos == nil then return end
  local p = {NUM.round(pos[1] + 0.0, 3), NUM.round(pos[2] + 0.0, 3), NUM.round(pos[3] + 0.0, 3)}
  local kind, i = what[1], what[2]
  if kind == "move" and i <= #self.points then
    self.points[i] = p
    self.picked = nil
  elseif kind == "insert" then
    table.insert(self.points, i, p)
  else                                                          -- (a move past the end too, as pathtool.py)
    self.points[#self.points + 1] = p
  end
  self:changed()
end

-- Backspace: the point picked up, else the last one, out
function PT:back()
  if self.picked ~= nil and self.picked <= #self.points then
    table.remove(self.points, self.picked)
    self.picked = nil
  elseif #self.points > 0 then
    table.remove(self.points)
  end
  self:changed()
end

function PT:doing()
  local n = #self.points
  if self.picked ~= nil then
    return string.format("%s \u{b7} point %d picked up - click where it goes", self.label, self.picked),
           {"Click: put down", "Backspace: remove"}
  end
  return string.format("%s \u{b7} %d point%s \u{b7} click in the world to add", self.label, n, n ~= 1 and "s" or ""),
         {"Enter: done", "Backspace: last out", "Right click: remove"}
end

return PT
