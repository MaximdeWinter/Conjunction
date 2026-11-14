-- QPlainTextEdit as the theme shows it (QPlainTextEdit{color BRIGHT; background FIELD; border 1px EDGE; padding 5px},
-- 13 px): the text in paragraphs, each set into the width as QTextLayout does (WrapAtWordBoundaryOrAnywhere,
-- textlayout.lua), the document's margin 4, lines 17 high; scrolled a line at a time (the bar's value is the first
-- line shown, its page the lines that fit counted from the end); the caret inverted as Qt draws it; the selection
-- CHOSEN with white text. Its editing model is QLineEdit's (lineedit.lua: words, undo steps) on the whole text, "\n"
-- between paragraphs; Up / Down keep the x the caret had, Home / End go to the line's ends, Ctrl+Home / End to the
-- text's, Page Up / Down a page of lines, Enter starts a paragraph, Tab is a tab.
--   local changed, text = PT.edit(id, x, y, w, h, text, {placeholder = "...", hit = fn, tip = key, readonly = true})
--   (readonly: setReadOnly - no typing; moving, selecting, copying stay)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local LE = require("conjunction.ui.lineedit")
local TL = require("conjunction.ui.textlayout")
local IV = require("conjunction.ui.itemview")
local SBAR = require("conjunction.ui.scrollbar")
local D = w3.ui.draw
local PT = {}

PT.PAD = 5
PT.MARGIN = 4                 -- QTextDocument::documentMargin
PT.LINE = 17

