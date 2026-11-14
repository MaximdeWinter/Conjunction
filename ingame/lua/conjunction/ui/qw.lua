-- Qt's widgets and box layouts as a tree, laid out as Qt lays them out (qboxlayout.cpp setupGeom / setGeometry,
-- qlayoutitem.cpp QWidgetItem, qlayout.cpp totalSizeHint), for windows built the way the app builds them: a QWidget
-- with a QVBoxLayout of rows, each a QWidget with an QHBoxLayout ... The tree is made anew each frame (it holds no
-- state: the controls keep theirs by id), laid out for the width it gets, then drawn.
--
--   local W = require("conjunction.ui.qw")
--   local row = W.widget(W.hbox({spacing = 6}, {W.field("radius"), spin, W.stretch()}))
--   local w, h = W.hint(row)        -- sizeHint;  W.min(row) minimumSizeHint
--   W.place(row, x, y, w, h)        -- every node's rectangle (node.r)
--   W.draw(row)                     -- each node's draw(node, r), parents first
--
-- A leaf: W.leaf{w = hint, h = hint, min_w, min_h (minimumSizeHint), hpol, vpol ("fixed", "minimum", "maximum",
-- "preferred", "expanding" ...), fixed_w, fixed_h, max_w, max_h, hfw = fn(width) -> height, draw = fn(node, r),
-- hidden}. In a box: node.stretch (addWidget's stretch), node.align ("left", "right", "hcenter", "top", "bottom",
-- "vcenter", "center" or a set {left = true, vcenter = true}).
local L = require("conjunction.ui.layout")
local W = {}
local BIG = L.BIG

-- --- leaves (QWidgetItem over a widget)
function W.leaf(o)
  -- (minimumSizeHint: the size hint unless told otherwise - a label's, a button's; a line edit says its own)
  if o.min_w == nil then o.min_w = o.w end
  if o.min_h == nil then o.min_h = o.h end
  local n = {kind = "leaf", o = o, draw_fn = o.draw, hidden = o.hidden}
  return n
end

