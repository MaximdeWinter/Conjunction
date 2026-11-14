-- dialogue_flow_view.py's FlowView: the dialogue drawn (dialogue_flow lays it out) in the look of the quest graph - the
-- dark dotted grid, blocks, square wires. A click on a block picks what it shows; the wheel zooms to the mouse, the
-- empty grid dragged moves; a double click opens (the empty grid: home); a right click: the box's menu.
--   local v = FV.new(on)     on: picked(ref, row), opened(ref, row), menu(ref, row, x, y), place(block, ref, row)
--   v:show_flow(flow, keep)  v:select(ref, row)  v:home()  v:frame(r, hovered)
-- Its view arithmetic is graph_view.lua's (QGraphicsView: a scale and the bars' values, no bars shown).
local GV = require("conjunction.ui.graph_view")
local F = require("conjunction.dialogue_flow")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local D = w3.ui.draw
local FV = setmetatable({}, {__index = GV})
FV.__index = FV

local qc = GV.qc
local BORDER = "80809078"                     -- QColor(128, 128, 144, 120)
local VCENTER_LEFT, CENTER = 0x81, 0x84
FV.MOVE_PX = 6

local function num(v)
  if math.type(v) == "integer" then return tostring(v) end
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  return string.format("%.17g", v)
end
local function cmd(out, ...)
  local parts = {...}
  for i, v in ipairs(parts) do if type(v) == "number" then parts[i] = num(v) end end
  out[#out + 1] = table.concat(parts, " ")
end
local function txt(s) return (P.str(s):gsub("\r\n", "\30"):gsub("[\r\n]", "\30")) end
local function trunc(d) return d >= 0 and math.floor(d) or math.ceil(d) end

function FV.new(on)
  local self = GV.new(on)
  setmetatable(self, FV)
  self.flow, self.chosen, self.chosen_row, self.hot, self.hot_row = nil, nil, nil, nil, -1
  self.file = (os.getenv("TEMP") or ".") .. "\\cj_flow_" .. tostring(self):gsub("[^%w]", "") .. ".png"
  return self
end

-- --- refs: the same box (dialogue_flow_view._same: the same objects, equal strings and numbers)
local function same(a, b)
  if a == nil or b == nil or #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if not (x == y) then return false end
  end
  return true
end
FV.same = same

function FV:show_flow(flow, keep)
  local centre, kh, kv
  if self.flow ~= nil and keep then
    centre = {self:to_scene((self.vw - 1) // 2, (self.vh - 1) // 2)}
    kh, kv = self.hval, self.vval
  end
  self.flow = flow
  self.settling = nil
  self.scene_rect = {-3000, -3000, flow.w + 6000, flow.h + 6000}
  self:recalc()
  if centre then
    -- (the bars as they were: centred again the view crept a pixel up and left with each change - graph_view)
    self:center_on(centre[1], centre[2])
    if self.left_indent == 0 then self:set_h(kh) end
    if self.top_indent == 0 then self:set_v(kv) end
  else
    self:home()
  end
end

-- the whole talk in view as far as it goes: at most 1, at least GV.MIN_ZOOM, its top a little in (FlowView.home)
function FV:home()
  self:reset_transform()
  if self.flow == nil then return end
  local want = math.min(1.0, math.max(GV.MIN_ZOOM, (self.vw - 40) / math.max(1.0, self.flow.w + 40)))
  self:scale(want)
  self:center_on(self.flow.w / 2, self.vh / 2 / want - 20 / want)
end

function FV:select(ref, row)
  self.chosen = ref
  self.chosen_row = (row and row >= 0) and {ref, row} or nil
end

function FV:item_at(x, y)
  if not self.flow then return nil end
  for _, b in ipairs(self.flow.boxes) do
    if b.x <= x and x <= b.x + b.w and b.y <= y and y <= b.y + b.h then return b end
  end
  return nil
end
function FV.row_at(b, ly)
  if b.kind ~= "choice" then return -1 end
  local k = trunc((ly - F.HEAD) // F.ROW)
  if k >= 0 and k < #b.rows and ly >= F.HEAD then return k end
  return -1
end

-- --- painted by Qt, as the app's items paint themselves
local function rect_r(b) return 0.5, 0.5, b.w - 1, b.h - 1 end

-- the picked box breathes (GV:draw_breath): its rectangle, unless a choice's row is what is picked
function FV:breathing()
  local f = self.flow
  local out = {}
  if not f then return out end
  for _, b in ipairs(f.boxes) do
    if same(b.ref, self.chosen) and not (b.kind == "choice" and self.chosen_row) then
      local rx, ry, rw, rh = rect_r(b)
      local x0, y0 = b.x + rx, b.y + ry
      out[#out + 1] = {x0, y0, x0 + rw, y0, x0 + rw, y0 + rh, x0, y0 + rh}
    end
  end
  return out
end

function FV:paint_box(out, b, pulse)
  cmd(out, "save")
  cmd(out, "item", b.x, b.y)
  cmd(out, "aa", 1)
  local rx, ry, rw, rh = rect_r(b)
  local colour = qc(P.T(b.colour) and b.colour or GV.MUTED)
  local selected = same(b.ref, self.chosen)
  local chosen_row = self.chosen_row
  if selected and not (b.kind == "choice" and chosen_row) then
    cmd(out, "pen", qc(GV.PICKED, trunc(50 + 110 * pulse)), 6)
    cmd(out, "nobrush")
    cmd(out, "rectf", rx, ry, rw, rh)
  end
  if b.kind == "label" then
    cmd(out, "fontpx", 10, 1, 0)
    cmd(out, "pen", colour, 1)
    cmd(out, "textelide", 2, 0, b.w, b.h, VCENTER_LEFT, trunc(b.w - 4), txt(b.title))
    cmd(out, "restore")
    return
  end
  cmd(out, "brush", qc(GV.RAISED))
  if b.kind == "pill" or b.kind == "choice" or b.kind == "if" or b.kind == "random" then
    cmd(out, "pen", qc(b.colour, 200), 1.2)
  elseif self.hot == b or selected then
    cmd(out, "pen", qc("#b0b0c0", 160), 1)
  else
    cmd(out, "pen", BORDER, 1)
  end
  cmd(out, "rectf", rx, ry, rw, rh)
  if b.kind == "pill" then
    cmd(out, "fontpx", 9, 1, 0.6)
    cmd(out, "pen", colour, 1)
    cmd(out, "textrect", rx, ry, rw, rh, CENTER, txt(b.title))
  elseif b.kind == "start" then
    cmd(out, "fontpx", 9, 1, 0.6)
    cmd(out, "pen", qc(GV.MUTED), 1)
    cmd(out, "textrect", 14, 0, 130, b.h, 0x80, txt(b.title))
    cmd(out, "fontpx", 11, 0, 0)
    if #b.rows > 0 then cmd(out, "textrect", 130, 0, b.w - 140, b.h, 0x80, txt("· " .. P.str(b.rows[1]))) end
  elseif b.kind == "lines" then
    local y = 8
    for _, row in ipairs(b.rows) do
      local name, text, speaker = row[2], row[3], row[5]
      local c = qc(speaker)
      local h = F.LINE * #text
      cmd(out, "nopen")
      cmd(out, "brush", c)
      cmd(out, "rectf", 10, y + 2, 3, h - 3)
      cmd(out, "fontpx", 9, 1, 0.5)
      cmd(out, "pen", c, 1)
      local cps = PYS.cps(name)
      cmd(out, "textrect", 20, y, 84, F.LINE, 0x80, txt(PYS.from_cps(cps, 1, math.min(14, #cps))))
      cmd(out, "fontpx", 12, 0, 0)
      cmd(out, "pen", qc(GV.TEXT), 1)
      for k, t in ipairs(text) do cmd(out, "textrect", 104, y + (k - 1) * F.LINE, b.w - 112, F.LINE, 0x80, txt(t)) end
      y = y + h + 5
    end
  elseif b.kind == "script" then
    cmd(out, "fontpx", 9, 1, 0.6)
    cmd(out, "pen", colour, 1)
    cmd(out, "textrect", 12, 0, 70, b.h, 0x80, txt(b.title))
    cmd(out, "fontpx", 11, 0, 0)
    cmd(out, "textrect", 80, 0, b.w - 90, b.h, 0x80, txt(P.str(b.rows[1])))
  else
    -- a choice / if / random: its title, a choice its answers
    cmd(out, "fontpx", 9, 1, 0.6)
    cmd(out, "pen", colour, 1)
    cmd(out, "textrect", 12, 0, b.w - 20, b.kind == "choice" and F.HEAD or b.h, 0x80, txt(b.title))
    if b.kind == "choice" then
      for k, row in ipairs(b.rows) do
        local j = k - 1
        local y = F.HEAD + j * F.ROW
        local kind = row.kind
        local c = qc((row.main and kind == "on") and F.MAIN or F.COLOUR[kind])
        if chosen_row and same(chosen_row[1], b.ref) and chosen_row[2] == j then
          cmd(out, "pen", qc(GV.PICKED, trunc(90 + 130 * pulse)), 1.6)
          cmd(out, "brush", qc(GV.PICKED, 24))
          cmd(out, "rectf", 2, y + 1, b.w - 4, F.ROW - 2)
        elseif self.hot == b and self.hot_row == j then
          cmd(out, "nopen")
          cmd(out, "brush", qc("#ffffff", 14))
          cmd(out, "rectf", 1, y, b.w - 2, F.ROW)
        end
        cmd(out, "nopen")
        cmd(out, "brush", c)
        cmd(out, "rectf", 8, y + 5, 3, F.ROW - 10)
        -- the tags at the right: what kind of answer, what it costs / needs / does
        local tags = {}
        for _, t in ipairs(row.chips) do if t ~= "main" then tags[#tags + 1] = t end end
        if F.WORD[kind] ~= "" then tags[#tags + 1] = F.WORD[kind] end
        local x = b.w - 10
        cmd(out, "fontpx", 9, 1, 0)
        for i = #tags, 1, -1 do
          local t = tags[i]
          local tw = GV.advance(9, true, 0, t) + 12
          x = x - tw
          local tc = t == F.WORD[kind] and c or qc("#a0a0b0")
          cmd(out, "pen", tc, 1)
          cmd(out, "nobrush")
          cmd(out, "rectf", x, y + 4, tw, F.ROW - 8)
          cmd(out, "textrect", x, y + 4, tw, F.ROW - 8, CENTER, txt(t))
          x = x - 5
        end
        cmd(out, "fontpx", 12, row.main and 1 or 0, 0)
        cmd(out, "pen", c, 1)
        cmd(out, "textelide", 18, y, x - 22, F.ROW, 0x80, trunc(math.max(10, x - 26)), txt(row.text))
        if kind ~= "on" then                 -- (its way leaves on the right: a port)
          cmd(out, "pen", c, 1.2)
          cmd(out, "brush", c)
          cmd(out, "rectf", b.w - 3, y + F.ROW / 2 - 4, 6, 8)
        end
      end
    end
  end
  cmd(out, "restore")
end

function FV:paint_flow_wire(out, w)
  if #w.points < 2 then return end
  local pts = {}
  for i, p in ipairs(w.points) do pts[i] = {p[1], p[2]} end
  local c = qc(P.T(w.colour) and w.colour or GV.MUTED)
  local x0, y0 = pts[#pts - 1][1], pts[#pts - 1][2]
  local x1, y1 = pts[#pts][1], pts[#pts][2]
  local dx = (x1 > x0 and 1 or 0) - (x1 < x0 and 1 or 0)
  local dy = (y1 > y0 and 1 or 0) - (y1 < y0 and 1 or 0)
  -- (into a box always with its arrow - the box's way in, as an output leaves from its square: MaximdeWinter 13.11.)
  local arrow = w.arrow or w.dst ~= nil
  if arrow then pts[#pts] = {x1 - 6 * dx, y1 - 6 * dy} end
  cmd(out, "save")
  cmd(out, "world")
  cmd(out, "aa", 1)
  cmd(out, "pen", c, 1.4, 0)
  if w.dashed then cmd(out, "dash", 4, 3) end
  cmd(out, "nobrush")
  local parts = {"path", "M", num(pts[1][1]), num(pts[1][2])}
  for i = 2, #pts do
    parts[#parts + 1] = "L"
    parts[#parts + 1] = num(pts[i][1])
    parts[#parts + 1] = num(pts[i][2])
  end
  out[#out + 1] = table.concat(parts, " ")
  cmd(out, "restore")
  if arrow then
    local head = {{-6, -3.2}, {0, 0}, {-6, 3.2}}
    local function turn(x, y)
      if dx == -1 and dy == 0 then return -x, -y end
      if dx == 0 and dy == 1 then return -y, x end
      if dx == 0 and dy == -1 then return y, -x end
      return x, y
    end
    cmd(out, "save")
    cmd(out, "item", x1, y1)
    cmd(out, "aa", 1)
    cmd(out, "nopen")
    cmd(out, "brush", c)
    local a = {}
    for i, p in ipairs(head) do
      local hx, hy = turn(p[1], p[2])
      a[#a + 1] = (i == 1 and "M " or "L ") .. num(hx) .. " " .. num(hy)
    end
    out[#out + 1] = "path " .. table.concat(a, " ") .. " Z"
    cmd(out, "restore")
  end
end

function FV:commands()
  local out = {}
  local dv = self.device
  if dv and (dv[1] > self.vw or dv[2] > self.vh) then cmd(out, "device", dv[1], dv[2], dv[3], dv[4]) end
  -- (the game draws them: the whole scene once, the view's zoom and scroll applied when drawn - GV:draw_scene; the
  -- background with it. Qt's picture: the view's part, as the app paints it)
  local scene = not GV.QT_PAINT
  local s = scene and 1 or self.m11
  local sx, sy = 0, 0
  if not scene then sx, sy = self:scroll() end
  cmd(out, "view", s, sx, sy)
  cmd(out, "aa", 1)
  local inv = 1 / s
  local l, t, r, b = sx * inv, sy * inv, (sx + self.vw) * inv, (sy + self.vh) * inv
  if scene then l, t, r, b = -math.huge, -math.huge, math.huge, math.huge end
  if not scene then
  cmd(out, "save")
  cmd(out, "fillrectf", l, t, r - l, b - t, qc(GV.SURFACE))
  if s >= 0.4 then
    cmd(out, "nopen")
    cmd(out, "brush", qc(GV.DOT))
    local gap = 20
    local x0 = trunc(l) // gap * gap
    local y = trunc(t) // gap * gap
    while y < b do
      local x = x0
      while x < r do
        cmd(out, "ellipsec", x, y, 1.1, 1.1)
        x = x + gap
      end
      y = y + gap
    end
  end
  cmd(out, "restore")
  end
  local f = self.flow
  if f then
    local function visible(x, y, w, h) return x < r + 10 and x + w > l - 10 and y < b + 10 and y + h > t - 10 end
    -- (a box being moved: at the mouse, its wires left out until it is let go and the flow drawn anew)
    local moving = self.drag and self.drag[1] == "box" and self.move_at and self.drag[2] or self.settling
    for _, w in ipairs(f.wires) do
      local wx0, wy0, wx1, wy1 = math.huge, math.huge, -math.huge, -math.huge
      for _, p in ipairs(w.points) do
        wx0, wy0, wx1, wy1 = math.min(wx0, p[1]), math.min(wy0, p[2]), math.max(wx1, p[1]), math.max(wy1, p[2])
      end
      local hidden = moving ~= nil and (w.src == moving or w.dst == moving)
      if not hidden and #w.points >= 2 and visible(wx0 - 8, wy0 - 8, wx1 - wx0 + 16, wy1 - wy0 + 16) then
        self:paint_flow_wire(out, w)
      end
    end
    local p = 0                                 -- (the breath: drawn over the picture, FV:breathing)
    for _, bx in ipairs(f.boxes) do
      if bx == moving and self.move_at then
        local ox, oy = bx.x, bx.y
        bx.x, bx.y = self.move_at[1], self.move_at[2]
        self:paint_box(out, bx, p)
        bx.x, bx.y = ox, oy
      elseif visible(bx.x - 6, bx.y - 6, bx.w + 12, bx.h + 12) then
        self:paint_box(out, bx, p)
      end
    end
    -- each box's way out: a square where a wire leaves it, as the quest graph's outputs (a choice's answers on its
    -- right have theirs in the box)
    for _, w in ipairs(f.wires) do
      local s = w.src
      if s ~= nil and s ~= moving and moving ~= w.dst and #w.points >= 2 then
        local a, n = w.points[1], w.points[2]
        local on_right = s.kind == "choice" and math.abs(a[1] - (s.x + s.w)) < 1
        if not on_right and visible(a[1] - 8, a[2] - 8, 16, 16) then
          local down = n[1] == a[1]
          cmd(out, "save")
          cmd(out, "world")
          cmd(out, "aa", 1)
          GV.paint_handle(self, out, a[1], a[2], P.T(w.colour) and w.colour or GV.EDGE, down, true)
          cmd(out, "restore")
        end
      end
    end
  end
  self:paint_block_drag(out)
  return out
end

-- --- a block of the sidebar dragged over the flow (DialogueFlowView.block_over / drawForeground): the box (or the
-- choice's row) it goes to, and the block at the mouse
function FV:block_over(kind, px, py)
  local inside = px >= 0 and py >= 0 and px < self.vw and py < self.vh
  self.drag_block = inside and kind or nil
  self.cursor_at = inside and {self:to_scene(px, py)} or nil
  self.drop_on = nil
  if inside then
    local b = self:item_at(self.cursor_at[1], self.cursor_at[2])
    if b ~= nil then self.drop_on = {b, FV.row_at(b, self.cursor_at[2] - b.y)} end
  end
  return inside
end

-- let go -> inside, and the ref and row the block goes to (none under it: what is picked)
function FV:block_dropped(kind, px, py)
  local inside = self:block_over(kind, px, py)
  local on = self.drop_on
  self.drag_block, self.drop_on, self.cursor_at = nil, nil, nil
  if not inside then return false end
  if on ~= nil then return true, on[1].ref, on[2] end
  return true, self.chosen, self.chosen_row and self.chosen_row[2] or -1
end

function FV:paint_block_drag(out)
  if self.drag_block == nil or self.cursor_at == nil then return end
  cmd(out, "world")
  cmd(out, "aa", 1)
  local accent = qc("#0088E8")
  if self.drop_on ~= nil then
    local b, row = self.drop_on[1], self.drop_on[2]
    cmd(out, "pen", accent, 2)
    cmd(out, "nobrush")
    if row >= 0 then
      cmd(out, "rectf", b.x + 2, b.y + F.HEAD + row * F.ROW, b.w - 4, F.ROW)
    else
      cmd(out, "linef", b.x + b.w / 2 - 60, b.y + b.h + F.GAP / 2, b.x + b.w / 2 + 60, b.y + b.h + F.GAP / 2)
    end
  end
  local cx, cy = self.cursor_at[1], self.cursor_at[2]
  cmd(out, "pen", accent, 1, 0x10, 0x40, 2)
  cmd(out, "brush", qc(GV.RAISED, 200))
  cmd(out, "rectf", cx - 50, cy - 13, 100, 26)
  cmd(out, "pen", qc(GV.TEXT), 1)
  cmd(out, "fontpx", 10, 1, 0)
  cmd(out, "textrect", cx - 50, cy - 13, 100, 26, CENTER, txt(self.drag_block:upper()))
end

-- --- the mouse (FlowView's events)
function FV:mouse(r, hovered)
  local mx, my, wheel = w3.ui.mouse()
  local ax, ay = math.floor(mx - r.x), math.floor(my - r.y)
  local x, y = self:to_scene(ax, ay)
  local on = self.on
  if not self.flow then return end
  if hovered and wheel and wheel ~= 0 and not self.press then
    local f = 1.15 ^ wheel
    local now = self.m11
    f = math.max(GV.MIN_ZOOM / now, math.min(2.0 / now, f))
    local bx, by = self:to_scene(ax, ay)
    self:scale(f)
    local nx, ny = self:from_scene(bx, by)
    self:set_h(self.hval + (nx - ax))
    self:set_v(self.vval + (ny - ay))
    x, y = self:to_scene(ax, ay)
  end
  if hovered and w3.ui.mouse_double(1) then
    self.press, self.panning = nil, nil
    self.swallow = true
    local b = self:item_at(x, y)
    if b == nil then self:home() elseif on.opened then on.opened(b.ref, FV.row_at(b, y - b.y)) end
    return
  end
  if hovered and (w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(3)) then
    self.press, self.panning = {ax, ay}, nil
    -- (a box under the left button moves with it, MaximdeWinter 13.11.; the right button, the empty grid: the view)
    local b = w3.ui.mouse_clicked(1) and self:item_at(x, y) or nil
    if b and b.key and on.moved_box then self.press.box, self.press.ox, self.press.oy = b, x - b.x, y - b.y end
  end
  local down = w3.ui.mouse_down(1) or w3.ui.mouse_down(3)
  if self.press and down then
    local far = math.abs(ax - self.press[1]) + math.abs(ay - self.press[2]) >= FV.MOVE_PX
    if self.drag or (far and self.press.box) then
      self.drag = self.drag or {"box", self.press.box}
      self.move_at = {x - self.press.ox, y - self.press.oy}
    elseif self.panning or far then
      local last = self.panning or self.press
      self.panning = {ax, ay}
      self:set_h(self.hval - (ax - last[1]))
      self:set_v(self.vval - (ay - last[2]))
    end
  elseif self.press and not down then
    local panned = self.panning or self.drag
    local drag, move_at = self.drag, self.move_at
    self.press, self.panning, self.drag, self.move_at = nil, nil, nil, nil
    if drag and move_at then                     -- (let go: on the 10 px grid, the box stays there until drawn anew)
      local b = drag[2]
      local nx, ny = math.floor(move_at[1] / 10 + 0.5) * 10, math.floor(move_at[2] / 10 + 0.5) * 10
      if nx ~= b.x or ny ~= b.y then
        local dx, dy = nx - b.x, ny - b.y
        b.x, b.y = nx, ny
        self.settling = b
        on.moved_box(b.key, dx, dy)
      end
    end
    if not panned and w3.ui.mouse_released(1) then
      local b = self:item_at(x, y)
      if b then
        local row = FV.row_at(b, y - b.y)
        self:select(b.ref, row)
        if on.picked then on.picked(b.ref, row) end
      end
    end
  end
  if hovered and w3.ui.mouse_released and w3.ui.mouse_released(2) then
    local b = self:item_at(x, y)
    if b then
      local row = FV.row_at(b, y - b.y)
      self:select(b.ref, row)
      if on.picked then on.picked(b.ref, row) end
      if on.menu then on.menu(b.ref, row, mx, my) end
    end
  end
  local hb = hovered and self:item_at(x, y) or nil
  self.hot = hb
  self.hot_row = hb and FV.row_at(hb, y - hb.y) or -1
end

function FV:frame(r, hovered)
  self:resize(math.floor(r.w), math.floor(r.h))
  if self.want_home and self.vw > 0 then
    self.want_home = nil
    self:home()
  end
  if self.swallow and not w3.ui.mouse_down(1) then self.swallow = false end
  if not self.swallow then self:mouse(r, hovered) end
  self.view_x, self.view_y = r.x, r.y
  local img = self:picture()
  if img and img.steps then
    self:draw_scene(img.steps, r)
  elseif img then
    D.image(img[1], r.x, r.y, img[2], img[3])
  end
  self:draw_breath(r)
  local AG = package.loaded["conjunction.agent"]        -- (the boxes in view, for the agent: by their text)
  if AG and self.flow then
    for k, b in ipairs(self.flow.boxes) do
      local x1, y1 = self:from_scene(b.x, b.y)
      local x2, y2 = self:from_scene(b.x + b.w, b.y + b.h)
      if x2 > 0 and y2 > 0 and x1 < r.w and y1 < r.h then
        AG.area("flow.box." .. tostring(b.id or k), r.x + x1, r.y + y1, x2 - x1, y2 - y1,
                b.title or b.text or b.kind)
      end
    end
  end
end

return FV
