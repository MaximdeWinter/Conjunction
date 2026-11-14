-- Conjunction's dialogs over the game (dialogs.py with the editor up: each one of the panel's windows, as
-- dialogs.run_dialog shows it - its own background, as big as it wants, at least 460 wide). Immediate mode: what the
-- Python code waits for comes back through then_.
--   DLG.ask_text(ed, title, label, then_, text) one line asked (QInputDialog, text: what it starts with) ->
--                                               then_(text or "")
--   DLG.message(ed, title, text, kind)         QMessageBox (kind: warning (default), information, critical,
--                                              question) with OK
--   DLG.question(ed, title, text, then_)       QMessageBox.question: Yes and No -> then_("yes" | "no")
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local DW = require("conjunction.ui.dialog_window")
local SI = require("conjunction.ui.shellicon")
local DLG = {}

local function panel_of(ed) return ed.panel or ed end

-- --- QInputDialog (a label, a line, OK and Cancel at the right; margins 9, 6 apart). Its window gets the size hint
-- Qt measures while it is a window of its own (margins 11) and the layout's own size (SetMinAndMaxSize) inside it
local Ask = {}
Ask.__index = Ask
DLG.Ask = Ask
-- (its window is never the active one: the caret shows, the frame stays EDGE - :focus needs an active window)
Ask.EDIT = setmetatable({edge_focus = T.EDGE}, {__index = CT.EDIT_STYLE})
function Ask.new(label, then_, text)
  local self = setmetatable({label = label, then_ = then_, text = text or ""}, Ask)
  CT.state("dlg.ask.text").e = nil
  CT.set_focus("dlg.ask.text")                   -- (the line has the keyboard when it opens)
  local _, h = self:layout_h(9)
  self.max_h = h
  return self
end
function Ask:layout_h(m)
  local _, lh = Q.label_size(self.label)
  local _, bh = Q.button_size("OK")
  return lh, m + lh + 6 + CT.edit_h() + 6 + bh + m
end
function Ask:size_hint()
  local lw = Q.label_size(self.label)
  local ow = Q.button_size("OK")
  local cw = Q.button_size("Cancel")
  local _, h = self:layout_h(11)
  return math.max(lw, ow + 6 + cw) + 22, h
end
function Ask:finish(ok)
  local text = ok and (self.text:match("^%s*(.-)%s*$")) or ""
  if CT.focus == "dlg.ask.text" then CT.set_focus(nil) end
  self.win:close()
  if self.then_ then self.then_(text) end
end
function Ask:frame(r)
  DW.background(r)
  local x, y, w = r.x + 9, r.y + 9, r.w - 18
  local lh = self:layout_h(9)
  Q.label(x, y, self.label, nil, T.BG)
  y = y + lh + 6
  local eh = CT.edit_h()
  local _, text, enter = CT.edit("dlg.ask.text", x, y, w, self.text, {style = Ask.EDIT})
  self.text = text
  y = y + eh + 6
  local ow, bh = Q.button_size("OK")
  local cw = Q.button_size("Cancel")
  local cx = x + w - cw
  local ox = cx - 6 - ow
  local ok = CT.button("dlg.ask.ok", ox, y, "OK", {w = ow, h = bh})
  local cancel = CT.button("dlg.ask.cancel", cx, y, "Cancel", {w = cw, h = bh})
  if ok or enter then self:finish(true)
  elseif cancel or (CT.focus == "dlg.ask.text" and w3.ui.pressed("Escape")) then self:finish(false) end
end

