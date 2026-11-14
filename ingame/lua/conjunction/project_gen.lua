-- Project.generate (project.py): the radish quest definition of a project written into a folder - production, one
-- layer per place, the structure, the journal, the quest's own entities (mesh library wrappers, planted trees with
-- their collision, decals, hide areas), items, rewards, communities, the scenes, the names, minigames, keyed texts
-- and own recordings beside it - the same files the app writes.
--   PG.generate(project, defdir, skip_templates) -> defdir      (project: {meta, places, id, base_id, path, ...})
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local N = require("conjunction.pynum")
local J = require("conjunction.json")
local PATHS = require("conjunction.paths")
local Q = require("conjunction.quest")
local GEN = require("conjunction.questgen_main")
local CR = require("conjunction.cr2w")
local H = require("conjunction.hashlib")
local M, L, F, S = GEN.map, GEN.list, GEN.float, GEN.str
local T, get = P.T, P.get
local PG = {}

local function fs() return w3.fs end
local function dirname(p) return (p:gsub("[\\/][^\\/]*$", "")) end
local function basename(p) return (p:gsub("^.*[\\/]", "")) end
local function stem(p) return (basename(p):gsub("%.[^.]*$", "")) end
local function join(...) return table.concat({...}, "\\") end
local function mkdirs(d)
  if fs().isdir(d) then return end
  mkdirs(dirname(d))
  fs().mkdir(d)
end
local function write_yaml(path, data, opts) Y.write(path, data, opts) end
local function remove_ymls(d)
  for _, e in ipairs(fs().list(d) or {}) do
    if not e.dir and e.name:match("%.yml$") then fs().remove(join(d, e.name)) end
  end
end
local function rmtree(d)
  for _, e in ipairs(fs().list(d) or {}) do
    local p = join(d, e.name)
    if e.dir then rmtree(p) else fs().remove(p) end
  end
  fs().rmdir(d)
end
local function read_json(path, default)
  if not fs().exists(path) then return default end
  local ok, v = pcall(J.read, path)
  if ok then return v end
  return default
end
-- re.sub(r"[^a-z0-9_]", "_", name.lower())[:40]
local function slug40(name)
  local s = PYS.lower(name):gsub("[^a-z0-9_]", "_")
  local cps = PYS.cps(s)
  if #cps > 40 then s = PYS.from_cps(cps, 1, 40) end
  return s
end

-- --- the mesh library (meshlib.py): a mesh of the game as a placeable entity of Conjunction's own
local function data_file(name) return dirname(PATHS.DATA .. "\\x") .. "\\" .. name end
function PG.mesh_reverse_index()
  local out = {}
  local idx = read_json(require("conjunction.assets").MESHES, {})
  for m, t in pairs(idx) do out[PYS.lower(t)] = m end
  return out
end
function PG.mesh_entity_name(mesh) return "m_" .. slug40(stem(mesh)) .. "_" .. H.md5(mesh):sub(1, 6) end
function PG.mesh_wrapper(mesh)
  return M("entityObject", M(".type", "CEntity", "components", M("mesh", M(
    ".type", "CStaticMeshComponent", "isStreamed", false, "mesh", mesh))))
end
function PG.decal_reverse_index()
  local out = {}
  local idx = read_json(require("conjunction.assets").DECALS, {})
  for tex, t in pairs(idx) do out[PYS.lower(t)] = tex end
  return out
end
function PG.decal_entity_name(texture) return "d_" .. slug40(stem(texture)) .. "_" .. H.md5(texture):sub(1, 6) end

-- --- furniture.py: decals and the CR2W pieces
local function slug(text) return (PYS.lower(S(text)):gsub("[^a-z0-9_]+", "_"):gsub("^_+", ""):gsub("_+$", "")) end
function PG.decal_name(texture, size)
  local base = slug(stem(P.replace(S(texture), "\\", "/")))
  local cps = PYS.cps(base)
  if #cps > 40 then base = PYS.from_cps(cps, 1, 40) end
  local parts = {}
  for k = 1, 2 do parts[k] = string.format("%g", F(size[k])) end       -- (f"{v:g}")
  return "decal_" .. base .. "_" .. P.replace(table.concat(parts, "x"), ".", "_")
