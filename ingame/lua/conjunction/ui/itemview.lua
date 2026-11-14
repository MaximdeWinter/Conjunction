-- Qt's item views as the app's lists behave (Qt 6.11 qlistview.cpp, qtreeview.cpp, qabstractslider.cpp): the scroll
-- bars' wheel (QAbstractSlider::scrollByDelta), QListView's layouts and cursor moves (IconMode: QIconModeViewBase,
-- ListMode: QListModeViewBase's static layout), QTreeView's rows of one height (ScrollPerItem), scrollTo.
-- Rectangles are Qt's: {l, t, r, b} with the right and the bottom inside (QRect).
--   local bar = IV.bar()                         a scroll bar: value, single, page, max, acc (the wheel's remainder)
--   IV.wheel(bar, notches, lines)               a wheel turn (notches: delta / 120, up > 0) -> changed
--   IV.icon_layout(n, tw, th, sp, vw)           -> G (QIconModeViewBase::doDynamicLayout, LeftToRight, wrapping)
--   IV.list_layout(n, tw, th, sp, bounds_h)     -> G (QListModeViewBase::doStaticLayout, TopToBottom, wrapping)
--   IV.move(G, action, cur, area)               QListView::moveCursor ("up", "down", "left", "right", "home", "end",
--                                               "pageup", "pagedown") -> the new current (1-based)
--   IV.tree_move(n, action, cur, top, area_h, row_h)   QTreeView::moveCursor for rows of one height
local IV = {}

-- --- QRect ---
local function rect(l, t, w, h) return {l, t, l + w - 1, t + h - 1} end
IV.rect = rect
local function copy(r) return {r[1], r[2], r[3], r[4]} end
local function width(r) return r[3] - r[1] + 1 end
local function height(r) return r[4] - r[2] + 1 end
local function translate(r, dx, dy) r[1], r[2], r[3], r[4] = r[1] + dx, r[2] + dy, r[3] + dx, r[4] + dy end
local function move_top(r, t) r[4] = t + (r[4] - r[2]) r[2] = t end
local function is_empty(r) return r[1] > r[3] or r[2] > r[4] end
local function is_null(r) return r[3] == r[1] - 1 and r[4] == r[2] - 1 end
-- QRect::center: (x1 + x2) / 2 in 64 bits, C's division
local function cdiv(a, b) local q = a // b if q < 0 and q * b ~= a then q = q + 1 end return q end
IV.cdiv = cdiv
local function center(r) return cdiv(r[1] + r[3], 2), cdiv(r[2] + r[4], 2) end
function IV.intersects(a, b)
  if is_null(a) or is_null(b) then return false end
  local l1, r1 = a[1], a[1]
  if a[3] - a[1] + 1 < 0 then l1 = a[3] else r1 = a[3] end
  local l2, r2 = b[1], b[1]
  if b[3] - b[1] + 1 < 0 then l2 = b[3] else r2 = b[3] end
  if l1 > r2 or l2 > r1 then return false end
  local t1, b1 = a[2], a[2]
  if a[4] - a[2] + 1 < 0 then t1 = a[4] else b1 = a[4] end
  local t2, b2 = b[2], b[2]
  if b[4] - b[2] + 1 < 0 then t2 = b[4] else b2 = b[4] end
  if t1 > b2 or t2 > b1 then return false end
  return true
end
-- QRect::contains(QRect) (not proper): all of r inside a
function IV.contains(a, r)
  if is_null(a) or is_null(r) then return false end
  return r[1] >= a[1] and r[3] <= a[3] and r[2] >= a[2] and r[4] <= a[4]
end

-- --- the scroll bar ---
function IV.bar(single, page, max)
  return {value = 0, single = single or 1, page = page or 0, max = max or 0, acc = 0.0}
end
local function trunc(x) return x >= 0 and math.floor(x) or -math.floor(-x) end
-- QAbstractSlider::setValue / setRange: bounded; -> changed
function IV.set(bar, v)
  v = math.max(0, math.min(bar.max, v))
  if v == bar.value then return false end
  bar.value = v
  return true
end
function IV.range(bar, max)
  bar.max = math.max(0, max)
  return IV.set(bar, bar.value)
end
-- QAbstractSliderPrivate::scrollByDelta, a QScrollBar (inverted controls): the wheel's lines (Windows' setting, 3) a
-- notch, the remainder kept for the next turn, never more than a page; -> changed
function IV.wheel(bar, notches, lines)
  local offset = notches
  local steps_f = (lines or 3) * offset * bar.single
  if bar.acc ~= 0 and offset / bar.acc < 0 then bar.acc = 0.0 end
  bar.acc = bar.acc + steps_f
  local steps = math.max(-bar.page, math.min(bar.page, trunc(bar.acc)))
  bar.acc = bar.acc - trunc(bar.acc)
  if steps == 0 then
    local eff = -bar.acc
    if eff > 0 and bar.value < bar.max then return false end
    if eff < 0 and bar.value > 0 then return false end
    bar.acc = 0.0
    return false
  end
  local before = bar.value
  IV.set(bar, bar.value - steps)
  if before == bar.value then bar.acc = 0.0 return false end
  return true
end

-- --- QListView, IconMode (Static movement, LeftToRight, wrapping): doDynamicLayout ---
-- vw: the layout's width (the viewport less the bar it may need). -> G: items (contents rectangles), cw, ch
function IV.icon_layout(n, tw, th, sp, vw)
  local right = vw - 1
  local seg_start = sp
  local flow, seg = sp, sp
  local delta_seg = 0
  local items = {}
  local maxr, maxb = 0, 0
  for i = 1, n do
    local delta = tw + sp
    if flow + delta > right and flow > seg_start then
      flow = seg_start
      seg = seg + delta_seg
      delta_seg = 0
    end
    delta_seg = math.max(delta_seg, th + sp)
    items[i] = rect(flow, seg, tw, th)
    maxr = math.max(maxr, flow + tw)
    maxb = math.max(maxb, seg + th)
    flow = flow + delta
  end
  -- (contentsSize: the items' union and the spacing)
  return {kind = "icon", ltr = true, n = n, items = items, sp = sp, cw = maxr + sp, ch = maxb + sp, tw = tw, th = th}
end

-- --- QListView, ListMode (TopToBottom, wrapping): doStaticLayout, all batches as one ---
-- bounds_h: the layout's height (the viewport less the sideways bar). The items as wide as their column.
function IV.list_layout(n, tw, th, sp, bounds_h)
  local seg_end = bounds_h
  local flow, seg = sp, sp
  local delta_seg = 0
  local seg_pos, seg_rows, seg_ext, flow_pos = {sp}, {1}, {}, {}
  for row = 1, n do
    local delta_flow, hint = th + sp, tw + sp
    if flow + delta_flow >= seg_end then
      seg_ext[#seg_ext + 1] = flow
      flow = sp
      seg = seg + sp + delta_seg
      seg_pos[#seg_pos + 1] = seg
      seg_rows[#seg_rows + 1] = row
      delta_seg = 0
    end
    flow_pos[row] = flow
    delta_seg = math.max(hint, delta_seg)
    flow = flow + sp + delta_flow
  end
  flow = flow - sp
  local cw = seg + delta_seg
  local ch = #seg_pos == 1 and flow or bounds_h - 1
  seg_ext[#seg_ext + 1] = flow
  flow_pos[n + 1] = flow
  seg_pos[#seg_pos + 1] = seg + delta_seg               -- (the last column's edge)
  local G = {kind = "list", ltr = false, n = n, sp = sp, cw = cw, ch = ch, seg_pos = seg_pos, seg_rows = seg_rows,
             seg_ext = seg_ext, flow_pos = flow_pos, tw = tw, th = th, items = {}}
  local s = 1
  for row = 1, n do
    while s < #seg_rows and seg_rows[s + 1] <= row do s = s + 1 end
    local x = seg_pos[s]
    G.items[row] = rect(x, flow_pos[row], seg_pos[s + 1] - x, th)
    G.items[row].seg = s
  end
  return G
end

-- qBinarySearch (qlistview.cpp): the last i in [first, last] with v[i] <= item
local function bsearch(v, item, first, last)
  local i = (first + last + 1) >> 1
  while last - first > 0 do
    if v[i] > item then last = i - 1 else first = i end
    i = (first + last + 1) >> 1
  end
  return i
end
IV.bsearch = bsearch

-- the items an area touches (QIconModeViewBase's BSP tree: the rectangles; QListModeViewBase: by columns, an item
-- reaching to the next one's start)
function IV.intersecting(G, area)
  local out = {}
  if G.kind == "icon" then
    for i = 1, G.n do if IV.intersects(G.items[i], area) then out[#out + 1] = i end end
    return out
  end
  local seg_start, seg_end, flow_start, flow_end = area[1], area[3], area[2], area[4]
  local sp = G.seg_pos
  if #sp < 2 or G.n == 0 then return out end
  local seg_last = #sp - 1
  local seg = bsearch(sp, seg_start, 1, seg_last + 1)
  while seg <= seg_last and sp[seg] <= seg_end do
    local first = G.seg_rows[seg]
    local last = (seg < seg_last and G.seg_rows[seg + 1] or G.n + 1) - 1
    if G.seg_ext[seg] >= flow_start then
      local row = bsearch(G.flow_pos, flow_start, first, last)
      while row <= last and G.flow_pos[row] <= flow_end do
        out[#out + 1] = row
        row = row + 1
      end
    end
    seg = seg + 1
  end
  return out
end

-- QListViewPrivate::closestIndex
local function closest(G, target, list)
  local shortest, best = math.huge, nil
  local tcx, tcy = center(target)
  for _, i in ipairs(list) do
    local r = G.items[i]
    local cx, cy = center(r)
    local d
    if (tcx >= r[1] and tcx < r[3]) or (cx >= target[1] and cx < target[3]) then
      d = math.abs(cy - tcy)
    elseif (tcy >= r[2] and tcy < r[4]) or (cy >= target[2] and cy < target[4]) then
      d = math.abs(cx - tcx)
    else
      d = math.abs(cx - tcx) + math.abs(cy - tcy)
    end
    if d < shortest then shortest, best = d, i end
  end
  return best
end
local function without(list, cur)
  local out = {}
  for _, i in ipairs(list) do if i ~= cur then out[#out + 1] = i end end
  return out
end

-- QListView::moveCursor (vh: the viewport's height). cur nil: the first item
function IV.move(G, action, cur, vh)
  local n = G.n
  if n == 0 then return nil end
  if not cur then return 1 end
  if (G.ltr and action == "left") or (not G.ltr and action == "up") then return cur > 1 and cur - 1 or cur end
  if (G.ltr and action == "right") or (not G.ltr and action == "down") then return cur < n and cur + 1 or cur end
  local initial = G.items[cur]
  local r = copy(initial)
  if is_empty(r) then return 1 end
  local cw, ch = G.cw, G.ch
  local found = {}
  if action == "left" then
    while #found == 0 do
      translate(r, -width(r), 0)
      if r[3] <= 0 then return cur end
      if r[1] < 0 then r[1] = 0 end
      found = without(IV.intersecting(G, r), cur)
    end
    return closest(G, initial, found)
  elseif action == "right" then
    while #found == 0 do
      translate(r, width(r), 0)
      if r[1] >= cw then return cur end
      if r[3] > cw then r[3] = cw end
      found = without(IV.intersecting(G, r), cur)
    end
    return closest(G, initial, found)
  elseif action == "up" then
    while #found == 0 do
      translate(r, 0, -height(r))
      if r[4] <= 0 then return cur end
      if r[2] < 0 then r[2] = 0 end
      found = without(IV.intersecting(G, r), cur)
    end
    return closest(G, initial, found)
  elseif action == "down" then
    while #found == 0 do
      translate(r, 0, height(r))
      if r[2] >= ch then return cur end
      if r[4] > ch then r[4] = ch end
      found = without(IV.intersecting(G, r), cur)
    end
    return closest(G, initial, found)
  elseif action == "pageup" then
    if height(r) >= vh then return IV.move(G, "up", cur, vh) end
    move_top(r, r[2] - vh + 1)
    if r[2] < height(r) then r[2], r[4] = 0, 1 end
    local idx = cur
    while #found == 0 or G.items[idx][2] <= G.items[cur][4] - vh or r[2] <= 0 do
      translate(r, 0, 1)
      if r[4] <= 0 then return cur end
      found = IV.intersecting(G, r)
      idx = closest(G, initial, found)
    end
    return idx
  elseif action == "pagedown" then
    if height(r) >= vh then return IV.move(G, "down", cur, vh) end
    move_top(r, r[2] + vh - 1)
    if r[4] > ch - height(r) then r[2], r[4] = ch - 1, ch end
    local idx = cur
    while #found == 0 or G.items[idx][4] >= vh + G.items[cur][2] or r[4] > ch do
      translate(r, 0, -1)
      if r[2] >= ch then return cur end
      found = IV.intersecting(G, r)
      idx = closest(G, initial, found)
    end
    return idx
  elseif action == "home" then
    return 1
  elseif action == "end" then
    return n
  end
  return cur
end

-- QListView::scrollTo(EnsureVisible): the bars' values that show item i (vbar, hbar: their values now; vw, vh: the
-- viewport) -> v, h
function IV.scroll_to(G, i, vbar, hbar, vw, vh)
  local r = G.items[i]
  local hoff = G.kind == "list" and (G.seg_pos[math.max(0, math.min(hbar.value, #G.seg_pos - 2)) + 1] or 0) or 0
  local vis = {r[1] - hoff, r[2] - vbar.value, r[3] - hoff, r[4] - vbar.value}
  local area = {0, 0, vw - 1, vh - 1}
  if IV.contains(area, vis) then return vbar.value, hbar.value end
  -- vertical (QCommonListViewBase::verticalScrollToValue: the rectangle with its spacing)
  local v = vbar.value
  local sp = G.sp
  if vis[2] < area[2] then v = v + vis[2] - sp
  elseif vis[4] > area[4] then v = v + math.min(vis[2] - sp, vis[4] + sp - vh + 1) end
  local h = hbar.value
  if G.kind == "list" then
    -- (QListModeViewBase::horizontalScrollToValue: by columns)
    local left_of = vis[1] < 0
    local right_of = vis[3] > area[3] and vis[1] > 0
    if left_of or right_of then
      local seg = bsearch(G.seg_rows, i, 1, #G.seg_rows)
      if left_of then
        h = seg - 1
      else
        local extent = width(r) + sp
        local left = seg
        local bottom = G.seg_pos[seg]
        local scroll_value = math.max(0, math.min(hbar.value, G.n))
        while left - 1 > scroll_value and (bottom - G.seg_pos[left - 1] + extent) <= vw do left = left - 1 end
        h = (seg - 1) - (seg - left + 1) + 1
      end
    end
  end
  return v, h
end

-- the item under a viewport point (indexAt), or nil
function IV.at(G, x, y, vbar, hbar)
  local hoff = G.kind == "list" and (G.seg_pos[math.max(0, math.min(hbar.value, #G.seg_pos - 2)) + 1] or 0) or 0
  local cx, cy = x + hoff, y + vbar.value
  local hit = IV.intersecting(G, {cx, cy, cx, cy})
  for _, i in ipairs(hit) do
    local r = G.items[i]
    if cx >= r[1] and cx <= r[3] and cy >= r[2] and cy <= r[4] then return i end
  end
  return nil
end

-- --- QTreeView, rows of one height, ScrollPerItem ---
-- cur 1-based; top: the first row shown (the bar's value, 0-based); area_h: the viewport's height
function IV.tree_move(n, action, cur, top, area_h, row_h)
  if n == 0 then return nil end
  if not cur then return 1 end
  local vi = cur - 1
  local function at(y)                       -- itemAtCoordinate
    if y < 0 then y = y - (row_h - 1) end
    local i = top + cdiv(y, row_h)
    return (i >= n or i < 0) and -1 or i
  end
  local function coord(i) return row_h * (i - top) end
  local r = vi
  if action == "down" then r = math.min(n - 1, vi + 1)
  elseif action == "up" then r = math.max(0, vi - 1)
  elseif action == "pagedown" then
    r = at(coord(vi) + area_h)
    if r == -1 or r >= n then r = n - 1 end
  elseif action == "pageup" then
    r = at(coord(vi) - area_h)
    if r == -1 then r = 0 end
  elseif action == "home" then r = 0
  elseif action == "end" then r = n - 1 end
  return r + 1
end
-- QTreeView::scrollTo(EnsureVisible), ScrollPerItem -> the bar's value
function IV.tree_scroll_to(i, bar, area_h, row_h)
  local item = i - 1
  local top = bar.value
  if item >= top and item < top + bar.page then return top end
  if item < top then return item end
  local y = area_h
  if y > row_h then
    while item >= 0 do
      y = y - row_h
      if y < 0 then item = item + 1 break end
      item = item - 1
    end
  end
  return item
end

return IV