-- --- QMessageBox (QMessageBoxPrivate::updateSize: a fixed size - the icon 32 px, the text 19 px after it, the
-- button box 6 below, margins 9; text wider than the soft limit, min(half the screen, 500), wraps there). The icon
-- spans two rows of the grid: under a line of text the second row takes the rest of the icon, under two lines none
-- (6 apart each). Its window is sized by the hint it has before it is shown (run_dialog): without buttons (OK comes
-- with the show) the text + 69 by 69, with Yes and No the text + 73 by 98 (measured: ref/probe_msgbox.py).
-- buttons: nil (OK) or "yesno" -> then_("yes" | "no"); Escape is No, Enter Yes
local Msg = {}
Msg.__index = Msg
DLG.Msg = Msg
function Msg.new(text, kind, screen_w, buttons, then_)
  local self = setmetatable({text = text, kind = kind or "warning", buttons = buttons, then_ = then_}, Msg)
  local _, bh = Q.button_size("OK")
  local tw = Q.hint_w(text)
  local width = 9 + 32 + 19 + tw + 9
  local soft = math.min((screen_w or 1600) // 2, 500)
  self.wrap = nil
  if width > soft then
    width = soft
    self.wrap = width - 9 - 32 - 19 - 9
  end
  local th = Q.line_h()
  if self.wrap then
    local _, h = DW.label_lines(text, T.FONT, false, self.wrap)
    th = h
  end
  self.fw = width
  self.fh = 9 + th + 6 + math.max(0, 32 - th - 6) + 6 + 9 + bh + 9
  self.min_h, self.max_h = self.fh, self.fh
  if buttons == "yesno" then self.hint_w, self.hint_h = tw + 73, 98 else self.hint_w, self.hint_h = self.fw, 0 end
  return self
end
function Msg:size_hint() return self.hint_w, self.hint_h end
function Msg:answer(a)
  self.win:close()
  if self.then_ then self.then_(a) end
end
function Msg:frame(r)
  local b = {x = r.x, y = r.y, w = math.min(r.w, self.fw), h = self.fh}
  DW.background(b)
  SI.draw(SI.std(self.kind, 32), b.x + 9, b.y + 9)
  local tx = b.x + 9 + 32 + 19
  if self.wrap then
    local lines = DW.label_lines(self.text, T.FONT, false, self.wrap)
    for k, l in ipairs(lines) do Q.text(tx, b.y + 9 + (k - 1) * Q.line_h(), T.TEXT, l.s, T.FONT, false, T.BG) end
  else
    Q.text(tx, b.y + 9, T.TEXT, self.text, T.FONT, false, T.BG)
  end
  local ow, bh = Q.button_size("OK")
  local by = b.y + b.h - 9 - bh
  if type(self.buttons) == "table" then         -- ({{key, label}, ...} at the right, in order; Enter: the first,
    local x = b.x + b.w - 9                     -- Escape: "cancel")
    local placed = {}
    for k = #self.buttons, 1, -1 do
      local bt = self.buttons[k]
      local bw = Q.button_size(bt[2])
      x = x - bw
      placed[k] = {x, bw}
      x = x - 6
    end
    for k, bt in ipairs(self.buttons) do
      if CT.button("dlg.msg." .. bt[1], placed[k][1], by, bt[2], {w = placed[k][2], h = bh}) then
        self:answer(bt[1])
        return
      end
    end
    if w3.ui.pressed("Enter") then self:answer(self.buttons[1][1])
    elseif w3.ui.pressed("Escape") then self:answer("cancel") end
    return
  end
  if self.buttons == "yesno" then
    local nw = Q.button_size("No")
    local yw = Q.button_size("Yes")
    local nx = b.x + b.w - 9 - nw
    local yes = CT.button("dlg.msg.yes", nx - 6 - yw, by, "Yes", {w = yw, h = bh})
    local no = CT.button("dlg.msg.no", nx, by, "No", {w = nw, h = bh})
    if yes or w3.ui.pressed("Enter") then self:answer("yes")
    elseif no or w3.ui.pressed("Escape") then self:answer("no") end
    return
  end
  if CT.button("dlg.msg.ok", b.x + b.w - 9 - ow, by, "OK", {w = ow, h = bh})
     or w3.ui.pressed("Escape") or w3.ui.pressed("Enter") then
    self.win:close()
  end
end

-- a question with buttons of its own: buttons {{key, label}, ...} -> then_(key) ("cancel": Escape)
function DLG.choose(ed, title, text, buttons, then_)
  local p = panel_of(ed)
  local m = Msg.new(text, "question", p.W, buttons, then_)
  local w = 9 + 6 * (#buttons - 1) + 9
  for _, bt in ipairs(buttons) do w = w + Q.button_size(bt[2]) end
  m.fw = math.max(m.fw, w)
  m.hint_w = m.fw
  return DW.open(p, "ask", title, m)
end

-- QMessageBox.question with Yes and No -> then_("yes" | "no")
function DLG.question(ed, title, text, then_)
  local p = panel_of(ed)
  return DW.open(p, "ask", title, Msg.new(text, "question", p.W, "yesno", then_))
end

function DLG.message(ed, title, text, kind)
  local p = panel_of(ed)
  return DW.open(p, "ask", title, Msg.new(text, kind, p.W))
end

-- --- How signing works (profile_view.explain): the heading, the text (data/how_signing.html in a QTextBrowser of
-- the theme's QTextEdit: FIELD, EDGE, padding 5, 13 px - TEXT: the page's colour wins), the key file's place (DIM,
-- wrapped), Show file, OK;
-- margins 20 16, 6 apart; 640 x 640
local Explain = {}
Explain.__index = Explain
DLG.Explain = Explain
function Explain.new(profile, html_file)
  local RT = require("conjunction.ui.richtext")
  local self = setmetatable({profile = profile}, Explain)
  self.text = RT.new(html_file, "html", {px = T.FONT, fg = T.TEXT, bg = T.FIELD, edge = T.EDGE, pad = 5})
  return self
end
function Explain:size_hint() return 640, 640 end
function Explain:frame(r)
  DW.background(r)
  local x, y, w = r.x + 20, r.y + 16, r.w - 40
  local bottom = r.y + r.h - 16
  Q.label(x, y, "How signing works (please read this once)", "head", T.BG)
  local _, hh = Q.label_size("How signing works", "head")
  local ok_w, bh = Q.button_size("OK")
  local show_w = self.profile and Q.button_size("Show file") or 0
  local lw = w - ok_w - 6 - (self.profile and (show_w + 6) or 0)
  local where = self.profile and ("Key file of " .. self.profile.name .. ": " .. self.profile.path) or ""
  local lines, lh = DW.label_lines(where, T.FONT, false, lw)
  local row_h = math.max(lh, bh)
  local ry = bottom - row_h
  local hit = function(id, b) return self.win:hit(id, b) end
  self.text:frame({x = x, y = y + hh + 6, w = w, h = ry - 6 - (y + hh + 6)}, hit)
  local ty = ry + Q.vcenter(row_h, lh)
  for k, l in ipairs(lines) do Q.text(x, ty + (k - 1) * Q.line_h(), T.DIM, l.s, T.FONT, false, T.BG) end
  local by = ry + (row_h - bh) // 2
  local bx = x + lw + 6
  if self.profile then
    if CT.button("dlg.explain.show", bx, by, "Show file", {w = show_w, h = bh}) and w3.proc then
      require("conjunction.fsutil").show(self.profile.path, true)
    end
    bx = bx + show_w + 6
  end
  if CT.button("dlg.explain.ok", bx, by, "OK", {w = ok_w, h = bh}) or w3.ui.pressed("Escape") then self.win:close() end
end
function DLG.how_signing(ed, profile)
  local PATHS = require("conjunction.paths")
  local file = (PATHS.REPO and (PATHS.REPO .. "\\conjunction\\data") or (PATHS.MOD_ROOT .. "\\data")) ..
               "\\how_signing.html"
  return DW.open(panel_of(ed), "how signing", "How signing works", Explain.new(profile, file))
end

-- --- a plug-in's README (settings_view.show_readme): the markdown in a QTextBrowser (SURFACE, TEXT 13 px, a LINE
-- border, padding 10) on the page (margins 16 12); 720 x 640
local Readme = {}
Readme.__index = Readme
DLG.Readme = Readme
function Readme.new(file)
  local RT = require("conjunction.ui.richtext")
  return setmetatable({text = RT.new(file, "markdown", {px = T.FONT, fg = T.TEXT, bg = T.SURFACE, edge = T.LINE,
                                                         pad = 10})}, Readme)
