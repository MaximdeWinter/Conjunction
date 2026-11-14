-- Python's ways with the project's data (yaml.lua's maps and lists, Y.null for None), for code carried over from the
-- app line by line:
--   P.T(v)                  bool(v): None, False, 0, "", an empty list or dict are false
--   P.get(d, k [, default]) d.get(k, default) - a stored None is None (nil), not the default
--   P.or_(a, b, ...)        a or b or ...: the first true one, else the last
--   P.str(v)                str(v)
--   P.has(d, k)             k in d (a key stored with None too)
--   P.startswith(s, p), P.endswith(s, p), P.replace(s, old, new)  str's (plain text, no patterns)
--   P.crc32(s)              zlib.crc32 of the UTF-8 bytes
--   P.list(v), P.map(v)     v, or an empty one when v is false (Python's `v or []`, `v or {}`)
local Y = require("conjunction.yaml")
local NUM = require("conjunction.pynum")
local P = {}

function P.null(v) return v == nil or v == Y.null end

function P.T(v)
  if v == nil or v == false or v == Y.null or v == 0 or v == "" then return false end
  if type(v) == "table" and next(v) == nil then return false end
  return true
end

function P.get(d, k, default)
  if type(d) ~= "table" or d == Y.null then return default end
  local v = d[k]
  if v == nil then return default end
  if v == Y.null then return nil end
  return v
end

function P.or_(...)
  local n = select("#", ...)
  for i = 1, n - 1 do
    local v = select(i, ...)
    if P.T(v) then return v end
  end
  return (select(n, ...))
end

-- a or f(): f only called when a is false (Python's `or` looks no further)
function P.or_else(a, f)
  if P.T(a) then return a end
  return f()
end

-- what `for x in v` goes through: a list, a string's characters, a dict's keys (anything else: Python's TypeError)
function P.iter(v)
  if v == nil or v == Y.null then error("TypeError: 'NoneType' object is not iterable", 2) end
  if type(v) == "string" then
    local out = {}
    for _, c in utf8.codes(v) do out[#out + 1] = utf8.char(c) end
    return out
  end
  if Y.is_map(v) then return Y.keys(v) end
  if type(v) == "table" then return v end
  error("TypeError: '" .. type(v) .. "' object is not iterable", 2)
end

-- repr(v): Python's (a string in single quotes unless it holds one and no double quote; lists, dicts, None ...)
local function repr(v)
  if v == nil or v == Y.null then return "None" end
  local t = type(v)
  if t == "boolean" or t == "number" then return NUM.str(v) end
  if t == "string" then
    local q = (v:find("'", 1, true) and not v:find('"', 1, true)) and '"' or "'"
    local out = {q}
    for _, c in utf8.codes(v) do
      local ch
      if c == 92 then ch = "\\\\"
      elseif c == 10 then ch = "\\n"
      elseif c == 13 then ch = "\\r"
      elseif c == 9 then ch = "\\t"
      elseif c == string.byte(q) then ch = "\\" .. q
      elseif c < 32 or c == 127 then ch = string.format("\\x%02x", c)
      elseif c >= 0x80 and c < 0xA0 then ch = string.format("\\x%02x", c)
      elseif c == 0xA0 or c == 0xAD then ch = string.format("\\x%02x", c)
      else ch = utf8.char(c) end
      out[#out + 1] = ch
    end
    out[#out + 1] = q
    return table.concat(out)
  end
  if t == "table" then
    if Y.is_map(v) then
      local parts = {}
      for k, x in pairs(v) do parts[#parts + 1] = repr(k) .. ": " .. repr(x) end
      return "{" .. table.concat(parts, ", ") .. "}"
    end
    local parts = {}
    for i = 1, #v do parts[i] = repr(v[i]) end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return tostring(v)
end
P.repr = repr

-- str(v): a string as it is, the rest as repr
function P.str(v)
  if type(v) == "table" and v ~= Y.null then return repr(v) end
  return NUM.str(v)
end

function P.has(d, k) return type(d) == "table" and d ~= Y.null and d[k] ~= nil end

function P.startswith(s, p) return s:sub(1, #p) == p end
function P.endswith(s, p) return p == "" or s:sub(-#p) == p end
function P.replace(s, old, new)
  if old == "" then return s end
  local out, i = {}, 1
  while true do
    local a, b = s:find(old, i, true)
    if not a then break end
    out[#out + 1] = s:sub(i, a - 1)
    out[#out + 1] = new
    i = b + 1
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

-- copy.deepcopy(x, memo): maps and lists copied all the way down (Y.null, strings, numbers kept); memo: the original
-- table -> its copy (one table met twice is copied once, as Python's memo does)
function P.deepcopy(x, memo)
  if type(x) ~= "table" or x == Y.null then return x end
  memo = memo or {}
  if memo[x] then return memo[x] end
  local out
  if Y.is_map(x) then
    out = Y.map()
    memo[x] = out
    for k, v in pairs(x) do out[k] = P.deepcopy(v, memo) end
  elseif Y.is_list(x) then
    out = Y.list({})
    memo[x] = out
    for i, v in ipairs(x) do out[i] = P.deepcopy(v, memo) end
  else
    out = {}
    memo[x] = out
    for k, v in pairs(x) do out[k] = P.deepcopy(v, memo) end
  end
  return out
end

function P.list(v) if P.T(v) then return v end return Y.list({}) end
function P.map(v) if P.T(v) then return v end return Y.map() end

local CRC
function P.crc32(s)
  if not CRC then
    CRC = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
      end
      CRC[i] = c
    end
  end
  local c = 0xFFFFFFFF
  for i = 1, #s do c = CRC[(c ~ s:byte(i)) & 0xFF] ~ (c >> 8) end
  return c ~ 0xFFFFFFFF
end

-- list(x) for a list or a sequence: a plain copy (1-based)
function P.copy_list(t)
  local out = {}
  for i, v in ipairs(t or {}) do out[i] = v end
  return out
end

-- `x in list` (by ==)
function P.contains(t, x)
  for _, v in ipairs(t or {}) do if v == x then return true end end
  return false
end

return P
