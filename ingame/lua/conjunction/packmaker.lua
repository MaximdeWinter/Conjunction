-- Make a mod a content pack (packmaker.py): Conjunction looks into a mod folder, shows what it found and what keeps it
-- from working with quests made by others, and writes the pack card (conjunction_pack.yml) and the table of contents
-- (conjunction_index.json) into the mod.
--   local r = PM.inspect(folder)     r.templates, r.items, r.meshes, r.checks {{level, key, text, things}}, r:counts()
--   PM.write(folder, meta, r) -> the card      PM.guess_kinds(r)
-- A check's level: "ok", "fix" (Conjunction does it: the card, the contents), "warn" (works, but others will trip over
-- it), "info".
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local R = require("conjunction.pyre")
local FS = require("conjunction.fsutil")
local C = require("conjunction.content")
local TI = require("conjunction.template_info")
local PM = {}

PM.KINDS = {"furniture", "items", "people", "creatures", "voices", "other"}
PM.ITEM_XML = R.compile([[(^|\\)gameplay\\items[^\\]*\\[^\\]*\.xml$]])

local Report = {}
Report.__index = Report
function PM.Report(folder)
  return setmetatable({folder = folder, templates = {}, items = {}, meshes = {}, replaces = {}, voices = 0,
                       meta = Y.map(), checks = {}}, Report)
end
-- {category = count}, in the order the categories come (dict insertion)
function Report:counts()
  local out = Y.map()
  for _, r in ipairs(self.templates) do
    local cat = P.T(r.cat) and r.cat or "Other"
    out[cat] = (out[cat] or 0) + 1
  end
  return out
end

