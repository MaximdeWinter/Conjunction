-- A QTableWidget with theme.py's sheet (rows chosen whole, not editable, no vertical header): a 1 px LINE frame on
-- SURFACE, the header's sections (34 high, the text centred; bold while the column has a chosen cell - Qt highlights
-- them), rows of 29 px and a grid line, the cell text 13 px #ddd 11 px in (chosen: CHOSEN, white), cut with an
-- ellipsis where it does not fit. The columns as setColumnWidth set them; the last one stretches, at least the
-- header's default section size (100) - wider than the viewport, the horizontal bar comes.
--   local t = TB.new({"When", "Who"}, {130, 120})   t:frame(r, rows, hit, ids)   t.cur (1-based)   t.on_click(i)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local D = w3.ui.draw
local TB = {}
TB.__index = TB

TB.ROW_H = 30             -- (29 and the grid's line)
TB.HEAD_H = 34
TB.DEFAULT_SECTION = 100

function TB.new(heads, widths)
  return setmetatable({heads = heads, widths = widths, cur = nil, vbar = IV.bar(), hbar = IV.bar()}, TB)
end
function TB:select(i) self.cur = i end
-- the chosen row scrolled into sight at the next frame (selectRow on a table already shown: scrollTo, EnsureVisible)
function TB:ensure_visible() self.want_visible = true end

-- a cell's text cut to w: QTableView wraps words (wordWrap is on), the cell shows one line. When that line's words
-- (their space with them) and the ellipsis fit, those and the ellipsis; else letter by letter as elidedText (measured
-- on Qt 20.10.: "Conjunction 0.1.0" is "Conjunction …" from 81 to 98 px, never "Conjunction 0.…")
local function elide(s, w)
  if Q.text_w(s, T.FONT) <= w then return s end
  local line = nil
  local i = 1
  while true do                                  -- (the line's breaks: after a run of spaces, after a hyphen)
    local a, b = s:find("[ ]+", i)
    local h = s:find("-", i, true)
    local cut
    if h and (not a or h < a) then cut = h elseif b then cut = b else break end
    local head = s:sub(1, cut)
    if Q.text_w((head:gsub(" +$", "")), T.FONT) > w then break end
    line, i = head, cut + 1
  end
  if line and Q.text_w(line, T.FONT) + Q.text_w("\u{2026}", T.FONT) <= w then return line .. "\u{2026}" end
  local CV = require("conjunction.ui.catalog_view")
  return CV.elide(s, "right", w, T.FONT, false)
end

-- r: the widget's rectangle; rows: {{text per column}, tips = {...}}; hit(id, r) -> clicked, hovered
function TB:frame(r, rows, hit, ids)
  ids = ids or "table"
  Q.view_frame(r.x, r.y, r.w, r.h)
  local vx, vy = r.x + 1, r.y + 1
  local vw, vh = r.w - 2, r.h - 2
  local n = #self.heads
  local function columns(view_w)
    local cols, x = {}, 0
    for i = 1, n - 1 do cols[i] = self.widths[i] or TB.DEFAULT_SECTION x = x + cols[i] end
    cols[n] = math.max(view_w - x, TB.DEFAULT_SECTION)
    return cols, x + cols[n]
  end
  -- which bars: the rows below the header, the columns across
  local need_h = #rows * TB.ROW_H
  local bar_v, bar_h = false, false
  for _ = 1, 2 do
    local w_ = vw - (bar_v and 10 or 0)
    local _, total = columns(w_)
    bar_h = total > w_
    local h_ = vh - TB.HEAD_H - (bar_h and 10 or 0)
    bar_v = need_h > h_
  end
  local w_ = vw - (bar_v and 10 or 0)
  local body_h = vh - TB.HEAD_H - (bar_h and 10 or 0)
  local cols, total = columns(w_)
  -- (QTableView scrolls per item: a page is the rows - the columns - that fit counted from the last; at the end the
  -- last one ends at the viewport's edge)
  local function fit(sizes, room)
    local k, sum = 0, 0
    for i = #sizes, 1, -1 do
      sum = sum + sizes[i]
      if sum > room then break end
      k = k + 1
    end
    return k
  end
  local heights = {}
  for i = 1, #rows do heights[i] = TB.ROW_H end
  local vb, hb = self.vbar, self.hbar
  vb.single, vb.page = 1, fit(heights, body_h)
  IV.range(vb, #rows - vb.page)
  if self.want_visible and self.cur then
    self.want_visible = nil
    if self.cur > vb.value + vb.page then IV.set(vb, self.cur - vb.page)
    elseif self.cur - 1 < vb.value then IV.set(vb, self.cur - 1) end
  end
  hb.single, hb.page = 1, fit(cols, w_)
  IV.range(hb, n - hb.page)
  local function offset(bar, sizes, all, room)
    if bar.max > 0 and bar.value >= bar.max then return all - room end
    local o = 0
    for i = 1, bar.value do o = o + sizes[i] end
    return o
  end
  local voff = offset(vb, heights, need_h, body_h)
  local hx = vx - offset(hb, cols, total, w_)
  -- the header
  D.clip(vx, vy, w_, TB.HEAD_H, function()
    local x = hx
    for i = 1, n do
      Q.header(x, vy, cols[i], TB.HEAD_H, self.heads[i], self.cur ~= nil)
      x = x + cols[i]
    end
  end)
  -- the rows
  local top = vy + TB.HEAD_H
  local over = CT.over({x = vx, y = top, w = w_, h = body_h})
  local _, _, wheel = w3.ui.mouse()
  if over and wheel and wheel ~= 0 then IV.wheel(vb, wheel >= 0 and math.min(wheel, 1) or math.max(wheel, -1), 3) end
  local tip
  D.clip(vx, top, w_, body_h, function()
    for i, row in ipairs(rows) do
      local y = top + (i - 1) * TB.ROW_H - voff
      if y + TB.ROW_H > top and y < top + body_h then
        local x = hx
        local chosen = self.cur == i
        for c = 1, n do
          local s = elide(row[c] or "", cols[c] - 1 - 16 - 6)   -- (the grid's line, the padding, the margins)
          Q.table_cell(x, y, cols[c] - 1, TB.ROW_H - 1, s, {chosen = chosen})
          local _, hv = hit(ids .. ".cell." .. i .. "." .. c, {x = x, y = y, w = cols[c], h = TB.ROW_H})
          if hv and row.tips and row.tips[c] and row.tips[c] ~= "" then tip = row.tips[c] end
          x = x + cols[c]
        end
        local clicked = hit(ids .. ".row." .. i, {x = vx, y = y, w = w_, h = TB.ROW_H})
        if clicked then
          self.cur = i
          if self.on_click then self.on_click(i) end
        end
      end
    end
  end)
  if tip then CT.tip("panel." .. ids .. ".cell", {"", tip}) end
  if bar_v then
    SBAR.draw(self, ids .. ".vbar", vb, {x = vx + w_, y = vy, w = 10, h = vh - (bar_h and 10 or 0)}, "v", hit)
  end
  if bar_h then
    SBAR.draw(self, ids .. ".hbar", hb, {x = vx, y = vy + vh - 10, w = w_, h = 10}, "h", hit)
  end
end

return TB
