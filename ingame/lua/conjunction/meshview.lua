-- The game's meshes for the 3D preview (meshview.py, its reading part): a cooked .w2mesh (positions, texture
-- coordinates, triangles, normals, the diffuse texture of each material), the meshes a template puts together (its
-- components, a person's look in the template's colours).
-- Cooked mesh: the CMesh's cookedData has quantizationScale / quantizationOffset, indexBufferOffset and renderChunks
-- (a count u8, then 37 bytes a chunk: vertex type u8, stream offsets 5 x u32, streams u8, index offset u32, 0x1d,
-- vertex count u16, index count u32, material u8, u8, u8, lod mask u8). The buffer (<mesh>.1.buffer) holds the
-- streams: positions u16 x 3 (value / 65535 * scale + offset; stride 8 or, skinned, more), uvs half x 2, normals
-- 10:10:10:2 then the tangent; indices u16. Triangles wind clockwise.
--   MV.read_mesh(path, depot, transform, shift) -> {part}   part: {rows = {x, y, z, u, v, nx, ny, nz, ...}, texture,
--                                                            cutout, mask, shift}
--   MV.entity_parts(path, depot, listed, look) -> how, {part}
--   MV.template_meshes / looks / coloring / person / entity as in meshview.py
-- Errors are raised where meshview.py raises (a missing file, a broken one); entity_parts leaves such a mesh out.
local CR = require("conjunction.cr2w")
local PR = require("conjunction.pyre")
local MV = {}

local unpack = string.unpack

-- reading in a coroutine (ui/view3d.lua): it gives the frame back when its time is up (MV.deadline, os.clock: the
-- wall clock under MSVC), at these points
MV.deadline = nil
local function breathe()
  if MV.deadline and os.clock() > MV.deadline and coroutine.isyieldable() then coroutine.yield() end
end
MV.breathe = breathe

MV.CUTOUT = {"hair", "foliage", "leaf", "leaves", "grass", "fur", "cutout", "tree", "branch", "feather"}
MV.DIFFUSE = {"Diffuse", "diffuse", "DiffuseMap", "Diffuse1", "BaseColor", "DiffuseArray"}
MV.SKIP = {"shadowmesh", "\\wounds\\", "_fill.", "proxy", "collision", "_lod", "\\blockout"}

-- f.names[k] / f.imports[k] / f.exports[k] (0-based k as the file has it) - an error past the end, as Python's
local function name(f, k)
  local v = f.names[k + 1]
  if v == nil or k < 0 then error("meshview: no name " .. tostring(k)) end
  return v
end
local function import(f, k)
  local v = f.imports[k + 1]
  if v == nil or k < 0 then error("meshview: no import " .. tostring(k)) end
  return v
end
local function export(f, k)
  local v = f.exports[k + 1]
  if v == nil or k < 0 then error("meshview: no export " .. tostring(k)) end
  return v
end
-- path -> {first part, parts} while set: the asset build asks which people can talk one after another, and their
-- templates include the same bases and heads (25.10.: 44 % of its reads were again); kept at most PART_CACHE_MAX
-- (a file taken apart is about 1.4 MB of Lua: 4000 filled TW3SE's 1 GB for all Lua mods after ~700, 07.11.)
MV.part_cache = nil
MV.PART_CACHE_MAX = 100
local function first_part(depot, path)
  local c = MV.part_cache
  local hit = c and c.files[path]
  if hit then return hit[1], hit[2] end
  breathe()
  local parts = CR.parts(depot:read(path))
  if not parts[1] then error("meshview: " .. path .. ": no CR2W in it") end
  if c then
    if c.n >= MV.PART_CACHE_MAX then c.files, c.n = {}, 0 end
    c.files[path], c.n = {parts[1], parts}, c.n + 1
  end
  return parts[1], parts
end
local function ends(s, suffix) return #s >= #suffix and s:sub(-#suffix) == suffix end
local function lower(s) return (s:gsub("%u", string.lower)) end
local function plain_find(s, part) return s:find(part, 1, true) ~= nil end
local function latin1(s)                      -- bytes as latin-1 letters, written as UTF-8
  return (s:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end))
end

