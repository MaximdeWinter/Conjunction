-- Python's str on Lua's UTF-8 strings: what Conjunction's Python does with text, character by character as Python
-- counts them (code points), with Python's own Unicode tables (data/unicode.lua, made by
-- ingame/tools/make_unicode.py). Checked against Python: ingame/ref/pystr_check.py.
--
--   S.lower(s), S.upper(s)                 str.lower / str.upper (a capital sigma at a word's end: final sigma)
--   S.strip(s [, chars]), lstrip, rstrip   str.strip (no chars: Unicode whitespace)
--   S.split(s)                             str.split() (runs of Unicode whitespace)
--   S.isalnum(s), isalpha, isdecimal, isdigit, isnumeric, isspace, islower, isupper
--   S.cps(s) -> {cp ...}, S.from_cps(cps [, i, j]), S.len(s)
--   S.is(cp, "ALNUM" | "ALPHA" | "DECIMAL" | "DIGIT" | "NUMERIC" | "SPACE" | "CASED" ...)   one character
local U = require("conjunction.data.unicode")
local S = {}
S.U = U

-- a code point in a sorted range list {a1, b1, a2, b2 ...}
local function in_ranges(r, cp)
  local lo, hi = 1, #r // 2
  while lo <= hi do
    local mid = (lo + hi) // 2
    local a, b = r[2 * mid - 1], r[2 * mid]
    if cp < a then hi = mid - 1 elseif cp > b then lo = mid + 1 else return true end
  end
  return false
end
S.in_ranges = in_ranges
function S.is(cp, name) return in_ranges(U[name], cp) end

local cp_of, char = utf8.codepoint, utf8.char
function S.cps(s)
  if s == "" then return {} end
  return {cp_of(s, 1, -1)}
end
-- (a slice as Python's: an end past the last one is the last one - 24.10.: a quest item's name under 20 letters
-- broke "Add item" with a name of its own)
function S.from_cps(cps, i, j)
  i, j = math.max(i or 1, 1), math.min(j or #cps, #cps)
  if j < i then return "" end
  if j - i < 4000 then return char(table.unpack(cps, i, j)) end
  local parts = {}
  for k = i, j, 4000 do parts[#parts + 1] = char(table.unpack(cps, k, math.min(j, k + 3999))) end
  return table.concat(parts)
end
function S.len(s) return utf8.len(s) end

local function ascii(s) return not s:find("[\128-\255]") end

-- str.lower: CPython's lower_ucs4 with handle_capital_sigma (the sigma before no cased letter, after one: final)
function S.lower(s)
  if ascii(s) then return s:lower() end
  local cps, out = S.cps(s), {}
  for i, c in ipairs(cps) do
    if c == 0x3A3 then
      local before, after = false, false
      local k = i - 1
      while k >= 1 and in_ranges(U.CASE_IGNORABLE, cps[k]) do k = k - 1 end
      before = k >= 1 and in_ranges(U.CASED, cps[k])
      k = i + 1
      while k <= #cps and in_ranges(U.CASE_IGNORABLE, cps[k]) do k = k + 1 end
      after = k <= #cps and in_ranges(U.CASED, cps[k])
      out[i] = (before and not after) and "\u{3C2}" or "\u{3C3}"
    else
      out[i] = U.LOWER[c] or char(c)
    end
  end
  return table.concat(out)
end
function S.upper(s)
  if ascii(s) then return s:upper() end
  local out = {}
  for i, c in ipairs(S.cps(s)) do out[i] = U.UPPER[c] or char(c) end
  return table.concat(out)
end

local function all(s, name)
  if s == "" then return false end
  local r = U[name]
  for _, c in utf8.codes(s) do
    if not in_ranges(r, c) then return false end
  end
  return true
end
function S.isalnum(s) return all(s, "ALNUM") end
function S.isalpha(s) return all(s, "ALPHA") end
function S.isdecimal(s) return all(s, "DECIMAL") end
function S.isdigit(s) return all(s, "DIGIT") end
function S.isnumeric(s) return all(s, "NUMERIC") end
function S.isspace(s) return all(s, "SPACE") end
-- str.islower / isupper: at least one cased character, none of the other case
function S.islower(s)
  local any = false
  for _, c in utf8.codes(s) do
    if in_ranges(U.ISUPPER, c) or in_ranges(U.ISTITLE, c) then return false end
    if in_ranges(U.ISLOWER, c) then any = true end
  end
  return any
end
function S.isupper(s)
  local any = false
  for _, c in utf8.codes(s) do
    if in_ranges(U.ISLOWER, c) or in_ranges(U.ISTITLE, c) then return false end
    if in_ranges(U.ISUPPER, c) then any = true end
  end
  return any
end

local function strip(s, chars, left, right)
  local cps = S.cps(s)
  local drop
  if chars == nil then
    drop = function(c) return in_ranges(U.SPACE, c) end
  else
    local set = {}
    for _, c in utf8.codes(chars) do set[c] = true end
    drop = function(c) return set[c] end
  end
  local i, j = 1, #cps
  if left then while i <= j and drop(cps[i]) do i = i + 1 end end
  if right then while j >= i and drop(cps[j]) do j = j - 1 end end
  return S.from_cps(cps, i, j)
end
function S.strip(s, chars) return strip(s, chars, true, true) end
function S.lstrip(s, chars) return strip(s, chars, true, false) end
function S.rstrip(s, chars) return strip(s, chars, false, true) end

-- str.splitlines(): the lines between \n, \r, \r\n, \v, \f, \x1c-\x1e, \x85,  ,   (no empty last one)
local BREAKS = {[10] = true, [13] = true, [11] = true, [12] = true, [0x1c] = true, [0x1d] = true, [0x1e] = true,
                [0x85] = true, [0x2028] = true, [0x2029] = true}
function S.splitlines(s)
  local out, cur, prev_cr = {}, {}, false
  for _, c in utf8.codes(s) do
    if c == 10 and prev_cr then
      prev_cr = false                            -- (\r\n: one break)
    elseif BREAKS[c] then
      out[#out + 1] = char(table.unpack(cur))
      cur = {}
      prev_cr = c == 13
    else
      cur[#cur + 1] = c
      prev_cr = false
    end
  end
  if #cur > 0 then out[#out + 1] = char(table.unpack(cur)) end
  return out
end

-- str.split(): the words between runs of whitespace, none empty
function S.split(s)
  if not s:find("[\128-\255]") then              -- (ASCII: its whitespace is 9-13 and 28-32 - the catalog's rows)
    local out = {}
    for w in s:gmatch("[^\t\n\v\f\r\28\29\30\31 ]+") do out[#out + 1] = w end
    return out
  end
  local out, cur = {}, {}
  for _, c in utf8.codes(s) do
    if in_ranges(U.SPACE, c) then
      if #cur > 0 then out[#out + 1] = char(table.unpack(cur)) cur = {} end
    else
      cur[#cur + 1] = c
    end
  end
  if #cur > 0 then out[#out + 1] = char(table.unpack(cur)) end
  return out
end

return S
