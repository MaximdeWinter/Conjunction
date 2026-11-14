-- Python's number built-ins as the app's code uses them, for code carried over from it: str(), float(), int(x, base),
-- round() (half to even; with digits through the correctly rounded decimal string, as CPython), sum() of floats
-- (Neumaier, Python 3.12+), repr of a float.
local Y = require("conjunction.yaml")
local N = {}

-- Python's repr of a float (float.__repr__)
function N.float_repr(x)
  if x ~= x then return "nan" end
  if x == math.huge then return "inf" end
  if x == -math.huge then return "-inf" end
  local r = Y.float_repr(x)
  local m, e = r:match("^(.-)%.0e(.*)$")
  if m and not m:find(".", 1, true) then return m .. "e" .. e end
  return r
end

-- str(x)
function N.str(x)
  if x == nil or x == Y.null then return "None" end
  local t = type(x)
  if t == "boolean" then return x and "True" or "False" end
  if t == "number" then return math.type(x) == "integer" and tostring(x) or N.float_repr(x) end
  if t == "string" then return x end
  return tostring(x)
end

local WS = "[ \t\n\r\f\v]"
-- float(x): a number, or a string Python's float() takes (spaces around it, underscores between digits, inf, nan)
function N.float(x)
  if type(x) == "number" then return math.type(x) == "float" and x or x + 0.0 end   -- (-0.0 stays -0.0)
  if x == true then return 1.0 end
  if x == false then return 0.0 end
  local s = tostring(x):gsub("^" .. WS .. "+", ""):gsub(WS .. "+$", "")
  local l = s:lower()
  local sign = 1.0
  local body = l
  if body:sub(1, 1) == "-" then sign, body = -1.0, body:sub(2) elseif body:sub(1, 1) == "+" then body = body:sub(2) end
  if body == "inf" or body == "infinity" then return sign * math.huge end
  if body == "nan" then return 0 / 0 end
  if s:find("_", 1, true) then
    if s:find("__", 1, true) or s:match("^_") or s:match("_$") or s:match("[^%d]_") or s:match("_[^%d]") then
      error("could not convert string to float: '" .. tostring(x) .. "'")
    end
    s = s:gsub("_", "")
  end
  if not s:match("^[-+]?%d*%.?%d*[eE]?[-+]?%d*$") or s:match("^[-+]?%.?[eE]") or s == "" or s == "." then
    error("could not convert string to float: '" .. tostring(x) .. "'")
  end
  local v = tonumber(s)
  if v == nil then error("could not convert string to float: '" .. tostring(x) .. "'") end
  return v + 0.0 == 0 and (s:match("^%-") and -0.0 or 0.0) or v + 0.0
end

-- int(s, base): Python's int() of a string in a base (16: "0x" allowed), nil when it is not one
function N.int_base(s, base)
  s = tostring(s):gsub("^" .. WS .. "+", ""):gsub(WS .. "+$", "")
  local sign = 1
  if s:sub(1, 1) == "-" then sign, s = -1, s:sub(2) elseif s:sub(1, 1) == "+" then s = s:sub(2) end
  if base == 16 then s = s:gsub("^0[xX]_?", "") end
  if s == "" or s:find("__", 1, true) or s:match("^_") or s:match("_$") then return nil end
  s = s:gsub("_", "")
  local pat = base == 16 and "^%x+$" or "^%d+$"
  if not s:match(pat) then return nil end
  local v = tonumber(s, base)
  return v and sign * v or nil
end

-- round(x): the nearest integer, half to even
function N.round0(x)
  local f = math.floor(x)
  local d = x - f
  if d > 0.5 or (d == 0.5 and f % 2 ~= 0) then f = f + 1 end
  return math.tointeger(f) or f
end
-- round(x, n): through the decimal string rounded correctly to n places (CPython's float round)
function N.round(x, n)
  if n == nil then return N.round0(x) end
  if math.type(x) == "integer" and n >= 0 then return x end      -- (round(int, n): the int itself)
  if x ~= x or x == math.huge or x == -math.huge then return x end
  local s = string.format("%." .. n .. "f", x)
  local v = tonumber(s)
  if v == 0 then return (s:sub(1, 1) == "-" or 1 / x < 0) and -0.0 or 0.0 end
  return v + 0.0
end

-- math.hypot as CPython computes it (mathmodule.c vector_norm): scaled by a power of two, the squares and their sum
-- kept exact in two parts, one correction step. dl_mul's fma is Dekker's exact product here (the same error term).
local SPLIT = 134217729.0                 -- 2^27 + 1
local function two_prod(a, b)
  local p = a * b
  local t = SPLIT * a
  local ah = t - (t - a)
  local al = a - ah
  t = SPLIT * b
  local bh = t - (t - b)
  local bl = b - bh
  return p, ((ah * bh - p) + ah * bl + al * bh) + al * bl
end
local function fast_sum(a, b)
  local x = a + b
  return x, (a - x) + b
end
local function frexp_e(x)                 -- the e of frexp(x) = m * 2^e, 0.5 <= m < 1 (x > 0, normal)
  local e = math.floor(math.log(x, 2)) + 1
  local m = x * 2.0 ^ (-e)
  if m >= 1.0 then e = e + 1 elseif m < 0.5 then e = e - 1 end
  return e
end
local DBL_MIN = 2.2250738585072014e-308
local function vector_norm(vec, max, found_nan)
  if max == math.huge then return max end
  if found_nan then return 0 / 0 end
  if max == 0.0 or #vec <= 1 then return max end
  local max_e = frexp_e(max)
  if max_e < -1023 then
    local v2 = {}
    for i, x in ipairs(vec) do v2[i] = x / DBL_MIN end
    return DBL_MIN * vector_norm(v2, max / DBL_MIN, found_nan)
  end
  local scale = 2.0 ^ (-max_e)
  local csum, frac1, frac2 = 1.0, 0.0, 0.0
  for _, x in ipairs(vec) do
    x = x * scale
    local hi, lo = two_prod(x, x)
    local shi, slo = fast_sum(csum, hi)
    csum = shi
    frac1 = frac1 + lo
    frac2 = frac2 + slo
  end
  local h = math.sqrt(csum - 1.0 + (frac1 + frac2))
  local hi, lo = two_prod(-h, h)
  local shi, slo = fast_sum(csum, hi)
  csum = shi
  frac1 = frac1 + lo
  frac2 = frac2 + slo
  local x = csum - 1.0 + (frac1 + frac2)
  h = h + x / (2.0 * h)
  return h / scale
end
function N.hypot(...)
  local vec, max, nan = {}, 0.0, false
  for i, v in ipairs({...}) do
    local x = math.abs(v + 0.0)
    vec[i] = x
    if x ~= x then nan = true end
    if x > max then max = x end
  end
  return vector_norm(vec, max, nan)
end

-- sum() as Python 3.12+ adds: integers exactly while they last, then floats with Neumaier's compensation
function N.sum(xs)
  local i_result, k = 0, 1
  while k <= #xs and math.type(xs[k]) == "integer" do i_result, k = i_result + xs[k], k + 1 end
  if k > #xs then return i_result end
  local f, c = i_result + xs[k], 0.0
  f = f + 0.0
  for j = k + 1, #xs do
    local x = xs[j]
    if math.type(x) == "integer" then
      f = f + x
    else
      local t = f + x
      if math.abs(f) >= math.abs(x) then c = c + ((f - t) + x) else c = c + ((x - t) + f) end
      f = t
    end
  end
  if c ~= 0 and c == c and c ~= math.huge and c ~= -math.huge then f = f + c end
  return f
end
return N
