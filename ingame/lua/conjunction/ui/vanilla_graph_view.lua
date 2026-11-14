-- vanilla_view.py's GraphView, BlockItem and WireItem: a game quest graph on screen - each block as the app paints it
-- (its family's colour at the left and in its head, its title, its name, what it does, its sockets), the links square
-- under them. A QGraphicsView: its arithmetic as Qt's (the ranges, the bars as needed, centerOn, the wheel zooming under
-- the mouse, fitInView; the scene's alignment the default, centred), its scene painted by Qt itself (cj_qt).
--   a click on a block: picked (its links lit); a drag on a block: moved; from an output's square onto an input (or a
--   block): linked; a click on a link: chosen; a drag on the graph: moved (Shift: a frame chooses blocks); the wheel:
--   zoom; a double click on a phase: into it; a right click: the menu (on_menu)
--   local gv = GV.new({editable = true})   gv:show_graph(g)   gv:frame(r, hovered)
--   callbacks: on_pick(b | nil), on_open(n), on_moved(n, x, y), on_connect(a, out, b, put), on_menu(target, mx, my, sx,
--   sy) (target {"block", b} | {"wire", link} | nil)
local V = require("conjunction.vanilla_graph")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local Q = require("conjunction.ui.qt")
local D = w3.ui.draw
local GV = {}
GV.__index = GV

GV.BG, GV.CARD, GV.CARD_HOVER, GV.BORDER = "#141417", "#24242a", "#2c2c34", "#3c3c42"
GV.PICKED = "#d9a441"
GV.WIRE = "#7a7a86"
GV.WIRE_COLOUR = {True = "#5cb85c", False = "#c0504d"}
-- QColor.lighter(150) of the wires' colours (Qt's HSV arithmetic: taken from Qt)
GV.LIGHTER = {["#7a7a86"] = "#b7b7c9", ["#5cb85c"] = "#94ff94", ["#c0504d"] = "#ff8a87", ["#d9a441"] = "#ffd993"}
GV.DETAIL_ZOOM = 0.45
GV.PORT = 8                     -- how near a port a press takes it
GV.LIVE = "#5cb85c"
GV.LIVE_FADE = 4.0              -- s a block stays lit after the game activated it
GV.MIN_ZOOM, GV.MAX_ZOOM = 0.08, 2.5
GV.MARGIN_X, GV.MARGIN_Y = 400, 300     -- around what is in the scene (grow)

local ALIGN_LEFT_V, ALIGN_RIGHT_V, ALIGN_CENTER, WORD_WRAP = 0x81, 0x82, 0x84, 0x1000
local function qc(s, a)
  return string.format("%s%02x", s:sub(2):lower(), a or 255)
end
local function num(x)
  if math.type(x) == "integer" then return tostring(x) end
  if x == math.floor(x) and math.abs(x) < 2 ^ 53 then return string.format("%d", x) end
  return string.format("%.17g", x)
end
local function txt(s) return (tostring(s):gsub("[%c]", " ")) end
-- qRound (Qt: half up)
local function qround(x) return math.floor(x + 0.5) end
-- int(x): towards zero
local function trunc(x) return x >= 0 and math.floor(x) or -math.floor(-x) end

function GV.new(opts)
  opts = opts or {}
  local self = setmetatable({editable = opts.editable ~= false, blocks = {}, order = {}, wires = {}, current = nil,
                             chosen_wire = nil, selected = {}, g = nil, fold_of = {}, m11 = 1.0, hval = 0, vval = 0,
                             hmin = 0, hmax = 0, vmin = 0, vmax = 0, w = 100, h = 30, vw = 98, vh = 28,
                             vpw = 98, vph = 28, hbar_on = false, vbar_on = false, scene = {0, 0, 0, 0},
                             left_indent = 0, top_indent = 0,
                             last_center = {0, 0}, hbar = IV.bar(1, 0, 0), vbar = IV.bar(1, 0, 0), bar_state = {},
                             hot = nil, img = nil, img_key = nil, hits = {}, hit_at = 0}, GV)
  self.file = (os.getenv("TEMP") or ".") .. "\\cj_vgraph_" .. tostring(self):gsub("[^%w]", "") .. ".png"
  return self
end

