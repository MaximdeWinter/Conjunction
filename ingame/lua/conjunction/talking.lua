-- Which looks of a person can move their mouth (conjunction/talking.py): read from the game's files (talking_looks:
-- a template's appearances, the face rigs of their heads) and kept where the app keeps it (data\talking_looks.json).
-- The asset build fills it for the whole catalog (assets_build.fill_talking, talking.fill).
local J = require("conjunction.json")
local S = require("conjunction.pystr")
local PATHS = require("conjunction.paths")
local T = {}
T.CACHE = PATHS.DATA .. "\\talking_looks.json"
T.SPAWN = "spawn:"
T.save = true                     -- (talking._save)
local cache

function T.load()
  if cache == nil then
    local ok, d = pcall(J.read, T.CACHE)
    cache = (ok and type(d) == "table") and d or require("conjunction.yaml").map()   -- (a dict: keys in order)
  end
  return cache
end
function T.reload() cache = nil end

-- talking_looks if already read, else nil
function T.known_talking(template) return T.load()[S.lower(template)] end

-- [look] of a template whose face can talk (a CMimicComponent in the first files of a template the look puts
-- together) - those the game spawns first, then the others; {} if none can. Kept in the cache with the looks the game
-- spawns it with (talking.talking_looks; read in a coroutine it gives the frames back as meshview does)
function T.talking_looks(template, depot)
  local Y = require("conjunction.yaml")
  local c = T.load()
  local key = S.lower(template)
  if c[key] ~= nil and c[T.SPAWN .. key] ~= nil then return c[key] end
  local MV = require("conjunction.meshview")
  local CR = require("conjunction.cr2w")
  local apps, used = MV.looks(template, depot)
  local faces = T.faces or {}                    -- (the asset build keeps them over all its people: T.faces)
  local function face(sub)
    if faces[sub] == nil then
      local found = false
      if depot:exists(sub) then
        MV.breathe()
        local parts = CR.parts(depot:read(sub))
        for k = 1, math.min(3, #parts) do
          for _, e in ipairs(parts[k].exports) do if e[1] == "CMimicComponent" then found = true end end
        end
      end
      faces[sub] = found
    end
    return faces[sub]
  end
  local talking, is_talking = {}, {}
  for _, a in ipairs(apps.keys) do
    for _, s in ipairs(apps.v[a]) do
      if face(s) then talking[#talking + 1] = a is_talking[a] = true break end
    end
  end
  local out, in_used = Y.list(), {}
  for _, u in ipairs(used) do in_used[u] = true if is_talking[u] then out[#out + 1] = u end end
  for _, a in ipairs(talking) do if not in_used[a] then out[#out + 1] = a end end
  local spawn = Y.list()
  for _, u in ipairs(used) do if apps.v[u] ~= nil then spawn[#spawn + 1] = u end end
  if #spawn == 0 then for _, a in ipairs(apps.keys) do spawn[#spawn + 1] = a end end
  c[key] = out
  c[T.SPAWN .. key] = spawn
  -- (as the app keeps it: json.dump, one line; the lab without a Documents\Conjunction of its own writes nothing;
  -- off while the asset build fills many at once: it writes the file once at the end)
  local home = os.getenv("CJ_HOME")
  if T.save and not (rawget(_G, "lab") ~= nil and (home == nil or home == "")) then
    pcall(function() w3.fs.write(T.CACHE, J.encode(c)) end)
  end
  return out
end
-- true (a look can move its mouth), false (none can), nil (not read yet)
function T.can_talk(template)
  local talking = T.known_talking(template)
  if talking == nil then return nil end
  return #talking > 0
end
-- the looks the game picks one of when it spawns the template, {} if not read yet
function T.spawn_looks(template)
  local v = T.load()[T.SPAWN .. S.lower(template)]
  if type(v) ~= "table" or #v == 0 then return {} end
  return v
end
-- "all", "some", "none", nil (not read yet)
function T.voice(template)
  local talking = T.known_talking(template)
  if talking == nil then return nil end
  if #talking == 0 then return "none" end
  local set = {}
  for _, l in ipairs(talking) do set[l] = true end
  for _, s in ipairs(T.spawn_looks(template)) do
    if not set[s] then return "some" end
  end
  return "all"
end
-- talking.mouth: 'moves' (this look's face can talk), 'shut' (another look could), 'none' (no look can), 'maybe' (no
-- look set and the game may give one that cannot); nil while not read yet
function T.mouth(template, look)
  local talking = T.known_talking(template)
  if talking == nil then return nil end
  if #talking == 0 then return "none" end
  if look == nil or look == "" or look == require("conjunction.yaml").null then
    return T.voice(template) == "some" and "maybe" or "moves"
  end
  for _, l in ipairs(talking) do if l == look then return "moves" end end
  return "shut"
end

-- talking.known_anims: the scene animations a template's body can play, if the app has read them (its
-- dialogue_anims.json) - a set; nil when not read yet
local anims
function T.known_anims(template)
  if anims == nil then
    local ok, d = pcall(J.read, require("conjunction.paths").DATA .. [[\dialogue_anims.json]])
    anims = ok and type(d) == "table" and d or {}
    anims.sets = anims.sets or {}
    anims.templates = anims.templates or {}
  end
  local sets = anims.templates[S.lower(template)]
  if sets == nil then return nil end
  local out = {}
  for _, s in ipairs(sets) do
    if anims.sets[s] == nil then return nil end
    for _, n in ipairs(anims.sets[s]) do out[n] = true end
  end
  return out
end

-- (the checks: everything read anew)
function T.forget_anims() anims = {sets = {}, templates = {}} end

-- the dialogue animsets a template lists (and those of the base entities it includes), a set
local function animsets(template, depot, depth)
  local ok, data = pcall(depot.read, depot, template)
  if not ok or type(data) ~= "string" then return {} end
  local out = {}
  for p in data:gmatch("[a-z0-9_\\]+%.w2anims") do
    if p:find("dialog", 1, true) then out[p] = true end
  end
  if depth < 2 then
    local bases = {}
    for b in data:gmatch("characters\\base_entities\\[a-z0-9_\\]+%.w2ent") do bases[b] = true end
    for b in pairs(bases) do
      for s in pairs(animsets(b, depot, depth + 1)) do out[s] = true end
    end
  end
  return out
end

-- talking.dialogue_anims: the scene animations a template's body can play - the names radish knows
-- (dialogue.all_animations) found in the dialogue animsets the template lists; a set (empty: none, an animal or a
-- monster). nil: nothing to tell by (no game or no radish to look in). What it reads is kept in dialogue_anims.json
-- as the app keeps it (the checks' runs keep nothing: CJ_REF)
function T.dialogue_anims(template, depot)
  local have = T.known_anims(template)
  if have ~= nil then return have end
  local known = require("conjunction.dialogue").all_animations()
  if #known == 0 then return nil end
  if depot == nil then
    local ok, d = pcall(function() return require("conjunction.depot").open(require("conjunction.config").load().game) end)
    if not ok then return nil end
    depot = d
  end
  local Y = require("conjunction.yaml")
  local key = S.lower(template)
  local sets = {}
  for s in pairs(animsets(key, depot, 0)) do sets[#sets + 1] = s end
  table.sort(sets)
  for _, s in ipairs(sets) do
    if anims.sets[s] == nil then
      local ok, data = pcall(depot.read, depot, s)
      local words = {}
      if ok and type(data) == "string" then
        for w in data:gmatch("[a-z0-9_]+") do if #w >= 4 then words[w] = true end end
      end
      local names = {}
      for _, a in ipairs(known) do if words[a[1]] then names[#names + 1] = a[1] end end
      table.sort(names)
      anims.sets[s] = Y.list(names)
    end
  end
  anims.templates[key] = Y.list(sets)
  local home = os.getenv("CJ_HOME")              -- (as talking_looks: the lab without a home of its own writes nothing)
  if not os.getenv("CJ_REF") and not (rawget(_G, "lab") ~= nil and (home == nil or home == "")) then
    pcall(function()
      local path = require("conjunction.paths").DATA .. [[\dialogue_anims.json]]
      assert(w3.fs.write(path .. ".tmp", J.encode(anims)))     -- (json.dump: one line)
      if w3.fs.exists(path) then w3.fs.remove(path) end
      w3.fs.rename(path .. ".tmp", path)
    end)
  end
  local out = {}
  for _, s in ipairs(sets) do for _, n in ipairs(anims.sets[s]) do out[n] = true end end
  return out
end

-- the look a speaking person gets, a note or nil: the chosen one if it can talk, else the first that can
function T.look_for_speaker(template, chosen, depot)
  local ok, talking = pcall(function()
    if depot == nil then depot = require("conjunction.depot").open(require("conjunction.config").load().game) end
    return T.talking_looks(template, depot)
  end)
  if not ok then return chosen, nil end
  if #talking == 0 then return chosen, "no look of it can move its mouth" end
  for _, l in ipairs(talking) do if l == chosen then return chosen, nil end end
  local note = nil
  if chosen ~= nil and chosen ~= "" and chosen ~= require("conjunction.yaml").null then
    note = "look " .. tostring(chosen) .. " cannot move its mouth - " .. tostring(talking[1]) .. " instead"
  end
  return talking[1], note
end

-- voice() of several (a folder of the catalog): the same for all, else "some"; nil if one is not read yet
function T.voices(templates)
  local found, n, last = {}, 0, nil
  for _, t in ipairs(templates) do
    local v = T.voice(t)
    if v == nil then return nil end
    if not found[v] then found[v] = true n = n + 1 last = v end
  end
  if n == 1 then return last end
  if n == 0 then error("talking.voices of nothing (Python: pop from an empty set)") end
  return "some"
end

return T
