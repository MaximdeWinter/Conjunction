-- Mark the problem (bugreport_view.Annotate): a screenshot to draw on - pen, arrow, box, text; four colours; undo -
-- then Done keeps the marked picture. Its own sheet (#bug #232326; QToolButton#tool #2e2e33, a 1 px #444 border,
-- padding 3; chosen #44444a with a #d9d9d9 border; the colours 22 x 22 with a 2 px #333 border, the chosen one's
-- white). A QVBoxLayout (margins 11, 6 apart): the tools' row, the picture fitted to the screen (at most 85 % of its
-- width, 80 % of its height, never larger). The marks are drawn by Qt itself (cj_qt_paint: the same QPainter calls
-- as Annotate._draw, antialiased round pens max(3, w / 400) wide) into the picture, the canvas shows it scaled as
-- Qt's QLabel does; a mark being drawn shows at once over it.
--   AN.open(ed, png, then_)   then_(marked png | nil)      AN.commands(png, w, h, marks) -> cj_qt_paint's commands
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local D = w3.ui.draw
local AN = {}
AN.__index = AN

local function rgb(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
AN.COLOURS = {"#ff3b30", "#ffcc00", "#34c759", "#ffffff"}
AN.TOOLS = {{"pen", "pencil", "bug.pen"}, {"arrow", "move-up-right", "bug.arrow"}, {"box", "square", "bug.box"},
            {"text", "type", "bug.text"}}
AN.C = {bg = rgb("#232326"), tool = rgb("#2e2e33"), tool_edge = rgb("#444444"), chosen = rgb("#44444a"),
        chosen_edge = rgb("#d9d9d9"), swatch_edge = rgb("#333333"), white = rgb("#ffffff"), text = rgb("#dddddd")}
local C = AN.C
local GREY = rgb("#cfcfcf")

-- QLineF: angle (degrees, counter-clockwise, y down), setLength, setAngle
local function angle(x1, y1, x2, y2)
  local t = math.atan(-(y2 - y1), x2 - x1) * (180 / math.pi)
  if t < 0 then t = t + 360 end
  if math.abs(t - 360) * 1e12 <= math.min(math.abs(t), 360) then return 0 end   -- (qFuzzyCompare(t, 360))
  return t
end
local function arrow_heads(a, b, w)
  -- line = QLineF(b, a); each head: QLineF(line), setLength(w * 6), setAngle(line.angle() + turn)
  local ang = angle(b[1], b[2], a[1], a[2])
  local out = {}
  for _, turn in ipairs({25, -25}) do
    local len = math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
    local x2, y2 = a[1], a[2]
    if len > 0 then                                   -- (setLength: a null line stays as it is)
      x2 = b[1] + (a[1] - b[1]) * (w * 6 / len)
      y2 = b[2] + (a[2] - b[2]) * (w * 6 / len)
    end
    local l = math.sqrt((x2 - b[1]) ^ 2 + (y2 - b[2]) ^ 2)
    local r = (ang + turn) * (math.pi / 180)
    out[#out + 1] = {b[1], b[2], b[1] + math.cos(r) * l, b[2] - math.sin(r) * l}
  end
  return out
end
local function num(x) return string.format("%.17g", x) end

-- cj_qt_paint's commands for the picture with its marks (Annotate._draw)
function AN.commands(png, w, h, marks)
  local out = {"image 0 0 0 0 " .. png, "aa 1"}
  local pw = math.max(3.0, w / 400)
  for _, m in ipairs(marks) do
    local tool, colour, data = m[1], m[2], m[3]
    out[#out + 1] = string.format("pen %sff %s 32 128 1", colour:sub(2), num(pw))     -- (RoundCap, RoundJoin, solid)
    out[#out + 1] = "nobrush"
    if tool == "pen" then
      local pts = {}
      for _, p in ipairs(data) do pts[#pts + 1] = num(p[1]) pts[#pts + 1] = num(p[2]) end
      out[#out + 1] = "polylinef " .. table.concat(pts, " ")
    elseif tool == "box" then
      local x1, y1, x2, y2 = data[1][1], data[1][2], data[2][1], data[2][2]
      local x, y = math.min(x1, x2), math.min(y1, y2)                  -- (QRectF(a, b).normalized())
      out[#out + 1] = string.format("rectf %s %s %s %s", num(x), num(y), num(math.abs(x2 - x1)), num(math.abs(y2 - y1)))
    elseif tool == "arrow" then
      local a, b = data[1], data[2]
      out[#out + 1] = string.format("linef %s %s %s %s", num(a[1]), num(a[2]), num(b[1]), num(b[2]))
      for _, hd in ipairs(arrow_heads(a, b, pw)) do
        out[#out + 1] = string.format("linef %s %s %s %s", num(hd[1]), num(hd[2]), num(hd[3]), num(hd[4]))
      end
    elseif tool == "text" then
      out[#out + 1] = string.format("font %s 1", num(math.max(14.0, w / 90)))
      out[#out + 1] = string.format("text %s %s %s", num(data[1][1]), num(data[1][2]), data[2])
    end
  end
  return table.concat(out, "\n")
end

function AN.new(ed, png, then_, screen_w, screen_h)
  local self = setmetatable({ed = ed, png = png, then_ = then_, marks = {}, tool = "pen", colour = AN.COLOURS[1]}, AN)
  local id, w, h = w3.ui.image_load(png)
  self.base = id and {id = id, w = w, h = h} or nil
  self.w, self.h = w or 1, h or 1
  local sw, sh = screen_w or 1600, screen_h or 900
  self.scale = math.min(1.0, (sw * 0.85) / self.w, (sh * 0.8) / self.h)
  self.cw, self.ch = math.floor(self.w * self.scale), math.floor(self.h * self.scale)
  if w3.plugin and w3.plugin.cj_qt_gl_start then pcall(w3.plugin.cj_qt_gl_start) end   -- (text needs Qt's app)
  self.seq = 0
  self:paint()
  return self
end

-- the canvas: the marked picture scaled as QPixmap.scaled(canvas, KeepAspectRatio, Smooth) gives it
function AN:paint()
  self.seq = self.seq + 1
  local out = string.format("%s.marked_view_%d.png", self.png, self.seq)
  local ok, r = pcall(w3.plugin.cj_qt_paint, out, tostring(self.w), tostring(self.h),
                      AN.commands(self.png, self.w, self.h, self.marks), self.cw .. " " .. self.ch)
  if ok then
    local id, w, h = w3.ui.image_load(out)
    if self.view then w3.ui.image_free(self.view.id) end
    self.view = id and {id = id, w = w, h = h} or nil
    if self.view_file then w3.fs.remove(self.view_file) end
    self.view_file = out
  else
    print("[annotate] " .. tostring(r))
  end
end

function AN:size_hint()
  local _, bh = Q.button_size("Cancel")
  return 11 + self.cw + 11, 11 + bh + 6 + self.ch + 11
end

function AN:done()
  local out = self.png:gsub("%.png$", "") .. "_marked.png"
  local ok = pcall(w3.plugin.cj_qt_paint, out, tostring(self.w), tostring(self.h),
                   AN.commands(self.png, self.w, self.h, self.marks))
  if self.win then self.win:close() end
  if self.view_file then w3.fs.remove(self.view_file) end
  if self.then_ then self.then_(ok and out or nil) end
end
function AN:cancel()
  if self.win then self.win:close() end
  if self.view_file then w3.fs.remove(self.view_file) end
  if self.then_ then self.then_(nil) end
end

local function hit(self, id, r)
  if self.win then return self.win:hit(id, r) end
  w3.ui.set_pos(r.x, r.y)
  local c, hv, held = w3.ui.hit("annotate." .. id, r.w, r.h)
  return c == 1, hv, held
end

function AN:frame(r)
  D.fill(r.x, r.y, r.w, r.h, C.bg)
  local x, y = r.x + 11, r.y + 11
  local ow, bh = Q.button_size("Done")
  local cw = Q.button_size("Cancel")
  -- the tools (27 x 27, in the row's middle), the colours (22 x 22), undo (23 x 23)
  local bx = x
  for _, t in ipairs(AN.TOOLS) do
    local b = {x = bx, y = y + (bh - 27) // 2, w = 27, h = 27}
    local clicked, hv = hit(self, "tool." .. t[1], b)
    local on = self.tool == t[1]
    Q.frame(b.x, b.y, b.w, b.h, on and C.chosen or C.tool, on and C.chosen_edge or C.tool_edge)
    Q.draw_icon(t[2], GREY, 16, b.x + 5, b.y + 5)
    if hv then CT.tip("annotate." .. t[1], t[3]) end
    if clicked then self.tool = t[1] end
    bx = bx + 27 + 6
  end
  bx = bx + 12
  for _, c in ipairs(AN.COLOURS) do
    local b = {x = bx, y = y + (bh - 22) // 2, w = 22, h = 22}
    local clicked, hv = hit(self, "colour." .. c, b)
    D.fill(b.x, b.y, b.w, b.h, rgb(c))
    D.rect(b.x, b.y, b.w, b.h, self.colour == c and C.white or C.swatch_edge, 2)
    if hv then CT.tip("annotate.colour", "bug.colour") end
    if clicked then self.colour = c end
    bx = bx + 22 + 6
  end
  bx = bx + 12
  do
    local b = {x = bx, y = y + (bh - 23) // 2, w = 23, h = 23}
    local clicked, hv = hit(self, "undo", b)
    if hv then                                      -- (icons.icon_button: rgba(255,255,255,0.08) under the mouse)
      D.fill(b.x, b.y, b.w, b.h, (255 << 24) | (255 << 16) | (255 << 8) | 20)
      CT.tip("annotate.undo", "bug.undo")
    end
    Q.draw_icon("undo-2", GREY, 16, b.x + 3, b.y + 3)
    if clicked and #self.marks > 0 then table.remove(self.marks) self:paint() end
  end
  local dx = r.x + r.w - 11 - ow
  local cx = dx - 6 - cw
  if CT.button("annotate.cancel", cx, y, "Cancel", {w = cw, h = bh, fg = C.text}) then self:cancel() return end
  if CT.button("annotate.done", dx, y, "Done", {w = ow, h = bh, fg = C.text}) then self:done() return end
  -- the canvas
  local ky = y + bh + 6
  local canvas = {x = x, y = ky, w = self.cw, h = self.ch}
  if self.view then D.image(self.view.id, canvas.x, canvas.y, self.view.w, self.view.h) end
  local _, over = hit(self, "canvas", canvas)
  local mx, my = w3.ui.mouse()
  local px, py = (mx - canvas.x) / self.scale, (my - canvas.y) / self.scale    -- (the picture's own pixels)
  if over and w3.ui.mouse_clicked(1) then
    if self.tool == "text" then
      local at = {px, py}
      local colour = self.colour
      require("conjunction.ui.dialogs").ask_text(self.ed, "Text", "Text:", function(text)
        if text and text ~= "" then
          self.marks[#self.marks + 1] = {"text", colour, {at, text}}
          self:paint()
        end
      end)
    else
      self.cur = {self.tool, self.colour, {{px, py}, {px, py}}}
    end
  end
  if self.cur then
    if w3.ui.mouse_down(1) then
      if self.cur[1] == "pen" then
        local last = self.cur[3][#self.cur[3]]
        if last[1] ~= px or last[2] ~= py then self.cur[3][#self.cur[3] + 1] = {px, py} end
      else self.cur[3][2] = {px, py} end
    else
      self.marks[#self.marks + 1] = self.cur
      self.cur = nil
      self:paint()
    end
  end
  if self.cur then                                  -- (the mark being drawn: at once, over the canvas)
    local m = self.cur
    local col = rgb(m[2])
    local lw = math.max(1, math.max(3.0, self.w / 400) * self.scale)
    local function sx(p) return canvas.x + p[1] * self.scale, canvas.y + p[2] * self.scale end
    D.clip(canvas.x, canvas.y, canvas.w, canvas.h, function()
      if m[1] == "pen" then
        for i = 2, #m[3] do
          local x1, y1 = sx(m[3][i - 1])
          local x2, y2 = sx(m[3][i])
          D.line(x1, y1, x2, y2, col, lw)
        end
      elseif m[1] == "box" then
        local x1, y1 = sx(m[3][1])
        local x2, y2 = sx(m[3][2])
        D.rect(math.min(x1, x2), math.min(y1, y2), math.abs(x2 - x1), math.abs(y2 - y1), col, lw)
      elseif m[1] == "arrow" then
        local x1, y1 = sx(m[3][1])
        local x2, y2 = sx(m[3][2])
        D.line(x1, y1, x2, y2, col, lw)
        for _, hd in ipairs(arrow_heads(m[3][1], m[3][2], math.max(3.0, self.w / 400))) do
          local a1, b1 = sx({hd[1], hd[2]})
          local a2, b2 = sx({hd[3], hd[4]})
          D.line(a1, b1, a2, b2, col, lw)
        end
      end
    end)
  end
end

-- the marking in one of the panel's windows over the game ("Mark the problem"), as big as it wants
function AN.open(ed, png, then_)
  local p = ed and ed.panel
  local sw, sh = 1600, 900
  if ed and ed.sys and ed.sys.client then
    local _, _, w, h = ed.sys.client()
    sw, sh = w or sw, h or sh
  end
  local body = AN.new(ed, png, then_, sw, sh)
  if not p then return body end
  local w = p:open_win("annotate", "Mark the problem", "annotate", function() return body end)
  w.body, body.win = body, w
  local hw, hh = body:size_hint()
  w.rect = {x = (sw - hw - 18) // 2, y = (sh - hh - 40) // 2, w = hw + 18, h = hh + 40}
  return body
end

return AN
