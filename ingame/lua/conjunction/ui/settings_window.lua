-- File > Settings over the game (settings_view.SettingsPage in a CatalogWindow, at least 1000 x 640): the sections on
-- the left (a QTreeWidget#nav 190 wide: rows 31 high, padding 6px 10px, the chosen one CHOSEN with white text, a LINE
-- at its right), the chosen section's page on the right (margins 16 12, 8 apart: the heading, then a QFormLayout - the
-- labels 190 wide, the fields 16 after them and no wider than 560, rows 8 apart). Values saved at once (settings.lua).
-- General, Profile (profile_view.ProfilePage), Game, Tools. (The Plug-ins page below is no longer offered: a plug-in
-- needs its Python, the game has none.)
--   local b = SW.new(ed, plugins)   b:select("Profile")   b:frame(r)   (DW.open-like: panel:open_win(..., b))
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local DW = require("conjunction.ui.dialog_window")
local S = require("conjunction.settings")
local F = require("conjunction.features")
local ID = require("conjunction.identity")
local PATHS = require("conjunction.paths")
local D = w3.ui.draw
local SW = {}
SW.__index = SW

SW.W, SW.H = 1000, 640
SW.NAV_W = 190
SW.NAV_ROW = 31
SW.ROW_H, SW.HEAD_H = 28, 26          -- the plug-ins table (settings_view.ROW_H, HEAD_H)
SW.KEEP = "This file is the profile's key. Keep it and copy it to a new PC (Documents\\Conjunction\\identity). " ..
          "Never post or send it: whoever has it can sign as this profile"
