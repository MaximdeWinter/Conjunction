-- What a cooked template is (assets.py: read_template and its helpers): class, components, inventory, loot, meshes,
-- includes, appearances, display name id, loot definitions; its kind and tags for the catalog.
--   TI.read_template(data) -> info or nil     TI.kind_and_tags(path, info) -> kind, {tags}
--   TI.java_hash(s)   TI.attrs(tag) -> {name = value} of an XML tag's attributes
local CR = require("conjunction.cr2w")
local TI = {}

TI.LIGHTS = {CPointLightComponent = true, CSpotLightComponent = true, CLightComponent = true}

-- (type, raw value bytes) of a top-level property of an object's data, or nil
local function prop_value(f, chunk, name)
  for _, p in ipairs(f:props(chunk)) do
    if p[1] == name then return p[2], chunk:sub(p[3] + 1, p[3] + p[4]) end
  end
  return nil, nil
end
TI.prop_value = prop_value

-- name -> {type, raw} of the fields of a struct value (raw from 0-based start, after its 0 byte) -> fields, the
-- offset after its end marker
local function struct_props(f, raw, start)
  local out, i = {}, start or 1
  while i + 2 <= #raw do
    local nm = string.unpack("<I2", raw, i + 1)
    if nm == 0 then break end
    local tp, sz = string.unpack("<I2I4", raw, i + 3)
    out[f.names[nm + 1]] = {f.names[tp + 1], raw:sub(i + 9, i + 4 + sz)}
    i = i + 4 + sz
  end
  return out, i + 2
end

local function names_of_array(f, raw)
  if not raw or #raw < 4 then return {} end
  local out, i = {}, 4
  for _ = 1, string.unpack("<I4", raw) do
    local fields
    fields, i = struct_props(f, raw, i + 1)
    local n = fields.name
    if n and n[1] == "CName" then out[#out + 1] = f.names[string.unpack("<I2", n[2]) + 1] end
  end
  return out
end

function TI.appearances(f, chunk)
  local _, raw = prop_value(f, chunk, "appearances")
  if not raw or raw == "" then return {} end
  return names_of_array(f, raw)
end

-- the loot definition names of a CR4LootParam (containers: CR4LootContainerParam {name: CName, ...})
function TI.loot_defs(f, chunk)
  local _, raw = prop_value(f, chunk, "containers")
  return names_of_array(f, raw)
end

local function ends(s, x) return s:sub(-#x) == x end

function TI.read_template(data)
  local parts = CR.parts(data)
  if #parts == 0 then return nil end
  local top = parts[1]
  local info = {class = "", components = {}, inventory = false, loot = {}, meshes = {}, includes = {}, appearances = {},
                name_id = 0, loot_defs = {}}
  for _, e in ipairs(top.exports) do
    if e[1] == "CEntityTemplate" then
      -- the entity object the template points at (a handle: +n = export n), else its entityClass
      local _, raw = prop_value(top, e[5], "entityObject")
      if raw and #raw >= 4 then
        local k = string.unpack("<i4", raw)
        if k > 0 and k <= #top.exports then info.class = top.exports[k][1] end
      end
      if info.class == "" then
        local _, raw2 = prop_value(top, e[5], "entityClass")
        if raw2 and raw2 ~= "" then info.class = top.names[string.unpack("<I2", raw2) + 1] end
      end
      break
    end
  end
  if (info.class == "" or ends(info.class, "Component")) and #parts > 1 and #parts[2].exports > 0 then
    info.class = parts[2].exports[1][1]          -- (the compiled entity's first object is the entity)
  end
  local comps, seen = {}, {}
  for k = 1, math.min(2, #parts) do
    for _, e in ipairs(parts[k].exports) do
      if ends(e[1], "Component") and e[1] ~= "CFXSpawnerComponent" and not seen[e[1]] then
        seen[e[1]] = true
        comps[#comps + 1] = e[1]
      end
    end
  end
  local have = {}
  for k, f in ipairs(parts) do
    for _, im in ipairs(f.imports) do
      local p = require("conjunction.pystr").lower(im[1])
      if ends(p, ".w2mesh") and not have[p] then
        have[p] = true
        info.meshes[#info.meshes + 1] = p
      elseif ends(p, ".w2ent") and k == 1 then
        info.includes[#info.includes + 1] = p
      end
      if (p:find("_container_definitions", 1, true) and not p:find("_mesh_entities", 1, true)) or
         p:find("\\loot", 1, true) then
        info.loot[#info.loot + 1] = p
      end
    end
  end
  local got = {}
  for k = 1, math.min(2, #parts) do
    for _, e in ipairs(parts[k].exports) do
      if e[1] == "CR4LootParam" then
        for _, n in ipairs(TI.loot_defs(parts[k], e[5])) do
          if not got[n] then got[n] = true info.loot_defs[#info.loot_defs + 1] = n end
        end
      end
    end
  end
  table.sort(comps)
  info.components = comps
  info.inventory = seen.CInventoryComponent == true
  for _, e in ipairs(top.exports) do
    if e[1] == "CEntityTemplate" then info.appearances = TI.appearances(top, e[5]) end
  end
  for k = 1, math.min(2, #parts) do
    for _, e in ipairs(parts[k].exports) do
      if e[1] == info.class then
        local t, raw = prop_value(parts[k], e[5], "displayName")
        if t == "LocalizedString" and raw and #raw >= 4 and info.name_id == 0 then
          info.name_id = string.unpack("<I4", raw)
        end
      end
    end
  end
  return info
end

function TI.java_hash(s)
  local h = 0
  for _, c in utf8.codes(s) do
    if c > 127 then c = 63 end                   -- (encode("ascii", "replace"): a letter beyond ASCII is one ?)
    h = (31 * h + c) & 0xFFFFFFFF
  end
  return h
end

function TI.attrs(tag)
  local out = {}
  for k, v in tag:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do out[k] = v end
  return out
end

local function camel_words(cls)
  local R = require("conjunction.pyre")
  local base = R.sub([[^(CR4|C|W3)(?=[A-Z])]], "", cls)
  local out = {}
  for _, w in ipairs(R.findall([[[A-Z][a-z]+|[A-Z]+(?![a-z])|\d+]], base)) do
    if #w > 2 then out[#out + 1] = require("conjunction.pystr").lower(w) end
  end
  return out
end

function TI.kind_and_tags(path, info)
  local CAT = require("conjunction.catalog")
  local kind = CAT.kind_of(path)
  local tags = {}
  for _, t in ipairs(CAT.tags_of(path)) do tags[t] = true end
  local cls = info.class or ""
  local comps = {}
  for _, c in ipairs(info.components or {}) do comps[c] = true end
  for _, w in ipairs(camel_words(cls)) do tags[w] = true end
  if cls:find("Container", 1, true) then
    if kind ~= "Character part" then kind = "Container" end
    tags.container = true
  end
  if info.inventory then tags.inventory = true end
  if (info.loot and #info.loot > 0) or cls:find("Container", 1, true) then tags.lootable = true end
  if cls == "CNewNPC" and kind ~= "Monster" and kind ~= "Animal" then kind = "NPC" end
  local light = false
  for c in pairs(TI.LIGHTS) do if comps[c] then light = true end end
  if light then
    tags.light = true
    if kind == "Decoration" or kind == "Other" or kind == "Gameplay" then kind = "Light" end
  end
  if cls:find("Door", 1, true) then tags.door = true end
  if comps.CInteractionComponent then tags.interactive = true end
  local list = {}
  for t in pairs(tags) do list[#list + 1] = t end
  table.sort(list)
  return kind, list
end

return TI
