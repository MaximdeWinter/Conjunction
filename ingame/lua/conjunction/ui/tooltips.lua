-- Tooltips as conjunction/tooltips.py draws them (its Tip window) and as Qt times them.
--
--   TT.hover(id, title, text)   from a control the mouse is over, every frame (ui/controls.lua does it)
--   TT.frame()                  once per frame after the windows: shows, moves or hides the tooltip
--
-- Look (tooltips.py STYLE): rgb(30,30,32), a 1 px #555 border, margins 10 7 10 8, title bold 12 px #f0f0f0, text 12 px
-- #d0d0d0, 3 px between; the text one line up to 300 px (its advance + 6), wrapped beyond.
-- Place: 14 px right of and 20 px below the mouse; above it (8 px) when it would leave the screen at the bottom;
-- 4 px from the right edge at most.
-- Time (Qt's windows11 style): 700 ms of rest over the control; within 2 s of the last one 20 ms; hidden when the mouse
-- leaves the control or a button is pressed.
local Q = require("conjunction.ui.qt")
local D = w3.ui.draw
local TT = {}

local BG, EDGE = 0x1e1e20ff, 0x555555ff
local TITLE, BODY = 0xf0f0f0ff, 0xd0d0d0ff
local PX = 12
TT.WAKE, TT.ASLEEP, TT.QUICK = 0.7, 2.0, 0.02

-- the lines of a text wrapped at width (greedy at spaces, as QTextLayout breaks a QLabel's text); a line break
-- starts a new line (the catalog's tooltip: what it is, then what a click does - they ran into one, 07.11.)
function TT.wrap(text, width, px)
  local lines = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      local try = line == "" and word or (line .. " " .. word)
      if line ~= "" and Q.text_w(try, px) > width then
        lines[#lines + 1] = line
        line = word
      else
        line = try
      end
    end
    if line ~= "" then lines[#lines + 1] = line end
  end
  return lines
end

-- the box of a tooltip: width, height and its lines
function TT.layout(title, text)
  local lh = Q.line_h(PX)
  local bw, lines = 0, {}
  if text and text ~= "" then
    for para in (text .. "\n"):gmatch("(.-)\n") do bw = math.max(bw, math.min(300, Q.text_w(para, PX) + 6)) end
    lines = TT.wrap(text, bw, PX)
  end
  local tw = (title and title ~= "") and Q.hint_w(title, PX, true) or 0
  local cw = math.max(bw, tw)
  local h = 1 + 7 + 8 + 1
  if tw > 0 then h = h + lh end
  if #lines > 0 then h = h + #lines * lh end
  if tw > 0 and #lines > 0 then h = h + 3 end
  return cw + 22, h, lines
end

function TT.draw(x, y, title, text)
  local w, h, lines = TT.layout(title, text)
  D.fill(x, y, w, h, BG)
  D.rect(x, y, w, h, EDGE, 1)
  local ty = y + 8
  local lh = Q.line_h(PX)
  if title and title ~= "" then
    Q.text(x + 11, ty, TITLE, title, PX, true, BG)
    ty = ty + lh + 3
  end
  for _, l in ipairs(lines) do
    Q.text(x + 11, ty, BODY, l, PX, false, BG)
    ty = ty + lh
  end
  return w, h
end

-- --- timing ---
local hovered = nil        -- {id, title, text} this frame
local cur = nil            -- the control the mouse rests on
local rest_since, last_mouse = 0, nil
local shown = nil          -- {x, y, title, text}
local asleep_until = -1    -- before then a tooltip comes quickly
local blocked = nil        -- a press hid the tooltip of this control

function TT.hover(id, title, text)
  if (title and title ~= "") or (text and text ~= "") then hovered = {id, title, text} end
end

function TT.frame()
  local now = w3.ui.time()
  local mx, my = w3.ui.mouse()
  local moved = not last_mouse or last_mouse[1] ~= mx or last_mouse[2] ~= my
  last_mouse = {mx, my}
  local pressed = w3.ui.mouse_clicked(1) or w3.ui.mouse_clicked(2) or w3.ui.mouse_clicked(3)
  local h = hovered
  hovered = nil
  if not h or (cur and cur ~= h[1]) then          -- left the control
    if shown then asleep_until = now + TT.ASLEEP end
    shown, cur, blocked = nil, h and h[1] or nil, nil
    rest_since = now
  end
  if not h then return end
  cur = h[1]
  if pressed then
    if shown then asleep_until = now + TT.ASLEEP end
    shown, blocked = nil, cur
    rest_since = now
    return
  end
  if moved then rest_since = now; blocked = nil end   -- after a press only a move wakes it again (as Qt's timer)
  if blocked == cur then return end
  local wait = now < asleep_until and TT.QUICK or TT.WAKE
  if not moved and now - rest_since >= wait and (not shown or shown.mx ~= mx or shown.my ~= my) then
    local sw, sh = w3.ui.screen()
    local w, hh = TT.layout(h[2], h[3])
    local x = math.min(mx + 14, sw - 1 - w - 4)
    local y = (my + 20 + hh < sh - 1) and (my + 20) or (my - hh - 8)
    shown = {x = x, y = y, mx = mx, my = my, title = h[2], text = h[3]}
    asleep_until = now + TT.ASLEEP
  end
  if shown then
    D.layer("front", function() TT.draw(shown.x, shown.y, shown.title, shown.text) end)
    asleep_until = now + TT.ASLEEP
  end
end

return TT