-- the visual lines of the text at width tw: {start (0-based position), n (letters on it), s (its text)}
local function lines_of(chars, tw)
  local out = {}
  local pstart = 0
  local i = 1
  local n = #chars
  while true do
    local j = i
    while j <= n and chars[j] ~= "\n" do j = j + 1 end
    local para = table.concat(chars, "", i, j - 1)
    for _, l in ipairs(TL.lines(para, T.FONT, false, tw, "word_any")) do
      local k = l.length + l.trailing
      local s = table.concat(chars, "", pstart + l.from, pstart + l.from + k - 1)
      out[#out + 1] = {start = pstart + l.from - 1, n = k, s = s, para_end = false}
    end
    out[#out].para_end = true
    if j > n then break end
    pstart = j
    i = j + 1
  end
  return out
end

-- the line a position is on (at a wrap: the next line's start)
local function line_at(lines, pos)
  for k, l in ipairs(lines) do
    if pos >= l.start and (pos < l.start + l.n or (l.para_end and pos == l.start + l.n)) then return k end
  end
  return #lines
end
local function x_of(l, pos)
  local offs = w3.ui.text_offsets(l.s, T.FONT)
  return offs[math.max(0, math.min(l.n, pos - l.start)) + 1]
end
local function pos_at_x(l, x)
  local offs = w3.ui.text_offsets(l.s, T.FONT)
  local best, bd = 0, math.huge
  local last = l.para_end and l.n or math.max(0, l.n - 1)    -- (a wrapped line's end is the next line's start)
  for i = 0, last do
    local d = math.abs(offs[i + 1] - x)
    if d < bd then best, bd = i, d end
  end
  return l.start + best
end

-- how many visual lines the text has at a text width (the document's, its margins out)
function PT.count_lines(text, tw)
  local chars = {}
  for _, c in utf8.codes(text or "") do chars[#chars + 1] = utf8.char(c) end
  return #lines_of(chars, tw)
end

function PT.state(id) return CT.state(id) end

-- QTextCursor's words: as QLineEdit's inside a paragraph, a paragraph's end and start each a stop of their own
local function word_left(e, pos)
  local c = e.chars
  if pos > 0 and c[pos] == "\n" then return pos - 1 end
  local i = pos
  while i > 0 and c[i] ~= "\n" and c[i]:match("^%s$") do i = i - 1 end
  if i == 0 or c[i] == "\n" then return i end
  local w = e:word_left(i)
  for k = i, w + 1, -1 do if c[k] == "\n" then return k end end
  return w
end
local function word_right(e, pos)
  local c = e.chars
  if c[pos + 1] == "\n" then return pos + 1 end
  local w = e:word_right(pos)
  for k = pos + 1, w do if c[k] == "\n" then return k - 1 end end
  return w
end
-- one key as QPlainTextEdit takes it (the ones its model has to know of beyond QLineEdit's)
function PT.key(e, name, ctrl, shift)
  local a, b = e:sel()
  if (name == "LeftArrow" or name == "RightArrow") and a and not shift and not ctrl then
    e:move(name == "LeftArrow" and a or b, false)       -- (a selection: to its start or its end)
  elseif (name == "LeftArrow" or name == "RightArrow") and ctrl then
    e:move(name == "LeftArrow" and word_left(e, e.cur) or word_right(e, e.cur), shift)
  elseif name == "Backspace" and ctrl and not a then
    if e.cur > 0 then e:begin("delete") e:remove(word_left(e, e.cur), e.cur) end
  elseif name == "Delete" and ctrl and not a then
    if e.cur < #e.chars then e:begin("delete") e:remove(e.cur, word_right(e, e.cur)) end
  elseif name == "Enter" then                            -- (a step of its own in the undo)
    e.kind = nil
    e:insert("\n")
    e.kind = nil
  else
    e:key(name, ctrl, shift)
  end
end

function PT.edit(id, x, y, w, h, text, opts)
  opts = opts or {}
  local entered = false
  text = text or ""
  local s = CT.state(id)
  if not s.e or s.e:text() ~= text then s.e = LE.new(text) s.e.cur = 0 s.top = 0 end
  local e = s.e
  s.bar = s.bar or IV.bar(1, 0, 0)
  local vx, vy = x + 1 + PT.PAD, y + 1 + PT.PAD
  local vw, vh = w - 2 - 2 * PT.PAD, h - 2 - 2 * PT.PAD
  local fit = math.max(1, (vh - PT.MARGIN) // PT.LINE)
  local tw = vw - 2 * PT.MARGIN
  local lines = lines_of(e.chars, tw)
  local bar = #lines > fit
  if bar then
    tw = vw - 10 - 2 * PT.MARGIN
    lines = lines_of(e.chars, tw)
  end
  local function clamp_top()
    s.bar.page = fit
    IV.range(s.bar, math.max(0, #lines - fit))
    s.top = math.max(0, math.min(s.top or 0, s.bar.max))
    s.bar.value = s.top
  end
  clamp_top()
  local tx0 = vx + PT.MARGIN
  local ty0 = vy + PT.MARGIN
  local function pos_at(mx, my)
    local k = math.max(1, math.min(#lines, s.top + 1 + (my - ty0) // PT.LINE))
    return pos_at_x(lines[k], mx - tx0)
  end

  -- the mouse
  -- (as every control's: nothing under an open drop-down list or a window over it - MaximdeWinter 14.11.: a click on the
  -- Starts list's entry went on into the description under it)
  local hitf = opts.hit or CT.hit_box
  local _, hovered = hitf(id, {x = x, y = y, w = w - (bar and 10 + 1 + PT.PAD or 0), h = h})
  if hovered then w3.ui.cursor("text") end
  if hovered and opts.tip then CT.tip(id, opts.tip) end
  local mx, my, wheel = w3.ui.mouse()
  local ctrl, shift = w3.ui.mods()
  if hovered and wheel and wheel ~= 0 then
    s.top = s.top - (wheel > 0 and 3 or -3)
    clamp_top()
  end
  if w3.ui.mouse_clicked(1) and hovered then
    CT.text_press = true
    CT.set_focus(id)
    local p = pos_at(mx, my)
    if w3.ui.mouse_double(1) then e:select_word(p) else e:move(p, shift) end
    s.dragging = true
    s.blink0 = w3.ui.time()
    s.want_x = nil
  end
  if s.dragging then
    if w3.ui.mouse_down(1) then
      local p = pos_at(mx, my)
      if p ~= e.cur then e:move(p, true) end
    else s.dragging = false end
  end

  -- the keys
  local focused = CT.focus == id
  local changed = false
  local moved_v = false
  if focused then
    w3.ui.want_text()
    s.blink0 = s.blink0 or w3.ui.time()
    local before = e:text()
    local typed = opts.readonly and "" or w3.ui.chars()
    if typed ~= "" and not ctrl then e:insert(typed) s.blink0 = w3.ui.time() s.want_x = nil end
    local function vmove(k)
      local cl = line_at(lines, e.cur)
      local nl = math.max(1, math.min(#lines, cl + k))
      if s.want_x == nil then s.want_x = x_of(lines[cl], e.cur) end
      local to
      if nl == cl then to = e.cur                           -- (above the first line or below the last: it stays)
      else to = pos_at_x(lines[nl], s.want_x) end
      local wx = s.want_x
      e:move(to, shift)
      s.want_x = wx
      moved_v = true
    end
    for _, k in ipairs(opts.readonly and {"LeftArrow", "RightArrow"} or {"LeftArrow", "RightArrow", "Backspace", "Delete"}) do
      if w3.ui.pressed(k, true) then PT.key(e, k, ctrl, shift) s.blink0 = w3.ui.time() s.want_x = nil end
    end
    local page = math.max(1, vh // PT.LINE)            -- (pageUpDown: the lines the viewport's height holds)
    if w3.ui.pressed("UpArrow", true) then vmove(-1) s.blink0 = w3.ui.time() end
    if w3.ui.pressed("DownArrow", true) then vmove(1) s.blink0 = w3.ui.time() end
    if w3.ui.pressed("PageUp", true) then vmove(-page) s.blink0 = w3.ui.time() end
    if w3.ui.pressed("PageDown", true) then vmove(page) s.blink0 = w3.ui.time() end
    if w3.ui.pressed("Home", true) then
      local l = lines[line_at(lines, e.cur)]
      e:move(ctrl and 0 or l.start, shift) s.want_x = nil
    end
    if w3.ui.pressed("End", true) then
      local l = lines[line_at(lines, e.cur)]
      local endp = l.para_end and (l.start + l.n) or (l.start + l.n - 1)
      e:move(ctrl and #e.chars or endp, shift) s.want_x = nil
    end
    -- (opts.on_enter: Enter ends the text instead - dialogue_view.AutoText, one line of speech; opts.tab_focus: Tab
    -- leaves it - setTabChangesFocus)
    if not opts.readonly and (w3.ui.pressed("Enter", true) or w3.ui.pressed("KeypadEnter", true)) then
      if opts.on_enter then entered = true else PT.key(e, "Enter") s.want_x = nil end
    end
    if not opts.readonly and w3.ui.pressed("Tab", true) and not ctrl and not opts.tab_focus then e:insert("\t") s.want_x = nil end
    if ctrl then
      for _, k in ipairs(opts.readonly and {"A"} or {"A", "Z", "Y"}) do if w3.ui.pressed(k, true) then e:key(k, true, shift) end end
      if w3.ui.pressed("C") or w3.ui.pressed("X") then
        local sel = e:selected()
        if sel ~= "" then
          w3.ui.clipboard((sel:gsub("\n", "\r\n")))
          if w3.ui.pressed("X") and not opts.readonly then e:backspace(false) end
        end
      end
      if w3.ui.pressed("V") and not opts.readonly then
        local clip = w3.ui.clipboard():gsub("\r\n", "\n"):gsub("\r", "\n")
        if clip ~= "" then e:insert(clip) end
      end
    end
    changed = e:text() ~= before
    if changed or moved_v or typed ~= "" then
      lines = lines_of(e.chars, tw)
    end
    -- (ensureCursorVisible: the caret's line inside the page)
    local cl = line_at(lines, e.cur) - 1
    if changed or moved_v or w3.ui.pressed("LeftArrow", true) or w3.ui.pressed("RightArrow", true) or
       w3.ui.pressed("Home", true) or w3.ui.pressed("End", true) then
      if cl < s.top then s.top = cl elseif cl >= s.top + fit then s.top = cl - fit + 1 end
    end
    clamp_top()
  end
  text = e:text()

  -- drawing
  -- (opts.look: another sheet's colours - {bg, fg, edge, edge_focus}; the theme's otherwise)
  local lk = opts.look or {}
  local BG, FG = lk.bg or T.FIELD, lk.fg or T.BRIGHT
  Q.frame(x, y, w, h, BG, (focused and opts.focus_edge ~= false) and (lk.edge_focus or T.EDGE_HOVER) or (lk.edge or T.EDGE))
  local cw = vw - (bar and 10 or 0)
  D.clip(vx, vy, cw, vh, function()
    if text == "" then
      if opts.placeholder then
        local ph = TL.wrap(opts.placeholder, T.FONT, false, tw, "word_any")
        for k, l in ipairs(ph) do
          Q.text(tx0, ty0 + (k - 1) * PT.LINE, (FG & 0xffffff00) | 0x80, l.s, T.FONT, false, BG)
        end
      end
    else
      local a, b = e:sel()
      for k = s.top + 1, math.min(#lines, s.top + fit + 1) do
        local l = lines[k]
        local ly = ty0 + (k - 1 - s.top) * PT.LINE
        Q.text(tx0, ly, FG, l.s, T.FONT, false, BG)
        if focused and a and b > l.start and a < l.start + l.n + (l.para_end and 1 or 0) then
          local offs = w3.ui.text_offsets(l.s, T.FONT)
          local sa = math.max(a, l.start) - l.start
          local sb = math.min(b, l.start + l.n) - l.start
          local sx, ex = tx0 + offs[sa + 1], tx0 + offs[sb + 1]
          if b > l.start + l.n and l.para_end then ex = tx0 + tw end      -- (a selected paragraph end: to the edge)
          D.fill(sx, ly, ex - sx, PT.LINE, T.CHOSEN)
          D.clip(sx, ly, ex - sx, PT.LINE, function() Q.text(tx0, ly, T.WHITE, l.s, T.FONT, false, T.CHOSEN) end)
        end
      end
    end
    if focused then
      local period = w3.ui.caret_ms() / 1000
      local on = period <= 0 or ((w3.ui.time() - (s.blink0 or 0)) % (2 * period)) < period
      local cl = line_at(lines, e.cur)
      if on and cl - 1 >= s.top and cl - 1 < s.top + fit then
        D.invert(tx0 + x_of(lines[cl], e.cur), ty0 + (cl - 1 - s.top) * PT.LINE, 1, PT.LINE)
      end
    end
  end)
  if bar then
    SBAR.draw(s, id .. ".vbar", s.bar, {x = vx + cw, y = vy, w = 10, h = vh}, "v", hitf, function(b) s.top = b.value end)
  end
  if entered then opts.on_enter(text) end
  return changed, text
end

return PT
