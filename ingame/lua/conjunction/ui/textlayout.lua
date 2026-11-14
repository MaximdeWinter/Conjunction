-- Lines as Qt sets a paragraph into a width (qtextlayout.cpp QTextLine::layout_helper): word by word - a break only
-- where qtbreak.lua allows one, the spaces before a word count once the word is taken, the spaces at a line's end
-- hang over it (trailing), a word wider than the line stays whole (WordWrap) or, with WrapAtWordBoundaryOrAnywhere,
-- the line is set again breaking anywhere (at grapheme boundaries). Widths are the text engine's pen positions
-- (w3.ui.text_offsets: Qt's advances with their kerning).
--   local lines = TL.lines(text, px, bold, width, mode)    mode "word" (QLabel's WordWrap, default) | "word_any" |
--                                                          "any" -> {{from, length, trailing, width}, ...}
--                                                          (code point indices from 1; width: the line's text, its
--                                                          trailing spaces not in it)
-- Checked against Qt's QTextLayout: ingame/ref/textlayout_check.py.
local QB = require("conjunction.qtbreak")
local S = require("conjunction.pystr")
-- a text's style for w3.ui: true -> "bold", "mono" (Consolas: a log) as it is
local function style_of(bold) if bold == "mono" then return "mono" end return bold and "bold" or nil end
local TL = {}
TL.TAB = 80                                       -- QTextOption::tabStopDistance's default (px)

-- characters whose decomposition is <noBreak> (QChar::decompositionTag() == NoBreak): white space that does not break
local NOBREAK = {[0xa0] = true, [0x2007] = true, [0x202f] = true, [0x0f0c] = true, [0x2011] = true}

local function offsets(text, px, bold)
  return w3.ui.text_offsets(text, px, style_of(bold))
end

-- one line from position from (1-based) of cps, at most width wide. rb: each letter's right bearing (1/64 px, Qt's
-- QFixed), least: the font's least (only near the edge is a letter's own looked at, as Qt does)
local NOT_CALC = 1                                -- (RightBearingNotCalculated: QFixed(1), in 1/64)
local function layout_line(cps, attr, adv, rb, least, from, width, mode)
  local n = #cps
  local brk, white = attr.brk, attr.white
  local breakany = mode == "any"
  local line = {w = 0, len = 0}
  local tmp = {w = 0, len = 0}
  local space = {w = 0, len = 0}
  local pos = from
  local right = NOT_CALC                          -- the right bearing taken into account (1/64, <= 0) or not yet
  local previous = nil                            -- the letter before (for its bearing)
  local ws_or_obj = false
  local min_rb = math.abs(math.min(0, least)) / 64
  local function neg_rb() return right == NOT_CALC and 0 or math.abs(right) / 64 end
  local function new_width() return line.w + tmp.w + space.w + neg_rb() end
  local function bearing_of(i) right = math.min(rb[i] or 0, 0) end
  local function calc_rb() if pos - 1 >= 1 then bearing_of(pos - 1) end end
  local function save_current() previous = pos - 1 >= 1 and pos - 1 or nil end
  local function full_otherwise_extend()
    if line.len > 0 and new_width() > width then return true end
    line.w = line.w + tmp.w + space.w
    line.len = line.len + tmp.len + space.len
    tmp.w, tmp.len, space.w, space.len = 0, 0, 0, 0
    return false
  end
  local found = false
  local reached_end = false
  while true do
    if pos > n then reached_end = true break end
    right = NOT_CALC                               -- (resetRightBearing: each run anew)
    local c = cps[pos]
    if c == 0x2028 or c == 0x2029 then
      -- a line or paragraph separator: the line ends here (it belongs to it)
      ws_or_obj = true
      tmp.len = tmp.len + 1
      if previous then bearing_of(previous) end
      line.w, line.len = line.w + tmp.w, line.len + tmp.len
      tmp.w, tmp.len = 0, 0
      found = true
      break
    elseif c == 0x09 then
      -- a tab: to the next tab stop (QTextEngine::calculateTabWidth, QTextOption's 80 px)
      ws_or_obj = true
      if full_otherwise_extend() then found = true break end
      local x = line.w + tmp.w + space.w
      local stop = TL.TAB
      local tab_w = (math.floor(x / stop) + 1) * stop - x
      space.w = space.w + tab_w
      space.len = space.len + 1
      pos = pos + 1
      if full_otherwise_extend() then found = true break end
    elseif white[pos] and not NOBREAK[c] then
      if pos > 1 and not white[pos - 1] then save_current() end
      ws_or_obj = true
      while pos <= n and white[pos] and not NOBREAK[cps[pos]] and cps[pos] ~= 0x2028 and cps[pos] ~= 0x2029 do
        space.w = space.w + adv[pos]
        space.len = space.len + 1
        pos = pos + 1
      end
    else
      if space.w > width then found = true break end
      ws_or_obj = false
      if pos == 1 or previous == nil or not white[pos - 1] then save_current() end
      local sb_or_ws = false
      repeat
        tmp.w = tmp.w + adv[pos]
        tmp.len = tmp.len + 1
        pos = pos + 1
        local breakable_space = pos <= n and white[pos] and not NOBREAK[cps[pos]]
        if pos > n or breakable_space or brk[pos] then
          sb_or_ws = true
          break
        elseif attr.grapheme[pos] and breakany then
          break
        end
      until pos > n
      if sb_or_ws or breakany then
        local prev_rb = right
        if new_width() + min_rb > width then calc_rb() end
        if full_otherwise_extend() then
          if prev_rb ~= NOT_CALC then right = prev_rb
          elseif previous then bearing_of(previous) end
          found = true
          break
        end
      end
      save_current()
    end
  end
  if reached_end then full_otherwise_extend() end
  if right == NOT_CALC and not ws_or_obj then calc_rb() end
  line.w = line.w + neg_rb()
  if line.len == 0 then
    line.w, line.len = line.w + tmp.w, line.len + tmp.len
  end
  return {from = from, length = line.len, trailing = space.len, width = line.w}, space.w
end

-- the grapheme boundaries (for breaking anywhere): every code point but a combining mark, a ZWJ and what follows it,
-- the second of a pair of regional indicators
local function graphemes(cps)
  local g = {}
  local ri = 0
  for i = 1, #cps + 1 do
    local c = cps[i]
    local b = true
    if c then
      local p = QB.props(c)
      local gb = p[4]
      if gb == 4 or gb == 5 or gb == 8 then b = false end              -- Extend, ZWJ, SpacingMark
      if i > 1 and QB.props(cps[i - 1])[4] == 5 and gb == 14 then b = false end   -- ZWJ x Extended_Pictographic
      if gb == 6 then
        ri = ri + 1
        if ri % 2 == 0 then b = false end
      else
        ri = 0
      end
    end
    if i == 1 then b = true end
    g[i] = b
  end
  return g
end

function TL.lines(text, px, bold, width, mode)
  mode = mode or "word"
  local cps = S.cps(text)
  local n = #cps
  local brk, must, white = QB.attributes(cps)
  local attr = {brk = brk, must = must, white = white}
  attr.grapheme = graphemes(cps)
  local offs = offsets(text, px, bold)
  local adv = {}
  for i = 1, n do adv[i] = offs[i + 1] - offs[i] end
  local rb, least = w3.ui.text_bearings(text, px, style_of(bold))
  local out = {}
  local from = 1
  if n == 0 then return {{from = 1, length = 0, trailing = 0, width = 0}} end
  while from <= n do
    local l, trailing_w = layout_line(cps, attr, adv, rb, least, from, width, mode == "any" and "any" or "word")
    if mode == "word_any" and l.width > width then
      -- (the word does not fit: this line set again breaking anywhere)
      l = layout_line(cps, attr, adv, rb, least, from, width, "any")
    end
    out[#out + 1] = l
    local _ = trailing_w
    from = from + l.length + l.trailing
    if l.length + l.trailing == 0 then from = from + 1 end
  end
  return out
end

-- the lines as text (their trailing spaces off) and their widths: {{s, w}, ...} - kept (MaximdeWinter 25.10.: the inspector
-- broke its texts into lines anew each frame, Qt's line breaking in Lua; 120 ms frames). Read only: shared.
local wrapped, wrapped_n = {}, 0
TL.WRAP_KEEP = 3000
function TL.wrap(text, px, bold, width, mode)
  local key = text .. "\0" .. tostring(px) .. (bold and "b" or "") .. "\0" .. tostring(width) .. "\0" .. tostring(mode)
  local got = wrapped[key]
  if got then return got end
  local cps = S.cps(text)
  local out = {}
  for _, l in ipairs(TL.lines(text, px, bold, width, mode)) do
    out[#out + 1] = {s = S.from_cps(cps, l.from, l.from + l.length - 1), w = l.width}
  end
  if wrapped_n >= TL.WRAP_KEEP then wrapped, wrapped_n = {}, 0 end
  wrapped[key], wrapped_n = out, wrapped_n + 1
  return out
end

-- QTextEngine's minWidth and maxWidth of a paragraph (a table cell's): the widest piece between two places a line
-- may break (its trailing spaces and bearing not in it), and the whole set on one line (its trailing spaces in it)
function TL.min_max(text, px, bold)
  local cps = S.cps(text)
  local n = #cps
  if n == 0 then return 0, 0 end
  local brk, _, white = QB.attributes(cps)
  local offs = offsets(text, px, bold)
  local minw = 0
  local pos = 1
  while pos <= n do
    if white[pos] and not NOBREAK[cps[pos]] then
      pos = pos + 1
    else
      local acc = 0
      repeat
        acc = acc + offs[pos + 1] - offs[pos]
        pos = pos + 1
      until pos > n or (white[pos] and not NOBREAK[cps[pos]]) or brk[pos]
      minw = math.max(minw, acc)
    end
  end
  local one = TL.lines(text, px, bold, 1e9, "word")
  local maxw = 0
  for _, l in ipairs(one) do
    local trailing = 0
    for i = l.from + l.length, l.from + l.length + l.trailing - 1 do trailing = trailing + offs[i + 1] - offs[i] end
    maxw = math.max(maxw, l.width + trailing)
  end
  return minw, maxw
end

return TL
