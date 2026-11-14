-- File > History over the game (profile_view.HistoryDialog): whether the project's history holds (every step signed
-- and unbroken, changed since its last step, or what is wrong - in red), its steps as a table (When, Who, What,
-- Changes, Tools: 130, 120, 80, 330 and the rest), the last step chosen; the chosen step's changes below it. A dialog
-- of at least 760 x 360 (setMinimumSize), its column 6 apart.
--   local b = HW.new(steps, check)   DW.open(panel, "history", "History of <name>", b)
local T = require("conjunction.ui.theme")
local Q = require("conjunction.ui.qt")
local DW = require("conjunction.ui.dialog_window")
local TB = require("conjunction.ui.table")
local Y = require("conjunction.yaml")
local HW = {}
HW.__index = HW

-- profile_view.state_text
function HW.state_text(check)
  if check == nil then return "No history (made before histories, or it was cut out)", false end
  if not check.ok then return check.problem, true end
  if check.changed_after then return "Every step signed and unbroken (changed since the last step)", false end
  return "Every step signed and unbroken", false
end
local function changes_text(s)
  local ch = (type(s.changes) == "table") and s.changes or {}
  if #ch == 0 then return "" end
  return #ch == 1 and ch[1] or string.format("%s (+%d more)", ch[1], #ch - 1)
end
local function str(v) if v == nil or v == Y.null then return "" end return tostring(v) end

function HW.new(steps, check)
  local self = setmetatable({steps = steps, check = check}, HW)
  self.table = TB.new({"When", "Who", "What", "Changes", "Tools"}, {130, 120, 80, 330})
  self.rows = {}
  for i, s in ipairs(steps) do
    local when = str(s.at):sub(1, 16):gsub("T", " ")
    local tools = {}
    for k, t in ipairs(type(s.tools) == "table" and s.tools or {}) do tools[k] = str(t) end
    local all = table.concat(tools, ", ")
    local ch = type(s.changes) == "table" and table.concat(s.changes, "\n") or ""
    self.rows[i] = {when, s.name ~= nil and str(s.name) or "?", s.label ~= nil and str(s.label) or str(s.step),
                    changes_text(s), all, tips = {ch, ch, ch, ch, all}}
  end
  self.table.on_click = function(i) self:show(i) end
  if #steps > 0 then
    self.table:select(#steps)
    self:show(#steps)
  end
  self.state, self.bad = HW.state_text(check)
  return self
end

function HW:show(i)
  local s = self.steps[i]
  local ch = type(s.changes) == "table" and s.changes or {}
  local head = str(s.label) .. " by " .. (s.name ~= nil and str(s.name) or "?")
  self.detail = head .. (#ch > 0 and (":\n" .. table.concat(ch, "\n")) or " (no changes named)")
end

-- its size hint: the minimum size wins (760 x 360)
function HW:size_hint() return 760, 360 end

-- a wrapped label's lines and height (text with its own line breaks: each paragraph wrapped)
local function lines_of(text, w)
  local out, h = {}, 0
  for para in (text .. "\n"):gmatch("(.-)\n") do
    local ls = DW.label_lines(para, T.FONT, false, w)
    for _, l in ipairs(ls) do out[#out + 1] = l end
  end
  return out, math.max(1, #out) * Q.line_h()
end

function HW:frame(r)
  DW.background(r)
  local x, y, w = r.x + 9, r.y + 9, r.w - 18
  local bottom = r.y + r.h - 9
  local sl, sh = lines_of(self.state, w)
  local dl, dh = lines_of(self.detail or "", w)
  local fg = self.bad and T.RED or T.TEXT
  for k, l in ipairs(sl) do Q.text(x, y + (k - 1) * Q.line_h(), fg, l.s, T.FONT, false, T.BG) end
  local ty = y + sh + 6
  local th = bottom - dh - 6 - ty
  self.table:frame({x = x, y = ty, w = w, h = th}, self.rows, function(id, b) return self.win:hit(id, b) end, "hist")
  local dy = bottom - dh
  for k, l in ipairs(dl) do Q.text(x, dy + (k - 1) * Q.line_h(), T.TEXT, l.s, T.FONT, false, T.BG) end
end

return HW