-- an ordered map: keys in the order they first came (a Python dict)
local function omap() return {keys = {}, v = {}} end
local function oset(m, k, val)
  if m.v[k] == nil then m.keys[#m.keys + 1] = k end
  m.v[k] = val
end

-- --- materials ---
-- a material instance's parameters: {name: {type, value bytes}} (in their order)
local function params(f, chunk)
  local props = f:props(chunk)
  local stop = #props > 0 and (props[#props][3] + props[#props][4]) or 1
  local data = chunk:sub(stop + 1)
  local out = omap()
  local i = 2                                       -- (the end of the properties: name 0)
  if #data < i + 4 then return out end
  local count = unpack("<I", data, i + 1)
  i = i + 4
  for _ = 1, math.min(count, 200) do
    if i + 8 > #data then break end
    local size, nm, tp = unpack("<IHH", data, i + 1)
    if size < 8 then break end
    oset(out, name(f, nm), {name(f, tp), data:sub(i + 9, i + size)})
    i = i + size
  end
  return out
end

-- the material graph (.w2mg) a material handle ends in - its name tells how it is drawn
local function graph(f, depot, handle, depth)
  depth = depth or 0
  if handle == 0 or depth > 4 then return "" end
  if handle < 0 then
    local path = import(f, -handle - 1)[1]
    if ends(path, ".w2mg") or not ends(path, ".w2mi") or not depot:exists(path) then return path end
    local g = first_part(depot, path)
    for k, e in ipairs(g.exports) do
      if e[1] == "CMaterialInstance" then return graph(g, depot, k, depth + 1) end
    end
    return path
  end
  local chunk = export(f, handle - 1)[5]
  local props = f:prop_map(chunk)
  if props.baseMaterial then
    return graph(f, depot, (unpack("<i", chunk, props.baseMaterial[2] + 1)), depth + 1)
  end
  return ""
end
MV.graph = graph

local NOT_COLOUR = PR.compile([[normal|spec|rough|mask|ambient|ao\b|height|detail|translucen|noise]], PR.I)
local NOT_COLOUR_FILE = PR.compile([[_(n|s|a|r|m|nm|ao|h)\d*\.xbm$]], PR.I)
local function not_colour(param, path)
  if NOT_COLOUR:search(param) then return true end
  return NOT_COLOUR_FILE:search(path) ~= nil
end

-- the diffuse texture (.xbm depot path) of a material handle, following imported .w2mi files (or, with other keys,
-- that texture: only those)
local function diffuse(f, depot, handle, depth, keys)
  depth = depth or 0
  local any_colour = keys == nil
  keys = keys or MV.DIFFUSE
  if handle == 0 or depth > 4 then return nil end
  if handle > 0 then
    local chunk = export(f, handle - 1)[5]
    local ps = params(f, chunk)
    for _, key in ipairs(keys) do
      local p = ps.v[key]
      if p and p[1]:sub(1, 7) == "handle:" then
        local h = unpack("<i", p[2])
        if h < 0 and ends(import(f, -h - 1)[1], ".xbm") then return import(f, -h - 1)[1] end
        if h < 0 and ends(import(f, -h - 1)[1], ".texarray") then
          -- walls and houses blend layers of an array by vertex colour; the cache keeps each layer as
          -- <array>.texture_<n>.xbm - the first is the base
          return import(f, -h - 1)[1] .. ".texture_0.xbm"
        end
      end
    end
    local props = f:prop_map(chunk)
    if props.baseMaterial then                       -- the base's diffuse first
      local found = diffuse(f, depot, (unpack("<i", chunk, props.baseMaterial[2] + 1)), depth + 1,
                            not any_colour and keys or nil)
      if found then return found end
    end
    if any_colour then                              -- any colour texture
      for _, pname in ipairs(ps.keys) do
        local tp, v = ps.v[pname][1], ps.v[pname][2]
        if tp:sub(1, 7) == "handle:" and #v >= 4 then
          local h = unpack("<i", v)
          if h < 0 then
            local p = import(f, -h - 1)[1]
            if ends(p, ".xbm") and not not_colour(pname, p) then return p end
          end
        end
      end
    end
    return nil
  end
  local path = import(f, -handle - 1)[1]               -- an imported material instance
  if not ends(path, ".w2mi") or not depot:exists(path) then return nil end
  local g = first_part(depot, path)
  for k, e in ipairs(g.exports) do
    if e[1] == "CMaterialInstance" then return diffuse(g, depot, k, depth + 1, not any_colour and keys or nil) end
  end
  return nil
end
MV.diffuse = diffuse

-- EngineTransform: flags u8 (1 position, 2 rotation, 4 scale), then 3 floats for each
function MV.transform(v)
  local pos, rot, scale = {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {1.0, 1.0, 1.0}
  if v == nil or v == "" then return {pos, rot, scale} end
  local flags, i = v:byte(1), 1
  for _, bt in ipairs({{1, pos}, {2, rot}, {4, scale}}) do
    if flags & bt[1] ~= 0 and i + 12 <= #v then
      local x, y, z = unpack("<fff", v, i + 1)
      bt[2][1], bt[2][2], bt[2][3] = x, y, z
      i = i + 12
    end
  end
  return {pos, rot, scale}
end

-- --- templates ---
-- {{mesh path, transform[, component name]}} of a template's mesh components (all its parts; none: those of the
-- templates it includes)
function MV.template_meshes(path, depot, names, depth)
  depth = depth or 0
  breathe()
  local parts = CR.parts(depot:read(path))
  local out, seen = {}, {}
  for _, f in ipairs(parts) do                       -- the entity, then its streamed pieces
    for _, e in ipairs(f.exports) do
      local cls, chunk = e[1], e[5]
      if plain_find(cls, "MeshComponent") and not plain_find(cls, "Destruction") then
        local mesh, tr, nm
        local ok, props = pcall(f.props, f, chunk)
        if not ok then ok, props = pcall(f.props, f, chunk, 0) end   -- (some start right with the first property)
        if ok then
          for _, p in ipairs(props) do
            local pname, off, sz = p[1], p[3], p[4]
            local v = chunk:sub(off + 1, off + sz)
            if pname == "mesh" then
              if #v >= 4 then
                local h = unpack("<i", v)
                mesh = h < 0 and import(f, -h - 1)[1] or nil
              elseif #v == 2 then
                local h = unpack("<H", v)
                mesh = (h > 0 and h <= #f.imports) and f.imports[h][1] or nil
              end
            elseif pname == "transform" then
              tr = v
            elseif pname == "name" then
              nm = v
            end
          end
          local key = (nm or "\0") .. "\1" .. tostring(mesh)
          if mesh and ends(mesh, ".w2mesh") and not seen[key] then
            seen[key] = true
            -- a String: a length byte (0x80: plain ascii, 0x40: one more length byte), then the letters
            local label = ""
            if nm and nm ~= "" then label = latin1(nm:sub((nm:byte(1) & 0x40 ~= 0) and 3 or 2)) end
            out[#out + 1] = names and {mesh, MV.transform(tr), label} or {mesh, MV.transform(tr)}
          end
        end
      end
    end
  end
  if #out > 0 then return out end
  local tmpl
  for _, e in ipairs(parts[1] and parts[1].exports or {}) do if e[1] == "CEntityTemplate" then tmpl = e break end end
  if tmpl == nil or depth > 3 then return {} end
  local f, chunk = parts[1], tmpl[5]
  local props = f:prop_map(chunk)
  if props.includes then                            -- e.g. a container definition: its mesh entity
    local off = props.includes[2]
    for k = 0, unpack("<I", chunk, off + 1) - 1 do
      local h = unpack("<i", chunk, off + 4 + 4 * k + 1)
      if h < 0 and depot:exists(import(f, -h - 1)[1]) then
        for _, x in ipairs(MV.template_meshes(import(f, -h - 1)[1], depot, names, depth + 1)) do out[#out + 1] = x end
      end
    end
  end
  return out
end

-- an array of structs as ordered property maps {name: {type, value bytes}}
local function struct_array(f, v)
  local n = unpack("<I", v)
  local out, i = {}, 4
  for _ = 1, n do
    local el = omap()
    i = i + 1
    while i + 2 <= #v do
      local nm = unpack("<H", v, i + 1)
      if nm == 0 then
        i = i + 2
        break
      end
      local tp, size = unpack("<HI", v, i + 3)
      oset(el, name(f, nm), {name(f, tp), v:sub(i + 9, i + 4 + size)})
      i = i + 4 + size
    end
    out[#out + 1] = el
  end
  return out
end

-- a CColorShift's (hue, saturation, luminance); what it leaves out is 0
local function shift_of(g, v)
  local out = {hue = 0, saturation = 0, luminance = 0}
  local i = 1
  while i + 8 <= #v do
    local nm = unpack("<H", v, i + 1)
    if nm == 0 then break end
    local size = unpack("<I", v, i + 5)
    local key, val = name(g, nm), v:sub(i + 9, i + 4 + size)
    if key == "hue" and #val >= 2 then
      out.hue = unpack("<H", val)
    elseif out[key] ~= nil and #val >= 1 then           -- (a hue of one byte too, as meshview._shift)
      out[key] = unpack("<b", val)
    end
    i = i + 4 + size
  end
  return {out.hue, out.saturation, out.luminance}
end

local function includes(f, chunk, props, fn)
  if not props.includes then return end
  local off = props.includes[2]
  for k = 0, unpack("<I", chunk, off + 1) - 1 do
    local h = unpack("<i", chunk, off + 4 + 4 * k + 1)
    fn(h)
  end
end
local function template_of(f)
  for _, e in ipairs(f.exports) do if e[1] == "CEntityTemplate" then return e end end
end

-- {[appearance .. "\1" .. component] = {shift 1, shift 2}} of a template and the ones it includes
function MV.coloring(path, depot, depth)
  depth = depth or 0
  local out = {}
  if depth > 3 or not depot:exists(path) then return out end
  local f = first_part(depot, path)
  local tmpl = template_of(f)
  if tmpl == nil then return out end
  local chunk = tmpl[5]
  local props = f:prop_map(chunk)
  includes(f, chunk, props, function(h)
    if h < 0 then
      for k, v in pairs(MV.coloring(import(f, -h - 1)[1], depot, depth + 1)) do out[k] = v end
    end
  end)
  if props.coloringEntries then
    local off, sz = props.coloringEntries[2], props.coloringEntries[3]
    for _, el in ipairs(struct_array(f, chunk:sub(off + 1, off + sz))) do
      local app, comp = el.v.appearance, el.v.componentName
      if app and comp then                          -- (Python's tuple: there is true, however empty its bytes)
        local key = name(f, (unpack("<H", app[2]))) .. "\1" .. name(f, (unpack("<H", comp[2])))
        local none = {0, 0, 0}
        out[key] = {el.v.colorShift1 and shift_of(f, el.v.colorShift1[2]) or none,
                    el.v.colorShift2 and shift_of(f, el.v.colorShift2[2]) or none}
      end
    end
  end
  return out
end

-- ({appearance: {template paths}} in order, {used appearances}) of a template and the ones it includes (its own win)
function MV.looks(path, depot, depth)
  depth = depth or 0
  local apps, used = omap(), {}
  if depth > 3 or not depot:exists(path) then return apps, used end
  local f = first_part(depot, path)
  local tmpl = template_of(f)
  if tmpl == nil then return apps, used end
  local chunk = tmpl[5]
  local props = f:prop_map(chunk)
  if props.appearances then
    local off, sz = props.appearances[2], props.appearances[3]
    for _, app in ipairs(struct_array(f, chunk:sub(off + 1, off + sz))) do
      local nm, inc = app.v.name, app.v.includedTemplates
      if nm and inc then
        local v = inc[2]
        local n = unpack("<I", v)
        local subs = {}
        for k = 0, n - 1 do
          local h = unpack("<i", v, 4 + 4 * k + 1)
          if h < 0 then subs[#subs + 1] = import(f, -h - 1)[1] end
        end
        if #subs > 0 then oset(apps, name(f, (unpack("<H", nm[2]))), subs) end
      end
    end
  end
  if props.usedAppearances then
    local off = props.usedAppearances[2]
    local n = unpack("<I", chunk, off + 1)
    used = {}
    for k = 0, n - 1 do used[#used + 1] = name(f, (unpack("<H", chunk, off + 4 + 2 * k + 1))) end
  end
  includes(f, chunk, props, function(h)
    if h < 0 then
      local more, more_used = MV.looks(import(f, -h - 1)[1], depot, depth + 1)
      for _, key in ipairs(more.keys) do if apps.v[key] == nil then oset(apps, key, more.v[key]) end end
      if #used == 0 then used = more_used end
    end
  end)
  return apps, used
end

-- (appearance name, {{mesh, transform, colour shifts or nil}}) of a template's appearance (the named one, else the
-- usual one): the meshes of the templates it includes, in the colours the template gives them
function MV.person(path, depot, appearance)
  local apps, used = MV.looks(path, depot)
  local order = {}
  if appearance and appearance ~= "" then order[#order + 1] = appearance end
  for _, u in ipairs(used) do if apps.v[u] ~= nil then order[#order + 1] = u end end
  for _, k in ipairs(apps.keys) do order[#order + 1] = k end
  for _, label in ipairs(order) do
    local out = {}
    for _, sub in ipairs(apps.v[label] or {}) do
      if depot:exists(sub) then
        for _, x in ipairs(MV.template_meshes(sub, depot, true)) do out[#out + 1] = x end
      end
    end
    if #out > 0 then
      local colours = MV.coloring(path, depot)
      local res = {}
      for i, x in ipairs(out) do res[i] = {x[1], x[2], colours[label .. "\1" .. x[3]]} end
      return label, res
    end
  end
  return "", {}
end

-- a mesh the 3D preview draws (not shadows, wounds, helpers)
function MV.shown(mesh)
  local l = lower(mesh)
  for _, k in ipairs(MV.SKIP) do if plain_find(l, k) then return false end end
  return true
end

-- (how, {{mesh, transform, colour shifts or nil}}): what the 3D preview draws for a template
function MV.entity(path, depot, listed, look)
  local lst = {}
  for _, m in ipairs(listed or {}) do if MV.shown(m) and #lst < 6 then lst[#lst + 1] = m end end
  local inlist = {}
  for _, m in ipairs(lst) do inlist[m] = true end
  local own = {}
  for _, x in ipairs(MV.template_meshes(path, depot)) do
    local m = x[1]
    if (#lst > 0 and inlist[m]) or (#lst == 0 and MV.shown(m)) then
      if #own < 12 then own[#own + 1] = {m, x[2], nil} end
    end
  end
  local nm, look_meshes = MV.person(path, depot, look)
  if #look_meshes > 0 then                          -- a look (a person, a creature, a thing with variants)
    local have = {}
    for _, x in ipairs(look_meshes) do have[x[1]] = true end
    local out = {}
    for _, x in ipairs(look_meshes) do out[#out + 1] = x end
    for _, x in ipairs(own) do if not have[x[1]] then out[#out + 1] = x end end   -- (e.g. the neck seam)
    return "look " .. nm, out
  end
  if #own > 0 then return "components", own end
  local out = {}
  for _, m in ipairs(lst) do out[#out + 1] = {m, nil, nil} end
  return "listed", out
end

-- --- meshes ---
local function half(h)                              -- an IEEE half as Python's struct "e" reads it
  local sign = (h & 0x8000) ~= 0 and -1.0 or 1.0
  local e, m = (h >> 10) & 0x1f, h & 0x3ff
  if e == 0 then return sign * m * 2.0 ^ -24 end
  if e == 31 then return m == 0 and sign * math.huge or (0.0 / 0.0) end
  return sign * (1.0 + m / 1024.0) * 2.0 ^ (e - 15)
end
MV.half = half
-- every half once, on first use (a mesh's uvs: two lookups a vertex instead of two calls)
local HALF = setmetatable({}, {__index = function(t, h)
  local v = half(h)
  t[h] = v
  return v
end})

-- the rows moved by a component's transform (scale, rotation - roll around y, pitch around x, yaw around z -,
-- position)
local function place(rows, transform)
  local p, r, s = transform[1], transform[2], transform[3]
  local px, py, pz, roll, pitch, yaw, sx, sy, sz = p[1], p[2], p[3], r[1], r[2], r[3], s[1], s[2], s[3]
  if px == 0 and py == 0 and pz == 0 and pitch == 0 and yaw == 0 and roll == 0 and sx == 1 and sy == 1 and sz == 1 then
    return rows
  end
  local cy, syw = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
  local cp, sp = math.cos(math.rad(pitch)), math.sin(math.rad(pitch))
  local cr, sr = math.cos(math.rad(roll)), math.sin(math.rad(roll))
  local function turn(x, y, z)
    x, z = x * cr + z * sr, -x * sr + z * cr
    y, z = y * cp - z * sp, y * sp + z * cp
    x, y = x * cy - y * syw, x * syw + y * cy
    return x, y, z
  end
  local out = {}
  for i = 1, #rows do out[i] = rows[i] end
  for i = 1, #out, 8 do
    local x, y, z = turn(out[i] * sx, out[i + 1] * sy, out[i + 2] * sz)
    out[i], out[i + 1], out[i + 2] = x + px, y + py, z + pz
    out[i + 5], out[i + 6], out[i + 7] = turn(out[i + 5], out[i + 6], out[i + 7])
  end
  return out
end
MV.place = place

-- {part} of the mesh's most detailed level (moved by transform; tinted by the colour shift its template gives it)
local MESH_ROWS          -- cj_core's cj_mesh_rows, false without it (nil: not looked up yet)

-- a render chunk's rows in Lua (cj_core without cj_mesh_rows): 8 a corner - position, uv, normal - each
-- triangle's corners one after the other; flat arrays, no table a vertex or a triangle
local function rows_in_lua(buf, path, s0, s1, s2, nverts, stride, idx_off, index_base, nidx, scale, offset)
  local raw = buf:sub(s0 + 1, s0 + stride * nverts)
  local px, py, pz = {}, {}, {}
  local sc1, sc2, sc3, of1, of2, of3 = scale[1], scale[2], scale[3], offset[1], offset[2], offset[3]
  for i = 0, nverts - 1 do
    if i & 2047 == 2047 then breathe() end
    local x, y, z = unpack("<HHH", raw, stride * i + 1)
    px[i], py[i], pz[i] = x / 65535.0 * sc1 + of1, y / 65535.0 * sc2 + of2, z / 65535.0 * sc3 + of3
  end
  local uvraw = buf:sub(s1 + 1, s1 + 4 * nverts)
  if #uvraw % 4 ~= 0 then error("meshview: " .. path .. ": a broken uv stream") end
  local uu, uw = {}, {}
  for i = 0, #uvraw // 4 - 1 do
    local a, b2 = unpack("<HH", uvraw, 4 * i + 1)
    uu[i], uw[i] = HALF[a], HALF[b2]
  end
  local nnx, nny, nnz
  if s2 ~= 0 and s2 + 8 * nverts <= #buf then
    nnx, nny, nnz = {}, {}, {}
    for i = 0, nverts - 1 do
      local n = unpack("<I", buf, s2 + 8 * i + 1)
      nnx[i], nny[i], nnz[i] = ((n & 1023) / 511.5) - 1.0, (((n >> 10) & 1023) / 511.5) - 1.0,
                               (((n >> 20) & 1023) / 511.5) - 1.0
    end
  end
  local start = index_base + idx_off
  if start + 2 * nidx > #buf then error("meshview: " .. path .. ": the indices past the buffer") end
  local rows = {}
  local nr = 0
  local function emit(v, nx, ny, nz)
    local u = uu[v]
    if u == nil then error("meshview: " .. path .. ": a vertex without its uv") end
    if nnx then nx, ny, nz = nnx[v], nny[v], nnz[v] end
    rows[nr + 1], rows[nr + 2], rows[nr + 3] = px[v], py[v], pz[v]
    rows[nr + 4], rows[nr + 5] = u, uw[v]
    rows[nr + 6], rows[nr + 7], rows[nr + 8] = nx, ny, nz
    nr = nr + 8
  end
  for t = 0, nidx - 3, 3 do
    if t % 3072 == 3069 then breathe() end
    local a, b2, c = unpack("<HHH", buf, start + 2 * t + 1)
    if a < nverts and b2 < nverts and c < nverts then
      local ax, ay, az = px[a], py[a], pz[a]
      local ux, uy, uz = px[b2] - ax, py[b2] - ay, pz[b2] - az
      local vx, vy, vz = px[c] - ax, py[c] - ay, pz[c] - az
      local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
      local ln = math.sqrt(nx * nx + ny * ny + nz * nz)
      if ln == 0 then ln = 1.0 end
      nx, ny, nz = -nx / ln, -ny / ln, -nz / ln      -- (the game winds its triangles clockwise)
      emit(a, nx, ny, nz)
      emit(b2, nx, ny, nz)
      emit(c, nx, ny, nz)
    end
  end
  return rows
end

function MV.read_mesh(path, depot, transform, shift)
  local f = first_part(depot, path)
  local mesh
  for _, e in ipairs(f.exports) do if e[1] == "CMesh" then mesh = e break end end
  if mesh == nil then return {} end
  local chunk = mesh[5]
  local props = f:prop_map(chunk)
  local materials = {}
  if props.materials then
    local off = props.materials[2]
    local n = unpack("<I", chunk, off + 1)
    for k = 0, n - 1 do materials[k + 1] = unpack("<i", chunk, off + 4 + 4 * k + 1) end
  end
  local cd = props.cookedData
  if not cd then error("meshview: " .. path .. ": no cookedData") end
  local cooked = chunk:sub(cd[2] + 1, cd[2] + cd[3])
  local cp = f:prop_map(cooked)
  local function need(k)
    local v = cp[k]
    if not v then error("meshview: " .. path .. ": no " .. k) end
    return v
  end
  local function vec(k)
    local t = need(k)
    local o, s = t[2], t[3]
    local sub = f:prop_map(cooked:sub(o + 1, o + s), 1)
    local out = {}
    for i, c in ipairs({"X", "Y", "Z"}) do out[i] = sub[c] and (unpack("<f", cooked, o + sub[c][2] + 1)) or 0.0 end
    return out
  end
  local scale, offset = vec("quantizationScale"), vec("quantizationOffset")
  local index_base = unpack("<I", cooked, need("indexBufferOffset")[2] + 1)
  local rct = need("renderChunks")
  local rc = cooked:sub(rct[2] + 4 + 1, rct[2] + rct[3])
  breathe()
  if MESH_ROWS == nil then MESH_ROWS = w3.plugin and w3.plugin.cj_mesh_rows or false end
  local buf = not MESH_ROWS and depot:read(path .. ".1.buffer") or nil   -- (cj_mesh_rows reads it itself)
  breathe()
  local textures = {}
  local function tex_of(mat)        -- (a material's diffuse, cutout, tint mask: once a mesh)
    if textures[mat] == nil then
      if mat < #materials then
        local h = materials[mat + 1]
        local g = lower(graph(f, depot, h))
        local mask = shift and diffuse(f, depot, h, 0, {"TintMask"}) or nil
        if shift and mask == nil and plain_find(g, "colorshift") then mask = "" end   -- (all of it: shift 1)
        local cut = false
        for _, w in ipairs(MV.CUTOUT) do if plain_find(g, w) then cut = true end end
        textures[mat] = {diffuse(f, depot, h), cut, mask}
      else
        textures[mat] = {nil, false, nil}
      end
    end
    return textures[mat]
  end
  local parts = {}
  if #rc == 0 then error("meshview: " .. path .. ": no render chunks") end
  local count = rc:byte(1)
  for k = 0, count - 1 do
    local r = 1 + 37 * k
    if r + 37 > #rc then break end
    local s0, s1, s2 = unpack("<III", rc, r + 2)
    local idx_off = unpack("<I", rc, r + 23)
    local nverts = unpack("<H", rc, r + 28)
    local nidx = unpack("<I", rc, r + 30)
    local mat, lod = rc:byte(r + 34), rc:byte(r + 37)
    if not (lod & 1 == 0 or s1 == 0 or nverts == 0) then
      -- skinned meshes keep bone indices and weights next to each position: 16 bytes a vertex
      local stride = s1 > s0 and (s1 - s0) // nverts or 8
      if not (stride == 8 or stride == 12 or stride == 16 or stride == 20 or stride == 24) then stride = 8 end
      local part
      if MESH_ROWS then
        -- (cj_core makes the rows, the same bytes: a person's look in a few ms instead of 100-400 ms of Lua)
        local function g(v) return string.format("%.17g", v) end
        local args = {path .. ".1.buffer", tostring(s0), tostring(s1), tostring(s2), tostring(nverts), tostring(stride),
                      tostring(index_base + idx_off), tostring(nidx), g(scale[1]), g(scale[2]), g(scale[3]),
                      g(offset[1]), g(offset[2]), g(offset[3])}
        if transform then
          for _, v3 in ipairs(transform) do for j = 1, 3 do args[#args + 1] = g(v3[j]) end end
        end
        local data = MESH_ROWS(table.unpack(args))
        local lx, ly, lz, hx, hy, hz, nf = unpack("<ddddddI4", data)
        part = {bin = data:sub(53), nfloats = nf, lo = {lx, ly, lz}, hi = {hx, hy, hz}}
      else
        local rows = rows_in_lua(buf, path, s0, s1, s2, nverts, stride, idx_off, index_base, nidx, scale, offset)
        part = {rows = transform and place(rows, transform) or rows}
      end
      local tx = tex_of(mat)
      part.texture, part.cutout = tx[1], tx[2]
      if tx[3] ~= nil then part.mask, part.shift = tx[3], shift end
      parts[#parts + 1] = part
    end
  end
  return parts
end

-- --- for the preview (cj_qt's MeshView) ---
local function scratch(sub)
  local dir = w3.fs.folder("temp") .. "\\cj_core"
  if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  if sub then
    dir = dir .. "\\" .. sub
    if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  end
  return dir
end
-- a texture as a picture file (load_images: a level not bigger than max_side), nil when the caches lack it
MV.tex_files = {}
function MV.texture_file(tex_name, max_side, game)
  max_side = max_side or 512
  local key = tex_name .. "@" .. max_side
  if MV.tex_files[key] ~= nil then return MV.tex_files[key] or nil end
  if not MV.tex_opened then
    w3.plugin.cj_tex_open(game)
    MV.tex_opened = true
  end
  local out = scratch("tex") .. "\\" .. w3.plugin.cj_hash("md5", key) .. ".png"
  if w3.fs.exists(out) then                         -- (made before: the caches' textures do not change)
    MV.tex_files[key] = out
    return out
  end
  local ok
  if coroutine.isyieldable() then                   -- (in the 3D view's reading: on cj_core's thread, frames go on)
    w3.plugin.cj_tex_image_async(tex_name, tostring(max_side), out)
    local answer = "busy"
    while answer == "busy" do
      coroutine.yield()
      answer = w3.plugin.cj_tex_status(out)
    end
    ok = answer:sub(1, 1) ~= "!"
  else
    ok = pcall(w3.plugin.cj_tex_image, tex_name, tostring(max_side), out)
  end
  MV.tex_files[key] = ok and out or false
  return ok and out or nil
end

-- MeshView.show_parts: the middle of everything, its radius, the distance to look from
function MV.frame_of(parts)
  local lo, hi
  for _, p in ipairs(parts) do
    local r = p.rows or {}
    if p.bin and p.nfloats > 0 then                 -- (cj_mesh_rows: its bounds came with it)
      if not lo then lo, hi = {p.lo[1], p.lo[2], p.lo[3]}, {p.hi[1], p.hi[2], p.hi[3]} end
      for k = 1, 3 do
        if p.lo[k] < lo[k] then lo[k] = p.lo[k] end
        if p.hi[k] > hi[k] then hi[k] = p.hi[k] end
      end
    end
    for i = 1, #r, 8 do
      if not lo then lo, hi = {r[i], r[i + 1], r[i + 2]}, {r[i], r[i + 1], r[i + 2]} end
      for k = 0, 2 do
        local v = r[i + k]
        if v < lo[k + 1] then lo[k + 1] = v end
        if v > hi[k + 1] then hi[k + 1] = v end
      end
    end
  end
  if not lo then return {center = {0.0, 0.0, 0.0}, radius = 1.0, dist = 3.0} end
  local c = {(lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2}
  local radius = math.max(0.05, math.max(hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3]) / 2)
  return {center = c, radius = radius, dist = radius * 3.2}
end

-- the parts as cj_qt_mesh_load reads them ("CJM1", see cj_qt_gl.cpp), their textures as picture files
function MV.write_parts(parts, file, game, side)
  side = side or 512
  local out = {"CJM1", string.pack("<I4", #parts)}
  for _, p in ipairs(parts) do
    breathe()
    local tex = p.texture and MV.texture_file(p.texture, side, game) or ""
    local mask = ""
    if p.mask == "" then mask = "*" elseif p.mask then mask = MV.texture_file(p.mask, side, game) or "" end
    local s = p.shift or {{0, 0, 0}, {0, 0, 0}}
    out[#out + 1] = string.pack("<I4BBB", p.bin and p.nfloats or #p.rows, p.cutout and 1 or 0, p.mask ~= nil and 1 or 0,
                                p.shift and 1 or 0)
    out[#out + 1] = string.pack("<ffffff", s[1][1], s[1][2], s[1][3], s[2][1], s[2][2], s[2][3])
    out[#out + 1] = string.pack("<s2", tex)
    out[#out + 1] = string.pack("<s2", mask)
    if p.bin then
      out[#out + 1] = p.bin                         -- (cj_mesh_rows: the floats already)
    else
      local r = p.rows
      for i = 1, #r, 4096 do
        local j = math.min(#r, i + 4095)
        out[#out + 1] = string.pack(string.rep("f", j - i + 1), table.unpack(r, i, j))
      end
    end
  end
  w3.fs.write(file, table.concat(out))
end

-- (how, {part}) of entity: a mesh that cannot be read is left out
function MV.entity_parts(path, depot, listed, look)
  local how, placed = MV.entity(path, depot, listed, look)
  local parts = {}
  for _, x in ipairs(placed) do
    local ok, got = pcall(MV.read_mesh, x[1], depot, x[2], x[3])
    if ok then for _, p in ipairs(got) do parts[#parts + 1] = p end end
  end
  return how, parts
end

return MV
