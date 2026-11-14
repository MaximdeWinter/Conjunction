-- graph_view.py: the quest graph on screen - PathView's look (a dark dotted grid, blocks in their own shapes,
-- orthogonal wires with small arrowheads), a node editor (nodes stand where they are put, wires are drawn by hand).
-- Qt draws it (cj_qt_paint: the scene's items as QGraphicsView paints them, with the view's transform); the view's
-- scrolling and zoom are QGraphicsView's own arithmetic (its scroll bars' values, their ranges from the scene rect).
--
--   local v = GV.new(on)        on: picked(id), opened(id), kind_menu(id, x, y), node_menu(id, x, y),
--                               wire_menu(link, x, y), place(block, drop), moved(id, x, y), connect(from, output,
--                               to, beside), relink(link, to), unlink(link)  (x, y: the screen point)
--   v:show_graph(g, keep)       routes and draws it (quest_graph.build_nodes); keep: the view stays
--   v:frame(r)                  the view in r (screen pixels): the picture, the mouse
--   v:select(id), v:select_wire(link), v:home(), v:show_node(id, margin)
local L = require("conjunction.graph_layout")
local R = require("conjunction.graph_route")
local QG = require("conjunction.quest_graph")
local P = require("conjunction.py")
local D = w3.ui.draw
local GV = {}
GV.__index = GV

GV.SURFACE = "#08080c"
GV.RAISED = "#1c1c26"
GV.EDGE = "#808090"
GV.TEXT = "#f0f0f5"
GV.MUTED = "#808090"
GV.DOT = "#1f1f2b"
GV.ACCENT = "#0088E8"
GV.PICKED = "#e8b64c"
GV.LIVE = {[1] = {"NOW", "#e3c65f"}, [2] = {"DONE", "#22c55e"}, [3] = {"FAILED", "#ef4444"}}
GV.MOVE_PX = 6
GV.PORT_HIT = 9
GV.QT_PAINT = false                             -- true: Qt paints the picture (the app's pixels; the lab's comparison)
local BORDER = "80809078"                     -- QColor(128, 128, 144, 120)
local LINE_BG = "ffffff0e"                    -- QColor(255, 255, 255, 14)
local VCENTER, CENTER, RIGHT_V = 0x80, 0x84, 0x82

-- a colour as the commands write it: "#rrggbb" (and an alpha) -> "rrggbbaa"
local function qc(c, alpha)
  c = c:gsub("^#", ""):lower()
  return c .. string.format("%02x", alpha or 255)
end
GV.qc = qc

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
-- a text as the command line takes it (one a line: a line break as 0x1e)
local function txt(s) return (P.str(s):gsub("\r\n", "\30"):gsub("[\r\n]", "\30")) end

-- QFontMetrics(_font(px, bold, spacing)).horizontalAdvance(text), asked of Qt once per text
local advances = {}
function GV.advance(px, bold, spacing, text)
  local key = px .. (bold and "b" or "") .. spacing .. "\0" .. text
  local v = advances[key]
  if v == nil then
    local ok, r = pcall(w3.plugin.cj_qt_advance, tostring(px), bold and "1" or "0", tostring(spacing), text)
    v = ok and tonumber(r) or 0
    advances[key] = v
  end
  return v
end

-- Qt's qRound (and q_round_bound): halves away from zero for positives, towards +inf for negatives
local function qround(d)
  if d >= 0 then return math.floor(d + 0.5) end
  local i1 = math.tointeger(d - 1 >= 0 and math.floor(d - 1) or math.ceil(d - 1))     -- int(d - 1): truncated
  return math.tointeger(math.floor(d - i1 + 0.5)) + i1
end
GV.qround = qround
-- Qt 6's qRound (centerOn, QPointF::toPoint): halves away from zero - int(d + 0.5), int(d - 0.5); q_round_bound (the
-- bars' ranges) keeps the rule above (dialogue_n1: -26.5 is -27 in centerOn)
local function qround6(d)
  if d >= 0 then return math.tointeger(math.floor(d + 0.5)) end
  return math.tointeger(math.ceil(d - 0.5))
end
GV.qround6 = qround6
local function trunc(d) return d >= 0 and math.floor(d) or math.ceil(d) end

-- --- the outline of a node: its block's shape (the cut corners say what it is)
local function chamfered(r, tl, tr, br, bl)
  local x0, y0, x1, y1 = r[1], r[2], r[1] + r[3], r[2] + r[4]
  return {x0 + tl, y0, x1 - tr, y0, x1, y0 + tr, x1, y1 - br, x1 - br, y1, x0 + bl, y1, x0, y1 - bl, x0, y0 + tl}
end
function GV.shape(node, r)
  local k, b = node.kind, node.block
  if L.ENDS[k] then
    local c = r[4] / 2
    return chamfered(r, c, c, c, c)
  end
  if b == "choice" then return chamfered(r, 12, 0, 12, 0) end
  if b == "parallel" or k == "start" or k == "path" then return chamfered(r, 9, 9, 9, 9) end
  if b == "action" or b == "chapter" then
    -- QPainterPath.addRect: moveTo the top left, lines round, closed
    return {r[1], r[2], r[1] + r[3], r[2], r[1] + r[3], r[2] + r[4], r[1], r[2] + r[4]}, true
  end
  return chamfered(r, 5, 5, 5, 5)