-- --- QGraphicsView's arithmetic (recalculateContentSize: the frame 1 px, the bars as needed, 10 wide - but the
-- ranges reckon a bar as 12; the scene centred where it is smaller than the view)
function GV:recalc()
  local s = self.m11
  local sr = self.scene
  local vx, vy, vw, vh = sr[1] * s, sr[2] * s, sr[3] * s, sr[4] * s
  local maxw, maxh = self.w - 2, self.h - 2
  local use_h, use_v = vw > maxw, vh > maxh
  if use_h and vh > maxh - 12 then use_v = true end
  if use_v and vw > maxw - 12 then use_h = true end
  local width, height = maxw - (use_v and 12 or 0), maxh - (use_h and 12 or 0)
  self.hbar_on, self.vbar_on = use_h, use_v
  self.vw, self.vh = maxw - (use_v and 10 or 0), maxh - (use_h and 10 or 0)
  self.hpage, self.vpage = width, height
  if vw > width then
    self.hmin, self.hmax = qround(vx), qround(vx + vw - width)
    self.hval = math.max(self.hmin, math.min(self.hmax, self.hval))
    self.left_indent = 0
  else
    self.hmin, self.hmax, self.hval = 0, 0, 0
    -- (centred in the whole viewport, the other bar not taken off - measured: probe in ref; updateScroll truncates)
    self.left_indent = trunc(maxw / 2 - (vx + (vx + vw)) / 2)
  end
  if vh > height then
    self.vmin, self.vmax = qround(vy), qround(vy + vh - height)
    self.vval = math.max(self.vmin, math.min(self.vmax, self.vval))
    self.top_indent = 0
  else
    self.vmin, self.vmax, self.vval = 0, 0, 0
    self.top_indent = trunc(maxh / 2 - (vy + (vy + vh)) / 2)
  end
end
function GV:sx() return self.hval - self.left_indent end
function GV:sy() return self.vval - self.top_indent end
function GV:set_h(v) self.hval = math.max(self.hmin, math.min(self.hmax, math.tointeger(v) or qround(v))) end
function GV:set_v(v) self.vval = math.max(self.vmin, math.min(self.vmax, math.tointeger(v) or qround(v))) end
function GV:to_scene(px, py) return (px + self:sx()) / self.m11, (py + self:sy()) / self.m11 end
function GV:from_scene(x, y) return x * self.m11 - self:sx(), y * self.m11 - self:sy() end
-- QGraphicsView.centerOn: Qt 6's qRound, halves away from zero (graph_view.lua measured it: -26.5 -> -27; here
-- -36.78 -> -37), the bars only where they scroll; the point kept as the last centre. (The viewport as laid out: a
-- bar shown or hidden by the ranges moves it only at the next layout - vpw, vph until then.)
local function qround6(d)
  if d >= 0 then return math.tointeger(math.floor(d + 0.5)) end
  return math.tointeger(math.ceil(d - 0.5))
end
function GV:center_on(x, y)
  if self.left_indent == 0 then self:set_h(qround6(x * self.m11 - self.vpw / 2.0)) end
  if self.top_indent == 0 then self:set_v(qround6(y * self.m11 - self.vph / 2.0)) end
  self.last_center = {x, y}
