-- The content packs in the game (conjunction/content.py, the part the catalog needs): the folders the game loads
-- content from, the packs marked in them (conjunction_pack.yml) or registered as cards (<id>.pack.yml with `detect`),
-- a pack's table of contents, what a quest uses and where it comes from (Origins, needs, manifest_packs).
local R = require("conjunction.pyre")
local S = require("conjunction.pystr")
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local CFG = require("conjunction.config")
local NUM = require("conjunction.pynum")
local PATHS = require("conjunction.paths")
local C = {}

C.MARKER = "conjunction_pack.yml"
C.INDEX = "conjunction_index.json"
-- the game's own depot paths (base game, expansions, free DLCs): everything else under dlc\ is a mod's
C.VANILLA_FILE = R.compile([[^(?!dlc\\)|^dlc\\(ep1|bob|dlc\d+)\\]])
-- the game's item definitions (gameplay\items*\*.xml)
C.ITEM_XML = R.compile([[(^|\\)gameplay\\items[^\\]*\\[^\\]*\.xml$]])

local function fs() return w3.fs end
local function game_of(game) return game or CFG.load().game or "" end
local function isfile(p) return fs().exists(p) and not fs().isdir(p) end

-- (kind, name, path) of every place the game loads content from: the game itself, each DLC, each mod
function C.folders(game)
  game = game_of(game)
  local out = {{"game", "", PATHS.join(game, "content")}}
  for _, ks in ipairs({{"dlc", "dlc"}, {"mods", "Mods"}}) do
    local root = PATHS.join(game, ks[2])
    if fs().isdir(root) then
      for _, e in ipairs(fs().list(root) or {}) do        -- (sorted by name, as sorted(os.listdir()))
        if e.dir then out[#out + 1] = {ks[1], e.name, PATHS.join(root, e.name)} end
      end
    end
  end
  return out
end

function C.read_pack_meta(path)
  local meta = Y.read(path)
  if meta == nil or meta == Y.null or meta == false or (type(meta) == "table" and next(meta) == nil) then
    meta = Y.map()
  end
  local id = meta.id
  if id == nil or id == Y.null or id == false or id == "" or id == 0 then id = "" end
  meta.id = S.lower(S.strip(NUM.str(id)))
  return meta
end

-- dict(meta, key=value ...): a copy with the keys after its own
local function with(meta, ...)
  local out = Y.map()
  for _, k in ipairs(Y.keys(meta)) do out[k] = meta[k] end
  local kv = {...}
  for i = 1, #kv, 2 do out[kv[i]] = kv[i + 1] end
  return out
end

local FOLDER_SPLIT = R.compile([[[\\/]+]])
-- 'dlc/dlcfurniture/content/blob0.bundle' -> 'dlc/dlcfurniture'
function C.folder_key(rel)
  local parts = FOLDER_SPLIT:split(S.strip(NUM.str(rel), "\\/"))
  if #parts >= 2 and (S.lower(parts[1]) == "dlc" or S.lower(parts[1]) == "mods") then
    return S.lower(parts[1]) .. "/" .. parts[2]
  end
  return nil
end

-- a registered mod is there when all its detect paths (relative to the game folder) exist
function C.detected(card, game)
  game = game_of(game)
  local paths = card.detect
  if paths == nil or paths == Y.null or type(paths) ~= "table" or next(paths) == nil then return false end
  for _, p in ipairs(paths) do
    local full = game
    for _, part in ipairs(FOLDER_SPLIT:split(p)) do full = PATHS.join(full, part) end
    if not fs().exists(full) then return false end
  end
  return true
end

-- contentpacks.pack_dirs: the app's packs (the mod's folder here), Documents\conjunction\packs, the config's
function C.card_dirs()
  local cfg = CFG.load()
  local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[\\/][^\\/]*$", "")
  local home = PATHS.HOME .. "\\packs"
  local dirs = {PATHS.join(here, "packs"), home}
  for _, d in ipairs(Y.is_list(cfg.pack_dirs) and cfg.pack_dirs or {}) do dirs[#dirs + 1] = d end
  local out = {}
  for _, d in ipairs(dirs) do
    if fs().isdir(d) then out[#out + 1] = d end
  end
  return out
end

function C.pack_cards()
  local out = {}
  for _, d in ipairs(C.card_dirs()) do
    for _, e in ipairs(fs().list(d) or {}) do
      local f = e.name
      if f:sub(-9) == ".pack.yml" then
        local ok, meta = pcall(C.read_pack_meta, PATHS.join(d, f))
        if ok and meta.id ~= "" then
          out[#out + 1] = with(meta, "index", PATHS.join(d, f:sub(1, -10) .. ".index.json"))
        end
      end
    end
  end
  return out
end

-- every content pack this game has: marker files in its DLC and mod folders, then registered mods whose files are
-- there. Each: its card's fields, folders = {"dlc/x" ...}, index (the file of its table of contents)
function C.installed_packs(game)
  game = game_of(game)
  local out, seen = {}, {}
  for _, f in ipairs(C.folders(game)) do
    local kind, name, path = f[1], f[2], f[3]
    if kind ~= "game" then
      local marker = PATHS.join(path, C.MARKER)
      if isfile(marker) then
        local ok, meta = pcall(C.read_pack_meta, marker)
        if ok and meta.id ~= "" then
          local key = kind .. "/" .. name
          if seen[meta.id] then
            for _, p in ipairs(out) do
              if p.id == meta.id then p.folders[#p.folders + 1] = key break end
            end
          else
            seen[meta.id] = true
            out[#out + 1] = with(meta, "folders", Y.list({key}), "index", PATHS.join(path, C.INDEX))
          end
        end
      end
    end
  end
  for _, card in ipairs(C.pack_cards()) do
    if not seen[card.id] and C.detected(card, game) then
      seen[card.id] = true
      local folders = Y.list({})
      for _, d in ipairs(Y.is_list(card.detect) and card.detect or {}) do
        local k = C.folder_key(d)
        if k then folders[#folders + 1] = k end
      end
      out[#out + 1] = with(card, "folders", folders)
    end
  end
  return out
end

-- {"templates": {row ...}, "items": {row ...}} of an installed pack (empty when it has none)
function C.pack_index(pack)
  local ok, data = pcall(J.read, pack.index or "")
  if ok and type(data) == "table" then return data end
  return Y.map({"templates", Y.list({}), "items", Y.list({})})
end

-- library._ver: "1.10" -> {1, 10} (a part that is no number: 0), compared as Python compares tuples
function C.ver(v)
  local out = {}
  for part in (tostring(v == nil and "" or v) .. "."):gmatch("(.-)%.") do
    out[#out + 1] = part:match("^%d+$") and tonumber(part) or 0
  end
  return out
end
function C.ver_less(a, b)
  for i = 1, math.min(#a, #b) do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  return #a < #b
end
local function pystr_of(v)
  if v == nil or v == Y.null then return "None" end
  if v == true then return "True" elseif v == false then return "False" end
  return NUM.str(v)
end

-- the packs of a quest's manifest this game lacks -> {need + why} (why: "missing" or "old: <installed version>")
function C.missing_packs(manifest, game)
  game = game_of(game)
  local have = {}
  for _, p in ipairs(C.installed_packs(game)) do have[p.id] = p end
  for _, p in ipairs(require("conjunction.contentpacks").packs()) do    -- (folder packs: voices, samples)
    if have[p.id] == nil then have[p.id] = {id = p.id, name = p.name, version = p.version} end
  end
  local out = {}
  local packs = type(manifest) == "table" and manifest.packs
  for _, need in ipairs(type(packs) == "table" and packs or {}) do
    local pid = S.lower(pystr_of(need.id ~= nil and need.id or ""))
    local p = have[pid]
    local detect = need.detect
    if p == nil and detect ~= nil and detect ~= Y.null and detect ~= false and C.detected(need, game) then
      p = {id = pid, version = need.version ~= nil and need.version or "0"}      -- (a registered mod's files)
    end
    local function with_why(why)
      local d = Y.map({})
      for _, k in ipairs(Y.keys(need)) do d[k] = need[k] end
      d.why = why
      return d
    end
    if p == nil then
      out[#out + 1] = with_why("missing")
    else
      local pv = p.version ~= nil and p.version or "0"
      local nv = need.version ~= nil and need.version or "0"
      if C.ver_less(C.ver(pystr_of(pv)), C.ver(pystr_of(nv))) then
        out[#out + 1] = with_why("old: " .. pystr_of(p.version))
      end
    end
  end
  return out
end

-- --- where a template, an item, a loot table comes from (content.Origins): the game's own first, then each DLC and
-- mod in the game's order. Read from the app's cache of the bundles (data\origins.json, a bundle's names while its
-- size and time are the same); the remaster's item files outside the bundles from the asset database.
C.ORIGINS = PATHS.DATA .. "\\origins.json"
C.ORIGINS_VERSION = 2
C.SUITE_DLCS = {dlcconjunctionmeshes = true, dlcconjunctionfoliage = true}
local Origins = {}
Origins.__index = Origins

function C.Origins(game)
  local self = setmetatable({game = game_of(game), templates = {}, items = {}, loot = {}, folder_paths = {}}, Origins)
  local ok, cache = pcall(J.read, C.ORIGINS)
  if not ok or type(cache) ~= "table" or cache.version ~= C.ORIGINS_VERSION then cache = {} end
  local bundles = cache.bundles or {}
  local by_folder = {}
  for path in pairs(bundles) do by_folder[#by_folder + 1] = path end
  table.sort(by_folder)
  for _, f in ipairs(C.folders(self.game)) do
    local kind, name, path = f[1], f[2], f[3]
    local key = kind == "game" and "game" or (kind .. "/" .. name)
    self.folder_paths[key] = path
    local lead = S.lower(path) .. "\\"
    for _, b in ipairs(by_folder) do
      if S.lower(b):sub(1, #lead) == lead then
        local data = bundles[b]
        local stamp = data.stamp or {}
        local size, mtime = fs().size(b), fs().mtime(b)
        if size ~= nil and stamp[1] == size and stamp[2] == math.floor(tonumber(mtime) or -1) then
          for _, p in ipairs(data.w2ent or {}) do if self.templates[p] == nil then self.templates[p] = key end end
          for _, n in ipairs(data.items or {}) do if self.items[n] == nil then self.items[n] = key end end
          for _, n in ipairs(data.loot or {}) do if self.loot[n] == nil then self.loot[n] = key end end
        end
      end
    end
  end
  -- no cache of the app's (the game's Conjunction never writes one): each template's first bundle from cj_core's
  -- depot index, its folder the one that bundle lies in (the game's own first, as the bundles load)
  if next(bundles) == nil then
    pcall(function()
      local d = require("conjunction.depot").open(self.game)
      local roots = {}
      for key, path in pairs(self.folder_paths) do roots[#roots + 1] = {S.lower(path) .. "\\", key} end
      table.sort(roots, function(x, y) return #x[1] > #y[1] end)        -- (the longest path first: a DLC in a mod)
      local of_bundle = {}
      for _, row in ipairs(d:glob_where("", ".w2ent")) do
        local p, b = row[1], row[2]
        local key = of_bundle[b]
        if key == nil then
          local low = S.lower(b)
          key = false
          for _, r in ipairs(roots) do if low:sub(1, #r[1]) == r[1] then key = r[2] break end end
          of_bundle[b] = key
        end
        if key and self.templates[p] == nil then self.templates[p] = key end
      end
    end)
  end
  pcall(function()                               -- the remaster's item definitions outside the bundles
    local DB = require("conjunction.db")
    local db = DB.open(require("conjunction.assets").DB, false)
    local rows = db:rows("select name, file from items")
    local loot = db:rows("select name, file from loot")
    db:close()
    for _, tr in ipairs({{self.items, rows}, {self.loot, loot}}) do
      for _, r in ipairs(tr[2]) do
        if C.VANILLA_FILE:match(S.lower(tostring(r[2]))) and tr[1][r[1]] == nil then tr[1][r[1]] = "game" end
      end
    end
  end)
  self.packs = C.installed_packs(self.game)
  self.pack_of_folder = {}
  for _, p in ipairs(self.packs) do
    for _, f in ipairs(p.folders or {}) do self.pack_of_folder[f] = p.id end
  end
  return self
end

function Origins:_origin(folder)
  if folder == nil then return nil end
  if folder == "game" then return "game" end
  local rest = folder:match("^[^/]*/(.*)$") or ""
  if C.SUITE_DLCS[S.lower(rest)] then return "suite" end
  if self.pack_of_folder[folder] then return "pack:" .. self.pack_of_folder[folder] end
  return "mod:" .. folder
end
function Origins:template(path) return self:_origin(self.templates[S.lower(tostring(path))]) end
function Origins:item(name) return self:_origin(self.items[tostring(name)]) end
function Origins:loot_table(name) return self:_origin(self.loot[tostring(name)]) end
function Origins:pack(pid)
  for _, p in ipairs(self.packs or {}) do if p.id == pid then return p end end
  return nil
end

-- --- what a quest takes from mods (the export's manifest)
C.KIND = {templates = "template", items = "item", loot = "loot table"}
local P_ = require("conjunction.py")

-- {templates = {path = {where}}, items = {name = {where}}, loot = {name = {where}}} - every thing of the game (or of
-- a pack) the project names: its places' objects and its quest (its own items left out)
function C.refs(project)
  local out = {templates = Y.map(), items = Y.map(), loot = Y.map()}
  local function add(kind, value, where)
    if type(value) == "string" and value ~= "" and value:sub(1, 4) ~= "own:" then
      local k = kind ~= "templates" and value or S.lower(value)
      local list = out[kind][k]
      if list == nil then list = {} out[kind][k] = list end
      list[#list + 1] = where
    end
  end
  local walk
  walk = function(x, where)
    if Y.is_map(x) then
      for k, v in pairs(x) do
        if type(v) == "string" and S.lower(v):sub(-6) == ".w2ent" then add("templates", v, where)
        elseif k == "item" or k == "hold" then add("items", v, where)
        elseif k == "items" and type(v) == "table" and not Y.is_map(v) and v ~= Y.null then
          for _, i in ipairs(v) do
            if Y.is_map(i) then walk(i, where) else add("items", i, where) end
          end
        elseif (k == "loot" or k == "loot_table") and type(v) == "string" then add("loot", v, where)
        else walk(v, where) end
      end
    elseif type(x) == "table" and x ~= Y.null then
      for _, v in ipairs(x) do walk(v, where) end
    end
  end
  for _, pname in ipairs(Y.keys(project.places)) do
    for _, o in ipairs(P_.list(P_.get(project.places[pname], "objects"))) do
      walk(o, pname .. "/" .. P_.str(P_.get(o, "id", "?")))
    end
  end
  local q = Y.map()
  for k, v in pairs(P_.map(P_.get(project.meta, "quest"))) do if k ~= "items" then q[k] = v end end
  walk(q, "quest")
  return out
end

local function own_template(project, ref)
  local id = S.lower(P_.str(project:id()))
  local low = S.lower(ref)
  return low:sub(1, #("dlc\\" .. id .. "\\")) == "dlc\\" .. id .. "\\" or low:sub(1, #("dlc\\dlc" .. id)) == "dlc\\dlc" .. id
end
function C.short(ref)
  local base = ref:match("([^\\/]*)$")
  base = base:match("^(.*)%.[^.]*$") or base
  return (base:gsub("_", " "))
end

-- what the quest uses that the game does not have -> {packs = Y.map {id = entry}, mods = Y.map {folder = {{kind, ref}}},
-- missing = {ref}}; labels(kind, ref): a thing's readable name
function C.needs(project, origins, labels)
  local o = origins or C.Origins(game_of())
  local r = C.refs(project)
  local out = {packs = Y.map(), mods = Y.map(), missing = {}}
  local get = {templates = function(x) return o:template(x) end, items = function(x) return o:item(x) end,
               loot = function(x) return o:loot_table(x) end}
  for _, kind in ipairs({"templates", "items", "loot"}) do
    local refs = Y.keys(r[kind])
    table.sort(refs)
    for _, ref in ipairs(refs) do
      local origin = get[kind](ref)
      if origin == "game" or origin == "suite" or origin == "own" then
        -- (the game's own)
      elseif origin == nil then
        if not (kind == "templates" and own_template(project, ref)) then out.missing[#out.missing + 1] = ref end
      elseif origin:sub(1, 5) == "pack:" then
        local pid = origin:sub(6)
        local p = o:pack(pid) or {id = pid}
        local entry = out.packs[pid]
        if entry == nil then
          local detect = Y.list({})
          for _, d in ipairs(P_.list(P_.get(p, "detect"))) do detect[#detect + 1] = d end
          if #detect == 0 then
            for _, f in ipairs(P_.list(P_.get(p, "folders"))) do detect[#detect + 1] = f .. "/" .. C.MARKER end
          end
          entry = Y.map({"id", pid, "name", P_.get(p, "name", pid), "author", P_.get(p, "author", ""),
                         "version", P_.str(P_.get(p, "version", "1")), "url", P_.get(p, "url", ""), "detect", detect,
                         "used", Y.list({})})
          out.packs[pid] = entry
        end
        entry.used[#entry.used + 1] = Y.map({"ref", ref, "kind", C.KIND[kind],
                                             "name", (labels and labels(kind, ref)) or C.short(ref)})
      else
        local folder = origin:sub(5)
        local list = out.mods[folder]
        if list == nil then list = {} out.mods[folder] = list end
        list[#list + 1] = {kind, ref}
      end
    end
  end
  return out
end

C.KNOWN = PATHS.DATA .. "\\known_mods.json"
-- what the author told this Conjunction about mods without a marker: {"dlc/dlcfoo" = {name, version, url}}
function C.known_mods()
  local ok, k = pcall(J.read, C.KNOWN)
  if ok and type(k) == "table" and k ~= Y.null then return k end
  return Y.map()
end
function C.remember_mod(folder, name, version, url)
  local k = C.known_mods()
  k[folder] = Y.map({"name", S.strip(name or ""), "version", S.strip(P_.str(version or "")), "url", S.strip(url or "")})
  if os.getenv("CJ_REF") == "1" then return end   -- (a check never writes the user's data)
  J.write(C.KNOWN .. ".tmp", k, {indent = 1})
  if fs().exists(C.KNOWN) then fs().remove(C.KNOWN) end
  fs().rename(C.KNOWN .. ".tmp", C.KNOWN)
end

-- a mod without a marker as a manifest pack: known by its folder (dlc/<x> or mods/<x>)
function C.mod_entry(folder, things, labels)
  local k = P_.map(C.known_mods()[folder])
  local kind, name = folder:match("^([^/]*)/(.*)$")
  local used = Y.list({})
  for _, t in ipairs(things) do
    used[#used + 1] = Y.map({"ref", t[2], "kind", C.KIND[t[1]], "name", (labels and labels(t[1], t[2])) or C.short(t[2])})
  end
  return Y.map({"id", "mod-" .. S.lower(name):gsub("[^a-z0-9_]+", "_"), "name", P_.or_(P_.get(k, "name"), name),
                "author", "", "version", P_.get(k, "version", ""), "url", P_.get(k, "url", ""),
                "detect", Y.list({(kind == "dlc" and "dlc/" or "Mods/") .. name}), "folder", folder, "used", used})
end

-- the manifest's packs (every mod the quest takes something from) and what was found nowhere here
function C.manifest_packs(project, origins, labels)
  local n = C.needs(project, origins, labels)
  local packs = Y.list({})
  for _, v in pairs(n.packs) do packs[#packs + 1] = v end
  local folders = Y.keys(n.mods)
  table.sort(folders)
  for _, f in ipairs(folders) do packs[#packs + 1] = C.mod_entry(f, n.mods[f], labels) end
  return packs, n.missing
end

-- labels(kind, ref): the catalog's name of a template / item (nil when the database is not there)
function C.labeler(assets)
  local a = assets
  if a == nil then
    pcall(function()
      local A = require("conjunction.assets")
      if A.ready() then a = A.new() end
    end)
  end
  local pack_names = {}
  for _, p in ipairs(C.installed_packs()) do
    local idx = C.pack_index(p)
    for _, r in ipairs(P_.list(P_.get(idx, "templates"))) do pack_names["templates|" .. S.lower(P_.get(r, "path", ""))] = P_.get(r, "name") end
    for _, r in ipairs(P_.list(P_.get(idx, "items"))) do pack_names["items|" .. P_.str(P_.get(r, "name"))] = P_.get(r, "label") end
  end
  return function(kind, ref)
    local key = kind .. "|" .. ref
    if pack_names[key] ~= nil then return pack_names[key] end
    if a == nil then return nil end
    if kind == "templates" then
      local t = a:template(ref)
      return t and P_.get(t, "name")
    end
    if kind == "items" then
      local it = a:item(ref)
      return it and P_.or_(P_.get(it, "label"), P_.get(it, "name"))
    end
    return nil
  end
end

return C
