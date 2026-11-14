-- Every quest carries the runtime's functions it calls (scriptlib.py): the build names each runtime function the
-- quest's files call after the quest (CjGive -> CjGive_<quest id>) and writes those functions, with everything they
-- call, as the quest's own script (Mods\moddlc<id>\content\scripts\local). Of the item tables (every item of the game
-- as text -> its name) only the items the quest names come along. What only the runtime can do (anything that adds to
-- the game's classes: @wrapMethod, @addMethod, @addField) a quest can not carry: a quest that calls it is refused.
--   SL.quest_script(qid, texts) -> script, renames      SL.apply(out, qid, script_dir, log) -> the script's path
local R = require("conjunction.pyre")
local PYS = require("conjunction.pystr")
local PATHS = require("conjunction.paths")
local SL = {}
SL.SCRIPT_NAME = "cj_quest_%s.ws"
SL.ITEM_SCRIPT = "conjunction_items.ws"
SL.TABLES = {"CjItemName", "CjLootName"}
SL.FEATURES = {{"definition.names.yml", "UpdateName"}}   -- people with names of their own (conjunction_names.ws)
local KEYWORDS = {"latent", "quest", "storyscene", "exec", "timer", "private", "public", "protected", "final", "cleanup",
                  "entry"}

local function fs() return w3.fs end
-- str.isspace of one character (the ASCII ones and \x1c-\x1f, as Python's)
local function is_space(c)
  if c == "" then return false end
  local b = c:byte()
  return b == 32 or (b >= 9 and b <= 13) or (b >= 28 and b <= 31)
end
local function sorted_keys(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end
-- a file read as Python's text mode reads it: its BOM (utf-8-sig) off, line ends \n
local function read_text(path, sig)
  local t = fs().read(path)                       -- (w3.fs: a path with letters beyond ASCII too)
  if not t then return nil end
  if sig and t:sub(1, 3) == "\239\187\191" then t = t:sub(4) end
  return (t:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

-- past whitespace and comments (i 1-based)
local function skip_space(s, i)
  while i <= #s do
    if is_space(s:sub(i, i)) then
      i = i + 1
    elseif s:sub(i, i + 1) == "//" then
      local j = s:find("\n", i, true)
      i = j and j + 1 or #s + 1
    elseif s:sub(i, i + 1) == "/*" then
      local j = s:find("*/", i + 2, true)
      i = j and j + 2 or #s + 1
    else
      break
    end
  end
  return i
end

-- from the first '{' at or after i to its matching '}' (strings, names and comments skipped) -> the index after it
local function block_end(s, i)
  i = s:find("{", i, true)
  if not i then error("ValueError: substring not found", 0) end
  local depth = 0
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' or c == "'" then
      local j = i + 1
      while j <= #s and s:sub(j, j) ~= c do j = j + (s:sub(j, j) == "\\" and 2 or 1) end
      i = j + 1
    elseif s:sub(i, i + 1) == "//" then
      local j = s:find("\n", i, true)
      i = j and j + 1 or #s + 1
    elseif s:sub(i, i + 1) == "/*" then
      local j = s:find("*/", i + 2, true)
      i = (j or -1) + 2
    else
      if c == "{" then
        depth = depth + 1
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 then return i + 1 end
      end
      i = i + 1
    end
  end
  error("ValueError: unbalanced braces", 0)
end

-- the app's HEAD.match(text, i) (re.M): at a line's start, whitespace, the modifiers (each followed by whitespace),
-- "function", whitespace, the name -> the modifiers' text, the name, the index after the name; nil
local function head_match(text, i)
  if not (i == 1 or text:sub(i - 1, i - 1) == "\n") then return nil end
  local j = i
  while j <= #text and is_space(text:sub(j, j)) do j = j + 1 end
  local from, k = j, j
  while true do
    local found
    for _, kw in ipairs(KEYWORDS) do
      if text:sub(k, k + #kw - 1) == kw and is_space(text:sub(k + #kw, k + #kw)) then found = kw break end
    end
    if not found then break end
    k = k + #found
    while k <= #text and is_space(text:sub(k, k)) do k = k + 1 end
  end
  local mods = text:sub(from, k - 1)
  if text:sub(k, k + 7) ~= "function" or not is_space(text:sub(k + 8, k + 8)) then return nil end
  local n = k + 8
  while n <= #text and is_space(text:sub(n, n)) do n = n + 1 end
  local name = text:match("^[A-Za-z_][A-Za-z0-9_]*", n)
  if not name then return nil end
  return mods, name, n + #name
end

-- the modifiers name quest or storyscene as a word
local function is_entry(mods)
  for w in mods:gmatch("[A-Za-z0-9_]+") do if w == "quest" or w == "storyscene" then return true end end
  return false
end

-- the name after "var" (a whole word) and whitespace, else ""
local function var_name(s)
  local i = 1
  while true do
    local a, b = s:find("var", i, true)
    if not a then return "" end
    local before = a > 1 and s:sub(a - 1, a - 1) or ""
    if not before:match("[A-Za-z0-9_\128-\255]") then
      local rest = s:sub(b + 1)
      local sp = rest:match("^[ \t\n\r\f\v]+")
      if sp then
        local name = rest:sub(#sp + 1):match("^[A-Za-z_][A-Za-z0-9_]*")
        if name then return name end
      end
    end
    i = a + 1
  end
end

-- the renames as whole words (a letter beyond ASCII belongs to a word, as with Python's \b)
function SL.rename_words(text, renames)
  return (text:gsub("[A-Za-z0-9_\128-\255]+", function(w) return renames[w] end))
end

-- the top-level definitions of a script file -> {{kind, name, text, entry, refs}}
function SL.parse(text)
  local out, i = {}, 1
  while true do
    i = skip_space(text, i)
    if i > #text then return out end
    local start = i
    local annotated = text:sub(i, i) == "@"
    if annotated then
      local close = text:find(")", i, true)
      if not close then error("ValueError: substring not found", 0) end
      i = skip_space(text, close + 1)
    end
    local mods, name, after = head_match(text, i)
    if mods then
      local e = block_end(text, after)
      out[#out + 1] = {kind = annotated and "annotated" or "function", name = name, text = text:sub(start, e - 1),
                       entry = not annotated and is_entry(mods), refs = {}}
      i = e
    else
      local semi = text:find(";", i, true)
      if not semi then error("ValueError: substring not found", 0) end
      out[#out + 1] = {kind = annotated and "annotated" or "other", name = var_name(text:sub(i, semi)),
                       text = text:sub(start, semi), refs = {}}
      i = semi + 1
    end
  end
end

-- --- the item tables: made from this game's catalog (and its packs' items), else the one that comes with Conjunction
local function shipped_names(fn)
  local text = read_text(PATHS.RUNTIME_SCRIPTS .. "\\local\\" .. SL.ITEM_SCRIPT, false)
  if not text then return {} end
  local set = {}
  local pat = R.compile("function " .. fn .. "\\d+\\(s : string\\) : name \\{(.*?)\\n\\}", R.S)
  for _, block in ipairs(pat:findall(text)) do
    for _, n in ipairs(R.findall('if \\(s == "([^"]+)"\\)', block)) do set[n] = true end
  end
  return sorted_keys(set)
end

local function table_of(fn, list)
  local ok = {}
  for _, n in ipairs(list) do if n:match("^[A-Za-z0-9 _]+$") then ok[#ok + 1] = n end end
  local out, chunks = {}, 0
  for k = 1, #ok, 120 do
    out[#out + 1] = string.format("function %s%d(s : string) : name {", fn, chunks)
    for j = k, math.min(#ok, k + 119) do out[#out + 1] = string.format("    if (s == \"%s\") { return '%s'; }", ok[j], ok[j]) end
    out[#out + 1] = "    return '';"
    out[#out + 1] = "}"
    chunks = chunks + 1
  end
  out[#out + 1] = "function " .. fn .. "(s : string) : name {"
  out[#out + 1] = "    var n : name;"
  for k = 0, chunks - 1 do out[#out + 1] = string.format("    n = %s%d(s); if (n != '') { return n; }", fn, k) end
  out[#out + 1] = "    return '';"
  out[#out + 1] = "}"
  return out
end

-- assets.write_item_script: conjunction_items.ws into folder -> its path
function SL.write_item_script(folder)
  local A = require("conjunction.assets")
  local DB = require("conjunction.db")
  local ready = A.ready()
  local set = {}
  if ready then
    local db = DB.open(A.DB, false)
    for _, r in ipairs(db:rows("select name from items")) do set[r[1]] = true end
    db:close()
  else
    for _, n in ipairs(shipped_names("CjItemName")) do set[n] = true end
  end
  local CT = require("conjunction.content")
  local ok, packs = pcall(CT.installed_packs)
  for _, p in ipairs(ok and packs or {}) do
    for _, it in ipairs((CT.pack_index(p) or {}).items or {}) do
      if it.name and it.name ~= "" then set[it.name] = true end
    end
  end
  local out = {"// generated by conjunction from this game's item definitions - an item's name as text -> the item's name"}
  for _, l in ipairs(table_of("CjItemName", sorted_keys(set))) do out[#out + 1] = l end
  out[#out + 1] = ""
  local loot
  if ready then
    loot = {}
    local db = DB.open(A.DB, false)
    for _, r in ipairs(db:rows("select name from loot")) do loot[#loot + 1] = r[1] end
    db:close()
    table.sort(loot)
  else
    loot = shipped_names("CjLootName")
  end
  for _, l in ipairs(table_of("CjLootName", loot)) do out[#out + 1] = l end
  out[#out + 1] = ""
  local path = folder .. "\\" .. SL.ITEM_SCRIPT
  assert(fs().write(path, table.concat(out, "\n")))
  return path
end

-- the runtime's scripts (the plug-ins of today add none: plugins.py add_scripts(..., runtime=True))
function SL.library_dirs()
  local out = {}
  if fs().isdir(PATHS.RUNTIME_SCRIPTS) then out[1] = PATHS.RUNTIME_SCRIPTS end
  return out
end

local function ws_files(dir, out)
  for _, e in ipairs(fs().list(dir) or {}) do
    local p = dir .. "\\" .. e.name
    if e.dir then ws_files(p, out) elseif PYS.lower(e.name):match("%.ws$") then out[#out + 1] = p end
  end
  return out
end

-- {name = block} of every runtime definition, each with the names it uses (refs, a set)
function SL.library(dirs)
  local own = dirs == nil
  local files = {}
  for _, d in ipairs(dirs or SL.library_dirs()) do
    local found = ws_files(d, {})
    table.sort(found)
    for _, f in ipairs(found) do files[#files + 1] = f end
  end
  local tmp
  if own then
    local keep = {}
    for _, f in ipairs(files) do if f:match("([^\\/]*)$") ~= SL.ITEM_SCRIPT then keep[#keep + 1] = f end end
    local A = require("conjunction.assets")
    local CT = require("conjunction.content")
    local packs = false
    pcall(function()
      for _, p in ipairs(CT.installed_packs()) do
        if #((CT.pack_index(p) or {}).items or {}) > 0 then packs = true end
      end
    end)
    if A.ready() or packs then
      tmp = (os.getenv("TEMP") or "C:\\tmp") .. "\\cj_items_" .. require("conjunction.marks").uuid4_hex():sub(1, 8)
      fs().mkdir(tmp)
      keep[#keep + 1] = SL.write_item_script(tmp)
    else
      keep[#keep + 1] = PATHS.RUNTIME_SCRIPTS .. "\\local\\" .. SL.ITEM_SCRIPT
    end
    files = keep
  end
  local blocks, order = {}, {}
  for _, f in ipairs(files) do
    local text = read_text(f, true)
    if text then
      for _, b in ipairs(SL.parse(text)) do
        if b.name ~= "" and blocks[b.name] == nil then
          blocks[b.name] = b
          order[#order + 1] = b.name
          b.order = #order
        end
      end
    end
  end
  if tmp then
    for _, e in ipairs(fs().list(tmp) or {}) do fs().remove(tmp .. "\\" .. e.name) end
    fs().rmdir(tmp)
  end
  for _, name in ipairs(order) do
    local b = blocks[name]
    local at = b.text:find("{", 1, true)
    local body = at and b.text:sub(at) or ""
    local refs = {}
    for w in body:gmatch("[A-Za-z_][A-Za-z0-9_]*") do
      if blocks[w] and w ~= name then refs[w] = true end
    end
    b.refs = refs
  end
  return blocks
end

-- the chain to something only the runtime can do, or nil
local function runtime_only(name, lib, seen)
  seen = seen or {}
  if seen[name] then return nil end
  seen[name] = true
  local b = lib[name]
  if b.kind ~= "function" then return {name} end
  for _, r in ipairs(sorted_keys(b.refs)) do
    local chain = runtime_only(r, lib, seen)
    if chain then
      table.insert(chain, 1, name)
      return chain
    end
  end
  return nil
end

-- the runtime functions the quest's files call (by name; named after the quest already when a build ran before)
function SL.used(texts, lib, sfx)
  local words = {}
  for _, t in ipairs(texts) do for w in t:gmatch("[A-Za-z_][A-Za-z0-9_]*") do words[w] = true end end
  if sfx and sfx ~= "" then
    local more = {}
    for w in pairs(words) do if #w >= #sfx and w:sub(-#sfx) == sfx then more[w:sub(1, #w - #sfx)] = true end end
    for w in pairs(more) do words[w] = true end
  end
  local out = {}
  for n in pairs(words) do if lib[n] and lib[n].kind == "function" then out[#out + 1] = n end end
  table.sort(out)
  return out
end

SL.RUNTIME_ONLY_MT = {__tostring = function(e) return "RuntimeOnly: " .. e.runtime_only end}
-- the functions needed, callers first; an error {runtime_only = chain} when one needs the runtime
function SL.closure(names, lib)
  local out, have, todo = {}, {}, {}
  for _, n in ipairs(names) do todo[#todo + 1] = n end
  while #todo > 0 do
    local n = table.remove(todo, 1)
    if not have[n] then
      local chain = runtime_only(n, lib)
      if chain then error(setmetatable({runtime_only = table.concat(chain, " -> ")}, SL.RUNTIME_ONLY_MT), 0) end
      out[#out + 1] = n
      have[n] = true
      for _, r in ipairs(sorted_keys(lib[n].refs)) do if not have[r] then todo[#todo + 1] = r end end
    end
  end
  return out
end

local function is_table_part(base, name)
  return name:sub(1, #base) == base and name:sub(#base + 1):match("^%d+$") ~= nil
end

-- a table's rows (CjItemName0..n): {{line, its text}}
local function table_rows(base, lib)
  local parts = {}
  for name, b in pairs(lib) do if is_table_part(base, name) then parts[#parts + 1] = b end end
  table.sort(parts, function(a, b) return a.order < b.order end)
  local rows = {}
  for _, b in ipairs(parts) do
    for ln in (b.text .. "\n"):gmatch("([^\n]*)\n") do
      if PYS.strip(ln):sub(1, 9) == "if (s == " then
        local lit = ln:match('"([^"\\]*)"')   -- (the item names have no escapes: [A-Za-z0-9 _])
        if lit then rows[#rows + 1] = {ln, lit} end
      end
    end
  end
  return rows
end

-- CjItemName_<id>(s): only the rows whose text the quest's files hold
local function table_fn(base, lib, texts, sfx)
  local hay = table.concat(texts, "\n")
  local keep = {}
  for _, r in ipairs(table_rows(base, lib)) do
    if hay:find(r[2], 1, true) then keep[#keep + 1] = r[1] .. "\n" end
  end
  return "function " .. base .. sfx .. "(s : string) : name {\n" .. table.concat(keep) .. "    return '';\n}\n"
end

-- the quest's own script and the renames -> script text, {runtime name = the quest's name}
function SL.quest_script(qid, texts, lib, features)
  lib = lib or SL.library()
  features = features or {}
  local sfx = "_" .. qid
  local entries = SL.used(texts, lib, sfx)
  local feats = {}
  for _, f in ipairs(features) do if lib[f] then feats[#feats + 1] = f end end
  if #entries == 0 and #feats == 0 then return "", {} end
  local start = {}
  for _, e in ipairs(entries) do start[#start + 1] = e end
  local fr = {}
  for _, f in ipairs(feats) do for r in pairs(lib[f].refs) do fr[r] = true end end
  for _, r in ipairs(sorted_keys(fr)) do start[#start + 1] = r end
  local need = SL.closure(start, lib)
  local in_need, tables = {}, {}
  for _, n in ipairs(need) do in_need[n] = true end
  for _, t in ipairs(SL.TABLES) do if in_need[t] then tables[#tables + 1] = t end end
  local kept = {}
  for _, n in ipairs(need) do
    local part = false
    for _, t in ipairs(SL.TABLES) do if n == t or is_table_part(t, n) then part = true end end
    if not part then kept[#kept + 1] = n end
  end
  need = kept
  local renames = {}
  for _, n in ipairs(need) do renames[n] = n .. sfx end
  for _, t in ipairs(tables) do renames[t] = t .. sfx end
  local parts = {"// " .. qid .. ": the runtime functions this quest calls, its own copy (built by Conjunction, scriptlib.py)\n"}
  for _, n in ipairs(need) do parts[#parts + 1] = SL.rename_words(lib[n].text, renames) .. "\n" end
  for _, f in ipairs(feats) do parts[#parts + 1] = SL.rename_words(lib[f].text, renames) .. "\n" end
  for _, t in ipairs(tables) do parts[#parts + 1] = table_fn(t, lib, texts, sfx) end
  local called = {}
  for _, n in ipairs(entries) do called[n] = renames[n] end
  return table.concat(parts, "\n"), called
end

-- whether the quest can call the runtime in the game instead of its own copy (Build & Play into the running game: no
-- script of its own, which the game would compile only at a start - MaximdeWinter 23.10.: no restart for that) -> true,
-- functions called, or false, why. Every function it needs as the runtime in the game has it, word for word; the item
-- tables there hold every item the quest names.
function SL.fits_runtime(texts, lib, installed, features)
  features = features or {}
  local entries = SL.used(texts, lib)
  local feats = {}
  for _, f in ipairs(features) do if lib[f] then feats[#feats + 1] = f end end
  if #entries == 0 and #feats == 0 then return true, 0 end
  local start = {}
  for _, e in ipairs(entries) do start[#start + 1] = e end
  local fr = {}
  for _, f in ipairs(feats) do for r in pairs(lib[f].refs) do fr[r] = true end end
  for _, r in ipairs(sorted_keys(fr)) do start[#start + 1] = r end
  local need = SL.closure(start, lib)
  local in_need = {}
  for _, n in ipairs(need) do in_need[n] = true end
  local check = {}
  for _, n in ipairs(need) do check[#check + 1] = n end
  for _, f in ipairs(feats) do check[#check + 1] = f end
  for _, n in ipairs(check) do
    local part = false
    for _, t in ipairs(SL.TABLES) do if n == t or is_table_part(t, n) then part = true end end
    if not part and (installed[n] == nil or installed[n].text ~= lib[n].text) then
      return false, "the runtime in the game has another " .. n
    end
  end
  local hay = table.concat(texts, "\n")
  for _, t in ipairs(SL.TABLES) do
    if in_need[t] then
      local have = {}
      for _, r in ipairs(table_rows(t, installed)) do have[r[2]] = true end
      local gone = {}
      for _, r in ipairs(table_rows(t, lib)) do
        if hay:find(r[2], 1, true) and not have[r[2]] then gone[#gone + 1] = r[2] end
      end
      table.sort(gone)
      if #gone > 0 then return false, "the runtime in the game does not know " .. gone[1] end
    end
  end
  return true, #entries
end

-- the build's definition files that name script functions (quest, scenes, stand-ins)
function SL.definition_files(out)
  local files, seen = {}, {}
  local function add(p) if not seen[p] then seen[p] = true files[#files + 1] = p end end
  local function walk(d)
    for _, e in ipairs(fs().list(d) or {}) do
      local p = d .. "\\" .. e.name
      if e.dir then walk(p) elseif e.name:match("%.yml$") then add(p) end
    end
  end
  for _, d in ipairs({"definition.quest", "definition.scenes"}) do
    if fs().isdir(out .. "\\" .. d) then walk(out .. "\\" .. d) end
  end
  for _, e in ipairs(fs().list(out) or {}) do
    if not e.dir and e.name:match("^definition%..*%.yml$") then add(out .. "\\" .. e.name) end
  end
  table.sort(files)
  return files
end

-- the build's step: the definition files call the quest's own names, its script is written to script_dir -> its path
-- (nil: the quest calls nothing of the runtime, or calls the runtime in the game: runtime, its scripts as the game
-- compiled them - SL.fits_runtime)
function SL.apply(out, qid, script_dir, log, lib, runtime)
  log = log or print
  lib = lib or SL.library()
  local files = SL.definition_files(out)
  local texts, list = {}, {}
  for _, f in ipairs(files) do
    texts[f] = read_text(f, false)
    list[#list + 1] = texts[f]
  end
  local features = {}
  for _, nb in ipairs(SL.FEATURES) do
    for _, f in ipairs(files) do
      local t = PYS.strip(texts[f])
      if f:match("([^\\/]*)$") == nb[1] and t ~= "" and t ~= "{}" then
        features[#features + 1] = nb[2]
        break
      end
    end
  end
  for _, e in ipairs(fs().isdir(script_dir) and fs().list(script_dir) or {}) do
    if e.name:match("^cj_quest_.*%.ws$") then fs().remove(script_dir .. "\\" .. e.name) end
  end
  if runtime then
    local fits, said = SL.fits_runtime(list, lib, SL.library({runtime}), features)
    if fits then
      log(string.format("[build] %s: calls %d functions of the runtime in the game", qid, said))
      return nil
    end
    log(string.format("[build] %s: its own script after all: %s", qid, said))
  end
  local script, renames = SL.quest_script(qid, list, lib, features)
  if script == "" then return nil end
  if next(renames) ~= nil then
    for _, f in ipairs(files) do
      local t = texts[f]
      local new = SL.rename_words(t, renames)
      if new ~= t then assert(fs().write(f, new)) end
    end
  end
  local function mkdirs(d)
    if fs().isdir(d) then return end
    mkdirs((d:gsub("\\[^\\]*$", "")))
    fs().mkdir(d)
  end
  mkdirs(script_dir)
  local path = script_dir .. "\\" .. string.format(SL.SCRIPT_NAME, qid)
  assert(fs().write(path, script))
  local n = 0
  for _ in pairs(renames) do n = n + 1 end
  local lines = select(2, script:gsub("\n", "\n"))
  log(string.format("[build] %s: its own script: %d functions called, %d lines", qid, n, lines))
  return path
end

return SL
