-- YAML as Conjunction's Python app reads and writes it (PyYAML 6: yaml.safe_load, yaml.safe_dump), so a project
-- opens in the app and in the mod alike and a file written here is byte for byte what the app would write.
--
--   local Y = require("conjunction.yaml")
--   local data = Y.load(text)                          -- mappings keep their order (Y.map), sequences are Y.list
--   local text = Y.dump(data, {sort_keys = false, default_flow_style = nil, allow_unicode = false})
--   Y.read(path), Y.write(path, data, opts)             -- files with CRLF, as Python's text mode on Windows
--
-- The writer is PyYAML's representer, serializer and emitter (emitter.py) carried over step by step: the same scalar
-- analysis, the same styles, the same line folding at 80 columns. Positions count code points, as Python's str.
-- Python's types: integer and float stay apart (math.type), None is Y.null, a str is a Lua string (UTF-8).
-- Checked against PyYAML on every project file and on generated data: ingame/ref/yaml_check.py.
local Y = {}

-- --- data: ordered mappings, lists, null ---
local ORDER = setmetatable({}, {__mode = "k"})
-- the keys in a mapping's ORDER list (set, the old entries of keys set to nil too): a new key is appended at once - the
-- search for an old place of it only for a key that had one (25.10.: every new key searched the whole list; reading
-- talking_looks.json, 16 000 keys, took 2.7 s of the catalog's opening)
local LISTED = setmetatable({}, {__mode = "k"})
local MAP, LIST = {}, {}
Y.null = setmetatable({}, {__tostring = function() return "null" end, __name = "yaml.null"})

local function map_pairs(t)
  local keys = ORDER[t]
  local i, seen = 0, {}
  return function()
    while true do
      i = i + 1
      local k = keys[i]
      if k == nil then return nil end
      local v = rawget(t, k)
      if v ~= nil and not seen[k] then
        seen[k] = true
        return k, v
      end
    end
  end, t, nil
end
MAP.__pairs = map_pairs
MAP.__newindex = function(t, k, v)
  if v == nil then return end
  local keys, listed = ORDER[t], LISTED[t]
  if listed[k] then
    for i = #keys, 1, -1 do if keys[i] == k then table.remove(keys, i) end end   -- (deleted before: at the end now)
  end
  keys[#keys + 1] = k
  listed[k] = true
  rawset(t, k, v)
end
MAP.__name = "yaml.map"
LIST.__name = "yaml.list"

-- a mapping that keeps the order its keys came in (a Python dict); optional {k1, v1, k2, v2, ...}
function Y.map(kv)
  local t = setmetatable({}, MAP)
  ORDER[t] = {}
  LISTED[t] = {}
  if kv then for i = 1, #kv, 2 do t[kv[i]] = kv[i + 1] end end
  return t
end
function Y.list(items)
  return setmetatable(items or {}, LIST)
end
function Y.is_map(t) return type(t) == "table" and getmetatable(t) == MAP end
function Y.is_list(t) return type(t) == "table" and getmetatable(t) == LIST end
-- the keys of a mapping in order
function Y.keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  return out
end
function Y.len(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
-- a key taken out (Python's dict.pop: the others keep their order)
function Y.remove(t, k)
  local v = rawget(t, k)
  rawset(t, k, nil)
  local keys = ORDER[t]
  for i = #keys, 1, -1 do if keys[i] == k then table.remove(keys, i) end end
  LISTED[t][k] = nil
  return v
end

-- --- code points ---
local function cps(s)
  local out = {}
  for _, c in utf8.codes(s) do out[#out + 1] = c end
  return out
end
local char = utf8.char
local function sub(a, i, j)   -- a's code points i..j (1-based, inclusive) as a string
  local t = {}
  for k = i, j do
    if a[k] == nil then break end
    t[#t + 1] = char(a[k])
  end
  return table.concat(t)
end
local function is_break(c) return c == 10 or c == 0x85 or c == 0x2028 or c == 0x2029 end
local function is_ws_or_end(c)   -- '\0 \t\r\n\x85  '
  return c == 0 or c == 32 or c == 9 or c == 13 or c == 10 or c == 0x85 or c == 0x2028 or c == 0x2029
end
local function in_set(c, set)
  return c ~= nil and c < 128 and set:find(string.char(c), 1, true) ~= nil
end

-- --- the resolver (resolver.py): which tag a plain scalar would get ---
-- Python's re `$` also matches before a final "\n": the text is tried without it too
local function whole(s, f)
  if f(s) then return true end
  if s:sub(-1) == "\n" then return f(s:sub(1, -2)) end
  return false
end
local BOOLS = {}
for w in ("yes Yes YES no No NO true True TRUE false False FALSE on On ON off Off OFF"):gmatch("%S+") do BOOLS[w] = true end
local function is_bool(s) return BOOLS[s] == true end
local function digits_us(s) return s ~= "" and not s:find("[^0-9_]") end
local function is_float(s)
  local t = s:gsub("^[-+]", "")
  -- [-+]?[0-9][0-9_]*\.[0-9_]*([eE][-+][0-9]+)?
  local a, b, e = t:match("^([0-9][0-9_]*)%.([0-9_]*)(.*)$")
  if a then
    if e == "" or e:match("^[eE][-+][0-9]+$") then return true end
  end
  -- \.[0-9][0-9_]*([eE][-+][0-9]+)?   (no sign)
  local f, e2 = s:match("^%.([0-9][0-9_]*)(.*)$")
  if f and (e2 == "" or e2:match("^[eE][-+][0-9]+$")) then return true end
  -- [-+]?[0-9][0-9_]*(:[0-5]?[0-9])+\.[0-9_]*
  local head, rest = t:match("^([0-9][0-9_]*)(:.*)$")
  if head then
    local parts, frac = rest:match("^(.-)%.([0-9_]*)$")
    if parts and parts ~= "" then
      local ok = true
      for p in parts:gmatch(":([^:]*)") do if not p:match("^[0-5]?[0-9]$") then ok = false end end
      if ok and parts:match("^:") then return true end
    end
  end
  if t:match("^%.inf$") or t:match("^%.Inf$") or t:match("^%.INF$") then return true end
  if s == ".nan" or s == ".NaN" or s == ".NAN" then return true end
  return false
end
local function is_int(s)
  local t = s:gsub("^[-+]", "")
  if t:match("^0b[01_]+$") then return true end
  if t:match("^0[0-7_]+$") then return true end
  if t == "0" or t:match("^[1-9][0-9_]*$") then return true end
  if t:match("^0x[0-9a-fA-F_]+$") then return true end
  local head, rest = t:match("^([1-9][0-9_]*)(:.+)$")
  if head then
    for p in rest:gmatch(":([^:]*)") do if not p:match("^[0-5]?[0-9]$") then return false end end
    return rest:match("^:") ~= nil
  end
  return false
end
local function is_null(s) return s == "~" or s == "null" or s == "Null" or s == "NULL" or s == "" end
local function is_timestamp(s)
  if s:match("^%d%d%d%d%-%d%d%-%d%d$") then return true end
  -- [0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(\.[0-9]*)?(([ \t]*)(Z|[-+][0-9]{1,2}(:[0-9]{2})?))?
  local y, rest = s:match("^(%d%d%d%d%-%d%d?%-%d%d?)(.*)$")
  if not y then return false end
  local r = rest:match("^[Tt](.*)$") or rest:match("^[ \t]+(.*)$")
  if not r then return false end
  local tm, tail = r:match("^(%d%d?:%d%d:%d%d)(.*)$")
  if not tm then return false end
  tail = tail:gsub("^%.%d*", "", 1)
  if tail == "" then return true end
  tail = tail:gsub("^[ \t]*", "", 1)
  return tail == "Z" or tail:match("^[-+]%d%d?$") ~= nil or tail:match("^[-+]%d%d?:%d%d$") ~= nil
end
-- the order resolver.py tries them in (by the first character)
local FIRST = {}
local function add(tag, f, chars)
  for c in chars:gmatch(".") do FIRST[c] = FIRST[c] or {}; table.insert(FIRST[c], {tag, f}) end
end
add("bool", is_bool, "yYnNtTfFoO")
add("float", is_float, "-+0123456789.")
add("int", is_int, "-+0123456789")
add("merge", function(s) return s == "<<" end, "<")
add("null", is_null, "~nN")
add("timestamp", is_timestamp, "0123456789")
add("value", function(s) return s == "=" end, "=")
add("yaml", function(s) return s == "!" or s == "&" or s == "*" end, "!&*")
function Y.resolve(s)
  if s == "" then return "null" end
  for _, r in ipairs(FIRST[s:sub(1, 1)] or {}) do
    if whole(s, r[2]) then return r[1] end
  end
  return "str"
end

-- --- the representer (representer.py, SafeRepresenter) ---
-- Python's repr of a float: the shortest digits that read back the same, fixed between 1e-4 and 1e16
local function float_repr(x)
  if x ~= x then return ".nan" end
  if x == math.huge then return ".inf" end
  if x == -math.huge then return "-.inf" end
  if x == 0 then return (1 / x < 0) and "-0.0" or "0.0" end
  -- the fewest digits that read back as x; of those the nearest (dtoa mode 0): the correctly rounded string, else
  -- its neighbour on the side of x
  local function parts(s)
    local sg, d1, rest, ex = s:match("^(-?)(%d)%.?(%d*)e([-+]%d+)$")
    return sg, d1 .. rest, tonumber(ex)
  end
  local function build(sg, D, E)
    return sg .. D:sub(1, 1) .. (#D > 1 and ("." .. D:sub(2)) or "") .. "e" .. (E < 0 and "-" or "+") .. math.abs(E)
  end
  local function step(D, E, up)
    local t = {}
    for i = 1, #D do t[i] = D:byte(i) - 48 end
    local i = #t
    if up then
      while i >= 1 do
        if t[i] == 9 then t[i] = 0; i = i - 1 else t[i] = t[i] + 1; break end
      end
      if i < 1 then t[1] = 1; for k = 2, #t do t[k] = 0 end; E = E + 1 end
    else
      while i >= 1 do
        if t[i] == 0 then t[i] = 9; i = i - 1 else t[i] = t[i] - 1; break end
      end
      if t[1] == 0 then for k = 1, #t do t[k] = 9 end; E = E - 1 end
    end
    for k = 1, #t do t[k] = string.char(48 + t[k]) end
    return table.concat(t), E
  end
  local s
  for p = 1, 17 do
    s = string.format("%." .. (p - 1) .. "e", x)
    local v = tonumber(s)
    if v == x then break end
    if p < 17 then
      local sg, D, E = parts(s)
      local D2, E2 = step(D, E, (v < x) == (x > 0))
      local c = build(sg, D2, E2)
      if tonumber(c) == x then s = c; break end
    end
  end
  local sign, d1, rest, ex = s:match("^(-?)(%d)%.?(%d*)e([-+]%d+)$")
  local digits = (d1 .. rest):gsub("0+$", "")
  if digits == "" then digits = "0" end
  local e = tonumber(ex)
  local decpt = e + 1
  local out
  if decpt > -4 and decpt <= 16 then
    if decpt <= 0 then
      out = "0." .. string.rep("0", -decpt) .. digits
    elseif decpt >= #digits then
      out = digits .. string.rep("0", decpt - #digits) .. ".0"
    else
      out = digits:sub(1, decpt) .. "." .. digits:sub(decpt + 1)
    end
  else
    local m = digits:sub(1, 1) .. (#digits > 1 and ("." .. digits:sub(2)) or "")
    out = m .. "e" .. (e < 0 and "-" or "+") .. string.format("%02d", math.abs(e))
  end
  out = sign .. out
  -- represent_float: a repr with an exponent and no point gets ".0" before the e
  if not out:find(".", 1, true) and out:find("e", 1, true) then out = out:gsub("e", ".0e", 1) end
  return out
end
Y.float_repr = float_repr

local function represent(data, opts)
  local t = type(data)
  if data == nil or data == Y.null then return {kind = "scalar", tag = "null", value = "null"} end
  if t == "boolean" then return {kind = "scalar", tag = "bool", value = data and "true" or "false"} end
  if t == "number" then
    if math.type(data) == "integer" then return {kind = "scalar", tag = "int", value = tostring(data)} end
    return {kind = "scalar", tag = "float", value = float_repr(data)}
  end
  if t == "string" then return {kind = "scalar", tag = "str", value = data} end
  if t == "table" then
    -- the same table twice is one node (represented_objects): the serializer gives it an anchor
    local memo = opts.nodes
    if memo[data] then return memo[data] end
    local best = true
    if Y.is_map(data) or (not Y.is_list(data) and next(data) ~= nil and data[1] == nil) then
      local items = {}
      local node = {kind = "mapping", items = items}
      memo[data] = node
      local keys = Y.is_map(data) and Y.keys(data) or (function()
        local ks = {}
        for k in pairs(data) do ks[#ks + 1] = k end
        table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
        return ks
      end)()
      if opts.sort_keys then
        local ok, sorted = pcall(require("conjunction.pysort").sorted, keys)   -- (sorted(): Python's order)
        if ok then keys = sorted else keys = Y.keys(data) end
      end
      for _, k in ipairs(keys) do
        local kn, vn = represent(k, opts), represent(data[k], opts)
        if kn.kind ~= "scalar" or vn.kind ~= "scalar" then best = false end
        items[#items + 1] = {kn, vn}
      end
      local flow = opts.default_flow_style
      if flow == nil then flow = best end
      node.flow = flow
      return node
    end
    local items = {}
    local node = {kind = "sequence", items = items}
    memo[data] = node
    for i = 1, #data do
      local n = represent(data[i], opts)
      if n.kind ~= "scalar" then best = false end
      items[i] = n
    end
    local flow = opts.default_flow_style
    if flow == nil then flow = best end
    node.flow = flow
    return node
  end
  error("yaml: cannot represent a " .. t)
end

-- --- the emitter (emitter.py) ---
local function analyze(a, allow_unicode)
  local n = #a
  if n == 0 then
    return {empty = true, multiline = false, flow_plain = false, block_plain = true, single = true, double = true,
            block = false}
  end
  local block_ind, flow_ind, line_breaks, special = false, false, false, false
  local lead_space, lead_break, trail_space, trail_break, break_space, space_break = false, false, false, false, false, false
  local s3 = n >= 3 and sub(a, 1, 3) or ""
  if s3 == "---" or s3 == "..." then block_ind, flow_ind = true, true end
  local preceded = true
  local followed = (n == 1) or is_ws_or_end(a[2])
  local prev_space, prev_break = false, false
  for i = 1, n do
    local ch = a[i]
    if i == 1 then
      if in_set(ch, "#,[]{}&*!|>'\"%@`") then flow_ind, block_ind = true, true end
      if in_set(ch, "?:") then
        flow_ind = true
        if followed then block_ind = true end
      end
      if ch == 45 and followed then flow_ind, block_ind = true, true end
    else
      if in_set(ch, ",?[]{}") then flow_ind = true end
      if ch == 58 then
        flow_ind = true
        if followed then block_ind = true end
      end
      if ch == 35 and preceded then flow_ind, block_ind = true, true end
    end
    if is_break(ch) then line_breaks = true end
    if not (ch == 10 or (ch >= 0x20 and ch <= 0x7E)) then
      if (ch == 0x85 or (ch >= 0xA0 and ch <= 0xD7FF) or (ch >= 0xE000 and ch <= 0xFFFD) or
          (ch >= 0x10000 and ch < 0x10FFFF)) and ch ~= 0xFEFF then
        if not allow_unicode then special = true end
      else
        special = true
      end
    end
    if ch == 32 then
      if i == 1 then lead_space = true end
      if i == n then trail_space = true end
      if prev_break then break_space = true end
      prev_space, prev_break = true, false
    elseif is_break(ch) then
      if i == 1 then lead_break = true end
      if i == n then trail_break = true end
      if prev_space then space_break = true end
      prev_space, prev_break = false, true
    else
      prev_space, prev_break = false, false
    end
    preceded = is_ws_or_end(ch)
    followed = (i + 1 >= n) or is_ws_or_end(a[i + 2])
  end
  local fp, bp, sq, dq, bl = true, true, true, true, true
  if lead_space or lead_break or trail_space or trail_break then fp, bp = false, false end
  if trail_space then bl = false end
  if break_space then fp, bp, sq = false, false, false end
  if space_break or special then fp, bp, sq, bl = false, false, false, false end
  if line_breaks then fp, bp = false, false end
  if flow_ind then fp = false end
  if block_ind then bp = false end
  return {empty = false, multiline = line_breaks, flow_plain = fp, block_plain = bp, single = sq, double = dq,
          block = bl}
end

local ESC = {[0] = "0", [7] = "a", [8] = "b", [9] = "t", [10] = "n", [11] = "v", [12] = "f", [13] = "r", [27] = "e",
             [34] = "\"", [92] = "\\", [0x85] = "N", [0xA0] = "_", [0x2028] = "L", [0x2029] = "P"}

function Y.dump(data, opts)
  opts = opts or {}
  local allow_unicode = opts.allow_unicode or false
  local best_indent, best_width = 2, 80
  if opts.width and opts.width > best_indent * 2 then best_width = opts.width end   -- (Emitter: width=)
  local out = {}
  local E = {indent = nil, indents = {}, flow_level = 0, column = 0, whitespace = true, indention = true,
             open_ended = false, root = false, seq_ctx = false, map_ctx = false, simple_key = false}
  local function write(s) out[#out + 1] = s end
  local function increase_indent(flow, indentless)
    E.indents[#E.indents + 1] = E.indent or false
    if E.indent == nil then
      E.indent = flow and best_indent or 0
    elseif not indentless then
      E.indent = E.indent + best_indent
    end
  end
  local function pop_indent()
    local v = table.remove(E.indents)
    E.indent = v ~= false and v or nil
  end
  local function write_indicator(ind, need_ws, whitespace, indention)
    local data = (E.whitespace or not need_ws) and ind or (" " .. ind)
    E.whitespace = whitespace or false
    E.indention = E.indention and (indention or false)
    E.column = E.column + utf8.len(data)
    E.open_ended = false
    write(data)
  end
  local function write_line_break(data)
    E.whitespace, E.indention = true, true
    E.column = 0
    write(data or "\n")
  end
  local function write_indent()
    local indent = E.indent or 0
    if not E.indention or E.column > indent or (E.column == indent and not E.whitespace) then write_line_break() end
    if E.column < indent then
      E.whitespace = true
      write(string.rep(" ", indent - E.column))
      E.column = indent
    end
  end
  local function brk_char(c) return c == 10 and nil or char(c) end

  local function write_plain(a, split)
    if E.root then E.open_ended = true end
    if #a == 0 then return end
    if not E.whitespace then
      E.column = E.column + 1
      write(" ")
    end
    E.whitespace, E.indention = false, false
    local spaces, breaks = false, false
    local start, n = 1, #a
    for e = 1, n + 1 do
      local ch = a[e]
      if spaces then
        if ch ~= 32 then
          if start + 1 == e and E.column > best_width and split then
            write_indent()
            E.whitespace, E.indention = false, false
          else
            E.column = E.column + (e - start)
            write(sub(a, start, e - 1))
          end
          start = e
        end
      elseif breaks then
        if not is_break(ch) then
          if a[start] == 10 then write_line_break() end
          for k = start, e - 1 do write_line_break(brk_char(a[k])) end
          write_indent()
          E.whitespace, E.indention = false, false
          start = e
        end
      else
        if ch == nil or ch == 32 or is_break(ch) then
          E.column = E.column + (e - start)
          write(sub(a, start, e - 1))
          start = e
        end
      end
      if ch ~= nil then
        spaces = ch == 32
        breaks = is_break(ch)
      end
    end
  end

  local function write_single_quoted(a, split)
    write_indicator("'", true)
    local spaces, breaks = false, false
    local start, n = 1, #a
    for e = 1, n + 1 do
      local ch = a[e]
      if spaces then
        if ch == nil or ch ~= 32 then
          if start + 1 == e and E.column > best_width and split and start ~= 1 and e ~= n + 1 then
            write_indent()
          else
            E.column = E.column + (e - start)
            write(sub(a, start, e - 1))
          end
          start = e
        end
      elseif breaks then
        if ch == nil or not is_break(ch) then
          if a[start] == 10 then write_line_break() end
          for k = start, e - 1 do write_line_break(brk_char(a[k])) end
          write_indent()
          start = e
        end
      else
        if ch == nil or ch == 32 or is_break(ch) or ch == 39 then
          if start < e then
            E.column = E.column + (e - start)
            write(sub(a, start, e - 1))
            start = e
          end
        end
      end
      if ch == 39 then
        E.column = E.column + 2
        write("''")
        start = e + 1
      end
      if ch ~= nil then
        spaces = ch == 32
        breaks = is_break(ch)
      end
    end
    write_indicator("'", false)
  end

  local function write_double_quoted(a, split)
    write_indicator('"', true)
    local start, n = 1, #a
    for e = 1, n + 1 do
      local ch = a[e]
      if ch == nil or ch == 34 or ch == 92 or ch == 0x85 or ch == 0x2028 or ch == 0x2029 or ch == 0xFEFF or
         not ((ch >= 0x20 and ch <= 0x7E) or (allow_unicode and ((ch >= 0xA0 and ch <= 0xD7FF) or
                                                               (ch >= 0xE000 and ch <= 0xFFFD)))) then
        if start < e then
          E.column = E.column + (e - start)
          write(sub(a, start, e - 1))
          start = e
        end
        if ch ~= nil then
          local data
          if ESC[ch] then data = "\\" .. ESC[ch]
          elseif ch <= 0xFF then data = string.format("\\x%02X", ch)
          elseif ch <= 0xFFFF then data = string.format("\\u%04X", ch)
          else data = string.format("\\U%08X", ch) end
          E.column = E.column + #data
          write(data)
          start = e + 1
        end
      end
      -- (Python: 0 < end < len(text)-1, end 0-based: e - 1)
      if 0 < e - 1 and e - 1 < n - 1 and (ch == 32 or start >= e) and E.column + (e - start) > best_width and split then
        local data = sub(a, start, e - 1) .. "\\"
        if start < e then start = e end
        E.column = E.column + utf8.len(data)
        write(data)
        write_indent()
        E.whitespace, E.indention = false, false
        if a[start] == 32 then
          E.column = E.column + 1
          write("\\")
        end
      end
    end
    write_indicator('"', false)
  end

  local function choose_style(node, an)
    local implicit0 = node.implicit[1]
    if implicit0 then
      if not (E.simple_key and (an.empty or an.multiline)) and
         ((E.flow_level > 0 and an.flow_plain) or (E.flow_level == 0 and an.block_plain)) then
        return ""
      end
    end
    if an.single and not (E.simple_key and an.multiline) then return "'" end
    return '"'
  end

  local function scalar_parts(node)
    if not node.cps then
      node.cps = cps(node.value)
      node.an = analyze(node.cps, allow_unicode)
      local detected = Y.resolve(node.value)
      node.implicit = {node.tag == detected, node.tag == "str"}
    end
  end

  -- (the length counts the tag as prepare_tag writes it, "!!str", even when it is not written)
  local TAG_LEN = {str = 5, int = 5, float = 7, bool = 6, null = 6}
  local function check_simple_key(node)
    if node.emitted then return #node.anchor < 128 end     -- an alias
    if node.kind == "scalar" then
      scalar_parts(node)
      return #node.cps + TAG_LEN[node.tag] < 128 and not node.an.empty and not node.an.multiline
    end
    return (node.anchor and #node.anchor or 0) + 5 < 128 and #node.items == 0
  end

  local expect_node
  local function process_scalar(node)
    scalar_parts(node)
    local style = choose_style(node, node.an)
    if not ((style == "" and node.implicit[1]) or (style ~= "" and node.implicit[2])) then
      error("yaml: a " .. node.tag .. " scalar would need a tag: " .. node.value)
    end
    local split = not E.simple_key
    if style == '"' then write_double_quoted(node.cps, split)
    elseif style == "'" then write_single_quoted(node.cps, split)
    else write_plain(node.cps, split) end
  end

  local function flow_sequence(node)
    write_indicator("[", true, true)
    E.flow_level = E.flow_level + 1
    increase_indent(true)
    for i, item in ipairs(node.items) do
      if i > 1 then write_indicator(",", false) end
      if E.column > best_width then write_indent() end
      expect_node(item, false, true, false, false)
    end
    pop_indent()
    E.flow_level = E.flow_level - 1
    write_indicator("]", false)
  end
  local function flow_mapping(node)
    write_indicator("{", true, true)
    E.flow_level = E.flow_level + 1
    increase_indent(true)
    for i, kv in ipairs(node.items) do
      if i > 1 then write_indicator(",", false) end
      if E.column > best_width then write_indent() end
      if check_simple_key(kv[1]) then
        expect_node(kv[1], false, false, true, true)
        write_indicator(":", false)
      else
        write_indicator("?", true)
        expect_node(kv[1], false, false, true, false)
        if E.column > best_width then write_indent() end
        write_indicator(":", true)
      end
      expect_node(kv[2], false, false, true, false)
    end
    pop_indent()
    E.flow_level = E.flow_level - 1
    write_indicator("}", false)
  end
  local function block_sequence(node)
    local indentless = E.map_ctx and not E.indention
    increase_indent(false, indentless)
    for _, item in ipairs(node.items) do
      write_indent()
      write_indicator("-", true, false, true)
      expect_node(item, false, true, false, false)
    end
    pop_indent()
  end
  local function block_mapping(node)
    increase_indent(false)
    for _, kv in ipairs(node.items) do
      write_indent()
      if check_simple_key(kv[1]) then
        expect_node(kv[1], false, false, true, true)
        write_indicator(":", false)
      else
        write_indicator("?", true, false, true)
        expect_node(kv[1], false, false, true, false)
        write_indent()
        write_indicator(":", true, false, true)
      end
      expect_node(kv[2], false, false, true, false)
    end
    pop_indent()
  end
  expect_node = function(node, root, seq, map, simple_key)
    E.root, E.seq_ctx, E.map_ctx, E.simple_key = root, seq, map, simple_key
    if node.emitted then                     -- an alias of a node written before
      write_indicator("*" .. node.anchor, true)
      return
    end
    if node.anchor then
      write_indicator("&" .. node.anchor, true)
      node.emitted = true
    end
    if node.kind == "scalar" then
      increase_indent(true)
      process_scalar(node)
      pop_indent()
    elseif node.kind == "sequence" then
      if E.flow_level > 0 or node.flow or #node.items == 0 then flow_sequence(node) else block_sequence(node) end
    else
      if E.flow_level > 0 or node.flow or #node.items == 0 then flow_mapping(node) else block_mapping(node) end
    end
  end

  local root = represent(data, {sort_keys = opts.sort_keys ~= false, default_flow_style = opts.default_flow_style,
                                nodes = {}})
  -- serializer.anchor_node: a node met a second time gets the next anchor, id001, id002 ...
  local seen, last = {}, 0
  local function walk(nd)
    if nd.kind == "scalar" then return end
    if seen[nd] then
      if not nd.anchor then
        last = last + 1
        nd.anchor = string.format("id%03d", last)
      end
      return
    end
    seen[nd] = true
    for _, it in ipairs(nd.items) do
      if nd.kind == "mapping" then walk(it[1]); walk(it[2]) else walk(it) end
    end
  end
  walk(root)
  -- an empty document (a lone empty plain scalar) starts with "---" (check_empty_document)
  if root.kind == "scalar" then
    scalar_parts(root)
    if root.value == "" and root.implicit[1] then
      write_indent()
      write_indicator("---", true)
    end
  end
  expect_node(root, true, false, false, false)
  write_indent()          -- the document's end
  if E.open_ended then    -- the stream's end after an open-ended document (a plain scalar at the root)
    write_indicator("...", true)
    write_indent()
  end
  return table.concat(out)
end

-- --- the reader: the YAML PyYAML writes (block and flow collections, plain and quoted scalars over several lines),
-- resolved as PyYAML's SafeLoader does ---
local function construct_plain(s)
  local tag = Y.resolve(s)
  if tag == "null" then return Y.null end
  if tag == "bool" then
    local l = s:lower()
    return l == "yes" or l == "true" or l == "on"
  end
  if tag == "int" then
    local t = s:gsub("_", "")
    local sign = 1
    if t:sub(1, 1) == "-" then sign, t = -1, t:sub(2) elseif t:sub(1, 1) == "+" then t = t:sub(2) end
    if t == "0" then return 0 end
    if t:sub(1, 2) == "0b" then return sign * tonumber(t:sub(3), 2) end
    if t:sub(1, 2) == "0x" then return sign * tonumber(t:sub(3), 16) end
    if t:sub(1, 1) == "0" then return sign * tonumber(t:sub(2), 8) end
    if t:find(":", 1, true) then
      local v = 0
      for p in t:gmatch("[^:]+") do v = v * 60 + tonumber(p) end
      return sign * v
    end
    return sign * math.tointeger(tonumber(t))
  end
  if tag == "float" then
    local t = s:gsub("_", ""):lower()
    local sign = 1.0
    if t:sub(1, 1) == "-" then sign, t = -1.0, t:sub(2) elseif t:sub(1, 1) == "+" then t = t:sub(2) end
    if t == ".inf" then return sign * math.huge end
    if t == ".nan" then return 0 / 0 end
    if t:find(":", 1, true) then
      local v = 0.0
      for p in t:gmatch("[^:]+") do v = v * 60 + tonumber(p) end
      return sign * v
    end
    return sign * (tonumber(t) + 0.0)
  end
  return s        -- str, and timestamps (kept as their text)
end

function Y.load(text)
  local src = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end
  local a = cps(src)
  local pos, n = 1, #a
  local function peek(k) return a[pos + (k or 0)] end
  local function col_of(p)   -- the column (0-based) of position p
    local c = 0
    local q = p - 1
    while q >= 1 and not is_break(a[q]) do c, q = c + 1, q - 1 end   -- (any YAML line break starts a line)
    return c
  end
  local function err(msg) error(string.format("yaml: %s at character %d", msg, pos), 0) end
  local function is_blank(c) return c == 32 or c == 9 end
  local function at_eol(p) local c = a[p] return c == nil or is_break(c) end

  -- skip spaces, comments and line breaks; -> the column of the next content (nil at the end)
  local function skip_space()
    while pos <= n do
      local c = a[pos]
      if c == 32 or c == 9 or is_break(c) then
        pos = pos + 1
      elseif c == 35 and (pos == 1 or is_blank(a[pos - 1]) or is_break(a[pos - 1])) then
        while pos <= n and not is_break(a[pos]) do pos = pos + 1 end
      else
        return col_of(pos)
      end
    end
    return nil
  end
  local function skip_inline()   -- spaces and a comment on this line
    while pos <= n and is_blank(a[pos]) do pos = pos + 1 end
    if a[pos] == 35 then while pos <= n and a[pos] ~= 10 do pos = pos + 1 end end
  end

  -- --- scalars as PyYAML's scanner reads them (scanner.py: scan_plain, scan_plain_spaces, scan_flow_scalar*,
  -- scan_line_break); `a` holds code points, `pos` the next one ---
  local function brk(c) return c == 10 or c == 13 or c == 0x85 or c == 0x2028 or c == 0x2029 end
  local function wsend(c) return c == nil or c == 0 or c == 32 or c == 9 or brk(c) end
  -- '\r\n', '\r', '\n', '\x85' -> "\n"; ' ', ' ' stay; else ""
  local function scan_line_break()
    local c = a[pos]
    if c == 13 or c == 10 or c == 0x85 then
      if c == 13 and a[pos + 1] == 10 then pos = pos + 2 else pos = pos + 1 end
      return "\n"
    elseif c == 0x2028 or c == 0x2029 then
      pos = pos + 1
      return char(c)
    end
    return ""
  end
  local function doc_sep_here()
    local p3 = sub(a, pos, pos + 2)
    return (p3 == "---" or p3 == "...") and wsend(a[pos + 3])
  end
  local function col_here() return col_of(pos) end

  local function scan_plain_spaces(indent)
    local chunks = {}
    local start = pos
    while a[pos] == 32 do pos = pos + 1 end
    local whitespaces = sub(a, start, pos - 1)
    local c = a[pos]
    if c ~= nil and brk(c) then
      local line_break = scan_line_break()
      if doc_sep_here() then return nil end
      local breaks = {}
      while a[pos] ~= nil and (a[pos] == 32 or brk(a[pos])) do
        if a[pos] == 32 then pos = pos + 1
        else
          breaks[#breaks + 1] = scan_line_break()
          if doc_sep_here() then return nil end
        end
      end
      if line_break ~= "\n" then chunks[#chunks + 1] = line_break
      elseif #breaks == 0 then chunks[#chunks + 1] = " " end
      for _, b in ipairs(breaks) do chunks[#chunks + 1] = b end
    elseif whitespaces ~= "" then
      chunks[#chunks + 1] = whitespaces
    end
    return chunks
  end

  -- a plain scalar; parent_indent: the indentation of the collection it is in (-1 at the root), flow: inside [ ] { }
  local function plain(flow, parent_indent)
    local chunks, spaces = {}, {}
    local indent = parent_indent + 1
    while true do
      if a[pos] == 35 then break end
      local length = 0
      while true do
        local c = a[pos + length]
        if wsend(c) or (c == 58 and (wsend(a[pos + length + 1]) or (flow and in_set(a[pos + length + 1], ",[]{}")))) or
           (flow and in_set(c, ",?[]{}")) then
          break
        end
        length = length + 1
      end
      if length == 0 then break end
      for _, s in ipairs(spaces) do chunks[#chunks + 1] = s end
      chunks[#chunks + 1] = sub(a, pos, pos + length - 1)
      pos = pos + length
      spaces = scan_plain_spaces(indent)
      if not spaces or #spaces == 0 or a[pos] == 35 or (not flow and col_here() < indent) then break end
    end
    return table.concat(chunks)
  end

  local function scan_flow_scalar_breaks()
    local chunks = {}
    while true do
      if doc_sep_here() then err("a document separator inside a quoted scalar") end
      while a[pos] == 32 or a[pos] == 9 do pos = pos + 1 end
      if a[pos] ~= nil and brk(a[pos]) then chunks[#chunks + 1] = scan_line_break()
      else return chunks end
    end
  end
  local function scan_flow_scalar_spaces()
    local chunks = {}
    local start = pos
    while a[pos] == 32 or a[pos] == 9 do pos = pos + 1 end
    local whitespaces = sub(a, start, pos - 1)
    local c = a[pos]
    if c == nil then err("the end inside a quoted scalar")
    elseif brk(c) then
      local line_break = scan_line_break()
      local breaks = scan_flow_scalar_breaks()
      if line_break ~= "\n" then chunks[#chunks + 1] = line_break
      elseif #breaks == 0 then chunks[#chunks + 1] = " " end
      for _, b in ipairs(breaks) do chunks[#chunks + 1] = b end
    else
      chunks[#chunks + 1] = whitespaces
    end
    return chunks
  end
  local REPL = {[48] = "\0", [97] = "\a", [98] = "\b", [116] = "\t", [9] = "\t", [110] = "\n", [118] = "\v",
                [102] = "\f", [114] = "\r", [101] = "\27", [32] = " ", [34] = '"', [92] = "\\", [47] = "/",
                [78] = char(0x85), [95] = char(0xA0), [76] = char(0x2028), [80] = char(0x2029)}
  local CODES = {[120] = 2, [117] = 4, [85] = 8}
  local function scan_flow_scalar_non_spaces(double)
    local chunks = {}
    while true do
      local length = 0
      while true do
        local c = a[pos + length]
        if c == nil or c == 39 or c == 34 or c == 92 or c == 0 or c == 32 or c == 9 or brk(c) then break end
        length = length + 1
      end
      if length > 0 then
        chunks[#chunks + 1] = sub(a, pos, pos + length - 1)
        pos = pos + length
      end
      local c = a[pos]
      if not double and c == 39 and a[pos + 1] == 39 then
        chunks[#chunks + 1] = "'"
        pos = pos + 2
      elseif (double and c == 39) or (not double and (c == 34 or c == 92)) then
        chunks[#chunks + 1] = char(c)
        pos = pos + 1
      elseif double and c == 92 then
        pos = pos + 1
        c = a[pos]
        if c ~= nil and REPL[c] then
          chunks[#chunks + 1] = REPL[c]
          pos = pos + 1
        elseif c ~= nil and CODES[c] then
          local len = CODES[c]
          pos = pos + 1
          local hx = sub(a, pos, pos + len - 1)
          if not hx:match("^%x+$") or #hx ~= len then err("an escape needs " .. len .. " hex digits") end
          chunks[#chunks + 1] = char(tonumber(hx, 16))
          pos = pos + len
        elseif c ~= nil and brk(c) then
          scan_line_break()
          for _, b in ipairs(scan_flow_scalar_breaks()) do chunks[#chunks + 1] = b end
        else
          err("an unknown escape")
        end
      else
        return chunks
      end
    end
  end
  local function flow_scalar(double)
    local quote = a[pos]
    pos = pos + 1
    local chunks = {}
    for _, s in ipairs(scan_flow_scalar_non_spaces(double)) do chunks[#chunks + 1] = s end
    while a[pos] ~= quote do
      for _, s in ipairs(scan_flow_scalar_spaces()) do chunks[#chunks + 1] = s end
      for _, s in ipairs(scan_flow_scalar_non_spaces(double)) do chunks[#chunks + 1] = s end
    end
    pos = pos + 1
    return table.concat(chunks)
  end
  local function single_quoted() return flow_scalar(false) end
  local function double_quoted() return flow_scalar(true) end

  local parse_node
  local function flow_node()
    local c = a[pos]
    if c == 91 then          -- [
      pos = pos + 1
      local list = Y.list()
      while true do
        skip_space()
        if a[pos] == 93 then pos = pos + 1; return list end
        local item = parse_node(-1, true)
        skip_space()
        if a[pos] == 58 and (is_ws_or_end(a[pos + 1]) or in_set(a[pos + 1], ",[]{}")) then
          -- a single pair in a flow sequence: a mapping of one
          pos = pos + 1
          skip_space()
          local v = (a[pos] == 44 or a[pos] == 93) and Y.null or parse_node(-1, true)
          local m = Y.map()
          m[item] = v
          item = m
          skip_space()
        end
        list[#list + 1] = item
        if a[pos] == 44 then pos = pos + 1
        elseif a[pos] ~= 93 then err("expected , or ]") end
      end
    elseif c == 123 then     -- {
      pos = pos + 1
      local m = Y.map()
      while true do
        skip_space()
        if a[pos] == 125 then pos = pos + 1; return m end
        if a[pos] == 63 and is_ws_or_end(a[pos + 1]) then pos = pos + 1; skip_space() end
        local k = parse_node(-1, true)
        skip_space()
        local v = Y.null
        if a[pos] == 58 then
          pos = pos + 1
          skip_space()
          if a[pos] ~= 44 and a[pos] ~= 125 then v = parse_node(-1, true) end
          skip_space()
        end
        m[k] = v
        if a[pos] == 44 then pos = pos + 1
        elseif a[pos] ~= 125 then err("expected , or }") end
      end
    elseif c == 39 then return single_quoted()
    elseif c == 34 then return double_quoted()
    else
      return construct_plain(plain(true, -1))
    end
  end

  -- a scalar key or value on one line, block context (quoted or plain); -> value, was_plain_text
  local function block_scalar(min_col)
    local c = a[pos]
    if c == 39 then return single_quoted() end
    if c == 34 then return double_quoted() end
    return construct_plain(plain(false, min_col))
  end

  -- is there "key:" starting at pos (on this line)?
  local function key_ahead()
    local p = pos
    local c = a[p]
    if c == 39 or c == 34 then        -- a quoted key: to its end, then ':'
      local q = p + 1
      while a[q] and a[q] ~= 10 do
        if a[q] == c then
          if c == 39 and a[q + 1] == 39 then q = q + 2
          else break end
        elseif c == 34 and a[q] == 92 then q = q + 2
        else q = q + 1 end
      end
      if a[q] ~= c then return false end
      q = q + 1
      while is_blank(a[q]) do q = q + 1 end
      return a[q] == 58 and is_ws_or_end(a[q + 1])
    end
    if c == 91 or c == 123 then return false end
    if c == 63 and is_ws_or_end(a[p + 1]) then return true end
    while a[p] and a[p] ~= 10 do
      if a[p] == 58 and is_ws_or_end(a[p + 1]) then return true end
      if a[p] == 35 and p > pos and is_blank(a[p - 1]) then return false end
      p = p + 1
    end
    return false
  end

  local function block_mapping(col)
    local m = Y.map()
    while true do
      local c = skip_space()
      if c == nil or c ~= col then break end
      if not key_ahead() then break end
      local k
      local complex = a[pos] == 63 and is_ws_or_end(a[pos + 1])
      if complex then
        pos = pos + 1
        skip_inline()
        k = parse_node(col, false)
        local c2 = skip_space()
        if c2 ~= col or a[pos] ~= 58 then m[k] = Y.null; goto continue end
      else
        if a[pos] == 39 then k = single_quoted() elseif a[pos] == 34 then k = double_quoted()
        else
          local cur = {}
          while not (a[pos] == 58 and is_ws_or_end(a[pos + 1])) do cur[#cur + 1] = char(a[pos]); pos = pos + 1 end
          k = construct_plain((table.concat(cur):gsub("[ \t]+$", "")))
        end
        while is_blank(a[pos]) do pos = pos + 1 end
      end
      pos = pos + 1          -- the ':'
      skip_inline()
      if at_eol(pos) then
        -- the value on the next lines: deeper, or a sequence at the same column
        local save = pos
        local c2 = skip_space()
        if c2 ~= nil and (c2 > col or (c2 == col and a[pos] == 45 and is_ws_or_end(a[pos + 1]))) then
          m[k] = parse_node(c2 == col and col - 1 or col, false)
        else
          pos = save
          m[k] = Y.null
        end
      else
        m[k] = parse_node(col, false)
      end
      ::continue::
    end
    return m
  end

  local function block_sequence(col)
    local list = Y.list()
    while true do
      local c = skip_space()
      if c == nil or c ~= col or not (a[pos] == 45 and is_ws_or_end(a[pos + 1])) then break end
      pos = pos + 1
      skip_inline()
      if at_eol(pos) then
        local save = pos
        local c2 = skip_space()
        if c2 ~= nil and c2 > col then
          list[#list + 1] = parse_node(col, false)
        else
          pos = save
          list[#list + 1] = Y.null
        end
      else
        while is_blank(a[pos]) do pos = pos + 1 end
        list[#list + 1] = parse_node(col, false)
      end
    end
    return list
  end

  -- a node whose content starts at pos; parent_col: the column it has to be deeper than
  -- an anchor (&name) or an alias (*name) at pos: its name (pos after it)
  local function name_at()
    local start = pos + 1
    pos = start
    while a[pos] and not wsend(a[pos]) and not in_set(a[pos], ",[]{}") do pos = pos + 1 end
    return sub(a, start, pos - 1)
  end
  local anchors = {}
  local parse_node_plain
  parse_node = function(parent_col, flow)
    if a[pos] == 42 then                -- *alias: the node with that anchor
      local name = name_at()
      if anchors[name] == nil then err("an alias without its anchor: " .. name) end
      return anchors[name]
    end
    if a[pos] == 38 then                -- &anchor: the node after it (on this line or the next ones)
      local name = name_at()
      local v
      if flow then
        skip_space()
        v = (a[pos] == 44 or a[pos] == 93 or a[pos] == 125) and Y.null or parse_node(parent_col, true)
      else
        skip_inline()
        if at_eol(pos) then
          local save = pos
          local c2 = skip_space()
          if c2 ~= nil and (c2 > parent_col or (c2 == parent_col and a[pos] == 45 and is_ws_or_end(a[pos + 1]))) then
            v = parse_node(c2 == parent_col and parent_col - 1 or parent_col, false)
          else
            pos = save
            v = Y.null
          end
        else
          v = parse_node(parent_col, false)
        end
      end
      anchors[name] = v
      return v
    end
    return parse_node_plain(parent_col, flow)
  end
  parse_node_plain = function(parent_col, flow)
    if flow then return flow_node() end
    local col = col_of(pos)
    local c = a[pos]
    if c == 45 and is_ws_or_end(a[pos + 1]) then return block_sequence(col) end
    if c == 91 or c == 123 then
      local v = flow_node()
      return v
    end
    if key_ahead() then return block_mapping(col) end
    return block_scalar(parent_col)
  end

  local c = skip_space()
  if c == nil then return Y.null end
  if a[pos] == 45 and a[pos + 1] == 45 and a[pos + 2] == 45 and is_ws_or_end(a[pos + 3]) then
    pos = pos + 3
    skip_inline()
    c = skip_space()
    if c == nil then return Y.null end
  end
  local v = parse_node(-1, false)
  skip_space()
  return v
end

-- --- files: UTF-8, CRLF line ends (Python's text mode on Windows) ---
-- (w3.fs takes UTF-8 paths; plain Lua's io for the tests outside the game)
local fs = rawget(_G, "w3") and w3.fs
function Y.read(path)
  local s
  if fs then
    s = fs.read(path)
  else
    local f = io.open(path, "rb")
    if f then s = f:read("a"); f:close() end
  end
  if not s then return nil end
  return Y.load(s)
end
function Y.write(path, data, opts)
  local text = Y.dump(data, opts):gsub("\n", "\r\n")
  if fs then
    assert(fs.write(path, text))
    return
  end
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  f:write(text)
  f:close()
  os.remove(path)
  assert(os.rename(tmp, path))
end

return Y
