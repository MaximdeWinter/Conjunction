-- The asset database for the editor (conjunction/assets.py's Assets): searching templates and items with their facets,
-- details, loot tables, pictures. The same database file the app builds (data\assets.sqlite), read through cj_core's
-- SQLite (db.lua): the same rows, the same full text scores, so the catalog shows the same things in the same order.
-- Checked against Python: ingame/ref/assets_check.py.
--
--   local A = ASSETS.new()                  (ASSETS.ready(): the database is there and of this version)
--   local rows, facets = A:browse(text, cat, sub, styles, traits, quest, limit)
--   A:browse_items(text, cat, sub, limit), A:loot_tables(text, limit), A:loot(name), A:items(text, limit)
--   A:template(path), A:item(name), A:thumbnail(path, size, meshes), A:icon(item)
-- facets: {tree = Counter of "cat\0sub", styles = Counter, traits = Counter, total = n}; a Counter keeps the order
-- its keys came in, as collections.Counter does: c.keys, c.n[key].
local DB = require("conjunction.db")
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local R = require("conjunction.pyre")
local S = require("conjunction.pystr")
local PS = require("conjunction.pysort")
local PATHS = require("conjunction.paths")
local CAT = require("conjunction.catalog")
local TAX = require("conjunction.taxonomy")
local CONTENT = require("conjunction.content")
local A = {}
A.__index = A

A.VERSION = 5
A.DB = PATHS.DATA .. "\\assets.sqlite"
A.THUMBS = PATHS.DATA .. "\\thumbs"
A.MESHES = PATHS.DATA .. "\\meshes.json"            -- meshlib.INDEX: mesh -> library template
A.DECALS = PATHS.DATA .. "\\decals.json"            -- meshlib.DECAL_INDEX: decal texture -> library template
A.FOLIAGE = PATHS.DATA .. "\\foliage.json"          -- foliage.INDEX: tree (.srt) -> library template
local CLUE_CLASSES = {W3MonsterClue = true, W3ClueCorpse = true}

-- Python's bool() of a database value (0, "", NULL are false)
local function truthy(v) return not (v == nil or v == false or v == Y.null or v == 0 or v == "" or v == 0.0) end

-- collections.Counter with its keys in the order they came
local Counter = {}
Counter.__index = Counter
function A.Counter() return setmetatable({keys = {}, n = {}}, Counter) end
function Counter:add(k, by)
  if self.n[k] == nil then self.keys[#self.keys + 1] = k self.n[k] = 0 end
  self.n[k] = self.n[k] + (by or 1)
end
function Counter:update(list) for _, k in ipairs(list) do self:add(k) end end
function Counter:get(k) return self.n[k] or 0 end

-- a row as a map by column name (db.lua's rows have the positions too)
local function as_map(r, cols)
  local m = {}
  for _, c in ipairs(cols) do m[c] = r[c] end
  return m
end

function A.ready()
  if not w3.fs.exists(A.DB) then return false end
  local ok, v = pcall(function()
    local db = DB.open(A.DB, false)
    local row = db:one("select value from meta where key='version'")
    db:close()
    return row
  end)
  return ok and v ~= nil and tonumber(v.value) == A.VERSION
end

-- A long read gives the frame back now and then in a coroutine that asked for it (A.sliced): the mesh library's rows
-- made anew (after an update of Conjunction or of a library: 37 000 meshes, 8 s on 12.11.) ran past TW3SE's 5 s for
-- a call in one frame, were stopped before they were kept, and so again at each opening of the panel
local slicers = setmetatable({}, {__mode = "k"})   -- coroutine -> when its slice began
local function breathe()
  local co = coroutine.running()
  local t = slicers[co]
  if t and os.clock() - t > 0.004 then
    coroutine.yield()
    slicers[co] = os.clock()
  end
end
-- fn() in the coroutine running now, a slice of 4 ms a resume (a job: editor.job, init's read ahead)
function A.sliced(fn)
  local co = coroutine.running()
  local before = slicers[co]
  slicers[co] = os.clock()
  local ok, err = pcall(fn)
  slicers[co] = before
  if not ok then error(err, 0) end
end

-- made while the game starts (init.lua, before the player is in the world, sliced): the assets with their rows in
-- memory and the people who can talk read; the panel's first opening takes them (25.10.: it read them then, 1.5 s of
-- its lag)
A.preloaded, A.preloading = nil, false
function A.preload()
  if A.preloaded or not A.ready() then return end
  A.preloading = true
  local ok, err = pcall(function()
    local a = A.new()
    a:_all()
    require("conjunction.talking").load()
    A.preloaded = a
  end)
  A.preloading = false
  if not ok then error(err, 0) end
end
function A.take_preloaded()
  local a = A.preloaded
  A.preloaded = nil
  return a
end

function A.new()
  local self = setmetatable({}, A)
  -- read into memory and let the file go: a rebuild can replace it while the editor runs
  self.db = DB.open(A.DB, true)
  self.memo = {}                                -- (one lookup's answer, kept: the copy in memory never changes)
  self.packs = self:_merge_packs()
  self.thumb_root = PATHS.join(require("conjunction.config").load().redkit or "", "r4data", "thumbnails")
  return self
end

local TPL_COLS = {"path", "name", "named", "kind", "class", "source", "quest", "inventory", "loot", "components",
                  "appearances", "meshes", "tags", "grp", "thumb", "cat", "sub", "styles", "traits", "loot_defs"}
local ITEM_COLS = {"name", "label", "descr", "category", "tags", "price", "weight", "icon", "equip_template",
                   "stackable", "file", "cat", "sub"}
local function get(r, k, default)
  local v = r[k]
  if v == nil then return default end
  return v
end
local function str(v) return require("conjunction.pynum").str(v) end

-- the content packs in the game join the catalog from their table of contents
function A:_merge_packs()
  local ok, packs = pcall(CONTENT.installed_packs)
  if not ok then return {} end
  local qs = {}
  for i = 1, #TPL_COLS do qs[i] = "?" end
  local iqs = {}
  for i = 1, #ITEM_COLS do iqs[i] = "?" end
  for _, p in ipairs(packs) do
    local idx = CONTENT.pack_index(p)
    local pname = truthy(p.name) and p.name or p.id
    for _, r0 in ipairs(Y.is_list(idx.templates) and idx.templates or {}) do
      local traits = {}
      local tv = r0.traits
      if not truthy(tv) then tv = "" end
      for _, t in ipairs(S.split(str(tv))) do traits[t] = true end
      traits.pack = true
      local tl = {}
      for t in pairs(traits) do tl[#tl + 1] = t end
      PS.sort(tl)
      local vals = {}
      for i, c in ipairs(TPL_COLS) do
        if c == "source" then vals[i] = pname
        elseif c == "traits" then vals[i] = table.concat(tl, " ")
        else vals[i] = get(r0, c, "") end
      end
      self.db:exec("insert or replace into templates values (" .. table.concat(qs, ",") .. ")", table.unpack(vals))
      self.db:exec("delete from template_search where path = ?", r0.path)
      local words = table.concat({get(r0, "cat", ""), get(r0, "sub", ""), get(r0, "kind", ""), get(r0, "class", ""),
                                  get(r0, "tags", ""), pname, (r0.path:gsub("\\", " "):gsub("_", " "))}, " ")
      self.db:exec("insert into template_search values (?,?,?)", r0.path, get(r0, "name", ""), words)
    end
    for _, r0 in ipairs(Y.is_list(idx.items) and idx.items or {}) do
      local label = truthy(r0.label) and r0.label or r0.name
      local vals = {}
      for i, c in ipairs(ITEM_COLS) do
        if c == "label" then vals[i] = label else vals[i] = get(r0, c, "") end
      end
      self.db:exec("insert or replace into items values (" .. table.concat(iqs, ",") .. ")", table.unpack(vals))
      self.db:exec("delete from item_search where name = ?", r0.name)
      self.db:exec("insert into item_search values (?,?,?)", r0.name, label,
                   table.concat({r0.name, get(r0, "cat", ""), get(r0, "sub", ""),
                                 (str(get(r0, "category", "")):gsub("_", " ")), str(get(r0, "tags", "")), pname}, " "))
    end
  end
  return packs
end

-- --- browsing: the rows in memory, filtered and counted per keystroke ---
function A:_all()
  if self._rows == nil then
    self._rows = {}
    local rows, cols = self.db:rows("select * from templates")
    for _, r0 in ipairs(rows) do
      local r = as_map(r0, cols)
      local sty = {}
      for _, x in ipairs(S.split(truthy(r.styles) and r.styles or "")) do sty[#sty + 1] = (x:gsub("_", " ")) end
      r.styles = sty
      r.traits = S.split(truthy(r.traits) and r.traits or "")
      if r.sub == "Trees & plants" then r.sub = "Plants & logs" end   -- (a database built before 04.10.)
      if CLUE_CLASSES[r.class] then r.traits[#r.traits + 1] = "clue" end
      if (truthy(r.components) and r.components or ""):find("CR4InteriorAreaComponent", 1, true) then
        r.traits[#r.traits + 1] = "interior"
      end
      for _, t in ipairs(r.traits) do                -- (a content pack's: under its own branch of Content packs)
        if t == "pack" then
          r.own_cat, r.own_sub = r.cat, r.sub       -- (what it is: a person keeps their looks)
          r.cat, r.sub = TAX.PACKS, tostring(r.source)
          break
        end
      end
      self._rows[#self._rows + 1] = r
      breathe()
    end
    for _, r in ipairs(self:_mesh_rows()) do self._rows[#self._rows + 1] = r end
  end
  return self._rows
end

local function index_of(path)
  if not w3.fs.exists(path) then return Y.map() end
  local ok, d = pcall(J.read, path)
  if ok and type(d) == "table" then return d end
  return Y.map()
end
A.mesh_index, A.decal_index, A.foliage_index = function() return index_of(A.MESHES) end,
  function() return index_of(A.DECALS) end, function() return index_of(A.FOLIAGE) end

-- the mesh library's rows, kept in a file beside the database (made anew when the library, the database or the
-- sorting rules changed: the stamps of those files are its key)
local HERE = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[\\/][^\\/]*$", "")
function A:_mesh_rows()
  local function stamp(f) return w3.fs.exists(f) and w3.fs.mtime(f) or 0 end
  local key = {}
  for _, f in ipairs({A.MESHES, A.DECALS, A.FOLIAGE, A.DB, HERE .. "\\taxonomy.lua", HERE .. "\\catalog.lua",
                      HERE .. "\\assets.lua", HERE .. "\\pyre.lua", HERE .. "\\foliage.lua"}) do
    key[#key + 1] = string.format("%.17g", stamp(f))
  end
  key = table.concat(key, " ")
  local cache = PATHS.DATA .. "\\mesh_rows.lua"     -- (Lua source: load() reads it far faster than JSON)
  if w3.fs.exists(cache) then
    local src = w3.fs.read(cache)
    local chunk = src and load(src, "=mesh_rows", "t", {})
    if chunk then
      local ok, kept_key, rows = pcall(chunk)
      if ok and kept_key == key then return rows end
    end
  end
  local rows = self:_mesh_rows_made()
  local out = {"return ", string.format("%q", key), ", {\n"}
  local FIELDS = {"path", "mesh", "decal", "tree", "name", "named", "kind", "class", "source", "quest", "inventory",
                  "loot", "components", "appearances", "meshes", "tags", "grp", "thumb", "cat", "sub", "words"}
  for _, r in ipairs(rows) do
    out[#out + 1] = "{"
    for _, f in ipairs(FIELDS) do
      local v = r[f]
      if v ~= nil then out[#out + 1] = f .. "=" .. (type(v) == "string" and string.format("%q", v) or tostring(v)) .. "," end
    end
    local function list(name, l)
      out[#out + 1] = name .. "={"
      for _, x in ipairs(l) do out[#out + 1] = string.format("%q", x) .. "," end
      out[#out + 1] = "},"
    end
    list("styles", r.styles)
    list("traits", r.traits)
    out[#out + 1] = "},\n"
  end
  out[#out + 1] = "}\n"
  pcall(w3.fs.write, cache, table.concat(out))
  return rows
end

local function sorted_words(text)
  local ws = {}
  for w in pairs(TAX.words(text)) do ws[#ws + 1] = w end
  PS.sort(ws)
  return table.concat(ws, " ")
end
local function lower_words(text)
  local out = {}
  for _, w in ipairs(S.split(text)) do out[#out + 1] = S.lower(w) end
  return table.concat(out, " ")
end
-- foliage.group: the catalog group of a tree from its folder and name
local FOLIAGE_GROUPS = {{"\\underwater\\", "Underwater plants"}, {"\\vegetables\\", "Crops"}, {"\\vineyard\\", "Crops"},
                        {"\\grass", "Grass"}, {"\\flowers\\", "Herbs & flowers"}, {"herbs", "Herbs & flowers"},
                        {"\\mushrooms", "Mushrooms"}, {"\\creeper\\", "Creepers"}, {"\\floating_plants\\", "Water plants"},
                        {"\\debris\\", "Debris"}, {"bush", "Bushes"}, {"shrub", "Bushes"}, {"\\trees\\", "Trees"}}
function A.foliage_group(tree)
  local p = S.lower(tree)
  for _, g in ipairs(FOLIAGE_GROUPS) do
    if p:find(g[1], 1, true) then return g[2] end
  end
  return "Plants"
end

-- the mesh library (walls, roofs, ruins ...), its decals and the foliage library as rows like templates
function A:_mesh_rows_made()
  local textured = {}
  for _, r in ipairs((self.db:rows("select path, textured from mesh_info"))) do textured[r[1]] = r[2] end
  local out = {}
  local mi = A.mesh_index()
  for _, mesh in ipairs(Y.keys(mi)) do
    local tpl = mi[mesh]
    local kind = CAT.kind_of(mesh)
    local cat, sub = TAX.classify(mesh, "", {}, kind, "", {mesh})
    local t = textured[mesh]
    if t == nil then t = 1 end
    if not truthy(t) then cat, sub = "Internal", "Internal" end
    local styles = TAX.styles(mesh)
    local name = CAT.caption(mesh)
    local quest = ("\\" .. mesh):find("\\quest", 1, true) ~= nil
    out[#out + 1] = {path = S.lower(tpl), mesh = mesh, name = name, named = 0, kind = kind, class = "mesh",
                     source = "Mesh library", quest = quest and 1 or 0, inventory = 0, loot = "[]",
                     components = "[]", appearances = "[]", meshes = J.encode(Y.list({mesh})), tags = "",
                     grp = CAT.group_of(mesh), thumb = 1, cat = cat, sub = sub, styles = styles,
                     traits = quest and {"quest"} or {},
                     words = " " .. sorted_words(table.concat({mesh, cat, sub, table.concat(styles, " ")}, " ")) ..
                             " " .. lower_words(cat .. " " .. sub)}
    breathe()
  end
  local di = A.decal_index()
  for _, tex in ipairs(Y.keys(di)) do
    local tpl = di[tex]
    out[#out + 1] = {path = S.lower(tpl), decal = tex, name = CAT.caption(tex) .. " (decal)", named = 0,
                     kind = "Decoration", class = "decal", source = "Mesh library",
                     quest = ("\\" .. tex):find("\\quest", 1, true) and 1 or 0, inventory = 0, loot = "[]",
                     components = J.encode(Y.list({"CDecalComponent"})), appearances = "[]", meshes = "[]",
                     tags = "decal", grp = CAT.group_of(tex), thumb = 1, cat = "Decoration", sub = "Decals",
                     styles = {}, traits = {}, words = " " .. sorted_words(tex .. " decal decoration decals")}
    breathe()
  end
  local fi = A.foliage_index()
  for _, tree in ipairs(Y.keys(fi)) do
    local tpl = fi[tree]
    local cat, sub = "Nature", A.foliage_group(tree)
    out[#out + 1] = {path = S.lower(tpl), tree = tree, name = CAT.caption(tree), named = 0, kind = "Plant",
                     class = "foliage", source = "Foliage library", quest = 0, inventory = 0, loot = "[]",
                     components = J.encode(Y.list({"CDynamicFoliageComponent"})), appearances = "[]",
                     meshes = "[]", tags = "foliage", grp = CAT.group_of(tree), thumb = 1, cat = cat, sub = sub,
                     styles = {}, traits = {},
                     words = " " .. sorted_words(table.concat({tree, cat, sub, "foliage tree"}, " ")) .. " " ..
                             lower_words(cat .. " " .. sub)}
    breathe()
  end
  return out
end

local WORD = R.compile([[\w+]])
-- user words -> an FTS5 query: every word, as a prefix ('gua' finds 'guard')
function A.fts(text)
  local q = {}
  for _, w in ipairs(WORD:findall(S.lower(text))) do q[#q + 1] = '"' .. w .. '"*' end
  return table.concat(q, " AND ")
end

function A:_scores(tbl, key, text)
  local q = A.fts(text)
  if q == "" then return nil end
  local out = {}
  for _, r in ipairs((self.db:rows(string.format("select %s, bm25(%s, 0, 8, 1) from %s where %s match ?", key, tbl,
                                                 tbl, tbl), q))) do
    out[r[1]] = r[2]
  end
  return out
end

local function has_all(set_list, need)       -- every one of `need` in the list
  for k in pairs(need) do
    local found = false
    for _, x in ipairs(set_list) do if x == k then found = true break end end
    if not found then return false end
  end
  return true
end
local function any_of(list, set)
  for _, x in ipairs(list) do if set[x] then return true end end
  return false
end

-- templates for the catalog: rows, facets (each choice counted with the other filters kept)
function A:browse(text, cat, sub, styles, traits, quest, limit)
  text, limit = text or "", limit or 400
  local scores = self:_scores("template_search", "path", text)
  local sty_set, tra_set = {}, {}
  local nsty = 0
  for _, s in ipairs(styles or {}) do if not sty_set[s] then sty_set[s] = true nsty = nsty + 1 end end
  for _, t in ipairs(traits or {}) do tra_set[t] = true end
  local tree, sty, tra = A.Counter(), A.Counter(), A.Counter()
  local out = {}
  local words = WORD:findall(S.lower(text))
  local has_cat, has_sub = cat ~= nil and cat ~= "", sub ~= nil and sub ~= ""
  for _, r in ipairs(self:_all()) do
    local skip = false
    if scores ~= nil then
      if r.words then                              -- a library mesh: every word must start one of its words
        for _, w in ipairs(words) do
          if not r.words:find(" " .. w, 1, true) then skip = true break end
        end
        if not skip then
          local n = 0
          local nm = " " .. S.lower(r.name)
          for _, w in ipairs(words) do if nm:find(" " .. w, 1, true) then n = n + 1 end end
          scores[r.path] = -2.0 * n
        end
      elseif scores[r.path] == nil then
        skip = true
      end
    end
    if not skip and truthy(r.quest) and not quest then skip = true end
    if not skip then
      local in_tree = (not has_cat or r.cat == cat) and (not has_sub or r.sub == sub) and
                      (has_cat or not TAX.HIDDEN_GROUPS[r.cat])
      local in_styles = nsty == 0 or any_of(r.styles, sty_set)
      local in_traits = has_all(r.traits, tra_set)
      if in_styles and in_traits then tree:add(r.cat .. "\0" .. r.sub) end
      if in_tree and in_traits then sty:update(r.styles) end
      if in_tree and in_styles then tra:update(r.traits) end
      if in_tree and in_styles and in_traits then out[#out + 1] = r end
    end
  end
  if scores ~= nil then
    -- real names first, then relevance
    PS.sort(out, function(r) return scores[r.path] + (truthy(r.named) and 0 or 2) end)
  else
    -- ((not named, not thumb, name.lower()) as one string: two flag bytes, then the name - the same order, a string
    -- compared at once instead of a tuple element by element)
    PS.sort(out, function(r)
      return (truthy(r.named) and "0" or "1") .. (truthy(r.thumb) and "0" or "1") .. S.lower(r.name)
    end)
  end
  local cut = {}
  for i = 1, math.min(limit, #out) do cut[i] = out[i] end
  return cut, {tree = tree, styles = sty, traits = tra, total = #out}
end

function A:browse_items(text, cat, sub, limit)
  text, limit = text or "", limit or 400
  if self._items == nil then
    self._items = {}
    local rows, cols = self.db:rows("select * from items order by label")
    for i, r in ipairs(rows) do self._items[i] = as_map(r, cols) end
  end
  local scores = self:_scores("item_search", "name", text)
  local tree, out = A.Counter(), {}
  local has_cat, has_sub = cat ~= nil and cat ~= "", sub ~= nil and sub ~= ""
  for _, r in ipairs(self._items) do
    if not (scores ~= nil and scores[r.name] == nil) and not (r.cat == "Internal" and cat ~= "Internal") then
      tree:add(r.cat .. "\0" .. r.sub)
      if (not has_cat or r.cat == cat) and (not has_sub or r.sub == sub) then out[#out + 1] = r end
    end
  end
  if scores ~= nil then PS.sort(out, function(r) return scores[r.name] end) end
  local cut = {}
  for i = 1, math.min(limit, #out) do cut[i] = out[i] end
  return cut, {tree = tree, styles = A.Counter(), traits = A.Counter(), total = #out}
end

-- loot definitions whose name or items match every word (their items' names count too)
function A:loot_tables(text, limit)
  text, limit = text or "", limit or 200
  local words = WORD:findall(S.lower(text))
  if self._loot == nil then
    local labels = {}
    for _, r in ipairs((self.db:rows("select name, label from items"))) do
      labels[r[1]] = S.lower(truthy(r[2]) and r[2] or "")
    end
    self._loot = {}
    for _, r in ipairs((self.db:rows("select name, entries, file from loot order by name"))) do
      local entries = J.decode(r[2])
      local hay = {(S.lower(r[1]):gsub("_", " "))}
      for _, x in ipairs(entries) do hay[#hay + 1] = S.lower(x[1]) .. " " .. (labels[x[1]] or "") end
      self._loot[#self._loot + 1] = {name = r[1], entries = entries, file = r[3], hay = table.concat(hay, " ")}
    end
  end
  local out = {}
  for _, r in ipairs(self._loot) do
    local all = true
    for _, w in ipairs(words) do if not r.hay:find(w, 1, true) then all = false break end end
    if all then
      out[#out + 1] = r
      if #out >= limit then break end
    end
  end
  return out
end

-- the answers of loot, template, item and icon are kept (23.10.: the inspector asked again every frame - a chest's
-- card took 25 ms of each frame, the game ran at 30 fps); callers do not change what they get
local NONE = {}
local function memo(self, kind, key, make)
  local m = self.memo
  if not m then return make() end
  local t = m[kind]
  if not t then t = {} m[kind] = t end
  local v = t[key]
  if v == nil then
    v = make()
    t[key] = v == nil and NONE or v
  elseif v == NONE then
    v = nil
  end
  return v
end

function A:loot(name)
  return memo(self, "loot", tostring(name), function()
    local r = self.db:one("select entries, file from loot where name = ?", name)
    if not r then return nil end
    return {name = name, entries = J.decode(r[1]), file = r[2]}
  end)
end

function A:items(text, limit)
  text, limit = text or "", limit or 400
  local q = A.fts(text)
  local rows, cols
  if q ~= "" then
    rows, cols = self.db:rows("select i.* from item_search s join items i on i.name = s.name where item_search match ? " ..
                              "and i.cat != 'Internal' order by bm25(item_search, 0, 8, 1) limit ?", q, limit)
  else
    rows, cols = self.db:rows("select * from items where cat != 'Internal' order by label limit ?", limit)
  end
  local out = {}
  for i, r in ipairs(rows) do out[i] = as_map(r, cols) end
  return out
end

function A:template(path)
  return memo(self, "template", S.lower(path), function()
    local rows, cols = self.db:rows("select * from templates where path = ?", S.lower(path))
    return rows[1] and as_map(rows[1], cols) or nil
  end)
end

function A:item(name)
  return memo(self, "item", tostring(name), function()
    local rows, cols = self.db:rows("select * from items where name = ?", name)
    return rows[1] and as_map(rows[1], cols) or nil
  end)
end

-- --- pictures: PNG files (thumbs\<size>\<path>.png, thumbs\icons\...), made on first use as the app makes them ---
-- (cj_core makes them on its thread; the lab makes none into the real data folder: guard.py's rule)
-- the folders of a file cj_core writes (its texture jobs make none), each made when missing
local function make_dirs(out)
  local dir = out:match("^(.*)\\[^\\]*$")
  local made = ""
  for part in dir:gmatch("[^\\]+") do
    made = made == "" and part or (made .. "\\" .. part)
    if #made > 2 and not w3.fs.isdir(made) then w3.fs.mkdir(made) end
  end
end
local function can_make(...)
  local p = w3.plugin
  if not p or (w3.lab and not os.getenv("CJ_ICONS") and not A.LAB_MAKES) then return false end
  for _, f in ipairs({...}) do if not p[f] then return false end end
  return true
end
-- -> a template's (a mesh's) picture file at size px, or nil and "pending" while it is made (assets.thumbnail):
-- REDkit's picture of it (a library tree's: the tree's), a blank one giving way to one of its first six meshes; a
-- library decal's: its texture. 25.10.: only the pictures the app had made were there - 4156 of 23411.
A.THUMB_PENDING = {}                                -- out -> "tex" | "thumb" while being made, false: none
function A:thumbnail(path, size, meshes)
  size = size or 128
  local out = PATHS.join(A.THUMBS, tostring(size), (PATHS.splitext(S.lower(path))) .. ".png")
  if w3.fs.exists(out) then return out end
  -- a content pack's thing: REDkit drew no picture of it - painted from the front, square (look_chooser; MaximdeWinter
  -- 13.11.: the pack's crate had no picture)
  local row = self:template(path)
  if row and (" " .. tostring(row.traits or "") .. " "):find(" pack ", 1, true) then
    local LC = require("conjunction.look_chooser")
    local tile = LC.cache_file(path, "", true)
    if w3.fs.exists(tile) then return tile end
    LC.want(path, "", false, true)
    return nil, "pending"
  end
  if not can_make("cj_thumb_async", "cj_mosaic_status", "cj_tex_image_async", "cj_tex_status") then return nil end
  local p = w3.plugin
  local state = A.THUMB_PENDING[out]
  if state == false then return nil end
  if state == nil then
    if not self.decals then
      local PG = require("conjunction.project_gen")
      self.decals, self.trees = PG.decal_reverse_index(), PG.foliage_reverse_index()
    end
    local key = S.lower(path)
    local tex = self.decals[key]
    if tex then                                     -- (a decal: its texture at twice the size, then made smaller)
      if not A.tex_opened then
        A.tex_opened = true
        pcall(p.cj_tex_open, require("conjunction.config").load().game or "")
      end
      make_dirs(out)
      A.THUMB_PENDING[out] = pcall(p.cj_tex_image_async, tex, tostring(size * 2), out) and "tex" or false
      return nil, "pending"
    end
    self.thumb_root = self.thumb_root or
                      PATHS.join(tostring(require("conjunction.config").load().redkit or ""), "r4data", "thumbnails")
    local root = self.thumb_root
    local function thmb(q) return PATHS.join(root, (PATHS.splitext(q))) .. ".thmb" end
    local files, mode = {thmb(self.trees[key] or path)}, "thmb"
    if key:sub(-6) == ".w2ent" then
      mode = "thmb+"
      if meshes == nil then
        local r = self:template(path)
        meshes = r and truthy(r.meshes) and J.decode(r.meshes) or {}
      end
      for i = 1, math.min(6, #meshes) do files[#files + 1] = thmb(meshes[i]) end
    end
    A.THUMB_PENDING[out] = pcall(p.cj_thumb_async, out, tostring(size), mode, table.unpack(files)) and "thumb" or false
    return nil, A.THUMB_PENDING[out] and "pending" or nil
  end
  if state == "tex" then
    local ok, answer = pcall(p.cj_tex_status, out)
    if ok and answer == "busy" then return nil, "pending" end
    if not ok or answer:sub(1, 1) == "!" then A.THUMB_PENDING[out] = false return nil end
    A.THUMB_PENDING[out] = pcall(p.cj_thumb_async, out, tostring(size), "png") and "thumb" or false
    return nil, A.THUMB_PENDING[out] and "pending" or nil
  end
  local ok, answer = pcall(p.cj_mosaic_status, out)
  if ok and answer == "busy" then return nil, "pending" end
  A.THUMB_PENDING[out] = nil
  if ok and answer == "ok" then return out end
  A.THUMB_PENDING[out] = false
  return nil
end

-- an item whose icon is in no texture cache (the game's data names none, or a file that is not there: 676 of the
-- items shown - Albert Vegelbud's mask's is "boots-01.png", MaximdeWinter 25.10.) -> the picture of its equip_template, the
-- template of that name (one with REDkit's picture first), or nil (and "pending" while it is made)
function A:icon_stand_in(it)
  local et = truthy(it.equip_template) and S.lower(tostring(it.equip_template)) or nil
  if not et then return nil end
  if not self.by_stem then
    self.by_stem = {}
    local rows = self.db:rows("select path, thumb from templates order by thumb desc, path")
    for _, r in ipairs(rows) do
      local stem = S.lower(r[1]):match("([^\\]+)%.[^.\\]*$")
      if stem and self.by_stem[stem] == nil then self.by_stem[stem] = r[1] end
    end
  end
  local path = self.by_stem[et]
  if not path then return nil end
  return self:thumbnail(path, 128)
end
-- -> the icon's picture file, or nil and "pending": one the app did not keep is made from the game's texture caches on
-- cj_core's thread (assets.icon's TextureCache; 24.10.: only 564 of 1772 were kept, the item grid showed "..."); asked
-- again, it is there once made. (A .dds icon becomes a .dds.png: the app wrote those as DDS, which Qt cannot read)
A.ICON_PENDING = {}                                 -- out -> true while being made
function A:icon(item)
  local it = type(item) == "string" and self:item(item) or item
  if not it then return nil end
  if not truthy(it.icon) then return self:icon_stand_in(it) end
  local got = memo(self, "icon", it.icon, function()
    local out = PATHS.join(A.THUMBS, "icons", (it.icon:gsub("/", "\\")))
    if w3.fs.exists(out) and not out:lower():find("%.dds$") then return out end
    if w3.fs.exists(out .. ".png") then return out .. ".png" end
    return nil
  end)
  if got then return got end
  local p = w3.plugin
  if not (p and p.cj_tex_image_async and p.cj_tex_status) or (w3.lab and not os.getenv("CJ_ICONS") and not A.LAB_MAKES) then
    return nil                                      -- (the lab makes none into the real data folder: guard.py's rule)
  end
  local out = PATHS.join(A.THUMBS, "icons", (it.icon:gsub("/", "\\")))
  if out:lower():find("%.dds$") then out = out .. ".png" end
  if A.ICON_PENDING[out] == nil then
    if not A.tex_opened then
      A.tex_opened = true
      pcall(p.cj_tex_open, require("conjunction.config").load().game or "")
    end
    make_dirs(out)
    A.ICON_PENDING[out] = pcall(p.cj_tex_image_async, "gameplay\\gui_new\\" .. it.icon:gsub("/", "\\"), "0", out)
    return nil, A.ICON_PENDING[out] and "pending" or nil
  end
  if A.ICON_PENDING[out] == false then return self:icon_stand_in(it) end
  local ok, answer = pcall(p.cj_tex_status, out)
  if not ok or answer:sub(1, 1) == "!" then A.ICON_PENDING[out] = false return self:icon_stand_in(it) end
  if answer == "busy" then return nil, "pending" end
  A.ICON_PENDING[out] = false
  if self.memo and self.memo.icon then self.memo.icon[it.icon] = out end   -- (made: from now on as a kept one)
  return out
end

return A
