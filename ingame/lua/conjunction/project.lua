-- A Conjunction project (project.py) as far as the editor uses it: project.yml, places\<name>.yml, the objects the
-- editor places, moves and deletes, the ids. Files are written byte for byte as the app writes them (yaml.lua).
--
--   local P = require("conjunction.project")
--   local pr = P.open(path)
--   pr:apply_change("change|placed|place=main|world=...|template=...|pos=1,2,3|rot=0,0,90")
--   pr:find_object("main", {x, y, z})       -- 1-based index or nil
local Y = require("conjunction.yaml")
local PYS = require("conjunction.pystr")   -- (Python's str.lower: umlauts too)
local NUM = require("conjunction.pynum")
local PATHS = require("conjunction.paths")
local QUEST = require("conjunction.quest")
local FOLD = require("conjunction.data.ascii_fold")
local P = {}
P.PROJECTS = PATHS.PROJECTS
local Project = {}
Project.__index = Project
P.Project = Project

local log = print

-- --- ids (ascii_id, is_id, fact_id, is_fact, slug_of) ---
-- the one way an id is made from typed text: a-z, 0-9 and `sep` between the words (lower = false keeps capitals)
function P.ascii_id(text, sep, lower)
  if sep == nil then sep = "_" end
  if lower == nil then lower = true end
  local s = (text == nil or text == false or text == "" or text == 0 or text == Y.null) and "" or NUM.str(text)
  local fold = lower and FOLD.lower or FOLD.keep
  local out = {}
  for _, c in utf8.codes(s) do
    if c < 0x80 then
      local ch = string.char(c)
      if lower then ch = ch:lower() end
      out[#out + 1] = ch:match("^%w$") and ch or " "
    else
      local f = fold[c]
      if f then out[#out + 1] = (f:gsub("%W", " ")) end
    end
  end
  local words = {}
  for w in table.concat(out):gmatch("%S+") do words[#words + 1] = w end
  return table.concat(words, sep)
end
function P.is_id(text)
  if text == nil or text == "" or text == Y.null then return false end
  local s = NUM.str(text)
  return s ~= "" and not s:find("[^a-z0-9_]")
end
function P.is_fact(text)
  if text == nil or text == "" or text == Y.null then return false end
  local s = NUM.str(text)
  return s ~= "" and not s:find("[^A-Za-z0-9_]")
end
-- (Python's str.strip(): its whitespace, Unicode's too)
local UWS = {[0x85] = true, [0xA0] = true, [0x1680] = true, [0x2028] = true, [0x2029] = true, [0x202F] = true,
             [0x205F] = true, [0x3000] = true}
for c = 0x2000, 0x200A do UWS[c] = true end
for c = 0x1C, 0x1F do UWS[c] = true end
for _, c in ipairs({9, 10, 11, 12, 13, 32}) do UWS[c] = true end
function P.strip(s)
  local cps = {}
  for _, c in utf8.codes(s) do cps[#cps + 1] = c end
  local i, j = 1, #cps
  while i <= j and UWS[cps[i]] do i = i + 1 end
  while j >= i and UWS[cps[j]] do j = j - 1 end
  local t = {}
  for k = i, j do t[#t + 1] = utf8.char(cps[k]) end
  return table.concat(t)
end
function P.fact_id(text)
  local s = P.strip((text == nil or text == false or text == "" or text == Y.null) and "" or NUM.str(text))
  if P.is_fact(s) then return s end
  return P.ascii_id(s, "_", false)
end
function P.slug_of(name)
  local s = P.ascii_id(name, ""):sub(1, 24)
  return s ~= "" and s or "project"
end

-- --- the worlds of radish's repository (worlds.repo.yml) ---
local function repo_worlds()
  local CFG = require("conjunction.config")
  local repo = Y.read(CFG.load().radish .. "\\repo.quests\\worlds.repo.yml")
  return repo.repository.worlds
end
-- radish world id per depot path (levels\novigrad\novigrad.w2w -> novigrad)
function P.worlds()
  local out = {}
  for k, v in pairs(repo_worlds()) do out[PYS.lower((v.world:gsub("/", "\\")))] = k end
  return out
end
function P.world_paths()
  local out = {}
  for k, v in pairs(repo_worlds()) do out[k] = PYS.lower((v.world:gsub("/", "\\"))) end
  return out
end

-- the libraries Conjunction builds, as they were named before 05.10.
local RENAMED = {{[[dlc\dlcw3suitemeshes\]], [[dlc\dlcconjunctionmeshes\]]},
                 {[[dlc\dlcw3suitefoliage\]], [[dlc\dlcconjunctionfoliage\]]}}
local function renamed(t)
  local low = PYS.lower(t)
  for _, r in ipairs(RENAMED) do
    if low:sub(1, #r[1]) == r[1] then return r[2] .. t:sub(#r[1] + 1) end
  end
  return t
end

local function is_yml(name)
  return name:sub(1, 1) ~= "." and PYS.lower(name):sub(-4) == ".yml"
end

-- --- opening ---
function P.open(path)
  local self = setmetatable({path = path}, Project)
  self.meta = Y.read(path .. "\\project.yml")
  self.places = Y.map()
  local dir = path .. "\\places"
  for _, e in ipairs(w3.fs.isdir(dir) and w3.fs.list(dir) or {}) do
    if not e.dir and is_yml(e.name) then
      local name = PATHS.splitext(e.name)
      local data = Y.read(dir .. "\\" .. e.name)
      if data == nil or data == Y.null or data == false or (type(data) == "table" and next(data) == nil) then
        data = Y.map()
      end
      self.places[name] = data
      local changed = false
      local objs = Y.is_map(data) and data.objects
      if type(objs) == "table" and objs ~= Y.null then
        for _, o in ipairs(objs) do
          local t = Y.is_map(o) and o.template or nil
          if type(t) == "string" and renamed(t) ~= t then
            o.template, changed = renamed(t), true
          end
        end
      end
      if changed then
        log("[project] " .. name .. ": objects of the renamed libraries now from dlcconjunction...")
        self:save_place(name)
      elseif self:_people_named(name, true) then
        self:save_place(name)
      end
    end
  end
  self:_ascii_ids()
  return self
end

-- the quest's id in the game: the project's id and the run of Build & Play (<id>r<n>)
function Project:base_id() return PYS.lower(NUM.str(self.meta.id)) end
function Project:id()
  local run = self.meta.run
  run = (run == nil or run == Y.null or run == false or run == "") and 0 or math.tointeger(tonumber(run)) or 0
  return run ~= 0 and (self:base_id() .. "r" .. run) or self:base_id()
end

function Project:place(name, world)
  local p = self.places[name]
  if p == nil then
    p = Y.map({"world", world == nil and Y.null or world, "visible", "start", "objects", Y.list()})
    self.places[name] = p
  end
  local w = p.world
  if world and world ~= Y.null and (w == nil or w == Y.null or w == "" or w == false) then p.world = world end
  return p
end

function Project:_template_id(o)
  local base = PATHS.basename((o.template:gsub("\\", "/")):gsub("/", "\\"))
  return P.ascii_id((PATHS.splitext(base)))
end

local function objects_of(place)
  local objs = Y.is_map(place) and place.objects or nil
  if objs == nil or objs == Y.null or objs == false then return Y.list() end
  return objs
end

-- every person of a place has an id of its own (built: one from before gets the build's npc<k>)
function Project:_people_named(name, built)
  local objs = objects_of(self.places[name] or Y.map())
  local taken = {}
  for _, o in ipairs(objs) do if Y.is_map(o) and o.id ~= nil then taken[o.id] = true end end
  local changed = false
  for k, o in ipairs(objs) do
    if Y.is_map(o) and not (o.id and o.id ~= Y.null and o.id ~= "") and o.template and o.template ~= "" and
       o.template ~= Y.null then
      local ok, person = pcall(QUEST.is_actor, o)
      if ok and person then
        local first = built and ("npc" .. (k - 1)) or self:_template_id(o)
        local oid, n = first, 2
        while taken[oid] do oid, n = first .. "_" .. n, n + 1 end
        o.id = oid
        taken[oid] = true
        changed = true
      end
    end
  end
  return changed
end

function Project:save_place(name)
  self:_people_named(name)
  Y.write(self.path .. "\\places\\" .. name .. ".yml", self.places[name], {sort_keys = false, default_flow_style = nil})
end
function Project:save_meta()
  Y.write(self.path .. "\\project.yml", self.meta, {sort_keys = false, allow_unicode = true, default_flow_style = false})
end

-- the index (1-based) of the object of `place` standing at pos, or the nearest within `near` m
function Project:find_object(place, pos, tol, near)
  tol, near = tol or 0.05, near or 1.5
  local p = self.places[place]
  local objs = Y.is_map(p) and p.objects or nil
  if objs == nil or objs == Y.null or #objs == 0 or pos == nil then return nil end
  local best, bd
  for i, o in ipairs(objs) do
    local sq = {}
    for k = 1, math.min(#o.pos, #pos) do
      local d = o.pos[k] - pos[k]
      sq[k] = d * d
    end
    local d = NUM.sum(sq)
    if bd == nil or d < bd then best, bd = i, d end
  end
  local lim = math.max(tol, near)
  return bd <= lim * lim and best or nil
end

-- every place/id reference of the quest to old becomes new; -> whether one changed
function Project:_rename_refs(old, new)
  local changed = false
  local function fix(x)
    if Y.is_map(x) then
      for k, v in pairs(x) do
        if v == old then x[k] = new; changed = true else fix(v) end
      end
    elseif type(x) == "table" and x ~= Y.null then
      for k, v in ipairs(x) do
        if v == old then x[k] = new; changed = true else fix(v) end
      end
    end
  end
  local q = self.meta.quest
  fix((q ~= nil and q ~= Y.null and q) or Y.map())
  return changed
end

-- an id for an object (for quest steps); without a name one from `base` (the catalog's title) or the template
function Project:name_object(place, index, name, base)
  local objs = self.places[place].objects
  local o = objs[index]
  if name == nil then
    local auto = self:_template_id(o)
    local id = o.id
    local ids = (id == nil or id == Y.null) and "" or NUM.str(id)
    local made = (id == auto) or (ids:sub(1, #auto + 1) == auto .. "_" and ids:sub(#auto + 2):match("^%d+$") ~= nil)
    if id ~= nil and id ~= Y.null and id ~= "" and not (base and made) then return id end
    base = base and P.ascii_id(base) or auto
    local taken = {}
    for _, x in ipairs(objs) do if x ~= o and x.id ~= nil then taken[x.id] = true end end
    local n
    name, n = base, 2
    while taken[name] do name, n = base .. "_" .. n, n + 1 end
  end
  local old = o.id
  o.id = name
  self:save_place(place)
  if old and old ~= Y.null and old ~= "" and old ~= name and
     self:_rename_refs(place .. "/" .. NUM.str(old), place .. "/" .. name) then
    self:save_meta()
  end
  return name
end

-- fields of an object set (nil, an empty list or "" removes one), the place saved; fields: {k1, v1, k2, v2, ...}
function Project:set_object(place, index, fields)
  local o = self.places[place].objects[index]
  for i = 1, #fields, 2 do
    local k, v = fields[i], fields[i + 1]
    if v == nil or v == Y.null or v == "" or (type(v) == "table" and Y.is_list(v) and #v == 0) then
      Y.remove(o, k)
    else
      o[k] = v
    end
  end
  self:save_place(place)
  return o
end

-- the placing profile's mark in an object's last digits (marks.stamp; without a profile the values stay)
P.stamp = function(project, pos, rot)
  local ok, p, r = pcall(require("conjunction.marks").stamp, project, pos, rot)
  if not ok then print("[project] mark: " .. tostring(p)) return pos, rot end   -- (placing never fails for the mark)
  return p, r
end

local function split(s, sep)
  local out = {}
  local i = 1
  while true do
    local j = s:find(sep, i, true)
    if not j then out[#out + 1] = s:sub(i); break end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + #sep
  end
  return out
end
P.split = split

local function floats(s, digits)
  local out = Y.list()
  for _, v in ipairs(split(s, ",")) do out[#out + 1] = NUM.round(NUM.float(v), digits) end
  return out
end

-- one report line of the game's editor (change|placed|place=..|...): stored -> a short description, or nil
function Project:apply_change(line)
  local at = line:find("change|", 1, true)
  if not at then return nil end
  local parts = split(P.strip(line:sub(at + 7)), "|")
  local what = parts[1]
  local kv = {}
  for i = 2, #parts do
    local eq = parts[i]:find("=", 1, true)
    if eq then kv[parts[i]:sub(1, eq - 1)] = parts[i]:sub(eq + 1) end
  end
  local name = (kv.place ~= nil and kv.place ~= "") and kv.place or "default"
  local world = P.worlds()[PYS.lower(kv.world or "")]
  local pos = floats(kv.pos, 3)
  local place = self:place(name, world)
  local objs = place.objects
  if what == "placed" then
    local rot = floats(kv.rot, 2)
    pos, rot = P.stamp(self, pos, rot)
    objs[#objs + 1] = Y.map({"template", kv.template, "pos", pos, "rot", rot})
    if kv.appearance and kv.appearance ~= "" then objs[#objs].appearance = kv.appearance end
  elseif what == "removed" or what == "effect" or what == "effect_off" or what == "look" or
         ((what == "moved" or what == "rotated") and kv.game == "1") then
    return self:_world_change(what, kv, world, pos)
  elseif what == "deleted" or what == "moved" or what == "rotated" then
    local key = what == "moved" and Y.list((function()
      local t = {}
      for i, v in ipairs(split(kv.from, ",")) do t[i] = NUM.float(v) end
      return t
    end)()) or pos
    if #objs == 0 then return nil end
    local d = {}
    for i, o in ipairs(objs) do
      local sq = {}
      for k = 1, math.min(#o.pos, #key) do local e = o.pos[k] - key[k]; sq[k] = e * e end
      d[i] = NUM.sum(sq)
    end
    local best = 1
    for i = 2, #d do if d[i] < d[best] then best = i end end
    if d[best] > 0.05 * 0.05 then
      -- none exactly there: the nearest of the same template within 1.5 m (a creature settles)
      local same
      for k, o in ipairs(objs) do
        if PYS.lower(o.template) == PYS.lower(kv.template or "") and d[k] <= 1.5 * 1.5 then
          if same == nil or d[k] < d[same] then same = k end
        end
      end
      if not same then return nil end
      best = same
    end
    if what == "deleted" then
      table.remove(objs, best)
    else
      objs[best].pos, objs[best].rot = P.stamp(self, pos, floats(kv.rot, 2))
    end
  else
    return nil
  end
  self:save_place(name)
  return what .. " in " .. name .. ": " .. (kv.template or "") .. " at " .. P.list_repr(pos)
end

-- Python's str() of a list of floats: [1.0, 2.5, 3.0]
function P.list_repr(l)
  local t = {}
  for i, v in ipairs(l) do t[i] = NUM.str(v) end
  return "[" .. table.concat(t, ", ") .. "]"
end

-- an object the game placed, changed in the editor: kept in world.yml (worldchanges)
function Project:_world_change(what, kv, world, pos)
  local W = require("conjunction.worldchanges")
  local guid = kv.guid or ""
  if not W.guid_ok(guid) then return nil end
  local label = W.short_name(kv.name or kv.template)
  if label == "" then label = string.format("object at %.0f, %.0f", pos[1], pos[2]) end
  if what == "effect_off" then
    for _, c in ipairs(W.load(self.path)) do
      if c.guid == guid and c["do"] == "effect" then W.drop(self.path, c.id) end
    end
    return "effect off: " .. label
  end
  local function fl(s) local t = {} for i, v in ipairs(split(s, ",")) do t[i] = NUM.float(v) end return t end
  if what == "moved" or what == "rotated" then
    local rot = fl(kv.rot or "0,0,0")
    local home = fl((kv.home and kv.home ~= "" and kv.home) or (kv.from and kv.from ~= "" and kv.from) or kv.pos)
    local home_rot = fl((kv.homerot and kv.homerot ~= "" and kv.homerot) or kv.rot or "0,0,0")
    local cid = W.add(self.path, guid, "move", W.transform(pos, rot), label, world, pos, W.transform(home, home_rot))
    return "world change " .. cid .. " (move): " .. label
  end
  local d = ({removed = "remove", effect = "effect", look = "look"})[what]
  local cid = W.add(self.path, guid, d, kv.value or "", label, world, pos)
  return "world change " .. cid .. " (" .. d .. ((kv.value and kv.value ~= "") and (" " .. kv.value) or "") .. "): " .. label
end

-- every id as the game's tools take it (07.10.): an item, an object or a place named with an umlaut or a space gets
-- its ascii_id and every reference follows; once, kept
function Project:_ascii_ids()
  local q = self.meta.quest
  local items = (q ~= nil and q ~= Y.null and Y.is_map(q) and q.items) or nil
  if items == Y.null or not Y.is_map(items) then items = Y.map() end
  local refs, place_names = Y.map(), Y.map()
  for _, iid in ipairs(Y.keys(items)) do
    if not P.is_id(iid) then
      local base = P.ascii_id(iid, ""):sub(1, 20)
      if base == "" then base = "item" end
      local new, n = base, 2
      while items[new] ~= nil do new, n = base .. n, n + 1 end
      items[new] = Y.remove(items, iid)
      refs["own:" .. NUM.str(iid)] = "own:" .. new
    end
  end
  for _, name in ipairs(Y.keys(self.places)) do
    if not P.is_id(name) then
      local base = P.ascii_id(name)
      if base == "" then base = "place" end
      local new, n = base, 2
      while self.places[new] ~= nil do new, n = base .. "_" .. n, n + 1 end
      place_names[name] = new
    end
  end
  for name, p in pairs(self.places) do
    local objs = objects_of(p)
    local taken = {}
    for _, o in ipairs(objs) do if Y.is_map(o) and o.id ~= nil then taken[o.id] = true end end
    for _, o in ipairs(objs) do
      local oid = Y.is_map(o) and o.id or nil
      if oid and oid ~= Y.null and oid ~= "" and not P.is_id(oid) then
        local base = P.ascii_id(oid)
        if base == "" then base = "object" end
        local new, n = base, 2
        while taken[new] do new, n = base .. "_" .. n, n + 1 end
        taken[new] = true
        o.id = new
        refs[name .. "/" .. NUM.str(oid)] = (place_names[name] or name) .. "/" .. new
      end
    end
    for _, o in ipairs(objs) do
      if place_names[name] and Y.is_map(o) and o.id and o.id ~= Y.null and o.id ~= "" then
        local k = name .. "/" .. NUM.str(o.id)
        if refs[k] == nil then refs[k] = place_names[name] .. "/" .. NUM.str(o.id) end
      end
    end
  end
  local facts = {}
  local any_fact = false
  local function find_facts(x, key)
    if Y.is_map(x) then
      for k, v in pairs(x) do
        if type(v) == "string" and (k == "fact" or (k == "name" and key == "fact")) and v ~= "" and not P.is_fact(v) then
          facts[v] = P.fact_id(v)
          any_fact = true
        end
        find_facts(v, k)
      end
    elseif type(x) == "table" and x ~= Y.null then
      for _, v in ipairs(x) do find_facts(v, key) end
    end
  end
  find_facts(q)
  if Y.len(refs) == 0 and Y.len(place_names) == 0 and not any_fact then return end
  local function follow(x, key)
    if Y.is_map(x) then
      local out = Y.map()
      for k, v in pairs(x) do
        if type(v) == "string" and (k == "fact" or (k == "name" and key == "fact")) then
          out[k] = facts[v] or v
        else
          out[k] = follow(v, k)
        end
      end
      return out
    end
    if type(x) == "table" and x ~= Y.null then
      local out = Y.list()
      for i, v in ipairs(x) do out[i] = follow(v, key) end
      return out
    end
    if type(x) == "string" then
      if refs[x] then return refs[x] end
      if place_names[x] then return place_names[x] end
    end
    return x
  end
  self.meta = follow(self.meta)
  for _, name in ipairs(Y.keys(self.places)) do
    self.places[name] = follow(self.places[name])
    local new = place_names[name]
    if new then
      self.places[new] = Y.remove(self.places, name)
      w3.fs.remove(self.path .. "\\places\\" .. name .. ".yml")
    end
    self:save_place(new or name)
  end
  self:save_meta()
  local said = {}
  for a, b in pairs(refs) do said[#said + 1] = a .. " -> " .. b end
  for a, b in pairs(place_names) do said[#said + 1] = a .. " -> " .. b end
  for a, b in pairs(facts) do said[#said + 1] = a .. " -> " .. b end
  log("[project] ids made readable for the game's tools: " .. table.concat(said, ", "))
end

-- --- the project browser's list (project.recent, examples, add_project, remember) ---
-- Conjunction's examples: beside the mod (deploy_mod copies the app's examples\ there)
P.EXAMPLES = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[\\/][^\\/]+$", "")) .. "\\examples"
local function key_of(path)                     -- os.path.normcase(os.path.abspath(p)): one way to compare paths
  return (PYS.lower(path):gsub("/", "\\"):gsub("\\+$", ""))
end
P.key_of = key_of
local function has_project(path) return w3.fs.exists(path .. "\\project.yml") end
function P.is_example(path)
  return key_of(PATHS.dirname(path)) == key_of(P.EXAMPLES)
end
-- the projects opened last (newest first) that still exist, then every other one in Documents\Conjunction and those
-- added from anywhere (newest first)
function P.recent()
  local CFG = require("conjunction.config")
  local cfg = CFG.load()
  local out, seen = {}, {}
  for _, path in ipairs(type(cfg.recent) == "table" and cfg.recent or {}) do
    if type(path) == "string" and has_project(path) and not P.is_example(path) then
      out[#out + 1] = path
      seen[key_of(path)] = true
    end
  end
  local others, in_others = {}, {}
  for _, e in ipairs(w3.fs.isdir(P.PROJECTS) and w3.fs.list(P.PROJECTS) or {}) do
    local path = P.PROJECTS .. "\\" .. e.name
    if has_project(path) and not seen[key_of(path)] then
      others[#others + 1] = path
      in_others[key_of(path)] = true
    end
  end
  for _, path in ipairs(type(cfg.projects_added) == "table" and cfg.projects_added or {}) do
    if type(path) == "string" and has_project(path) and not seen[key_of(path)] and not in_others[key_of(path)] then
      others[#others + 1] = path
    end
  end
  -- (sorted by the time of their project.yml, newest first; Python's sort keeps equals in their order)
  local t = {}
  for i, path in ipairs(others) do t[i] = {path, w3.fs.mtime(path .. "\\project.yml") or 0, i} end
  table.sort(t, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[3] < b[3] end)
  for _, x in ipairs(t) do out[#out + 1] = x[1] end
  return out
end
-- --- the runs of Build & Play: <project>\versions\<quest id of a run>\{dlc, mod, project}
P.VERSIONS, P.KEEP_VERSIONS = "versions", 5

-- the project's files as this run was built (to go back to it later) -> versions\<qid>\project
function P.snapshot(project_path, qid)
  local FS = require("conjunction.fsutil")
  local dst = project_path .. "\\" .. P.VERSIONS .. "\\" .. qid .. "\\project"
  if w3.fs.isdir(dst) then FS.rmtree(dst) end
  local skip = {build = true, [P.VERSIONS] = true, ["wcc.log"] = true, __pycache__ = true}
  for _, d in ipairs({project_path .. "\\" .. P.VERSIONS, project_path .. "\\" .. P.VERSIONS .. "\\" .. qid}) do
    if not w3.fs.isdir(d) then w3.fs.mkdir(d) end
  end
  FS.copytree(project_path, dst, function(name) return skip[name] end)
  P.prune_versions(project_path)
end

-- a run's DLC (part "dlc") or mod bundle ("mod") out of root into versions\<its quest id>\<part>
function P.park_run(project_path, root, name, part)
  local FS = require("conjunction.fsutil")
  local qid = part == "dlc" and name:sub(4) or name:sub(7)          -- dlc<qid> / moddlc<qid>
  local dst = project_path .. "\\" .. P.VERSIONS .. "\\" .. qid .. "\\" .. part
  if w3.fs.isdir(dst) then FS.rmtree(dst) end
  for _, d in ipairs({project_path .. "\\" .. P.VERSIONS, project_path .. "\\" .. P.VERSIONS .. "\\" .. qid}) do
    if not w3.fs.isdir(d) then w3.fs.mkdir(d) end
  end
  local src = root .. "\\" .. name
  if not w3.fs.rename(src, dst) then                -- (shutil.move: another drive - a copy, then the original goes)
    FS.copytree(src, dst)
    FS.rmtree(src)
  end
end

-- only the newest KEEP_VERSIONS runs stay (by the run's number: a run parked just now is not the newest)
function P.prune_versions(project_path)
  local FS = require("conjunction.fsutil")
  local d = project_path .. "\\" .. P.VERSIONS
  local runs = {}
  for _, e in ipairs(w3.fs.isdir(d) and w3.fs.list(d) or {}) do
    if e.dir then
      local n = e.name:match("r(%d+)$")
      runs[#runs + 1] = {d .. "\\" .. e.name, n and math.tointeger(tonumber(n)) or -1, #runs + 1}
    end
  end
  table.sort(runs, function(a, b)                   -- (sorted(..., reverse=True) keeps equals in their order)
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[3] < b[3]
  end)
  for k = P.KEEP_VERSIONS + 1, #runs do FS.rmtree(runs[k][1]) end
end

-- {{name, path}} of the examples
function P.examples()
  local out = {}
  local names = {}
  for _, e in ipairs(w3.fs.isdir(P.EXAMPLES) and w3.fs.list(P.EXAMPLES) or {}) do names[#names + 1] = e.name end
  table.sort(names)
  for _, name in ipairs(names) do
    local path = P.EXAMPLES .. "\\" .. name
    if has_project(path) then
      local ok, meta = pcall(Y.read, path .. "\\project.yml")
      local n = ok and type(meta) == "table" and meta.name
      out[#out + 1] = {(type(n) == "string" and n ~= "") and n or name, path}
    end
  end
  return out
end
-- a project from anywhere into the browser's list (its folder or its project.yml) -> its folder, or nil
function P.add_project(path)
  local folder = PYS.lower(PATHS.basename(path)) == "project.yml" and PATHS.dirname(path) or path
  if not has_project(folder) then return nil end
  local CFG = require("conjunction.config")
  local cfg = CFG.load()
  local added = Y.list({folder})
  for _, x in ipairs(type(cfg.projects_added) == "table" and cfg.projects_added or {}) do
    if key_of(x) ~= key_of(folder) then added[#added + 1] = x end
  end
  cfg.projects_added = added
  CFG.save(cfg)
  return folder
end
-- opened: first in the list (an example's copy is what was opened, not the example)
function P.remember(path)
  if P.is_example(path) then return end
  local CFG = require("conjunction.config")
  local cfg = CFG.load()
  local list = Y.list({path})
  for _, x in ipairs(type(cfg.recent) == "table" and cfg.recent or {}) do
    if x ~= path and #list < 10 then list[#list + 1] = x end
  end
  cfg.recent = list
  CFG.save(cfg)
end
-- Documents\Conjunction\<slug>, or <slug>2, 3 ... when taken (keep: the project's own folder counts as free)
function P.free_folder(slug, keep)
  local path, n = P.PROJECTS .. "\\" .. slug, 2
  while w3.fs.exists(path) and not (keep and key_of(path) == key_of(keep)) do
    path, n = P.PROJECTS .. "\\" .. slug .. n, n + 1
  end
  return path
end
-- project.rename: a new name. Never built yet: its id and its folder follow the name (MaximdeWinter 04.10.: a typo in the
-- name stayed in the id); once built they stay - the game knows the quest by its id, a new one would leave the old
-- DLC in it. -> the project's path (moved or not)
function P.rename(project, name)
  name = P.strip((tostring(name):gsub("%s+", " ")))
  local old = project.meta.name
  if name == "" or name == old then return project.path end
  project.meta.name = name
  local quest = project.meta.quest
  if Y.is_map(quest) and (quest.title == nil or quest.title == Y.null or quest.title == "" or quest.title == old) then
    quest.title = name                          -- (the journal's title went with the name: it still does)
  end
  local built = w3.fs.isdir(project.path .. "\\build")
  local inside = key_of(project.path:gsub("[\\/][^\\/]*$", "")) == key_of(P.PROJECTS)
  if not built and inside then
    local target = P.free_folder(P.slug_of(name), project.path)
    local tail = NUM.str(project.meta.id):sub(-4)
    project.meta.id = target:match("([^\\/]+)$") .. tail
    if key_of(target) ~= key_of(project.path) then
      local ok, err = w3.fs.rename(project.path, target)
      if not ok then error("OSError: " .. tostring(err), 0) end
      local CFG = require("conjunction.config")
      local cfg = CFG.load()
      local list = Y.list({})
      for _, p in ipairs(type(cfg.recent) == "table" and cfg.recent or {}) do
        list[#list + 1] = key_of(p) == key_of(project.path) and target or p
      end
      cfg.recent = list
      CFG.save(cfg)
      project.path = target
    end
  end
  project:save_meta()
  return project.path
end
-- Project.create: the folder, project.yml (id, name, description; a place mod says so), signed (the maker's mark
-- and the history's first step: never in the way of the work)
function P.create(path, pid, name, description, kind)
  if not w3.fs.isdir(path .. "\\places") then w3.fs.mkdir(path .. "\\places") end
  local meta = Y.map({"id", pid, "name", name, "description", description or ""})
  if kind == "place" then meta.kind = "place" end
  local text = Y.dump(meta, {sort_keys = false})
  assert(w3.fs.write(path .. "\\project.yml", (text:gsub("\n", "\r\n"))))   -- (Python's text mode: CRLF)
  local pr = P.open(path)
  local ok, err = pcall(function()
    require("conjunction.marks").ensure(pr)
    require("conjunction.provenance").note_safely(path, "edit")
  end)
  if not ok then print("[project] mark / history: " .. tostring(err)) end
  return pr
end
-- a new, empty project named name (its folder from the name, its id the folder's name and a random tail)
function P.new_project(name, kind)
  local path = P.free_folder(P.slug_of(name))
  local tail = require("conjunction.marks").uuid4_hex():sub(1, 4)
  P.create(path, (path:match("([^\\/]+)$")) .. tail, name, "", kind or "quest")
  return path
end

-- when a project changed last (project_browser.when): its project.yml's time, as the app shows it
function P.when(path)
  local t = w3.fs.mtime(path .. "\\project.yml")
  return t and os.date("%d.%m.%Y %H:%M", math.floor(t)) or ""
end

return P