-- every .bundle below a folder, sorted
function PM.bundles_in(path)
  local out = {}
  for _, f in ipairs(FS.walk(path)) do if f.name:sub(-7) == ".bundle" then out[#out + 1] = f.path end end
  table.sort(out)
  return out
end

-- one file out of a bundle (cj_core's decoders) -> its bytes
function PM.read(bundle, e)
  local tmp = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_bundle_" .. require("conjunction.marks").uuid4_hex():sub(1, 10)
  local r = w3.plugin.cj_bundle_read(bundle, tostring(e[4]), tostring(e[2]), tostring(e[3]), tostring(e[5]), tmp)
  if not r or not tostring(r):match("^%d+$") then error(tostring(r), 0) end
  local data = w3.fs.read(tmp)
  w3.fs.remove(tmp)
  return data
end

-- id -> text and key hash -> id of the mod's own English strings
local function strings_of(folder)
  local WS = require("conjunction.w3strings")
  local by_id, by_key = {}, {}
  for _, f in ipairs(FS.walk(folder)) do
    if PYS.lower(f.name) == "en.w3strings" then
      local ok, _v, _l, texts, keys = pcall(WS.read, w3.fs.read(f.path) or "", "en")
      if ok then
        for k, v in pairs(texts) do by_id[k] = v end
        for sid, h in pairs(keys) do by_key[h] = sid end
      end
    end
  end
  return by_id, by_key
end

local ITEM = R.compile([[<item\s([^>]*?)(/>|>(.*?)</item>)]], R.S)
local COMMENT = R.compile([[<!--.*?-->]], R.S)
local TAGS = R.compile([[<tags>(.*?)</tags>]], R.S)

function PM.item_rows(text, path, by_id, by_key, game_text)
  local T = require("conjunction.taxonomy")
  local GEN = require("conjunction.questgen")
  local out = {}
  for m in ITEM:finditer(COMMENT:sub("", text)) do
    local a = TI.attrs(m:group(1))
    if P.T(a.name) then
      local tags = {}
      local t = TAGS:search(m:group(3) or "")
      if t then
        for x in (t:group(1) .. ","):gmatch("([^,]*),") do
          x = PYS.strip(x)
          if x ~= "" then tags[#tags + 1] = x end
        end
      end
      local function text_of(key)
        local sid = (key and key ~= "") and by_key[TI.java_hash(PYS.lower(key))] or nil   -- (keys are hashed lower case)
        if sid ~= nil and by_id[sid] ~= nil then return by_id[sid] end
        return (key and key ~= "") and ((game_text or {})[key] or "") or ""
      end
      local label = text_of(a.localisation_key_name or "")
      local cat, sub = T.classify_item(a.category or "", tags)
      out[#out + 1] = Y.map({"name", a.name, "label", label, "descr", text_of(a.localisation_key_description or ""),
                             "category", a.category or "", "tags", table.concat(tags, " "),
                             "price", GEN.float(P.or_(a.price, 0)), "weight", GEN.float(P.or_(a.weight, 0)),
                             "icon", a.icon_path or "", "equip_template", a.equip_template or "",
                             "stackable", a.stackable or "", "file", path, "cat", cat, "sub", sub})
    end
  end
  return out
end

function PM.template_row(path, info, by_id, source)
  local CAT = require("conjunction.catalog")
  local T = require("conjunction.taxonomy")
  info = info or {}
  local kind, tags = TI.kind_and_tags(path, info)
  local real = by_id[(info.name_id and info.name_id ~= 0) and info.name_id or -1] or ""
  local cls, comps = info.class or "", info.components or {}
  local cat, sub = T.classify(path, cls, comps, kind, real, info.meshes or {})
  local decal = false
  for _, c in ipairs(comps) do if c == "CDecalComponent" then decal = true end end
  if decal and #(info.meshes or {}) == 0 then cat, sub = "Decoration", "Decals" end   -- (a picture on the world)
  local traits = T.traits(path, cls, comps, info.inventory, info.loot, real ~= "")
  local styles = {}
  for _, s in ipairs(T.styles(path, real)) do styles[#styles + 1] = (s:gsub(" ", "_")) end
  local meshes = {}
  for k = 1, math.min(40, #(info.meshes or {})) do meshes[k] = info.meshes[k] end
  local function js(list) return J.encode(Y.list(list or {})) end
  return Y.map({"path", path, "name", real ~= "" and real or CAT.caption(path), "named", real ~= "" and 1 or 0,
                "kind", kind, "class", cls, "source", source, "quest", 0, "inventory", info.inventory and 1 or 0,
                "loot", js(info.loot), "components", js(comps), "appearances", js(info.appearances),
                "meshes", js(meshes), "tags", table.concat(tags, " "), "grp", CAT.group_of(path), "thumb", 0,
                "cat", cat, "sub", sub, "styles", table.concat(styles, " "), "traits", table.concat(traits, " "),
                "loot_defs", js(info.loot_defs)})
end

-- the depot paths of the game's own templates and its item names: what a mod would replace
local function game_paths()
  local ok, o = pcall(C.Origins)
  if not ok then return {}, {} end
  local tpl, items = {}, {}
  for p, f in pairs(o.templates) do if f == "game" then tpl[p] = true end end
  for n, f in pairs(o.items) do if f == "game" then items[n] = true end end
  return tpl, items
end

-- what a mod folder brings and what it needs to work with everyone's quests
function PM.inspect(folder, log)
  local PK = require("conjunction.packer")
  local r = PM.Report(folder)
  local marker = folder .. "\\" .. C.MARKER
  if w3.fs.exists(marker) and not w3.fs.isdir(marker) then
    local ok, m = pcall(C.read_pack_meta, marker)
    r.meta = ok and m or Y.map()
  end
  local by_id, by_key = strings_of(folder)
  local source = P.or_(P.get(r.meta, "name"), (folder:gsub("[\\/]+$", "")):match("([^\\/]*)$"))
  local files, order = {}, {}
  for _, b in ipairs(PM.bundles_in(folder)) do
    for _, e in ipairs(PK.entries(b)) do
      local p = PYS.lower(e[1])
      if files[p] == nil then files[p] = {b, e} order[#order + 1] = p end
    end
  end
  table.sort(order)
  local game_tpl, game_items = game_paths()
  local used = {}
  for _, p in ipairs(order) do
    local b, e = files[p][1], files[p][2]
    if p:sub(-6) == ".w2ent" then
      local ok, info = pcall(function() return TI.read_template(PM.read(b, e)) end)
      if not ok then info = nil end
      r.templates[#r.templates + 1] = PM.template_row(p, info, by_id, source)
      for _, m in ipairs((info or {}).meshes or {}) do used[m] = true end
      if game_tpl[p] then r.replaces[#r.replaces + 1] = p end
    elseif PM.ITEM_XML:search(p) then
      local ok, raw = pcall(PM.read, b, e)
      if ok and raw then
        local text
        if raw:sub(1, 2) == "\255\254" or raw:sub(1, 2) == "\254\255" then
          text = require("conjunction.build").utf16_decode(raw)
        else
          text = require("conjunction.w3strings").decode_replace((raw:gsub("^\239\187\191", "")))
        end
        for _, row in ipairs(PM.item_rows(text, p, by_id, by_key)) do r.items[#r.items + 1] = row end
      end
    end
  end
  for _, p in ipairs(order) do
    if p:sub(-7) == ".w2mesh" and not used[p] then r.meshes[#r.meshes + 1] = p end
  end
  for _, f in ipairs(FS.walk(folder)) do
    if PYS.lower(f.name):sub(-9) == ".w3speech" then r.voices = r.voices + 1 end
  end
  PM.checks(r, game_items)
  if log then
    log(string.format("[pack] %s: %d templates, %d items, %d loose meshes", folder, #r.templates, #r.items, #r.meshes))
  end
  return r
end

local function sorted(list)
  local out = {table.unpack(list)}
  table.sort(out)
  return out
end

function PM.checks(r, game_items)
  local c = r.checks
  local function add(...) c[#c + 1] = {...} end
  if #r.templates == 0 and #r.items == 0 then
    add("warn", "empty", "Nothing to place or give: no templates (.w2ent) and no item definitions found in the " ..
                         "folder's bundles.", {})
  end
  if P.T(P.get(r.meta, "id")) then
    add("ok", "card", "Pack card: " .. P.str(P.or_(P.get(r.meta, "name"), r.meta.id)) .. " " ..
                      P.str(P.get(r.meta, "version", "")), {})
  else
    add("fix", "card", "No pack card yet: quests cannot name this mod, players cannot be told it is missing.", {})
  end
  if not P.T(P.get(r.meta, "url")) then
    add("warn", "url", "No download link: players who lack the mod are not told where to get it.", {})
  end
  local index = r.folder .. "\\" .. C.INDEX
  local bundles = PM.bundles_in(r.folder)
  local fresh = true
  local it = w3.fs.exists(index) and w3.fs.mtime(index) or nil
  for _, b in ipairs(bundles) do if it == nil or (w3.fs.mtime(b) or 0) > it then fresh = false end end
  if it ~= nil and fresh then
    add("ok", "index", string.format("Table of contents: %d templates, %d items.", #r.templates, #r.items), {})
  elseif it ~= nil then
    add("fix", "index", "The mod changed since its table of contents was written: write the card again.", {})
  else
    add("fix", "index", "Table of contents: written with the card (what the catalog shows of the mod).", {})
  end
  local clash = {}
  for _, i in ipairs(r.items) do if game_items[i.name] then clash[#clash + 1] = i.name end end
  if #clash > 0 then
    add("warn", "item_names", "Items with a name the game already uses - they change the game's item for everyone. " ..
                              "Give new items names of their own (a prefix).", sorted(clash))
  end
  -- helper items no player sees (a sword's scabbard: neither a name nor an icon) - no warning
  local helper = {}
  for _, i in ipairs(r.items) do
    local noshow = false
    for t in i.tags:gmatch("%S+") do if t == "NoShow" then noshow = true end end
    if i.label == "" and i.icon == "" and (i.category:sub(-9) == "scabbards" or noshow) then helper[i.name] = true end
  end
  local unnamed, noicon = {}, {}
  for _, i in ipairs(r.items) do
    if i.label == "" and not helper[i.name] then unnamed[#unnamed + 1] = i.name end
    if i.icon == "" and not helper[i.name] then noicon[#noicon + 1] = i.name end
  end
  if #unnamed > 0 then
    add("warn", "item_labels", "Items without a readable name (no en.w3strings text for their localisation_key_name): " ..
                               "quests and the catalog show the raw name.", sorted(unnamed))
  end
  if #noicon > 0 then add("info", "item_icons", "Items without an icon (icon_path).", sorted(noicon)) end
  if #r.replaces > 0 then
    add("warn", "replaces", "Files at the game's own paths: the mod replaces them. Quests that use them show the " ..
                            "game's version to players without the mod - new things belong in folders of their own.",
        r.replaces)
  end
  local rep, prefixes, plist = {}, {}, {}
  for _, p in ipairs(r.replaces) do rep[p] = true end
  for _, t in ipairs(r.templates) do
    if not rep[t.path] then
      local a, b2 = t.path:match("^([^\\]*)\\?([^\\]*)")
      local key = a .. ((t.path:sub(1, 4) == "dlc\\") and ("\\" .. b2) or "")
      if not prefixes[key] then prefixes[key] = true plist[#plist + 1] = key end
    end
  end
  if #plist > 3 then
    add("info", "folders", "New files spread over many top folders - one folder of the mod's own (dlc\\<mod>\\...) " ..
                           "keeps them apart from other mods.", sorted(plist))
  end
  if #r.meshes > 0 then
    add("info", "meshes", "Meshes without a template: they cannot be placed. Conjunction can place meshes of the game " ..
                          "through its mesh library; templates for these come with a later version.",
        {table.unpack(r.meshes, 1, math.min(50, #r.meshes))})
  end
end

function PM.slug(text)
  local s = PYS.lower(P.str(text)):gsub("[^a-z0-9_]+", "_")
  return (s:gsub("^_+", ""):gsub("_+$", ""))
end

function PM.guess_kinds(r)
  local out = {}
  local world = {}
  for _, t in ipairs(r.templates) do if t.kind ~= "Item" then world[#world + 1] = t end end
  local furn = {Furniture = true, Decoration = true, Architecture = true, Containers = true, Lights = true, Props = true}
  local is_furn = false
  for _, t in ipairs(world) do
    if furn[t.cat] or t.kind == "Decoration" or t.kind == "Container" or t.kind == "Light" then is_furn = true end
  end
  if is_furn then out[#out + 1] = "furniture" end
  if #r.items > 0 then out[#out + 1] = "items" end
  local people, creatures = false, false
  for _, t in ipairs(r.templates) do
    if t.kind == "NPC" then people = true end
    if t.kind == "Monster" or t.kind == "Animal" then creatures = true end
  end
  if people then out[#out + 1] = "people" end
  if creatures then out[#out + 1] = "creatures" end
  if r.voices > 0 then out[#out + 1] = "voices" end
  if #out == 0 then out[1] = "other" end
  return out
end

-- the pack card and the table of contents into the mod folder. meta: id, name, author, version, url, description,
-- kinds
function PM.write(folder, meta, report)
  report = report or PM.inspect(folder)
  local base = (folder:gsub("[\\/]+$", "")):match("([^\\/]*)$")
  -- the id stays once written (quests name the pack by it); a new one carries the author too
  local first = PM.slug(P.or_(P.get(meta, "name"), base))
  if P.T(P.get(meta, "author")) and not first:find(PM.slug(meta.author), 1, true) then
    first = first .. "_" .. PM.slug(meta.author)
  end
  local kinds = P.T(P.get(meta, "kinds")) and meta.kinds or PM.guess_kinds(report)
  local m = Y.map({"id", PM.slug(P.or_(P.get(meta, "id"), P.get(report.meta or Y.map(), "id"), first)),
                   "name", PYS.strip(P.str(P.or_(P.get(meta, "name"), ""))) ~= "" and PYS.strip(P.str(meta.name)) or base,
                   "author", PYS.strip(P.str(P.or_(P.get(meta, "author"), ""))),
                   "version", PYS.strip(P.str(P.or_(P.get(meta, "version"), "1.0"))),
                   "url", PYS.strip(P.str(P.or_(P.get(meta, "url"), ""))),
                   "description", PYS.strip(P.str(P.or_(P.get(meta, "description"), ""))),
                   "kinds", Y.list({table.unpack(kinds)}), "made_with", "conjunction"})
  if m.id == "" then require("conjunction.questgen").fail("The pack needs a name") end
  local prefix = m.id:gsub("_", " ") .. " "        -- (Conjunction names a pack's things <pack>_<name>)
  for _, t in ipairs(report.templates) do
    t.source = m.name
    if t.named == 0 and t.name:sub(1, #prefix) == prefix and #t.name > #prefix then t.name = t.name:sub(#prefix + 1) end
  end
  local index = Y.map({"pack", m.id, "version", m.version, "templates", Y.list(report.templates),
                       "items", Y.list(report.items)})
  local path = folder .. "\\" .. C.INDEX
  assert(FS.write_text(path .. ".tmp", J.encode(index, {indent = 0})))
  if w3.fs.exists(path) then w3.fs.remove(path) end
  assert(w3.fs.rename(path .. ".tmp", path))
  local card = folder .. "\\" .. C.MARKER
  Y.write(card .. ".tmp", m, {sort_keys = false, allow_unicode = true, default_flow_style = false})
  if w3.fs.exists(card) then w3.fs.remove(card) end
  assert(w3.fs.rename(card .. ".tmp", card))
  report.meta = m
  return m
end

return PM