end
function Readme:size_hint() return 720, 640 end
function Readme:frame(r)
  DW.background(r)
  self.text:frame({x = r.x + 16, y = r.y + 12, w = r.w - 32, h = r.h - 24},
                  function(id, b) return self.win:hit(id, b) end)
end
function DLG.readme(ed, title, file)
  return DW.open(panel_of(ed), "readme", title, Readme.new(file))
end

-- --- Updates (updates.show): each note, each newer one (bold BRIGHT, Open on Nexus beside it), OK at the right; a
-- QVBoxLayout (margins 9, 6 apart; its hint measured as a window of its own: 11); the room beyond the hints to the
-- notes' labels
local Updates = {}
Updates.__index = Updates
DLG.Updates = Updates
function Updates.new(found, notes)
  return setmetatable({found = found and found.what or {}, notes = notes or {}}, Updates)
end
function Updates:items()
  local items = {}
  local _, bh = Q.button_size("OK")
  for _, t in ipairs(self.notes) do
    local w, h = Q.label_size(t)
    items[#items + 1] = {kind = "note", text = t, hint = h, w_hint = w}
  end
  for _, f in ipairs(self.found) do
    local t = string.format("%s %s is out (you have %s)", f[1], f[3], f[2])
    local w = Q.hint_w(t, T.FONT, true)
    items[#items + 1] = {kind = "new", text = t, url = f[4], hint = bh, min = bh, max = bh,
                         w_hint = w + 6 + Q.button_size("Open on Nexus")}
  end
  items[#items + 1] = {kind = "ok", hint = bh, min = bh, max = bh, w_hint = Q.button_size("OK")}
  return items
end
function Updates:size_hint()
  local w, h = 0, 0
  local items = self:items()
  for _, it in ipairs(items) do w = math.max(w, it.w_hint) h = h + it.hint end
  return w + 22, h + (#items - 1) * 6 + 22
end
function Updates:frame(r)
  local L = require("conjunction.ui.layout")
  DW.background(r)
  local items = self:items()
  local placed = L.column(items, r.x, r.y, r.w, r.h, {margins = {9, 9, 9, 9}, spacing = 6})
  local _, bh = Q.button_size("OK")
  for i, it in ipairs(items) do
    local b = placed[i]
    if it.kind == "note" then
      Q.text(b.x, b.y + Q.vcenter(b.h, Q.line_h()), T.TEXT, it.text, T.FONT, false, T.BG)
    elseif it.kind == "new" then
      local gw = Q.button_size("Open on Nexus")
      Q.text(b.x, b.y + Q.vcenter(b.h, Q.line_h(T.FONT, true)), T.BRIGHT, it.text, T.FONT, true, T.BG)
      if CT.button("dlg.updates.go." .. i, b.x + b.w - gw, b.y, "Open on Nexus", {w = gw, h = bh}) and w3.proc then
        require("conjunction.fsutil").show(it.url)
      end
    else
      local ow = Q.button_size("OK")
      if CT.button("dlg.updates.ok", b.x + b.w - ow, b.y, "OK", {w = ow, h = bh}) then self.win:close() end
    end
  end
end

-- --- file choosers (dialogs.pick_file / pick_folder with the editor up: Qt's own file dialog in a window)
function DLG.pick_file(ed, title, start, name_filter, then_)
  return require("conjunction.ui.file_dialog").open(ed, {title = title, start = start, filter = name_filter}, then_)
end
function DLG.pick_folder(ed, title, start, then_)
  return require("conjunction.ui.file_dialog").open(ed, {title = title, start = start, folder = true}, then_)
end

-- Settings > Profile > Check origin (profile_view.CheckOriginDialog: origin_window.lua)
function DLG.check_origin(ed) return require("conjunction.ui.origin_window").open(ed) end

function DLG.ask_text(ed, title, label, then_, text)
  return DW.open(panel_of(ed), "ask", title, Ask.new(label, then_, text))
end

return DLG
