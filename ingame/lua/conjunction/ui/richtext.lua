-- A QTextBrowser showing rich text (HTML or Markdown): the document set and painted by Qt itself (cj_qt_rich: its
-- QTextDocument at the viewport's width, the widget's font and colours, opaque - ClearType as in the window), the part
-- that shows drawn, scrolled per pixel (20 a step, 3 a notch), the bar where it is longer than the viewport.
--   local v = RT.new(file, "html" | "markdown", {px =, fg =, bg =, edge =, pad =})   v:frame(r, hit)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local D = w3.ui.draw
local RT = {}
RT.__index = RT
RT.LINK = (0x48 << 24) | (0x9c << 16) | (0xf0 << 8) | 255      -- (the palette's link colour)

local seq = 0
function RT.new(file, format, style)
  style = style or {}
  local self = setmetatable({file = file, format = format or "html", px = style.px or T.FONT, fg = style.fg or T.BRIGHT,
                             bg = style.bg or T.FIELD, edge = style.edge or T.EDGE, pad = style.pad or 5,
                             bar = IV.bar(20, 0, 0)}, RT)
  return self
end

-- the document at a width (painted again when the width changes)
function RT:paint(width)
  if self.width == width and self.pic ~= nil then return self.pic end
  -- (Qt's application has to be up: cj_qt_rich waits for it - the mod starts it with the editor, init.lua)
  self.width = width
  seq = seq + 1
  local out = string.format("%s\\cj_rich_%d.png", os.getenv("TEMP") or ".", seq)
  local good, res = pcall(w3.plugin.cj_qt_rich, out, tostring(width), self.format, self.file, tostring(self.px),
                          string.format("%08x", self.fg), string.format("%08x", self.bg), string.format("%08x", RT.LINK))
  if self.pic then w3.ui.image_free(self.pic.id) end
  self.pic = false
  if good then
    local id, w, h = w3.ui.image_load(out)
    if id then self.pic = {id = id, w = w, h = h} end
  else
    print("[richtext] " .. tostring(res))
  end
  if self.out then w3.fs.remove(self.out) end
  self.out = out
  return self.pic
end

function RT:frame(r, hit)
  Q.frame(r.x, r.y, r.w, r.h, self.bg, self.edge)
  local vx, vy = r.x + 1 + self.pad, r.y + 1 + self.pad
  local vw, vh = r.w - 2 - 2 * self.pad, r.h - 2 - 2 * self.pad
  local pic = self:paint(vw)
  local bar = false
  if pic and pic.h > vh then
    bar = true
    pic = self:paint(vw - 10)                       -- (the bar takes its room: the text is set again narrower)
  end
  if not pic then return end
  local w_ = vw - (bar and 10 or 0)
  local b = self.bar
  b.single, b.page = 20, vh
  IV.range(b, math.max(0, pic.h - vh))
  if CT.over({x = vx, y = vy, w = w_, h = vh}) then
    local _, _, wheel = w3.ui.mouse()
    if wheel and wheel ~= 0 then IV.wheel(b, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  end
  D.clip(vx, vy, w_, vh, function() D.image(pic.id, vx, vy - b.value, pic.w, pic.h) end)
  if bar then SBAR.draw(self, "rich.vbar." .. tostring(self.file), b, {x = vx + w_, y = vy, w = 10, h = vh}, "v", hit) end
end

return RT
