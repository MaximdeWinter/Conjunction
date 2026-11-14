-- The quest library (library.py): quests to play are .w3q files in Documents\Conjunction\quests; at every start (and on
-- Refresh) what is new is installed into the game, what changed updated, what was removed taken out. Installed quests
-- are remembered in data\library.json (which DLC and mod folder came from which file, the file's size and time as
-- os.stat gives them) - the app and the mod keep the same file.
--   LIB.sync(log) -> {entry} (file, manifest, status: installed | missing | clash | broken, problems, missing_packs)
--   LIB.read_manifest(path)   LIB.pack_problem(need)   LIB.QUESTS
local J = require("conjunction.json")
local Y = require("conjunction.yaml")
local CFG = require("conjunction.config")
local PATHS = require("conjunction.paths")
local FS = require("conjunction.fsutil")
local PYS = require("conjunction.pystr")
local NUM = require("conjunction.pynum")
local LIB = {}

LIB.QUESTS = PATHS.QUESTS
LIB.STATE = PATHS.DATA .. "\\library.json"
LIB.QUEST_MANIFEST = "conjunction_quest.yml"      -- packaging.QUEST_MANIFEST, content.QUEST_MARKER
LIB.RUNTIME_VERSION = require("conjunction.setup").RUNTIME_VERSION

local function truthy(v) return not (v == nil or v == false or v == Y.null or v == 0 or v == "" or
                                     (type(v) == "table" and next(v) == nil)) end
local function pystr(v)
  if v == nil or v == Y.null then return "None" end
  if v == true then return "True" elseif v == false then return "False" end
  return NUM.str(v)
end
local function get(m, k, dflt) local v = m[k] if v == nil then return dflt end return v end

local function state()
  local ok, st = pcall(J.read, LIB.STATE)
  if ok and type(st) == "table" then return st end
  return Y.map({})
end
local function save(st)
  local home = os.getenv("CJ_HOME")                -- (the lab without a home of its own writes nothing: config.lua)
  if rawget(_G, "lab") ~= nil and (home == nil or home == "") then return end
  w3.fs.mkdir(PATHS.DATA)
  J.write(LIB.STATE, st, {indent = 1})
end

-- a zip's names (cj_zip_list) and one entry's bytes (cj_zip_extract into a file of its own)
local function tmp_dir()
  local d = (os.getenv("TEMP") or ".") .. "\\cj_library"
  w3.fs.mkdir(d)
  return d
