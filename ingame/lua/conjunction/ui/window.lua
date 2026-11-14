-- Conjunction's windows over the game (item_chooser.py CatalogWindow: every window works like the Asset Browser):
-- frameless like the panel (#panel: rgba(24,24,26,235), a 1 px #444 border), its header 26 high (the title bold 14 px
-- #eee, the x: 24 x 20, transparent, #5a2a2a under the mouse), the body below (margins 8 2 8 6, 4 apart); moved by its
-- header, resized at its border, docked at a side (ui/dock.lua, key "window_<kind>"). Several at once, one per purpose
-- (key). Where it stood is kept per kind (config "catalog_windows").
--   local w = WIN.new(panel, key, title, kind)   w.body = {frame = function(self, r) ... end}   w:frame()   w:close()
--   w:hit(id, r)  (its own ids: "win.<key>.<id>")
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local CFG = require("conjunction.config")
local Y = require("conjunction.yaml")
local DK = require("conjunction.ui.dock")
local D = w3.ui.draw
local WIN = {}
WIN.__index = WIN

local function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | (a or 255) end
WIN.C = {bg = rgba(24, 24, 26, 235), edge = rgba(0x44, 0x44, 0x44), title = rgba(0xee, 0xee, 0xee),
         close_hover = rgba(0x5a, 0x2a, 0x2a), x = rgba(0xcf, 0xcf, 0xcf)}
local C = WIN.C
WIN.HEADER_H = 26

-- a window at x, y, w wide has its header on the screen (at least 60 px of it across)
function WIN.header_seen(x, y, w)
  local W, H = DK.W or 1920, DK.H or 1080
  return x + w >= 60 and x <= W - 60 and y >= 0 and y <= H - WIN.HEADER_H
end

function WIN.new(panel, key, title, kind)
  kind = kind or "items"
  local self = setmetatable({panel = panel, key = key, title = title, kind = kind, shown = true, body = nil}, WIN)
  self.ed = panel.ed
  local kept = CFG.load().catalog_windows
  local r = type(kept) == "table" and kept[kind] or nil
  -- (where it was kept, if its header is on the screen: MaximdeWinter 24.10. - the item and the loot window were kept at
  -- -8000, -8000 and opened where nobody saw them; "+ Add item" seemed to do nothing)
  if type(r) == "table" and #r == 4 and WIN.header_seen(r[1], r[2], r[3]) then
    self.rect = {x = r[1], y = r[2], w = r[3], h = r[4]}
  else
    local g = panel.rect or {x = 12, y = 96, w = 516, h = 790}
    self.rect = {x = g.x + 60, y = g.y + 60, w = math.max(760, g.w - 120), h = math.max(560, g.h - 120)}
  end
  -- (inside the picture: 11.11., at 1280 x 720 the content pack window reached 106 px under its edge, Build pack
  -- with it)
  local W, H, r = DK.W or 1920, DK.H or 1080, self.rect
  r.x, r.y = math.max(0, math.min(r.x, W - 368)), math.max(0, math.min(r.y, H - 248))
  r.w, r.h = math.max(360, math.min(r.w, W - r.x - 8)), math.max(240, math.min(r.h, H - r.y - 8))
  self.min_w, self.min_h = 360, 240
  self.mover = DK.mover(self, "window_" .. kind, panel.ed, {min_w = 360, min_h = 240,
                                                             hit = function(id, rr) return self:hit(id, rr) end,
                                                             keep = function() end})
  self.extra = 0
  self.mover.docker.extra = function() return self.extra end
  self.mover.docker:apply()                       -- (docked: at its side again)
  return self
end
-- px an inspector adds beside the body (the panel's inspector_extra, MaximdeWinter 25.10.: "1 zu 1 der asset manager"): the
-- window grows by it at its right, what it had stays as wide; docked it grows into the game; kept without it
function WIN:set_extra(px)
  local delta = px - self.extra
  if delta == 0 then return end
  self.extra = px
  self.mover.min_w = self.min_w + px
  if self.mover.max_from then self.mover.max_from.w = self.mover.max_from.w + delta end
  if self.mover.docker:apply() or self.mover.max_from then return end
  local r = self.rect
  local W = DK.W or 1920
  local x, w = r.x, math.max(self.mover.min_w, r.w + delta)
  if delta > 0 then                               -- (it stays on the screen: further left, at most as wide as it)
    w = math.min(w, W)
    if x + w > W then x = math.max(0, W - w) end
  end
  self.rect = {x = x, y = r.y, w = w, h = r.h}
end

function WIN:visible() return self.shown end
-- a hit box of this window (nothing over it: a window above, the bar, an open list)
function WIN:hit(id, r)
  local mx, my = w3.ui.mouse()
  if CT.blocker and CT.blocker(mx, my) then return false, false, false end
  w3.ui.set_pos(r.x, r.y)
  local clicked, hovered, held = w3.ui.hit("win." .. self.key .. "." .. id, r.w, r.h)
  if CT.IM.covers(mx, my) then return false, false, false end
  return clicked == 1, hovered, held
end
function WIN:covers(x, y)
  if self.shown and self.body and self.body.full_screen and self.body:full_screen() then
    return self.body:covers_full(x, y)            -- (its middle is the game's: the mouse goes to the game there)
  end
  local r = self.rect
  return self.shown and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

function WIN:frame()
  if not self.shown then return end
  -- a body that takes the whole screen (the scene workshop's cutscene editor: the game shows through its middle):
  -- no background, no header, the body lays out its own parts
  if self.body and self.body.full_screen and self.body:full_screen() then
    local was = Q.translucent
    Q.translucent = true
    self.body:frame_full({x = 0, y = 0, w = DK.W or 1920, h = DK.H or 1080})
    Q.translucent = was
    return
  end
  self.mover:follow()
  local r = self.rect
  local was = Q.translucent
  Q.translucent = true                   -- (a translucent window like the panel: Q.text decides per pixel)
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  D.rect(r.x, r.y, r.w, r.h, C.edge, 1)
  -- the column inside the frame: margins 8 2 8 6, spacing 4
  local x, y, w = r.x + 1 + 8, r.y + 1 + 2, r.w - 2 - 16
  local body = {x = x, y = y + WIN.HEADER_H + 4, w = w, h = r.y + r.h - 1 - 6 - (y + WIN.HEADER_H + 4)}
  if self.body and self.body.max_h and self.body.max_h < body.h then
    -- a body that grows no further (QInputDialog: SetMinAndMaxSize): the column's room left goes into its gaps,
    -- before the header, between, after the body (qGeomCalc)
    local L = require("conjunction.ui.layout")
    local mh = self.body.max_h
    local placed = L.column({{hint = WIN.HEADER_H, min = WIN.HEADER_H, max = WIN.HEADER_H},
                             {hint = mh, min = mh, max = mh, stretch = 1}}, x, y, w, r.y + r.h - 1 - 6 - y,
                            {spacing = 4})
    y = placed[1].y
    body = {x = x, y = placed[2].y, w = w, h = placed[2].h}
  end
  local header = {x = x, y = y, w = w, h = WIN.HEADER_H}
  -- the title (margins 2 0 0 0), the x at the right, in the middle of the header
  local th = Q.line_h(14, true)
  Q.text(x + 2, y + Q.vcenter(WIN.HEADER_H, th), C.title, self.title, 14, true)
  local xb = {x = x + w - 24, y = y + (WIN.HEADER_H - 20) // 2, w = 24, h = 20}
  local clicked, hovered = self:hit("close", xb)
  if hovered then D.fill(xb.x, xb.y, xb.w, xb.h, C.close_hover) CT.tip("panel.win.close", "ic.close") end
  Q.draw_icon("x", C.x, 14, xb.x + (xb.w - 14) // 2, xb.y + (xb.h - 14) // 2)
  -- maximize / back left of it (dock.lua; MaximdeWinter 24.10.)
  local mb = {x = xb.x - 24 - 2, y = xb.y, w = 24, h = 20}
  local mclicked, mhovered = self:hit("max", mb)
  local maxed = self.mover:maximized()
  if mhovered then D.fill(mb.x, mb.y, mb.w, mb.h, 0xffffff14) CT.tip("panel.win.max", {"", maxed and "Back to its size" or "Fills the screen"}) end
  Q.draw_icon(maxed and "copy" or "square", C.x, 14, mb.x + (mb.w - 14) // 2, mb.y + (mb.h - 14) // 2)
  if self.body then self.body:frame(body) end
  self.mover:frame(header, {xb, mb})
  if mclicked then self.mover:toggle_max() end
  Q.translucent = was
  if clicked then self:close() end
end

function WIN:close()
  if not self.shown then return end
  self.shown = false
  local cfg = CFG.load()
  local wins = Y.map({})
  if type(cfg.catalog_windows) == "table" then
    for _, k in ipairs(Y.keys(cfg.catalog_windows)) do wins[k] = cfg.catalog_windows[k] end
  end
  local g = self.rect
  wins[self.kind] = Y.list({g.x, g.y, g.w - self.extra, g.h})
  cfg.catalog_windows = wins
  CFG.save(cfg)
  if self.body and self.body.closed then self.body:closed() end      -- (what it still holds kept)
  if self.panel.window_closed then self.panel:window_closed(self) end
  if self.on_closed then self.on_closed() end
end

return WIN
