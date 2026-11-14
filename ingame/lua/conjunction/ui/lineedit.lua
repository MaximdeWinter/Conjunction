-- The editing model of Qt's QLineEdit, without drawing (ui/controls.lua draws and feeds it). Positions are Qt's cursor
-- positions: 0 before the first letter, n after the last (n letters; a letter is one UTF-8 code point).
--
-- Measured against Qt (ingame/ref/behave_edit.py -> behave_edit.txt, lab test edit_behave.lua):
-- * words: runs of letters/digits/_ , runs of other signs, runs of spaces; Ctrl+Left goes to the start of the word
--   before (over spaces), Ctrl+Right to the start of the next one (or the end)
-- * Left/Right with a selection move one letter from the cursor and drop the selection
-- * undo: typing in a row is one step, deleting in a row is one step, a move ends a step; undo brings back the text,
--   the cursor and the selection from before the step
local E = {}
E.__index = E

local function letters(text)
  local out = {}
  for _, cp in utf8.codes(text) do out[#out + 1] = utf8.char(cp) end
  return out
end
local function class(ch)
  if ch:match("^%s$") then return "s" end
  if ch:match("^[%w_]$") or #ch > 1 then return "w" end
  return "p"
end

function E.new(text)
  local e = setmetatable({}, E)
  e:set(text or "")
  e.undo, e.redo = {}, {}
  return e
end

function E:set(text)
  self.chars = letters(text)
  self.cur = #self.chars
  self.anchor = nil
  self.kind = nil
end
function E:text() return table.concat(self.chars) end
function E:sel()
  if not self.anchor or self.anchor == self.cur then return nil end
  return math.min(self.anchor, self.cur), math.max(self.anchor, self.cur)
end
function E:selected()
  local a, b = self:sel()
  if not a then return "" end
  return table.concat(self.chars, "", a + 1, b)
end

-- word boundaries
function E:word_left(pos)
  local c = self.chars
  local i = pos
  while i > 0 and class(c[i]) == "s" do i = i - 1 end
  if i == 0 then return 0 end
  local k = class(c[i])
  while i > 0 and class(c[i]) == k do i = i - 1 end
  return i
end
function E:word_right(pos)
  local c = self.chars
  local n = #c
  local i = pos
  if i < n and class(c[i + 1]) ~= "s" then
    local k = class(c[i + 1])
    while i < n and class(c[i + 1]) == k do i = i + 1 end
  end
  while i < n and class(c[i + 1]) == "s" do i = i + 1 end
  return i
end

-- undo groups
function E:snapshot() return {chars = {table.unpack(self.chars)}, cur = self.cur, anchor = self.anchor} end
function E:restore(s) self.chars, self.cur, self.anchor = {table.unpack(s.chars)}, s.cur, s.anchor end
function E:begin(kind)
  if self.kind ~= kind or self:sel() then
    self.undo[#self.undo + 1] = self:snapshot()
    self.redo = {}
  end
  self.kind = kind
end

-- editing
function E:remove(a, b)   -- letters a+1 .. b
  for _ = a + 1, b do table.remove(self.chars, a + 1) end
  self.cur, self.anchor = a, nil
end
function E:insert(s)
  self:begin("insert")
  local a, b = self:sel()
  if a then self:remove(a, b) end
  for _, ch in ipairs(letters(s)) do
    table.insert(self.chars, self.cur + 1, ch)
    self.cur = self.cur + 1
  end
  self.anchor = nil
end
function E:backspace(word)
  local a, b = self:sel()
  if not a and self.cur == 0 then return end
  self:begin("delete")
  if a then self:remove(a, b) return end
  self:remove(word and self:word_left(self.cur) or self.cur - 1, self.cur)
end
function E:delete(word)
  local a, b = self:sel()
  if not a and self.cur == #self.chars then return end
  self:begin("delete")
  if a then self:remove(a, b) return end
  self:remove(self.cur, word and self:word_right(self.cur) or self.cur + 1)
end

-- moving (a move ends an undo step)
function E:move(to, select)
  to = math.max(0, math.min(#self.chars, to))
  if select then self.anchor = self.anchor or self.cur else self.anchor = nil end
  self.cur = to
  self.kind = nil
end
function E:select_all() self.anchor, self.cur, self.kind = 0, #self.chars, nil end
function E:select_word(pos)
  local c = self.chars
  if #c == 0 then return end
  local i = math.max(1, math.min(#c, pos + 1))
  local k = class(c[i])
  local a, b = i - 1, i
  while a > 0 and class(c[a]) == k do a = a - 1 end
  while b < #c and class(c[b + 1]) == k do b = b + 1 end
  self.anchor, self.cur, self.kind = a, b, nil
end

function E:do_undo()
  if #self.undo == 0 then return false end
  self.redo[#self.redo + 1] = self:snapshot()
  self:restore(table.remove(self.undo))
  self.kind = nil
  return true
end
function E:do_redo()
  if #self.redo == 0 then return false end
  self.undo[#self.undo + 1] = self:snapshot()
  self:restore(table.remove(self.redo))
  self.kind = nil
  return true
end

-- one key as QLineEdit takes it: name (ImGui's), ctrl, shift -> true when the text changed
function E:key(name, ctrl, shift)
  local before = self:text()
  if name == "LeftArrow" then self:move(ctrl and self:word_left(self.cur) or self.cur - 1, shift)
  elseif name == "RightArrow" then self:move(ctrl and self:word_right(self.cur) or self.cur + 1, shift)
  elseif name == "Home" then self:move(0, shift)
  elseif name == "End" then self:move(#self.chars, shift)
  elseif name == "Backspace" then self:backspace(ctrl)
  elseif name == "Delete" then self:delete(ctrl)
  elseif name == "A" and ctrl then self:select_all()
  elseif name == "Z" and ctrl then self:do_undo()
  elseif name == "Y" and ctrl then self:do_redo()
  end
  return self:text() ~= before
end

return E
