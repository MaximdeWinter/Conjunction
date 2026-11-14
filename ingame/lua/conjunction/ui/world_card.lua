-- The card for an object the game placed (conjunction/world_card.py; edit existing on, one selected): remove it,
-- play one of its effects on it, give it another look - each kept as a world change (worldchanges.lua) the script
-- extender applies; the changes kept for it below, each with its x. In the inspector's box, in its place.
-- A QFrame: a column with margins 6 (the panel's QLabel 13 px #ccc; the title bold, the note #c9a).
--   local wc = WC.new(panel)      wc:show_object(sel, project_path)   wc:set_info(effects, looks)   wc:say(text)
--   wc:frame(rect)                 (the box's rect: 330 wide; the card stands 8 in)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local L = require("conjunction.ui.layout")
local CT = require("conjunction.ui.controls")
local TL = require("conjunction.ui.textlayout")
local W = require("conjunction.worldchanges")
local WC = {}
WC.__index = WC

local function rgba(s) return (tonumber(s:sub(2), 16) << 8) | 255 end
local C = {label = rgba("#cccccc"), note = rgba("#cc99aa")}

function WC.new(panel)
  return setmetatable({panel = panel, sel = nil, effects = {}, looks = {}, fx_i = 1, app_i = 1, changes = {}}, WC)
end

-- sel: the selected object's report {guid, name, template, pos}
function WC:show_object(sel, project_path)
  self.sel = sel
  self.title = W.short_name(sel.name or sel.template)
  if self.title == "" then self.title = "Object" end
  self.lasting = W.guid_ok(sel.guid)
  self.note = self.lasting and "" or "Made by the game while playing, it cannot be changed permanently"
  self:set_info({}, {})
  self:refresh(project_path)
end
-- what it can play and switch to (the game's worldinfo line)
function WC:set_info(effects, looks)
  self.effects, self.looks = effects or {}, looks or {}
  self.fx_i, self.app_i = 1, 1
end
function WC:say(text) self.note = text end
function WC:refresh(project_path)
  self.changes = {}
  local guid = (self.sel or {}).guid
  for _, c in ipairs(W.load(project_path) or {}) do
    if c.guid == guid then self.changes[#self.changes + 1] = c end
  end
end

local function lines_of(text, px, bold, w) return TL.wrap(text, px, bold, math.max(0, w), "word") end
local function label_h(text, px, bold, w) return math.max(1, #lines_of(text, px, bold, w)) * Q.line_h(px, bold) end

function WC:hit(id, r) return self.panel:hit(id, r) end

function WC:frame(box)
  local pn = self.panel
  local ed = pn.ed
  local x, w = box.x + 8 + 6, box.w - 8 - 12
  local y = box.y + 6
  local PN = require("conjunction.ui.panel")
  -- the title (bold), the note
  local th = label_h(self.title, 13, true, w)
  for k, l in ipairs(lines_of(self.title, 13, true, w)) do Q.text(x, y + (k - 1) * Q.line_h(13, true), C.label, l.s, 13, true) end
  y = y + th + 6
  local nh = label_h(self.note, 13, false, w)
  for k, l in ipairs(lines_of(self.note, 13, false, w)) do Q.text(x, y + (k - 1) * Q.line_h(13), C.note, l.s, 13) end
  y = y + nh + 6
  -- Remove
  local b = {x = x, y = y, w = w, h = 29}
  local clicked, hv, held = self:hit("wc.remove", b)
  local off = not self.lasting
  Q.button(b.x, b.y, b.w, b.h, "Remove", {hover = (hv or held) and not off, pressed = held and hv and not off,
                                          disabled = off, fg = T.BUTTON_TEXT})
  if hv then CT.tip("panel.wc.remove", "world.remove") end
  if clicked and not off and ed.world_remove then ed:world_remove() end
  y = y + 29 + 6
  -- Effect [the effects] [On] [Off];  Look [the looks] [Set]
  local function row(label, names, idx_key, buttons, id)
    local items = {{hint = Q.hint_w(label), min = Q.hint_w(label), max = Q.hint_w(label), cross = 31, cross_max = 31}}
    items[#items + 1] = {hint = 0, min = 0, stretch = 1, cross = 31, cross_max = 31}
    for _, bt in ipairs(buttons) do
      local bw = Q.hint_w(bt[1]) + 22
      items[#items + 1] = {hint = bw, min = bw, max = bw, cross = 29, cross_max = 29}
    end
    local placed = L.row(items, x, y, w, 31, {spacing = 6})
    local l = placed[1]
    Q.text(l.x, l.y + Q.vcenter(l.h, Q.line_h()), C.label, label, T.FONT)
    local enabled = #names > 0 and self.lasting
    local cb = placed[2]
    if enabled then
      local changed, i = CT.combo("panel.wc." .. id, cb.x, cb.y, cb.w, names, self[idx_key], pn.lay and pn.lay.frame,
                                  {h = 31, fg = T.BRIGHT})
      if changed then self[idx_key] = i end
    else
      Q.combo(cb.x, cb.y, cb.w, cb.h, names[self[idx_key]] or "", {fg = T.BRIGHT})
    end
    for k, bt in ipairs(buttons) do
      local r = placed[2 + k]
      local c2, h2, held2 = self:hit("wc." .. id .. "." .. k, r)
      Q.button(r.x, r.y, r.w, r.h, bt[1], {hover = (h2 or held2) and enabled, pressed = held2 and h2 and enabled,
                                           disabled = not enabled, fg = T.BUTTON_TEXT})
      if h2 then CT.tip("panel.wc." .. id .. "." .. k, bt[2]) end
      if c2 and enabled then bt[3](names[self[idx_key]]) end
    end
    y = y + 31 + 6
  end
  row("Effect", self.effects, "fx_i", {
    {"On", "world.effect_on", function(n) if n and n ~= "" and ed.world_effect then ed:world_effect(n, true) end end},
    {"Off", "world.effect_off", function(n) if n and n ~= "" and ed.world_effect then ed:world_effect(n, false) end end},
  }, "fx")
  row("Look", self.looks, "app_i", {
    {"Set", "world.look", function(n) if n and n ~= "" and ed.world_look then ed:world_look(n) end end},
  }, "app")
  -- the changes kept for it: "Effect fire  (change 1)" [x]
  local DO = {remove = "Removed", move = "Moved"}
  for _, c in ipairs(self.changes) do
    local text = DO[c["do"]] or (c["do"] == "effect" and ("Effect " .. tostring(c.value or "")))
                 or (c["do"] == "look" and ("Look " .. tostring(c.value or ""))) or tostring(c["do"])
    text = text .. "  (change " .. tostring(c.id) .. ")"
    local placed = L.row({{hint = 0, min = 0, stretch = 1, cross = 29, cross_max = 29},
                          {hint = 24, min = 24, max = 24, cross = 29, cross_max = 29}}, x, y, w, 29, {spacing = 6})
    local l = placed[1]
    Q.text(l.x, l.y + Q.vcenter(l.h, Q.line_h()), C.label, text, T.FONT)
    local r = placed[2]
    local c2, h2, held2 = self:hit("wc.drop." .. tostring(c.id), r)
    Q.button(r.x, r.y, r.w, r.h, "x", {hover = h2 or held2, pressed = held2 and h2, fg = T.BUTTON_TEXT})
    if h2 then CT.tip("panel.wc.drop", "world.drop") end
    if c2 and ed.world_drop then ed:world_drop(c.id) end
    y = y + 29 + 6
  end
  local _ = PN
end

return WC
