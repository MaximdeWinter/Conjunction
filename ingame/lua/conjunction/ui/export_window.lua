-- The export window in the game (export_window.ask): before the export, what the quest's page will say - its name,
-- where it starts, its description - shown and changeable; any project can be exported, the open one first. A
-- QVBoxLayout (margins 20 16 20 16, 6 apart): Export (#head), the project's choice, the note, a form (Name, Starts,
-- Description: the labels' column as wide as its widest, 6 to the fields), Include the project, where the exports go,
-- the buttons (Open last export, Show exported quests | Cancel, Export). The description takes what height is left.
--   local d = EW.new(project, include_source, then_)    then_({project, include_source, rebuild})   DW.open(panel, "export", "Export", d)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local L = require("conjunction.ui.layout")
local PT = require("conjunction.ui.plaintext")
local DW = require("conjunction.ui.dialog_window")
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local EW = {}
EW.__index = EW

EW.INFO = "This is what the quest's Nexus page and the journal will show"
EW.SOURCE = "Include the project (others can open and change it)"
local FORM_GAP, SPACING, DESC_HINT = 6, 6, 192

local function start_line(project)
  local st = require("conjunction.packaging").starts_with(project) or {}
  local text = P.str(P.or_(P.get(st, "text"), ""))
  local world = P.get(st, "world")
  return text .. (P.T(world) and (" (" .. P.str(world) .. ")") or "")
end

-- the folder of the project's newest export, or nil
function EW.last_export(project) return require("conjunction.packaging").find_export(project:base_id()) end

function EW.new(project, include_source, then_)
  local self = setmetatable({open = project, include_source = include_source == true, then_ = then_}, EW)
  local PR = require("conjunction.project")
  self.paths, self.labels = {}, {}
  local function key(p) return PYS.lower((p:gsub("/", "\\"))) end
  local list = {project.path}
  for _, p in ipairs(PR.recent and PR.recent() or {}) do if key(p) ~= key(project.path) then list[#list + 1] = p end end
  for k, path in ipairs(list) do
    local ok, other = pcall(function() return k == 1 and project or PR.open(path) end)
    if ok and other then
      self.paths[#self.paths + 1] = path
      local label = P.or_(P.get(other.meta, "name"), other:id())
      self.labels[#self.labels + 1] = P.str(label) .. (k == 1 and "  (open)" or "")
    end
  end
  self.index = 1
  self:load()
  return self
end

-- the chosen project's values into the fields
function EW:load()
  local path = self.paths[self.index]
  self.project = path == self.open.path and self.open or require("conjunction.project").open(path)
  local meta = self.project.meta
  local q = P.map(P.get(meta, "quest"))
  self.place = P.get(meta, "kind") == "place"
  self.name = P.str(P.or_(self.place and P.get(meta, "name") or P.get(q, "title"), ""))
  local page = P.map(P.get(meta, "page"))
  self.starts = P.str(P.or_(P.get(P.map(P.get(page, "starts")), "text"), start_line(self.project)))
  self.desc = P.str(P.or_(P.get(q, "description"), P.get(meta, "description"), ""))
  self.last = EW.last_export(self.project)
  for _, id in ipairs({"dlg.ex.name", "dlg.ex.starts", "dlg.ex.desc"}) do CT.state(id).e = nil end
end

-- the column's items
function EW:items(width)
  local items = {}
  local function add(k, it) it.key = k items[#items + 1] = it end
  local head_h = Q.line_h(14, true) + 4
  add("head", {hint = head_h, min = head_h, max = head_h})
  local _, eh = Q.edit_size(118)
  add("which", {hint = 31, min = 31, max = 31})
  local iw, ih = DW.label_hint(EW.INFO, T.FONT, false, 0)
  add("info", {hint = ih, w_hint = iw, hfw = function(w) local _, h = DW.label_lines(EW.INFO, T.FONT, false, w) return h end})
  local rows = self.place and 2 or 3
  local fixed = (rows - 1) * (eh + FORM_GAP) + FORM_GAP
  add("form", {hint = fixed + DESC_HINT, min = fixed + 110, stretch = 1})
  local _, ch = Q.check_size(EW.SOURCE)
  add("source", {hint = ch, min = ch, max = ch})
  local where = "Exports go to " .. require("conjunction.packaging").EXPORTS
  local ww, wh = DW.label_hint(where, T.FONT, false, 0)
  add("where", {hint = wh, w_hint = ww, text = where,
                hfw = function(w) local _, h = DW.label_lines(where, T.FONT, false, w) return h end})
  local _, bh = Q.button_size("Cancel")
  add("buttons", {hint = bh, min = bh, max = bh})
  local _ = width
  return items
end

-- the dialog's size hint: at least 600 wide (setMinimumWidth), the items' hints down (the labels at the width given)
function EW:size_hint()
  local w = 600
  local items = self:items(w)
  local h = 0
  for _, it in ipairs(items) do h = h + (it.hfw and it.hfw(w - 40) or it.hint) end
  return w, h + (#items - 1) * SPACING + 32
end

function EW:frame(r)
  DW.background(r)
  local items = self:items(r.w)
  local placed = L.column(items, r.x, r.y, r.w, r.h, {margins = {20, 16, 20, 16}, spacing = SPACING})
  for i, it in ipairs(items) do
    local b = placed[i]
    local k = it.key
    if k == "head" then
      Q.text(b.x + Q.label_indent(14, true) // 2, b.y, T.BRIGHT, "Export", 14, true, T.BG)
    elseif k == "which" then
      local changed, index = CT.combo("dlg.ex.which", b.x, b.y, b.w, self.labels, self.index, self.win.rect, {h = b.h})
      if changed then self.index = index self:load() end
    elseif k == "info" or k == "where" then
      local text = k == "info" and EW.INFO or it.text
      local lines = DW.label_lines(text, T.FONT, false, b.w)
      for n, l in ipairs(lines) do Q.text(b.x, b.y + (n - 1) * Q.line_h(), T.DIM, l.s, T.FONT, false, T.BG) end
    elseif k == "form" then
      self:form(b)
    elseif k == "source" then
      local _, v = CT.check("dlg.ex.source", b.x, b.y, EW.SOURCE, self.include_source, {h = b.h})
      if v ~= nil then self.include_source = v end
    elseif k == "buttons" then
      self:buttons(b)
    end
  end
end

-- QFormLayout: the labels' column as wide as its widest label, each label as high as its field less 2, its text in
-- the middle; 6 between the rows and to the fields
function EW:form(b)
  local _, eh = Q.edit_size(118)
  local labels = self.place and {"Name", "Description"} or {"Name", "Starts", "Description"}
  local lw = 0
  for _, s in ipairs(labels) do lw = math.max(lw, Q.hint_w(s)) end
  local fx, fw = b.x + lw + FORM_GAP, b.w - lw - FORM_GAP
  local y = b.y
  for _, s in ipairs(labels) do
    local lh = eh - 2
    Q.text(b.x, y + Q.vcenter(lh, Q.line_h()), T.TEXT, s, T.FONT, false, T.BG)
    if s == "Name" then
      local _, text = CT.edit("dlg.ex.name", fx, y, fw, self.name, {placeholder = "Name", h = eh})
      self.name = text
      y = y + eh + FORM_GAP
    elseif s == "Starts" then
      local _, text = CT.edit("dlg.ex.starts", fx, y, fw, self.starts, {placeholder = "Where it starts", h = eh})
      self.starts = text
      y = y + eh + FORM_GAP
    else
      local dh = b.y + b.h - y
      local _, text = PT.edit("dlg.ex.desc", fx, y, fw, dh, self.desc, {placeholder = "Description (optional)",
                                                                   look = {fg = T.TEXT}})   -- (the sheet: a dialog's text)
      self.desc = text
    end
  end
end

function EW:buttons(b)
  local w1 = Q.button_size("Open last export")
  local w2 = Q.button_size("Show exported quests")
  local wc = Q.button_size("Cancel")
  local we = Q.button_size("Export")
  local PK = require("conjunction.packaging")
  if CT.button("dlg.ex.last", b.x, b.y, "Open last export", {w = w1, h = b.h, disabled = self.last == nil,
                                                              tip = {"", self.last or "Not exported yet"}}) then
    if self.last then EW.show(self.last) end
  end
  if CT.button("dlg.ex.all", b.x + w1 + 6, b.y, "Show exported quests", {w = w2, h = b.h, tip = {"", PK.EXPORTS}}) then
    EW.show(PK.EXPORTS)
  end
  local xe = b.x + b.w - we
  local xc = xe - 6 - wc
  if CT.button("dlg.ex.cancel", xc, b.y, "Cancel", {w = wc, h = b.h}) then self.win:close() end
  local named = self.name:match("%S") ~= nil
  if CT.button("dlg.ex.go", xe, b.y, "Export", {w = we, h = b.h, primary = true, disabled = not named}) then
    self:done()
  end
end

-- a folder shown (QDesktopServices.openUrl: Explorer)
function EW.show(folder)
  require("conjunction.build").makedirs(folder)
  if w3.proc then require("conjunction.fsutil").show(folder) end
end

-- the window's values into the project -> {include_source, rebuild} (rebuild: the name changed)
function EW.apply(project, name, start, description, include_source)
  local meta = project.meta
  local place = P.get(meta, "kind") == "place"
  name, start, description = PYS.strip(name), PYS.strip(start), PYS.strip(description)
  local rebuild = false
  if place then
    if name ~= "" and name ~= P.get(meta, "name") then
      meta.name = name
      rebuild = true
    end
    meta.description = description
  else
    if not Y.is_map(meta.quest) then meta.quest = Y.map() end
    local q = meta.quest
    if name ~= "" and name ~= P.get(q, "title") then
      q.title = name
      rebuild = true
    end
    q.description = description
    if not Y.is_map(meta.page) then meta.page = Y.map() end
    local page = meta.page
    if start ~= "" and start ~= start_line(project) then
      page.starts = Y.map({"text", start, "world", ""})
    else
      Y.remove(page, "starts")
    end
    if next(Y.keys(page)) == nil then Y.remove(meta, "page") end
  end
  project:save_meta()
  return {include_source = include_source, rebuild = rebuild}
end

function EW:done()
  if not self.name:match("%S") then return end
  local values = EW.apply(self.project, self.name, self.starts, self.desc, self.include_source)
  values.project = self.project
  self.win:close()
  if self.then_ then self.then_(values) end
end

return EW
