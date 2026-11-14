-- Python's sorted() / list.sort(): stable (equal keys keep their order - Lua's table.sort does not), with Python's
-- order of values: numbers by value (true and false as 1 and 0), strings by code point (UTF-8's byte order is the
-- same), tuples (Lua sequences) element by element, the shorter first when one begins the other.
--   local PS = require("conjunction.pysort")
--   PS.sort(list [, key [, reverse]])        in place, as list.sort(key=..., reverse=...)
--   PS.sorted(list [, key [, reverse]])      a sorted copy
--   PS.lt(a, b)                              Python's a < b
local PS = {}

-- strings by byte (= code point): Lua's '<' asks strcoll, which follows the process's collation (only "C" is bytes)
local function bytes_lt(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then return x < y end
  end
  return #a < #b
end
local strlt = os.setlocale(nil, "collate") == "C" and function(a, b) return a < b end or bytes_lt
PS.strlt = strlt

local function num(v)
  if v == true then return 1 elseif v == false then return 0 end
  return v
end

-- Python's a < b for the values a sort key has (raises as Python would on values it cannot order); strings first, the
-- most common - and in a tuple an element equal to the other's is passed by at once (25.10.: the catalog's sorts
-- asked lt twice for each element; its opening took seconds)
local function lt(a, b)
  local ta, tb = type(a), type(b)
  if ta == "string" and tb == "string" then return strlt(a, b) end
  if ta == "table" and tb == "table" then
    local na, nb = #a, #b
    for i = 1, (na < nb and na or nb) do
      local x, y = a[i], b[i]
      if x ~= y then
        if lt(x, y) then return true end
        if lt(y, x) then return false end
      end
    end
    return na < nb
  end
  if (ta == "number" or ta == "boolean") and (tb == "number" or tb == "boolean") then return num(a) < num(b) end
  error("pysort: '<' not supported between " .. ta .. " and " .. tb, 3)
end
PS.lt = lt

-- a merge sort on positions: stable; reverse as Python's (equal ones keep their order too)
function PS.sort(list, key, reverse)
  local n = #list
  if n < 2 then return list end
  local keys = {}
  for i = 1, n do                       -- (not key and key(x) or x: a key of false is a key)
    if key then keys[i] = key(list[i]) else keys[i] = list[i] end
  end
  local idx, tmp = {}, {}
  for i = 1, n do idx[i] = i end
  -- Lua's own sort (C) on the positions, equal keys by their position: the same order as the stable merge below,
  -- which stays for what table.sort refuses (an order that is not one: NaN)
  local fine = pcall(table.sort, idx, reverse and function(i, j)
    local a, b = keys[i], keys[j]
    if lt(b, a) then return true end
    if lt(a, b) then return false end
    return i < j
  end or function(i, j)
    local a, b = keys[i], keys[j]
    if lt(a, b) then return true end
    if lt(b, a) then return false end
    return i < j
  end)
  if fine then
    local out = {}
    for i = 1, n do out[i] = list[idx[i]] end
    for i = 1, n do list[i] = out[i] end
    return list
  end
  for i = 1, n do idx[i] = i end
  local before
  if reverse then
    before = function(i, j) return lt(keys[j], keys[i]) end
  else
    before = function(i, j) return lt(keys[i], keys[j]) end
  end
  local width = 1
  while width < n do
    for lo = 1, n, 2 * width do
      local mid = math.min(lo + width - 1, n)
      local hi = math.min(lo + 2 * width - 1, n)
      if mid < hi then
        local i, j, k = lo, mid + 1, lo
        while i <= mid and j <= hi do
          -- take the right one only when it comes strictly before: equal ones keep their order
          if before(idx[j], idx[i]) then tmp[k] = idx[j] j = j + 1 else tmp[k] = idx[i] i = i + 1 end
          k = k + 1
        end
        while i <= mid do tmp[k] = idx[i] i = i + 1 k = k + 1 end
        while j <= hi do tmp[k] = idx[j] j = j + 1 k = k + 1 end
        for q = lo, hi do idx[q] = tmp[q] end
      end
    end
    width = width * 2
  end
  local out = {}
  for i = 1, n do out[i] = list[idx[i]] end
  for i = 1, n do list[i] = out[i] end
  return list
end

function PS.sorted(list, key, reverse)
  local copy = {}
  for i = 1, #list do copy[i] = list[i] end
  return PS.sort(copy, key, reverse)
end

return PS
