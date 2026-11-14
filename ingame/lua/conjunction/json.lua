-- JSON as Conjunction's Python app reads and writes it (json.load, json.dump(..., indent=1)): config.json and the
-- caches open in the app and in the mod alike. Mappings keep their order (yaml.lua's Y.map), arrays are Y.list,
-- null is Y.null; integers and floats stay apart.
--
--   local J = require("conjunction.json")
--   local data = J.decode(text)
--   local text = J.encode(data, {indent = 1})      -- json.dumps(data, indent=1); no indent: one line (", ", ": ")
--   options as json.dumps has them: sort_keys = true, separators = {",", ":"}, ensure_ascii = false
--   J.read(path), J.write(path, data, opts)
-- Checked against Python's json: ingame/ref/json_check.py.
local Y = require("conjunction.yaml")
local J = {}

-- --- writing (json.encoder, ensure_ascii) ---
local ESC = {[8] = "\\b", [9] = "\\t", [10] = "\\n", [12] = "\\f", [13] = "\\r", [34] = '\\"', [92] = "\\\\"}
local function str(s, raw)
  local out = {'"'}
  for _, c in utf8.codes(s) do
    if ESC[c] then out[#out + 1] = ESC[c]
    elseif raw and c > 0x7E then out[#out + 1] = utf8.char(c)    -- (ensure_ascii=False: the letters as they are)
    elseif c < 0x20 or c > 0x7E then
      if c == 0x7F then out[#out + 1] = "\127"
      elseif c < 0x10000 then out[#out + 1] = string.format("\\u%04x", c)
      else
        local v = c - 0x10000
        out[#out + 1] = string.format("\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
      end
    else
      out[#out + 1] = string.char(c)
    end
  end
  out[#out + 1] = '"'
  return table.concat(out)
end

local function float_text(x)
  if x ~= x then return "NaN" end
  if x == math.huge then return "Infinity" end
  if x == -math.huge then return "-Infinity" end
  -- float.__repr__ (YAML's representer adds ".0" before an e; repr does not)
  local r = Y.float_repr(x)
  local m, e = r:match("^(.-)%.0e(.*)$")
  if m and not m:find(".", 1, true) then return m .. "e" .. e end
  return r
end

local function key_text(k, raw)
  local t = type(k)
  if t == "string" then return str(k, raw) end
  if t == "boolean" then return k and '"true"' or '"false"' end
  if k == Y.null then return '"null"' end
  if t == "number" then
    if math.type(k) == "integer" then return '"' .. tostring(k) .. '"' end
    return '"' .. float_text(k) .. '"'
  end
  error("json: keys must be str, int, float, bool or None, not " .. t)
end

local function encode(x, indent, level, out, o)
  local t = type(x)
  if x == nil or x == Y.null then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = x and "true" or "false"
  elseif t == "number" then out[#out + 1] = math.type(x) == "integer" and tostring(x) or float_text(x)
  elseif t == "string" then out[#out + 1] = str(x, o.raw)
  elseif t == "table" then
    local is_map = Y.is_map(x) or (not Y.is_list(x) and next(x) ~= nil and x[1] == nil)
    local open, close = is_map and "{" or "[", is_map and "}" or "]"
    local items = {}
    if is_map then
      if Y.is_map(x) and not o.sort_keys then
        for k, v in pairs(x) do items[#items + 1] = {k, v} end
      elseif o.sort_keys then                     -- (sorted(dct.items()): the keys as Python compares them)
        local ks = {}
        for k in pairs(x) do ks[#ks + 1] = k end
        table.sort(ks, function(a, b)
          if type(a) ~= type(b) then error("json: sort_keys with keys of two types") end
          return a < b
        end)
        for _, k in ipairs(ks) do items[#items + 1] = {k, x[k]} end
      else
        local ks = {}
        for k in pairs(x) do ks[#ks + 1] = k end
        table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(ks) do items[#items + 1] = {k, x[k]} end
      end
    else
      for i = 1, #x do items[i] = x[i] end
    end
    if #items == 0 then out[#out + 1] = open .. close; return end
    out[#out + 1] = open
    local inner = indent and ("\n" .. string.rep(" ", indent * (level + 1))) or ""
    local sep = o.item_sep or (indent and "," or ", ")
    for i, it in ipairs(items) do
      if i > 1 then out[#out + 1] = sep end
      out[#out + 1] = inner
      if is_map then
        out[#out + 1] = key_text(it[1], o.raw)
        out[#out + 1] = o.key_sep or ": "
        encode(it[2], indent, level + 1, out, o)
      else
        encode(it, indent, level + 1, out, o)
      end
    end
    if indent then out[#out + 1] = "\n" .. string.rep(" ", indent * level) end
    out[#out + 1] = close
  else
    error("json: cannot write a " .. t)
  end
end

function J.encode(x, opts)
  local out = {}
  opts = opts or {}
  local seps = opts.separators
  local o = {sort_keys = opts.sort_keys, raw = opts.ensure_ascii == false,
             item_sep = seps and seps[1] or nil, key_sep = seps and seps[2] or nil}
  encode(x, opts.indent, 0, out, o)
  return table.concat(out)
end

-- --- reading (json.decoder: NaN, Infinity and -Infinity too) ---
function J.decode(s)
  local pos = 1
  local function err(m) error(string.format("json: %s at byte %d", m, pos), 0) end
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local value
  local function string_at()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then err("a string without its end") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local simple = ({b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/"})[e]
        if simple then
          out[#out + 1] = simple
          pos = pos + 2
        elseif e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16)
          if not cp then err("a bad \\u escape") end
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
              pos = pos + 6
            end
          end
          out[#out + 1] = utf8.char(cp)
        else
          err("a bad escape")
        end
      else
        local j = s:find('["\\]', pos)
        if not j then err("a string without its end") end
        out[#out + 1] = s:sub(pos, j - 1)
        pos = j
      end
    end
    return table.concat(out)
  end
  value = function()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local m = Y.map()
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return m end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then err("a key") end
        local k = string_at()
        ws()
        if s:sub(pos, pos) ~= ":" then err("':'") end
        pos = pos + 1
        m[k] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return m end
        if d ~= "," then err("',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1
      local l = Y.list()
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return l end
      while true do
        l[#l + 1] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return l end
        if d ~= "," then err("',' or ']'") end
      end
    elseif c == '"' then return string_at()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return Y.null
    elseif s:sub(pos, pos + 2) == "NaN" then pos = pos + 3; return 0 / 0
    elseif s:sub(pos, pos + 7) == "Infinity" then pos = pos + 8; return math.huge
    elseif s:sub(pos, pos + 8) == "-Infinity" then pos = pos + 9; return -math.huge
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then err("a value") end
      pos = pos + #num
      if num:find("[.eE]") then          -- (tonumber keeps -0.0; adding 0.0 would make it +0.0)
        local v = tonumber(num)
        return math.type(v) == "integer" and v * 1.0 or v
      end
      return math.tointeger(tonumber(num)) or tonumber(num)
    end
  end
  local v = value()
  ws()
  if pos <= #s then err("more after the value") end
  return v
end

local fs = rawget(_G, "w3") and w3.fs
function J.read(path)
  local s
  if fs then s = fs.read(path) else
    local f = io.open(path, "rb")
    if f then s = f:read("a"); f:close() end
  end
  if not s then return nil end
  if s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end
  return J.decode(s)
end
-- (Python's text mode on Windows: "\n" in a string is escaped, so the only line ends are the indentation's: CRLF)
function J.write(path, data, opts)
  local text = J.encode(data, opts or {indent = 1}):gsub("\n", "\r\n")
  if fs then assert(fs.write(path, text)); return end
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

return J
