-- The model of Qt's QSpinBox / QDoubleSpinBox, without drawing (ui/controls.lua draws and feeds it).
-- Measured against Qt (ingame/ref/behave_spin.py -> behave_spin.txt, lab test spin_behave.lua):
-- * the wheel steps without the keyboard focus, one step per notch (half notches add up), Ctrl ten steps
-- * Up/Down one step, PageUp/PageDown ten (with the focus)
-- * typed text that would go past the maximum is refused (999: "1234" stays "123"); the decimal sign is Windows'
--   (w3.ui.locale: "," here), another sign is refused; Enter takes the text, clamped, written again with its decimals
local LE = require("conjunction.ui.lineedit")
local S = {}
S.__index = S

local DEC = nil
local function dec_of_windows()
  if not DEC then DEC = (w3.ui and w3.ui.locale and w3.ui.locale()) or "." end
  return DEC
end

-- opts: min, max, step, decimals, dec (the decimal sign: "." for a box set to QLocale.c(), else Windows')
function S.new(value, opts)
  opts = opts or {}
  local s = setmetatable({min = opts.min or 0, max = opts.max or 99, step = opts.step or 1, decimals = opts.decimals or 0,
                          wheel = 0, dec = opts.dec, special = opts.special}, S)
  s.value = s:clamp(value or 0)
  s.edit = LE.new(s:format(s.value))
  return s
end

function S:clamp(v)
  if v < self.min then v = self.min end
  if v > self.max then v = self.max end
  if self.decimals == 0 then v = math.floor(v + 0.5) else
    local m = 10 ^ self.decimals
    v = math.floor(v * m + 0.5) / m
  end
  return v
end

function S:format(v)
  if self.special and v == self.min then return self.special end     -- (setSpecialValueText: the minimum's words)
  if self.decimals == 0 then return string.format("%d", math.floor(v + 0.5)) end
  return (string.format("%." .. self.decimals .. "f", v):gsub("%.", self.dec or dec_of_windows()))
end

function S:parse(text)
  if self.special and text == self.special then return self.min end
  local t = text:gsub((self.dec or dec_of_windows()):gsub("%p", "%%%0"), ".")
  return tonumber(t)
end

-- would Qt's validator let this text stand while typing?
function S:acceptable(text)
  if text == "" or text == "-" then return self.min < 0 or text == "" end
  local d = (self.dec or dec_of_windows()):gsub("%p", "%%%0")
  local int, frac = text:match("^(%-?%d*)" .. d .. "(%d*)$")
  if not int then int = text:match("^(%-?%d+)$") end
  if not int then return false end
  if frac and (self.decimals == 0 or #frac > self.decimals) then return false end
  if int:sub(1, 1) == "-" and self.min >= 0 then return false end
  local v = self:parse(text)
  if v and v > self.max and v > 0 then return false end
  if v and v < self.min and v < 0 then return false end
  return true
end

function S:type(chars)
  for _, cp in utf8.codes(chars) do
    local before = self.edit:text()
    local snap = self.edit:snapshot()
    self.edit:insert(utf8.char(cp))
    if not self:acceptable(self.edit:text()) then self.edit:restore(snap) end
    if self.edit:text() == before then self.edit:restore(snap) end
  end
end

function S:set(v)
  self.value = self:clamp(v)
  self.edit = LE.new(self:format(self.value))
end
function S:step_by(n) self:set((self:parse(self.edit:text()) or self.value) + n * self.step) end
function S:commit() self:set(self:parse(self.edit:text()) or self.value) end

-- the wheel: notches (1 = 120 of Windows' units); returns true when it stepped
function S:on_wheel(notches, ctrl)
  self.wheel = self.wheel + notches
  local whole = self.wheel >= 0 and math.floor(self.wheel + 1e-6) or -math.floor(-self.wheel + 1e-6)
  if whole == 0 then return false end
  self.wheel = self.wheel - whole
  self:step_by(whole * (ctrl and 10 or 1))
  return true
end

function S:key(name, ctrl, shift)
  if name == "UpArrow" then self:step_by(1)
  elseif name == "DownArrow" then self:step_by(-1)
  elseif name == "PageUp" then self:step_by(10)
  elseif name == "PageDown" then self:step_by(-10)
  elseif name == "Enter" or name == "KeypadEnter" then self:commit()
  else self.edit:key(name, ctrl, shift) end
end

return S
