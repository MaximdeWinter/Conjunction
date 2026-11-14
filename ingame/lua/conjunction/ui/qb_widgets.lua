-- The Quest tab's controls as questboard.py makes them (its STYLE over theme.py's), each a leaf of ui/qw.lua with
-- Qt's size hint and policy, drawn and clicked here. The ids keep each control's state from frame to frame.
--   local B = require("conjunction.ui.qb_widgets")
--   B.field("radius"), B.line(id, text, placeholder, done), B.menu(id, text, entries, current, fn), B.chip(...),
--   B.button(id, text, fn, name), B.icon(id, icon, fn), B.spin(id, value, lo, hi, done), B.combo(id, items, i, fn),
--   B.check(id, text, on, fn), B.row(widgets, stretch_last), B.missing(text), B.num(n), B.kind(id, text, fn)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local IM = require("conjunction.ui.inline_menu")
local W = require("conjunction.ui.qw")
local D = w3.ui.draw
local B = {}

local function hex(s, a) return (tonumber(s:sub(2), 16) << 8) | (a or 255) end
B.C = {
  field = hex("#999999"), num = hex("#f0f0f0"), kind = hex("#9a9a9a"), kind_hover = hex("#dddddd"),
  kind_hover_edge = hex("#666666"),
  menu_fg = hex("#dddddd"), menu_bg = hex("#262629"), menu_edge = hex("#555555"), menu_hover = hex("#aaaaaa"),
  chip_fg = hex("#cfcfcf"), chip_bg = hex("#262629"), chip_edge = hex("#555555"), chip_on_fg = hex("#ffffff"),
  chip_on_bg = hex("#4b4b50"), chip_on_edge = hex("#c8c8c8"),
  plus_fg = hex("#9a9a9a"), plus_edge = hex("#444444"), plus_hover_fg = hex("#eeeeee"), plus_hover_edge = hex("#888888"),
  target_fg = hex("#eeeeee"), target_bg = hex("#262629"), target_edge = hex("#555555"), target_hover = hex("#999999"),
  empty_fg = hex("#aaaaaa"), empty_bg = hex("#1f1f22"), empty_edge = hex("#666666"),
  missing = hex("#e57a7a"), unit = hex("#9a9a9a"), list = hex("#1d1d20"), list_edge = hex("#444444"),
  list_hot = hex("#34343a"),
  card = hex("#26262a"), card_edge = hex("#3c3c42"), area = hex("#1e1e1e"),
}
local C = B.C
B.bg = C.area                 -- what the controls lie on (text blends with it): set by the card being drawn

-- a QLabel's text: in the middle of its box, cut to it (a letter's fringe past the box is not drawn)
local function vtext(r, colour, s, px, bold, bg)
  D.clip(r.x, r.y, r.w, r.h, function()
    Q.text(r.x, r.y + Q.vcenter(r.h, Q.line_h(px, bold)), colour, s, px, bold, bg or B.bg)
  end)
end

-- a dashed 1 px frame as Qt's style sheet paints border-style: dashed (qcssutil.cpp qDrawBorder: a 1 px dashed edge
-- is a DotLine, FlatCap, antialiased, on the pixel edge - bottom, right, left, top), drawn by Qt once per size
local dashed_pics = {}
function B.dashed(x, y, w, h, colour)
  local key = string.format("%dx%d_%08x", w, h, colour)
  local pic = dashed_pics[key]
  if pic == nil then
    pic = false
    local c = string.format("%08x", colour)
    local cmds = table.concat({
      "aa 1", "pen " .. c .. " 1 0 64 3",
      string.format("linef 0 %d %d %d", h - 1, w - 1, h - 1),
      string.format("linef %d 0 %d %d", w - 1, w - 1, h - 1),
      string.format("linef 0 0 0 %d", h - 1),
      string.format("linef 0 0 %d 0", w - 1),
    }, "\n")
    local file = (os.getenv("TEMP") or ".") .. "\\cj_dashed_" .. key .. ".png"
    if pcall(w3.plugin.cj_qt_paint, file, tostring(w), tostring(h), cmds) then
      local id, iw, ih = w3.ui.image_load(file)
      if id then pic = {id, iw, ih} end
    end
    dashed_pics[key] = pic
  end
  if pic then D.image(pic[1], x, y, pic[2], pic[3]) end