end
local function path_cmd(pts, closed_rect)
  local out = {"M", num(pts[1]), num(pts[2])}
  for i = 3, #pts, 2 do
    out[#out + 1] = "L"
    out[#out + 1] = num(pts[i])
    out[#out + 1] = num(pts[i + 1])
  end
  if closed_rect then
    out[#out + 1] = "L"
    out[#out + 1] = num(pts[1])
    out[#out + 1] = num(pts[2])
  end
  out[#out + 1] = "Z"
  return table.concat(out, " ")
end

function GV.new(on)
  local self = setmetatable({on = on or {}, graph = nil, chosen = nil, chosen_wire = nil, live = nil, press = nil,
                             drag = nil, drop = nil, cursor_at = nil, hot_port = nil, hot_node = nil,
                             hot_title = false, fresh = false, m11 = 1.0, hval = 0, vval = 0, vw = 100, vh = 30,
                             scene_rect = {0, 0, 0, 0}, left_indent = 0, top_indent = 0, hmin = 0, hmax = 0,
                             vmin = 0, vmax = 0, img = nil, img_key = nil, last_paint = 0}, GV)
  self.file = (os.getenv("TEMP") or ".") .. "\\cj_graph_" .. tostring(self):gsub("[^%w]", "") .. ".png"
  return self
end

-- --- QGraphicsView's arithmetic: the scroll bars' ranges and values, the transform (a scale only)
function GV:recalc()
  local s = self.m11
  local sr = self.scene_rect
  local vx, vy, vw, vh = sr[1] * s, sr[2] * s, sr[3] * s, sr[4] * s       -- (matrix.mapRect of the scene rect)
  local old_l, old_t = self.left_indent, self.top_indent
  local left, right = qround(vx), qround(vx + vw - self.vw)
  if left >= right then
    self.left_indent = self.vw // 2 - (vx + (vx + vw)) / 2      -- (maxSize.width() / 2: an int)
    self.hmin, self.hmax = 0, 0
    self.hval = 0
  else
    self.left_indent = 0
    self.hmin, self.hmax = left, right
    if old_l ~= 0 then self.hval = -old_l end
    self.hval = math.max(left, math.min(right, self.hval))
  end
  local top, bottom = qround(vy), qround(vy + vh - self.vh)
  if top >= bottom then
    self.top_indent = self.vh // 2 - (vy + (vy + vh)) / 2
    self.vmin, self.vmax = 0, 0
    self.vval = 0
  else
    self.top_indent = 0
    self.vmin, self.vmax = top, bottom
    if old_t ~= 0 then self.vval = -old_t end
    self.vval = math.max(top, math.min(bottom, self.vval))
  end
end
function GV:set_h(v) self.hval = math.max(self.hmin, math.min(self.hmax, math.tointeger(v) or qround6(v))) end
function GV:set_v(v) self.vval = math.max(self.vmin, math.min(self.vmax, math.tointeger(v) or qround6(v))) end
-- the scroll offset QGraphicsViewPrivate keeps (qint64(-leftIndent) + the bar's value)
function GV:scroll()
  return trunc(-self.left_indent) + self.hval, trunc(-self.top_indent) + self.vval
end
-- mapToScene(QPoint) / mapFromScene(QPointF) -> QPoint
function GV:to_scene(px, py)
  local sx, sy = self:scroll()
  local inv = 1 / self.m11
  return (px + sx) * inv, (py + sy) * inv
end
function GV:from_scene(x, y)
  local sx, sy = self:scroll()
  return qround6(x * self.m11 - sx), qround6(y * self.m11 - sy)
end
function GV:center_on(x, y)
  if self.left_indent == 0 then self:set_h(qround6(x * self.m11 - self.vw / 2.0)) end
  if self.top_indent == 0 then self:set_v(qround6(y * self.m11 - self.vh / 2.0)) end
end
function GV:scale(f)
  local m = self.m11 * f
  if m == self.m11 then return end
  self.m11 = m
  self:recalc()                               -- (NoAnchor: the bars keep their values)
end
function GV:reset_transform()
  if self.m11 ~= 1.0 then
    self.m11 = 1.0
    self:recalc()
  end
end
function GV:ensure_visible(rx, ry, rw, rh, xm, ym)
  local s = self.m11
  local l, t = rx * s, ry * s
  local r, b = l + rw * s, t + rh * s
  local sx, sy = self:scroll()
  local left, right, top, bottom = sx, sx + self.vw, sy, sy + self.vh
  if l <= left + xm and self.left_indent == 0 then self:set_h(trunc(l - xm - 0.5)) end
  if r >= right - xm and self.left_indent == 0 then self:set_h(trunc(r - self.vw + xm + 0.5)) end
  if t <= top + ym and self.top_indent == 0 then self:set_v(trunc(t - ym - 0.5)) end
  if b >= bottom - ym and self.top_indent == 0 then self:set_v(trunc(b - self.vh + ym + 0.5)) end
end

-- the viewport's size (a resize: the ranges anew; homed again until looked around in)
function GV:resize(w, h)
  if w == self.vw and h == self.vh then return end
  self.vw, self.vh = w, h
  self:recalc()
  if self.fresh then self:home() end
end

-- --- building
function GV:show_graph(g, keep)
  if keep == nil then keep = true end
  local cx, cy, kh, kv
  if self.graph ~= nil and keep then
    -- mapToScene(viewport().rect().center()): QRect's centre ((w - 1) / 2, integer)
    cx, cy = self:to_scene((self.vw - 1) // 2, (self.vh - 1) // 2)
    kh, kv = self.hval, self.vval
  end
  self.settling = nil                           -- (the moved node is where it was let go now: its wires drawn again)
  for _, n in pairs(g.nodes) do n.w, n.h = L.size(n) end
  R.route(g)
  self.graph = g
  local x0, y0, x1, y1
  for _, n in pairs(g.nodes) do
    x0 = x0 and math.min(x0, n.x) or n.x
    y0 = y0 and math.min(y0, n.y) or n.y
    x1 = x1 and math.max(x1, n.x + n.w) or n.x + n.w
    y1 = y1 and math.max(y1, n.y + n.h) or n.y + n.h
  end
  if x0 == nil then x0, y0, x1, y1 = 0, 0, 0, 0 end
  self.scene_rect = {x0 - 3000, y0 - 3000, (x1 - x0) + 6000, (y1 - y0) + 6000}
  self:recalc()
  for _, n in pairs(g.nodes) do self:title_rect(n) end
  if self.hot_node and not g.nodes[self.hot_node] then self.hot_node = nil end
  if cx ~= nil then
    -- the bars as they were (the scroll values are the scene's, its rect changing does not move them): centred
    -- again on the centre's integer point the view crept a pixel up and left with each change, 13.11.
    self:center_on(cx, cy)
    if self.left_indent == 0 then self:set_h(kh) end
    if self.top_indent == 0 then self:set_v(kv) end
  else
    self:home()
    self.fresh = true
  end
  self.img_key = nil
end

function GV:has_input(nid) return self.graph.nodes[nid].kind ~= "start" end

function GV:exit_colour(node, k)
  local ex = node.exits[k]
  return QG.PORT_COLOUR[ex.to] or (ex.wired and GV.EDGE or GV.MUTED)
end

-- the kinds a node's block can be (its title opens them), or {} for the graph's own nodes
function GV:kinds_of(node)
  if node.card == nil or node.card.i == nil or node.block == "chapter" or node.block == "end" or node.block == "" then
    return {}
  end
  local kinds = QG.KINDS_OF[node.block] or {}
  if not require("conjunction.features").experimental() then
    local out = {}
    for _, k in ipairs(kinds) do if k ~= "worldchange" then out[#out + 1] = k end end
    kinds = out
  end
  return kinds
end

-- where the kind is drawn (NodeItem.title_rect), worked out as paint does
function GV:title_rect(n)
  n.title_rect = nil
  if L.ENDS[n.kind] or #self:kinds_of(n) == 0 then return end
  local x = 12
  if n.number ~= 0 then x = x + GV.advance(11, true, 0, tostring(n.number)) + 7 end
  local width = GV.advance(9, true, 0.6, n.title .. " ▾")
  n.title_rect = {x - 4, 7, width + 8, L.HEAD - 14}
end

-- --- looking around
function GV:home()
  self:reset_transform()
  local g = self.graph
  if g == nil or next(g.nodes) == nil then return end
  local left, right, top
  for _, n in pairs(g.nodes) do
    left = left and math.min(left, n.x) or n.x
    right = right and math.max(right, n.x + n.w) or n.x + n.w
    top = top and math.min(top, n.y) or n.y
  end
  local want = math.min(1.0, math.max(GV.MIN_ZOOM, (self.vw - 40) / math.max(1, right - left + 40)))
  self:scale(want)
  self:center_on((left + right) / 2, top + self.vh / 2 / want - 30 / want)
end

function GV:select(nid) self.chosen = nid end
function GV:select_wire(link) self.chosen_wire = link end

function GV:bounding(n)
  local extra = 0
  for _, e in ipairs(n.exits) do if QG.fails_here(e) then extra = QG.FAIL_MARK + 10 break end end
  return n.x - 8, n.y - 8, n.w + 16 + extra, n.h + 16
end

function GV:show_node(nid, margin)
  margin = margin or 40
  self.fresh = false
  local n = self.graph and self.graph.nodes[nid]
  if n then
    local x, y, w, h = self:bounding(n)
    self:ensure_visible(x, y, w, h, margin, margin)
  end
end

-- the wheel: zoom around the point under the mouse
-- the least zoom of the graph and the dialogue's flow (MaximdeWinter 13.11.: zoomed out to 0.25 nothing could be read - the
-- 9 to 12 px of their text were 2 to 3 px; at 0.6 the smallest is 5.4 px, the lines' 7)
GV.MIN_ZOOM = 0.6
function GV:wheel(notches, at_x, at_y)
  self.fresh = false
  local f = 1.15 ^ (notches * 120 / 120)
  local now = self.m11
  f = math.max(GV.MIN_ZOOM / now, math.min(2.0 / now, f))
  local bx, by = self:to_scene(at_x, at_y)
  self:scale(f)
  local mx, my = self:from_scene(bx, by)
  self:set_h(self.hval + (mx - at_x))
  self:set_v(self.vval + (my - at_y))
end

-- --- what is where (scene points)
function GV:node_at(x, y)
  local ids = {}
  for id in pairs(self.graph.nodes) do ids[#ids + 1] = id end
  for i = #ids, 1, -1 do                          -- (the topmost first: the last one added)
    local n = self.graph.nodes[ids[i]]
    if n.x <= x and x <= n.x + n.w and n.y <= y and y <= n.y + n.h then return n end
  end
  return nil
end

function GV:port_at(x, y)
  for _, n in pairs(self.graph.nodes) do
    if n.goes_on and not L.ENDS[n.kind] then
      local px, py = L.port(n, "next")
      if math.abs(x - px) <= GV.PORT_HIT + 4 and math.abs(y - py) <= GV.PORT_HIT then return {n.id, "next"} end
    end
    if #n.exits > 0 and n.x + n.w - GV.PORT_HIT <= x and x <= n.x + n.w + GV.PORT_HIT then
      for k = 0, #n.exits - 1 do
        local _, py = L.port(n, k)
        if math.abs(y - py) <= L.EXIT / 2 then return {n.id, k} end
      end
    end
  end
  return nil
end

function GV:input_at(x, y)
  for _, n in pairs(self.graph.nodes) do
    if n.kind ~= "start" then
      local px, py = L.port(n, "in")
      if math.abs(x - px) <= GV.PORT_HIT + 6 and math.abs(y - py) <= GV.PORT_HIT then return n.id end
    end
  end
  return nil
end

local function near_segment(x, y, a, b, d)
  if a[1] == b[1] then
    return math.abs(x - a[1]) <= d and math.min(a[2], b[2]) - d <= y and y <= math.max(a[2], b[2]) + d
  end
  return math.abs(y - a[2]) <= d and math.min(a[1], b[1]) - d <= x and x <= math.max(a[1], b[1]) + d
end
function GV:wire_at(x, y, d)
  d = d or 6
  for _, w in ipairs(self.graph.wires) do
    for i = 1, #w.points - 1 do
      if near_segment(x, y, w.points[i], w.points[i + 1], d) then return w end
    end
  end
  return nil
end

function GV:output_name(nid, port)
  if port == "next" then return "next" end
  return self.graph.nodes[nid].exits[port + 1].to
end

function GV:links_into(nid)
  local out = {}
  for _, w in ipairs(self.graph.wires) do if w.dst == nid then out[#out + 1] = w.link end end
  return out
end

local function same_link(a, b)
  return a ~= nil and b ~= nil and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end
GV.same_link = same_link

-- --- the picture (QGraphicsView.paintEvent: the background, the wires, the nodes, the drag's marks)
function GV.pulse(t)
  return 0.5 + 0.5 * math.sin((t or w3.time()) * 3.2)
end

function GV:paint_handle(out, x, y, c, vertical, filled)
  cmd(out, "pen", qc(c), 1.2)
  cmd(out, "brush", filled and qc(c) or qc(GV.SURFACE))
  local w, h = 12, 7
  if not vertical then w, h = 7, 12 end
  cmd(out, "rectf", x - w / 2, y - h / 2, w, h)
end

-- the + of a wired output: drag it onto a node for one more way at the same time
GV.PLUS_OFF = 17                 -- the + of a wired output: this far right of its port (the bottom one)
GV.PLUS_IN = 17                  -- an exit's: this far inside the node, left of its port
function GV:paint_plus(out, x, y, hot)
  cmd(out, "pen", qc(hot and GV.ACCENT or GV.EDGE), 1.2)
  cmd(out, "brush", qc(GV.SURFACE))
  cmd(out, "rectf", x - 5, y - 5, 10, 10)
  cmd(out, "linef", x - 3, y, x + 3, y)
  cmd(out, "linef", x, y - 3, x, y + 3)
end
local function same_plus(a, id, k) return a ~= nil and a[1] == id and a[2] == k end

-- (node id, output) of the + beside a wired output at x, y (the scene's)
function GV:plus_at(x, y)
  for _, n in pairs(self.graph.nodes) do
    if n.goes_on and not L.ENDS[n.kind] and n.next_wired == true then
      local px, py = L.port(n, "next")
      if math.abs(x - (px + GV.PLUS_OFF)) <= 7 and math.abs(y - py) <= 7 then return {n.id, "next"} end
    end
    for k0, ex in ipairs(n.exits or {}) do
      if ex.wired == true and not QG.fails_here(ex) then
        local _, py = L.port(n, k0 - 1)
        if math.abs(x - (n.x + n.w - GV.PLUS_IN)) <= 7 and math.abs(y - py) <= 7 then return {n.id, k0 - 1} end
      end
    end
  end
  return nil
end

function GV:paint_ports(out, n)
  if self:has_input(n.id) then
    local px = L.port(n, "in")
    self:paint_handle(out, px - n.x, 0, GV.EDGE, true, #self:links_into(n.id) > 0)
  end
  if n.goes_on and not L.ENDS[n.kind] then
    local hot = self.hot_port ~= nil and self.hot_port[1] == n.id and self.hot_port[2] == "next"
    local px = L.port(n, "next")
    self:paint_handle(out, px - n.x, n.h, hot and GV.ACCENT or GV.EDGE, true, n.next_wired == true)
    if n.next_wired == true then
      self:paint_plus(out, px - n.x + GV.PLUS_OFF, n.h, same_plus(self.hot_plus, n.id, "next"))
    end
  end
end

function GV:paint_node(out, n, pulse_now)
  cmd(out, "save")
  cmd(out, "item", n.x, n.y)
  cmd(out, "aa", 1)
  local r = {0.5, 0.5, n.w - 1, n.h - 1}
  local pts, rect = GV.shape(n, r)
  local outline = path_cmd(pts, rect)
  local colour = qc(P.T(n.colour) and n.colour or GV.EDGE)
  local live = self.live and GV.LIVE[self.live(n)] or nil
  local selected = self.chosen == n.id
  local hot = self.hot_node == n.id
  if live and live[1] == "NOW" then
    cmd(out, "pen", qc(live[2], 70), 6)
    cmd(out, "nobrush")
    out[#out + 1] = "path " .. outline
  end
  if selected then
    cmd(out, "pen", qc(GV.PICKED, math.floor(50 + 110 * pulse_now)), 6)
    cmd(out, "nobrush")
    out[#out + 1] = "path " .. outline
  end
  cmd(out, "brush", qc(n.block == "chapter" and "#22222e" or GV.RAISED))
  if L.ENDS[n.kind] then
    cmd(out, "pen", qc(n.colour, 170), 1)
  elseif selected then
    cmd(out, "pen", qc(GV.PICKED), 1.6)
  elseif live and live[1] == "NOW" then
    cmd(out, "pen", qc(live[2]), 1.3)
  elseif QG.PLACEHOLDERS[n.kind] then
    cmd(out, "pen", qc("#b0b0c0", 170), 1, 0x10, 0x40, 2)
  elseif n.kind == "path" or n.block == "parallel" then
    cmd(out, "pen", qc(n.colour, 190), 1, 0x10, 0x40, 2)
  elseif hot then
    cmd(out, "pen", qc("#b0b0c0", 150), 1)
  else
    cmd(out, "pen", BORDER, 1)
  end
  out[#out + 1] = "path " .. outline
  if P.T(n.lane) and not L.ENDS[n.kind] and n.kind ~= "path" then     -- a path's column: its colour on the left
    cmd(out, "save")
    out[#out + 1] = "clippath " .. outline
    cmd(out, "fillrectf", 0, 0, 3, n.h, qc(n.lane))
    cmd(out, "restore")
  end
  if L.ENDS[n.kind] then
    cmd(out, "fontpx", 9, 1, 0.6)
    cmd(out, "pen", colour, 1)
    cmd(out, "textrect", r[1], r[2], r[3], r[4], CENTER, txt(n.title))
    self:paint_ports(out, n)
    cmd(out, "restore")
    return
  end
  -- the title row: number, KIND (a menu of what it does), · subject
  local x = 12
  if n.number ~= 0 then
    cmd(out, "fontpx", 11, 1, 0)
    cmd(out, "pen", qc(GV.TEXT), 1)
    cmd(out, "textrect", x, 0, 30, L.HEAD, VCENTER, tostring(n.number))
    x = x + GV.advance(11, true, 0, tostring(n.number)) + 7
  end
  local kinds = #self:kinds_of(n) > 0
  local title = n.title .. (kinds and " ▾" or "")
  local width = GV.advance(9, true, 0.6, title)
  if n.title_rect ~= nil and hot and self.hot_title then
    local tr = n.title_rect
    cmd(out, "pen", qc(P.T(n.colour) and n.colour or GV.EDGE, 200), 1)
    cmd(out, "brush", qc(P.T(n.colour) and n.colour or GV.EDGE, 30))
    cmd(out, "rectf", tr[1], tr[2], tr[3], tr[4])
  end
  cmd(out, "fontpx", 9, 1, 0.6)
  cmd(out, "pen", colour, 1)
  cmd(out, "textrect", x, 0, n.w - x - 10, L.HEAD, VCENTER, txt(title))
  x = x + width + 6
  if P.T(n.subject) and not L.subject_below(n) then   -- (too long: a row of its own under it, L.body)
    cmd(out, "fontpx", 10, 0, 0)
    cmd(out, "pen", qc(GV.MUTED), 1)
    cmd(out, "textelide", x, 0, n.w - x - 18, L.HEAD, VCENTER, trunc(math.max(0, n.w - x - 18)), txt("· " .. n.subject))
  end
  local right = n.w - 11
  if n.hidden then                                -- its eye shut: a small one here too
    local Q = require("conjunction.ui.qt")
    cmd(out, "imagefast", trunc(right - 6), trunc(L.HEAD / 2 - 6), 12, 12, Q.root .. "\\icons\\eye-off_808090_12.png")
    right = right - 16
  end
  if #n.missing > 0 then                          -- a red dot: something is still missing here
    cmd(out, "nopen")
    cmd(out, "brush", qc("#ef4444"))
    cmd(out, "ellipsec", right, L.HEAD / 2, 3, 3)
    right = right - 10
  end
  if live then
    cmd(out, "fontpx", 8, 1, 0.6)
    cmd(out, "pen", qc(live[2]), 1)
    cmd(out, "textrect", right - 60, 0, 60, L.HEAD, RIGHT_V, live[1])
  end
  local y = L.HEAD - 6
  for _, row in ipairs(L.body(n)) do
    if row[1] == "text" then
      local big = n.kind == "chapter" or n.kind == "path"
      cmd(out, "fontpx", big and 12 or 11, n.block ~= "action" and 1 or 0, 0)
      local c = n.kind == "path" and qc(n.colour) or QG.PLACEHOLDERS[n.kind] and qc("#b8b8c8") or qc(GV.TEXT)
      cmd(out, "pen", c, 1)
      if QG.PLACEHOLDERS[n.kind] then cmd(out, "fontpx", 11, 0, 0) end
    elseif row[1] == "subject" then
      cmd(out, "fontpx", 10, 0, 0)
      cmd(out, "pen", qc(GV.MUTED), 1)
    else
      cmd(out, "fontpx", 10, 0, 0)
      cmd(out, "pen", qc("#ef6b6b"), 1)
    end
    cmd(out, "textrect", 12, y, n.w - 22, L.LINE, VCENTER, txt(row[2]))
    y = y + L.LINE
  end
  -- the exits: one row each, the label at the right next to its port
  if #n.exits > 0 then
    local ey = L.exits_top(n)
    cmd(out, "pen", LINE_BG, 1)
    cmd(out, "linef", 1, ey, n.w - 1, ey)
    for k0, ex in ipairs(n.exits) do
      local k = k0 - 1
      local c = self:exit_colour(n, k0)
      local mark = ({next = "  ↓", retry = "  ↺"})[ex.to] or ""
      if QG.fails_here(ex) then
        c = QG.FAIL
        local y0 = ey + k * L.EXIT + L.EXIT / 2
        cmd(out, "pen", qc(QG.FAIL, 200), 1)
        cmd(out, "brush", qc(GV.RAISED))
        cmd(out, "rectf", n.w + 8, y0 - 7, QG.FAIL_MARK, 14)
        cmd(out, "fontpx", 8, 1, 0.5)
        cmd(out, "pen", qc(QG.FAIL), 1)
        cmd(out, "textrect", n.w + 8, y0 - 7, QG.FAIL_MARK, 14, CENTER, "FAILS")
      end
      local plus = ex.wired == true and not QG.fails_here(ex)
      cmd(out, "fontpx", 10, 0, 0)
      cmd(out, "pen", qc(c), 1)
      cmd(out, "textelide", 10, ey + k * L.EXIT, n.w - (plus and 40 or 22), L.EXIT, RIGHT_V, n.w - (plus and 58 or 40),
          txt(ex.label) .. "\31" .. mark)
      if plus then                                -- (inside: the wire leaves the port to the right)
        self:paint_plus(out, n.w - GV.PLUS_IN, ey + k * L.EXIT + L.EXIT / 2, same_plus(self.hot_plus, n.id, k))
      end
      local hp = self.hot_port
      local hotp = hp ~= nil and hp[1] == n.id and hp[2] == k
      self:paint_handle(out, n.w, ey + k * L.EXIT + L.EXIT / 2, hotp and GV.ACCENT or c, false, ex.wired == true)
    end
  end
  self:paint_ports(out, n)
  cmd(out, "restore")
end

function GV:paint_wire(out, w)
  if #w.points < 2 then return end
  local pts = {}
  for i, p in ipairs(w.points) do pts[i] = {p[1], p[2]} end
  local x0, y0 = pts[#pts - 1][1], pts[#pts - 1][2]
  local x1, y1 = pts[#pts][1], pts[#pts][2]
  local dx = (x1 > x0 and 1 or 0) - (x1 < x0 and 1 or 0)
  local dy = (y1 > y0 and 1 or 0) - (y1 < y0 and 1 or 0)
  pts[#pts] = {x1 - 6 * dx, y1 - 6 * dy}                -- (room for the arrowhead)
  local c = qc(P.T(w.colour) and w.colour or GV.EDGE, P.T(w.colour) and 230 or 255)
  cmd(out, "save")
  cmd(out, "world")
  cmd(out, "aa", 1)
  if same_link(w.link, self.chosen_wire) then
    cmd(out, "pen", qc(GV.ACCENT), 2.6, 0)
  else
    cmd(out, "pen", c, 1.4, 0)
  end
  if w.style == "lane" then cmd(out, "dash", 4, 3) end
  cmd(out, "nobrush")
  local parts = {"path", "M", num(pts[1][1]), num(pts[1][2])}
  for i = 2, #pts do
    parts[#parts + 1] = "L"
    parts[#parts + 1] = num(pts[i][1])
    parts[#parts + 1] = num(pts[i][2])
  end
  out[#out + 1] = table.concat(parts, " ")
  cmd(out, "restore")
  -- the arrowhead, its tip on the port (PathView's shape), turned as the wire comes in
  local head = {{-6, -3.2}, {0, 0}, {-6, 3.2}}
  local function turn(x, y)
    if dx == -1 then return -x, -y end            -- 180
    if dy == 1 then return -y, x end              -- 90
    if dy == -1 then return y, -x end             -- -90
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

-- what a drag would do, drawn over the graph (drawForeground)
function GV:paint_drag(out)
  if not self.drag or self.drag[1] == "pan" or self.cursor_at == nil then return end
  cmd(out, "world")
  cmd(out, "aa", 1)
  local accent = qc(GV.ACCENT)
  local kind = self.drag[1]
  local g = self.graph
  local cx, cy = self.cursor_at[1], self.cursor_at[2]
  if kind == "wire" or kind == "rewire" then
    local src, port
    if kind == "wire" then
      src, port = g.nodes[self.drag[2]], self.drag[3]
    else
      local link = self.drag[2]
      src = g.nodes[link[1]]
      port = "next"
      if link[2] ~= "next" then
        for k, e in ipairs(src.exits) do if e.to == link[2] then port = k - 1 break end end
      end
    end
    local ax, ay = L.port(src, port)
    cmd(out, "pen", self.drop and accent or qc(GV.MUTED), 1.6, 0x10, 0x40, 2)
    cmd(out, "linef", ax, ay, cx, cy)
    if self.drop then
      local n = g.nodes[self.drop]
      cmd(out, "pen", accent, 2)
      cmd(out, "nobrush")
      local pts, rect = GV.shape(n, {n.x - 3, n.y - 3, n.w + 6, n.h + 6})
      out[#out + 1] = "path " .. path_cmd(pts, rect)
    end
    return
  end
  if kind == "move" then
    local n = g.nodes[self.drag[2]]
    cmd(out, "pen", qc(GV.MUTED), 1.2, 0x10, 0x40, 2)
    for _, w in ipairs(g.wires) do
      if w.src == n.id or w.dst == n.id then
        local s, d = g.nodes[w.src], g.nodes[w.dst]
        local spx, spy = self:item_pos(s)
        local dpx, dpy = self:item_pos(d)
        local ax, ay = L.port(s, w.port)
        local bx, by = L.port(d, "in")
        cmd(out, "linef", ax - s.x + spx, ay - s.y + spy, bx - d.x + dpx, by - d.y + dpy)
      end
    end
    return
  end
  local d = self.drop
  if d == nil then return end
  if d[1] == "wire" then
    for _, w in ipairs(g.wires) do
      if same_link(w.link, d[2]) then
        cmd(out, "pen", accent, 3)
        cmd(out, "nobrush")
        local parts = {"path", "M", num(w.points[1][1]), num(w.points[1][2])}
        for i = 2, #w.points do
          parts[#parts + 1] = "L"
          parts[#parts + 1] = num(w.points[i][1])
          parts[#parts + 1] = num(w.points[i][2])
        end
        out[#out + 1] = table.concat(parts, " ")
        break
      end
    end
  end
  cmd(out, "pen", accent, 1, 0x10, 0x40, 2)
  cmd(out, "brush", qc(GV.RAISED, 200))
  cmd(out, "rectf", cx - 60, cy - 14, 120, 28)
  cmd(out, "pen", qc(GV.TEXT), 1)
  cmd(out, "fontpx", 10, 1, 0)
  cmd(out, "textrect", cx - 60, cy - 14, 120, 28, CENTER, txt((QG.LABEL[self.drag[2]] or self.drag[2]):upper()))
end

-- a block from the sidebar dragged over the graph: onto a wire - put into it; anywhere else - where it is let go
-- (on its own, wired by hand)
function GV:drop_at(x, y)
  local w = self:wire_at(x, y, 8)
  if w ~= nil then return {"wire", w.link, x, y} end
  return {"free", x, y}
end

-- the sidebar's block is dragged, the mouse at (px, py) of the view -> over the graph
function GV:block_over(kind, px, py)
  local inside = px >= 0 and py >= 0 and px < self.vw and py < self.vh
  self.drag = inside and {"block", kind} or nil
  self.cursor_at = inside and {self:to_scene(px, py)} or nil
  self.drop = inside and self:drop_at(self.cursor_at[1], self.cursor_at[2]) or nil
  return inside
end

function GV:block_dropped(kind, px, py)
  local inside = self:block_over(kind, px, py)
  local drop = self.drop
  self.drag, self.drop, self.cursor_at = nil, nil, nil
  if inside and drop ~= nil and self.on.place then self.on.place(kind, drop) end
  return inside
end

-- where a node's item stands now (a node being moved follows the mouse)
function GV:item_pos(n)
  if self.drag and self.drag[1] == "move" and self.drag[2] == n.id and self.move_at then
    return self.move_at[1], self.move_at[2]
  end
  return n.x, n.y
end

function GV:commands()
  local out = {}
  -- (in a window: painted as on its backing store - self.device {w, h, x, y}: the window, the viewport's place in it)
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
  -- the background: the exposed scene rect (the viewport mapped back), the dots on its 20 px grid
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
  local g = self.graph
  if g then
    local function visible(x, y, w, h) return x < r + 10 and x + w > l - 10 and y < b + 10 and y + h > t - 10 end
    for _, w in ipairs(g.wires) do
      local hidden = (self.drag and self.drag[1] == "move" and self.move_at and
                      (w.src == self.drag[2] or w.dst == self.drag[2])) or
                     (self.settling ~= nil and (w.src == self.settling or w.dst == self.settling))
      if not hidden then
        local wx0, wy0, wx1, wy1 = math.huge, math.huge, -math.huge, -math.huge
        for _, p in ipairs(w.points) do
          wx0, wy0, wx1, wy1 = math.min(wx0, p[1]), math.min(wy0, p[2]), math.max(wx1, p[1]), math.max(wy1, p[2])
        end
        if #w.points >= 2 and visible(wx0 - 8, wy0 - 8, wx1 - wx0 + 16, wy1 - wy0 + 16) then self:paint_wire(out, w) end
      end
    end
    local p = 0                                 -- (the breath: drawn over the picture, GV:draw_breath)
    for _, n in pairs(g.nodes) do
      local bx, by, bw, bh = self:bounding(n)
      local px, py = self:item_pos(n)
      if visible(bx - n.x + px, by - n.y + py, bw, bh) then
        if px ~= n.x or py ~= n.y then
          local ox, oy = n.x, n.y
          n.x, n.y = px, py
          self:paint_node(out, n, p)
          n.x, n.y = ox, oy
        else
          self:paint_node(out, n, p)
        end
      end
    end
    self:paint_drag(out)
  end
  return out
end

-- the picture made anew when something in it changed (and, a node picked, as its outline breathes: every 60 ms)
function GV:picture()
  local now = w3.time()
  -- (the commands are built again only when what they show may have changed: the mouse, a pick, a drag, the view,
  -- the graph - else at most every 0.25 s for what changes on its own; 24.10.: built each frame they took 5 ms)
  local function pt(p) return p and (tostring(p[1]) .. "," .. tostring(p[2])) or "-" end
  local function hp(p) return type(p) == "table" and (tostring(p[1]) .. ":" .. tostring(p[2])) or tostring(p) end
  local key = table.concat({tostring(self.graph), tostring(self.flow), tostring(self.chosen), tostring(self.chosen_wire),
                            tostring(self.chosen_row), tostring(self.hot_node), tostring(self.hot), hp(self.hot_port), hp(self.hot_plus), tostring(self.hot_row),
                            tostring(self.hot_title), tostring(self.drag), hp(self.drop), hp(self.drop_on),
                            tostring(self.drag_block), pt(self.cursor_at), pt(self.move_at), tostring(self.settling),
                            GV.QT_PAINT and table.concat({self.m11, self.hval, self.vval, self.vw, self.vh}, ",") or ""},
                           "|")
  if self.img and key == self.state_key then return self.img end
  self.state_key, self.state_at = key, now
  local list = self:commands()
  local cmds = table.concat(list, "\n")
  if self.img and cmds == self.img_key then return self.img end
  if not GV.QT_PAINT then                       -- (the game draws them: ui/painter.lua)
    self.img = {steps = require("conjunction.ui.painter").compile(list)}
    self.img_key, self.last_paint = cmds, now
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
  self.img_key, self.last_paint = cmds, now
  return self.img
end

-- --- the mouse (GraphView's events: press, move, release, the context menu on the right button's release, a double
-- click on the second press)
function GV:mouse(r, hovered)
  local mx, my, wheel = w3.ui.mouse()
  local ax, ay = math.floor(mx - r.x), math.floor(my - r.y)
  local x, y = self:to_scene(ax, ay)
  local on = self.on
  local g = self.graph
  if g == nil then return end
  if hovered and wheel and wheel ~= 0 and not self.press then
    for _ = 1, math.max(1, math.floor(math.abs(wheel) + 0.5)) do self:wheel(wheel > 0 and 1 or -1, ax, ay) end
    x, y = self:to_scene(ax, ay)
  end
  -- a double click (the second press): a node opens, the empty graph is shown whole
  if hovered and w3.ui.mouse_double(1) then
    self.press, self.drag, self.drop, self.cursor_at = nil, nil, nil, nil
    self.swallow = true
    local n = self:node_at(x, y)
    if n ~= nil then
      if on.opened then on.opened(n.id) end
    else
      self:home()
    end
    return
  end
  if hovered and (w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(3)) then
    self.fresh = false
    if w3.ui.mouse_clicked(3) then
      self.press = {"pan", nil, ax, ay, button = 3}
    else
      local plus = self:plus_at(x, y)
      local port = plus == nil and self:port_at(x, y) or nil
      local inp = (plus == nil and port == nil) and self:input_at(x, y) or nil
      if plus ~= nil then
        self.press = {"plus", plus, ax, ay}
      elseif port ~= nil then
        self.press = {"port", port, ax, ay}
      elseif inp ~= nil and #self:links_into(inp) > 0 then
        self.press = {"input", inp, ax, ay}
      else
        local n = self:node_at(x, y)
        if n ~= nil then
          local tr = n.title_rect
          local lx, ly = x - n.x, y - n.y
          local title = tr ~= nil and lx >= tr[1] and lx <= tr[1] + tr[3] and ly >= tr[2] and ly <= tr[2] + tr[4]
          self.press = {title and "title" or "node", n.id, ax, ay, ox = lx, oy = ly}
        else
          local w = self:wire_at(x, y)
          if w ~= nil then self.press = {"wire", w.link, ax, ay} else self.press = {"pan", nil, ax, ay} end
        end
      end
    end
  end
  local down = w3.ui.mouse_down(1) or w3.ui.mouse_down(3)
  if self.press and down then
    if not self.drag and math.abs(ax - self.press[3]) + math.abs(ay - self.press[4]) >= GV.MOVE_PX then
      local what, data = self.press[1], self.press[2]
      if what == "pan" then
        self.drag = {"pan", ax, ay}
      elseif what == "port" then
        self.drag = {"wire", data[1], data[2]}
      elseif what == "plus" then
        self.drag = {"wire", data[1], data[2], true}        -- (beside the wire there: both run)
      elseif what == "input" then
        local ins = self:links_into(data)
        self.drag = {"rewire", ins[#ins]}
      elseif what == "node" or what == "title" then
        self.drag = {"move", data, self.press.ox, self.press.oy}
      end
    end
    if self.drag then
      local kind = self.drag[1]
      if kind == "pan" then
        local ddx, ddy = ax - self.drag[2], ay - self.drag[3]
        self.drag[2], self.drag[3] = ax, ay
        self:set_h(self.hval - ddx)
        self:set_v(self.vval - ddy)
        return
      end
      self.cursor_at = {x, y}
      if kind == "move" then
        self.move_at = {x - self.drag[3], y - self.drag[4]}
      else
        local n = self:node_at(x, y)
        self.drop = (n ~= nil and n.kind ~= "start") and n.id or nil
      end
      return
    end
  end
  if self.press and not down then
    local press, drag, drop = self.press, self.drag, self.drop
    local move_at = self.move_at
    self.press, self.drag, self.drop, self.cursor_at, self.move_at = nil, nil, nil, nil, nil
    if drag then
      local kind = drag[1]
      if kind == "move" then
        local n = g.nodes[drag[2]]
        local NUM = require("conjunction.pynum")       -- (Python's round: halves to even)
        local nx, ny = NUM.round0(move_at[1] / L.GRID) * L.GRID, NUM.round0(move_at[2] / L.GRID) * L.GRID
        if nx ~= n.x or ny ~= n.y then
          -- (where it was let go until the graph is built anew - the next frame; drawn at its old place for that
          -- frame it jumped back and forth, 13.11. - its wires, still the old ones, hidden till then)
          n.x, n.y = nx, ny
          if on.moved then
            self.settling = drag[2]
            on.moved(drag[2], math.tointeger(nx) or nx, math.tointeger(ny) or ny)
          end
        end
      elseif kind == "wire" then
        if drop ~= nil and on.connect then
          local _, shift = w3.ui.mods()
          on.connect(drag[2], self:output_name(drag[2], drag[3]), drop, shift == true or drag[4] == true)
        end
      elseif kind == "rewire" then
        if drop ~= nil then
          if on.relink then on.relink(drag[2], drop) end
        elseif on.unlink then
          on.unlink(drag[2])
        end
      end
      return
    end
    local what, data = press[1], press[2]
    if what == "title" then
      local n = g.nodes[data]
      if on.picked then on.picked(data) end
      local sx, sy = self:from_scene(n.x + 10, n.y + L.HEAD)
      if on.kind_menu then on.kind_menu(data, r.x + sx, r.y + sy) end
    elseif what == "node" or what == "port" or what == "input" or what == "plus" then
      self:select_wire(nil)
      if on.picked then on.picked((what == "node" or what == "input") and data or data[1]) end
    elseif what == "wire" then
      self:select_wire(data)
    elseif what == "pan" then
      self:select_wire(nil)
    end
    return
  end
  -- the right button let go: the menu of the node or the wire under it
  if hovered and w3.ui.mouse_released and w3.ui.mouse_released(2) then
    local n = self:node_at(x, y)
    if n ~= nil then
      if on.picked then on.picked(n.id) end
      if on.node_menu then on.node_menu(n.id, mx, my) end
    else
      local w = self:wire_at(x, y)
      if w ~= nil then
        self:select_wire(w.link)
        if on.wire_menu then on.wire_menu(w.link, mx, my) end
      end
    end
  end
  -- not dragging: what is under the mouse (the port's handle, the node and its kind)
  if not self.drag then
    local hp = hovered and self:port_at(x, y) or nil
    self.hot_port = hp
    self.hot_plus = hovered and self:plus_at(x, y) or nil
    local hn, ht = nil, false
    if hovered then
      local ids = {}
      for id in pairs(g.nodes) do ids[#ids + 1] = id end
      for i = #ids, 1, -1 do
        local n = g.nodes[ids[i]]
        local bx, by, bw, bh = self:bounding(n)
        if x >= bx and x <= bx + bw and y >= by and y <= by + bh then
          hn = n.id
          local tr = n.title_rect
          local lx, ly = x - n.x, y - n.y
          ht = tr ~= nil and lx >= tr[1] and lx <= tr[1] + tr[3] and ly >= tr[2] and ly <= tr[2] + tr[4]
          break
        end
      end
    end
    self.hot_node, self.hot_title = hn, ht
  end
end

-- one frame in r: the size, the mouse, the picture
function GV:frame(r, hovered)
  self:resize(math.floor(r.w), math.floor(r.h))
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
  self:agent_areas(r)
end

-- the scene drawn by the game (ui/painter.lua): the background, its dots on a 20 px grid (from 0.4 zoom on), the
-- steps with the view's zoom and scroll
function GV:draw_scene(steps, r)
  local s = self.m11
  local sx, sy = self:scroll()
  D.fill(r.x, r.y, r.w, r.h, (tonumber(GV.SURFACE:sub(2), 16) << 8) | 0xff)
  if s >= 0.4 then
    local c = (tonumber(GV.DOT:sub(2), 16) << 8) | 0xff
    local gap = 20
    local l, t = sx / s, sy / s
    local rr, bb = (sx + r.w) / s, (sy + r.h) / s
    local d = math.max(1, 2.2 * s)
    local y = math.floor(t / gap) * gap
    D.clip(r.x, r.y, r.w, r.h, function()
      while y < bb do
        local x = math.floor(l / gap) * gap
        local py = r.y + y * s - sy - d / 2
        while x < rr do
          D.fill(r.x + x * s - sx - d / 2, py, d, d, c)
          x = x + gap
        end
        y = y + gap
      end
    end)
  end
  require("conjunction.ui.painter").draw(steps, r.x, r.y, r.w, r.h, {s, sx, sy})
end

-- The picked one's breath (its outline glows from 50 to 160 and back, the app's QTimer 60 ms): the picture keeps the
-- glow at its least and is not made anew for it - the rest is drawn over it here each frame, the outer half of the
-- glow's 6 px along the shape (24.10.: the picture made anew every 60 ms took 22 ms of each frame, the game ran at
-- 30 fps with the quest window open). -> the shapes that breathe: {flat scene points}
function GV:breathing()
  local g = self.graph
  if not (g and self.chosen ~= nil) then return {} end
  for _, n in pairs(g.nodes) do
    if n.id == self.chosen then
      local px, py = self:item_pos(n)
      local pts = GV.shape(n, {0.5, 0.5, n.w - 1, n.h - 1})
      for i = 1, #pts, 2 do pts[i], pts[i + 1] = pts[i] + px, pts[i + 1] + py end
      return {pts}
    end
  end
  return {}
end
-- a convex outline moved out by d (mitred corners; repeated points left out)
function GV.outset(pts, d)
  local p = {}
  for i = 1, #pts, 2 do
    local q = p[#p]
    if not q or math.abs(q[1] - pts[i]) > 1e-6 or math.abs(q[2] - pts[i + 1]) > 1e-6 then p[#p + 1] = {pts[i], pts[i + 1]} end
  end
  if #p > 2 and math.abs(p[1][1] - p[#p][1]) < 1e-6 and math.abs(p[1][2] - p[#p][2]) < 1e-6 then p[#p] = nil end
  local n = #p
  if n < 3 then return {} end
  local area = 0
  for i = 1, n do local a, b = p[i], p[i % n + 1] area = area + a[1] * b[2] - b[1] * a[2] end
  local s = area > 0 and 1 or -1
  local function normal(a, b)
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l = math.sqrt(dx * dx + dy * dy)
    return s * dy / l, -s * dx / l
  end
  local out = {}
  for i = 1, n do
    local a, b, c = p[(i - 2) % n + 1], p[i], p[i % n + 1]
    local n1x, n1y = normal(a, b)
    local n2x, n2y = normal(b, c)
    local mx, my = n1x + n2x, n1y + n2y
    local ml = math.sqrt(mx * mx + my * my)
    if ml < 1e-6 then mx, my, ml = n1x, n1y, 1 end
    mx, my = mx / ml, my / ml
    local k = d / math.max(0.2, mx * n1x + my * n1y)
    out[#out + 1] = b[1] + mx * k
    out[#out + 1] = b[2] + my * k
  end
  return out
end
function GV:draw_breath(r)
  local shapes = self:breathing()
  if #shapes == 0 then return end
  -- (over the glow of 50 already in the picture: together 50 + 110 * pulse, as the app's)
  local a = math.floor(137 * GV.pulse(w3.time()))
  if a <= 0 then return end
  local c = (tonumber(GV.PICKED:sub(2), 16) << 8) | a
  local s = self.m11
  D.clip(r.x, r.y, r.w, r.h, function()
    for _, pts in ipairs(shapes) do
      local o = GV.outset(pts, 1.5)
      for i = 1, #o, 2 do
        local x, y = self:from_scene(o[i], o[i + 1])
        o[i], o[i + 1] = r.x + x, r.y + y
      end
      if #o >= 6 then D.poly(o, c, 3 * s, true) end
    end
  end)
end

-- the nodes in view as the agent sees them (agent.py read the tiles' accessibleName): a node clicked by its title
function GV:agent_areas(r)
  local AG = package.loaded["conjunction.agent"]
  if not (AG and self.graph and self.graph.nodes) then return end
  for nid, n in pairs(self.graph.nodes) do
    if n.x and n.w then
      local x1, y1 = self:from_scene(n.x, n.y)
      local x2, y2 = self:from_scene(n.x + n.w, n.y + n.h)
      if x2 > 0 and y2 > 0 and x1 < r.w and y1 < r.h then
        AG.area("graph.node." .. tostring(nid), r.x + x1, r.y + y1, x2 - x1, y2 - y1, n.title or n.text)
      end
    end
  end
end

function GV:free()
  if self.img and self.img[1] then w3.ui.image_free(self.img[1]) end
  self.img, self.img_key = nil, nil
end

return GV
