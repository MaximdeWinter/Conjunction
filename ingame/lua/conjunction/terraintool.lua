-- The terrain brush in the world - the editor's Terrain mode (terraintool.py, experimental). The ground under the cursor
-- comes from the terrain's own heights (terrain.lua), the strokes already painted included - the game's ground stays as
-- it was until the next start. The bar draws the brush (its circle or square on the ground, the inner line at half
-- strength) and a net over the ground the strokes changed (ui/hud.lua draw_terrain): gold up, blue down.
--   left button held   paint (a dab every third of the radius); Shift: the other way; Ctrl: smooth. Ramp: press at its
--                      start, let go at its end. Flatten / set: to the height where the drag began, or the one set
--   wheel              the brush's size; Shift + wheel: its strength        Ctrl+Z  the last drag taken back
-- Each drag is kept in the project at once (terrain.yml); Build & Play puts the changed tiles and their collision into
-- the quest's mod.
--   local tt = TT.new(ed)   tt:handle(edge, up, now, V, mx, my, w, h, moved_cam)   tt:net_lines()   tt:outline(radius)
local TER = require("conjunction.terrain")
local CFG = require("conjunction.config")
local NUM = require("conjunction.pynum")
local Y = require("conjunction.yaml")
local TT = {}
TT.__index = TT

TT.TOOLS = {{"raise", "Raise"}, {"lower", "Lower"}, {"smooth", "Smooth"}, {"flatten", "Flatten"},
            {"set", "Set height"}, {"ramp", "Ramp"}, {"noise", "Roughen"}, {"terrace", "Terrace"}}
TT.LABEL = {}
for _, t in ipairs(TT.TOOLS) do TT.LABEL[t[1]] = t[2] end
TT.DEFAULTS = {op = "raise", radius = 6.0, strength = 0.3, falloff = "smooth", shape = "circle", height = Y.null,
               step = 1.0, scale = 4.0}
TT.DEFAULT_ORDER = {"op", "radius", "strength", "falloff", "shape", "height", "step", "scale"}
TT.RADIUS = {0.5, 60.0}
TT.STRENGTH = {raise = {0.02, 5.0}, lower = {0.02, 5.0}, noise = {0.05, 5.0}}    -- metres; the rest 0..1
TT.SPACING = 0.33                 -- a dab every third of the radius
TT.NET = 34                       -- lines of the net each way at most

local depot = nil
function TT.depot()
  depot = depot or require("conjunction.depot").open(CFG.load().game)
  return depot
end

local function given(v) return v ~= nil and v ~= Y.null end

function TT.new(ed)
  local self = setmetatable({ed = ed}, TT)
  local brush = Y.map()
  local saved = CFG.load().terrain_brush
  for _, k in ipairs(TT.DEFAULT_ORDER) do brush[k] = TT.DEFAULTS[k] end
  if type(saved) == "table" then for _, k in ipairs(Y.keys(saved)) do brush[k] = saved[k] end end
  self.brush = brush
  self.groups = TER.load(ed.project.path)
  self.terrain, self.world, self.loading = nil, nil, false
  self.cursor, self.drag, self.net, self.at = nil, nil, nil, nil
  return self
end

