-- File > New project in the game (app.NewProjectDialog, in_game): its name, what it is (a quest, or a place mod), the
-- warning that the game starts again (unless switched off), Cancel and Create. A QVBoxLayout (margins 9, 8 apart): the
-- name field, per kind a radio button and its note (DIM, 22 px in, wrapped), the warning (RED bold, wrapped), Don't
-- show again, 6 px, the buttons at the right. The window's height comes from the dialog's size hint (its notes
-- wrapped as their hints wrap them); at the real width the space left goes to the labels, as Qt shares it.
--   local d = NP.new(then_)   then_(name, kind) when Create is pressed      DW.open(panel, "new project", ...)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local L = require("conjunction.ui.layout")
local DW = require("conjunction.ui.dialog_window")
local CFG = require("conjunction.config")
local NP = {}
NP.__index = NP

NP.KINDS = {{"quest", "Quest", "Steps, talks and a journal entry. Its places come and go with the quest"},
            {"place", "Place mod", "A place that is always in the world: a house for Geralt, a camp, decoration"}}
NP.WARNING = "Creating a project restarts the game. Automatic quick save"

function NP.new(then_)
  local self = setmetatable({then_ = then_, name = "", kind = "quest", dont_warn = false}, NP)
  -- (no warning in the game: a new project no longer restarts it - editor.switch_project, MaximdeWinter 24.10.; the app's
  -- dialog keeps it, the app still starts the game again)
  self.warn = NP.WARN_RESTART == true and not CFG.load().new_project_warning_off
  CT.state("dlg.np.name").e = nil
  return self
end

-- the column's items: {key, widget for L.column (hint, min, max, hfw)}
function NP:items()
  local xw = Q.label_indent(T.FONT)
  local items = {}
  local function add(key, it) it.key = key items[#items + 1] = it end
  local ew, eh = Q.edit_size(118)
  add("name", {hint = eh, min = eh, max = eh, w_hint = ew})
  for _, k in ipairs(NP.KINDS) do
    local rw, rh = Q.radio_size(k[2], self.kind == k[1])
    add("radio:" .. k[1], {hint = rh, min = rh, max = rh, w_hint = rw})
    -- (margin-left 22: a boxed QLabel - its size counts the advance of 'x', it paints at half of it)
    local nw, nh = DW.label_hint(k[3], T.FONT, false, 22 + xw)
    add("note:" .. k[1], {hint = nh, w_hint = nw, h_hint = nh, text = k[3],
                          hfw = function(w) local _, h = DW.label_lines(k[3], T.FONT, false, w - 22 - xw) return h end})
  end
  if self.warn then
    local ww, wh = DW.label_hint(NP.WARNING, T.FONT, true, 0)
    add("warn", {hint = wh, w_hint = ww, h_hint = wh,
                 hfw = function(w) local _, h = DW.label_lines(NP.WARNING, T.FONT, true, w) return h end})
    local cw, ch = Q.check_size("Don't show again")
    add("dont", {hint = ch, min = ch, max = ch, w_hint = cw})
  end
  add("gap", {hint = 6, min = 6, max = 6, spacer = true, fixed = true, empty = true, w_hint = 0})
  local bw1, bh = Q.button_size("Cancel")
  local bw2 = Q.button_size("Create")
  add("buttons", {hint = bh, min = bh, max = bh, w_hint = bw1 + 8 + bw2})
  return items
end

-- QWidget::sizeHint of the dialog: the widest item's hint and the items' hints down (the labels' as their hints wrap);
-- measured while the dialog is a window of its own - Qt's top-level margins, 11 (in its window it has 9)
function NP:size_hint()
  local items = self:items()
  local w, h, n = 0, 0, 0
  for _, it in ipairs(items) do
    w = math.max(w, it.w_hint or 0)
    h = h + (it.h_hint or it.hint)
    if not it.empty then n = n + 1 end
  end
  return w + 22, h + (n - 1) * 8 + 22
end

function NP:frame(r)
  DW.background(r)
  local items = self:items()
  local placed = L.column(items, r.x, r.y, r.w, r.h, {margins = {9, 9, 9, 9}, spacing = 8})
  local xw = Q.label_indent(T.FONT)
  local hit = function(id, b) return self.win:hit(id, b) end
  for i, it in ipairs(items) do
    local b = placed[i]
    local key = it.key
    if key == "name" then
      local _, text, enter = CT.edit("dlg.np.name", b.x, b.y, b.w, self.name, {placeholder = "Name", tip = "proj.name", h = b.h})
      self.name = text
      if enter then self:done() end
    elseif key:sub(1, 6) == "radio:" then
      local k = key:sub(7)
      for _, kk in ipairs(NP.KINDS) do
        if kk[1] == k then
          if CT.radio("dlg.np." .. key, b.x, b.y, kk[2], self.kind == k) then self.kind = k end
        end
      end
    elseif key:sub(1, 5) == "note:" then
      local lines, lh = DW.label_lines(it.text, T.FONT, false, b.w - 22 - xw)
      local ty = b.y + Q.vcenter(b.h, lh)          -- (QLabel: AlignLeft | AlignVCenter, the half pixel down)
      for k, l in ipairs(lines) do Q.text(b.x + 22 + xw // 2, ty + (k - 1) * Q.line_h(), T.DIM, l.s, T.FONT, false, T.BG) end
    elseif key == "warn" then
      local lines, lh = DW.label_lines(NP.WARNING, T.FONT, true, b.w)
      local ty = b.y + Q.vcenter(b.h, lh)
      for k, l in ipairs(lines) do Q.text(b.x, ty + (k - 1) * Q.line_h(T.FONT, true), T.RED, l.s, T.FONT, true, T.BG) end
    elseif key == "dont" then
      local _, v = CT.check("dlg.np.dont", b.x, b.y, "Don't show again", self.dont_warn)
      if v ~= nil then self.dont_warn = v end
    elseif key == "buttons" then
      local bw1, bh = Q.button_size("Cancel")
      local bw2 = Q.button_size("Create")
      local x2 = b.x + b.w - bw2
      local x1 = x2 - 8 - bw1
      local named = self.name:match("%S") ~= nil
      if CT.button("dlg.np.cancel", x1, b.y, "Cancel", {w = bw1, h = bh}) then self.win:close() end
      if CT.button("dlg.np.create", x2, b.y, "Create", {w = bw2, h = bh, primary = true, disabled = not named}) then
        self:done()
      end
    end
  end
  local _ = hit
end

function NP:done()
  local name = self.name:match("^%s*(.-)%s*$")
  if name == "" then return end
  if self.warn and self.dont_warn then
    local cfg = CFG.load()
    cfg.new_project_warning_off = true
    CFG.save(cfg)
  end
  self.win:close()
  if self.then_ then self.then_(name, self.kind) end
end

return NP
