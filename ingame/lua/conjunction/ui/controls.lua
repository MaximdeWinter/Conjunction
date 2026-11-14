-- Conjunction's controls with their behaviour, as Qt's widgets behave (ui/qt.lua draws them). Immediate mode: call a
-- control every frame inside a w3.ui window; it returns what happened this frame.
--
--   if C.button("save", x, y, "Save") then ... end
--   local changed, text, enter = C.edit("name", x, y, 180, text, {placeholder = "Quest name"})
--   local toggled, on = C.check("loot", x, y, "Loot", on)
--
-- Qt's rules kept here (each checked against the Python Conjunction):
-- * a button looks pressed while the mouse is held on it, and clicks when it is let go over it (moving off cancels)
-- * a click gives the keyboard to a control that takes it (a text field); a click on anything else keeps it where
--   it was (Qt's NoFocus buttons and panels)
-- * a text field: the caret blinks at Windows' rate and shows again at every key; the text scrolls so the caret stays
--   in view; keys as QLineEdit (arrows, Ctrl+arrows by word, Home/End, Shift to select, Backspace/Delete, Ctrl+A/C/X/V,
--   Ctrl+Z/Y); a double click selects a word, dragging selects; the selection CHOSEN with white text
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local TT = require("conjunction.ui.tooltips")
local TIPS = require("conjunction.ui.tips")
local C = {}
local D = w3.ui.draw

C.focus = nil          -- the id of the control with the keyboard
C.text_press = false   -- this frame's press was on a text field (a line edit, a spin box)
local state = {}       -- per id: what a control keeps between frames
local function st_of(id)
  local s = state[id]
  if not s then s = {} state[id] = s end
  return s
end
function C.state(id) return st_of(id) end
function C.set_focus(id) C.focus = id; if id then st_of(id).blink0 = nil end end   -- the caret starts on

local IM = require("conjunction.ui.inline_menu")
C.IM = IM
-- C.blocker(mx, my): a window over these controls there (the bar and its menus over the panel: Qt's windows of their
-- own). Asked before the item is made: ImGui gives the mouse to the first item under it, so the one beneath must not be
-- one there
C.blocker = nil
local function hit(id, x, y, w, h)
  local mx, my = w3.ui.mouse()
  if C.blocker and C.blocker(mx, my) then return 0, false, false end
  w3.ui.set_pos(x, y)
  local clicked, hovered, held = w3.ui.hit(id, w, h)
  if IM.covers(mx, my) then return 0, false, false end   -- an open drop-down list lies over it
  return clicked, hovered, held
end

-- a box that takes the mouse (an item of its own) -> clicked (a left click let go on it), hovered, held
function C.hit_box(id, r)
  local clicked, hovered, held = hit(id, r.x, r.y, r.w, r.h)
  return clicked == 1, hovered, held
end

-- the mouse over a box, without an item of its own there (a list's area for the wheel: an item over the whole list
-- would take the mouse from its rows - ImGui gives it to the first item under it)
function C.over(r)
  local mx, my = w3.ui.mouse()
  if C.blocker and C.blocker(mx, my) then return false end
  if IM.covers(mx, my) then return false end
  return w3.ui.window_hovered() and mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h
end

-- QPushButton -> clicked
function C.button(id, x, y, text, opts)
  opts = opts or {}
  local w, h = Q.button_size(text)
  w, h = opts.w or w, opts.h or h
  local clicked, hovered, held = hit(id, x, y, w, h)
  if opts.disabled then clicked, hovered, held = 0, false, false end
  Q.button(x, y, w, h, text, {hover = hovered or held, pressed = held and hovered, disabled = opts.disabled,
                              primary = opts.primary, fg = opts.fg})
  if hovered and opts.tip then C.tip(id, opts.tip) end
  return clicked == 1, w, h
end

-- QCheckBox -> toggled, value
function C.check(id, x, y, text, value, opts)
  opts = opts or {}
  local w, h = Q.check_size(text, opts.px)
  h = opts.h or h
  local clicked, hovered = hit(id, x, y, w, h)
  if opts.disabled then clicked, hovered = 0, false end
  if clicked == 1 then value = not value end
  Q.check(x, y, text, {checked = value, hover = hovered, disabled = opts.disabled, bg = opts.bg, fg = opts.fg,
                       h = opts.h, px = opts.px})
  if hovered and opts.tip then C.tip(id, opts.tip) end
  return clicked == 1, value, w, h
end

-- QRadioButton -> chosen (this one was clicked)
function C.radio(id, x, y, text, on, opts)
  opts = opts or {}
  local w, h = Q.radio_size(text, on)
  local clicked, hovered = hit(id, x, y, w, h)
  Q.radio(x, y, text, {checked = on, hover = hovered, bg = opts.bg})
  if hovered and opts.tip then C.tip(id, opts.tip) end
  return clicked == 1 and not on, w, h
end

-- --- QLineEdit (the editing model: ui/lineedit.lua, checked against Qt) ---
local LE = require("conjunction.ui.lineedit")
local KEYNAMES = {"LeftArrow", "RightArrow", "Home", "End", "Backspace", "Delete"}

-- a QLineEdit's look: theme.py's (an app page) unless opts.style says otherwise (the bar's sheet: hud.lua)
C.EDIT_STYLE = {bg = T.FIELD, edge = T.EDGE, edge_focus = T.EDGE_HOVER, fg = T.TEXT, px = T.FONT,
                pad = {5, 5, 5, 5}, sel_bg = T.CHOSEN, sel_fg = T.WHITE}
-- QLineEdit's height: the line (at least 14), its 1 px margins, the padding, the border
function C.edit_h(st)
  st = st or C.EDIT_STYLE
  return math.max(Q.line_h(st.px), 14) + 2 + st.pad[2] + st.pad[4] + 2
end

-- -> changed, text, enter (Enter pressed this frame), w, h  (opts.h: a height its layout gave it, not its own)
function C.edit(id, x, y, w, text, opts)
  opts = opts or {}
  text = text or ""
  local st = opts.style or C.EDIT_STYLE
  local pl, pt, pr, pb = st.pad[1], st.pad[2], st.pad[3], st.pad[4]
  local h = opts.h or C.edit_h(st)
  local s = st_of(id)
  if not s.e or s.e:text() ~= text then s.e = LE.new(text) end    -- set from outside: as QLineEdit.setText
  local e = s.e
  local px = st.px
  local tx0 = x + 1 + pl + 2                    -- where the text starts (border, padding, QLineEdit's 2 px)
  local vis_w = w - 2 - pl - pr - 4 - 1         -- the text's room (the cursor's pixel inside it)
  s.scroll = s.scroll or 0
  local bold = st.bold and "bold" or nil         -- (a sheet's font:bold - the inspector's item name)
  local offs = w3.ui.text_offsets(e:text(), px, bold)  -- offs[i + 1]: the x before letter i + 1 (Qt position i)
  local function pos_at(mx)
    local rel = mx - tx0 + s.scroll
    local best, bd = 0, math.huge
    for i, ox in ipairs(offs) do
      local d = math.abs(ox - rel)
      if d < bd then best, bd = i - 1, d end
    end
    return best
  end

  local clicked, hovered, held = hit(id, x, y, w, h)
  if hovered or held then w3.ui.cursor("text") end
  if hovered and opts.tip then C.tip(id, opts.tip) end
  local changed, enter = false, false
  local mx = w3.ui.mouse()
  local ctrl, shift = w3.ui.mods()
  if w3.ui.mouse_clicked(1) and hovered then
    C.text_press = true                          -- (a press on a text field: the typing goes on - the panel asks)
    C.set_focus(id)
    local pos = pos_at(mx)
    if w3.ui.mouse_double(1) then e:select_word(pos)
    else e:move(pos, shift) end
    s.dragging = true
    s.blink0 = w3.ui.time()
  end
  if s.dragging then
    if w3.ui.mouse_down(1) then
      local pos = pos_at(mx)
      if pos ~= e.cur then e:move(pos, true) end
    else
      s.dragging = false
    end
  end

  local focused = C.focus == id
  local ro = opts.readonly                        -- (setReadOnly: no typing; moving, selecting, copying stay)
  if focused then
    w3.ui.want_text()
    s.blink0 = s.blink0 or w3.ui.time()
    local before = e:text()
    local typed = w3.ui.chars()
    if typed ~= "" and not ctrl and not ro then e:insert(typed) end
    for _, k in ipairs(KEYNAMES) do
      if w3.ui.pressed(k, true) and not (ro and (k == "Backspace" or k == "Delete")) then
        e:key(k, ctrl, shift)
        s.blink0 = w3.ui.time()
      end
    end
    if ctrl then
      for _, k in ipairs({"A", "Z", "Y"}) do
        if w3.ui.pressed(k, true) and not (ro and k ~= "A") then e:key(k, true, shift) end
      end
      if w3.ui.pressed("C") or w3.ui.pressed("X") then
        local sel = e:selected()
        if sel ~= "" then
          w3.ui.clipboard(sel)
          if w3.ui.pressed("X") and not ro then e:backspace(false) end
        end
      end
      if w3.ui.pressed("V") and not ro then
        local clip = w3.ui.clipboard():gsub("[\r\n].*", "")   -- a line edit takes the first line
        if clip ~= "" then e:insert(clip) end
      end
    end
    if w3.ui.pressed("Enter") or w3.ui.pressed("KeypadEnter") then enter = true end
    changed = e:text() ~= before
    if typed ~= "" then s.blink0 = w3.ui.time() end
    offs = w3.ui.text_offsets(e:text(), px, bold)
  end
  -- the horizontal scroll (QLineEdit::paintEvent, at every paint - with the focus or not): the cursor kept in the
  -- line's rectangle; text that fits stands at the left; past its end no empty room on the right
  do
    local lw = vis_w + 1                          -- (lineRect: the contents less the 2 px margins)
    local cix = offs[e.cur + 1]
    local used = offs[#offs] + 1
    if used <= lw then s.scroll = 0
    elseif cix - s.scroll >= lw then s.scroll = cix - lw + 1
    elseif cix - s.scroll < 0 and s.scroll < used then s.scroll = cix
    elseif used - s.scroll < lw then s.scroll = used - lw + 1
    else s.scroll = math.max(0, s.scroll) end
  end
  text = e:text()

  -- draw: the field, the text, the selection with white text, the cursor
  Q.frame(x, y, w, h, st.bg, focused and st.edge_focus or st.edge)
  local lh = Q.line_h(px, st.bold)
  -- (QLineEdit::paintEvent: its 1 px margins inside the padding, the line centred with the odd pixel below; C's
  -- division, so a field squeezed below its height lets the text go up by half of what is missing)
  local room = h - 2 - pt - pb - 2 - lh + 1
  local ty = y + 1 + pt + 1 + (room >= 0 and room // 2 or -((-room) // 2))
  local tx = tx0 - s.scroll
  D.clip(x + 1 + pl, y + 1 + pt, w - 2 - pl - pr, h - 2 - pt - pb, function()   -- (its contents: a low field cuts)
    if text == "" then
      if opts.placeholder then             -- (QLineEdit::paintEvent: elided at the right to the line's width)
        local ph = Q.elide(opts.placeholder, "right", vis_w + 1, px, st.bold)
        Q.text(tx0, ty, (st.fg & 0xffffff00) | 0x80, ph, px, st.bold, st.bg)
      end
    else
      Q.text(tx, ty, st.fg, text, px, st.bold, st.bg)
      local a, b = e:sel()
      if focused and a then
        local sx, ex = tx + offs[a + 1], tx + offs[b + 1]
        D.fill(sx, ty, ex - sx, lh, st.sel_bg)
        D.clip(sx, ty, ex - sx, lh, function() Q.text(tx, ty, st.sel_fg, text, px, st.bold, st.sel_bg) end)
      end
    end
    if focused and not ro then        -- (a read-only field shows no cursor)
      local period = w3.ui.caret_ms() / 1000
      local on = period <= 0 or ((w3.ui.time() - (s.blink0 or 0)) % (2 * period)) < period
      if on then D.invert(tx + offs[e.cur + 1], ty, 1, lh) end   -- Qt inverts what is under it
    end
  end)
  return changed, text, enter, w, h
end

-- --- QSpinBox / QDoubleSpinBox (the model: ui/spinbox.lua, checked against Qt) ---
local SB = require("conjunction.ui.spinbox")

-- opts: min, max, step, decimals, buttons (false: QAbstractSpinBox.NoButtons), w, fg (the text: QWidget{color} of an
-- app page, else the controls' BRIGHT) -> changed, value, w, h
function C.spin(id, x, y, value, opts)
  opts = opts or {}
  local w, h = Q.spin_size(opts.w)
  local s = st_of(id)
  if not s.sb or (C.focus ~= id and s.sb.value ~= value) then s.sb = SB.new(value, opts) end
  local sb = s.sb
  local clicked, hovered, held = hit(id, x, y, w, h)
  local mx, my = w3.ui.mouse()
  local _, _, wheel = w3.ui.mouse()
  local ctrl, shift = w3.ui.mods()
  local now = w3.ui.time()
  local before = sb.value
  local arrows = opts.buttons ~= false
  local ax = x + w - 18
  local up_box = arrows and mx >= ax and mx < x + w - 1 and my >= y + 1 and my < y + h // 2
  local down_box = arrows and mx >= ax and mx < x + w - 1 and my >= y + h // 2 and my < y + h - 1
  -- (the wheel only once it is clicked into - as Qt it needed no focus, and a scroll over the page changed the
  -- quest's level on the way, MaximdeWinter 14.11.)
  if hovered and wheel ~= 0 and C.focus == id then sb:on_wheel(wheel, ctrl) end
  if w3.ui.mouse_clicked(1) and hovered then
    C.text_press = true
    if up_box or down_box then
      s.repeat_dir, s.repeat_next = up_box and 1 or -1, now + 0.5     -- held: again after 500 ms, then every 150 ms
      sb:step_by(s.repeat_dir)
    else
      C.set_focus(id)
    end
  end
  if s.repeat_dir then
    if not w3.ui.mouse_down(1) then s.repeat_dir = nil
    elseif now >= s.repeat_next then sb:step_by(s.repeat_dir) s.repeat_next = now + 0.15 end
  end
  local focused = C.focus == id
  if focused then
    w3.ui.want_text()
    s.blink0 = s.blink0 or now
    local typed = w3.ui.chars()
    if typed ~= "" and not ctrl then sb:type(typed) s.blink0 = now end
    for _, k in ipairs({"UpArrow", "DownArrow", "PageUp", "PageDown", "Enter", "KeypadEnter", "LeftArrow",
                        "RightArrow", "Home", "End", "Backspace", "Delete"}) do
      if w3.ui.pressed(k, true) then sb:key(k, ctrl, shift) s.blink0 = now end
    end
    if ctrl and w3.ui.pressed("A") then sb.edit:select_all() end
  end
  -- draw (Q.spin's frame and arrows; the text from the model, as the text field draws it)
  local text = sb.edit:text()
  Q.frame(x, y, w, h, T.FIELD, focused and T.EDGE_HOVER or T.EDGE)
  if arrows then
    -- (the arrows as buttons of their own: a face, lighter under the mouse, pressed while held - MaximdeWinter 14.11.: they
    -- worked but showed nothing)
    local half = h // 2
    for k, box in ipairs({{y + 1, half - 1, up_box, 1, "chevron-up"}, {y + half, h - half - 1, down_box, -1, "chevron-down"}}) do
      local by, bh, over, dir, icon = box[1], box[2], hovered and box[3], box[4], box[5]
      local held_now = s.repeat_dir == dir and w3.ui.mouse_down(1)
      D.fill(ax, by, x + w - 1 - ax, bh, held_now and T.EDGE_HOVER or (over and T.CHOSEN or T.BUTTON))
      Q.draw_icon(icon, T.TEXT, 10, ax + (x + w - 1 - ax - 10) // 2, by + (bh - 10) // 2)   -- (made in #ccc only)
      if k == 1 then D.fill(ax, y + half - 1, x + w - 1 - ax, 1, T.EDGE) end
    end
    D.fill(ax - 1, y + 1, 1, h - 2, T.EDGE)
  end
  local tx, ty = x + 12, y + (h - Q.line_h()) // 2
  local offs = w3.ui.text_offsets(text, T.FONT)
  D.clip(x + 1, y + 1, (arrows and ax or x + w - 1) - x - 1, h - 2, function()
    Q.text(tx, ty, opts.fg or T.TEXT, text, T.FONT, false, T.FIELD)
    local a, b = sb.edit:sel()
    if focused and a then
      local sx, ex = tx + offs[a + 1], tx + offs[b + 1]
      D.fill(sx, ty, ex - sx, Q.line_h(), T.CHOSEN)
      D.clip(sx, ty, ex - sx, Q.line_h(), function() Q.text(tx, ty, T.WHITE, text, T.FONT, false, T.CHOSEN) end)
    end
    if focused then
      local period = w3.ui.caret_ms() / 1000
      if period <= 0 or ((now - s.blink0) % (2 * period)) < period then D.invert(tx + offs[sb.edit.cur + 1], ty, 1, Q.line_h()) end
    end
  end)
  if hovered and opts.tip then C.tip(id, opts.tip) end
  return sb.value ~= before, sb.value, w, h
end

-- --- QComboBox (inline_menu.Combo: the list opens inside the window) ---
-- items: a list of strings; win: the window's rectangle {x, y, w, h} (where the list may go) -> changed, index, w, h
function C.combo(id, x, y, w, items, index, win, opts)
  opts = opts or {}
  local h = opts.h or 30
  local clicked, hovered = hit(id, x, y, w, h)
  if opts.disabled then clicked, hovered = 0, false end      -- (setEnabled(False): it does not open)
  local changed = false
  if clicked == 1 then
    if IM.is_open(id) then IM.close() else
      local list = {}
      for i, t in ipairs(items) do
        list[i] = {text = t, checked = i == index, action = function() if i ~= index then st_of(id).picked = i end end}
      end
      IM.open(id, {x = x, y = y, w = w, h = h}, list, win, {bg = opts.list_bg})
    end
  end
  local s = st_of(id)
  if s.picked then index, s.picked, changed = s.picked, nil, true end
  Q.combo(x, y, w, h, items[index] or "", {focus = false, fg = opts.fg})
  if hovered and opts.tip then C.tip(id, opts.tip) end
  return changed, index, w, h
end

-- a control's tooltip (ui/tooltips.lua): a TIPS key, or {title, text}; call while the mouse is over it
function C.tip(id, tip)
  if type(tip) == "table" then TT.hover(id, tip[1], tip[2]) elseif tip then TT.hover(id, "", TIPS[tip]) end
end
C.frame = TT.frame   -- once per frame after the windows

return C
