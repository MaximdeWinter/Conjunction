-- New furniture from 3D files (furniture.py): a folder of FBX files with their textures becomes a content pack. For
-- every <name>.fbx: REDkit's wcc_lite imports it as a mesh, the textures beside it become the game's textures
-- (<name>_d / _diffuse / _albedo / _basecolor for the colour, <name>_n / _normal for the normal map), every material of
-- the mesh gets the game's standard material (pbr_std) with them, a box around it is its collision, an entity with the
-- mesh is the thing placed. Pictures named <name>.decal[.WxH].png become decals, items.yml the pack's own items. Then
-- the DLC is built (build.lua), its texture and collision caches cooked, installed, and the card written.
--   FU.plan(folder)  FU.decals(folder)  FU.pack_items(folder)  FU.texture_mesh(path, diffuse, normal)
--   FU.add_box_collision(path, material)   FU.build_pack(folder, meta, install, log, work, step) -> the pack's folder,
--   true when it goes into the game only at its next start (FU.install: the running game has the pack loaded)
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local R = require("conjunction.pyre")
local CR = require("conjunction.cr2w")
local FU = {}

FU.TEX_D = {"_d", "_diffuse", "_albedo", "_basecolor", "_color", "_col", ""}
FU.TEX_N = {"_n", "_normal", "_nrm", "_norm"}
FU.IMAGE = {".png", ".tga", ".jpg", ".jpeg", ".dds", ".bmp"}
FU.FLAT_NORMAL = [[engine\textures\editor\normal.xbm]]
FU.PBR = [[engine\materials\graphs\pbr_std.w2mg]]
local pack = string.pack

function FU.slug(text)
  local s = PYS.lower(P.str(text)):gsub("[^a-z0-9_]+", "_")
  return (s:gsub("^_+", ""):gsub("_+$", ""))
end