end
function PG.decal_entity(texture, size, depth)
  depth = depth or 0.6
  return M("entityObject", M(".type", "CEntity", "components", M("decal", M(
    ".type", "CDecalComponent", "diffuseTexture", texture, "specularity", 0.2,
    "transform", M("pos", L(0, 0, 0), "scale", L(F(size[1]), F(size[2]), depth))))))
end
function PG.decal_template(qid, texture, size)
  return table.concat({"dlc", "dlc" .. qid, "data", "entities", PG.decal_name(texture, size) .. ".w2ent"}, "\\")
end
-- a property: name, type, size (counting itself), value
local function prop(f, name, typ, value) return string.pack("<I2I2I4", f:add_name(name), f:add_name(typ), #value + 4) .. value end
local function floats(f, fields, values)
  local out = {"\0"}
  for k, n in ipairs(fields) do out[#out + 1] = prop(f, n, "Float", string.pack("<f", values[k])) end
  out[#out + 1] = "\0\0"
  return table.concat(out)
end
PG.prop, PG.floats = prop, floats

-- --- the foliage library (foliage.py): a tree as an entity; a planted tree's collision made beside the quest
PG.FOLIAGE_SIDES = 8
PG.FOLIAGE_MATERIAL = "wood_solid"
function PG.foliage_reverse_index()
  local out = {}
  for tree, t in pairs(read_json(data_file("foliage.json"), {})) do out[PYS.lower(t)] = tree end
  return out
end
function PG.foliage_entity_name(tree) return "f_" .. slug40(stem(tree)) .. "_" .. H.md5(tree):sub(1, 6) end
function PG.foliage_entity(tree, coll_rel)
  local comps = M("tree", M(".type", "CDynamicFoliageComponent", "baseTree", P.replace(tree, "\\", "/"), "isStreamed", false))
  if coll_rel then
    comps.collision = M(".type", "CStaticMeshComponent", "isStreamed", false, "mesh", coll_rel, "drawableFlags", Y.list({}))
  end
  return M("entityObject", M(".type", "CEntity", "components", comps))
end

-- srt.py: a tree resource's extents and collision objects (SpeedTree 7 data inside a CR2W file)
local HEAD = "SRT 07.0.0"
local function string_table(data, k)
  local off = k + 16
  while off < #data - 16 do
    local n = string.unpack("<i4", data, off + 1)
    if n >= 3 and n <= 256 then
      local sizes_end = off + 4 + 8 * n
      if sizes_end <= #data then
        local ok = true
        local lens = {}
        for i = 0, n - 1 do
          local z, x = string.unpack("<i4i4", data, off + 4 + 8 * i + 1)
          if z ~= 0 or x <= 0 or x % 4 ~= 0 or x > 1024 then ok = false break end
          lens[#lens + 1] = x
        end
        if ok then
          local pos, names = sizes_end, {}
          for _, x in ipairs(lens) do
            local s = data:sub(pos + 1, pos + x)
            if #s < x or s:sub(-1) ~= "\0" then ok = false break end
            local head = s:match("^([^%z]*)")
            for c = 1, #head do
              local b = head:byte(c)
              if b < 32 or b >= 127 then ok = false break end
            end
            if not ok then break end
            names[#names + 1] = head
            pos = pos + x
          end
          if ok then
            for _, nm in ipairs(names) do
              local low = nm:lower()
              if low:match("%.dds$") or low:match("%.tga$") or low:match("%.png$") then return off, pos end
            end
          end
        end
      end
    end
    off = off + 4
  end
  return nil
end
function PG.srt_read(data)
  local k0 = data:find(HEAD, 1, true)
  if not k0 then return nil end
  local k = k0 - 1
  local ext = {string.unpack("<ffffff", data, k + 21)}
  local _, e = string_table(data, k)
  if not e then return nil end
  local n = string.unpack("<i4", data, e + 1)
  if n < 0 or n > 64 then return nil end
  local out = {}
  for i = 0, n - 1 do
    local o = e + 4 + 36 * i
    local v = {string.unpack("<fffffff", data, o + 8 + 1)}
    if v[7] > 0 then out[#out + 1] = {{v[1], v[2], v[3]}, {v[4], v[5], v[6]}, v[7]} end
  end
  return {extents = {{ext[1], ext[2], ext[3]}, {ext[4], ext[5], ext[6]}}, collision = out}
end

-- a capsule as a convex prism: sides around the axis c1 -> c2, reaching r past both ends -> vertices, polygons
function PG.prism(c1, c2, r, sides)
  sides = sides or PG.FOLIAGE_SIDES
  local ax = {c2[1] - c1[1], c2[2] - c1[2], c2[3] - c1[3]}
  local length = math.sqrt(0 + ax[1] * ax[1] + ax[2] * ax[2] + ax[3] * ax[3])
  if length < 1e-4 then ax, length = {0.0, 0.0, 1.0}, 0.0 end
  local d = length ~= 0 and {ax[1] / length, ax[2] / length, ax[3] / length} or ax
  local lo = {c1[1] - d[1] * r, c1[2] - d[2] * r, c1[3] - d[3] * r}
  local hi = {c1[1] + d[1] * (length + r), c1[2] + d[2] * (length + r), c1[3] + d[3] * (length + r)}
  local helper = math.abs(d[1]) < 0.9 and {1.0, 0.0, 0.0} or {0.0, 1.0, 0.0}
  local u = {d[2] * helper[3] - d[3] * helper[2], d[3] * helper[1] - d[1] * helper[3], d[1] * helper[2] - d[2] * helper[1]}
  local nu = math.sqrt(0 + u[1] * u[1] + u[2] * u[2] + u[3] * u[3])
  u = {u[1] / nu, u[2] / nu, u[3] / nu}
  local w = {d[2] * u[3] - d[3] * u[2], d[3] * u[1] - d[1] * u[3], d[1] * u[2] - d[2] * u[1]}
  local ring = {}
  for i = 0, sides - 1 do
    ring[#ring + 1] = {math.cos(2 * math.pi * i / sides) * r, math.sin(2 * math.pi * i / sides) * r}
  end
  local verts = {}
  for _, ab in ipairs(ring) do
    verts[#verts + 1] = {lo[1] + ab[1] * u[1] + ab[2] * w[1], lo[2] + ab[1] * u[2] + ab[2] * w[2], lo[3] + ab[1] * u[3] + ab[2] * w[3]}
  end
  for _, ab in ipairs(ring) do
    verts[#verts + 1] = {hi[1] + ab[1] * u[1] + ab[2] * w[1], hi[2] + ab[1] * u[2] + ab[2] * w[2], hi[3] + ab[1] * u[3] + ab[2] * w[3]}
  end
  local polys = {sides}
  for i = sides - 1, 0, -1 do polys[#polys + 1] = i end
  polys[#polys + 1] = sides
  for i = sides, 2 * sides - 1 do polys[#polys + 1] = i end
  for i = 0, sides - 1 do
    local j = (i + 1) % sides
    for _, x in ipairs({4, i, j, sides + j, sides + i}) do polys[#polys + 1] = x end
  end
  return verts, polys
end

function PG.base_mesh()
  if PATHS.REPO then return PATHS.REPO .. "\\conjunction\\data\\collision_base.w2mesh" end
  return PATHS.MOD_ROOT .. "\\data\\collision_base.w2mesh"
end

-- a mesh that draws nothing of its own and collides like the tree: the base mesh with a CCollisionMesh of one
-- convex prism per capsule
function PG.collision_mesh(path, capsules, material)
  material = material or PG.FOLIAGE_MATERIAL
  local f = CR.parse(assert(fs().read(PG.base_mesh())))
  local mesh = f.exports[1]
  local props = f:props(mesh[5])
  for _, n in ipairs({"collisionMesh", "handle:CCollisionMesh", "CCollisionMesh", "shapes", "array:2,0,ptr:ICollisionShape",
                      "CCollisionShapeConvex", "vertices", "array:99,0,Vector", "polygons", "array:99,0,Uint16", "Vector",
                      "X", "Y", "Z", "W", "Float", "physicalMaterialName", "CName", material}) do f:add_name(n) end
  local k_mesh = #f.exports
  local shapes = {}
  for _, c in ipairs(capsules) do
    local verts, polys = PG.prism(c[1], c[2], c[3])
    local av = {string.pack("<I4", #verts)}
    for _, v in ipairs(verts) do av[#av + 1] = floats(f, {"X", "Y", "Z", "W"}, {v[1], v[2], v[3], 1.0}) end
    local ap = {string.pack("<I4", #polys)}
    for _, x in ipairs(polys) do ap[#ap + 1] = string.pack("<I2", x) end
    shapes[#shapes + 1] = "\0" .. prop(f, "physicalMaterialName", "CName", string.pack("<I2", f:add_name(material))) ..
                          prop(f, "vertices", "array:99,0,Vector", table.concat(av)) ..
                          prop(f, "polygons", "array:99,0,Uint16", table.concat(ap)) .. "\0\0"
  end
  local refs = {string.pack("<I4", #shapes)}
  for i = 0, #shapes - 1 do refs[#refs + 1] = string.pack("<i4", k_mesh + 2 + i) end
  f.exports[#f.exports + 1] = {"CCollisionMesh", 0, 1, 0, "\0" .. prop(f, "shapes", "array:2,0,ptr:ICollisionShape",
                                                                         table.concat(refs)) .. "\0\0"}
  for _, s in ipairs(shapes) do f.exports[#f.exports + 1] = {"CCollisionShapeConvex", 0, k_mesh + 1, 0, s} end
  local after = props[#props]
  for _, p in ipairs(props) do if p[1] == "autoHideDistance" then after = p break end end
  local at = after[3] + after[4]
  mesh[5] = mesh[5]:sub(1, at) .. prop(f, "collisionMesh", "handle:CCollisionMesh", string.pack("<i4", k_mesh + 1)) ..
            mesh[5]:sub(at + 1)
  mkdirs(dirname(path))
  assert(fs().write(path .. ".tmp", f:save()))
  if fs().exists(path) then fs().remove(path) end
  fs().rename(path .. ".tmp", path)
end

-- a planted tree in a quest: its collision mesh beside the quest's definition, handed to the build -> its depot path
-- in the quest's DLC, or nil when the tree has no collision
function PG.quest_collision(project, tree, defdir)
  local depot = require("conjunction.depot").open(require("conjunction.config").load().game)
  local info = PG.srt_read(depot:read(tree)) or {}
  if not info.collision or #info.collision == 0 then return nil end
  local name = PG.foliage_entity_name(tree)
  local rel = table.concat({"dlc", "dlc" .. project.id, "data", "collision", name .. ".w2mesh"}, "\\")
  local path = join(dirname(defdir), "collision", name .. ".w2mesh")
  PG.collision_mesh(path, info.collision)
  project.extra_resources[rel] = path
  return rel
end

-- --- envhide.py: an area where the game's terrain / foliage / water is not drawn
function PG.envhide_entity_name(place, oid) return PYS.lower("cj_envhide_" .. S(place) .. "_" .. S(oid)) end
function PG.envhide_entity(spec)
  local pts = Y.list({})
  for _, p in ipairs(P.list(get(spec, "points"))) do pts[#pts + 1] = L(F(p[1]), F(p[2]), 0.0, 1.0) end
  if #pts < 3 then GEN.fail("A hide area needs at least three points") end
  return M("entityObject", M(".type", "CEntity", "components", M("hide", M(
    ".type", "CTriggerAreaEnvironmentVisibilityComponent", "height", F(get(spec, "height", 20.0)), "localPoints", pts,
    "hideFoliage", T(get(spec, "foliage", true)), "hideTerrain", T(get(spec, "terrain", false)),
    "hideWater", T(get(spec, "water", false))))))
end

-- --- the quest graph's own objectives (graph_journal.yml)
PG.GRAPH_JOURNAL = "graph_journal.yml"
function PG.graph_objectives(path)
  if not path then return {} end
  local f = join(path, PG.GRAPH_JOURNAL)
  if not fs().exists(f) then return {} end
  local doc = Y.read(f)
  return P.list(get(doc or Y.map(), "objectives"))
end
-- an objective more, made in the quest graph (in the journal from the next build on) -> its id
function PG.new_graph_objective(path, caption)
  local have = PG.graph_objectives(path)
  local out = Y.list({})
  for i, o in ipairs(have) do out[i] = o end
  local oid = "zgraph" .. (#have + 1)
  out[#out + 1] = M("id", oid, "caption", caption)
  Y.write(join(path, PG.GRAPH_JOURNAL), M("objectives", out), {allow_unicode = true, default_flow_style = false})
  return oid
end

function PG.add_graph_objectives(path, journals)
  local extra = PG.graph_objectives(path)
  local quests = get(journals or Y.map(), "quests") or Y.map()
  if #extra == 0 or Y.len(quests) == 0 then return end
  local q = quests[Y.keys(quests)[1]]
  local main = GEN.setdefault(GEN.setdefault(q, "instructions", Y.map()), "main", Y.list({}))
  local have = {}
  for _, item in ipairs(main) do if Y.is_map(item) then for k in pairs(item) do have[k] = true end end end
  for _, o in ipairs(extra) do
    if not have[o.id] then main[#main + 1] = M(o.id, M("caption", o.caption)) end
  end
end

function PG.generate(project, defdir, skip_templates)
  skip_templates = skip_templates or {}
  mkdirs(defdir)
  remove_ymls(defdir)
  local id = project.id
  local prod = M("production", M("settings", M(
    "id", id, "caption", get(project.meta, "name", id), "description", get(project.meta, "description", ""),
    "menuvisibile", true, "enabled", true, "storesdata", false, "strings-idspace", GEN.idspace(id),
    "strings-idstart", 0, "version", 12)))
  write_yaml(join(defdir, "prod.quest-" .. id .. ".yml"), prod, {sort_keys = false, default_flow_style = false})
  local mesh_of = PG.mesh_reverse_index()
  local tree_of = PG.foliage_reverse_index()
  local own_entities = Y.map()
  project.extra_resources = Y.map()
  local depot = require("conjunction.depot").open(require("conjunction.config").load().game)
  project.skipped = {}
  local own_prefix = PYS.lower("dlc\\dlc" .. id .. "\\")
  local function missing(template)
    if template == "cj_envhide" then return false end
    if tree_of[PYS.lower(template)] then return false end
    local res = mesh_of[PYS.lower(template)] or template
    local low = PYS.lower(res)
    return not (P.startswith(low, "dlc\\dlcconjunction") or P.startswith(low, own_prefix)) and not depot:exists(res)
  end
  local kept = Y.map()
  for _, name in ipairs(Y.keys(project.places)) do
    local p = project.places[name]
    local objs = Y.list({})
    for _, o in ipairs(P.list(get(p, "objects"))) do
      if not Q.is_actor(o) and missing(o.template) then
        project.skipped[#project.skipped + 1] = name .. "/" .. S(P.or_(get(o, "id"), o.template)) .. " (not in this version of the game)"
      elseif skip_templates[PYS.lower(o.template)] then
        project.skipped[#project.skipped + 1] = name .. "/" .. S(P.or_(get(o, "id"), o.template)) .. " (REDkit cannot cook it)"
      else
        objs[#objs + 1] = o
      end
    end
    kept[name] = GEN.with(p, "objects", objs)
  end
  local all_places = project.places
  project.places = kept
  local ok, a, b, c, d, e, f_, g, h, i = pcall(GEN.generate, project, project.plugin_blocks)
  project.places = all_places
  if not ok then error(a, 0) end
  local blocks, journals, meta, tags, communities, scenes, rewards, speech, items = a, b, c, d, e, f_, g, h, i
  local decal_of = PG.decal_reverse_index()
  local function own_mesh(template)
    local tex = decal_of[PYS.lower(template)]
    if tex then
      local ename = PG.decal_entity_name(tex)
      own_entities[ename] = PG.decal_entity(tex, {1.0, 1.0})
      return table.concat({"dlc", "dlc" .. id, "data", "entities", ename .. ".w2ent"}, "\\")
    end
    local tree = tree_of[PYS.lower(template)]
    if tree then
      local ename = PG.foliage_entity_name(tree)
      local coll = PG.quest_collision(project, tree, defdir)
      own_entities[ename] = PG.foliage_entity(tree, coll)
      return table.concat({"dlc", "dlc" .. id, "data", "entities", ename .. ".w2ent"}, "\\")
    end
    local mesh = mesh_of[PYS.lower(template)]
    if not mesh then return template end
    local ename = PG.mesh_entity_name(mesh)
    own_entities[ename] = PG.mesh_wrapper(mesh)
    return table.concat({"dlc", "dlc" .. id, "data", "entities", ename .. ".w2ent"}, "\\")
  end
  local layers = Y.map()
  for _, name in ipairs(Y.keys(kept)) do
    local p = kept[name]
    if T(get(p, "objects")) then
      local statics = Y.map()
      for k0, o in ipairs(p.objects) do
        local i0 = k0 - 1
        local oid_or = T(get(o, "id")) and S(o.id) or string.format("obj%03d", i0)
        if Q.is_actor(o) or T(get(o, "marker")) then
          -- (NPCs come as a community; spot markers stay in the editor)
        elseif T(get(o, "trail")) then
          if not (project.step_trails or {})[name .. "/" .. S(get(o, "id"))] then
            for n, pc in ipairs(P.list(get(o, "pieces"))) do
              statics[string.format("%s_p%02d", oid_or, n - 1)] = M("template", pc[5], "pos", L(F(pc[1]), F(pc[2]), F(pc[3])),
                                                                    "rot", L(0.0, 0.0, F(pc[4])))
            end
          end
        else
          if T(get(o, "envhide")) then
            local ename = PG.envhide_entity_name(name, oid_or)
            own_entities[ename] = PG.envhide_entity(o.envhide)
            o = GEN.with(o, "template", table.concat({"dlc", "dlc" .. id, "data", "entities", ename .. ".w2ent"}, "\\"))
          end
          if T(get(o, "decal")) then
            local size = T(get(o, "size")) and o.size or {1.0, 1.0}
            local sz = {F(size[1]), F(size[2])}
            own_entities[PG.decal_name(o.decal, sz)] = PG.decal_entity(S(o.decal), sz)
            o = GEN.with(o, "template", PG.decal_template(id, o.decal, sz))
          end
          local s = M("template", own_mesh(o.template), "pos", o.pos, "rot", o.rot)
          if T(get(o, "id")) and tags[name .. "/" .. S(o.id)] ~= nil then s.tags = L(tags[name .. "/" .. S(o.id)]) end
          statics[oid_or] = s
        end
      end
      if Y.len(statics) > 0 then layers[name] = M("world", p.world, "statics", statics) end
    end
  end
  for _, w in ipairs(Y.keys(meta)) do
    local m = M("world", w)
    for k, v in pairs(meta[w]) do m[k] = v end
    layers[GEN.meta_layer(id, w)] = m
  end
  for k, v in pairs(project.step_layers or Y.map()) do layers[k] = v end
  for k, v in pairs(project.step_entities or Y.map()) do own_entities[k] = v end
  write_yaml(join(defdir, "layers.yml"), M("layers", layers), {sort_keys = false, default_flow_style = nil})
  PG.add_graph_objectives(project.path, journals)
  if T(journals) then write_yaml(join(defdir, "journals.yml"), M("journals", journals), {sort_keys = false, allow_unicode = true,
                                                                                      default_flow_style = false}) end
  local block = {sort_keys = false, default_flow_style = false}          -- (yaml.safe_dump's own default)
  if Y.len(own_entities) > 0 then write_yaml(join(defdir, "entities.yml"), M("entities", own_entities), block) end
  if T(items) then
    write_yaml(join(defdir, "items.yml"), M("items", M("own", items)), {sort_keys = false, allow_unicode = true,
                                                                        default_flow_style = false})
  end
  if T(rewards) then write_yaml(join(defdir, "rewards.yml"), M("rewards", rewards), block) end
  if T(communities) then write_yaml(join(defdir, "communities.yml"), M("communities", communities), block) end
  local up = dirname(defdir)
  local scenedir = join(up, "definition.scenes")
  if fs().isdir(scenedir) then remove_ymls(scenedir) end
  local gamedir = join(up, "definition.game")
  if fs().isdir(gamedir) then rmtree(gamedir) end
  -- a quest put into one of the game's quests: that phase, changed, to be built under the game's path
  local ig = get(get(project.meta, "quest") or Y.map(), "inside_game") or Y.map()
  if T(get(ig, "phase")) then
    local CE = require("conjunction.cr2w_edit")
    local f = require("conjunction.cr2w").parse(depot:read(ig.phase))
    local start_fact, over_fact = project.id .. "_inside", project.id .. "_over"     -- (quest.inside_facts)
    CE.insert_hook(f, math.tointeger(tonumber(P.str(ig.block))), get(ig, "socket"), start_fact, over_fact)
    local target = join(gamedir, (ig.phase:gsub("/", "\\")))
    mkdirs(dirname(target))
    assert(fs().write(target, f:save()))
  end
  -- game cutscenes replaced: every game scene that plays one, with the other one in it (cutscene_swap.lua)
  local CS = require("conjunction.cutscene_swap")
  local changes, change_keys, files = {}, {}, {}
  local whole = {}
  for _, sid in ipairs(Y.keys(P.map(get(project.meta, "swaps")))) do
    whole[require("conjunction.pystr").lower(P.str(get(project.meta.swaps[sid], "scene", "")))] = true
  end
  for _, cs in ipairs(P.list(get(project.meta, "cutscene_swaps"))) do
    if T(get(cs, "old")) and T(get(cs, "new")) then
      for _, scene in ipairs(CS.info(depot, cs.old).scenes) do
        if whole[require("conjunction.pystr").lower(scene)] then
          GEN.fail(scene:match("([^\\]*)$") .. " is already replaced as a whole, its cutscene cannot be replaced too")
        end
        if changes[scene] == nil then
          changes[scene] = {}
          change_keys[#change_keys + 1] = scene
        end
        changes[scene][cs.old] = cs.new
      end
      if T(get(cs, "file")) then              -- an own cutscene: into the mod bundle under its depot path
        files[cs.new] = cs.file
        local target = join(gamedir, cs.new)
        mkdirs(dirname(target))
        assert(fs().copy(cs.file, target))
      end
    end
  end
  for _, scene in ipairs(require("conjunction.pysort").sorted(change_keys)) do
    local data, hit = CS.swapped(depot, scene, changes[scene], files)
    if #hit > 0 then
      local target = join(gamedir, (scene:gsub("/", "\\")))
      mkdirs(dirname(target))
      assert(fs().write(target, data))
    end
  end
  local targets = Y.map()
  for _, name in ipairs(Y.keys(scenes)) do
    local t = get(scenes[name], "_target")
    if T(t) then targets[name] = Y.remove(scenes[name], "_target") end
  end
  if Y.len(targets) > 0 then
    mkdirs(scenedir)
    write_yaml(join(scenedir, "targets.yml"), targets, {sort_keys = true, default_flow_style = false})
  end
  for _, name in ipairs(Y.keys(scenes)) do
    mkdirs(scenedir)
    write_yaml(join(scenedir, "scene." .. name .. ".yml"), scenes[name], {sort_keys = false, allow_unicode = true,
                                                                          default_flow_style = false})
  end
  local names_file = join(up, "definition.names.yml")
  if fs().exists(names_file) then fs().remove(names_file) end
  local names = Y.map()
  local place_names = Y.keys(project.places)
  table.sort(place_names)
  for _, place in ipairs(place_names) do
    for _, o in ipairs(P.list(get(project.places[place], "objects"))) do
      if T(get(o, "display")) and T(get(o, "id")) and Q.is_actor(o) then names[id .. "_" .. place .. "_" .. S(o.id)] = o.display end
    end
  end
  if Y.len(names) > 0 then write_yaml(names_file, names, {sort_keys = true, allow_unicode = true, default_flow_style = false}) end
  local mg_file = join(up, "definition.minigames.yml")
  if fs().exists(mg_file) then fs().remove(mg_file) end
  if T(project.minigames) then write_yaml(mg_file, project.minigames, {sort_keys = true, default_flow_style = false}) end
  local keyed_file = join(up, "definition.strings.csv")
  if fs().exists(keyed_file) then fs().remove(keyed_file) end
  if project.keyed_strings and #project.keyed_strings > 0 then
    local rows = {}
    for _, k in ipairs(project.keyed_strings) do
      rows[#rows + 1] = string.format("%d|        |%s|%s", k[1], k[2], table.concat(PYS.split(S(k[3])), " "))
    end
    assert(fs().write(keyed_file, table.concat(rows, "\n") .. "\n"))
  end
  local speech_file = join(up, "definition.speech.yml")
  if fs().exists(speech_file) then fs().remove(speech_file) end
  if T(speech) then
    write_yaml(speech_file, M("speech", speech), {sort_keys = false, allow_unicode = true, default_flow_style = false})
  end
  write_yaml(join(defdir, "structure.root.yml"), M("structure", M("quest", M("blocks", blocks))),
             {sort_keys = false, default_flow_style = nil, allow_unicode = true})
  return defdir
end

return PG