-- the terrain of the world being edited (made as the editor's job: the depot and the tiles take a moment)
function TT:make(world) return TER.Terrain(world, TT.depot()) end
function TT:ready()
  local world = self.ed.world
  if not world or world == "" then return false end
  if self.terrain ~= nil and self.world == world then return true end
  if not self.loading then
    self.loading = true
    local function load()
      local ok, t = pcall(function()
        local t = self:make(world)
        t:apply(TER.strokes_of(self.groups, world))
        return t
      end)
      if ok then self.terrain, self.world, self.net = t, world, nil
      else
        print("[terrain] no terrain for " .. tostring(world) .. ": " .. tostring(t))   -- (an interior)
        self.world = world
      end
      self.loading = false
    end
    if self.ed.job then self.ed:job(load) else load() end
  end
  return false
end

-- the terrain again from the kept strokes (after an undo)
function TT:_rebuild()
  local t = self:make(self.world)
  t:apply(TER.strokes_of(self.groups, self.world))
  self.terrain, self.net = t, nil
end

-- --- the brush
function TT:set(k, value)
  self.brush[k] = value
  local cfg = CFG.load()
  cfg.terrain_brush = self.brush
  CFG.save(cfg)
  if self.ed.hud and self.ed.hud.sync then self.ed.hud:sync() end
end
function TT:resize(notches)
  local lo, hi = TT.RADIUS[1], TT.RADIUS[2]
  self:set("radius", NUM.round(math.max(lo, math.min(hi, self.brush.radius * 1.12 ^ notches)), 2))
end
function TT:strengthen(notches)
  local r = TT.STRENGTH[self.brush.op] or {0.05, 1.0}
  self:set("strength", NUM.round(math.max(r[1], math.min(r[2], self.brush.strength * 1.15 ^ notches)), 3))
end

function TT:_stroke(op, x, y, extra)
  local b = self.brush
  local s = Y.map({"op", op, "x", NUM.round(x, 2), "y", NUM.round(y, 2), "radius", b.radius, "strength", b.strength})
  if b.falloff ~= "smooth" then s.falloff = b.falloff end
  if b.shape ~= "circle" then s.shape = b.shape end
  if op == "noise" then             -- (one after the other: a multiple assignment fills the map right to left)
    s.scale = b.scale
    s.seed = #self.groups
  end
  if op == "terrace" then s.step = b.step end
  if (op == "flatten" or op == "set") and self.drag and given(self.drag.height) then
    s.height = NUM.round(self.drag.height, 3)
  end
  if (op == "smooth" or op == "flatten" or op == "ramp" or op == "terrace") and s.strength > 1 then s.strength = 1.0 end
  for _, kv in ipairs(extra or {}) do s[kv[1]] = kv[2] end
  return s
end

-- --- input (the editor's tick, the mouse over the world)
function TT:handle(edge, up, now, V, mx, my, w, h, moved_cam)
  if not self:ready() then return end
  local cam = self.ed.cam
  local key = string.format("%d,%d,%.3f,%.3f,%.3f,%s,%s", NUM.round0(mx), NUM.round0(my), cam.pos[1], cam.pos[2],
                            cam.pos[3], tostring(cam.yaw), tostring(cam.pitch))
  if key ~= self.at or moved_cam then
    self.at = key
    local origin, d = self.ed:cursor_ray(mx, my, w, h)
    self.cursor = self.terrain:ground(origin, d)
  end
  local c = self.cursor
  if edge[V.LBUTTON] and c then
    local op = self.brush.op
    if now[V.CTRL] then op = "smooth"
    elseif now[V.SHIFT] and (op == "raise" or op == "lower") then op = op == "raise" and "lower" or "raise" end
    local height = given(self.brush.height) and self.brush.height or c[3]
    self.drag = {op = op, strokes = {}, start = {c[1], c[2], c[3]}, last = nil, height = height}
    if op ~= "ramp" then self:_dab(c) end
  elseif self.drag and now[V.LBUTTON] and c and self.drag.op ~= "ramp" then
    local last = self.drag.last
    if last == nil or NUM.hypot(c[1] - last[1], c[2] - last[2]) >= self.brush.radius * TT.SPACING then self:_dab(c) end
  end
  if self.drag and up[V.LBUTTON] then self:_finish(c) end
end

function TT:_dab(c)
  local s = self:_stroke(self.drag.op, c[1], c[2])
  self.terrain:apply({s})
  self.drag.strokes[#self.drag.strokes + 1] = s
  self.drag.last = {c[1], c[2], c[3]}
  self.net = nil
end

function TT:_finish(c)
  local d = self.drag
  self.drag = nil
  if d.op == "ramp" then
    if not c or NUM.hypot(c[1] - d.start[1], c[2] - d.start[2]) < 0.5 then return end
    local s = self:_stroke("ramp", d.start[1], d.start[2],
                           {{"x2", NUM.round(c[1], 2)}, {"y2", NUM.round(c[2], 2)}, {"height", NUM.round(d.start[3], 3)},
                            {"height2", NUM.round(c[3], 3)}})
    self.terrain:apply({s})
    d.strokes = {s}
    self.net = nil
  end
  if #d.strokes == 0 then return end
  self.groups[#self.groups + 1] = Y.map({"world", self.world, "strokes", Y.list(d.strokes)})
  TER.save(self.ed.project.path, self.groups)
  self.ed.undo[#self.ed.undo + 1] = {"terrain"}
  if self.ed.hud and self.ed.hud.sync then self.ed.hud:sync() end
end

-- the last drag taken back (the editor's Ctrl+Z)
function TT:undo()
  if #self.groups == 0 then return end
  table.remove(self.groups)
  TER.save(self.ed.project.path, self.groups)
  if self.world then self:_rebuild() end
  if self.ed.hud and self.ed.hud.sync then self.ed.hud:sync() end
end

-- the panel's Undo: the last drag, whatever else was changed since (its entry leaves the editor's list)
function TT:undo_button()
  for i = #self.ed.undo, 1, -1 do
    if self.ed.undo[i][1] == "terrain" then table.remove(self.ed.undo, i) break end
  end
  self:undo()
end

-- every stroke of this world gone (the panel's Reset)
function TT:clear()
  local before = #self.groups
  local keep = {}
  for _, g in ipairs(self.groups) do if g.world ~= self.world then keep[#keep + 1] = g end end
  self.groups = keep
  TER.save(self.ed.project.path, self.groups)
  local gone = before - #self.groups                -- (as many of the editor's terrain undo entries go, the newest)
  for i = #self.ed.undo, 1, -1 do
    if gone > 0 and self.ed.undo[i][1] == "terrain" then
      table.remove(self.ed.undo, i)
      gone = gone - 1
    end
  end
  if self.world then self:_rebuild() end
  if self.ed.hud and self.ed.hud.sync then self.ed.hud:sync() end
end

function TT:painted()
  local n = 0
  for _, g in ipairs(self.groups) do if g.world == self.world then n = n + 1 end end
  return n
end

local function g_fmt(v) return string.format("%g", v) end      -- (f"{v:g}")
function TT:doing()
  local b = self.brush
  if self.terrain == nil then
    return (self.ed.world and self.ed.world ~= "") and "Terrain · reading the ground ..." or "Terrain", {}
  end
  local unit = TT.STRENGTH[b.op] and "m" or ""
  local what = string.format("%s · %s m · %s%s", TT.LABEL[b.op], g_fmt(b.radius), g_fmt(b.strength), unit)
  return "Terrain · " .. what, {"Shift", "Ctrl", "Wheel"}
end

-- --- what the bar draws (hud.draw_terrain)
-- the brush's edge on the ground, as world points (circle: 49, square: 4 x 12 + 1)
function TT:outline(c, radius)
  local pts = {}
  if self.brush.shape == "square" then
    local k = 12
    local side = {}
    for i = 0, k - 1 do side[#side + 1] = {-1 + 2 * i / k, -1} end
    for i = 0, k - 1 do side[#side + 1] = {1, -1 + 2 * i / k} end
    for i = 0, k - 1 do side[#side + 1] = {1 - 2 * i / k, 1} end
    for i = 0, k do side[#side + 1] = {-1, 1 - 2 * i / k} end
    for _, uv in ipairs(side) do pts[#pts + 1] = {c[1] + uv[1] * radius, c[2] + uv[2] * radius} end
  else
    for t = 0, 48 do
      pts[#pts + 1] = {c[1] + radius * math.cos(t * math.pi / 24), c[2] + radius * math.sin(t * math.pi / 24)}
    end
  end
  local out = {}
  for i, p in ipairs(pts) do out[i] = {p[1], p[2], self.terrain:height(p[1], p[2]) + 0.05} end
  return out
end

-- lines over the ground the strokes changed, in its new height: {{{point, dz}, ...}, ...} (kept until they change)
function TT:net_lines()
  if self.net ~= nil then return self.net end
  local strokes = TER.strokes_of(self.groups, self.world)
  for _, s in ipairs(self.drag and self.drag.strokes or {}) do strokes[#strokes + 1] = s end
  if #strokes == 0 then self.net = {} return self.net end
  local x0, x1, y0, y1, r = math.huge, -math.huge, math.huge, -math.huge, 0
  for _, s in ipairs(strokes) do
    for _, x in ipairs({s.x, given(s.x2) and s.x2 or s.x}) do x0, x1 = math.min(x0, x), math.max(x1, x) end
    for _, y in ipairs({s.y, given(s.y2) and s.y2 or s.y}) do y0, y1 = math.min(y0, y), math.max(y1, y) end
    r = math.max(r, s.radius)
  end
  x0, x1, y0, y1 = x0 - r, x1 + r, y0 - r, y1 + r
  local t = self.terrain
  local step = math.max(t.spacing * 2, math.max(x1 - x0, y1 - y0) / TT.NET)
  local nx, ny = math.floor((x1 - x0) / step) + 1, math.floor((y1 - y0) / step) + 1
  local grid, delta = {}, {}
  for j = 0, ny - 1 do
    grid[j + 1], delta[j + 1] = {}, {}
    for i = 0, nx - 1 do
      local x, y = x0 + i * step, y0 + j * step
      grid[j + 1][i + 1] = {x, y}
      delta[j + 1][i + 1] = t:change(x, y)
    end
  end
  local lines = {}
  local function run_of(cells)
    local run = {}
    for _, cell in ipairs(cells) do
      local p, dz = cell[1], cell[2]
      if math.abs(dz) > 0.03 then
        run[#run + 1] = {{p[1], p[2], t:height(p[1], p[2]) + 0.03}, dz}
      elseif #run > 0 then
        lines[#lines + 1] = run
        run = {}
      end
    end
    if #run > 0 then lines[#lines + 1] = run end
  end
  for j = 1, ny do
    local cells = {}
    for i = 1, nx do cells[i] = {grid[j][i], delta[j][i]} end
    run_of(cells)
  end
  for i = 1, nx do
    local cells = {}
    for j = 1, ny do cells[j] = {grid[j][i], delta[j][i]} end
    run_of(cells)
  end
  self.net = lines
  return lines
end

return TT
