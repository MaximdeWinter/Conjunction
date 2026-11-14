-- The controls of Conjunction drawn as Qt draws them with theme.py's style sheet (conjunction/theme.py base()).
-- Each control has a size function (Qt's size hint) and a paint function (a rectangle and a state); the
-- interactive controls (ui/controls.lua) put the two together with the mouse and the keyboard.
--
-- Positions are screen pixels. Text goes through w3.ui.draw.text with its background, so it blends as Qt's does.
-- a text's style for w3.ui: true -> "bold", "mono" (Consolas: a log) as it is
local function Q_style(bold) if bold == "mono" then return "mono" end return bold and "bold" or nil end
local T = require("conjunction.ui.theme")
local Q = {}

local D = w3.ui.draw

-- the folder of the mod (icons/ beside ui/)
local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[\\/]ui[\\/]qt%.lua$", "")
Q.root = here

local icons = {}
function Q.icon(name, colour, size, stroke)
  local key = string.format("%s_%06x_%d%s", name, colour // 256, size, stroke and ("_w" .. stroke) or "")
  local ic = icons[key]
  if ic == nil then
    local id, w, h = w3.ui.image_load(here .. "\\icons\\" .. key .. ".png")
    ic = id and {id = id, w = w, h = h} or false
    icons[key] = ic
    if not id then print("conjunction: no icon " .. key .. ".png (ingame/tools/make_icons.py)") end
  end
  return ic or nil
end
-- a picture of icons/ by its file name (the logo)
function Q.draw_icon_file(file, x, y)
  local key = "file:" .. file
  local ic = icons[key]
  if ic == nil then
    local id, w, h = w3.ui.image_load(here .. "\\icons\\" .. file .. ".png")
    ic = id and {id = id, w = w, h = h} or false
    icons[key] = ic
  end
  if ic then D.image(ic.id, x, y, ic.w, ic.h) end
end
function Q.draw_icon(name, colour, size, x, y, stroke)
  local ic = Q.icon(name, colour, size, stroke)
  if ic then D.image(ic.id, x, y, ic.w, ic.h) end
end

-- QFontMetrics::elidedText (QTextEngine::elidedText): letter by letter, each with its kerning, until the width less
-- the ellipsis is reached; the letter that reaches it goes too ("right" or "middle")
local S = require("conjunction.pystr")
function Q.elide(s, mode, width, px, bold)
  local full = Q.text_w(s, px, bold)
  local cps = S.cps(s)
  if full <= width or #cps <= 1 then return s end
  local ell = Q.text_w("\u{2026}", px, bold)
  local avail = width - ell
  if avail < 0 then return "" end
  local offs = w3.ui.text_offsets(s, px, Q_style(bold))   -- the pen before each letter, the end last
  -- (offs is by byte position of each letter's start: map letters)
  local xs = {}
  local bi = 1
  for i = 1, #cps do xs[i] = offs[i] end
  xs[#cps + 1] = offs[#cps + 1]
  local function w_of(i) return xs[i + 1] - xs[i] end      -- letter i (1-based) with its kerning to the next
  if mode == "right" then
    local cur, pos = 0, 1
    local nxt = 1
    repeat
      pos = nxt
      nxt = nxt + 1
      cur = cur + w_of(pos)
    until not (nxt <= #cps and cur < avail)
    return S.from_cps(cps, 1, pos - 1) .. "\u{2026}"
  end
  -- middle
  local lw, rw = 0, 0
  local lpos, nl = 1, 1
  local rpos, nr = #cps + 1, #cps + 1
  repeat
    lpos, rpos = nl, nr
    nl = nl + 1
    nr = nr - 1
    lw = lw + w_of(lpos)
    rw = rw + w_of(nr)
  until not (nl <= #cps and nr > 1 and lw + rw < avail)
  local _ = bi
  return S.from_cps(cps, 1, lpos - 1) .. "\u{2026}" .. S.from_cps(cps, rpos, #cps)
end

-- text
function Q.text_w(s, px, bold) return (w3.ui.text_size(s, px or T.FONT, Q_style(bold))) end
-- the width a size hint uses (QFontMetrics::size: the advance and the last letter's overhang)
function Q.hint_w(s, px, bold) return w3.ui.text_hint(s, px or T.FONT, Q_style(bold)) end
-- QFontMetrics::averageCharWidth of Segoe UI (measured in Qt)
local AVG = {[11] = {5, 6}, [12] = {6, 7}, [13] = {6, 7}, [14] = {6, 8}}
function Q.avg_w(px, bold) local a = AVG[px or T.FONT] or {6, 7} return a[bold and 2 or 1] end
function Q.line_h(px, bold) local _, _, l = w3.ui.font_metrics(px or T.FONT, Q_style(bold)) return l end
-- Q.translucent: drawing an overlay window (hud.py's bar, the panel): Qt renders those into an ARGB buffer.
Q.translucent = false
-- In a translucent window Qt decides per pixel (qt_alphargbblit_argb32): over an opaque pixel ClearType blended with
-- gamma, over a translucent one the average of the coverage, blended plainly. bg's alpha says which.
function Q.text(x, y, colour, s, px, bold, bg)
  if Q.translucent and not (bg and (bg & 0xff) == 0xff) then
    D.text(x, y, colour, s, px or T.FONT, Q_style(bold), 0, nil, "gray")
  else
    D.text(x, y, colour, s, px or T.FONT, Q_style(bold), 0, bg)
  end
end

-- a frame: background and a 1 px border inside the rectangle (Qt's border:1px solid)
local function frame(x, y, w, h, bg, edge)
  if bg then D.fill(x, y, w, h, bg) end
  if edge then D.rect(x, y, w, h, edge, 1) end
end
Q.frame = frame

-- QLabel (page(): colour TEXT, 13 px; #head 14 px bold BRIGHT with 4 px below, #title bold BRIGHT, #name 14 px bold
-- BRIGHT, #dim 11 px DIM, #problem RED)
Q.LABELS = {
  [""] = {T.TEXT, T.FONT, false, 0},
  head = {T.BRIGHT, T.FONT_HEAD, true, 4},
  title = {T.BRIGHT, T.FONT, true, 0},
  name = {T.BRIGHT, T.FONT_HEAD, true, 0},
  dim = {T.DIM, T.FONT_SMALL, false, 0},
  problem = {T.RED, T.FONT, false, 0},
}
-- A label with a box (padding, a border: Qt gives it a frame) gets QLabel's indent: its size hint adds the advance of
-- 'x', its text stands half of that in (qlabel.cpp: sizeForWidth adds fm.horizontalAdvance('x'), paintEvent half).
function Q.label_indent(px, bold) return Q.text_w("x", px, bold) end
-- a QLabel's text (or picture) of height ih centred in a box of height h: the odd pixel goes below the middle
-- (ref/qt vcenter: eight fonts, eight heights each)
function Q.vcenter(h, ih) return (h - ih + 1) // 2 end
local function indent(k) return k[4] > 0 and Q.label_indent(k[2], k[3]) or 0 end
function Q.label_size(s, kind)
  local k = Q.LABELS[kind or ""]
  return Q.hint_w(s, k[2], k[3]) + indent(k), Q.line_h(k[2], k[3]) + k[4]
end
function Q.label(x, y, s, kind, bg)
  local k = Q.LABELS[kind or ""]
  Q.text(x + indent(k) // 2, y, k[1], s, k[2], k[3], bg or T.BG)
end

-- QPushButton: padding 5px 10px, border 1px EDGE, BUTTON; hover EDGE_HOVER; pressed CHOSEN; #primary CHOSEN with
-- CHOSEN_EDGE
function Q.button_size(s)
  return Q.hint_w(s) + 22, Q.line_h() + 12
end
function Q.button(x, y, w, h, s, st)
  st = st or {}
  local bg, edge, fg = T.BUTTON, T.EDGE, st.fg or T.TEXT   -- an app page's QWidget{color} wins over #dddddd
  if st.primary then bg, edge, fg = T.CHOSEN, T.CHOSEN_EDGE, T.BRIGHT end
  if st.hover and not st.disabled then edge = T.EDGE_HOVER end
  if st.pressed and not st.disabled then bg = T.CHOSEN end
  if st.disabled then bg, edge, fg = T.BUTTON, T.LINE, T.DISABLED_TEXT end
  frame(x, y, w, h, bg, edge)
  local tw = Q.text_w(s)
  local dy = h - 12 - Q.line_h()                -- (C's division: a button lower than its text keeps it at the top)
  local tx, ty = x + 11 + (w - 22 - tw) // 2, y + 6 + (dy >= 0 and dy // 2 or -((-dy) // 2))
  if tw > w - 22 then
    -- (drawText into the contents clips: a button narrower than its text shows what fits)
    D.clip(x + 11, y + 6, math.max(0, w - 22), math.max(0, h - 12), function() Q.text(tx, ty, fg, s, T.FONT, false, bg) end)
  else
    Q.text(tx, ty, fg, s, T.FONT, false, bg)
  end
end

-- a QPushButton with a menu (the theme has no indicator of its own: the Windows 11 style's): 20 px more for the
-- indicator, the text in the middle of the rest; the indicator U+E972 of Segoe Fluent Icons, 13 px #ddd, in the
-- middle of 20 px that end 7 before the right (ref/probe_indicator.py: 0 off), painted by Qt over the button's colour
function Q.menu_button_size(s) local w, h = Q.button_size(s) return w + 20, h end
local indicators = {}
function Q.menu_button(x, y, w, h, s, st)
  st = st or {}
  Q.button(x, y, w, h, "", st)
  local bg = T.BUTTON
  if st.pressed and not st.disabled then bg = T.CHOSEN end
  local tw = Q.text_w(s)
  local dy = h - 12 - Q.line_h()
  local tx, ty = x + 11 + (w - 20 - 22 - tw) // 2, y + 6 + (dy >= 0 and dy // 2 or -((-dy) // 2))
  Q.text(tx, ty, st.disabled and T.DISABLED_TEXT or (st.fg or T.TEXT), s, T.FONT, false, bg)
  local key = string.format("%d_%08x", h, bg)
  local pic = indicators[key]
  if pic == nil then
    pic = false
    local file = (os.getenv("TEMP") or ".") .. "\\cj_indicator_" .. key .. ".png"
    local cmds = table.concat({"fill " .. string.format("%08x", bg), "fontfam 13 0 Segoe Fluent Icons", "pen ddddddff 1",
                               string.format("textrect 3 -1 20 %d 132 %s", h, utf8.char(0xE972))}, "\n")
    if pcall(w3.plugin.cj_qt_paint, file, "29", tostring(h - 2), cmds) then   -- (the right border stays)
      local id, iw, ih = w3.ui.image_load(file)
      if id then pic = {id, iw, ih} end
    end
    indicators[key] = pic
  end
  if pic then D.image(pic[1], x + w - 30, y + 1, pic[2], pic[3]) end
end

-- QLineEdit: FIELD, border EDGE (focus EDGE_HOVER), padding 5px, text BRIGHT; the placeholder half as bright
function Q.edit_size(w) return w or 180, Q.line_h() + 14 end
function Q.edit(x, y, w, h, text, st)
  st = st or {}
  frame(x, y, w, h, T.FIELD, st.focus and T.EDGE_HOVER or T.EDGE)
  local ty = y + 1 + 5 + (h - 12 - Q.line_h()) // 2
  local tx = x + 1 + 5 + 2
  if text == "" and st.placeholder then
    Q.text(tx, ty, (T.TEXT & 0xffffff00) | 0x80, st.placeholder, T.FONT, false, T.FIELD)
  else
    Q.text(tx, ty, T.TEXT, text, T.FONT, false, T.FIELD)
  end
end

-- QComboBox: as a field, the drop-down 20 px wide with chevron-down 12 px
function Q.combo(x, y, w, h, text, st)
  st = st or {}
  frame(x, y, w, h, T.FIELD, st.focus and T.EDGE_HOVER or T.EDGE)
  -- (its text cut at the edit field's right: the border, the padding, the drop-down's 20 px)
  D.clip(x + 1, y + 1, math.max(0, w - 27), h - 2, function()
    Q.text(x + 1 + 5, y + 1 + 5 + (h - 12 - Q.line_h() + 1) // 2, st.fg or T.TEXT, text, T.FONT, false, T.FIELD)
  end)
  Q.draw_icon("chevron-down", T.TEXT, 12, x + w - 1 - 20 + 4, y + (h - 12) // 2)
end

-- QSpinBox: a field 35 px high with the number at 11, 10 and chevrons 10 px at the right (up, down)
function Q.spin_size(w) return w or 90, 35 end
function Q.spin(x, y, w, h, text, st)
  st = st or {}
  frame(x, y, w, h, T.FIELD, st.focus and T.EDGE_HOVER or T.EDGE)
  Q.text(x + 12, y + (h - Q.line_h()) // 2, T.TEXT, text, T.FONT, false, T.FIELD)
  Q.draw_icon("chevron-up", T.TEXT, 10, x + w - 14, y + 4)
  Q.draw_icon("chevron-down", T.TEXT, 10, x + w - 14, y + h - 14)
end

-- QCheckBox: the indicator 14 px inside a 1 px border (16 px, Qt's box model), at the top; 8 px, the text
function Q.check_size(s, px) return T.BOX + 2 + 8 + Q.hint_w(s, px), Q.line_h(px) end
function Q.check(x, y, s, st)
  st = st or {}
  local b = T.BOX + 2
  local px = st.px or T.FONT             -- (an app page's 13 px; the app's own 12 px where no page rule is)
  local h = st.h or Q.line_h(px)         -- (st.h: the height its layout gave it; box and text each centred in it)
  local by = y + (h - b) // 2
  local edge = st.disabled and T.LINE or (st.hover and T.EDGE_HOVER or T.EDGE)
  frame(x, by, b, b, st.disabled and T.BG or T.FIELD, edge)
  if st.checked then Q.draw_icon("check", T.BRIGHT, 12, x + 2, by + 2) end
  Q.text(x + b + 8, y + (h - Q.line_h(px)) // 2, st.fg or T.TEXT, s, px, false, st.bg or T.BG)   -- disabled too: QWidget{color} wins
end

-- QRadioButton: the indicator as Qt draws it (parts/radio_*.png, ingame/tools/make_parts.py: 14 px, chosen 18 px
-- with its 3 px ring), the text after it, centred in the widget's height
local PARTS = require("conjunction.parts.parts")
local function part_img(name)
  local key = "part:" .. name
  local ic = icons[key]
  if ic == nil then
    local id, w, h = w3.ui.image_load(here .. "\\parts\\" .. name .. ".png")
    ic = id and {id = id, w = w, h = h} or false
    icons[key] = ic
  end
  return ic or nil
end
-- a part as it is, its top left at x, y
Q.part_img = part_img
function Q.draw_part(name, x, y)
  local img = part_img(name)
  if img then D.image(img.id, x, y, img.w, img.h) end
end
function Q.radio_size(s, checked)
  local p = PARTS[checked and "radio_on" or "radio_off"]
  return p[5] + Q.hint_w(s), p[7]
end
function Q.radio(x, y, s, st)
  st = st or {}
  local name = (st.checked and "radio_on" or "radio_off") .. (st.hover and "_hover" or "")
  local p = PARTS[name]
  local img = part_img(name)
  if img then D.image(img.id, x + p[1], y + p[2], img.w, img.h) end
  Q.text(x + p[5], y + (p[7] - Q.line_h() + 1) // 2, T.TEXT, s, T.FONT, false, st.bg or T.BG)
end

-- QProgressBar: FIELD, border LINE, the chunk CHOSEN, its text centred (on a page 13 px TEXT: QWidget's rules win)
function Q.progress(x, y, w, h, value)
  frame(x, y, w, h, T.FIELD, T.LINE)
  local cw = math.floor((w - 2) * value / 100 + 0.5)
  if cw > 0 then D.fill(x + 1, y + 1, cw, h - 2, T.CHOSEN) end
  local s = string.format("%d%%", value)
  local tw = Q.text_w(s)
  local tx, ty = x + (w - tw + 1) // 2, y + (h - Q.line_h() + 1) // 2
  -- the part over the chunk blends on CHOSEN, the rest on FIELD
  D.clip(x, y, x + 1 + cw - x, h, function() Q.text(tx, ty, T.TEXT, s, T.FONT, false, T.CHOSEN) end)
  D.clip(x + 1 + cw, y, w - 1 - cw, h, function() Q.text(tx, ty, T.TEXT, s, T.FONT, false, T.FIELD) end)
end

-- the back button (theme.back_button): GOLD, bold 13 px, a GOLD border, padding 3px 10px 3px 6px, arrow 18 px
-- (st.bg: what it lies on - in the translucent panel its text is smoothed in grey, as Qt does there)
function Q.back_size(s) return Q.text_w(s, 13, true) + 52, 29 end   -- QToolButton measures the advance only   -- QToolButton, text beside the icon
function Q.back(x, y, w, h, s, st)
  st = st or {}
  if st.hover then D.fill(x, y, w, h, 0xd9a44128) end
  D.rect(x, y, w, h, T.GOLD, 1)
  local tw = Q.text_w(s, 13, true)
  local gx = x + 1 + 6 + (w - 52 - tw) // 2 + 2          -- QToolButton: the icon, 1 px, the text (measured on Qt's)
  Q.draw_icon("arrow-left", T.GOLD, 18, gx, y + (h - 18) // 2, 3)
  Q.text(gx + 20, y + (h - Q.line_h(13, true)) // 2, T.GOLD, s, 13, true, st.bg or T.BG)
end

-- QScrollBar: 10 px, the handle SCROLL (hover EDGE), at least 24 px
function Q.scrollbar_v(x, y, h, pos, page, total, st)
  if total <= page then return end
  local hh = math.max(24, math.floor(h * page / total))
  local hy = y + math.floor((h - hh) * pos / (total - page))
  D.fill(x, hy, 10, hh, st and st.hover and T.EDGE or T.SCROLL)
end

-- QTabBar: tabs HEADER, padding 6px 14px, border LINE without the bottom; chosen CHOSEN with CHOSEN_EDGE
-- (px: the tabs' font, 13 px on an app page, the app's 12 px in the editor's panel)
function Q.tab_size(s, px) return Q.hint_w(s, px) + 30, Q.line_h(px) + 13 end
function Q.tab(x, y, w, h, s, st)
  st = st or {}
  local px = st.px or T.FONT
  local bg, edge, fg = T.HEADER, T.LINE, T.HEAD_TEXT
  if st.chosen then bg, edge, fg = T.CHOSEN, T.CHOSEN_EDGE, T.WHITE end
  D.fill(x, y, w, h, bg)
  D.fill(x, y, w, 1, edge)
  D.fill(x, y + 1, 1, h - 1, edge)
  D.fill(x + w - 1, y + 1, 1, h - 1, edge)
  Q.text(x + 15 + (w - 30 - Q.text_w(s, px)) // 2, y + 7, fg, s, px, false, bg)
end

-- Item views on an app page (page(): QWidget{font-size:13px; color} win over the views' 12 px and #dddddd):
-- SURFACE, border LINE, rows as Qt sizes them; chosen CHOSEN with white text, under the mouse HOVER.
Q.LIST_ROW = 20     -- a list row: the line and 20 px (padding 3px 6px and the view's own margins, measured)
Q.TREE_ROW = 8      -- a tree row: the line and 8 px
Q.TABLE_ROW = 30    -- a table row (QHeaderView's default section size), the grid line in it
Q.HEADER_H = 34     -- a table's header
function Q.list_row_h() return Q.line_h() + Q.LIST_ROW end
function Q.tree_row_h() return Q.line_h() + Q.TREE_ROW end
function Q.view_frame(x, y, w, h) frame(x, y, w, h, T.SURFACE, T.LINE) end
function Q.list_item(x, y, w, h, s, st)
  st = st or {}
  local bg = st.chosen and T.CHOSEN or (st.hover and T.HOVER or T.SURFACE)
  if bg ~= T.SURFACE then D.fill(x, y, w, h, bg) end
  Q.text(x + 9, y + (h - Q.line_h()) // 2, st.chosen and T.WHITE or T.TEXT, s, T.FONT, false, bg)
end
-- row_x: the left of the row (Qt marks the whole row, its indentation too)
function Q.tree_item(x, y, w, h, s, st, branch, row_x)
  st = st or {}
  local bg = st.chosen and T.CHOSEN or (st.hover and T.HOVER or T.SURFACE)
  row_x = row_x or x
  if bg ~= T.SURFACE then D.fill(row_x, y, x + w - row_x, h, bg) end
  Q.text(x + 9, y + (h - Q.line_h() + 1) // 2, st.chosen and T.WHITE or T.TEXT, s, T.FONT, false, bg)
  if branch ~= nil then   -- the arrow in the indentation before the item
    local name = branch and "branch_open" or "branch_closed"
    local img = part_img(name .. (st.chosen and "_chosen" or (st.hover and "_hover" or "")))   -- (ClearType on it)
    local p = PARTS[name]
    if img then D.image(img.id, x - p[3], y + (h - p[4]) // 2, img.w, img.h) end   -- (a style primitive: odd pixel up)
  end
end
function Q.table_cell(x, y, w, h, s, st)
  st = st or {}
  local bg = st.chosen and T.CHOSEN or T.SURFACE
  if bg ~= T.SURFACE then D.fill(x, y, w, h, bg) end
  Q.text(x + 11, y + (h - Q.line_h()) // 2, st.chosen and T.WHITE or T.TEXT, s, T.FONT, false, bg)
  D.fill(x + w, y, 1, h + 1, T.LINE)        -- the grid: right and bottom
  D.fill(x, y + h, w, 1, T.LINE)
end
-- QHeaderView::section: HEADER, #bbbbbb, 11 px, padding 4px 8px, lines LINE right and below; the text centred
function Q.header(x, y, w, h, s, bold)
  if bold == nil then bold = true end           -- (a section of a column with a chosen cell: Qt highlights it)
  D.fill(x, y, w, h, T.HEADER)
  D.fill(x, y + h - 1, w, 1, T.LINE)
  D.fill(x + w - 1, y, 1, h, T.LINE)
  local tw = Q.text_w(s, T.FONT_SMALL, true)   -- (centred by its bold width: "Name" 31, 29 normal)
  Q.text(x + 8 + (w - 17 - tw) // 2, y + (h - Q.line_h(T.FONT_SMALL)) // 2, T.HEAD_TEXT, s, T.FONT_SMALL, bold, T.HEADER)
end

-- a QTreeView's header section: its text at the left (AlignLeft | AlignVCenter), not bold
function Q.header_left(x, y, w, h, s)
  D.fill(x, y, w, h, T.HEADER)
  D.fill(x, y + h - 1, w, 1, T.LINE)
  D.fill(x + w - 1, y, 1, h, T.LINE)
  Q.text(x + 8, y + (h - Q.line_h(T.FONT_SMALL)) // 2, T.HEAD_TEXT, s, T.FONT_SMALL, false, T.HEADER)
end

-- QMenu: SURFACE, border EDGE, 12 px; an item 4px 14px, chosen CHOSEN, white; disabled grey; a separator LINE
function Q.menu_item_h() return Q.line_h(T.FONT_LIST) + 8 end
function Q.menu_size(items)
  local w = 0
  local h = 2
  for _, it in ipairs(items) do
    if it == "-" then h = h + 7 else
      w = math.max(w, Q.text_w(it.text or it, T.FONT_LIST))
      h = h + Q.menu_item_h()
    end
  end
  return w + 28 + 2, h
end
function Q.menu(x, y, w, h, items, active)
  frame(x, y, w, h, T.SURFACE, T.EDGE)
  local iy = y + 1
  for i, it in ipairs(items) do
    if it == "-" then
      D.fill(x + 1, iy + 3, w - 2, 1, T.LINE)
      iy = iy + 7
    else
      local ih = Q.menu_item_h()
      local bg, fg = T.SURFACE, (0xdddddd << 8) | 0xff
      if i == active and not it.disabled then bg, fg = T.CHOSEN, T.WHITE; D.fill(x + 1, iy, w - 2, ih, bg) end
      if it.disabled then fg = T.DISABLED_TEXT end
      Q.text(x + 1 + 14, iy + 4, fg, it.text or it, T.FONT_LIST, false, bg)
      iy = iy + ih
    end
  end
end

return Q
