-- The theme's scroll bars (theme.py: 10 px, no arrows, the handle #3a3a3e, under the mouse EDGE, at least 24 px) as
-- QScrollBar has them: the handle where QStyle puts it (sliderPositionFromValue), dragged it follows the mouse
-- (tracking), a press beside it a page that way, again while held (500 ms, then every 50 ms) until the handle has
-- passed the mouse.
--   SB.draw(st, id, bar, r, dir, hit, on_change)   st: the view's state for its bars (what is under the mouse, dragged)
--                                                  bar: an itemview.lua bar; r: the bar's rectangle; dir "v" | "h";
--                                                  hit(id, r) -> clicked, hovered, held; on_change(bar) after a move
local IV = require("conjunction.ui.itemview")
local T = require("conjunction.ui.theme")
local D = w3.ui.draw
local SB = {}

function SB.slider_pos(min, max, value, span)
  if span <= 0 or value < min or max <= min then return 0 end
  if value > max then return span end
  local range, p = max - min, value - min
  if range > span then return (2 * p * span + range) // (2 * range) end
  local div, mod = span // range, span % range
  return p * div + (2 * p * mod + range) // (2 * range)
end
function SB.slider_value(min, max, pos, span)
  if span <= 0 or pos <= 0 then return min end
  if pos >= span then return max end
  local range = max - min
  if span > range then return min + (2 * pos * range + span) // (2 * span) end
  local div, mod = range // span, range % span
  return min + pos * div + (2 * pos * mod + span) // (2 * span)
end
-- the handle: its length and its position along a bar len long (nil: nothing to scroll)
function SB.handle(len, bar)
  local page, max = bar.page, bar.max
  if max <= 0 then return nil end
  local hl = math.max(24, (page * len) // (max + page))
  hl = math.min(hl, len)
  return hl, SB.slider_pos(0, max, bar.value, len - hl)
end

function SB.draw(st, id, bar, r, dir, hit, on_change)
  local len = dir == "v" and r.h or r.w
  local hl, hp = SB.handle(len, bar)
  if not hl then return end
  local mx, my = w3.ui.mouse()
  local _, hovered, held = hit(id, r)
  local along = dir == "v" and my - r.y or mx - r.x
  local on_handle = along >= hp and along < hp + hl
  if st.bar_hot == id then st.bar_hot = nil end
  if hovered and on_handle then st.bar_hot = id end
  local now = w3.ui.time()
  local function set(v) if IV.set(bar, v) and on_change then on_change(bar) end end
  if hovered and w3.ui.mouse_clicked(1) then
    if on_handle then
      st.bar_drag, st.drag_off = id, along - hp
    else
      st.bar_page = {id = id, dir = along < hp and -1 or 1, next = now + 0.5}
      set(bar.value + st.bar_page.dir * bar.page)
    end
  end
  if st.bar_drag == id then
    if held then set(SB.slider_value(0, bar.max, along - st.drag_off, len - hl))
    else st.bar_drag = nil end
  end
  local pg = st.bar_page
  if pg and pg.id == id then
    if not held then st.bar_page = nil
    elseif now >= pg.next then
      local hl2, hp2 = SB.handle(len, bar)
      if hl2 and ((pg.dir < 0 and along < hp2) or (pg.dir > 0 and along >= hp2 + hl2)) then
        set(bar.value + pg.dir * bar.page)
      end
      pg.next = now + 0.05
    end
  end
  hl, hp = SB.handle(len, bar)
  if not hl then return end
  local lit = st.bar_hot == id or st.bar_drag == id
  if dir == "v" then D.fill(r.x, r.y + hp, r.w, hl, lit and T.EDGE or T.SCROLL)
  else D.fill(r.x + hp, r.y, hl, r.h, lit and T.EDGE or T.SCROLL) end
end

return SB
