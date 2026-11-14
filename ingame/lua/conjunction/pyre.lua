-- Python's re module for Lua: the same patterns find the same things (sre's rules), on code points as Python's str
-- (positions are Python's: 0-based character indices). Checked against Python's re: ingame/ref/pyre_check.py.
--
--   local R = require("conjunction.pyre")
--   R.search(p, s [, flags]), R.match, R.fullmatch     -> a match or nil
--   R.findall(p, s [, flags]) -> {string or {groups} ...};  R.finditer(p, s [, flags]) -> iterator of matches
--   R.sub(p, repl, s [, count [, flags]]) -> string (repl: a template with \1, \g<name> ..., or a function(m))
--   R.subn(...) -> string, n;  R.split(p, s [, maxsplit [, flags]]);  R.escape(s);  R.compile(p [, flags])
--   a compiled pattern: the same as methods, p:search(s [, pos [, endpos]]) ...
--   a match: m:group([g ...]), m:groups([default]), m:groupdict(), m:start([g]), m:stop([g]) (Python's end),
--            m:span([g]), m.string, m.pos, m.re; a group that took no part: nil (Python's None)
-- Flags: R.I, R.M, R.S, R.X, R.A (and R.U, Python's default for str). Parts of re no Conjunction code uses
-- ((?(id)yes|no), \N{...}, re.L) raise an error rather than doing something else.
local S = require("conjunction.pystr")
local U = S.U
local in_ranges = S.in_ranges
local R = {I = 2, IGNORECASE = 2, L = 4, M = 8, MULTILINE = 8, S = 16, DOTALL = 16, U = 32, UNICODE = 32, X = 64,
           VERBOSE = 64, A = 256, ASCII = 256}

local function perr(msg, pat) error("pyre: " .. msg .. " in pattern " .. string.format("%q", pat), 3) end

-- --- characters and their classes ---
local function low1(c) return U.SIMPLE_LOWER[c] or c end       -- _sre.unicode_tolower
local function is_word(c, ascii)
  if ascii or c < 128 then
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
  end
  return c == 95 or in_ranges(U.ALNUM, c)
end
local function is_digit(c, ascii)
  if ascii or c < 128 then return c >= 48 and c <= 57 end
  return in_ranges(U.DECIMAL, c)
end
local function is_space(c, ascii)
  if ascii or c < 128 then return c == 32 or (c >= 9 and c <= 13) or (not ascii and (c >= 28 and c <= 31)) end
  return in_ranges(U.SPACE, c)
end
-- sre's \s for ASCII: " \t\n\r\f\v" (SRE_IS_SPACE); for str patterns (Unicode) Py_UNICODE_ISSPACE, which has 28..31
local CLASS = {d = function(c, a) return is_digit(c, a) end, w = function(c, a) return is_word(c, a) end,
               s = function(c, a) return is_space(c, a) end}

-- --- the parser (sre_parse) ---
local SPECIAL_ESC = {n = 10, t = 9, r = 13, f = 12, v = 11, a = 7, ["\\"] = 92}

local P = {}
P.__index = P
local function parser(pat, flags)
  return setmetatable({pat = pat, cps = S.cps(pat), i = 1, flags = flags, ngroups = 0, names = {}, gnames = {}}, P)
end
function P:peek(k) return self.cps[self.i + (k or 0)] end
function P:next() local c = self.cps[self.i] self.i = self.i + 1 return c end
function P:eat(ch) if self.cps[self.i] == ch then self.i = self.i + 1 return true end return false end
function P:verbose_skip()
  if self.flags & R.X == 0 then return end
  while true do
    local c = self:peek()
    if c == nil then return end
    if is_space(c, true) then self.i = self.i + 1
    elseif c == 35 then                               -- '#' to the line's end
      while self:peek() and self:peek() ~= 10 do self.i = self.i + 1 end
    else return end
  end
end

-- \x.., \u...., \U........, \0.., octal, \1..\99 (a backreference outside a set)
function P:escape(in_set)
  local c = self:next()
  if c == nil then perr("bad escape (end of pattern)", self.pat) end
  local ch = utf8.char(c)
  if SPECIAL_ESC[ch] then return {t = "char", c = SPECIAL_ESC[ch]} end
  if ch == "b" and in_set then return {t = "char", c = 8} end
  local function hex(n)
    local s = ""
    for _ = 1, n do
      local d = self:next()
      if not d or not utf8.char(d):match("%x") then perr("bad hex escape", self.pat) end
      s = s .. utf8.char(d)
    end
    return tonumber(s, 16)
  end
  if ch == "x" then return {t = "char", c = hex(2)} end
  if ch == "u" then return {t = "char", c = hex(4)} end
  if ch == "U" then return {t = "char", c = hex(8)} end
  if ch == "N" then perr("\\N{...} is not supported", self.pat) end
  if ch == "0" then
    local v = 0
    for _ = 1, 2 do
      local d = self:peek()
      if d and d >= 48 and d <= 55 then v = v * 8 + d - 48 self.i = self.i + 1 else break end
    end
    return {t = "char", c = v}
  end
  if c >= 49 and c <= 57 then                         -- \1.. : octal with three digits, else a group
    local d2, d3 = self:peek(), self:peek(1)
    if d2 and d3 and c <= 55 and d2 >= 48 and d2 <= 55 and d3 >= 48 and d3 <= 55 then
      self.i = self.i + 2
      return {t = "char", c = (c - 48) * 64 + (d2 - 48) * 8 + (d3 - 48)}
    end
    if in_set then perr("bad escape \\" .. ch .. " in a set", self.pat) end
    local n = c - 48
    if d2 and d2 >= 48 and d2 <= 57 then n = n * 10 + d2 - 48 self.i = self.i + 1 end
    return {t = "backref", n = n}
  end
  local lower = ch:lower()
  if CLASS[lower] then return {t = "class", f = CLASS[lower], neg = ch ~= lower} end
  if not in_set then
    if ch == "A" then return {t = "begin"} end
    if ch == "Z" then return {t = "end"} end
    if ch == "b" then return {t = "wordb"} end
    if ch == "B" then return {t = "nwordb"} end
  end
  if ch:match("[%a%d]") then perr("bad escape \\" .. ch, self.pat) end
  return {t = "char", c = c}
end

function P:set()
  local node = {t = "set", items = {}, neg = false}
  if self:eat(94) then node.neg = true end
  local first = true
  while true do
    local c = self:peek()
    if c == nil then perr("unterminated character set", self.pat) end
    if c == 93 and not first then self.i = self.i + 1 break end
    first = false
    local lo
    if c == 92 then
      self.i = self.i + 1
      lo = self:escape(true)
    else
      self.i = self.i + 1
      lo = {t = "char", c = c}
    end
    if lo.t == "char" and self:peek() == 45 and self:peek(1) and self:peek(1) ~= 93 then   -- a range a-b
      self.i = self.i + 1
      local hc = self:next()
      local hi
      if hc == 92 then hi = self:escape(true) else hi = {t = "char", c = hc} end
      if hi.t ~= "char" then perr("bad character range", self.pat) end
      if hi.c < lo.c then perr("bad character range", self.pat) end
      node.items[#node.items + 1] = {lo.c, hi.c}
    elseif lo.t == "char" then
      node.items[#node.items + 1] = {lo.c, lo.c}
    else
      node.items[#node.items + 1] = lo                -- a class (\d \w \s and their negations)
    end
  end
  return node
end

local FLAG_LETTERS = {i = R.I, m = R.M, s = R.S, x = R.X, a = R.A, u = R.U, L = R.L}

function P:group_or_ext()
  -- after '(': a group, or (?...)
  if not self:eat(63) then                            -- '?'
    self.ngroups = self.ngroups + 1
    local idx = self.ngroups
    local inner = self:alt()
    if not self:eat(41) then perr("missing ), unterminated subpattern", self.pat) end
    return {t = "group", n = idx, node = inner}
  end
  local c = self:next()
  local ch = c and utf8.char(c)
  if ch == ":" then
    local inner = self:alt()
    if not self:eat(41) then perr("missing )", self.pat) end
    return inner
  elseif ch == "P" then
    local k = self:next()
    if k == 60 then                                   -- (?P<name>...)
      local name = {}
      while self:peek() and self:peek() ~= 62 do name[#name + 1] = self:next() end
      self.i = self.i + 1
      name = utf8.char(table.unpack(name))
      self.ngroups = self.ngroups + 1
      local idx = self.ngroups
      self.names[name] = idx
      self.gnames[idx] = name
      local inner = self:alt()
      if not self:eat(41) then perr("missing )", self.pat) end
      return {t = "group", n = idx, node = inner}
    elseif k == 61 then                               -- (?P=name)
      local name = {}
      while self:peek() and self:peek() ~= 41 do name[#name + 1] = self:next() end
      self.i = self.i + 1
      name = utf8.char(table.unpack(name))
      if not self.names[name] then perr("unknown group name " .. name, self.pat) end
      return {t = "backref", n = self.names[name]}
    end
    perr("unknown extension ?P", self.pat)
  elseif ch == "=" or ch == "!" then
    local inner = self:alt()
    if not self:eat(41) then perr("missing )", self.pat) end
    return {t = "look", behind = false, neg = ch == "!", node = inner}
  elseif ch == "<" then
    local k = self:next()
    if k == 61 or k == 33 then
      local inner = self:alt()
      if not self:eat(41) then perr("missing )", self.pat) end
      local w = R._width(inner)
      if not w then perr("look-behind requires fixed-width pattern", self.pat) end
      return {t = "look", behind = true, neg = k == 33, node = inner, width = w}
    end
    -- (?<name>...) (Python 3.12+ allows it too? no: only (?P<name>); sre raises)
    perr("unknown extension ?<", self.pat)
  elseif ch == "#" then
    while self:peek() and self:peek() ~= 41 do self.i = self.i + 1 end
    self.i = self.i + 1
    return {t = "empty"}
  elseif ch == ">" then
    local inner = self:alt()
    if not self:eat(41) then perr("missing )", self.pat) end
    return {t = "atomic", node = inner}
  elseif ch == "(" then
    perr("conditional groups are not supported", self.pat)
  else
    -- flags: (?aiLmsux) for the whole pattern (only at the start), (?flags-flags:...) for a part
    self.i = self.i - 1
    local on, off, minus = 0, 0, false
    while true do
      local f = self:next()
      if f == nil then perr("missing -, : or )", self.pat) end
      local fc = utf8.char(f)
      if fc == ")" then
        if minus then perr("missing :", self.pat) end
        if not self.at_start then perr("global flags not at the start of the expression", self.pat) end
        self.flags = self.flags | on
        return {t = "empty", global = on}
      elseif fc == ":" then
        local saved = self.flags
        self.flags = (self.flags | on) & ~off
        local inner = self:alt()
        self.flags = saved
        if not self:eat(41) then perr("missing )", self.pat) end
        return inner
      elseif fc == "-" then
        minus = true
      elseif FLAG_LETTERS[fc] then
        if minus then off = off | FLAG_LETTERS[fc] else on = on | FLAG_LETTERS[fc] end
      else
        perr("unknown flag", self.pat)
      end
    end
  end
end

function P:atom()
  self:verbose_skip()
  local c = self:peek()
  if c == nil then return nil end
  local f = self.flags
  if c == 124 or c == 41 then return nil end          -- '|' ')'
  local start = self.i
  self.i = self.i + 1
  local node
  if c == 40 then
    self.at_start = start == 1
    node = self:group_or_ext()                        -- (its parts carry the flags of where they stand)
    self.at_start = false
    return node
  elseif c == 91 then node = self:set()
  elseif c == 46 then node = {t = "any"}
  elseif c == 94 then node = {t = "bol"}
  elseif c == 36 then node = {t = "eol"}
  elseif c == 92 then node = self:escape(false)
  elseif c == 42 or c == 43 or c == 63 then perr("nothing to repeat", self.pat)
  elseif c == 123 and self:counted_ahead() then perr("nothing to repeat", self.pat)
  else node = {t = "char", c = c} end
  -- the flags in force where it stands
  node.ic = f & R.I ~= 0
  node.dotall = f & R.S ~= 0
  node.multi = f & R.M ~= 0
  node.ascii = f & R.A ~= 0
  return node
end

-- is a {m,n} here (else '{' is a plain character, as in sre)?
function P:counted_ahead()
  local k = self.i
  local s = {}
  while self.cps[k] and self.cps[k] ~= 125 do s[#s + 1] = utf8.char(self.cps[k]) k = k + 1 end
  if not self.cps[k] then return false end
  s = table.concat(s)
  return s ~= "" and s:match("^%d*,?%d*$") ~= nil       -- (sre_parse: "{}" is a character, "{,}" a repeat)
end

function P:quantified()
  local node = self:atom()
  if node == nil then return nil end
  while true do
    self:verbose_skip()
    local c = self:peek()
    local min, max
    if c == 42 then min, max = 0, math.huge self.i = self.i + 1
    elseif c == 43 then min, max = 1, math.huge self.i = self.i + 1
    elseif c == 63 then min, max = 0, 1 self.i = self.i + 1
    elseif c == 123 then
      local k = self.i + 1
      local s = {}
      while self.cps[k] and self.cps[k] ~= 125 do s[#s + 1] = utf8.char(self.cps[k]) k = k + 1 end
      s = table.concat(s)
      local a, comma, b = s:match("^(%d*)(,?)(%d*)$")
      if not self.cps[k] or not a or s == "" then
        return node                                   -- not a repeat: '{' stays a character (read next)
      end
      self.i = k + 1
      min = a ~= "" and tonumber(a) or 0
      max = comma == "" and min or (b ~= "" and tonumber(b) or math.huge)
      if max < min then perr("min repeat greater than max repeat", self.pat) end
    else
      return node
    end
    if node.t == "bol" or node.t == "eol" or node.t == "begin" or node.t == "end" or node.t == "wordb" or
       node.t == "nwordb" or node.t == "look" then
      if node.t ~= "look" then perr("nothing to repeat", self.pat) end
    end
    if node.t == "rep" and not node.wrapped then perr("multiple repeat", self.pat) end
    local greedy, possessive = true, false
    if self:eat(63) then greedy = false elseif self:eat(43) then possessive = true end
    node = {t = "rep", min = min, max = max, greedy = greedy, node = node}
    if possessive then node = {t = "atomic", node = node, wrapped = true} end
  end
end

function P:seq()
  local items = {}
  while true do
    local n = self:quantified()
    if n == nil then break end
    if n.t ~= "empty" then items[#items + 1] = n end
  end
  if #items == 1 then return items[1] end
  return {t = "seq", items = items}
end

function P:alt()
  local alts = {self:seq()}
  while self:eat(124) do alts[#alts + 1] = self:seq() end
  if #alts == 1 then return alts[1] end
  return {t = "alt", items = alts}
end

-- a fixed width or nil (look-behind)
function R._width(n)
  local t = n.t
  if t == "char" or t == "any" or t == "set" or t == "class" then return 1 end
  if t == "seq" then
    local w = 0
    for _, x in ipairs(n.items) do
      local k = R._width(x)
      if not k then return nil end
      w = w + k
    end
    return w
  end
  if t == "alt" then
    local w
    for _, x in ipairs(n.items) do
      local k = R._width(x)
      if not k or (w and k ~= w) then return nil end
      w = k
    end
    return w
  end
  if t == "group" or t == "atomic" then return R._width(n.node) end
  if t == "rep" then
    local k = R._width(n.node)
    if not k or n.min ~= n.max then return nil end
    return k * n.min
  end
  if t == "bol" or t == "eol" or t == "begin" or t == "end" or t == "wordb" or t == "nwordb" or t == "look" or
     t == "empty" then return 0 end
  return nil
end

-- --- the matcher: each node becomes m(i, k) -> the end the continuation k gave, or false ---
-- st: {s = cps, n = #cps, caps = {}} for the match being tried; positions are 1-based (Python's index + 1)
local function char_test_raw(node)
  local t = node.t
  local ic, ascii = node.ic, node.ascii
  if t == "char" then
    local c = node.c
    if ic then
      local lc = ascii and (c >= 65 and c <= 90 and c + 32 or c) or low1(c)
      local extra = not ascii and U.EXTRA_CASES[lc] or nil
      return function(x)
        local lx = ascii and (x >= 65 and x <= 90 and x + 32 or x) or low1(x)
        if lx == lc then return true end
        if extra then for _, e in ipairs(extra) do if lx == e then return true end end end
        return false
      end
    end
    return function(x) return x == c end
  elseif t == "any" then
    if node.dotall then return function() return true end end
    return function(x) return x ~= 10 end
  elseif t == "class" then
    local f, neg = node.f, node.neg
    return function(x) return f(x, ascii) ~= neg end
  elseif t == "set" then
    local items, neg = node.items, node.neg
    local function has(x)
      for _, it in ipairs(items) do
        if it.t then
          if it.f(x, ascii) ~= it.neg then return true end
        elseif x >= it[1] and x <= it[2] then
          return true
        end
      end
      return false
    end
    if ic then
      return function(x)
        local ok = has(x)
        if not ok then
          local lx = ascii and (x >= 65 and x <= 90 and x + 32 or x) or low1(x)
          ok = has(lx)
          if not ok then
            -- the upper case ones that lower to it (sre puts the set's characters lowered in, and their cases)
            for _, it in ipairs(items) do
              if not it.t then
                for y = it[1], math.min(it[2], it[1] + 400) do
                  local ly = ascii and (y >= 65 and y <= 90 and y + 32 or y) or low1(y)
                  if ly == lx then ok = true break end
                end
                if ok then break end
              end
            end
          end
          if not ok and not ascii and U.EXTRA_CASES[lx] then
            for _, e in ipairs(U.EXTRA_CASES[lx]) do if has(e) then ok = true break end end
          end
        end
        return ok ~= neg
      end
    end
    return function(x) return has(x) ~= neg end
  end
end

-- the test with ASCII looked up in a table made once (the paths are ASCII: most tests are)
local function char_test(node)
  local raw = char_test_raw(node)
  local t = {}
  for c = 0, 127 do t[c] = raw(c) and true or false end
  return function(x)
    if x < 128 then return t[x] end
    return raw(x)
  end
end

-- the test a part's first character must pass, when only that character decides (nil: something else may)
local function char_first(node)
  local t = node.t
  if t == "char" or t == "any" or t == "class" or t == "set" then return char_test(node) end
  if t == "group" or t == "atomic" then return char_first(node.node) end
  if t == "rep" then return node.min >= 1 and char_first(node.node) or nil end
  if t == "seq" then return node.items[1] and char_first(node.items[1]) or nil end
  if t == "alt" then
    local tests = {}
    for k, x in ipairs(node.items) do
      tests[k] = char_first(x)
      if not tests[k] then return nil end
    end
    return function(c)
      for _, f in ipairs(tests) do if f(c) then return true end end
      return false
    end
  end
  return nil
end

local compile_node

local function word_at(st, i, ascii) local c = st.s[i] return c ~= nil and is_word(c, ascii) end

compile_node = function(node, nxt)
  -- nxt(i) is what follows; returns m(i) -> end or false
  local t = node.t
  if t == "char" or t == "any" or t == "class" or t == "set" then
    local test = char_test(node)
    return function(st, i)
      local c = st.s[i]
      if c ~= nil and i <= st.n and test(c) then return nxt(st, i + 1) end
      return false
    end
  elseif t == "seq" then
    -- runs of plain characters (no IGNORECASE) compared in one loop
    local items, k = node.items, #node.items
    local m = nxt
    while k >= 1 do
      local x = items[k]
      if x.t == "char" and not x.ic then
        local j = k
        while j > 1 and items[j - 1].t == "char" and not items[j - 1].ic do j = j - 1 end
        if k - j >= 1 then
          local lit = {}
          for q = j, k do lit[#lit + 1] = items[q].c end
          local len, after = #lit, m
          m = function(st, i)
            if i + len - 1 > st.n then return false end
            local s = st.s
            for q = 1, len do if s[i + q - 1] ~= lit[q] then return false end end
            return after(st, i + len)
          end
          k = j - 1
        else
          m = compile_node(x, m)
          k = k - 1
        end
      else
        m = compile_node(x, m)
        k = k - 1
      end
    end
    return m
  elseif t == "alt" then
    -- per ASCII character the alternatives that can begin with it, in their order (the others would fail there)
    local ms, tests = {}, {}
    for k, x in ipairs(node.items) do ms[k] = compile_node(x, nxt) tests[k] = char_first(x) end
    local lists, at_end = {}, {}
    for c = 0, 127 do
      local l = {}
      for k = 1, #ms do if not tests[k] or tests[k](c) then l[#l + 1] = ms[k] end end
      lists[c] = l
    end
    for k = 1, #ms do if not tests[k] then at_end[#at_end + 1] = ms[k] end end
    return function(st, i)
      local c = i <= st.n and st.s[i] or nil
      local list = c == nil and at_end or (c < 128 and lists[c] or ms)
      for k = 1, #list do
        local r = list[k](st, i)
        if r then return r end
      end
      return false
    end
  elseif t == "empty" then
    return nxt
  elseif t == "group" then
    local n = node.n
    local close = function(st, i)
      local caps = st.caps
      local os, oe = caps[2 * n - 1], caps[2 * n]
      caps[2 * n - 1], caps[2 * n] = st.open[n], i
      local r = nxt(st, i)
      if not r then caps[2 * n - 1], caps[2 * n] = os, oe end
      return r
    end
    local inner = compile_node(node.node, close)
    return function(st, i)
      local was = st.open[n]
      st.open[n] = i
      local r = inner(st, i)
      if not r then st.open[n] = was end
      return r
    end
  elseif t == "backref" then
    local n, ic = node.n, node.ic
    return function(st, i)
      local a, b = st.caps[2 * n - 1], st.caps[2 * n]
      if not a then return false end
      local len = b - a
      if i + len - 1 > st.n then return false end
      for k = 0, len - 1 do
        local x, y = st.s[a + k], st.s[i + k]
        if x ~= y and not (ic and low1(x) == low1(y)) then return false end
      end
      return nxt(st, i + len)
    end
  elseif t == "bol" then
    if node.multi then
      return function(st, i) if i == 1 or st.s[i - 1] == 10 then return nxt(st, i) end return false end
    end
    return function(st, i) if i == 1 then return nxt(st, i) end return false end
  elseif t == "eol" then
    if node.multi then
      return function(st, i) if i == st.n + 1 or st.s[i] == 10 then return nxt(st, i) end return false end
    end
    return function(st, i)
      if i == st.n + 1 or (i == st.n and st.s[i] == 10) then return nxt(st, i) end
      return false
    end
  elseif t == "begin" then
    return function(st, i) if i == 1 then return nxt(st, i) end return false end
  elseif t == "end" then
    return function(st, i) if i == st.n + 1 then return nxt(st, i) end return false end
  elseif t == "wordb" or t == "nwordb" then
    local want, ascii = t == "wordb", node.ascii
    return function(st, i)
      if st.n == 0 then                               -- (an empty string:  never, \B always - Python 3.14)
        if want then return false end
        return nxt(st, i)
      end
      local b = (i > 1 and word_at(st, i - 1, ascii)) ~= (i <= st.n and word_at(st, i, ascii))
      if b == want then return nxt(st, i) end
      return false
    end
  elseif t == "look" then
    local inner = compile_node(node.node, function(_, j) return j end)
    local neg, behind, width = node.neg, node.behind, node.width
    return function(st, i)
      local ok
      if behind then
        local from = i - width
        ok = from >= 1 and inner(st, from) == i         -- (fixed width: every way through ends at i)
      else
        ok = inner(st, i) and true or false
      end
      if ok ~= neg then return nxt(st, i) end
      return false
    end
  elseif t == "atomic" then
    local inner = compile_node(node.node, function(_, j) return j end)
    return function(st, i)
      local j = inner(st, i)
      if not j then return false end
      return nxt(st, j)
    end
  elseif t == "rep" then
    local min, max, greedy, sub = node.min, node.max, node.greedy, node.node
    local st_t = sub.t
    if st_t == "char" or st_t == "any" or st_t == "class" or st_t == "set" then
      -- one character a time: count how far it goes, then try the rest from there (no recursion)
      local test = char_test(sub)
      if greedy then
        return function(st, i)
          local s, n = st.s, st.n
          local j = i
          while j - i < max and j <= n and test(s[j]) do j = j + 1 end
          while j - i >= min do
            local r = nxt(st, j)
            if r then return r end
            j = j - 1
          end
          return false
        end
      end
      return function(st, i)
        local s, n = st.s, st.n
        local j = i
        while j - i < min do
          if j > n or not test(s[j]) then return false end
          j = j + 1
        end
        while true do
          local r = nxt(st, j)
          if r then return r end
          if j - i >= max or j > n or not test(s[j]) then return false end
          j = j + 1
        end
      end
    end
    -- any part, as sre's MAX_UNTIL / MIN_UNTIL: below the minimum it goes on (empty or not); then, greedy, another
    -- pass unless the last one was empty, else the rest; lazy the rest first. The pass under way is a frame
    -- {count before it, its start} on this repeat's stack in st.rep (a repeat inside itself pushes its own)
    local key = {}
    local body, attempt
    local function tail(st, i) return nxt(st, i) end
    local function run_body(st, i, cnt)
      local stack = st.rep[key]
      if not stack then stack = {} st.rep[key] = stack end
      stack[#stack + 1] = {cnt, i}
      local r = body(st, i)
      stack[#stack] = nil
      return r
    end
    attempt = function(st, i, cnt, last)
      if cnt < min then return run_body(st, i, cnt) end
      if greedy then
        if cnt < max and i ~= last then
          local r = run_body(st, i, cnt)
          if r then return r end
        end
        return tail(st, i)
      end
      local r = tail(st, i)
      if r then return r end
      if cnt >= max or i == last then return false end
      return run_body(st, i, cnt)
    end
    body = compile_node(sub, function(st, j)
      local stack = st.rep[key]
      local fr = stack[#stack]
      stack[#stack] = nil                           -- (the pass is done: what follows sees the frame below)
      local r = attempt(st, j, fr[1] + 1, fr[2])
      stack[#stack + 1] = fr
      return r
    end)
    return function(st, i) return attempt(st, i, 0, nil) end
  end
  error("pyre: no matcher for " .. tostring(t))
end

-- what a match's first character must be, when the pattern says so (nil: anything, or nothing at all)
-- (f(c, i): c the character at i; ^ and \A without MULTILINE only at the start)
local function first_test(node)
  local t = node.t
  if t == "char" or t == "any" or t == "class" or t == "set" then
    local f = char_test(node)
    return function(c) return c ~= nil and f(c) end
  end
  if (t == "bol" and not node.multi) or t == "begin" then return function(_, i) return i == 1 end end
  if t == "group" or t == "atomic" then return first_test(node.node) end
  if t == "rep" then return node.min >= 1 and first_test(node.node) or nil end
  if t == "seq" then return node.items[1] and first_test(node.items[1]) or nil end
  if t == "alt" then
    -- the ones a character decides: looked up for ASCII; the others (^) asked with the place
    local chars, others = {}, {}
    for _, x in ipairs(node.items) do
      local cf = char_first(x)
      if cf then
        chars[#chars + 1] = cf
      else
        local f = first_test(x)
        if not f then return nil end
        others[#others + 1] = f
      end
    end
    local ascii = {}
    for c = 0, 127 do
      ascii[c] = false
      for _, f in ipairs(chars) do if f(c) then ascii[c] = true break end end
    end
    return function(c, i)
      if c ~= nil then
        if c < 128 then
          if ascii[c] then return true end
        else
          for _, f in ipairs(chars) do if f(c) then return true end end
        end
      end
      for _, f in ipairs(others) do if f(c, i) then return true end end
      return false
    end
  end
  return nil
end
-- look-arounds and atomic groups may leave groups set after a failed try
local function keeps_groups(node)
  if node.t == "look" or node.t == "atomic" then return true end
  for _, x in ipairs(node.items or {}) do if keeps_groups(x) then return true end end
  return node.node ~= nil and keeps_groups(node.node)
end

-- --- compiled patterns ---
local Pattern = {}
Pattern.__index = Pattern
local cache = {}

function R.compile(pat, flags)
  if type(pat) == "table" and getmetatable(pat) == Pattern then return pat end
  flags = flags or 0
  local key = flags .. "\0" .. pat
  if cache[key] then return cache[key] end
  local p = parser(pat, flags)
  p.at_start = true
  -- global flags anywhere at the top must come first; a first pass finds (?flags) at the very start
  if p.cps[1] == 40 and p.cps[2] == 63 then
    local k = 3
    local on = 0
    while p.cps[k] and FLAG_LETTERS[utf8.char(p.cps[k])] do on = on | FLAG_LETTERS[utf8.char(p.cps[k])] k = k + 1 end
    if p.cps[k] == 41 then p.flags = p.flags | on end
  end
  local tree = p:alt()
  if p.i <= #p.cps then
    if p.cps[p.i] == 41 then perr("unbalanced parenthesis", pat) end
    perr("unexpected end", pat)
  end
  -- three ways to end: anywhere; further than st.floor (sre's must_advance after an empty match); exactly at
  -- st.want (fullmatch)
  local done = function(_, i) return i end
  local more = function(st, i) if i > st.floor then return i end return false end
  local exact = function(st, i) if i == st.want then return i end return false end
  local obj = setmetatable({pattern = pat, flags = p.flags, groups = p.ngroups, groupindex = p.names,
                            gnames = p.gnames, m = compile_node(tree, done), m_more = compile_node(tree, more),
                            m_full = compile_node(tree, exact), first = first_test(tree),
                            keeps = keeps_groups(tree)}, Pattern)
  cache[key] = obj
  return obj
end

local Match = {}
Match.__index = Match

local last_s, last_cps
local function cps_of(s)
  if s ~= last_s then
    last_s, last_cps = s, S.cps(s)
    last_cps.str, last_cps.ascii = s, #s == #last_cps
  end
  return last_cps
end
-- characters a..b of the string (an ASCII one: cut, else made from its code points)
local function slice(cps, a, b)
  if cps.ascii then return cps.str:sub(a, b) end
  return S.from_cps(cps, a, b)
end

-- one try at i: the match's end or nil, the groups in st.caps
-- (an empty match where the last one ended: sre wants one that goes further from there)
-- (a failed try leaves the groups as it found them - each part undoes what it set - unless a look-around or an
-- atomic group kept some: then they start anew)
local function try_at(self, st, i, must_advance)
  if self.keeps then st.caps, st.open, st.rep = {}, {}, {} end
  if must_advance then
    st.floor = i
    return self.m_more(st, i) or nil
  end
  return self.m(st, i) or nil
end

local function new_match(self, s, cps, st, a, e, pos, endpos)
  local m = setmetatable({string = s, re = self, pos = pos - 1, endpos = endpos - 1, _cps = cps, _a = a, _e = e,
                          _caps = st.caps}, Match)
  local last, lastn = nil, nil
  for g = 1, self.groups do
    if st.caps[2 * g] and (lastn == nil or st.caps[2 * g] >= lastn) then last, lastn = g, st.caps[2 * g] end
  end
  m.lastindex = last
  m.lastgroup = last and self.gnames[last] or nil
  return m
end

-- search from pos (0-based) to endpos: the first match
local function run(self, s, pos, endpos, mode, must_advance_at, have_cps)
  local cps = have_cps or cps_of(s)
  local n = #cps
  pos = pos or 0
  endpos = endpos or n
  if pos < 0 then pos = 0 end
  if endpos > n then endpos = n end
  if pos > endpos then return nil end
  local st = {s = cps, n = endpos, caps = {}, open = {}, rep = {}}
  local i0 = pos + 1
  if mode == "match" or mode == "full" then
    if mode == "full" then
      st.caps, st.open, st.rep, st.want = {}, {}, {}, endpos + 1
      local e = self.m_full(st, i0)
      if e then return new_match(self, s, cps, st, i0, e, i0, endpos + 1) end
      return nil
    end
    local e = try_at(self, st, i0, must_advance_at == i0)
    if e then return new_match(self, s, cps, st, i0, e, i0, endpos + 1) end
    return nil
  end
  local first = self.first
  for i = i0, endpos + 1 do
    -- (a match has to begin with a character the pattern's first part takes: elsewhere no try)
    if not first or first(i <= endpos and cps[i] or nil, i) then
      local e = try_at(self, st, i, must_advance_at == i)
      if e then return new_match(self, s, cps, st, i, e, i0, endpos + 1) end
    end
  end
  return nil
end

function Pattern:search(s, pos, endpos) return run(self, s, pos, endpos, "search") end
function Pattern:match(s, pos, endpos) return run(self, s, pos, endpos, "match") end
function Pattern:fullmatch(s, pos, endpos) return run(self, s, pos, endpos, "full") end

-- every match, as sre's finditer: after an empty match the next must not be empty at the same place
function Pattern:finditer(s, pos, endpos)
  local cps = cps_of(s)
  local at = pos or 0
  local stop = endpos or #cps
  local must
  local s_ = s
  return function()
    if at > stop then return nil end
    -- (its own code points: cps_of keeps only the last string's - 25.10., the asset build's item files were
    -- decoded again for each item, the attributes searched between)
    local m = run(self, s_, at, stop, "search", must, cps)
    if not m then at = stop + 1 return nil end
    local a, e = m._a - 1, m._e - 1
    must = (e == a) and (e + 1) or nil                -- (1-based: the place the next one must leave)
    at = e
    return m
  end
end

local function group_text(m, g)
  if g == 0 then return slice(m._cps, m._a, m._e - 1) end
  local a, e = m._caps[2 * g - 1], m._caps[2 * g]
  if not a then return nil end
  return slice(m._cps, a, e - 1)
end

-- every match as finditer finds them, without match objects: cb(a, e, caps, cps) per match (1-based, e past its
-- end); cb returns true to stop. One state for them all (findall, sub and split go through here)
local function each(self, s, pos, endpos, cb)
  local cps = cps_of(s)
  local n = #cps
  pos, endpos = pos or 0, endpos or n
  if pos < 0 then pos = 0 end
  if endpos > n then endpos = n end
  local st = {s = cps, n = endpos, caps = {}, open = {}, rep = {}}
  local first, keeps, m, m_more = self.first, self.keeps, self.m, self.m_more
  local i, must = pos + 1, nil
  while i <= endpos + 1 do
    local a, e
    for j = i, endpos + 1 do
      if not first or first(j <= endpos and cps[j] or nil, j) then
        if keeps then st.caps, st.open, st.rep = {}, {}, {} end
        if must == j then
          st.floor = j
          e = m_more(st, j)
        else
          e = m(st, j)
        end
        if e then a = j break end
      end
    end
    if not a then return end
    if cb(a, e, st.caps, cps) then return end
    st.caps = {}
    must = (e == a) and e or nil                      -- (after an empty match: the next must leave its place)
    i = e
  end
end

local function cap_text(cps, caps, g)
  local a, e = caps[2 * g - 1], caps[2 * g]
  if not a then return nil end
  return slice(cps, a, e - 1)
end

function Pattern:findall(s, pos, endpos)
  local out, groups = {}, self.groups
  each(self, s, pos, endpos, function(a, e, caps, cps)
    if groups == 0 then
      out[#out + 1] = slice(cps, a, e - 1)
    elseif groups == 1 then
      out[#out + 1] = cap_text(cps, caps, 1) or ""
    else
      local t = {}
      for g = 1, groups do t[g] = cap_text(cps, caps, g) or "" end
      out[#out + 1] = t
    end
  end)
  return out
end

-- the replacement template (sre_parse.parse_template): \1..\99, \g<n>, \g<name>, escapes
local function template(self, repl)
  local parts = {}
  local cps = S.cps(repl)
  local i, lit = 1, {}
  local function flush() if #lit > 0 then parts[#parts + 1] = S.from_cps(lit) lit = {} end end
  while i <= #cps do
    local c = cps[i]
    if c == 92 then
      local d = cps[i + 1]
      if d == nil then error("pyre: bad escape (end of pattern) in the replacement", 3) end
      local ch = utf8.char(d)
      if ch == "g" then
        local k = i + 2
        if cps[k] ~= 60 then error("pyre: missing < in the replacement", 3) end
        local name = {}
        k = k + 1
        while cps[k] and cps[k] ~= 62 do name[#name + 1] = cps[k] k = k + 1 end
        name = S.from_cps(name)
        local g = tonumber(name) or self.groupindex[name]
        if not g or g > self.groups then error("pyre: invalid group reference " .. name, 3) end
        flush()
        parts[#parts + 1] = g
        i = k + 1
      elseif d >= 48 and d <= 57 then
        local e = cps[i + 2]
        if d == 48 or (e and e >= 48 and e <= 55 and d <= 55 and cps[i + 3] and cps[i + 3] >= 48 and cps[i + 3] <= 55) then
          -- octal
          local v, k = 0, i + 1
          for _ = 1, 3 do
            if cps[k] and cps[k] >= 48 and cps[k] <= 55 then v = v * 8 + cps[k] - 48 k = k + 1 else break end
          end
          lit[#lit + 1] = v
          i = k
        else
          local g = d - 48
          local k = i + 2
          if e and e >= 48 and e <= 57 then g = g * 10 + e - 48 k = k + 1 end
          if g > self.groups then error("pyre: invalid group reference " .. g, 3) end
          flush()
          parts[#parts + 1] = g
          i = k
        end
      elseif SPECIAL_ESC[ch] or ch == "b" then
        lit[#lit + 1] = ch == "b" and 8 or SPECIAL_ESC[ch]
        i = i + 2
      elseif ch:match("%a") then
        error("pyre: bad escape \\" .. ch .. " in the replacement", 3)
      else
        lit[#lit + 1] = 92
        lit[#lit + 1] = d
        i = i + 2
      end
    else
      lit[#lit + 1] = c
      i = i + 1
    end
  end
  flush()
  return parts
end

function Pattern:subn(repl, s, count)
  count = count or 0
  local fn = repl
  local out, last, n = {}, 1, 0
  local all
  if type(repl) == "function" then                    -- (the function gets a match object)
    all = cps_of(s)
    for m in self:finditer(s) do
      out[#out + 1] = slice(all, last, m._a - 1)
      out[#out + 1] = fn(m)
      last = m._e
      n = n + 1
      if count > 0 and n >= count then break end
    end
  else
    local parts = template(self, repl)
    each(self, s, nil, nil, function(a, e, caps, cps)
      all = cps
      out[#out + 1] = slice(cps, last, a - 1)
      for _, p in ipairs(parts) do
        if p == 0 then out[#out + 1] = slice(cps, a, e - 1)
        elseif type(p) == "number" then out[#out + 1] = cap_text(cps, caps, p) or ""
        else out[#out + 1] = p end
      end
      last = e
      n = n + 1
      return count > 0 and n >= count
    end)
    all = all or cps_of(s)
  end
  out[#out + 1] = slice(all, last, #all)
  return table.concat(out), n
end
function Pattern:sub(repl, s, count) return (self:subn(repl, s, count)) end

-- str split by the pattern: the groups in between (a group that took no part: Y.null, Python's None)
function Pattern:split(s, maxsplit)
  maxsplit = maxsplit or 0
  local null = require("conjunction.yaml").null
  local out, last, n, groups = {}, 1, 0, self.groups
  local all
  each(self, s, nil, nil, function(a, e, caps, cps)
    all = cps
    out[#out + 1] = slice(cps, last, a - 1)
    for g = 1, groups do
      local t = cap_text(cps, caps, g)
      if t == nil then out[#out + 1] = null else out[#out + 1] = t end
    end
    last = e
    n = n + 1
    return maxsplit > 0 and n >= maxsplit
  end)
  all = all or cps_of(s)
  out[#out + 1] = slice(all, last, #all)
  return out
end

-- --- matches ---
local function gidx(m, g)
  if g == nil then return 0 end
  if type(g) == "string" then
    local k = m.re.groupindex[g]
    if not k then error("pyre: no such group " .. g, 3) end
    return k
  end
  if g < 0 or g > m.re.groups then error("pyre: no such group " .. tostring(g), 3) end
  return g
end
function Match:group(...)
  local n = select("#", ...)
  if n <= 1 then
    local g = gidx(self, (...))
    if g == 0 then return slice(self._cps, self._a, self._e - 1) end
    return group_text(self, g)
  end
  local out = {}
  for k = 1, n do out[k] = self:group((select(k, ...))) end
  return table.unpack(out, 1, n)
end
function Match:groups(default)
  local out = {}
  for g = 1, self.re.groups do
    local t = group_text(self, g)
    if t == nil then t = default end
    out[g] = t
  end
  return out
end
function Match:groupdict(default)
  local out = {}
  for name, g in pairs(self.re.groupindex) do
    local t = group_text(self, g)
    if t == nil then t = default end
    out[name] = t
  end
  return out
end
function Match:start(g)
  g = gidx(self, g)
  if g == 0 then return self._a - 1 end
  local a = self._caps[2 * g - 1]
  return a and a - 1 or -1
end
function Match:stop(g)
  g = gidx(self, g)
  if g == 0 then return self._e - 1 end
  local e = self._caps[2 * g]
  return e and e - 1 or -1
end
Match["end"] = Match.stop
function Match:span(g) return self:start(g), self:stop(g) end

-- --- the module's functions ---
function R.search(p, s, flags) return R.compile(p, flags):search(s) end
function R.match(p, s, flags) return R.compile(p, flags):match(s) end
function R.fullmatch(p, s, flags) return R.compile(p, flags):fullmatch(s) end
function R.findall(p, s, flags) return R.compile(p, flags):findall(s) end
function R.finditer(p, s, flags) return R.compile(p, flags):finditer(s) end
function R.sub(p, repl, s, count, flags) return R.compile(p, flags):sub(repl, s, count) end
function R.subn(p, repl, s, count, flags) return R.compile(p, flags):subn(repl, s, count) end
function R.split(p, s, maxsplit, flags) return R.compile(p, flags):split(s, maxsplit) end
-- re.escape (3.7+): only the characters special in a pattern
local SPECIAL = {}
for ch in ("()[]{}?*+-|^$\\.&~# \t\n\r\v\f"):gmatch(".") do SPECIAL[ch:byte()] = true end
function R.escape(s)
  local out = {}
  for _, c in utf8.codes(s) do
    if SPECIAL[c] then out[#out + 1] = "\\" end
    out[#out + 1] = utf8.char(c)
  end
  return table.concat(out)
end
function R.purge() cache = {} end

return R