end

-- --- labels
-- QLabel#field: 12 px #999 (preferred both ways: in a row as high as the row, its text in the middle)
function B.field(text)
  return W.leaf{w = Q.hint_w(text, 12), h = Q.line_h(12), draw = function(_, r) vtext(r, C.field, text, 12) end}
end
-- a QLabel with its own colour and size (the unit after a number: UNIT_STYLE #9a9a9a 12 px)
function B.label(text, colour, px, bold)
  px = px or 12
  return W.leaf{w = Q.hint_w(text, px, bold), h = Q.line_h(px, bold),
                draw = function(_, r) vtext(r, colour or C.field, text, px, bold) end}
end
-- a QLabel of rich text with word wrap: runs {{text, colour}} (a span's colour; &nbsp; as U+00A0), px; its hint as
-- QLabelPrivate::sizeForWidth(-1) has it (80 average letters, half, a quarter), its minimum the widest word, its
-- height for a width the wrapped lines
function B.rich(runs, px, wrap)
  px = px or 12
  -- the words, each letter with its colour (runs of spaces between them collapse, as HTML's)
  local words, cur = {}, nil
  for _, run in ipairs(runs) do
    for _, c in utf8.codes(run[1]) do
      local ch = utf8.char(c)
      if ch == " " or ch == "\t" or ch == "\n" then
        cur = nil
      else
        if not cur then cur = {text = "", parts = {}} words[#words + 1] = cur end
        local last = cur.parts[#cur.parts]
        if last and last[2] == run[2] then last[1] = last[1] .. ch else cur.parts[#cur.parts + 1] = {ch, run[2]} end
        cur.text = cur.text .. ch
      end
    end
  end
  local function lines_for(width)
    local lines, line = {}, nil
    for _, w in ipairs(words) do
      if line and Q.text_w(line.text .. " " .. w.text, px) > width then
        lines[#lines + 1] = line
        line = nil
      end
      if not line then
        line = {text = w.text, words = {w}}
      else
        line.text = line.text .. " " .. w.text
        line.words[#line.words + 1] = w
      end
    end
    if line then lines[#lines + 1] = line end
    return lines
  end
  local lh = Q.line_h(px)
  local function box(width)
    local ls = lines_for(width)
    local bw = 0
    for _, l in ipairs(ls) do bw = math.max(bw, Q.text_w(l.text, px)) end
    return bw, math.max(1, #ls) * lh
  end
  local hw, hh, widest
  if wrap then
    local avg = ({[11] = 5, [12] = 6, [13] = 6})[px] or 6
    local w = avg * 80
    hw, hh = box(w)
    if hh < 4 * lh and hw > w // 2 then hw, hh = box(w // 2) end
    if hh < 2 * lh and hw > w // 4 then hw, hh = box(w // 4) end
    widest = 0
    for _, wd in ipairs(words) do widest = math.max(widest, Q.text_w(wd.text, px)) end
  else
    hw, hh = box(1e9)
    widest = hw
  end
  return W.leaf{w = hw, h = hh, min_w = widest, min_h = lh, hfw = wrap and function(width) return select(2, box(width)) end or nil,
                draw = function(_, r)
    local ls = lines_for(wrap and r.w or 1e9)
    local y = r.y + (wrap and 0 or Q.vcenter(r.h, lh))
    for _, l in ipairs(ls) do
      -- each colour's piece where the whole line puts it (its advance from the line's start)
      local prefix = ""
      for wi, w in ipairs(l.words) do
        if wi > 1 then prefix = prefix .. " " end
        for _, part in ipairs(w.parts) do
          Q.text(r.x + Q.text_w(prefix, px), y, part[2], part[1], px, false, B.bg)
          prefix = prefix .. part[1]
        end
      end
      y = y + lh
    end
  end}
end

-- QLabel#num: the goal's number, bold 15 px #f0f0f0, at least 22 wide
function B.num(n)
  local s = tostring(n)
  return W.leaf{w = math.max(22, Q.hint_w(s, 15, true)), h = Q.line_h(15, true), min_w = 22,
                draw = function(_, r) vtext(r, C.num, s, 15, true) end}
end

-- --- buttons
local function hit(id, r) return CT.hit_box(id, r) end

-- QToolButton#menu (#chip: its own look, checked CHOSEN): the text in the middle, 12 px; a ··· menu: the ellipsis
function B.tool(id, text, opts)
  opts = opts or {}
  local icon = opts.icon
  local w = icon and (16 + 21) or (Q.hint_w(text, 12) + 27)
  local h = opts.plus and 27 or 25                    -- (#plus: padding 3px 8px)
  return W.leaf{w = w, h = h, hpol = "preferred", vpol = "fixed", draw = function(_, r)
    local clicked, hovered = hit(id, r)
    if opts.plus then                                 -- QToolButton#plus: dashed #444, #9a9a9a (#eee on #888)
      local fg, edge = C.plus_fg, C.plus_edge
      if hovered then fg, edge = C.plus_hover_fg, C.plus_hover_edge end
      B.dashed(r.x, r.y, r.w, r.h, edge)
      local tw = Q.text_w(text, 12)
      Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(12)), fg, text, 12, false, B.bg)
      if hovered and opts.tip then CT.tip(id, opts.tip) end
      if clicked and opts.on then opts.on(r) end
      return
    end
    local bg, edge, fg = C.menu_bg, C.menu_edge, opts.colour or C.menu_fg
    if opts.chip then
      bg, edge, fg = C.chip_bg, C.chip_edge, C.chip_fg
      if opts.checked then bg, edge, fg = C.chip_on_bg, C.chip_on_edge, C.chip_on_fg end
    elseif hovered then
      edge = C.menu_hover
    end
    if opts.edge then edge = opts.edge end
    if opts.dashed then
      D.fill(r.x, r.y, r.w, r.h, bg)
      B.dashed(r.x, r.y, r.w, r.h, edge)
    else
      Q.frame(r.x, r.y, r.w, r.h, bg, edge)
    end
    if icon then
      Q.draw_icon(icon, 0xcfcfcfff, 16, r.x + (r.w - 16) // 2, r.y + (r.h - 16) // 2)
    else
      local tw = Q.text_w(text, 12, opts.bold)
      Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(12, opts.bold)), fg, text, 12, opts.bold, bg)
    end
    if hovered and opts.tip then CT.tip(id, opts.tip) end
    if clicked and opts.on then opts.on(r) end
  end}
end

-- _menu_button: a QToolButton#menu that opens a flat list (entries {key, label}; the current one ticked)
function B.menu(id, text, entries, current, fn, opts)
  opts = opts or {}
  local o = {tip = opts.tip, colour = opts.colour, edge = opts.colour, bold = opts.bold, plus = opts.plus,
             dashed = opts.dashed}
  if opts.dashed then o.colour = 0xaaaaaaff end         -- (nothing chosen yet: border-style dashed, #aaa)
  if text == "···" then o.icon = "ellipsis" end
  o.on = function(r)
    if IM.is_open(id) then IM.close() return end
    local list = {}
    for _, e in ipairs(entries) do
      local k = e[1]
      list[#list + 1] = {text = e[2], checked = k == current, action = function() fn(k) end}
    end
    IM.open(id, r, list, B.window, {bg = B.list_bg})
  end
  return B.tool(id, text, o)
end

-- _chip: a checkable QToolButton#chip
function B.chip(id, text, checked, fn, opts)
  opts = opts or {}
  return B.tool(id, text, {chip = true, checked = checked, tip = opts.tip, on = function() fn() end})
end

-- QToolButton#kindmenu: the step's kind, bold 11 px #9a9a9a, a menu of the other kinds of its block
function B.kind(id, text, entries, current, fn, opts)
  opts = opts or {}
  return W.leaf{w = Q.hint_w(text, 11, true) + 19, h = 22, vpol = "fixed", draw = function(_, r)
    local clicked, hovered = hit(id, r)
    local fg = hovered and C.kind_hover or C.kind
    if hovered then D.rect(r.x, r.y, r.w, r.h, C.kind_hover_edge, 1) end
    local tw = Q.text_w(text, 11, true)
    Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(11, true)), fg, text, 11, true, B.bg)
    if hovered and opts.tip then CT.tip(id, opts.tip) end
    if clicked then
      if IM.is_open(id) then IM.close() return end
      local list = {}
      for _, e in ipairs(entries) do
        local k = e[1]
        list[#list + 1] = {text = e[2], checked = k == current, action = function() fn(k) end}
      end
      IM.open(id, r, list, B.window, {bg = B.list_bg})
    end
  end}
end

-- an icon button (icons.icon_button): no border, padding 2, 16 px; under the mouse a light film
function B.icon(id, icon, fn, opts)
  opts = opts or {}
  return W.leaf{w = 23, h = 23, vpol = "fixed", draw = function(_, r)
    local clicked, hovered = hit(id, r)
    if hovered then D.fill(r.x, r.y, r.w, r.h, 0xffffff14) end
    Q.draw_icon(icon, hovered and 0xffffffff or 0xcfcfcfff, 16, r.x + (r.w - 16) // 2, r.y + (r.h - 16) // 2)
    if hovered and opts.tip then CT.tip(id, opts.tip) end
    if clicked and fn then fn() end
  end}
end

-- _button: a QPushButton of the board's sheet - #small (2px 8px), #plus (dashed, 3px), #target (bold, 3px 10px,
-- left), #target_empty (dashed #666, the octagon before the text, left)
function B.button(id, text, fn, name, opts)
  opts = opts or {}
  name = name or "small"
  local w, h
  if name == "plus" then w, h = Q.hint_w(text, 12) + 8, 24
  elseif name == "target" then w, h = Q.hint_w(text, 12, true) + 22 + (opts.icon and 20 or 0), 24
  elseif name == "target_empty" then w, h = Q.hint_w(text, 12) + ((opts.no_icon and not opts.icon) and 24 or 42), 24
  elseif name == "doit" then w, h = Q.hint_w(text, 12, true) + 12, Q.line_h(12, true) + 6
  elseif name == "entry" then w, h = Q.hint_w(text, 12) + 12, Q.line_h(12) + 6
  else w, h = Q.hint_w(text, 12) + (opts.icon and 38 or 18), 22 end
  return W.leaf{w = w, h = h, hpol = "minimum", vpol = "fixed", draw = function(_, r)
    local clicked, hovered, held = hit(id, r)
    if name == "plus" then
      local fg, edge = C.plus_fg, C.plus_edge
      if hovered then fg, edge = C.plus_hover_fg, C.plus_hover_edge end
      B.dashed(r.x, r.y, r.w, r.h, edge)
      local tw = Q.text_w(text, 12)
      Q.text(r.x + (r.w - tw) // 2, r.y + Q.vcenter(r.h, Q.line_h(12)), fg, text, 12, false, B.bg)
    elseif name == "doit" or name == "entry" then
      -- (_search_list's sheet: text-align left, no border, padding 3px 6px; #doit bold white, #entry #ddd; under
      -- the mouse #34343a)
      local bg = hovered and C.list_hot or B.bg
      if hovered then D.fill(r.x, r.y, r.w, r.h, bg) end
      local bold = name == "doit"
      D.clip(r.x, r.y, r.w, r.h, function()
        Q.text(r.x + 6, r.y + 3 + Q.vcenter(r.h - 6, Q.line_h(12, bold)), bold and T.WHITE or C.menu_fg, text, 12,
               bold, bg)
      end)
    elseif name == "target" or name == "target_empty" then
      local bg, edge, fg = C.target_bg, C.target_edge, C.target_fg
      if name == "target_empty" then bg, edge, fg = C.empty_bg, C.empty_edge, C.empty_fg end
      if hovered then edge = C.target_hover end
      if opts.waiting then bg, edge, fg = T.CHOSEN, T.CHOSEN_EDGE, T.WHITE end
      if opts.missing and not opts.waiting then edge, fg = hovered and C.target_hover or C.missing, C.missing end
      if name == "target_empty" and not opts.waiting then
        D.fill(r.x, r.y, r.w, r.h, bg)
        B.dashed(r.x, r.y, r.w, r.h, edge)
      else
        Q.frame(r.x, r.y, r.w, r.h, bg, edge)
      end
      local x = r.x + 1 + 10
      if opts.icon then                         -- (its own icon: the way's spline, #ddd 14 px)
        Q.draw_icon(opts.icon, 0xddddddff, 14, x, r.y + (r.h - 14) // 2)
        x = x + 14 + 4
      elseif name == "target_empty" and not opts.no_icon then
        Q.draw_icon("octagon-alert", C.missing, 14, x, r.y + (r.h - 14) // 2)
        x = x + 14 + 4
      end
      local bold = name == "target"
      D.clip(r.x + 1 + 10, r.y + 1, math.max(0, r.w - 22), r.h - 2, function()
        Q.text(x, r.y + Q.vcenter(r.h, Q.line_h(12, bold)), fg, text, 12, bold, bg)
      end)
    else
      local bg, edge = T.BUTTON, T.EDGE
      if hovered then edge = T.EDGE_HOVER end
      if held and hovered then bg = T.CHOSEN end
      Q.frame(r.x, r.y, r.w, r.h, bg, edge)
      local tw = Q.text_w(text, 12)
      local block = (opts.icon and (tw > 0 and 20 or 16) or 0) + tw     -- (an icon alone: in the middle)
      local x = r.x + 1 + 8 + (r.w - 18 - block) // 2
      if opts.icon then
        Q.draw_icon(opts.icon, opts.icon_colour or 0xcfcfcfff, 16, x, r.y + (r.h - 16) // 2)
        x = x + (tw > 0 and 18 or 16)
      end
      Q.text(x, r.y + Q.vcenter(r.h, Q.line_h(12)), T.BUTTON_TEXT, text, 12, false, bg)
    end
    if hovered and opts.tip then CT.tip(id, opts.tip) end
    if clicked and fn then fn() end
  end}
end

-- --- fields
-- QLineEdit (theme: 13 px, padding 5): Expanding, 17 letters x wide; done(text) when it is left or Enter
-- the chapter's title (QLineEdit{color:#f0f0f0;font:bold 15px;background:transparent;border:none}: the theme's
-- padding stays - 4 here and no border is the same room)
B.CHAPTER_STYLE = setmetatable({bg = 0x1b1b1fff, edge = false, edge_focus = false, fg = 0xf0f0f0ff, px = 15, bold = true,
                                pad = {4, 4, 4, 4}}, {__index = CT.EDIT_STYLE})
-- fields with something typed and the focus, this frame: id -> {done, text, state, frame}; one not drawn again is
-- given its text at the frame's end (B.flush_stale) - its card went before it lost the focus
B.pending, B.frame_no = {}, 0
local function keep_pending(id, st, done, focused)
  if focused and st.typed ~= nil and done then
    B.pending[id] = {done = done, text = st.typed, state = st, frame = B.frame_no}
  else
    B.pending[id] = nil
  end
end
function B.flush_stale()
  for id, p in pairs(B.pending) do
    if p.frame < B.frame_no then
      B.pending[id] = nil
      p.state.typed = nil
      if CT.focus == id then CT.set_focus(nil) end
      pcall(p.done, p.text)
    end
  end
  B.frame_no = B.frame_no + 1
end

function B.line(id, text, placeholder, done, opts)
  opts = opts or {}
  local style = opts.style == "chapter" and B.CHAPTER_STYLE or B.EDIT_STYLE
  local eh = CT.edit_h(style)
  local hint = opts.style == "chapter" and (17 * Q.text_w("x", 15, true) + 14) or (17 * Q.text_w("x") + 16)
  return W.leaf{w = hint, h = eh, min_w = 42, hpol = "expanding", vpol = "fixed",
                fixed_w = opts.fixed_w, draw = function(_, r)
    local st = CT.state(id)
    local _, t, enter = CT.edit(id, r.x, r.y, r.w, st.typed or text,
                                {placeholder = placeholder, style = style, tip = opts.tip, h = r.h,
                                 readonly = opts.disabled})
    local typed_now = t ~= (st.typed or text)
    st.typed = t
    local focused = CT.focus == id
    -- names: a QCompleter (case-insensitive, the names holding the text) as a list under the field while typing
    if opts.names and #opts.names > 0 then
      local list_id = id .. ".complete"
      if typed_now then
        local items, low = {}, t:lower()
        for _, n in ipairs(opts.names) do
          if low ~= "" and n:lower():find(low, 1, true) then
            items[#items + 1] = {text = n, action = function()
              st.typed = nil
              if done then done(n) end
            end}
          end
        end
        if #items > 0 then IM.open(list_id, r, items, B.window or r, {bg = B.list_bg})
        elseif IM.is_open(list_id) then IM.close() end
      elseif not focused and IM.is_open(list_id) and not IM.covers(w3.ui.mouse()) then
        IM.close()
      end
    end
    if (st.had_focus and not focused) or enter then
      st.typed = nil
      if done then done(t) end
    end
    if not focused and not enter then st.typed = nil end
    st.had_focus = focused
    keep_pending(id, st, done, focused and st.typed ~= text)
  end}
end

-- a QLineEdit that keeps what is typed (a list's filter: textChanged) -> its leaf; the text: B.found(id)
function B.find(id, placeholder, opts)
  opts = opts or {}
  local style = B.EDIT_STYLE
  return W.leaf{w = 17 * Q.text_w("x") + 16, h = CT.edit_h(style), min_w = 42, hpol = "expanding", vpol = "fixed",
                draw = function(_, r)
    local st = CT.state(id)
    local _, t = CT.edit(id, r.x, r.y, r.w, st.text or "", {placeholder = placeholder, style = style, tip = opts.tip,
                                                           h = r.h})
    st.text = t
  end}
end
function B.found(id) return CT.state(id).text or "" end

-- QPlainTextEdit (theme) of a fixed height; done(text) 600 ms after the last key (the card stays)
function B.plain(id, text, placeholder, h, done, opts)
  opts = opts or {}
  local PT = require("conjunction.ui.plaintext")
  return W.leaf{w = 256, h = h, min_w = 0, hpol = "expanding", vpol = "fixed", fixed_h = h, draw = function(_, r)
    local st = CT.state(id .. ".v")
    local changed, t = PT.edit(id, r.x, r.y, r.w, r.h, st.typed or text, {placeholder = placeholder, tip = opts.tip})
    if changed then
      st.typed = t
      st.due = w3.time() + 0.6
    end
    if st.due and w3.time() >= st.due then
      st.due = nil
      local v = st.typed
      st.typed = nil
      if done then done(v) end
    end
  end}
end

-- dialogue_view.AutoText: a QPlainTextEdit#autotext (#e6e6e6 on #1d1d20, a #444 border also with the focus) as
-- high as its text (wrapped at its width: lines of 17, the document's margins, its frame, 6 more - the last block's
-- bounding rect has a margin of its own, QPlainTextDocumentLayout::blockBoundingRect); done(text) when it is left
B.AUTOTEXT = {bg = 0x1d1d20ff, fg = 0xe6e6e6ff, edge = 0x444444ff, edge_focus = 0x444444ff}
function B.autotext(id, text, placeholder, done, opts)
  opts = opts or {}
  local PT = require("conjunction.ui.plaintext")
  local function height(w)
    local st = CT.state(id .. ".v")
    local t = st.typed or text
    local tw = w - 2 * (1 + PT.PAD) - 2 * PT.MARGIN
    local n = math.max(1, t ~= "" and PT.count_lines(t, tw) or 1)
    return n * PT.LINE + 3 * PT.MARGIN + 2 * (1 + PT.PAD) + 6
  end
  -- (its height follows its width - setFixedHeight from _fit at the width it has: the layout asks hfw; its hint, a
  -- fixed one's least too, that of the text unwrapped)
  return W.leaf{w = 256, h = height(1e6), min_w = 0, hpol = "expanding", vpol = "fixed", hfw = height,
                draw = function(_, r)
    local st = CT.state(id .. ".v")
    local was = CT.focus == id
    local changed, t = PT.edit(id, r.x, r.y, r.w, r.h, st.typed or text, {placeholder = placeholder, tip = opts.tip,
                                                                          look = B.AUTOTEXT, tab_focus = true,
                                                                          on_enter = opts.enter})
    if changed then st.typed = t end
    if st.had and CT.focus ~= id and st.typed ~= nil then
      local v = st.typed
      st.typed = nil
      if done then done(v) end
    end
    st.had = CT.focus == id
    keep_pending(id, st, done, st.had)
    local _ = was
  end}
end

-- QSpinBox (theme): the widest of its range's texts (and a suffix) plus 90; done(value) as _live has it: 400 ms
-- after the last change, or at once on Enter or leaving it
function B.spin(id, value, lo, hi, done, opts)
  opts = opts or {}
  local suffix = opts.suffix or ""
  local w = math.max(Q.text_w(tostring(lo) .. suffix .. " "), Q.text_w(tostring(hi) .. suffix .. " ")) + 90
  return W.leaf{w = w, h = 35, hpol = "minimum", vpol = "fixed", draw = function(_, r)
    local st = CT.state(id)
    local _, v = CT.spin(id, r.x, r.y, st.pending or value, {min = lo, max = hi, w = r.w, fg = T.BRIGHT, tip = opts.tip,
                                                              special = opts.special})
    if v ~= (st.pending or value) then
      st.pending = v
      st.due = w3.time() + 0.4
    end
    local focused = CT.focus == id
    if st.pending ~= nil and ((st.due and w3.time() >= st.due) or (st.had_focus and not focused)) then
      local p = st.pending
      st.pending, st.due = nil, nil
      if done and p ~= value then done(p) end
    end
    st.had_focus = focused
  end}
end

-- fields.with_unit: [the field] [unit] 3 apart (Maximum, Fixed)
function B.with_unit(spin, after)
  local items = {spin}
  if after and after:match("%S") then items[#items + 1] = B.label(after:match("^%s*(.-)%s*$"), C.unit, 12) end
  return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 3}, items), {hpol = "maximum", vpol = "fixed"})
end

-- Combo (QComboBox, AdjustToContentsOnFirstShow): the widest item and 33; fn(index) when another is chosen
function B.combo(id, items, index, fn, opts)
  opts = opts or {}
  local widest = 0
  for _, t in ipairs(items) do widest = math.max(widest, Q.text_w(t)) end
  local w = opts.w or (widest + 33)
  local h = Q.line_h() + 14
  return W.leaf{w = w, h = h, hpol = "preferred", vpol = "fixed", draw = function(_, r)
    local changed, i = CT.combo(id, r.x, r.y, r.w, items, index, B.window, {h = r.h, fg = T.BRIGHT, tip = opts.tip,
                                                                          list_bg = B.list_bg})
    if changed and fn then fn(i) end
  end}
end

-- QCheckBox: 12 px (the panel's), the box and the text
function B.check(id, text, on, fn, opts)
  opts = opts or {}
  local cw, ch = Q.check_size(text, 12)
  return W.leaf{w = cw, h = ch, vpol = "fixed", draw = function(_, r)
    local changed, v = CT.check(id, r.x, r.y, text, on, {px = 12, h = r.h, tip = opts.tip, bg = B.bg,
                                                       fg = 0xffffffff})   -- (no sheet colour: the palette's white)
    if changed and fn then fn(v) end
  end}
end

-- --- rows
-- _row: a QWidget with a QHBoxLayout (0 margins, 6 apart), the last item stretched (stretch_last)
function B.row(items, stretch_last)
  if stretch_last == nil then stretch_last = true end
  if stretch_last and #items > 0 then items[#items].stretch = 1 end
  return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 6}, items))
end
-- a plain QWidget (a gap that takes the room: _row's last)
function B.gap() return W.leaf{w = 0, h = 0} end

-- _missing_row: the octagon (14 px), 5 apart, "Missing: ..." in red 12 px
function B.missing(text)
  local icon = W.leaf{w = 14, h = 14, draw = function(_, r)
    Q.draw_icon("octagon-alert", C.missing, 14, r.x + (r.w - 14) // 2, r.y + (r.h - 14) // 2)
  end}
  local note = B.label(text, C.missing, 12)
  note.stretch = 1
  return W.widget(W.hbox({margins = {0, 0, 0, 0}, spacing = 5}, {icon, note}))
end

return B
