-- radish missing at the start (radish_view.ask): radish's Nexus page to download it, then Conjunction finds the zip in
-- Downloads (Check again) or the user picks it; unpacked and checked (radish_tools.lua). A QVBoxLayout, margins 20 16,
-- 6 apart, at least 560 wide: the head, what radish is for, its link (GOLD, underlined), a status line, the buttons
-- at the right (Later, Check again, Pick the zip ..., Download on Nexus).
--   RW.open(ed, then_)     then_(folder) once radish is there
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local CT = require("conjunction.ui.controls")
local L = require("conjunction.ui.layout")
local DW = require("conjunction.ui.dialog_window")
local RT = require("conjunction.radish_tools")
local D = w3.ui.draw
local RW = {}

RW.HEAD = "radish modding tools are missing"
RW.INFO = "Conjunction builds quests with the radish modding tools by rmemr. Download the zip from its Nexus page " ..
          "(Manual download). Conjunction finds it in your Downloads folder, or pick it here. Until then everything " ..
          "works except building"
RW.BUTTONS = {"Later", "Check again", "Pick the zip ...", "Download on Nexus"}

local Body = {}
Body.__index = Body
RW.Body = Body

function Body.new(ed, then_)
  return setmetatable({ed = ed, then_ = then_, status = ""}, Body)
end

local function wrapped(key, text)
  local w, h = DW.label_hint(text, T.FONT, false, 0)
  return {key = key, hint = h, w_hint = w, h_hint = h, text = text,
          hfw = function(width) local _, hh = DW.label_lines(text, T.FONT, false, width) return hh end}
end
function Body:items()
  local items = {}
  local hw, hh = Q.label_size(RW.HEAD, "head")
  items[#items + 1] = {key = "head", hint = hh, w_hint = hw, h_hint = hh, text = RW.HEAD}
  items[#items + 1] = wrapped("info", RW.INFO)
  local lw, lh = Q.label_size(RT.NEXUS)
  items[#items + 1] = {key = "link", hint = lh, w_hint = lw, h_hint = lh, text = RT.NEXUS}
  items[#items + 1] = wrapped("status", self.status)
  local _, bh = Q.button_size("OK")
  local bw = 0
  for k, t in ipairs(RW.BUTTONS) do bw = bw + Q.button_size(t) + (k > 1 and 6 or 0) end
  items[#items + 1] = {key = "buttons", hint = bh, min = bh, max = bh, w_hint = bw}
  return items
end
function Body:size_hint()
  local w, h, n = 0, 0, 0
  for _, it in ipairs(self:items()) do
    w = math.max(w, it.w_hint or 0)
    h = h + (it.h_hint or it.hint)
    n = n + 1
  end
  return math.max(560, w + 40), h + (n - 1) * 6 + 32
end

-- the zip unpacked and checked: radish there, the window closed; or what is wrong in the status line
function Body:take(zip)
  local ok, got = pcall(RT.install_from, zip, function() end)
  if ok then
    self.win:close()
    if self.then_ then self.then_(got) end
  else
    self.status = RT.message(got)
  end
end

function Body:frame(r)
  if self.taking and self.shown_busy then       -- (the status says what it does first: unpacking takes a moment)
    local z = self.taking
    self.taking, self.shown_busy = nil, nil
    self:take(z)
  elseif self.taking then
    self.shown_busy = true
  end
  DW.background(r)
  local items = self:items()
  local placed = L.column(items, r.x, r.y, r.w, r.h, {margins = {20, 16, 20, 16}, spacing = 6})
  for i, it in ipairs(items) do
    local b = placed[i]
    if it.key == "head" then
      local _, lh = Q.label_size(it.text, "head")
      Q.label(b.x, b.y + Q.vcenter(b.h, lh), it.text, "head", T.BG)
    elseif it.key == "info" or it.key == "status" then
      local lines, lh = DW.label_lines(it.text, T.FONT, false, b.w)
      local ty = b.y + Q.vcenter(b.h, lh)
      for k, l in ipairs(lines) do Q.text(b.x, ty + (k - 1) * Q.line_h(), T.TEXT, l.s, T.FONT, false, T.BG) end
    elseif it.key == "link" then
      local lh = Q.line_h()
      local ty = b.y + (b.h - lh) // 2           -- (a rich text label: its document centred rounded down)
      local w = Q.text_w(it.text, T.FONT)
      Q.text(b.x, ty, T.GOLD, it.text, T.FONT, false, T.BG)
      D.fill(b.x, ty + lh - 2, w, 1, T.GOLD)      -- (the underline: Segoe UI's, 2 px above the line's end)
      local clicked, hovered = self.win:hit("radish.link", {x = b.x, y = ty, w = w, h = lh})
      if hovered then w3.ui.cursor("hand") end
      if clicked and w3.proc then require("conjunction.fsutil").show(RT.NEXUS) end
    elseif it.key == "buttons" then
      local _, bh = Q.button_size("OK")
      local x = b.x + b.w
      local xs = {}
      for k = #RW.BUTTONS, 1, -1 do
        local bw = Q.button_size(RW.BUTTONS[k])
        x = x - bw
        xs[k] = {x, bw}
        x = x - 6
      end
      local pressed = {}
      for k, t in ipairs(RW.BUTTONS) do
        pressed[k] = CT.button("dlg.radish." .. k, xs[k][1], b.y, t, {w = xs[k][2], h = bh, default = k == 4})
      end
      if pressed[1] then self.win:close() end
      if pressed[2] then
        local z = RT.find_zip()
        if z then self.status, self.taking = "Unpacking and checking radish...", z
        else self.status = "Not in Downloads yet" end
      end
      if pressed[3] then
        require("conjunction.ui.dialogs").pick_file(self.ed, "The radish zip from Nexus", "", "Zip (*.zip)",
                                                    function(p)
          if p and p ~= "" then self.status, self.taking = "Unpacking and checking radish...", p end
        end)
      end
      if pressed[4] and w3.proc then require("conjunction.fsutil").show(RT.NEXUS) end
    end
  end
end

function RW.open(ed, then_)
  return DW.open(ed.panel or ed, "radish", "Conjunction", Body.new(ed, then_))
end

return RW
