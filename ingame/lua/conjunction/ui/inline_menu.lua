-- Drop-down lists inside their window, as conjunction/inline_menu.py shows them (InlineList).
--
--   IM.open(id, anchor, items, win, opts)   anchor {x, y, w, h} (the button), win {x, y, w, h} (its window)
--   IM.frame()                              once per frame after the window's content: draws, takes clicks
--   IM.is_open(id)
-- items: {text = , checked = , disabled = , icon = , action = fn} | {group = "Heading", items = {...}} | "-"
--
-- Measured on Qt (ingame/ref/qt/inline_list.png, an app page):
-- * under the button, as wide as its entries + 24 (at least the button and 140), as high as they are + 6, the room
--   of the window at most (it scrolls then); above the button when there is more room there
-- * a 1 px #5a5a60 border, inside it 1 px of #232326, then the page's background (the page's QScrollArea rule wins)
-- * entries 24 px: 12 px #ddd, 10 px in; under the mouse #3a3a40 white, checked #4b4b50 white; a disabled entry
--   looks the same (the #entry rule wins over :disabled) but does nothing
-- * a group heading 23 px: bold 11 px #9a9a9a, 10 px in, 6 px above; its entries 4 spaces in per depth
-- * a separator takes no room and shows nothing (its QFrame is 0 px high)
-- * an icon (a Remove entry's trash can): 16 px #cfcfcf at 10 px, its text 4 px after it
-- * longer than its room: the theme's scroll bar at the right inside the border (the entries that much narrower);
--   the first checked entry scrolled into sight as QScrollArea::ensureWidgetVisible does (50 px around it)
-- * a click on an entry closes the list, then runs the entry; a click elsewhere closes it and goes through, except
--   on its own button (only closes); Escape closes it
local Q = require("conjunction.ui.qt")
local T = require("conjunction.ui.theme")
local D = w3.ui.draw
local IM = {}

local FRAME, INNER = 0x5a5a60ff, 0x232326ff
local ENTRY_TEXT, HOT, CHECKED, GROUP = 0xddddddff, 0x3a3a40ff, 0x4b4b50ff, 0x9a9a9aff
local ENTRY_H, GROUP_H = 24, 23

local open = nil   -- {id, anchor, rows, x, y, w, h, scroll, opened_frame}

local function flatten(items, depth, rows)
  for _, it in ipairs(items) do
    if it == "-" then
      -- no room, nothing drawn (Qt's separator collapses)
    elseif it.group then
      rows[#rows + 1] = {kind = "group", text = it.group}
      flatten(it.items or {}, depth + 1, rows)
    elseif it.visible ~= false then
      rows[#rows + 1] = {kind = "entry", text = string.rep("    ", depth) .. it.text, item = it, icon = it.icon}
    end
  end
  return rows
end

function IM.open(id, anchor, items, win, opts)
  opts = opts or {}
  local rows = flatten(items, 0, {})
  local want_w, want_h = 0, 2 + 2
  for _, r in ipairs(rows) do
    if r.kind == "group" then
      want_w = math.max(want_w, Q.hint_w(r.text, 11, true) + 20 + Q.label_indent(11, true))   -- (its padding: indent)
      want_h = want_h + GROUP_H
    else
      want_w = math.max(want_w, Q.hint_w(r.text, 12) + 24 + (r.icon and 20 or 0))
      want_h = want_h + ENTRY_H
    end
  end
  local below = win.y + win.h - (anchor.y + anchor.h) - 6
  local above = anchor.y - win.y - 6
  local h = math.min(want_h + 6, math.max(below, above, 120))
  local w = math.min(math.max(want_w + 24, anchor.w, 140), math.max(160, win.w - 12))
  local y = (below >= h or below >= above) and (anchor.y + anchor.h) or (anchor.y - h)
  local x = math.min(math.max(win.x + 4, anchor.x), math.max(win.x + 4, win.x + win.w - w - 4))
  open = {id = id, anchor = anchor, rows = rows, x = x, y = math.max(win.y + 4, y), w = w, h = h, scroll = 0,
          content_h = want_h, opened = select(2, w3.ui.time()), bg = opts.bg or T.BG}
  -- the first checked entry in view (QScrollArea::ensureWidgetVisible, margins 50)
  local vh, cy = h - 4, 2
  for _, r in ipairs(rows) do
    if r.kind == "entry" and r.item.checked then
      if cy + ENTRY_H > vh then
        local top, bottom = cy - 50, cy + ENTRY_H - 1 + 50
        local v = bottom - top + 1 > vh and (top + bottom) // 2 - vh // 2 or bottom - vh + 1
        open.scroll = math.max(0, math.min(want_h - vh, v))
      end
      break
    end
    cy = cy + (r.kind == "group" and GROUP_H or ENTRY_H)
  end
end

function IM.is_open(id) return open ~= nil and (id == nil or open.id == id) end
-- the mouse is over the open list: the controls under it take no hover and no click (Qt: the list is on top)
function IM.covers(x, y) return open ~= nil and x >= open.x and y >= open.y and x < open.x + open.w and y < open.y + open.h end
function IM.close() open = nil end

local function inside(x, y, r) return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h end

-- -> true when the list took this frame's click (the caller's controls under it should not act on it)
function IM.frame()
  if not open then return false end
  local o = open
  local mx, my = w3.ui.mouse()
  local _, frame = w3.ui.time()
  if w3.ui.pressed("Escape") then open = nil return false end
  local over = inside(mx, my, o)
  if w3.ui.mouse_clicked(1) and frame > o.opened and not over then
    open = nil
    return inside(mx, my, o.anchor)          -- a click on its own button only closes it
  end
  local _, _, wheel = w3.ui.mouse()
  local inner_h = o.h - 4
  local bar = o.content_h > inner_h and {value = o.scroll, max = o.content_h - inner_h, page = inner_h} or nil
  local vw = o.w - 4 - (bar and 10 or 0)
  if over and wheel ~= 0 and bar then
    o.scroll = math.max(0, math.min(bar.max, o.scroll - wheel * 3 * ENTRY_H))
    bar.value = o.scroll
  end
  local took = false
  D.layer("front", function()
    D.fill(o.x, o.y, o.w, o.h, INNER)
    D.rect(o.x, o.y, o.w, o.h, FRAME, 1)
    D.fill(o.x + 2, o.y + 2, o.w - 4, o.h - 4, o.bg)
    if bar then
      local br = {x = o.x + o.w - 2 - 10, y = o.y + 2, w = 10, h = inner_h}
      require("conjunction.ui.scrollbar").draw(o, "bar", bar, br, "v", function(_, r)
        local h = inside(mx, my, r)
        return h and w3.ui.mouse_clicked(1), h, w3.ui.mouse_down(1)
      end, function(b) o.scroll = b.value end)
    end
    D.clip(o.x + 2, o.y + 2, vw, o.h - 4, function()
      local y = o.y + 2 + 2 - o.scroll
      for _, r in ipairs(o.rows) do
        if r.kind == "group" then
          Q.text(o.x + 2 + 10 + Q.text_w("x", 11, true) // 2, y + 6, GROUP, r.text, 11, true, o.bg)   -- QLabel's indent (it has padding)
          y = y + GROUP_H
        else
          local it = r.item
          local box = {x = o.x + 2, y = y, w = vw, h = ENTRY_H}
          local AG = package.loaded["conjunction.agent"]      -- (an entry the agent can choose: agent.menu)
          if AG and y + ENTRY_H > o.y + 2 and y < o.y + o.h - 2 and not it.disabled then
            AG.area("inline." .. tostring(o.id) .. "." .. tostring(r.text), box.x, box.y, box.w, box.h, r.text)
          end
          local hot = over and inside(mx, my, box) and my >= o.y + 2 and my < o.y + o.h - 2 and not o.bar_drag
          local bg = hot and HOT or (it.checked and CHECKED or o.bg)
          if bg ~= o.bg then D.fill(box.x, box.y, box.w, box.h, bg) end
          local tx = box.x + 10
          if r.icon then
            Q.draw_icon(r.icon, 0xcfcfcfff, 16, tx, y + (ENTRY_H - 16) // 2)
            tx = tx + 20
          end
          Q.text(tx, y + (ENTRY_H - Q.line_h(12)) // 2, (hot or it.checked) and T.WHITE or ENTRY_TEXT, r.text, 12, false, bg)
          if hot and w3.ui.mouse_released(1) and not it.disabled then
            open = nil
            took = true
            if it.action then it.action() end
          end
          y = y + ENTRY_H
        end
      end
    end)
  end)
  if over then took = true end
  return took
end

return IM
