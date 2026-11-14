-- The asset database built in the game (assets.build): every placeable template and every item of the user's game,
-- with what they are - read from the game's own bundles, its strings and REDkit's thumbnails, written to
-- data\assets.sqlite as the app writes it (the same tables, rows and order: the catalog ranks and lists the same).
-- Then which people can talk (talking.fill: the catalog's speech badge).
--   AB.build(log [, step])        in a coroutine (ed:job): a little each frame, the game goes on
--   AB.read_items(depot) / AB.read_loot(depot) / AB.mesh_textured(data) / AB.template_paths(depot)
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local CFG = require("conjunction.config")
local PATHS = require("conjunction.paths")
local PYS = require("conjunction.pystr")
local PS = require("conjunction.pysort")
local R = require("conjunction.pyre")
local CR = require("conjunction.cr2w")
local TI = require("conjunction.template_info")
local AB = {}

AB.LANG = "en"
AB.VERSION = 5
AB.WORKERS = 6            -- (the app's processes: the order its pool gives the templates back in)
AB.SCHEMA = {
  "create table meta(key text primary key, value text)",
  "create table templates(path text primary key, name text, named int, kind text, class text, source text, " ..
    "quest int, inventory int, loot text, components text, appearances text, meshes text, tags text, grp text, " ..
    "thumb int, cat text, sub text, styles text, traits text, loot_defs text)",
  "create table loot(name text primary key, entries text, file text)",
  "create table items(name text primary key, label text, descr text, category text, tags text, price real, " ..
    "weight real, icon text, equip_template text, stackable text, file text, cat text, sub text)",
  "create table mesh_info(path text primary key, textured int)",
  "create virtual table template_search using fts5(path unindexed, name, words, " ..
    "tokenize='unicode61 remove_diacritics 2')",
  "create virtual table item_search using fts5(name unindexed, label, words, tokenize='unicode61 remove_diacritics 2')",
}
AB.TEXTURE_EXT = {".xbm", ".w2mi", ".texarray"}

-- the frame given back once its slice is used up (25.10.: every 400 templates froze the game for most of a second;
-- a slice of AB.SLICE s keeps it moving and costs the build a little); called after each piece of work
AB.SLICE = 0.04
local slice_end = 0
local function yield()
  if coroutine.isyieldable() and os.clock() >= slice_end then
    coroutine.yield()
    slice_end = os.clock() + AB.SLICE
  end
end
local function js(v) return J.encode(v) end                -- (json.dumps: ", " and ": ", ASCII only)

-- an XML file's text: UTF-16 up to 4.04, UTF-8 with a BOM since the remaster (assets._xml_text)
local function xml_text(raw)
  local b1, b2 = raw:byte(1, 2)
  if (b1 == 0xff and b2 == 0xfe) or (b1 == 0xfe and b2 == 0xff) then
    return AB.utf16(raw)
  end
  if raw:sub(1, 3) == "\239\187\191" then return raw:sub(4) end
  return raw
end
-- UTF-16 (with its BOM) -> UTF-8, "replace" for broken pairs
function AB.utf16(raw)
  local le = raw:byte(1) == 0xff
  local out, i, n = {}, 3, #raw
  local function u(k) local a, b = raw:byte(k, k + 1) return le and (a + b * 256) or (a * 256 + b) end
  while i + 1 <= n do
    local c = u(i)
    i = i + 2
    if c >= 0xD800 and c <= 0xDBFF and i + 1 <= n then
      local d = u(i)
      if d >= 0xDC00 and d <= 0xDFFF then
        c = 0x10000 + (c - 0xD800) * 0x400 + (d - 0xDC00)
        i = i + 2
      else
        c = 0xFFFD
      end
    elseif c >= 0xD800 and c <= 0xDFFF then
      c = 0xFFFD
    end
    out[#out + 1] = utf8.char(c)
  end
  return table.concat(out)
end

local ITEM = R.compile([[<item\s([^>]*?)(/>|>(.*?)</item>)]], R.S)
local TAGS = R.compile([[<tags>(.*?)</tags>]], R.S)
local LOOT = R.compile([[<loot\s([^>]*?)(/>|>(.*?)</loot>)]], R.S)
local LOOT_ENTRY = R.compile([[<loot_entry\s([^>]*?)/?>]])
local COMMENT = R.compile([[<!--.*?-->]], R.S)

local function float(v) return tonumber(v) and (tonumber(v) + 0.0) or 0.0 end
-- int(float(v or 1)): missing or empty is 1, "0" stays 0, the fraction cut off toward zero
local function qty(v)
  if v == nil or v == "" then return 1 end
  local f = float(v)
  return math.tointeger(f >= 0 and math.floor(f) or math.ceil(f))
end

-- every item definition; later files override earlier ones with the same name, as the game's _plus files
-- (assets.read_items)
function AB.read_items(d)
  local C = require("conjunction.content")
  local files = {}
  for _, p in ipairs(d:glob("", ".xml")) do
    if C.ITEM_XML:search(p) and C.VANILLA_FILE:match(p) then files[#files + 1] = p end
  end
  files = PS.sorted(files, function(x)
    return {x:sub(1, 4) == "dlc\\", x:find("items_plus", 1, true) ~= nil, x}
  end)
  local items = Y.map()
  for _, p in ipairs(files) do
    local ok, text = pcall(function() return xml_text(d:read(p)) end)
    if ok then
      for m in ITEM:finditer(text) do
        local a = TI.attrs(m:group(1))
        if a.name and a.name ~= "" then
          local body = m:group(3) or ""
          local tags = {}
          local t = TAGS:search(body)
          if t then
            for x in (t:group(1) .. ","):gmatch("([^,]*),") do
              local s = PYS.strip(x)
              if s ~= "" then tags[#tags + 1] = s end
            end
          end
          items[a.name] = {name = a.name, category = a.category or "", tags = tags, price = float(a.price),
                           weight = float(a.weight), icon = a.icon_path or "", key_name = a.localisation_key_name or "",
                           key_desc = a.localisation_key_description or "", equip_template = a.equip_template or "",
                           stackable = a.stackable or "", file = p}
        end
      end
    end
    yield()
  end
  return items
end

-- every loot definition: name -> {entries = {{item, min, max, chance}}, file} (assets.read_loot)
function AB.read_loot(d)
  local files = {}
  for _, p in ipairs(d:glob("", ".xml")) do
    if p:find("\\def_loot", 1, true) and p:find("\\items", 1, true) then files[#files + 1] = p end
  end
  files = PS.sorted(files, function(x) return {x:find("_plus", 1, true) ~= nil, x} end)
  local out = Y.map()
  for _, p in ipairs(files) do
    local ok, text = pcall(function() return xml_text(d:read(p)) end)
    if ok then
      text = COMMENT:sub("", text)
      for m in LOOT:finditer(text) do
        local a = TI.attrs(m:group(1))
        if a.name and a.name ~= "" then
          local entries = {}
          for e in LOOT_ENTRY:finditer(m:group(3) or "") do
            local b = TI.attrs(e:group(1))
            if b.name and b.name ~= "" then
              entries[#entries + 1] = {b.name, qty(b.quantity_min), qty(b.quantity_max), float(b.chance)}
            end
          end
          out[a.name] = {entries = entries, file = p}
        end
      end
    end
    yield()
  end
  return out
end

-- does a cooked mesh use any texture (assets.mesh_textured: the engine's bare material alone is a helper nobody sees)
function AB.mesh_textured(data)
  local parts = CR.parts(data)
  if #parts == 0 then return false end
  for _, f in ipairs(parts) do
    for _, im in ipairs(f.imports) do
      local low = PYS.lower(im[1])
      for _, ext in ipairs(AB.TEXTURE_EXT) do
        if low:sub(-#ext) == ext then return true end
      end
    end
  end
  return false
end

-- the templates of the catalog: every .w2ent of the game's own bundles and the DLCs' (content packs and mods join it
-- from their own table of contents, content.lua), not a skipped one, not the mesh library's
function AB.template_paths(d)
  local CAT = require("conjunction.catalog")
  local game = CFG.load().game
  local own = PYS.lower(game .. "\\content\\")
  local out = {}
  for _, r in ipairs(d:glob_where("", ".w2ent")) do
    local p, b = r[1], r[2]
    if not CAT.SKIP:search(p) and not p:find("\\dlcconjunctionmeshes\\", 1, true) and
        (PYS.lower(b):sub(1, #own) == own or b:find("\\bundles\\", 1, true)) then
      out[#out + 1] = p
    end
  end
  return PS.sorted(out)
end

-- the order the app's pool gives them back in: chunk i = paths[i::n], the chunks one after another
local function pool_order(list, n)
  local out = {}
  for i = 1, n do
    for k = i, #list, n do out[#out + 1] = list[k] end
  end
  return out
end

local EMPTY = {class = "", components = {}, inventory = false, loot = {}, meshes = {}, appearances = {}, name_id = 0}

function AB.build(log, step)
  log = log or print
  local CAT = require("conjunction.catalog")
  local TX = require("conjunction.taxonomy")
  local WS = require("conjunction.w3strings")
  local DB = require("conjunction.db")
  local A = require("conjunction.assets")
  local LIB = require("conjunction.libraries")
  local t0 = os.time()
  local cfg = CFG.load()
  local d = require("conjunction.depot").open(cfg.game)
  local text_by_id, id_by_key = WS.read_strings(AB.LANG, log)
  local paths = AB.template_paths(d)
  log(string.format("[assets] %d templates, reading ...", #paths))
  local infos, order = {}, {}
  for n, p in ipairs(pool_order(paths, AB.WORKERS * 8)) do
    local ok, info = pcall(function() return TI.read_template(d:read(p)) end)
    if ok then infos[p] = info or false                   -- (None: no template in it)
    else infos[p] = {error = tostring(info)} end           -- (one broken template does not stop the build)
    order[#order + 1] = p
    if n % 2000 == 0 then log(string.format("[assets]   %d / %d", n, #paths)) end
    yield()
    if step then step(n, #paths) end
  end
  -- which meshes have textures at all (the library's and the templates')
  local mesh_set = {}
  for _, m in ipairs(LIB.meshes(d)) do mesh_set[m] = true end
  for _, p in ipairs(order) do
    local info = infos[p]
    if info and not info.error then for _, m in ipairs(info.meshes or {}) do mesh_set[m] = true end end
  end
  local mesh_paths = {}
  for m in pairs(mesh_set) do if d:exists(m) then mesh_paths[#mesh_paths + 1] = m end end
  mesh_paths = PS.sorted(mesh_paths)
  log(string.format("[assets] %d meshes: textures ...", #mesh_paths))
  local textured = {}
  local hidden = 0
  for n, m in ipairs(mesh_paths) do
    local ok, v = pcall(function() return AB.mesh_textured(d:read(m)) end)
    textured[m] = (not ok or v) and 1 or 0           -- (unreadable: counted as textured, shown)
    if textured[m] == 0 then hidden = hidden + 1 end
    yield()
  end
  log(string.format("[assets]   %d without any texture (hidden)", hidden))
  local thumbs = cfg.redkit .. "\\r4data\\thumbnails"
  local tmp = A.DB .. ".new"
  if w3.fs.exists(tmp) then w3.fs.remove(tmp) end
  local db = DB.open(tmp, "write")
  for _, sql in ipairs(AB.SCHEMA) do db:exec(sql) end
  db:exec("begin")
  local rows, people = 0, {}
  for n, p in ipairs(order) do
    local info = infos[p]
    if not info or info.error then info = EMPTY end
    local kind, tags = TI.kind_and_tags(p, info)
    local real = text_by_id[(info.name_id ~= nil and info.name_id ~= 0) and info.name_id or -1] or ""
    local name = real ~= "" and real or CAT.caption(p)
    local cls, comps = info.class or "", info.components or {}
    local cat, sub = TX.classify(p, cls, comps, kind, real, info.meshes or {})
    local ms = info.meshes or {}
    if (cls == "CEntity" or cls == "CGameplayEntity" or cls == "") and #ms > 0 then
      local any = false
      for _, m in ipairs(ms) do if (textured[m] or 1) ~= 0 then any = true break end end
      if not any then cat, sub = "Internal", "Internal" end      -- (shows only untextured helper geometry)
    end
    local styles = TX.styles(p, real)
    local traits = TX.traits(p, cls, comps, info.inventory, info.loot, real ~= "")
    local has_thumb = w3.fs.exists(thumbs .. "\\" .. p:gsub("%.[^.\\]*$", "") .. ".thmb")
    local quest = false
    for _, t in ipairs(traits) do if t == "quest" then quest = true end end
    local meshes40 = {}
    for i = 1, math.min(40, #ms) do meshes40[i] = ms[i] end
    local st = {}
    for i, s in ipairs(styles) do st[i] = (s:gsub(" ", "_")) end
    db:exec("insert into templates values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", p, name, real ~= "" and 1 or 0,
            kind, cls, CAT.source_of(p), quest and 1 or 0, info.inventory and 1 or 0, js(Y.list(info.loot or {})),
            js(Y.list(comps)), js(Y.list(info.appearances or {})), js(Y.list(meshes40)), table.concat(tags, " "),
            CAT.group_of(p), has_thumb and 1 or 0, cat, sub, table.concat(st, " "), table.concat(traits, " "),
            js(Y.list(info.loot_defs or {})))
    db:exec("insert into template_search values (?,?,?)", p, name,
            table.concat({cat, sub, table.concat(styles, " "), kind, cls, table.concat(tags, " "), CAT.group_of(p),
                          (p:gsub("\\", " "):gsub("_", " "))}, " "))
    rows = rows + 1
    if cat == "People" then people[#people + 1] = p end
    yield()
  end
  local loot = AB.read_loot(d)
  local names = Y.keys(loot)
  names = PS.sorted(names)
  for _, nm in ipairs(names) do
    db:exec("insert into loot values (?,?,?)", nm, js(Y.list(loot[nm].entries)), loot[nm].file)
  end
  log(string.format("[assets] %d loot tables", #names))
  for _, m in ipairs(mesh_paths) do db:exec("insert into mesh_info values (?,?)", m, textured[m]) end
  local items = AB.read_items(d)
  local irows = 0
  for _, key in ipairs(Y.keys(items)) do
    local it = items[key]
    local kn, kd = TI.java_hash(PYS.lower(it.key_name)), TI.java_hash(PYS.lower(it.key_desc))
    local label = text_by_id[id_by_key[kn] or -1] or ""
    if label == "" then label = it.name end
    local descr = text_by_id[id_by_key[kd] or -1] or ""
    local cat, sub = TX.classify_item(it.category, it.tags)
    db:exec("insert into items values (?,?,?,?,?,?,?,?,?,?,?,?,?)", it.name, label, descr, it.category,
            table.concat(it.tags, " "), it.price, it.weight, it.icon, it.equip_template, it.stackable, it.file, cat, sub)
    db:exec("insert into item_search values (?,?,?)", it.name, label,
            table.concat({it.name, cat, sub, (it.category:gsub("_", " ")), table.concat(it.tags, " ")}, " "))
    irows = irows + 1
  end
  db:exec("insert into meta values ('version', ?)", tostring(AB.VERSION))
  db:exec("commit")
  db:close()
  if w3.fs.exists(A.DB) then w3.fs.remove(A.DB) end
  w3.fs.rename(tmp, A.DB)
  log(string.format("[assets] %d templates, %d items -> %s (%d s)", rows, irows, A.DB, os.time() - t0))
  -- which people can talk: the catalog's speech badge (talking.fill)
  local ok, err = pcall(AB.fill_talking, people, log)
  if not ok then log("[assets] which people can talk: " .. tostring(err)) end
  return rows, irows
end

-- talking.fill: which of these templates can talk, those not known yet, kept in talking_looks.json
function AB.fill_talking(paths, log)
  local T = require("conjunction.talking")
  local cache = T.load()
  local seen, todo = {}, {}
  for _, p in ipairs(paths) do
    local low = PYS.lower(p)
    if (cache[low] == nil or cache[T.SPAWN .. low] == nil) and not seen[p] then
      seen[p] = true
      todo[#todo + 1] = p
    end
  end
  todo = PS.sorted(todo)
  if #todo == 0 then return 0 end
  log(string.format("[talking] %d templates: which can talk ...", #todo))
  local d = require("conjunction.depot").open(CFG.load().game)
  -- (in the order the app's processes answer: its 24 chunks todo[i::24], each in its order; the file written once;
  -- the files read and the heads looked at kept over all of them: the same bases again and again)
  T.save = false
  local MV = require("conjunction.meshview")
  MV.part_cache, T.faces = {files = {}, n = 0}, {}
  local failed, first = 0, nil
  local ok, err = pcall(function()
    local n = 0
    for i = 1, 24 do
      for k = i, #todo, 24 do
        local fine, why = pcall(T.talking_looks, todo[k], d)
        if not fine then                        -- (one broken template does not stop it - said once at the end)
          failed = failed + 1
          first = first or (todo[k] .. ": " .. tostring(why))
        end
        n = n + 1
        yield()
      end
    end
  end)
  T.save = true
  MV.part_cache, T.faces = nil, nil
  if failed > 0 then log(string.format("[talking] %d could not be read (the first: %s)", failed, first)) end
  if not ok then error(err, 0) end
  pcall(function() J.write(T.CACHE, cache, {}) end)
  return #todo
end

return AB
