-- Snap to side for Conjunction's windows over the game (conjunction/dock.py): a window floats where it was put;
-- dragged by its header to within SNAP px of an edge of the game, a frame shows where it would go (the bar's overlay
-- draws it: ed.hud.dock_preview); let go there, it fills that side - left / right the whole height under the bar, top
-- / bottom the whole width. Docked, only its inner edge resizes it; dragged away, it floats again at its old size.
-- Windows docked on one side share it. Side and size are kept (config "docks": {key: {side, size}}).
-- In the game's client pixels (ImGui's); the game's rectangle is the screen under the bar.
--   local d = DK.new(win, "panel", ed)     win: {rect = {x, y, w, h}, visible() -> bool, min_w, min_h}
--   d:drag_moved(mx, my) / d:drag_released(mx, my)   d:inner_edge()   d:resized()   d:apply()
--   DK.insets() -> {left, right, top, bottom}
--   local mv = DK.mover(win, key, ed, opts)          the header drag and the border resize of a window (Mover)
local CFG = require("conjunction.config")
local Y = require("conjunction.yaml")
local DK = {}
DK.__index = DK

DK.SNAPPING = false                                 -- (dock.SNAPPING: off since 23.10., every window floats)
DK.SNAP = 36
DK.MIN = 260
DK.BAR_H = 32                                       -- (hud.BAR_H)
local SIDES = {"left", "right", "top", "bottom"}
local INNER = {left = "right", right = "left", top = "bottom", bottom = "top"}
local all = {}
DK.all = all

-- the game's client size (the panel's frame tells it each frame)
DK.W, DK.H = 1600, 900
function DK.game_rect()
  return {x = 0, y = DK.BAR_H, w = DK.W, h = DK.H - DK.BAR_H}
end

function DK.insets()
  local out = {left = 0, right = 0, top = 0, bottom = 0}
  for _, d in ipairs(all) do
    if d.side and d.win:visible() then
      local g = d.win.rect
      out[d.side] = math.max(out[d.side], (d.side == "left" or d.side == "right") and g.w or g.h)
    end
  end
  return out
end

