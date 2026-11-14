-- The mesh and foliage libraries (meshlib.py, foliage.py), built in the game: once on the user's machine, a DLC with
-- one small entity per mesh of the world (walls, roofs, rocks, crates) and per tree, bush and flower (with the tree's
-- own collision as convex prisms) - nothing of the game is copied, the entities point at the game's files.
--   LIB.build_meshes(log [, limit])     LIB.build_foliage(log [, limit])     (in a coroutine: ed:job)
--   LIB.meshes(depot) / LIB.decals(depot) / LIB.trees(depot)   what goes in, sorted
--   LIB.generate_meshes(defdir, meshes, decals) / LIB.generate_foliage(work, trees, log)   the radish definition
-- The parts they share with a quest's build (a tree's entity and collision, a decal's entity, the names) are
-- project_gen.lua's.
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local CFG = require("conjunction.config")
local PATHS = require("conjunction.paths")
local PYS = require("conjunction.pystr")
local PS = require("conjunction.pysort")
local R = require("conjunction.pyre")
local GEN = require("conjunction.questgen_main")
local PG = require("conjunction.project_gen")
local LIB = {}

local M, L = GEN.map, GEN.list
local function data_dir() return (PATHS.DATA .. "\\x"):gsub("[\\/][^\\/]*$", "") end
local function join(...) return table.concat({...}, "\\") end
local function rmtree(d) if w3.fs.isdir(d) then require("conjunction.fsutil").rmtree(d) end end

LIB.MESH_DLC, LIB.FOLIAGE_DLC = "conjunctionmeshes", "conjunctionfoliage"
-- world building meshes; not: characters (body parts), items (have templates), merged sector meshes, engine, fx
LIB.KEEP = R.compile([[^(dlc\\[^\\]+\\(data\\)?)?environment\\|^gameplay\\]])
LIB.DROP = R.compile([[proxy|\\lod\d|_lod\d|shadow|\\collision|_col\.w2mesh$|occluder|\\terrain\\|\\foliage\\|]] ..
                     [[\\trees?\\|\\grass\\|\\water\\]])
-- a decal's picture, not one of its other maps (normal, specular, height, mask ...)
LIB.DECAL_MAPS = R.compile([[(_n|_nm|_nrm|_normal|_s|_spec|_h|_a|_alpha|_m|_mask|_r|_rough|_e|_ao)\d*\.xbm$]])

local function depot()
  return require("conjunction.depot").open(CFG.load().game)
end