-- a container widget: a QWidget (or QFrame) with its layout; o: margins (its contents margins - a frame's border),
-- hpol, vpol (preferred), draw (its own painting under the children), after (once the children are drawn), hidden
function W.widget(layout, o)
  o = o or {}
  return {kind = "widget", layout = layout, o = o, draw_fn = o.draw, after_fn = o.after, hidden = o.hidden}
end

-- QHBoxLayout / QVBoxLayout: o.margins {l, t, r, b}, o.spacing
function W.hbox(o, items) return {kind = "box", dir = "h", o = o or {}, items = items or {}} end
function W.vbox(o, items) return {kind = "box", dir = "v", o = o or {}, items = items or {}} end
-- catalog_view.Flow: widgets in rows that wrap (gap apart); its hint and minimum the largest item's minimum
function W.flow(o, items) return {kind = "flow", o = o or {}, items = items or {}} end
-- Flow._do: the items at their hints, a new row where the next would pass the right edge (QRect.right(): x + w - 1)
local function flow_do(n, x0, y0, w, test)
  local gap = n.o.spacing or 4
  local x, y, line = x0, y0, 0
  local right = x0 + w - 1
  for _, it in ipairs(n.items) do
    if not it.hidden then
      local hw, hh = W.hint(it)
      if x + hw > right and line > 0 then x, y, line = x0, y + line + gap, 0 end
      if not test then W._place_at(it, x, y, hw, hh) end
      x = x + hw + gap
      line = math.max(line, hh)
    end
  end
  return y + line - y0
end

-- addStretch(n): an empty QSpacerItem that takes what is left (no spacing round it)
function W.stretch(n) return {kind = "spacer", stretch = n or 1, size = 0} end
-- addSpacing(px)
function W.spacing(px) return {kind = "spacer", stretch = 0, size = px, fixed = true} end

local function aligned(node)
  local a = node.align
  if a == nil then return {} end
  if type(a) == "table" then return a end
  local out = {}
  if a == "center" then out.hcenter, out.vcenter = true, true else out[a] = true end
  return out
end
local function h_aligned(al) return al.left or al.right or al.hcenter end
local function v_aligned(al) return al.top or al.bottom or al.vcenter end

-- the leaf's QWidgetItem sizes: {w = {hint, min, max, expanding, least}, h = {...}} (L.widget)
local function leaf_axes(n)
  if n._axes then return n._axes end
  local o = n.o
  n._axes = L.widget(o.w or 0, o.h or 0, o.hpol, o.vpol, {min_w = o.min_w, min_h = o.min_h, fixed_w = o.fixed_w,
                                                          fixed_h = o.fixed_h, max_w = o.max_w, max_h = o.max_h})
  return n._axes
end

local item_sizes

-- QBoxLayoutPrivate::setupGeom: the box's hint, minimum, maximum, expanding directions (its margins in)
local function box_geom(b)
  if b._geom then return b._geom end
  local horz = b.dir == "h"
  local maxw = horz and 0 or BIG
  local maxh = horz and BIG or 0
  local minw, minh, hintw, hinth = 0, 0, 0, 0
  local horexp, verexp = false, false
  local prev = nil
  local fixed = b.o.spacing or 6
  local chain = {}
  local has_hfw = false
  for i, it in ipairs(b.items) do
    local s = item_sizes(it)
    local empty = s.empty
    local spacing = 0
    if not empty then
      spacing = prev and fixed or 0
      if prev then chain[prev].spacing = spacing end
      prev = i
    end
    local ignore = empty and (it.kind == "leaf" or it.kind == "widget")
    local dummy = true
    local function maxexp(maxv, exp, boxmax, boxexp, boxempty)
      -- qMaxExpCalc
      if exp then
        if boxexp then maxv = math.max(maxv, boxmax) end
      else
        if boxexp or (dummy and (not boxempty or maxv == 0)) then maxv = boxmax
        elseif dummy == boxempty then maxv = math.min(maxv, boxmax) end
      end
      dummy = dummy and boxempty
      return maxv, exp or boxexp
    end
    local stretch = it.stretch or 0
    if horz then
      local expand = s.hexp or stretch > 0
      horexp = horexp or expand
      maxw = maxw + spacing + s.max_w
      minw = minw + spacing + s.min_w
      hintw = hintw + spacing + s.w
      if not ignore then maxh, verexp = maxexp(maxh, verexp, s.max_h, s.vexp, empty) end
      minh = math.max(minh, s.min_h)
      hinth = math.max(hinth, s.h)
      chain[i] = {hint = s.w, min = s.min_w, max = s.max_w, expanding = expand, stretch = stretch, empty = empty}
    else
      local expand = s.vexp or stretch > 0
      verexp = verexp or expand
      maxh = maxh + spacing + s.max_h
      minh = minh + spacing + s.min_h
      hinth = hinth + spacing + s.h
      if not ignore then maxw, horexp = maxexp(maxw, horexp, s.max_w, s.hexp, empty) end
      minw = math.max(minw, s.min_w)
      hintw = math.max(hintw, s.w)
      chain[i] = {hint = s.h, min = s.min_h, max = s.max_h, expanding = expand, stretch = stretch, empty = empty}
    end
    has_hfw = has_hfw or s.hfw ~= nil
  end
  maxw, maxh = math.min(maxw, BIG), math.min(maxh, BIG)
  maxw, maxh = math.max(maxw, minw), math.max(maxh, minh)                       -- (expandedTo(minSize))
  hintw = math.min(math.max(hintw, minw), maxw)
  hinth = math.min(math.max(hinth, minh), maxh)
  local m = b.o.margins or {0, 0, 0, 0}
  local ex, ey = m[1] + m[3], m[2] + m[4]
  b._geom = {w = hintw + ex, h = hinth + ey, min_w = minw + ex, min_h = minh + ey,
             max_w = math.min(BIG, maxw + ex), max_h = math.min(BIG, maxh + ey), hexp = horexp, vexp = verexp,
             chain = chain, has_hfw = has_hfw}
  return b._geom
end

-- QBoxLayout::heightForWidth(w): a vertical box adds its items' heights for that width; a row, the most
local function box_hfw(b, w)
  local g = box_geom(b)
  local m = b.o.margins or {0, 0, 0, 0}
  local inner = w - m[1] - m[3]
  local h = 0
  if b.dir == "h" then
    local items = {}
    for i, it in ipairs(b.items) do items[i] = g.chain[i] end
    local placed = L.row(items, 0, 0, inner, 0, {spacing = b.o.spacing or 6})
    for i, it in ipairs(b.items) do
      local s = item_sizes(it)
      local hh = s.hfw and s.hfw(placed[i].w) or s.h
      if not s.empty then h = math.max(h, hh) end
    end
  else
    for i, it in ipairs(b.items) do
      local s = item_sizes(it)
      local hh = s.hfw and s.hfw(inner) or s.h
      h = h + hh + (g.chain[i].spacing or 0)
    end
  end
  return h + m[2] + m[4]
end

-- the sizes of an item as its layout sees it: {w, h, min_w, min_h, max_w, max_h, hexp, vexp, empty, hfw}
item_sizes = function(it)
  if it._sizes then return it._sizes end
  local s
  if it.kind == "spacer" then
    -- QSpacerItem: (size, 0) or (0, size), the box's direction expanding (a stretch) or fixed (a spacing)
    s = {w = it.size, h = it.size, min_w = it.fixed and it.size or 0, min_h = it.fixed and it.size or 0,
         max_w = it.fixed and it.size or BIG, max_h = it.fixed and it.size or BIG, hexp = not it.fixed,
         vexp = not it.fixed, empty = true}
  elseif it.kind == "flow" then
    local mw, mh = 0, 0
    for _, x in ipairs(it.items) do
      local cs = item_sizes(x)
      mw, mh = math.max(mw, cs.min_w), math.max(mh, cs.min_h)
    end
    s = {w = mw, h = mh, min_w = mw, min_h = mh, max_w = BIG, max_h = BIG, hexp = true, vexp = true, empty = false,
         hfw = function(w) return flow_do(it, 0, 0, w, true) end}
  elseif it.kind == "box" then
    local g = box_geom(it)
    local empty = true                            -- (QLayout::isEmpty: every item empty)
    for _, x in ipairs(it.items) do if not item_sizes(x).empty then empty = false end end
    s = {w = g.w, h = g.h, min_w = g.min_w, min_h = g.min_h, max_w = g.max_w, max_h = g.max_h, hexp = g.hexp,
         vexp = g.vexp, empty = empty}
    if g.has_hfw then s.hfw = function(w) return box_hfw(it, w) end end
  elseif it.kind == "widget" then
    -- QWidget with a layout: its hint and minimum the layout's (and its contents margins), Preferred both ways
    -- (its layout as a layout item: a box's setupGeom, a flow's own sizes)
    local ls = item_sizes(it.layout)
    local g = {w = ls.w, h = ls.h, min_w = ls.min_w, min_h = ls.min_h, hexp = ls.hexp, vexp = ls.vexp,
               has_hfw = ls.hfw ~= nil}
    local cm = it.o.margins or {0, 0, 0, 0}
    local ex, ey = cm[1] + cm[3], cm[2] + cm[4]
    local o = it.o
    local hint_h = g.h + ey
    if g.has_hfw then hint_h = ls.hfw(g.w) + ey end
    local ax = L.widget(g.w + ex, hint_h, o.hpol or "preferred", o.vpol or "preferred",
                        {min_w = g.min_w + ex, min_h = g.min_h + ey, fixed_w = o.fixed_w, fixed_h = o.fixed_h,
                         max_w = o.max_w, max_h = o.max_h})
    s = {w = ax.w.hint, h = ax.h.hint, min_w = ax.w.min, min_h = ax.h.min, max_w = ax.w.max, max_h = ax.h.max,
         hexp = ax.w.expanding or (ax.w.max > ax.w.hint and g.hexp),
         vexp = ax.h.expanding or (ax.h.max > ax.h.hint and g.vexp), empty = it.hidden == true}
    if g.has_hfw then s.hfw = function(w) return ls.hfw(w - ex) + ey end end
  else
    local ax = leaf_axes(it)
    s = {w = ax.w.hint, h = ax.h.hint, min_w = ax.w.min, min_h = ax.h.min, max_w = ax.w.max, max_h = ax.h.max,
         hexp = ax.w.expanding, vexp = ax.h.expanding, empty = it.hidden == true, hfw = it.o.hfw}
  end
  -- a hidden widget takes no room (QWidgetItem: isEmpty, its sizeHint and minimumSize 0 x 0)
  if it.hidden == true and (it.kind == "leaf" or it.kind == "widget") then
    s.w, s.h, s.min_w, s.min_h, s.hfw = 0, 0, 0, 0, nil
  end
  -- an alignment: the item may be as big as the box gives (it is put inside), and not expanding that way
  local al = aligned(it)
  if it.kind ~= "spacer" and it.kind ~= "box" then
    if h_aligned(al) then s.max_w, s.hexp = BIG, false end
    if v_aligned(al) then s.max_h, s.vexp = BIG, false end
  end
  it._sizes = s
  return s
end

function W.hint(n) local s = item_sizes(n) return s.w, s.h end
function W.min(n) local s = item_sizes(n) return s.min_w, s.min_h end
function W.max(n) local s = item_sizes(n) return s.max_w, s.max_h end
function W.hfw(n, w) local s = item_sizes(n) return s.hfw and s.hfw(w) or s.h end

local place

-- QWidgetItem::setGeometry: no bigger than its maximum; aligned within, else in the middle of what it got
local function place_widget_item(it, x, y, w, h)
  local s = item_sizes(it)
  local al = aligned(it)
  local sw, sh = math.min(w, s.max_w), math.min(h, s.max_h)
  if it.kind == "leaf" then
    local ax = leaf_axes(it)
    sw, sh = math.min(w, ax.w.max), math.min(h, ax.h.max)
    if h_aligned(al) then sw = math.min(sw, ax.w.hint) end
    if v_aligned(al) then
      if it.o.hfw then sh = math.min(sh, it.o.hfw(sw)) else sh = math.min(sh, ax.h.hint) end
    end
  elseif h_aligned(al) or v_aligned(al) then
    local g = item_sizes({kind = it.kind, layout = it.layout, o = it.o})
    if h_aligned(al) then sw = math.min(sw, g.w) end
    if v_aligned(al) then sh = math.min(sh, g.hfw and g.hfw(sw) or g.h) end
  end
  local px, py = x, y
  if al.right then px = x + (w - sw) elseif not al.left then px = x + (w - sw) // 2 end
  if al.bottom then py = y + (h - sh) elseif not al.top then py = y + (h - sh) // 2 end
  it.r = {x = px, y = py, w = sw, h = sh}
  if it.kind == "widget" then
    local cm = it.o.margins or {0, 0, 0, 0}
    place(it.layout, px + cm[1], py + cm[2], sw - cm[1] - cm[3], sh - cm[2] - cm[4])
  end
end

-- QBoxLayout::setGeometry: inside its margins, qGeomCalc along, each item its slot
place = function(n, x, y, w, h)
  if n.kind == "spacer" then n.r = {x = x, y = y, w = w, h = h} return end
  if n.kind == "flow" then
    n.r = {x = x, y = y, w = w, h = h}
    flow_do(n, x, y, w, false)
    return
  end
  if n.kind ~= "box" then place_widget_item(n, x, y, w, h) return end
  n.r = {x = x, y = y, w = w, h = h}
  local g = box_geom(n)
  local m = n.o.margins or {0, 0, 0, 0}
  local ix, iy, iw, ih = x + m[1], y + m[2], w - m[1] - m[3], h - m[2] - m[4]
  local items = {}
  for i, it in ipairs(n.items) do
    local c = g.chain[i]
    items[i] = {hint = c.hint, min = c.min, max = c.max, expanding = c.expanding, stretch = c.stretch, empty = c.empty}
    if n.dir == "v" and g.has_hfw then
      local s = item_sizes(it)
      if s.hfw then
        local width = math.max(s.min_w, math.min(iw, s.max_w))
        local hh = s.hfw(width)
        items[i].hint, items[i].min = hh, hh
      end
    end
  end
  local placed
  local o = {spacing = n.o.spacing or 6}
  if n.dir == "h" then placed = L.row(items, ix, iy, iw, ih, o) else placed = L.column(items, ix, iy, iw, ih, o) end
  for i, it in ipairs(n.items) do
    local p = placed[i]
    if n.dir == "h" then place(it, p.x, iy, p.w, ih) else place(it, ix, p.y, iw, p.h) end
  end
end

function W.place(n, x, y, w, h) place(n, x, y, w, h) end
W._place_at = function(n, x, y, w, h) place(n, x, y, w, h) end

-- every node drawn, parents first (a node's draw(node, r))
function W.draw(n)
  if n.hidden then return end
  if n.kind == "leaf" or n.kind == "widget" then
    if n.draw_fn and n.r then n.draw_fn(n, n.r) end
    if n.kind == "widget" then
      W.draw(n.layout)
      if n.after_fn and n.r then n.after_fn(n, n.r) end
    end
  elseif n.kind == "box" or n.kind == "flow" then
    for _, it in ipairs(n.items) do W.draw(it) end
  end
end

-- every node with a rectangle, in the tree's order (for checks against Qt's geometry)
function W.walk(n, fn)
  if n.kind == "leaf" or n.kind == "widget" then fn(n) end
  if n.kind == "widget" then W.walk(n.layout, fn) end
  if n.kind == "box" or n.kind == "flow" then for _, it in ipairs(n.items) do W.walk(it, fn) end end
end

return W
