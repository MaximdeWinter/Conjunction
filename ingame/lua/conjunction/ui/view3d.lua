-- The inspector's 3D view (meshview.MeshView in the picture's place): what meshview.lua reads is drawn by cj_qt with
-- the app's own OpenGL (cj_qt_gl.cpp) into a picture, again when the view turns. Drag to turn (any button: yaw by
-- half the pixels, pitch too, within -89..89), the wheel to come closer (x 0.9) or go back (x 1.1), between 0.6 and
-- 20 times the radius. Reading takes a while (a person: most of a second): it runs as a coroutine, BUDGET seconds a
-- frame (V3.SYNC: all at once, for the lab's pictures).
--   local v = V3.new()     v:load(key, produce, on_ready)   v:tick()   v:show_parts(parts) -> ok   v:draw(r, hit)
local MV = require("conjunction.meshview")
local DP = require("conjunction.depot")
local CFG = require("conjunction.config")
local CT = require("conjunction.ui.controls")
local D = w3.ui.draw
local V3 = {}
V3.__index = V3

V3.BUDGET = 0.004
V3.SYNC = false

-- the game's files, opened once (the index is kept while no bundle changes); in the reading's coroutine its index
-- is made on cj_core's thread while the frames go on
local depot
function V3.depot()
  if depot then return depot end
  if coroutine.isyieldable() then
    local game = CFG.load().game
    local d = DP.open_async(game)
    while not d do
      coroutine.yield()
      d = DP.open_async(game)
    end
    depot = d
  else
    depot = DP.open(CFG.load().game)
  end
  return depot
end
function V3.game() return CFG.load().game end

local function scratch(name)
  local dir = w3.fs.folder("temp") .. "\\cj_core"
  if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  return dir .. "\\" .. name
end

function V3.new()
  return setmetatable({yaw = 215.0, pitch = 20.0, dist = 3.0, center = {0.0, 0.0, 0.0}, radius = 1.0,
                       mesh = nil, job = nil, img = nil, drawn = nil, flip = 0}, V3)
end

-- produce() runs as a coroutine (meshview.lua gives the frame back at its points); on_ready(key, ok, result)
-- (the parts are written for cj_qt in the coroutine too: their textures take a while)
function V3:load(key, produce, on_ready, tex_side)
  local file = scratch(tex_side and ("mesh3d_" .. tex_side .. ".bin") or "mesh3d.bin")
  local co = coroutine.create(function()
    pcall(w3.plugin.cj_qt_gl_start)                  -- (Qt's thread starts meanwhile: half a second the first time)
    local parts = produce()
    if type(parts) == "table" and #parts > 0 then
      local ok, err = pcall(MV.write_parts, parts, file, V3.game(), tex_side)
      if not ok then print("[conjunction] 3D view: " .. tostring(err)) return {} end
      local ok2, state = pcall(w3.plugin.cj_qt_gl_start)
      while ok2 and state == "starting" do
        coroutine.yield()
        ok2, state = pcall(w3.plugin.cj_qt_gl_start)
      end
      -- (the upload to OpenGL on Qt's thread too: a person's takes most of 100 ms)
      local ok3, ticket = pcall(w3.plugin.cj_qt_mesh_load, file, V3.SYNC and "" or "async")
      if not ok3 then print("[conjunction] 3D view: " .. tostring(ticket)) return {} end
      if not V3.SYNC then
        local answer = "busy"
        while answer == "busy" do
          coroutine.yield()
          answer = w3.plugin.cj_qt_mesh_ready(ticket)
        end
        ticket = answer
      end
      parts.mesh = ticket
    end
    return parts
  end)
  self.job = {key = key, co = co, on_ready = on_ready, file = file}
  if V3.SYNC then                                  -- (the lab: to the end now, waiting where it waits)
    while self.job do self:tick() end
  end
end

-- each frame: the job goes on for its share of the frame
function V3:tick()
  local job = self.job
  if not job then return end
  MV.deadline = (not V3.SYNC) and (os.clock() + (self.budget or V3.BUDGET)) or nil
  local ok, res = coroutine.resume(job.co)
  MV.deadline = nil
  if coroutine.status(job.co) ~= "dead" then return end
  self.job = nil
  job.on_ready(job.key, ok, res)
end
function V3:busy() return self.job ~= nil end

-- MeshView.show_parts: the parts to cj_qt (written by load's coroutine), the frame around them
function V3:show_parts(parts)
  local id = parts.mesh
  if not id then return false end
  if self.mesh then pcall(w3.plugin.cj_qt_mesh_free, self.mesh) end
  self.mesh = id
  local fr = MV.frame_of(parts)
  self.center, self.radius, self.dist = fr.center, fr.radius, fr.dist
  self.drawn = nil
  return true
end

local function g(v) return string.format("%.17g", v) end
-- the picture of the view at w x h (drawn again when something changed)
function V3:picture(w, h)
  if not self.mesh then return nil end
  local want = table.concat({self.mesh, w, h, g(self.yaw), g(self.pitch), g(self.dist)}, " ")
  if self.drawn == want and self.img then return self.img end
  self.flip = 1 - self.flip
  local out = scratch("view3d_" .. self.flip .. ".png")
  local ok, err = pcall(w3.plugin.cj_qt_mesh_render, tostring(self.mesh), tostring(w), tostring(h), g(self.yaw),
                        g(self.pitch), g(self.dist), g(self.center[1]), g(self.center[2]), g(self.center[3]),
                        g(self.radius), out)
  if not ok then
    print("[conjunction] 3D view: " .. tostring(err))
    self.drawn = want
    return self.img
  end
  local id, iw, ih = w3.ui.image_load(out)
  if self.img then w3.ui.image_free(self.img[1]) end
  self.img = id and {id, iw, ih} or nil
  self.drawn = want
  return self.img
end

-- one frame in r: the picture, the mouse (hit(id, r) -> clicked, hovered, held as the owner's hit boxes)
function V3:draw(r, hit)
  local img = self:picture(r.w, r.h)
  if img then D.image(img[1], r.x, r.y, img[2], img[3]) end
  local _, hv = hit("ins.view3d", r)
  if hv then CT.tip("panel.ins.view3d", "ins.view3d") end
  local mx, my, wheel = w3.ui.mouse()
  local pressed = w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2) or w3.ui.mouse_clicked(3)
  if hv and pressed then self.last = {mx, my} end
  local down = w3.ui.mouse_down(1) or w3.ui.mouse_down(2) or w3.ui.mouse_down(3)
  if self.last and down then
    local dx, dy = mx - self.last[1], my - self.last[2]
    if dx ~= 0 or dy ~= 0 then
      self.last = {mx, my}
      self.yaw = self.yaw - dx * 0.5                 -- (drag right: it turns right)
      self.pitch = math.max(-89.0, math.min(89.0, self.pitch + dy * 0.5))
    end
  elseif self.last and not down then
    self.last = nil
  end
  if hv and wheel and wheel ~= 0 then             -- (Qt: one event a notch)
    for _ = 1, math.max(1, math.floor(math.abs(wheel) + 0.5)) do
      self.dist = math.max(self.radius * 0.6, math.min(self.radius * 20, self.dist * (wheel > 0 and 0.9 or 1.1)))
    end
  end
end

function V3:free()
  if self.mesh then pcall(w3.plugin.cj_qt_mesh_free, self.mesh) end
  if self.img then w3.ui.image_free(self.img[1]) end
  self.mesh, self.img, self.drawn = nil, nil, nil
end

return V3
