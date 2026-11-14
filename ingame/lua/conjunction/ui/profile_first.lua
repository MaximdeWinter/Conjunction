-- The first start's profile dialogs (profile_view.first_hint, ask_first), over the game as dialogs.run_dialog shows a
-- dialog: "Profile (optional)" - what a profile is, Not now, Make a profile - said once (config profile_hint_shown);
-- "Your name" - the name a new profile signs with (OK once one is typed), then the key made and How signing works.
-- A QVBoxLayout, margins 20 16, 6 apart, at least 460 wide; the room the window gives beyond the hints goes to the
-- labels, shared as qGeomCalc shares it (layout.lua).
--   PF.first_hint(ed)   PF.ask_first(ed)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local L = require("conjunction.ui.layout")
local DW = require("conjunction.ui.dialog_window")
local CFG = require("conjunction.config")
local ID = require("conjunction.identity")
local PF = {}

PF.HINT = "A profile signs what you make with your name, so it shows that a quest is yours. It is a name and a key " ..
          "file on this PC. You can make one now or later in Settings > Profile"
PF.NAME = "Shown in the history of everything made with Conjunction (more profiles and a new name in Settings > " ..
          "Profile)"

local Body = {}
Body.__index = Body
PF.Body = Body

-- kind "hint" | "name"
function Body.new(kind, then_)
  local self = setmetatable({kind = kind, then_ = then_, name = ""}, Body)
  if kind == "name" then CT.state("dlg.pf.name").e = nil end
  return self
end
function Body:items()
  local items = {}
  local function add(key, it) it.key = key items[#items + 1] = it end
  local head = self.kind == "hint" and "Profile (optional)" or "Your name"
  local hw, hh = Q.label_size(head, "head")
  add("head", {hint = hh, w_hint = hw, h_hint = hh, text = head})
  local info = self.kind == "hint" and PF.HINT or PF.NAME
  local iw, ih = DW.label_hint(info, T.FONT, false, 0)
  add("info", {hint = ih, w_hint = iw, h_hint = ih, text = info,
               hfw = function(w) local _, h = DW.label_lines(info, T.FONT, false, w) return h end})
  if self.kind == "name" then
    local ew, eh = Q.edit_size(118)
    add("edit", {hint = eh, min = eh, max = eh, w_hint = ew})
  end
  local _, bh = Q.button_size("OK")
  local bw = self.kind == "hint" and (Q.button_size("Not now") + 6 + Q.button_size("Make a profile")) or
             Q.button_size("OK")
  add("buttons", {hint = bh, min = bh, max = bh, w_hint = bw})
  return items
end
function Body:size_hint()
  local w, h, n = 0, 0, 0
  for _, it in ipairs(self:items()) do
    w = math.max(w, it.w_hint or 0)
    h = h + (it.h_hint or it.hint)
    n = n + 1
  end
  return math.max(460, w + 40), h + (n - 1) * 6 + 32
end
function Body:frame(r)
  DW.background(r)
  local items = self:items()
  local placed = L.column(items, r.x, r.y, r.w, r.h, {margins = {20, 16, 20, 16}, spacing = 6})
  for i, it in ipairs(items) do
    local b = placed[i]
    if it.key == "head" then
      local _, lh = Q.label_size(it.text, "head")
      Q.label(b.x, b.y + Q.vcenter(b.h, lh), it.text, "head", T.BG)
    elseif it.key == "info" then
      local lines, lh = DW.label_lines(it.text, T.FONT, false, b.w)
      local ty = b.y + Q.vcenter(b.h, lh)
      for k, l in ipairs(lines) do Q.text(b.x, ty + (k - 1) * Q.line_h(), T.TEXT, l.s, T.FONT, false, T.BG) end
    elseif it.key == "edit" then
      local _, text, enter = CT.edit("dlg.pf.name", b.x, b.y, b.w, self.name, {placeholder = "Name", h = b.h})
      self.name = PF.cut(text)
      if enter then self:ok() end
    elseif it.key == "buttons" then
      local _, bh = Q.button_size("OK")
      if self.kind == "hint" then
        local mw = Q.button_size("Make a profile")
        local nw = Q.button_size("Not now")
        local mx = b.x + b.w - mw
        local nx = mx - 6 - nw
        if CT.button("dlg.pf.later", nx, b.y, "Not now", {w = nw, h = bh}) then self.win:close() end
        if CT.button("dlg.pf.make", mx, b.y, "Make a profile", {w = mw, h = bh}) then
          self.win:close()
          if self.then_ then self.then_(true) end
        end
      else
        local ow = Q.button_size("OK")
        local named = self.name:match("%S") ~= nil
        if CT.button("dlg.pf.ok", b.x + b.w - ow, b.y, "OK", {w = ow, h = bh, disabled = not named}) then self:ok() end
      end
    end
  end
end
-- (setMaxLength(40))
function PF.cut(s)
  local n = 0
  for p in utf8.codes(s) do
    n = n + 1
    if n > 40 then return s:sub(1, p - 1) end
  end
  return s
end
function Body:ok()
  local name = self.name:match("^%s*(.-)%s*$")
  if name == "" then return end
  self.win:close()
  if self.then_ then self.then_(name) end
end

local function panel_of(ed) return ed.panel or ed end

-- the name a new profile signs with: the key made, How signing works shown
function PF.ask_first(ed)
  if #ID.profiles() > 0 then return end
  DW.open(panel_of(ed), "ask first", "Conjunction", Body.new("name", function(name)
    local p = ID.create(name)
    require("conjunction.ui.dialogs").how_signing(ed, p)
  end))
end

-- once, at the first start: what a profile is (a profile is opt-in, never asked for)
function PF.first_hint(ed)
  local cfg = CFG.load()
  if #ID.profiles() > 0 or (cfg.profile_hint_shown ~= nil and cfg.profile_hint_shown ~= false) then return end
  cfg.profile_hint_shown = true
  CFG.save(cfg)
  DW.open(panel_of(ed), "first hint", "Conjunction", Body.new("hint", function() PF.ask_first(ed) end))
end

return PF