function DK.new(win, key, ed, default_size)
  local docks = CFG.load().docks
  local kept = (type(docks) == "table" and docks[key]) or {}
  local self = setmetatable({win = win, key = key, ed = ed}, DK)
  local side = kept.side
  self.side = DK.SNAPPING and (side == "left" or side == "right" or side == "top" or side == "bottom") and side or nil
  self.size = math.tointeger(tonumber(kept.size)) or default_size or 420
  self.float_size = nil
  self.extra = function() return 0 end
  self.candidate = nil
  all[#all + 1] = self
  return self
end

function DK:keep()
  local cfg = CFG.load()
  local docks = Y.map({})
  if type(cfg.docks) == "table" then for _, k in ipairs(Y.keys(cfg.docks)) do docks[k] = cfg.docks[k] end end
  docks[self.key] = Y.map({"side", self.side or Y.null, "size", self.size})
  cfg.docks = docks
  CFG.save(cfg)
end

function DK:side_at(px, py)
  if not DK.SNAPPING then return nil end
  local r = DK.game_rect()
  local S = DK.SNAP
  if not (r.x - S <= px and px <= r.x + r.w + S and r.y - S <= py and py <= r.y + r.h + S) then return nil end
  local near = {left = px - r.x, right = r.x + r.w - px, top = py - r.y, bottom = r.y + r.h - py}
  local side, best
  for _, s in ipairs({"left", "right", "top", "bottom"}) do       -- (min over the dict: the first of equals)
    if best == nil or near[s] < best then side, best = s, near[s] end
  end
  return best <= S and side or nil
end

local function index_of(d) for i, x in ipairs(all) do if x == d then return i end end end
function DK:rect(side)
  side = side or self.side
  if not side then return nil end
  local r = DK.game_rect()
  local x, y, w, h = r.x, r.y, r.w, r.h
  local mates = {}
  for _, d in ipairs(all) do if d.side == side and d.win:visible() and d ~= self then mates[#mates + 1] = d end end
  local n = #mates + 1
  local k = 0
  for _, d in ipairs(mates) do if index_of(d) < index_of(self) then k = k + 1 end end
  local across = (side == "left" or side == "right") and w or h
  local least = (side == "left" or side == "right") and (self.win.min_w or 0) or (self.win.min_h or 0)
  local size = math.min(math.max(DK.MIN, self.size + ((side == "left" or side == "right") and self.extra() or 0), least),
                        across - 120)
  local lefts, rights = 0, 0
  for _, d in ipairs(all) do
    if d.side == "left" and d.win:visible() then lefts = math.max(lefts, d.size) end
    if d.side == "right" and d.win:visible() then rights = math.max(rights, d.size) end
  end
  if side == "left" or side == "right" then
    local part = h // n
    local top = y + k * part
    local left = side == "left" and x or x + w - size
    return {x = left, y = top, w = size, h = k < n - 1 and part or h - k * part}
  end
  local x0, x1 = x + lefts, x + w - rights
  local part = (x1 - x0) // n
  local top = side == "top" and y or y + h - size
  return {x = x0 + k * part, y = top, w = k < n - 1 and part or (x1 - x0) - k * part, h = size}
end

function DK:preview(r)
  local hud = self.ed and self.ed.hud
  if hud then hud.dock_preview = r end
end
function DK:others()
  for _, d in ipairs(all) do
    if d ~= self and d.side and d.win:visible() then d:apply() end
  end
  if self.ed then self.ed.insets = DK.insets() end
end

function DK:drag_moved(mx, my)
  if self.side then
    self.side = nil
    local g = self.win.rect
    local fw, fh
    if self.float_size then fw, fh = self.float_size[1], self.float_size[2]
    else fw, fh = math.max(DK.MIN, math.min(g.w, 520)), math.max(DK.MIN, math.min(g.h, 640)) end
    self.win.rect = {x = mx - fw // 2, y = my - 12, w = fw, h = fh}
    self:keep()
    self:others()
  end
  self.candidate = self:side_at(mx, my)
  self:preview(self.candidate and self:rect(self.candidate) or nil)
end
function DK:drag_released(mx, my)
  local side = self:side_at(mx, my)
  self.candidate = nil
  self:preview(nil)
  if side then self:dock(side) end
  return side
end
function DK:dock(side)
  if not self.side then
    local g = self.win.rect
    self.float_size = {g.w, g.h}
  end
  self.side = side
  self:keep()
  self:apply()
  self:others()
end
function DK:inner_edge() return INNER[self.side] end
function DK:resized()
  if not self.side then return end
  local g = self.win.rect
  self.size = math.max(DK.MIN, (self.side == "left" or self.side == "right") and g.w - self.extra() or g.h)
  self:keep()
  self:apply()
  self:others()
end
function DK:apply()
  local r = self:rect()
  if r then
    local g = self.win.rect
    if not g or g.x ~= r.x or g.y ~= r.y or g.w ~= r.w or g.h ~= r.h then self.win.rect = r end
  end
  return r ~= nil
end

-- --- the header drag and the border resize (dock.Mover; the panel's _frame_mouse is the same) ---
DK.EDGE = 7
local MV = {}
MV.__index = MV
DK.movers = {}
-- opts: min_w, min_h; keep(rect): where it floats, kept (the panel keeps it less its inspector); hit(id, r)
function DK.mover(win, key, ed, opts)
  opts = opts or {}
  local self = setmetatable({win = win, key = key, ed = ed, min_w = opts.min_w or 360, min_h = opts.min_h or 240,
                             keep = opts.keep, hit = opts.hit}, MV)
  self.docker = opts.docker or DK.new(win, key, ed)
  DK.movers[#DK.movers + 1] = self
  return self
end
-- a window moved or resized right now (the overlay keeps the mouse while it is dragged: past the window's edge of
-- the frame before, the game took it - 23.10.: moving was laggy)
function DK.busy_any()
  for _, m in ipairs(DK.movers) do if m.drag ~= nil or m.resize ~= nil then return true end end
  return false
end
-- the window where the mouse has it now, before the window lays itself out and draws (MV:frame comes after its
-- controls: the window followed a frame late)
function MV:follow()
  if self.max_from then                       -- (maximized: the whole game below the bar, also at a new size)
    local g = DK.game_rect()
    local r = self.win.rect
    if r.x ~= g.x or r.y ~= g.y or r.w ~= g.w or r.h ~= g.h then self.win.rect = g end
  end
  if not w3.ui.mouse_down(1) then return end
  local mx, my = w3.ui.mouse()
  local d = self.drag
  if d and d.moved and self.docker.side == nil then
    self.win.rect = {x = d[3] + mx - d[1], y = d[4] + my - d[2], w = self.win.rect.w, h = self.win.rect.h}
  elseif self.resize then
    self.win.rect = self:resized_rect(mx, my)
  end
end
function MV:resized_rect(mx, my)
  local s = self.resize
  local g, ed = s[3], s[4]
  local dx, dy = mx - s[1], my - s[2]
  local left, top, right, bottom = g.x, g.y, g.x + g.w - 1, g.y + g.h - 1
  if ed[1] then left = math.min(g.x + dx, right - self.min_w) end
  if ed[3] then right = math.max(right + dx, left + self.min_w) end
  if ed[2] then top = math.min(g.y + dy, bottom - self.min_h) end
  if ed[4] then bottom = math.max(bottom + dy, top + self.min_h) end
  return {x = left, y = top, w = right - left + 1, h = bottom - top + 1}
end
function MV:keep_rect()
  if self.keep then return self.keep(self.win.rect) end
  local g = self.win.rect
  local cfg = CFG.load()
  cfg[self.key .. "_rect"] = Y.list({g.x, g.y, g.w, g.h})
  CFG.save(cfg)
end
function MV:kept_rect()
  local r = CFG.load()[self.key .. "_rect"]
  if type(r) == "table" and #r == 4 then return {x = r[1], y = r[2], w = r[3], h = r[4]} end
end
-- which borders a point of the window is on (docked: only the inner one)
function MV:edges(px, py)
  local r, e = self.win.rect, DK.EDGE
  local lx, ly = px - r.x, py - r.y
  local found = {lx < e, ly < e, lx > r.w - e, ly > r.h - e}
  local inner = self.docker:inner_edge()
  if not inner then return found end
  local keep = ({left = 1, top = 2, right = 3, bottom = 4})[inner]
  local out = {false, false, false, false}
  out[keep] = found[keep]
  return out
end
-- every frame, after the window's own controls (they take the mouse first): header {x, y, w, h}; buttons: the
-- header's buttons and fields ({x, y, w, h} each) - the arrow there, not the move cursor (the app's ArrowCursor on
-- them: MaximdeWinter 23.10., the move cursor showed over the whole header - ImGui calls a box hovered under an earlier one)
function MV:frame(header, buttons)
  local mx, my = w3.ui.mouse()
  local r = self.win.rect
  local hid = "dock." .. self.key
  -- the header (what its buttons leave of it) and the borders, as hit boxes
  local _, on_header = self.hit(hid .. ".head", header)
  for _, b in ipairs(buttons or {}) do
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then on_header = false end
  end
  local e = DK.EDGE
  local over_edge = false
  for i, b in ipairs({{x = r.x, y = r.y, w = e, h = r.h}, {x = r.x, y = r.y, w = r.w, h = e},
                      {x = r.x + r.w - e, y = r.y, w = e, h = r.h}, {x = r.x, y = r.y + r.h - e, w = r.w, h = e}}) do
    local _, hv = self.hit(hid .. ".edge" .. i, b)
    if hv then over_edge = true end
  end
  if on_header and not self.drag and not self.resize then w3.ui.cursor("move") end
  local function shape(el, et, er, eb)
    if (el and et) or (er and eb) then return "nwse" end
    if (er and et) or (el and eb) then return "nesw" end
    if el or er then return "ew" end
    if et or eb then return "ns" end
  end
  if over_edge and not self.drag then
    local ed = self:edges(mx, my)
    local s = shape(ed[1], ed[2], ed[3], ed[4])
    if s then w3.ui.cursor(s) end
  end
  if on_header and w3.ui.mouse_double(1) and not self.drag then
    self:toggle_max()
    return
  end
  if self.max_from then over_edge = false end   -- (maximized: no resizing)
  if w3.ui.mouse_clicked(1) then
    if on_header then
      self.drag = {mx, my, r.x, r.y, moved = false}
    elseif over_edge then
      local ed = self:edges(mx, my)
      if ed[1] or ed[2] or ed[3] or ed[4] then self.resize = {mx, my, {x = r.x, y = r.y, w = r.w, h = r.h}, ed} end
    end
  end
  if self.drag then
    local d = self.drag
    if w3.ui.mouse_down(1) then
      if d.moved or math.abs(mx - d[1]) + math.abs(my - d[2]) >= 4 then
        if not d.moved and self.max_from then
          local f, g = self.max_from, self.win.rect
          self.max_from = nil
          local nx = math.floor(mx - f.w * (mx - g.x) / math.max(1, g.w))
          self.win.rect = {x = nx, y = g.y, w = f.w, h = f.h}
          d[1], d[2], d[3], d[4] = mx, my, nx, g.y
        end
        d.moved = true
        local was = self.docker.side
        if was == nil then
          self.win.rect = {x = d[3] + mx - d[1], y = d[4] + my - d[2], w = self.win.rect.w, h = self.win.rect.h}
        end
        self.docker:drag_moved(mx, my)
        if was ~= nil then
          local g = self.win.rect
          d[1], d[2], d[3], d[4] = mx, my, g.x, g.y
        end
      end
      w3.ui.cursor("move")
    else
      self.drag = nil
      if d.moved then
        if not self.docker:drag_released(mx, my) then self:keep_rect() end
      end
    end
  elseif self.resize then
    local s = self.resize
    if w3.ui.mouse_down(1) then
      local ed = s[4]
      self.win.rect = self:resized_rect(mx, my)
      local c = shape(ed[1], ed[2], ed[3], ed[4])
      if c then w3.ui.cursor(c) end
    else
      self.resize = nil
      if self.docker.side then self.docker:resized() else self:keep_rect() end
    end
  end
end
function MV:busy() return self.drag ~= nil or self.resize ~= nil end

-- Maximize, as Windows does (MaximdeWinter 24.10.): the window over the whole game below the bar, or back where it was; the
-- header's button, or a double click on the header. Dragged by its header it comes back to its size under the mouse.
function MV:maximized() return self.max_from ~= nil end
function MV:toggle_max()
  local r = self.win.rect
  if self.max_from then
    self.win.rect = self.max_from
    self.max_from = nil
  else
    self.max_from = {x = r.x, y = r.y, w = r.w, h = r.h}
    self.win.rect = DK.game_rect()
  end
end

return DK