local function listdir(folder)
  local out = {}
  for _, e in ipairs(w3.fs.list(folder) or {}) do out[#out + 1] = e.name end
  return out
end
local function splitext(n) local b, e = n:match("^(.*)(%.[^.]*)$") return b or n, e or "" end

-- REDkit's importer: an FBX -> .w2mesh, an image -> .xbm (about 30 s each: the engine starts every time)
function FU.wcc_import(src, out, log)
  local B = require("conjunction.build")
  local cfg = require("conjunction.config").load()
  B.makedirs(out:match("^(.*)\\[^\\]*$"))
  local wcc = cfg.wcc
  local lines = {}
  local p = assert(w3.proc.run(B.list2cmdline({wcc, "import", "-depot=local", "-file=" .. src, "-out=" .. out}),
                               {cwd = wcc:match("^(.*)\\[^\\]*$")}))
  while true do
    for _, ln in ipairs(w3.proc.lines(p) or {}) do lines[#lines + 1] = ln end
    local code = w3.proc.exit(p)
    if code ~= nil then
      for _, ln in ipairs(w3.proc.lines(p) or {}) do lines[#lines + 1] = ln end
      w3.proc.close(p)
      if not w3.fs.exists(out) then
        local tail = {}
        for _, ln in ipairs(lines) do
          if ln:find("[Error][WCC]", 1, true) or ln:find("Imported", 1, true) then tail[#tail + 1] = ln end
        end
        local last = {table.unpack(tail, math.max(1, #tail - 2), #tail)}
        B.fail("wcc_lite could not import " .. src:match("([^\\/]*)$") .. ": " ..
               (#last > 0 and table.concat(last, " ") or tostring(code)))
      end
      break
    end
    if coroutine.isyieldable() then coroutine.yield() end
  end
  log("[furniture] imported " .. src:match("([^\\/]*)$"))
  return out
end

function FU.find_texture(folder, base, suffixes)
  local files = {}
  for _, f in ipairs(listdir(folder)) do files[PYS.lower(f)] = f end
  for _, sfx in ipairs(suffixes) do
    for _, ext in ipairs(FU.IMAGE) do
      local f = files[PYS.lower(base) .. sfx .. ext]
      if f then return folder .. "\\" .. f end
    end
  end
  return nil
end

-- every material of an imported mesh -> the game's standard material with these textures (depot paths)
function FU.texture_mesh(path, diffuse, normal)
  local f = CR.parse(assert(w3.fs.read(path)))
  local mesh = f.exports[1]
  if mesh[1] ~= "CMesh" then require("conjunction.questgen").fail(path .. ": not a mesh") end
  local n = {}
  for _, k in ipairs({"baseMaterial", "handle:IMaterial", "CMaterialInstance", "CMaterialGraph", "Diffuse", "Normal",
                      "handle:ITexture", "CBitmapTexture"}) do n[k] = f:add_name(k) end
  local function imp(p, cls)
    for k, im in ipairs(f.imports) do if PYS.lower(im[1]) == PYS.lower(p) then return k - 1 end end
    f.imports[#f.imports + 1] = {p, cls, 0}
    return #f.imports - 1
  end
  local base = imp(FU.PBR, "CMaterialGraph")
  local params = {{"Diffuse", imp(diffuse, "CBitmapTexture")}, {"Normal", imp(normal or FU.FLAT_NORMAL, "CBitmapTexture")}}
  local chunk = {"\0", pack("<I2I2I4i4", n.baseMaterial, n["handle:IMaterial"], 8, -(base + 1)), "\0\0",
                 pack("<I4", #params)}
  for _, pr in ipairs(params) do chunk[#chunk + 1] = pack("<I4I2I2i4", 12, n[pr[1]], n["handle:ITexture"], -(pr[2] + 1)) end
  -- the mesh's materials: one instance for all of them (the FBX's material names stay for the chunks)
  local mats
  for _, p in ipairs(f:props(mesh[5])) do if p[1] == "materials" and not mats then mats = p end end
  if not mats then require("conjunction.questgen").fail(path .. ": the mesh has no materials") end
  local off = mats[3]
  local count = string.unpack("<I4", mesh[5], off + 1)
  f.exports[#f.exports + 1] = {"CMaterialInstance", 8192, 1, 0, table.concat(chunk)}
  local handle = #f.exports                     -- (+n = export n)
  local data = mesh[5]
  for k = 0, count - 1 do
    local at = off + 4 + 4 * k
    data = data:sub(1, at) .. pack("<i4", handle) .. data:sub(at + 5)
  end
  mesh[5] = data
  local out = f:save()
  assert(w3.fs.write(path .. ".tmp", out))
  w3.fs.remove(path)
  assert(w3.fs.rename(path .. ".tmp", path))
  return count
end

local function prop(f, name, typ, value) return pack("<I2I2I4", f:add_name(name), f:add_name(typ), #value + 4) .. value end
local function floats(f, fields, values)
  local out = {"\0"}
  for i, nm in ipairs(fields) do out[#out + 1] = prop(f, nm, "Float", pack("<f", values[i])) end
  out[#out + 1] = "\0\0"
  return table.concat(out)
end

-- a box around the mesh as its collision (CCollisionMesh with a CCollisionShapeBox, the mesh's collisionMesh at it)
function FU.add_box_collision(path, material)
  material = material or "wood_solid"
  local CE = require("conjunction.cr2w_edit")
  local f = CR.parse(assert(w3.fs.read(path)))
  local mesh = f.exports[1]
  local props = f:props(mesh[5])
  for _, p in ipairs(props) do if p[1] == "collisionMesh" then return false end end
  local box = CE.decode(f, mesh[5]).boundingBox
  box = type(box) == "table" and box or {}
  local lo, hi = type(box.Min) == "table" and box.Min or {}, type(box.Max) == "table" and box.Max or {}
  local c, half = {}, {}
  for i, a in ipairs({"X", "Y", "Z"}) do
    c[i] = ((lo[a] or 0.0) + (hi[a] or 0.0)) / 2
    half[i] = math.max(0.01, ((hi[a] or 0.0) - (lo[a] or 0.0)) / 2)
  end
  for _, nm in ipairs({"collisionMesh", "handle:CCollisionMesh", "CCollisionMesh", "shapes", "array:2,0,ptr:ICollisionShape",
                       "CCollisionShapeBox", "pose", "Matrix", "Vector", "X", "Y", "Z", "W", "Float",
                       "physicalMaterialName", "CName", material, "halfExtendsX", "halfExtendsY", "halfExtendsZ"}) do
    f:add_name(nm)
  end
  local xyzw = {"X", "Y", "Z", "W"}
  local rows = {{1.0, 0.0, 0.0, 0.0}, {0.0, 1.0, 0.0, 0.0}, {0.0, 0.0, 1.0, 0.0}, {c[1], c[2], c[3], 1.0}}
  local m = {"\0"}
  for i, a in ipairs(xyzw) do m[#m + 1] = prop(f, a, "Vector", floats(f, xyzw, rows[i])) end
  m[#m + 1] = "\0\0"
  local matrix = table.concat(m)
  local k_mesh = #f.exports                     -- (the collision mesh's export index less one, the box after it)
  local shape = {"\0", prop(f, "pose", "Matrix", matrix), prop(f, "physicalMaterialName", "CName", pack("<I2", f:add_name(material)))}
  for i, a in ipairs({"X", "Y", "Z"}) do shape[#shape + 1] = prop(f, "halfExtends" .. a, "Float", pack("<f", half[i])) end
  shape[#shape + 1] = "\0\0"
  local cmesh = "\0" .. prop(f, "shapes", "array:2,0,ptr:ICollisionShape", pack("<I4i4", 1, k_mesh + 2)) .. "\0\0"
  f.exports[#f.exports + 1] = {"CCollisionMesh", 0, 1, 0, cmesh}
  f.exports[#f.exports + 1] = {"CCollisionShapeBox", 0, k_mesh + 1, 0, table.concat(shape)}
  -- the mesh points at it: a property after autoHideDistance (where the game's meshes have it)
  local after = props[#props]
  for _, p in ipairs(props) do if p[1] == "autoHideDistance" then after = p break end end
  local at = after[3] + after[4]
  mesh[5] = mesh[5]:sub(1, at) .. prop(f, "collisionMesh", "handle:CCollisionMesh", pack("<i4", k_mesh + 1)) ..
            mesh[5]:sub(at + 1)
  local out = f:save()
  assert(w3.fs.write(path .. ".tmp", out))
  w3.fs.remove(path)
  assert(w3.fs.rename(path .. ".tmp", path))
  return true
end

-- {{name, fbx, diffuse image, normal image}} of the folder's FBX files
function FU.plan(folder)
  local names = listdir(folder)
  table.sort(names)
  local out = {}
  for _, f in ipairs(names) do
    if PYS.lower(f):sub(-4) == ".fbx" then
      local base = splitext(f)
      out[#out + 1] = {FU.slug(base), folder .. "\\" .. f, FU.find_texture(folder, base, FU.TEX_D),
                       FU.find_texture(folder, base, FU.TEX_N)}
    end
  end
  return out
end

FU.DECAL = R.compile([[^(?P<base>.+?)\.decal(?:\.(?P<w>\d+(?:\.\d+)?)x(?P<h>\d+(?:\.\d+)?))?\.(png|tga|jpg|jpeg)$]], R.I)

-- {{name, image, {width, height} in metres}}: <name>.decal.png (the longer side 1 m) or <name>.decal.2x1.png
function FU.decals(folder)
  local N = require("conjunction.pynum")
  local names = listdir(folder)
  table.sort(names)
  local out = {}
  for _, f in ipairs(names) do
    local m = FU.DECAL:match(f)
    if m then
      local size
      if m:group("w") then
        size = {tonumber(m:group("w")) + 0.0, tonumber(m:group("h")) + 0.0}
      else
        size = {1.0, 1.0}
        local r = w3.plugin and w3.plugin.cj_img_size and w3.plugin.cj_img_size(folder .. "\\" .. f)
        local w, h = tostring(r or ""):match("^(%d+)%D+(%d+)")
        w, h = tonumber(w), tonumber(h)
        if w and h and w > 0 and h > 0 then
          size = w >= h and {1.0, N.round(h / w, 3)} or {N.round(w / h, 3), 1.0}
        end
      end
      out[#out + 1] = {FU.slug(m:group("base")), folder .. "\\" .. f, size}
    end
  end
  return out
end

-- the pack's own items: items.yml beside the 3D files
function FU.pack_items(folder)
  local f = folder .. "\\items.yml"
  if not w3.fs.exists(f) then return Y.map() end
  local data = P.map(Y.read(f))
  local src = P.T(P.get(data, "items")) and data.items or data
  local out = Y.map()
  for k, v in pairs(src) do
    local id = FU.slug(k)
    if id ~= "" then
      local d = Y.map()
      for kk, vv in pairs(P.map(v)) do d[kk] = vv end
      out[id] = d
    end
  end
  return out
end

-- (isStreamed false as the mesh's: streamed, the cook put the decal into a buffer a spawned entity never loads - it
-- came without any component, nothing to see, 13.11.)
local function decal_entity(texture, size, depth)
  return Y.map({"entityObject", Y.map({".type", "CEntity", "components", Y.map({"decal", Y.map({
    ".type", "CDecalComponent", "isStreamed", false, "diffuseTexture", texture, "specularity", 0.2,
    "transform", Y.map({"pos", Y.list({0, 0, 0}), "scale", Y.list({size[1] + 0.0, size[2] + 0.0, depth or 0.6})})})})})})
end

-- after_encode for build_dlc: each own item gets its base item's icon, category, tags, price and weight (or its own)
function FU.item_xml_fixer(pid, items, log)
  return function(uncooked, dlc)
    local path = uncooked .. "\\dlc\\" .. dlc .. "\\data\\gameplay\\items\\def_item_quest.xml"
    if not w3.fs.exists(path) or next(Y.keys(items)) == nil then return end
    local db
    pcall(function()
      local A = require("conjunction.assets")
      if A.ready() then db = A.new() end
    end)
    local raw = assert(w3.fs.read(path))
    local bom = raw:sub(1, 3) == "\239\187\191"
    local utf16 = not bom and raw:sub(1, 2) == "\255\254"
    local text = utf16 and require("conjunction.build").utf16_decode(raw) or (bom and raw:sub(4) or raw)
    local ITEMBLOCK = R.compile([[<item name=.*?</item>]], R.S)
    local TAGS = R.compile([[<!--<tags></tags>-->|<tags>.*?</tags>]], R.S)
    text = ITEMBLOCK:sub(function(m)
      local block = m:group(0)
      local name = PYS.lower(block:match('<item name="([^"]+)"'))
      local pre = pid .. "_own_"
      local iid = name:sub(1, #pre) == pre and name:sub(#pre + 1) or nil
      local d = iid and items[iid] or nil
      if d == nil then return block end
      local base = (db and P.T(P.get(d, "base")) and db:item(d.base)) or {}
      local function num(v) return P.str(v) end
      local attrs = {{"category", P.or_(P.get(d, "category"), P.get(base, "category"), P.T(P.get(d, "text")) and "book" or "misc")},
                     {"icon_path", P.or_(P.get(d, "icon"), P.get(base, "icon"), "")},
                     {"price", num(P.get(d, "price", P.get(base, "price", 1)))},
                     {"weight", num(P.get(d, "weight", P.get(base, "weight", 0.1)))}}
      for _, kv in ipairs(attrs) do
        local k, v = kv[1], P.str(kv[2])
        if v ~= "" then
          local pat = R.compile("\\b" .. k .. '="[^"]*"')
          if pat:search(block) then
            block = pat:sub(function() return k .. '="' .. v .. '"' end, block, 1)
          else
            block = block:gsub('<item name="', '<item ' .. k .. '="' .. v:gsub("%%", "%%%%") .. '" name="', 1)
          end
        end
      end
      local tags = {}
      if P.T(P.get(d, "tags")) then
        for _, t in ipairs(d.tags) do tags[#tags + 1] = P.str(t) end
      else
        for t in P.str(P.get(base, "tags") or ""):gmatch("%S+") do
          if t:sub(1, 5) ~= "Quest" then tags[#tags + 1] = t end
        end
      end
      if P.T(P.get(d, "text")) then tags[#tags + 1] = "ReadableItem" end
      local joined = table.concat(tags, ", ")
      block = TAGS:sub(function() return "<tags>" .. joined .. "</tags>" end, block, 1)
      return block
    end, text)
    local out
    if utf16 then
      local parts = {"\255\254"}
      for _, c in utf8.codes(text) do
        if c >= 0x10000 then
          local v = c - 0x10000
          parts[#parts + 1] = pack("<I2I2", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
        else parts[#parts + 1] = pack("<I2", c) end
      end
      out = table.concat(parts)
    else
      out = (bom and "\239\187\191" or "") .. text
    end
    assert(w3.fs.write(path, out))
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    log(string.format("[furniture] %s: %d items", pid, n))
  end
end

-- Build pack's steps: each file REDkit imports, the DLC, its caches, the metadata, the copy into the game
-- (each about 30 s: testpack, 13.11., 8 steps in a little over 4 min)
FU.STEP_SECONDS = 30
function FU.step_count(things, pictures, install)
  local total = #pictures + 1 + 1 + 1 + (install ~= false and 1 or 0)
  local any_xbm = #pictures > 0
  for _, t in ipairs(things) do
    total = total + 1 + (t[3] and 1 or 0) + (t[4] and 1 or 0)
    if t[3] or t[4] then any_xbm = true end
  end
  if any_xbm then total = total + 1 end
  return total
end

-- the built pack into the game's dlc folder. A pack the running game has loaded holds its files (13.11.: the copy over
-- it failed half way, and not even its folder can be renamed) - so the installed one is only touched once its folder
-- could be renamed aside; a loaded one stays, the new one waits beside the game (_conjunction_parked\packs) and
-- cj_core swaps it in at the next start, before the engine mounts the DLCs (play.park_later).
-- -> the folder the new pack is in, true when it goes into the game only at its next start
function FU.install(game, dlc, packed)
  local B, FS = require("conjunction.build"), require("conjunction.fsutil")
  local dest = game .. "\\dlc\\" .. dlc
  local parked = game .. "\\_conjunction_parked"
  local old = parked .. "\\old\\" .. dlc
  if w3.fs.exists(old) then FS.rmtree(old) end              -- (the one swapped out at the last start)
  if not w3.fs.exists(dest) then
    FS.copytree(packed, dest)
    return dest, false
  end
  B.makedirs(parked .. "\\old")
  if w3.fs.rename(dest, old) then                           -- (the game has not loaded it)
    FS.copytree(packed, dest)
    FS.rmtree(old)
    return dest, false
  end
  local wait = parked .. "\\packs\\" .. dlc
  if w3.fs.exists(wait) then FS.rmtree(wait) end
  FS.copytree(packed, wait)
  require("conjunction.play").park_later(game, {{"dlc\\" .. dlc, "_conjunction_parked\\old\\" .. dlc},
                                                {"_conjunction_parked\\packs\\" .. dlc, "dlc\\" .. dlc}})
  return wait, true
end

-- the folder's FBX files and decal pictures -> an installed content pack -> its folder
-- (step(i, n, text): called as each of the long steps begins - the window's progress, MaximdeWinter 13.11.)
function FU.build_pack(folder, meta, install, log, work, step)
  if install == nil then install = true end
  log = log or print
  local B = require("conjunction.build")
  local PM = require("conjunction.packmaker")
  local FS = require("conjunction.fsutil")
  local C = require("conjunction.content")
  local cfg = require("conjunction.config").load()
  local pid = FU.slug(P.or_(P.get(meta, "id"), P.get(meta, "name"), (folder:gsub("[\\/]+$", "")):match("([^\\/]*)$")))
  if pid == "" then require("conjunction.questgen").fail("The pack needs a name") end
  local dlc = "dlc" .. pid
  work = work or (require("conjunction.paths").DATA .. "\\packs_work\\" .. pid)
  local raw = work .. "\\imported"
  local extra, ents = Y.map(), Y.map()
  local things, pictures, items = FU.plan(folder), FU.decals(folder), FU.pack_items(folder)
  if #things == 0 and #pictures == 0 and next(Y.keys(items)) == nil then
    require("conjunction.questgen").fail("no .fbx files, no .decal pictures and no items.yml in " .. folder)
  end
  local total, done = FU.step_count(things, pictures, install), 0
  local function go(text)
    done = done + 1
    if step then step(done, total, text) end
  end
  for _, pc in ipairs(pictures) do
    local rel = "dlc\\" .. dlc .. "\\data\\decals\\" .. pc[1] .. ".xbm"
    go("Importing " .. pc[2]:match("([^\\/]*)$"))
    FU.wcc_import(pc[2], raw .. "\\" .. rel, log)
    extra[rel] = raw .. "\\" .. rel
    ents[pid .. "_" .. pc[1]] = decal_entity(rel, pc[3])
  end
  for _, t in ipairs(things) do
    local name, fbx, diff, norm = t[1], t[2], t[3], t[4]
    local mesh_rel = "dlc\\" .. dlc .. "\\data\\furniture\\" .. name .. ".w2mesh"
    local mesh = raw .. "\\" .. mesh_rel
    go("Importing " .. fbx:match("([^\\/]*)$"))
    FU.wcc_import(fbx, mesh, log)
    local tex = {}
    for _, ki in ipairs({{"d", diff}, {"n", norm}}) do
      if ki[2] then
        local rel = "dlc\\" .. dlc .. "\\data\\furniture\\textures\\" .. name .. "_" .. ki[1] .. ".xbm"
        go("Importing " .. ki[2]:match("([^\\/]*)$"))
        FU.wcc_import(ki[2], raw .. "\\" .. rel, log)
        extra[rel] = raw .. "\\" .. rel
        tex[ki[1]] = rel
      end
    end
    if tex.d then FU.texture_mesh(mesh, tex.d, tex.n)
    else log(string.format("[furniture] %s: no colour texture next to it (%s_d.png), shown grey", name, name)) end
    if P.get(meta, "collision", true) ~= false then FU.add_box_collision(mesh) end
    extra[mesh_rel] = mesh
    ents[pid .. "_" .. name] = Y.map({"entityObject", Y.map({".type", "CEntity", "components", Y.map({"mesh", Y.map({
      ".type", "CStaticMeshComponent", "isStreamed", false, "mesh", mesh_rel})})})})
  end
  local defdir = work .. "\\definition.quest"
  if w3.fs.isdir(defdir) then FS.rmtree(defdir) end
  B.makedirs(defdir)
  local prod = Y.map({"production", Y.map({"settings", Y.map({
    "id", pid, "caption", P.or_(P.get(meta, "name"), pid), "description", P.or_(P.get(meta, "description"), "furniture"),
    "menuvisibile", false, "enabled", true, "storesdata", false, "strings-idspace", 9997, "strings-idstart", 0,
    "version", 12})})})
  local o = {sort_keys = false, default_flow_style = false}
  Y.write(defdir .. "\\prod.quest-" .. pid .. ".yml", prod, o)
  Y.write(defdir .. "\\structure.root.yml", Y.map({"structure", Y.map({"quest", Y.map({"blocks", Y.map({
    "start", Y.map({"next", Y.list({"end"})}), "end", Y.map({"next", ".done"})})})})}), o)
  if next(Y.keys(ents)) ~= nil then Y.write(defdir .. "\\entities.furniture.yml", Y.map({"entities", ents}), o) end
  if next(Y.keys(items)) ~= nil then
    local own = Y.map()
    for iid, d in pairs(items) do
      local e = Y.map()
      for _, kv in ipairs({{"name", P.or_(P.get(d, "name"), iid)}, {"description", P.get(d, "description", "")},
                           {"text", P.get(d, "text", "")}}) do
        if P.T(kv[2]) then e[kv[1]] = kv[2] end
      end
      own[iid] = e
    end
    Y.write(defdir .. "\\items.yml", Y.map({"items", Y.map({"own", own})}),
            {sort_keys = false, default_flow_style = false, allow_unicode = true})
  end
  go("Building the DLC")
  local packed = B.build_dlc(defdir, work, false, log, nil, extra, FU.item_xml_fixer(pid, items, log))
  -- the textures cooked into the DLC's texture cache, the boxes into its collision cache
  local content_dir = packed .. "\\content"
  local db = work .. "\\cook.db"
  local caches = {}
  for rel in pairs(extra) do if rel:sub(-4) == ".xbm" then caches[1] = {"textures", "texture.cache"} break end end
  caches[#caches + 1] = {"physics", "collision.cache"}
  local wdir = cfg.wcc:match("^(.*)\\[^\\]*$")
  for _, kn in ipairs(caches) do
    log(string.format("[furniture] %s: %s cache", pid, kn[1]))
    go(kn[1] == "textures" and "Building the texture cache" or "Building the collision cache")
    B.run({cfg.wcc, "buildcache", kn[1], "-platform=pc", "-db=" .. db, "-out=" .. content_dir .. "\\" .. kn[2]}, wdir, log)
  end
  go("Writing the metadata")
  B.run({cfg.wcc, "metadatastore", "-path=" .. content_dir}, wdir, log)
  local target, later = packed, false
  if install then
    go("Installing into the game")
    target, later = FU.install(cfg.game, dlc, packed)
  end
  local m2 = Y.map()
  for k, v in pairs(P.map(meta)) do m2[k] = v end
  m2.id = pid
  local m = PM.write(target, m2)
  if install then                               -- (the card goes with the pack when it is shared)
    for _, f in ipairs({C.MARKER, C.INDEX}) do assert(w3.fs.copy(target .. "\\" .. f, packed .. "\\" .. f)) end
  end
  local n = 0
  for _ in pairs(items) do n = n + 1 end
  log(string.format("[furniture] %s %s: %d pieces, %d decals, %d items -> %s%s", m.name, m.version, #things, #pictures,
                    n, target, later and " (into the game at its next start)" or ""))
  return target, later
end

return FU
