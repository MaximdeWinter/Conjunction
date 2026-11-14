-- A message over the game (panel.Notice): stays until closed (a failed build) or goes by itself (a build that
-- worked, after ms). A frame rgba(24,24,26,240) with a 1 px border in its colour (red #e57a7a for an error, green
-- #9fd38a else), inside margins 12 8 8 8, 6 apart: the text (bold 13 px in that colour, wrapped, at most 620 wide),
-- for an error the Build tab button, the x (24 x 22). As wide as Qt's adjustSize makes it (its hint, at least 200:
-- the text has a stretch), centred over the game, 60 below its top. Drawn over everything.
--   local n = NT.new(panel)   n:say(text, error, ms)   n:dismiss()   n:frame(W, H)   n:covers(x, y)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local TL = require("conjunction.ui.textlayout")
local D = w3.ui.draw
local NT = {}
NT.__index = NT

local function rgba(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
NT.C = {bg = (24 << 24) | (24 << 16) | (26 << 8) | 240, error = rgba("#e57a7a"), ok = rgba("#9fd38a"),
        x = rgba("#cfcfcf")}
local C = NT.C
NT.MAX_W = 620
NT.SPACING = 6

function NT.new(panel)
  return setmetatable({panel = panel, wanted = false, text = "", error = false, until_ = nil}, NT)
end

function NT:say(text, error, ms)
  self.text = tostring(text)
  self.error = error and true or false
  self.wanted = true
  self.ms = (not self.error) and (ms or 8000) or nil   -- (counted from its first frame: say may come from anywhere)
  self.until_ = nil
  self.geom = nil
end
function NT:dismiss()
  self.wanted = false
  self.ms, self.until_ = nil, nil
end

-- the text's lines at a width (fm.boundingRect with word wrap): {{s, w}}, its size
local function lines_at(text, w)
  local ls = TL.wrap(text, 13, true, math.max(0, w), "word")
  local bw = 0
  for _, l in ipairs(ls) do bw = math.max(bw, math.ceil(l.w - 1e-9)) end
  return ls, bw, math.max(1, #ls) * Q.line_h(13, true)
end
-- QLabel's size hint with word wrap (QLabelPrivate::sizeForWidth(-1)): 80 average letters (at most its maximum
-- width), half of it while it gives fewer than 4 lines, a quarter while fewer than 2
local function label_hint(text)
  local w = math.min(Q.avg_w(13, true) * 80, NT.MAX_W)
  local lh = Q.line_h(13, true)
  local _, bw, bh = lines_at(text, w)
  if bh < 4 * lh and bw > w // 2 then _, bw, bh = lines_at(text, w // 2) end
  if bh < 2 * lh and bw > w // 4 then _, bw, bh = lines_at(text, w // 4) end
  return bw, bh
end

-- where everything is, relative to the notice's top left
function NT:layout()
  if self.geom then return self.geom end
  local S = NT.SPACING
  local bw, bh = Q.button_size("Build tab")
  local lw = label_hint(self.text)
  local fixed = 1 + 12 + S + 24 + 8 + 1 + (self.error and (bw + S) or 0)
  local w = math.max(lw + fixed, 200)
  lw = w - fixed                                -- (the text takes what is left: its stretch)
  local lines, _, lh = lines_at(self.text, lw)
  local inner = math.max(lh, 22, self.error and bh or 0)
  local g = {w = w, h = 1 + 8 + inner + 8 + 1, lines = lines}
  g.label = {x = 13, y = 9 + inner // 2 - lh // 2, w = lw, h = lh}   -- (QStyle::alignedRect halves each)
  local x = 13 + lw + S
  if self.error then
    g.more = {x = x, y = 9 + (inner - bh) // 2, w = bw, h = bh}
    x = x + bw + S
  end
  g.close = {x = x, y = 9 + (inner - 22) // 2, w = 24, h = 22}
  self.geom = g
  return g
end

function NT:visible() return self.wanted end
function NT:covers(x, y)
  local r = self.rect
  return self.wanted and r ~= nil and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end
function NT:hit(id, r)
  w3.ui.set_pos(r.x, r.y)
  local clicked, hovered, held = w3.ui.hit("notice." .. id, r.w, r.h)
  return clicked == 1, hovered, held
end

-- a push button of theme.py (the panel's style: its text #ddd); icon: the x instead of a text
local function push(self, id, b, text, tip)
  local clicked, hv, held = self:hit(id, b)
  local bg, edge = T.BUTTON, (hv or held) and T.EDGE_HOVER or T.EDGE
  if held and hv then bg = T.CHOSEN end
  if text then
    Q.button(b.x, b.y, b.w, b.h, text, {hover = hv or held, pressed = held and hv, fg = T.BUTTON_TEXT})
  else
    Q.frame(b.x, b.y, b.w, b.h, bg, edge)
    Q.draw_icon("x", C.x, 14, b.x + 11 + (b.w - 22 - 16) // 2 + 1, b.y + 6 + (b.h - 12 - 16) // 2 + 1)
  end
  if hv then CT.tip("notice." .. id, tip) end
  return clicked
end

-- where it stands: centred over the game, 60 below its top
function NT:place(W, _H, g) return (W - g.w) // 2, 60 end

-- one frame: W, H the game's client size
function NT:frame(W, H)
  if self.wanted and self.ms and not self.until_ then self.until_ = w3.ui.time() + self.ms / 1000 end
  if self.wanted and self.until_ and w3.ui.time() >= self.until_ then self:dismiss() end
  if not self.wanted then self.rect = nil return end
  local g = self:layout()
  local x, y = self:place(W, H, g)
  local r = {x = x, y = y, w = g.w, h = g.h}
  self.rect = r
  local colour = self.error and C.error or C.ok
  local was = Q.translucent
  Q.translucent = true                   -- (its window is translucent: Q.text decides per pixel)
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  D.rect(r.x, r.y, r.w, r.h, colour, 1)
  local lh = Q.line_h(13, true)
  for k, l in ipairs(g.lines) do
    Q.text(r.x + g.label.x, r.y + g.label.y + (k - 1) * lh, colour, l.s, 13, true)
  end
  local function at(b) return {x = r.x + b.x, y = r.y + b.y, w = b.w, h = b.h} end
  local more = g.more and push(self, "more", at(g.more), "Build tab", "pan.notice_more")
  local close = push(self, "close", at(g.close), nil, "pan.notice_close")
  Q.translucent = was
  if close then self:dismiss() end
  if more then
    self:dismiss()
    local p = self.panel
    if p.open_build then p:open_build() end
  end
end

return NT