end
function LIB.zip_names(path)
  local out = tmp_dir() .. "\\names.txt"
  local ok, r = pcall(w3.plugin.cj_zip_list, path, out)
  if not ok then error((tostring(r):gsub("^cj_zip_list: ", "")), 0) end
  local names = {}
  for line in (w3.fs.read(out) or ""):gmatch("([^\n]*)\n") do
    names[#names + 1] = line:match("^(.*)\t%d+$") or line
  end
  return names
end
function LIB.zip_extract(path, plan)            -- plan: {{name, target}}
  if #plan == 0 then return end
  local lines = {}
  for i, p in ipairs(plan) do lines[i] = p[1] .. "\t" .. p[2] end
  local pf = tmp_dir() .. "\\plan.txt"
  assert(w3.fs.write(pf, table.concat(lines, "\n") .. "\n"))
  local ok, r = pcall(w3.plugin.cj_zip_extract, path, pf)
  if not ok then error((tostring(r):gsub("^cj_zip_extract: ", "")), 0) end
end

-- packaging.manifest_name / read_manifest: in its DLC folder (older files: the root)
function LIB.manifest_name(names)
  for _, n in ipairs(names) do if n == "manifest.yml" then return n end end
  for _, n in ipairs(names) do
    local _, slashes = n:gsub("/", "")
    if slashes == 2 and n:sub(1, 4) == "dlc/" and n:sub(-(#LIB.QUEST_MANIFEST + 1)) == "/" .. LIB.QUEST_MANIFEST then
      return n
    end
  end
  error("'no manifest'", 0)                     -- (KeyError's words)
end
function LIB.read_manifest(path)
  local names = LIB.zip_names(path)
  local name = LIB.manifest_name(names)
  local out = tmp_dir() .. "\\manifest.yml"
  LIB.zip_extract(path, {{name, out}})
  local m = Y.load(w3.fs.read(out) or "")
  if m == nil or m == Y.null or m == false then m = Y.map({}) end
  return m
end

-- [first, last] text id of a manifest (older ones: radish's space)
local function strings_of(m)
  if truthy(m.strings) then
    local out = {}
    for i, x in ipairs(m.strings) do out[i] = math.tointeger(tonumber(x)) or tonumber(x) end
    return out
  end
  if m.strings_idspace ~= nil and m.strings_idspace ~= Y.null then
    local lo = 2110000000 + math.tointeger(tonumber(m.strings_idspace)) * 1000
    return {lo, lo + 999}
  end
  return nil
end
local function overlap(a, b) return a ~= nil and b ~= nil and #a > 0 and #b > 0 and a[1] <= b[2] and b[1] <= a[2] end

-- 'needs Medieval Furniture 1.2 (14 things: oak chair, ...)' - what a missing mod is and gives
function LIB.pack_problem(need)
  local name = truthy(need.name) and need.name or need.id
  local ver = truthy(need.version) and (" " .. pystr(need.version)) or ""
  local used = {}
  for _, u in ipairs(type(need.used) == "table" and need.used or {}) do
    used[#used + 1] = truthy(u.name) and u.name or u.ref
  end
  local things = ""
  if #used > 0 then
    local first = {}
    for i = 1, math.min(3, #used) do first[i] = pystr(used[i]) end
    things = string.format(" (%d %s: %s", #used, #used == 1 and "thing" or "things", table.concat(first, ", ")) ..
             (#used > 3 and ", ..." or "") .. ")"
  end
  local why = pystr(get(need, "why", ""))
  if why:sub(1, 3) == "old" then
    return string.format("needs %s%s or newer (installed: %s)%s", pystr(name), ver, why:sub(6), things)
  end
  return string.format("needs the mod %s%s%s", pystr(name), ver, things)
end

-- what keeps a quest from playing (empty: nothing); known_ids: the quests this game has
function LIB.problems(m, game, others, known_ids)
  local out = {}
  local rt = tonumber(get(m, "runtime", 1)) or 1
  if math.floor(rt) > LIB.RUNTIME_VERSION then
    out[#out + 1] = string.format("needs Conjunction Runtime %s or newer", pystr(m.runtime))
  end
  for _, need in ipairs(require("conjunction.content").missing_packs(m, game)) do
    out[#out + 1] = LIB.pack_problem(need)
  end
  for _, other in ipairs(others) do
    if J.encode(other.id) == J.encode(m.id) then
      out[#out + 1] = string.format("the same id as %s - only one of them can be installed", pystr(other.title))
    elseif overlap(strings_of(other), strings_of(m)) then
      out[#out + 1] = string.format("clashes with %s (the same text ids)", pystr(other.title))
    else
      local mine = {}
      for _, r in ipairs(type(m.replaces) == "table" and m.replaces or {}) do mine[pystr(r)] = true end
      local both = {}
      for _, r in ipairs(type(other.replaces) == "table" and other.replaces or {}) do
        if mine[pystr(r)] then both[#both + 1] = pystr(r) end
      end
      table.sort(both)
      if #both > 0 then
        out[#out + 1] = string.format("clashes with %s (both change the game's %s)", pystr(other.title), both[1])
      end
    end
  end
  if known_ids ~= nil and truthy(m.after) and not known_ids[PYS.lower(pystr(m.after))] then
    out[#out + 1] = string.format("starts after the quest %s, which is not installed", pystr(m.after))
  end
  return out
end

local function isdir(p) return w3.fs.isdir(p) end

-- the quest's DLC (and mod) folder from the file, only what lies in its own folders
local function install(path, m, game)
  local id = pystr(m.id)
  local dlc = PATHS.join(game, "dlc", "dlc" .. id)
  local mod = PATHS.join(game, "Mods", "moddlc" .. id)
  for _, d in ipairs({dlc, mod}) do if isdir(d) then FS.rmtree(d) end end
  local own_dlc, own_mod = PYS.lower("dlc" .. id), PYS.lower("moddlc" .. id)
  local plan = {}
  for _, name in ipairs(LIB.zip_names(path)) do
    if name:sub(-1) ~= "/" then
      local top, rest = name:match("^([^/]*)/(.*)$")
      if not top then top, rest = name, "" end
      local first, inner = rest:match("^([^/]*)/(.*)$")
      if not first then first, inner = rest, "" end
      local target
      if top == "dlc" and PYS.lower(first) == own_dlc then          -- (the game's layout, 1.0)
        if inner:sub(1, 19) ~= "conjunction_source/" then target, rest = PATHS.join(dlc, inner), inner end
      elseif top == "Mods" and PYS.lower(first) == own_mod then
        target, rest = PATHS.join(mod, inner), inner
      elseif top == "dlc" then target = PATHS.join(dlc, rest)        -- (older files: dlc/<content>, mod/<content>)
      elseif top == "mod" then target = PATHS.join(mod, rest) end
      if target then
        local bad = false
        for part in (rest:gsub("\\", "/") .. "/"):gmatch("([^/]*)/") do if part == ".." then bad = true end end
        if not bad then plan[#plan + 1] = {name, (target:gsub("/", "\\"))} end
      end
    end
  end
  LIB.zip_extract(path, plan)
  local out = Y.list({dlc})
  if isdir(mod) then out[#out + 1] = mod end
  return out
end

local function uninstall(folders)
  local game = CFG.load().game or ""
  for _, d in ipairs(folders or {}) do
    if type(d) == "string" and d ~= "" and PYS.lower(d):sub(1, #game) == PYS.lower(game) and isdir(d) then
      FS.rmtree(d)
    end
  end
end

-- quests made with Conjunction that came into the game another way (a mod manager): checked, left where they are
function LIB.by_hand(game, st, log)
  log = log or print
  st = st or state()
  local ours = {}
  for _, k in ipairs(Y.keys(st)) do
    for _, d in ipairs(type(st[k].folders) == "table" and st[k].folders or {}) do ours[PYS.lower(d)] = true end
  end
  local out = {}
  local root = PATHS.join(game, "dlc")
  if not isdir(root) then return out end
  local names = {}
  for _, e in ipairs(w3.fs.list(root) or {}) do names[#names + 1] = e.name end
  table.sort(names)
  local C = require("conjunction.content")
  for _, name in ipairs(names) do
    local path = PATHS.join(root, name)
    local marker = PATHS.join(path, LIB.QUEST_MANIFEST)
    if not ours[PYS.lower(path)] and w3.fs.exists(marker) and not isdir(marker) then
      local ok, m = pcall(Y.read, marker)
      if not ok then log(string.format("[library] %s: %s", marker, tostring(m)))
      else
        if m == nil or m == Y.null or m == false then m = Y.map({}) end
        local probs = LIB.problems(m, game, {})
        out[#out + 1] = {file = "dlc\\" .. name, manifest = m, status = #probs > 0 and "missing" or "installed",
                         problems = probs, missing_packs = C.missing_packs(m, game), by_hand = true}
      end
    end
  end
  return out
end

-- the game in line with the quests folder -> {entry}
function LIB.sync(log)
  log = log or print
  w3.fs.mkdir(LIB.QUESTS)
  local game = CFG.load().game or ""
  local files = {}
  for _, e in ipairs(w3.fs.list(LIB.QUESTS) or {}) do
    if PYS.lower(e.name):sub(-4) == ".w3q" then files[#files + 1] = e.name end
  end
  table.sort(files)
  if game == "" or game == Y.null or not isdir(PATHS.join(game, "content")) then
    log("[library] The game's folder is not set")
    local out = {}
    for _, f in ipairs(files) do
      out[#out + 1] = {file = f, manifest = Y.map({}), status = "missing", missing_packs = {},
                       problems = {"the game's folder is not set (Conjunction's setup asks for it)"}}
    end
    return out
  end
  local st = state()
  local entries = {}
  local manifests, order = {}, {}
  for _, f in ipairs(files) do
    local ok, m = pcall(LIB.read_manifest, PATHS.join(LIB.QUESTS, f))
    if ok then manifests[f] = m order[#order + 1] = f
    else
      entries[#entries + 1] = {file = f, manifest = Y.map({}), status = "broken",
                               problems = {"not a quest file: " .. tostring(m)}}
    end
  end
  local hand = LIB.by_hand(game, st, log)
  if #order > 0 or #hand > 0 then
    local ok, e = pcall(require("conjunction.setup").install_runtime)
    if not ok then log("[library] runtime not installed: " .. tostring(e)) end
  end
  local known_ids = {}
  for _, f in ipairs(order) do known_ids[PYS.lower(pystr(get(manifests[f], "id", "")))] = true end
  for _, e in ipairs(hand) do known_ids[PYS.lower(pystr(get(e.manifest, "id", "")))] = true end
  local C = require("conjunction.content")
  local seen = {}
  for _, f in ipairs(order) do
    local m = manifests[f]
    local path = PATHS.join(LIB.QUESTS, f)
    local others = {}
    for _, g in ipairs(order) do if g ~= f and g < f then others[#others + 1] = manifests[g] end end
    local probs = LIB.problems(m, game, others, known_ids)
    local entry = {file = f, manifest = m, status = "installed", problems = probs,
                   missing_packs = C.missing_packs(m, game)}
    local size, mtime = w3.plugin.cj_py_stat(path):match("^(%d+) (%S+)$")
    local stamp = Y.list({math.tointeger(tonumber(size)), tonumber(mtime) + 0.0})
    local known = st[f]
    if #probs > 0 then
      local clash = false
      for _, p in ipairs(probs) do if p:find("same", 1, true) or p:find("clashes", 1, true) then clash = true end end
      entry.status = clash and "clash" or "missing"
      if known then
        uninstall(known.folders)
        Y.remove(st, f)
      end
    elseif not known or J.encode(known.stamp) ~= J.encode(stamp) then
      local folders = install(path, m, game)
      st[f] = Y.map({"stamp", stamp, "folders", folders, "id", get(m, "id", Y.null)})
      log(string.format("[library] Installed %s (%s)", pystr(m.title), f))
    end
    seen[f] = true
    entries[#entries + 1] = entry
  end
  for _, f in ipairs(Y.keys(st)) do                -- removed from the folder: out of the game too
    if not seen[f] then
      uninstall(st[f].folders)
      log("[library] removed " .. f)
      Y.remove(st, f)
    end
  end
  save(st)
  for _, e in ipairs(LIB.by_hand(game, st, log)) do entries[#entries + 1] = e end
  return entries
end

return LIB