end
-- updateLastCenterPoint: the viewport's middle (QRect.center) in the scene
function GV:update_center()
  self.last_center = {self:to_scene((self.vpw - 1) // 2, (self.vph - 1) // 2)}
end
-- the viewport laid out anew (a frame: the bars where the ranges put them)
function GV:layout() self.vpw, self.vph = self.vw, self.vh end
function GV:resize(w, h)
  if w == self.w and h == self.h then return end
  self.w, self.h = w, h
  self:recalc()
  self:layout()
  self:update_center()           -- (resizeAnchor NoAnchor)
end
-- setTransform (a scale m11): the ranges anew, then centerView(AnchorUnderMouse): the point under the mouse kept
-- there (mouse: the viewport's point, nil when the mouse is not over it - then the last centre)
function GV:set_scale(m, mouse)
  if m == self.m11 then return end
  local before = mouse and {self:to_scene(mouse[1], mouse[2])} or nil
  self.m11 = m
  self:recalc()
  if mouse then
    local cx, cy = self:to_scene((self.vpw - 1) // 2, (self.vph - 1) // 2)
    local mx, my = self:to_scene(mouse[1], mouse[2])
    self:center_on(before[1] + (cx - mx), before[2] + (cy - my))
  else
    self:center_on(self.last_center[1], self.last_center[2])
  end
end
function GV:scale(k, mouse) self:set_scale(self.m11 * k, mouse) end
function GV:reset_transform() self:set_scale(1.0, nil) end
-- QGraphicsView.fitInView(rect, KeepAspectRatio): 1:1, then the ratio that fits the viewport less 2 px all round,
-- centred on the rectangle
function GV:fit_in_view(rx, ry, rw, rh)
  if rw == 0 and rh == 0 then return end
  self:set_scale(1.0, nil)
  local vw, vh = self.vpw - 4, self.vph - 4
  if vw <= 0 or vh <= 0 or rw <= 0 or rh <= 0 then return end
  local k = math.min(vw / rw, vh / rh)
  self:set_scale(self.m11 * k, nil)
  self:center_on(rx + rw / 2, ry + rh / 2)
end

-- --- the scene's items
-- a block's boundingRect in the scene: 6 px more at the sides, 2 above and below
local function block_rect(b) return b.x - 6, b.y - 2, b.w + 12, b.h + 4 end
-- a link's: its shape's (a stroke 9 wide, flat ends) control points
local function wire_rect(pts)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    if a[1] ~= b[1] or a[2] ~= b[2] then
      local ex = a[2] == b[2] and 0 or 4.5
      local ey = a[1] == b[1] and 0 or 4.5
      if a[2] == b[2] then ey = 4.5 end
      if a[1] == b[1] then ex = 4.5 end
      x0 = math.min(x0, a[1] - ex, b[1] - ex)
      x1 = math.max(x1, a[1] + ex, b[1] + ex)
      y0 = math.min(y0, a[2] - ey, b[2] - ey)
      y1 = math.max(y1, a[2] + ey, b[2] + ey)
    end
  end
  if x0 == math.huge then return nil end
  return x0, y0, x1 - x0, y1 - y0
end

function GV:items_rect()
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  local function add(x, y, w, h)
    x0, y0 = math.min(x0, x), math.min(y0, y)
    x1, y1 = math.max(x1, x + w), math.max(y1, y + h)
  end
  for _, w in ipairs(self.wires) do
    local x, y, ww, hh = wire_rect(w.pts)
    if x then add(x, y, ww, hh) end
  end
  for _, n in ipairs(self.order) do add(block_rect(self.blocks[n].b)) end
  if x0 == math.huge then return 0, 0, 0, 0 end
  return x0, y0, x1 - x0, y1 - y0
end

local function is_back(pts) return #pts > 4 and pts[2][1] - pts[1][1] < 20 end

function GV:show_graph(g)
  self.g, self.blocks, self.order, self.wires = g, {}, {}, {}
  self.current, self.chosen_wire, self.drag, self.selected = nil, nil, nil, {}
  for _, w in ipairs(g.wires) do
    self.wires[#self.wires + 1] = {link = w[1], pts = w[2], back = is_back(w[2]), chosen = false, lit = false}
  end
  for _, n in ipairs(g.order) do
    local b = g.blocks[n]
    self.blocks[n] = {b = b, picked = false, hit = false, lit = false, live_at = 0}
    self.order[#self.order + 1] = n
  end
  self:grow()
end

-- the scene: what is in it, 400 more at the sides, 300 above and below
function GV:grow()
  local x, y, w, h = self:items_rect()
  self.scene = {x - GV.MARGIN_X, y - GV.MARGIN_Y, w + 2 * GV.MARGIN_X, h + 2 * GV.MARGIN_Y}
  self:recalc()
end

-- the links again after a block moved
function GV:reroute()
  V.route(self.g)
  local by = {}
  for _, w in ipairs(self.g.wires) do by[w[1]] = w[2] end
  for _, w in ipairs(self.wires) do
    if by[w.link] then
      w.pts = by[w.link]
      w.back = is_back(w.pts)
    end
  end
end

-- a block's links stand out while the mouse is on it (and the picked one's while nothing is)
function GV:light(item)
  item = item or self.current
  local n = item and item.b.n or nil
  local ends = {}
  for _, w in ipairs(self.wires) do
    local mine = n ~= nil and (w.link[1] == n or w.link[3] == n)
    w.lit = mine
    if mine then
      ends[w.link[1]] = true
      ends[w.link[3]] = true
    end
  end
  for k, it in pairs(self.blocks) do it.lit = ends[k] == true end
end

function GV:pick(item)
  if self.current then self.current.picked = false end
  self.current = item
  if item then item.picked = true end
  self:choose_wire(nil)
  self:light(nil)
  if self.on_pick then self.on_pick(item and item.b or nil) end
end

function GV:choose_wire(w)
  if self.chosen_wire then self.chosen_wire.chosen = false end
  self.chosen_wire = w
  if w then w.chosen = true end
end

-- the blocks chosen (a frame, Ctrl+click) - else the one picked -> block numbers
function GV:chosen()
  local sel = {}
  for _, n in ipairs(self.order) do if self.selected[n] then sel[#sel + 1] = n end end
  if #sel == 0 and self.current then sel[1] = self.current.b.n end
  return sel
end

function GV:pick_n(n)
  local it = self.blocks[n] or self.blocks[self.fold_of[n] or false]
  if it then self:pick(it) end
  return it
end

-- the blocks whose title, name, comment or lines hold the words: marked, the first in sight
function GV:find(words)
  words = require("conjunction.pystr").lower(require("conjunction.pystr").strip(words))
  self.hits = {}
  local list = {}
  for _, n in ipairs(self.order) do list[#list + 1] = self.blocks[n] end
  list = require("conjunction.pysort").sorted(list, function(it) return {it.b.y, it.b.x} end)
  for _, it in ipairs(list) do
    local b = it.b
    local parts = {b.title, b.name, b.comment}
    for _, l in ipairs(b.lines) do parts[#parts + 1] = l end
    local text = require("conjunction.pystr").lower(table.concat(parts, " "))
    it.hit = words ~= "" and text:find(words, 1, true) ~= nil
    if it.hit then self.hits[#self.hits + 1] = it end
  end
  self.hit_at = 0
  if #self.hits > 0 then self:center_on_item(self.hits[1]) end
  return self.hits[1]
end

function GV:find_next()
  if #self.hits == 0 then return nil end
  self.hit_at = (self.hit_at + 1) % #self.hits
  local it = self.hits[self.hit_at + 1]
  self:center_on_item(it)
  self:pick(it)
  return it
end

-- centerOn(item): its bounding rectangle's middle
function GV:center_on_item(it)
  local x, y, w, h = block_rect(it.b)
  self:center_on(x + w / 2, y + h / 2)
end

function GV:fit()
  local x, y, w, h = self:items_rect()
  self:fit_in_view(x, y, w, h)
  if self.m11 > 1.0 then self:reset_transform() end
end

-- ("in" | "out", socket name) of the port at a point of block b (its own coordinates), or nil
function GV.port_at(b, px, py)
  local top = V.HEAD + V.text_rows(b) * V.LINE
  for _, side in ipairs({{"in", b.inputs, 0}, {"out", b.outputs, b.w}}) do
    for k, name in ipairs(side[2]) do
      local y = top + (k - 1) * V.ROW + V.ROW / 2
      if math.abs(px - side[3]) <= GV.PORT and math.abs(py - y) <= V.ROW / 2 then return side[1], name end
    end
  end
  return nil
end

-- the block under a point of the scene (the topmost: the last added), its bounding rectangle
function GV:block_at(x, y)
  for k = #self.order, 1, -1 do
    local it = self.blocks[self.order[k]]
    local bx, by, bw, bh = block_rect(it.b)
    if x >= bx and x < bx + bw and y >= by and y < by + bh then return it end
  end
  return nil
end
-- the link under a point (its shape: a stroke 9 wide)
function GV:wire_at(x, y)
  for k = #self.wires, 1, -1 do
    local w = self.wires[k]
    local p = w.pts
    for i = 1, #p - 1 do
      local a, b = p[i], p[i + 1]
      local x0, x1 = math.min(a[1], b[1]), math.max(a[1], b[1])
      local y0, y1 = math.min(a[2], b[2]), math.max(a[2], b[2])
      if x >= x0 - 4.5 and x <= x1 + 4.5 and y >= y0 - 4.5 and y <= y1 + 4.5 and
         (a[1] == b[1] and x >= x0 - 4.5 or a[2] == b[2]) then
        if (a[2] == b[2] and x >= x0 and x <= x1) or (a[1] == b[1] and y >= y0 and y <= y1) then return w end
      end
    end
  end
  return nil
end

-- --- painted
function GV:block_cmds(out, it)
  local b = it.b
  local colour = V.FAMILY[b.family] or V.FAMILY.game
  local lod = self.m11
  local note = b.family == "note" or b.family == "notes"
  local chosen = it.picked or self.selected[b.n]
  out[#out + 1] = string.format("item %s %s", num(b.x), num(b.y))
  local edge = chosen and GV.PICKED or (it.hit and "#e8e8e8" or (it.lit and "#8a8a92" or GV.BORDER))
  out[#out + 1] = string.format("pen %s %d 16 64 %d", qc(edge), chosen and 2 or 1,
                                (self.selected[b.n] and not it.picked) and 2 or 1)
  out[#out + 1] = "brush " .. qc(note and "#2a2a22" or (self.hot == it and GV.CARD_HOVER or GV.CARD))
  out[#out + 1] = string.format("rectf 0 0 %d %d", b.w, b.h)
  if it.live_at and it.live_at > 0 then          -- the game ran it: green, strong while fresh
    local fresh = math.max(0.0, 1.0 - (w3.time() - it.live_at) / GV.LIVE_FADE)
    out[#out + 1] = string.format("pen %s %s", qc(GV.LIVE, math.floor(90 + 165 * fresh)), num(1.5 + 2.5 * fresh))
    out[#out + 1] = "nobrush"
    out[#out + 1] = string.format("rectf -3 -3 %d %d", b.w + 6, b.h + 6)
  end
  out[#out + 1] = string.format("fillrectf 0 0 %d %d %s", b.w, V.HEAD, qc(colour, 70))
  out[#out + 1] = string.format("fillrectf 0 0 3 %d %s", b.h, qc(colour))
  if lod < GV.DETAIL_ZOOM then                    -- far out: its name big, readable from afar
    local text = V.shows_name(b) and b.name or b.title
    local px = trunc(math.max(10, math.min(13 / math.max(lod, 0.05), b.h * 0.4, 40)))
    out[#out + 1] = string.format("fontpx %d 1 0", px)
    out[#out + 1] = "pen e8e8ecff 1"
    local lh = self:font_height(px)
    local lines = math.max(1, trunc(b.h * 0.9 // lh))
    out[#out + 1] = string.format("textelide 8 2 %d %d %d %d %s", b.w - 16, b.h - 4, ALIGN_CENTER | WORD_WRAP,
                                  trunc((b.w - 16) * lines * 0.95), txt(text))
    return
  end
  out[#out + 1] = "fontpx 12 1 0"
  out[#out + 1] = "pen f2f2f4ff 1"
  out[#out + 1] = string.format("textelide 9 0 %d %d %d %d %s", b.w - 16, V.HEAD, ALIGN_LEFT_V, b.w - 16, txt(b.title))
  local y = V.HEAD
  if V.shows_name(b) then                         -- the designer's name for it
    out[#out + 1] = "fontpx 11 1 0"
    out[#out + 1] = "pen ececf0ff 1"
    out[#out + 1] = string.format("textelide 9 %d %d %d %d %d %s", y, b.w - 16, V.LINE, ALIGN_LEFT_V, b.w - 16,
                                  txt(b.name))
    y = y + V.LINE
  end
  out[#out + 1] = "fontpx 11 0 0"
  out[#out + 1] = "pen " .. (note and "e0dcc0ff" or "b4b4bcff") .. " 1"
  for k = 1, math.min(#b.lines, note and 8 or 3) do
    out[#out + 1] = string.format("textelide 9 %d %d %d %d %d %s", y, b.w - 16, V.LINE, ALIGN_LEFT_V, b.w - 16,
                                  txt(b.lines[k]))
    y = y + V.LINE
  end
  out[#out + 1] = "fontpx 10 0 0"
  local top = V.HEAD + V.text_rows(b) * V.LINE
  local half = b.w / 2
  for k, name in ipairs(b.inputs) do              -- inputs at the left, outputs at the right
    local yy = top + (k - 1) * V.ROW
    out[#out + 1] = string.format("fillrectf -4 %s 8 8 9a9aa4ff", num(yy + V.ROW / 2 - 4))
    if name ~= "" then
      out[#out + 1] = "pen 9a9aa0ff 1"
      out[#out + 1] = string.format("textelide 8 %d %s %d %d %d %s", yy, num(half - 8), V.ROW, ALIGN_LEFT_V,
                                    trunc(half - 10), txt(name))
    end
  end
  for k, name in ipairs(b.outputs) do
    local yy = top + (k - 1) * V.ROW
    out[#out + 1] = string.format("fillrectf %d %s 8 8 %s", b.w - 4, num(yy + V.ROW / 2 - 4),
                                  qc(GV.WIRE_COLOUR[name] or "#9a9aa4"))
    if name ~= "" then
      out[#out + 1] = "pen 9a9aa0ff 1"
      out[#out + 1] = string.format("textelide %s %d %s %d %d %d %s", num(half), yy, num(half - 8), V.ROW,
                                    ALIGN_RIGHT_V, trunc(half - 10), txt(name))
    end
  end
  if b.opens then
    out[#out + 1] = "pen 9a9aa0ff 1"
    out[#out + 1] = string.format("textrect %d 0 20 %d %d %s", b.w - 26, V.HEAD, ALIGN_RIGHT_V, "»")
  end
end

-- QFontMetrics(QFont("Segoe UI", px, bold)).height(), asked of Qt once per size
local heights = {}
function GV:font_height(px)
  if heights[px] == nil then
    local ok, h = pcall(w3.plugin.cj_qt_font_height, tostring(px), "1")
    heights[px] = ok and tonumber(h) or math.floor(px * 1.33 + 0.5)
  end
  return heights[px]
end

function GV:wire_cmds(out, w)
  local c = w.chosen and GV.PICKED or (GV.WIRE_COLOUR[w.link[2]] or GV.WIRE)
  if w.lit then c = GV.LIGHTER[c] or c end
  out[#out + 1] = string.format("pen %s %s 16 64 %d", qc(c), (w.chosen or w.lit) and "2.6" or "1.3", w.back and 2 or 1)
  out[#out + 1] = "nobrush"
  local parts = {"path M", num(w.pts[1][1]), num(w.pts[1][2])}
  for i = 2, #w.pts do
    parts[#parts + 1] = "L"
    parts[#parts + 1] = num(w.pts[i][1])
    parts[#parts + 1] = num(w.pts[i][2])
  end
  out[#out + 1] = table.concat(parts, " ")
end

function GV:commands()
  local out = {}
  out[#out + 1] = "fill " .. qc(GV.BG)
  out[#out + 1] = "aa 1"
  out[#out + 1] = string.format("view %s %s %s", num(self.m11), num(self:sx()), num(self:sy()))
  local x0, y0 = self:to_scene(0, 0)
  local x1, y1 = self:to_scene(self.vw, self.vh)
  local function seen(x, y, w, h) return x <= x1 + 1 and x + w >= x0 - 1 and y <= y1 + 1 and y + h >= y0 - 1 end
  -- (the order Qt paints them: by z - the links at -1, a lit or chosen one at -0.5, the blocks 0 - then as added)
  for pass = 1, 2 do
    for _, w in ipairs(self.wires) do
      local front = w.lit or w.chosen
      if (pass == 1) ~= front then
        local x, y, ww, hh = wire_rect(w.pts)
        if x and seen(x, y, ww, hh) then
          out[#out + 1] = "world"
          self:wire_cmds(out, w)
        end
      end
    end
  end
  for _, n in ipairs(self.order) do
    local it = self.blocks[n]
    if seen(block_rect(it.b)) then self:block_cmds(out, it) end
  end
  if self.drag and self.drag.pts then             -- a link being drawn
    out[#out + 1] = "world"
    out[#out + 1] = string.format("pen %s 1.6 16 64 2", qc(GV.PICKED))
    out[#out + 1] = "nobrush"
    local p = self.drag.pts
    out[#out + 1] = string.format("path M %s %s L %s %s L %s %s L %s %s", num(p[1]), num(p[2]), num(p[3]), num(p[4]),
                                  num(p[5]), num(p[6]), num(p[7]), num(p[8]))
  end
  if self.band then                               -- the frame choosing blocks (the style's rubber band)
    local b = self.band
    out[#out + 1] = "view 1 0 0"
    out[#out + 1] = "pen 3399ffff 1"
    out[#out + 1] = "brush 3399ff40"
    out[#out + 1] = string.format("rect %d %d %d %d", math.min(b[1], b[3]), math.min(b[2], b[4]),
                                  math.abs(b[3] - b[1]), math.abs(b[4] - b[2]))
  end
  return out
end

function GV:picture()
  local list = self:commands()
  local cmds = table.concat(list, "\n")
  if self.img and cmds == self.img_key then return self.img end
  if not require("conjunction.ui.graph_view").QT_PAINT then     -- (the game draws them: ui/painter.lua)
    self.img = {steps = require("conjunction.ui.painter").compile(list)}
    self.img_key = cmds
    return self.img
  end
  local ok = pcall(w3.plugin.cj_qt_paint, self.file, tostring(self.vw), tostring(self.vh), cmds, "fast")
  if ok then
    local id, iw, ih = w3.ui.image_load(self.file)
    if id then
      if self.img and self.img[1] then w3.ui.image_free(self.img[1]) end
      self.img = {id, iw, ih}
    end
  end
  self.img_key = cmds
  return self.img
end

function GV:free()
  if self.img and self.img[1] then w3.ui.image_free(self.img[1]) end
  self.img, self.img_key = nil, nil
end

-- the tooltip of a block: its title and name, what it does, its comment, its kind's words
local function block_tip(b)
  local lines = {b.title .. (b.name ~= "" and (": " .. b.name) or "")}
  for k = 1, math.min(6, #b.lines) do lines[#lines + 1] = b.lines[k] end
  if b.comment ~= "" then lines[#lines + 1] = "comment: " .. b.comment end
  if b.kind then lines[#lines + 1] = b.kind.text end
  return table.concat(lines, "\n")
end

-- --- one frame in r (the view with its frame): the size, the mouse, the picture, the bars
function GV:frame(r, hovered)
  self:resize(math.floor(r.w), math.floor(r.h))
  self:layout()
  local vx, vy = r.x + 1, r.y + 1
  local mx, my, wheel = w3.ui.mouse()
  local ax, ay = mx - vx, my - vy
  local inside = hovered and ax >= 0 and ay >= 0 and ax < self.vw and ay < self.vh
  local sx, sy = self:to_scene(ax, ay)
  local hot = (inside and not self.press) and self:block_at(sx, sy) or (self.press and self.press.item or nil)
  if hot ~= self.hot then
    self.hot = hot
    self:light(hot)
  end
  if inside and wheel and wheel ~= 0 and not self.press then
    local k = wheel > 0 and 1.15 or 1 / 1.15
    local s = self.m11 * k
    if s >= GV.MIN_ZOOM and s <= GV.MAX_ZOOM then self:scale(k, {math.floor(ax), math.floor(ay)}) end
  end
  local ctrl, shift = w3.ui.mods()
  if inside and w3.ui.mouse_double(1) then
    local it = self:block_at(sx, sy)
    if it and it.b.opens and self.on_open then self.on_open(it.b.n) end
  elseif inside and w3.ui.mouse_clicked(1) then
    local it = self:block_at(sx, sy)
    if it then
      local side, name = GV.port_at(it.b, sx - it.b.x, sy - it.b.y)
      if self.editable and side == "out" then
        self.drag = {item = it, output = name}
        self:drag_to(sx, sy)
      else
        if not ctrl then
          self:pick(it)
          if not self.selected[it.b.n] then self.selected = {} end
        end
        if ctrl then self.selected[it.b.n] = not self.selected[it.b.n] or nil else self.selected[it.b.n] = true end
        local group = {}
        for n in pairs(self.selected) do group[n] = {self.blocks[n].b.x, self.blocks[n].b.y} end
        group[it.b.n] = {it.b.x, it.b.y}
        self.press = {ax, ay, item = it, group = group, from = {sx, sy}}
      end
    else
      local w = self:wire_at(sx, sy)
      if w then
        self:pick(nil)
        self:choose_wire(w)
      elseif shift then
        self.band = {ax, ay, ax, ay}
        self.press = {ax, ay, band = true}
      else
        self.press = {ax, ay, last = {ax, ay}}    -- (ScrollHandDrag: the graph follows the mouse)
      end
    end
  end
  if inside and w3.ui.mouse_clicked(2) and self.on_menu then
    local it = self:block_at(sx, sy)
    local w = not it and self:wire_at(sx, sy) or nil
    if w then self:choose_wire(w) elseif it then self:pick(it) end
    self.on_menu(it and {"block", it.b} or (w and {"wire", w.link} or nil), mx, my, sx, sy)
  end
  if self.drag then
    if w3.ui.mouse_down(1) then
      self:drag_to(sx, sy)
    else
      local d = self.drag
      self.drag = nil
      local target = self:block_at(sx, sy)
      if target and target ~= d.item and (#target.b.inputs > 0 or d.output == "Thunder") then
        local side, name = GV.port_at(target.b, sx - target.b.x, sy - target.b.y)
        local put = (side == "in") and name or (target.b.inputs[1] or "In")
        if d.output == "Thunder" then
          for _, s in ipairs(V.sockets(target.b.cls)[1]) do
            if s == "Cut" then put = "Cut" break end    -- (a stop wired: into the block's Cut)
          end
        end
        if self.on_connect then self.on_connect(d.item.b.n, d.output, target.b.n, put) end
      end
    end
  elseif self.press then
    local p = self.press
    if w3.ui.mouse_down(1) then
      if p.item then                              -- a block (and those chosen with it) moved
        if self.editable then
          local dx, dy = sx - p.from[1], sy - p.from[2]
          for n, at in pairs(p.group) do
            local b = self.blocks[n].b
            b.x, b.y = math.floor(at[1] + dx), math.floor(at[2] + dy)
          end
          p.moved = dx ~= 0 or dy ~= 0
          if p.moved then self:reroute() end
        end
      elseif p.band then
        p.band = true
        self.band[3], self.band[4] = ax, ay
      else
        local dx, dy = ax - p.last[1], ay - p.last[2]
        p.last = {ax, ay}
        if dx ~= 0 then self:set_h(self.hval - dx) end
        if dy ~= 0 then self:set_v(self.vval - dy) end
        if dx ~= 0 or dy ~= 0 then self:update_center() end
      end
    else
      self.press = nil
      if p.item then
        if p.moved and self.on_moved then
          for n, at in pairs(p.group) do
            local b = self.blocks[n].b
            if b.x ~= at[1] or b.y ~= at[2] then self.on_moved(n, b.x, b.y) end
          end
        end
      elseif p.band then
        local b = self.band
        self.band = nil
        local ax0, ay0 = self:to_scene(math.min(b[1], b[3]), math.min(b[2], b[4]))
        local ax1, ay1 = self:to_scene(math.max(b[1], b[3]), math.max(b[2], b[4]))
        self.selected = {}
        for _, n in ipairs(self.order) do       -- (Qt's IntersectsItemShape: what the frame touches)
          local bx, by, bw, bh = block_rect(self.blocks[n].b)
          if bx < ax1 and bx + bw > ax0 and by < ay1 and by + bh > ay0 then self.selected[n] = true end
        end
      elseif math.abs(ax - p[1]) + math.abs(ay - p[2]) < 4 then
        if self.current then self:pick(nil) end -- a click on the empty graph: nothing picked
        self.selected = {}
        self:choose_wire(nil)
      end
    end
  end
  if self.hot and not self.press and not self.drag then
    w3.ui.cursor("hand")
    CT.tip("vg.block." .. self.hot.b.n, {"", block_tip(self.hot.b)})
  end
  Q.frame(r.x, r.y, r.w, r.h, 0x141417ff, 0x333333ff)   -- (the view's background under its bars too)
  local img = self:picture()
  if img and img.steps then
    require("conjunction.ui.painter").draw(img.steps, vx, vy, self.vw, self.vh)
  elseif img then
    D.image(img[1], vx, vy, img[2], img[3])
  end
  local AG = package.loaded["conjunction.agent"]        -- (the blocks in view, for the agent: by title and name)
  if AG and self.order then
    for _, key in ipairs(self.order) do
      local it = self.blocks[key]
      if it and it.b then
        local bx, by, bw, bh = block_rect(it.b)
        local x1, y1 = self:from_scene(bx, by)
        local x2, y2 = self:from_scene(bx + bw, by + bh)
        if x2 > 0 and y2 > 0 and x1 < self.vw and y1 < self.vh then
          local b = it.b
          AG.area("vg.block." .. tostring(b.n or key), vx + x1, vy + y1, x2 - x1, y2 - y1,
                  (b.title or "") .. ((b.name or "") ~= "" and (": " .. b.name) or ""))
        end
      end
    end
  end
  local hit = function(id, rr) return CT.hit_box(id, rr) end
  if self.vbar_on then
    local b = self.vbar
    b.page = self.vpage
    IV.range(b, self.vmax - self.vmin)
    IV.set(b, self.vval - self.vmin)
    SBAR.draw(self.bar_state, "vg.vbar", b, {x = vx + self.vw, y = vy, w = 10, h = self.vh}, "v", hit,
              function(bb) self:set_v(self.vmin + bb.value) self:update_center() end)
  end
  if self.hbar_on then
    local b = self.hbar
    b.page = self.hpage
    IV.range(b, self.hmax - self.hmin)
    IV.set(b, self.hval - self.hmin)
    SBAR.draw(self.bar_state, "vg.hbar", b, {x = vx, y = vy + self.vh, w = self.vw, h = 10}, "h", hit,
              function(bb) self:set_h(self.hmin + bb.value) self:update_center() end)
  end
end

-- a link being drawn: out to the right, then along the middle to the mouse
function GV:drag_to(sx, sy)
  local d = self.drag
  local x0, y0 = V.out_port(d.item.b, d.output)
  local mx = math.max(x0 + 20, (x0 + sx) / 2)
  d.pts = {x0, y0, mx, y0, mx, sy, sx, sy}
end

return GV