local GREY = (0xcf << 24) | (0xcf << 16) | (0xcf << 8) | 255     -- (icons.GREY; the page's QWidget{color} is on
-- every widget of it - buttons, table cells - over their own sheet's)

function SW.new(ed, plugins)
  local self = setmetatable({ed = ed, cur = 1, values = {}, texts = {}}, SW)
  self.plugins = plugins or require("conjunction.plugins").new()
  self:fill()
  return self
end

-- the sections (settings_view.fill): Conjunction's own, Profile after General (no Plug-ins: they need Python, the game
-- has none - MaximdeWinter 14.11.: out)
function SW:fill()
  self.sections = {}
  for _, sec in ipairs(S.SECTIONS) do
    self.sections[#self.sections + 1] = {title = sec, kind = "own"}
    if sec == "General" then self.sections[#self.sections + 1] = {title = "Profile", kind = "profile"} end
  end
  self.listing = self.plugins:listing()
end
function SW:select(title)
  for i, s in ipairs(self.sections) do if s.title == title then self.cur = i return true end end
  return false
end
function SW:size_hint() return SW.W - 24, SW.H - 48 end

local function hit(self, id, r) return self.win:hit(id, r) end

-- --- the nav
function SW:draw_nav(r)
  D.fill(r.x, r.y, r.w, r.h, T.BG)
  D.fill(r.x + r.w - 1, r.y, 1, r.h, T.LINE)
  for i, s in ipairs(self.sections) do
    local row = {x = r.x, y = r.y + (i - 1) * SW.NAV_ROW, w = r.w - 1, h = SW.NAV_ROW}
    local clicked, hovered = hit(self, "nav." .. i, row)
    if clicked then self.cur = i end
    local chosen = self.cur == i
    local bg = chosen and T.CHOSEN or (hovered and T.HOVER or T.BG)
    if bg ~= T.BG then D.fill(row.x, row.y, row.w, row.h, bg) end
    Q.text(row.x + 13, row.y + Q.vcenter(row.h, Q.line_h()), chosen and T.WHITE or T.TEXT, s.title, T.FONT, false, bg)
  end
end

-- --- a page's parts
local function head(x, y, title)
  Q.label(x, y, title, "head", T.BG)
  local _, h = Q.label_size(title, "head")
  return h
end
-- a form row's label (QFormLayout: as high as the row, at most 7/4 of its own height; the text centred in it)
local function form_label(x, y, row_h, text)
  local lh = Q.line_h()
  local h = math.min(row_h, lh * 7 // 4)
  Q.text(x, y + Q.vcenter(h, lh), T.TEXT, text, T.FONT, false, T.BG)
end
local function wrapped(x, y, w, text, fg, px)
  local lines, h = {}, 0
  for para in (text .. "\n"):gmatch("(.-)\n") do
    for _, l in ipairs(DW.label_lines(para, px or T.FONT, false, w)) do lines[#lines + 1] = l end
  end
  local lh = Q.line_h(px)
  for k, l in ipairs(lines) do Q.text(x, y + (k - 1) * lh, fg or T.TEXT, l.s, px or T.FONT, false, T.BG) end
  return math.max(1, #lines) * lh
end

-- a QPushButton with an icon (16 px, icons.GREY; Qt's hint adds 4 for it, text or not) before its text: the two
-- centred together, the text 2 px after it (an app page's QWidget{color} on it, as on every button there)
local function icon_button(self, id, x, y, text, icon, opts)
  opts = opts or {}
  local tw = text ~= "" and Q.hint_w(text) or 0
  local w = opts.w or (16 + 4 + tw + 22)
  local h = opts.h or ((text ~= "" and Q.line_h() or 16) + 12)
  local b = {x = x, y = y, w = w, h = h}
  local clicked, hovered, held = hit(self, id, b)
  Q.frame(b.x, b.y, b.w, b.h, (held and hovered) and T.CHOSEN or T.BUTTON, (hovered or held) and T.EDGE_HOVER or T.EDGE)
  local cw = w - 22
  local label = 16 + (text ~= "" and (4 + Q.text_w(text)) or 0)
  local ix = x + 11 + (cw - label) // 2
  local iy = y + 6 + (h - 12 - 16) // 2
  Q.draw_icon(icon, GREY, 16, ix, iy)     -- (QIcon's Active picture: only with the keyboard on it)
  if text ~= "" then
    local bg = (held and hovered) and T.CHOSEN or T.BUTTON
    Q.text(ix + 18, y + 6 + (h - 12 - Q.line_h()) // 2, T.TEXT, text, T.FONT, false, bg)
  end
  if hovered and opts.tip then CT.tip("panel.win.settings." .. id, opts.tip) end
  return clicked, w, h
end

-- a text field that keeps its value when Enter is pressed or it loses the keyboard (editingFinished)
function SW:line(id, x, y, w, key, save, opts)
  local cid = "panel.win.settings." .. id
  if self.texts[id] == nil then self.texts[id] = key end
  local _, text, enter = CT.edit(cid, x, y, w, self.texts[id], opts)
  self.texts[id] = text
  local focused = CT.focus == cid
  if enter or (self.focus_was == cid and not focused) then
    local t = text:match("^%s*(.-)%s*$")
    if t ~= self.saved_text then save(t) end
  end
  if focused and self.focus_was ~= cid then self.saved_text = text:match("^%s*(.-)%s*$") end
  if focused then self.focus_now = cid end
  return text
end

-- --- Conjunction's own sections
function SW:own_page(x, y, w, sec)
  y = y + head(x, y, sec) + 8
  local fx = x + T.LABEL_W + 16
  local fw = math.min(T.FIELD_W, w - T.LABEL_W - 16)
  for _, f in ipairs(S.FIELDS) do
    local key, label, typ = f[2], f[3], f[4]
    if f[1] == sec and not (key == F.KEY and not F.offered()) then
      local tip = "set." .. key
      local row_h
      if typ == "bool" then
        local v = self.values[key]
        if v == nil then v = not not S.value(key) self.values[key] = v end
        local lh = Q.line_h()
        row_h = lh
        local toggled, nv = CT.check("panel.win.settings." .. key, fx, y, "", v, {h = 16, bg = T.BG, tip = tip})
        if toggled then self.values[key] = nv S.set_value(key, nv) end
      else
        local eh = CT.edit_h()
        row_h = eh
        local bw = (typ == "path" or typ == "file") and 42 or 0
        local lw = fw - (bw > 0 and (bw + 4) or 0)
        local cur = S.value(key)
        cur = (cur ~= nil and cur ~= false) and tostring(cur) or ""
        self:line(key, fx, y, lw, cur, function(t) S.set_value(key, t) end, {tip = tip})
        if bw > 0 then
          local clicked = icon_button(self, key .. ".pick", fx + lw + 4, y + (eh - 28) // 2, "", "folder-open",
                                      {w = 42, h = 28, tip = typ == "path" and "set.pick_folder" or "set.pick_file"})
          if clicked then self:pick(key, typ) end
        end
      end
      local lr = {x = x, y = y, w = T.LABEL_W, h = math.min(row_h, Q.line_h() * 7 // 4)}
      local _, lhov = hit(self, "label." .. key, lr)
      if lhov then CT.tip("panel.win.settings.label." .. key, tip) end
      form_label(x, y, row_h, label)
      y = y + row_h + 8
      if key == F.KEY then                         -- what it is, said plainly (MaximdeWinter 05.10.)
        y = y + wrapped(x, y, math.min(w, T.LABEL_W + 16 + T.FIELD_W), F.WARNING, T.RED) + 8
      end
    end
  end
end

-- a folder or file chosen for a field (dialogs.lua: Qt's own file dialog in one of the windows)
function SW:pick(key, typ)
  local ok, DLG = pcall(require, "conjunction.ui.dialogs")
  if not ok then return end
  local function got(path)
    if not path or path == "" then return end
    self.texts[key] = path
    S.set_value(key, path)
  end
  if typ == "path" then DLG.pick_folder(self.ed, "Folder", "", got)
  else DLG.pick_file(self.ed, "File", "", "", got) end
end

-- --- Profile (profile_view.ProfilePage)
function SW:profile_page(x, y, w)
  y = y + head(x, y, "Profile") + 8
  local fx = x + T.LABEL_W + 16
  local fw = math.min(T.FIELD_W, w - T.LABEL_W - 16)
  local act = ID.active()
  local ps = ID.profiles()
  local names, index = {"No profile (nothing is signed)"}, 1
  for i, p in ipairs(ps) do
    names[i + 1] = p.name
    if act and p.id == act.id then index = i + 1 end
  end
  local eh = CT.edit_h()
  local changed, ni = CT.combo("panel.win.settings.profile.choice", fx, y, fw, names, index, self.win.rect,
                               {h = eh, tip = "set.profile.choice"})
  if changed then
    if ni == 1 then ID.set_active(nil) else ID.set_active(ps[ni - 1]) end
    self.texts["profile.name"] = nil
    act = ID.active()
  end
  form_label(x, y, eh, "Signs as")
  y = y + eh + 8
  if act then
    self:line("profile.name", fx, y, fw, act.name, function(t)
      if t ~= "" and t ~= act.name then act:rename(t) self.texts["profile.name"] = nil end
    end, {placeholder = "Name", tip = "set.profile.name"})
  else
    Q.frame(fx, y, fw, eh, T.FIELD, T.EDGE)
    Q.text(fx + 8, y + 7, (T.TEXT & 0xffffff00) | 0x80, "Name", T.FONT, false, T.FIELD)
  end
  form_label(x, y, eh, "Name")
  y = y + eh + 8
  local file = act and act.path or "No profile (New profile makes one)"
  local fh = wrapped(fx, y, fw, file)
  form_label(x, y, fh, "Key file")
  y = y + fh + 8
  y = y + wrapped(x, y, w, SW.KEEP, T.DIM) + 8
  local bx = x
  local function button(id, text, tip, disabled)
    local bw, bh = Q.button_size(text)
    local c = CT.button("panel.win.settings.profile." .. id, bx, y, text,
                        {w = bw, h = bh, tip = tip, disabled = disabled})
    bx = bx + bw + 8
    return c
  end
  if button("show", "Show key file", "set.profile.show", act == nil) and act then self:show_file(act.path) end
  if button("new", "New profile", "set.profile.new") then self:new_profile() end
  if button("add", "Add key file", "set.profile.add") then self:add_key_file() end
  if button("check", "Check origin", "set.profile.check") then self:check_origin() end
  if button("how", "How signing works", "set.profile.how") then self:how_signing(act) end
end

-- Explorer with the file selected (Conjunction never shows what is in it)
function SW:show_file(path)
  if w3.proc and w3.proc.run then require("conjunction.fsutil").show(path, true) end
end
function SW:new_profile()
  local ok, DLG = pcall(require, "conjunction.ui.dialogs")
  if not ok then return end
  DLG.ask_text(self.ed, "New profile", "Name (a key of its own, nothing links it to the other profiles)", function(t)
    if t and t ~= "" then ID.create(t) self.texts["profile.name"] = nil end
  end)
end
function SW:add_key_file()
  local ok, DLG = pcall(require, "conjunction.ui.dialogs")
  if not ok then return end
  local home = os.getenv("USERPROFILE") or PATHS.HOME
  DLG.pick_file(self.ed, "Add key file", home, "Conjunction key (*" .. ID.EXT .. ")", function(path)
    if not path or path == "" then return end
    local good, p = pcall(ID.add_file, path)
    if good then ID.set_active(p)
    else DLG.message(self.ed, "Add key file", "Not a Conjunction key file (" .. tostring(p) .. ")") end
    self.texts["profile.name"] = nil
  end)
end
function SW:check_origin()
  local ok, DLG = pcall(require, "conjunction.ui.dialogs")
  if ok and DLG.check_origin then DLG.check_origin(self.ed) end
end
function SW:how_signing(act)
  local ok, DLG = pcall(require, "conjunction.ui.dialogs")
  if ok and DLG.how_signing then DLG.how_signing(self.ed, act) end
end

-- --- Plug-ins
-- the columns: On 44, Plug-in the rest, Version, Author, Status as wide as their contents (the header's bold text
-- and 25; a cell's text and 22), README as wide as its button and the cell's padding
function SW:plugin_columns(vw)
  local heads = {"On", "Plug-in", "Version", "Author", "Status", ""}
  local cols = {44, 0, 0, 0, 0, 0}
  local rows = self:plugin_rows()
  for c = 3, 5 do
    local m = Q.hint_w(heads[c], T.FONT, true) + 25
    for _, row in ipairs(rows) do m = math.max(m, Q.text_w(row[c], T.FONT) + 22) end
    cols[c] = m
  end
  local rw = 0
  for _, row in ipairs(rows) do if row.readme then rw = math.max(rw, Q.button_size("README")) end end
  cols[6] = rw > 0 and (rw + 16 + 8) or 34
  cols[2] = math.max(0, vw - cols[1] - cols[3] - cols[4] - cols[5] - cols[6])
  return cols, heads, rows
end
function SW:plugin_rows()
  local rows = {}
  for _, ms in ipairs(self.listing) do
    local m, st = ms[1], ms[2]
    local words = (m.adult and st == "off") and "off, adult content" or st
    local first = (words:match("^([^\r\n]*)") or ""):sub(1, 80)
    rows[#rows + 1] = {"", m.name or m.id, m.version or "", m.author or "", first, id = m.id, on = st ~= "off",
                       readme = m.readme, tip = m.description, status_tip = #words > 80 and words or nil,
                       loaded = st == "loaded"}
  end
  return rows
end

function SW:plugins_page(x, y, w)
  y = y + head(x, y, "Plug-ins") + 8
  local rows_n = #self.listing
  local th = SW.HEAD_H + rows_n * SW.ROW_H + 2
  Q.view_frame(x, y, w, th)
  local vx, vy, vw = x + 1, y + 1, w - 2
  local cols, heads, rows = self:plugin_columns(vw)
  local cx = vx
  for c = 1, 6 do
    Q.header_left(cx, vy, cols[c], SW.HEAD_H, heads[c])
    cx = cx + cols[c]
  end
  local tip
  for i, row in ipairs(rows) do
    local ry = vy + SW.HEAD_H + (i - 1) * SW.ROW_H
    cx = vx
    for c = 1, 6 do
      local cw = cols[c]
      if c == 1 then
        local box = cx + 8 + (cw - 16 - 24) // 2
        local toggled, v = CT.check("panel.win.settings.plugin." .. row.id, box, ry + (SW.ROW_H - 16) // 2, "",
                                    row.on, {h = 16, bg = T.SURFACE, tip = "set.plugins.on"})
        if toggled then
          S.set_enabled(row.id, v)
          self.enabled_now = self.enabled_now or {}
          self.enabled_now[row.id] = v
        end
        if self.enabled_now and self.enabled_now[row.id] ~= nil then row.on = self.enabled_now[row.id] end
      elseif c == 6 then
        if row.readme then
          local bw = Q.button_size("README")
          local bx = cx + 8 + (cw - 16 - bw) // 2
          if CT.button("panel.win.settings.readme." .. row.id, bx, ry, "README", {w = bw, h = SW.ROW_H,
                                                                                tip = "set.plugins.readme"}) then
            self:show_readme(row)
          end
        end
      else
        local dim = c == 3 or c == 4 or (c == 5 and not row.loaded)
        local s = row[c]
        if s ~= "" then
          Q.text(cx + 11, ry + Q.vcenter(SW.ROW_H, Q.line_h()), dim and T.DIM or T.TEXT, s, T.FONT, false, T.SURFACE)
        end
        local _, hv = hit(self, "cell." .. i .. "." .. c, {x = cx, y = ry, w = cw, h = SW.ROW_H})
        if hv and c == 2 and row.tip and row.tip ~= "" then tip = row.tip end
        if hv and c == 5 and row.status_tip then tip = row.status_tip end
      end
      cx = cx + cw
    end
  end
  if tip then CT.tip("panel.win.settings.cell", {"", tip}) end
  y = y + th
  if rows_n == 0 then
    y = y + 8
    Q.label(x, y, "No plug-ins found", "dim", T.BG)
    y = y + Q.line_h(T.FONT_SMALL)
  end
  y = y + 8 + 8
  Q.label(x, y, PATHS.PLUGINS, "dim", T.BG)
  y = y + Q.line_h(T.FONT_SMALL) + 8
  if icon_button(self, "plugins.folder", x, y, "Open plug-ins folder", "folder-open", {tip = "set.plugins.folder"}) then
    if not w3.fs.isdir(PATHS.PLUGINS) then w3.fs.mkdir(PATHS.PLUGINS) end
    if w3.proc and w3.proc.run then require("conjunction.fsutil").show(PATHS.PLUGINS) end
  end
end

-- a plug-in's README in a window of its own (dialogs.lua)
function SW:show_readme(row)
  local ok, DLG = pcall(require, "conjunction.ui.dialogs")
  if ok and DLG.readme then DLG.readme(self.ed, (row[2] ~= "" and row[2] or row.id) .. " - README", row.readme) end
end

function SW:frame(r)
  self.focus_now = nil
  D.fill(r.x, r.y, r.w, r.h, T.BG)
  self:draw_nav({x = r.x, y = r.y, w = SW.NAV_W, h = r.h})
  local px, py, pw = r.x + SW.NAV_W + 16, r.y + 12, r.w - SW.NAV_W - 32
  local s = self.sections[self.cur]
  D.clip(r.x + SW.NAV_W, r.y, r.w - SW.NAV_W, r.h, function()
    if s.kind == "own" then self:own_page(px, py, pw, s.title)
    elseif s.kind == "profile" then self:profile_page(px, py, pw)
    else self:plugins_page(px, py, pw) end
  end)
  self.focus_was = self.focus_now
end

return SW