-- every environment mesh of the game (meshlib.meshes) -> sorted depot paths
function LIB.meshes(d)
  d = d or depot()
  local out = {}
  for _, p in ipairs(d:glob("", ".w2mesh")) do
    if LIB.KEEP:search(p) and not LIB.DROP:search(p) then out[#out + 1] = p end
  end
  return PS.sorted(out)
end

-- the game's decal pictures, base game and expansions (meshlib.decals)
function LIB.decals(d)
  d = d or depot()
  local C = require("conjunction.content")
  local out = {}
  for _, p in ipairs(d:glob("", ".xbm")) do
    if p:find("decal", 1, true) and C.VANILLA_FILE:match(p) and not LIB.DECAL_MAPS:search(p) and
        p:sub(1, 11) ~= "characters\\" and not p:find("censored", 1, true) then
      out[#out + 1] = p
    end
  end
  return PS.sorted(out)
end

local function settings(id, caption, description, idspace)
  return M("production", M("settings", M("id", id, "caption", caption, "description", description,
                                         "menuvisibile", false, "enabled", true, "storesdata", false,
                                         "strings-idspace", idspace, "strings-idstart", 0, "version", 12)))
end
local function empty_quest()
  return M("structure", M("quest", M("blocks", M("start", M("next", Y.list({"end"})), "end", M("next", ".done")))))
end
local function dump(path, data) Y.write(path, data, {sort_keys = false, default_flow_style = false}) end   -- (safe_dump)

-- radish definition (meshlib.generate): production, an empty quest (the DLC needs one), the editor's lamp, entities
-- in files of 2000, the decal pictures -> {mesh: template}, {decal texture: template}
function LIB.generate_meshes(defdir, mesh_list, decal_list)
  if not w3.fs.isdir(defdir) then require("conjunction.build").makedirs(defdir) end
  for _, e in ipairs(w3.fs.list(defdir) or {}) do
    if not e.dir and e.name:sub(-4) == ".yml" then w3.fs.remove(join(defdir, e.name)) end
  end
  local id = LIB.MESH_DLC
  dump(join(defdir, "prod.quest-" .. id .. ".yml"), settings(id, "conjunction mesh library",
       "every environment mesh as a placeable entity (generated locally)", 9998))
  dump(join(defdir, "structure.root.yml"), empty_quest())
  -- the editor's lamp (H, conjunction_editor.ws CjLamp): a flashlight where the camera looks, wider and farther than
  -- the game's own lamp, without flickering and shadows
  local lamp = M("entityObject", M(".type", "CEntity", "components", M("lamp", M(
    ".type", "CSpotLightComponent", "radius", 25.0, "brightness", 25.0, "outerAngle", 70.0, "softness", 2.0,
    "color", Y.list({255, 246, 232, 255}), "shadowCastingMode", "LSCM_None", "autoHideDistance", 80.0))))
  dump(join(defdir, "entities.lamp.yml"), M("entities", M("cj_editor_lamp", lamp)))
  local index, dindex = Y.map(), Y.map()
  for k = 1, #mesh_list, 2000 do
    local ents = Y.map()
    for i = k, math.min(#mesh_list, k + 1999) do
      local m = mesh_list[i]
      local name = PG.mesh_entity_name(m)
      ents[name] = PG.mesh_wrapper(m)
      index[m] = join("dlc", "dlc" .. id, "data", "entities", name .. ".w2ent")
    end
    dump(join(defdir, string.format("entities.%03d.yml", (k - 1) // 2000)), M("entities", ents))
  end
  if #decal_list > 0 then
    local ents = Y.map()
    for _, tex in ipairs(decal_list) do
      local name = PG.decal_entity_name(tex)
      ents[name] = PG.decal_entity(tex, {1.0, 1.0})
      dindex[tex] = join("dlc", "dlc" .. id, "data", "entities", name .. ".w2ent")
    end
    dump(join(defdir, "entities.decals.yml"), M("entities", ents))
  end
  return index, dindex
end

-- meshlib.build: generate, encode, cook, pack, install; the catalog's index files
function LIB.build_meshes(log, limit)
  local A = require("conjunction.assets")
  local B = require("conjunction.build")
  local out = join(data_dir(), "meshlib")
  local d = depot()
  local mesh_list = LIB.meshes(d)
  if limit then for i = #mesh_list, limit + 1, -1 do mesh_list[i] = nil end end
  log(string.format("[meshlib] %d meshes", #mesh_list))
  local decal_list = LIB.decals(d)
  log(string.format("[meshlib] %d decal pictures", #decal_list))
  local index, dindex = LIB.generate_meshes(join(out, "definition.quest"), mesh_list, decal_list)
  B.build_dlc(join(out, "definition.quest"), out, true, log)
  J.write(A.MESHES, index, {})
  J.write(A.DECALS, dindex, {})
  log("[meshlib] catalog index -> " .. A.MESHES)
end

-- the game's foliage resources (foliage.trees: radish's list of them, the ones this game has) -> sorted depot paths
function LIB.trees(d)
  d = d or depot()
  local cfg = CFG.load()
  local text = w3.fs.read(join(cfg.radish, "repo.quests", "all.foliage.repo.yml")) or ""
  local seen, out = {}, {}
  for p in text:gmatch(":%s*(%S+%.srt)") do
    local path = PYS.lower((p:gsub("/", "\\")))
    if not seen[path] and d:exists((p:gsub("/", "\\"))) then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  return PS.sorted(out)
end

-- foliage.generate: the radish definition and the collision meshes -> {tree: template}, {depot path: file}
function LIB.generate_foliage(work, tree_list, log)
  local defdir = join(work, "definition.quest")
  rmtree(defdir)
  require("conjunction.build").makedirs(defdir)
  local id = LIB.FOLIAGE_DLC
  dump(join(defdir, "prod.quest-" .. id .. ".yml"), settings(id, "conjunction foliage library",
       "the game's trees as placeable entities", 9996))
  dump(join(defdir, "structure.root.yml"), empty_quest())
  local d = depot()
  local index, extra, ents, with_coll = Y.map(), Y.map(), Y.map(), 0
  for _, t in ipairs(tree_list) do
    local name = PG.foliage_entity_name(t)
    local info = PG.srt_read(d:read(t)) or {}
    local coll_rel
    if info.collision and #info.collision > 0 then
      coll_rel = join("dlc", "dlc" .. id, "data", "collision", name .. ".w2mesh")
      local dst = join(work, "collision", name .. ".w2mesh")
      PG.collision_mesh(dst, info.collision)
      extra[coll_rel] = dst
      with_coll = with_coll + 1
    end
    ents[name] = PG.foliage_entity(t, coll_rel)
    index[t] = join("dlc", "dlc" .. id, "data", "entities", name .. ".w2ent")
  end
  dump(join(defdir, "entities.yml"), M("entities", ents))
  log(string.format("[foliage] %d trees, %d with collision", #tree_list, with_coll))
  return index, extra
end

-- foliage.build: generate, encode, cook (with the collision cache), install
function LIB.build_foliage(log, limit, only)
  local B = require("conjunction.build")
  local cfg = CFG.load()
  local work = join(data_dir(), "foliagelib")
  local tree_list = only or LIB.trees()
  if limit then for i = #tree_list, limit + 1, -1 do tree_list[i] = nil end end
  local index, extra = LIB.generate_foliage(work, tree_list, log)
  -- (the collision meshes carry buffers: build_dlc lets wcc_lite pack them, and cooks their collision cache)
  local packed = B.build_dlc(join(work, "definition.quest"), work, false, log, nil, extra, nil, true)
  local target = join(cfg.game, "dlc", "dlc" .. LIB.FOLIAGE_DLC)
  rmtree(target)
  require("conjunction.fsutil").copytree(packed, target)
  log("[foliage] installed -> " .. target)
  J.write(join(data_dir(), "foliage.json"), index, {})
  return packed
end

return LIB
