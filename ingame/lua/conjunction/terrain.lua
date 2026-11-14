-- The terrain of a world (terrain.py): its height read from the game's cooked tiles, changed by brush strokes, written
-- back as cooked tiles a mod puts over the game's.
-- The world's CClipMap (in its .w2w): terrainCorner, terrainSize (metres per edge), numTilesPerEdge, tileRes,
-- lowestElevation / highestElevation. A tile: <world dir>\terrain_tiles\tile_<row>_x_<col>_res<tileRes>.w2ter, its
-- heights u16 row by row in <tile>.1.buffer (and every 2nd, 4th, 8th, 16th sample in .3 .5 .8 .11).
--   local t = TER.Terrain("novigrad")   t:height(x, y)   t:apply(strokes) -> {{row, col}}   t:write(out_dir)
--   t:collision(game) -> collision.cache entries     TER.load(project) / TER.save(project, groups)
--   TER.build_into(project, files_dir, cache_dir, log) -> tiles changed
-- A stroke: {op, x, y, radius, strength, shape = "circle" | "square", falloff = "smooth" | "linear" | "hard"}; the ops:
-- raise / lower (metres), smooth, flatten (to height), set, ramp (to x2, y2: height -> height2), noise (scale, seed),
-- terrace (step).
local CR = require("conjunction.cr2w")
local NUM = require("conjunction.pynum")
local PYS = require("conjunction.pystr")
local P = require("conjunction.py")
local TER = {}

TER.HEIGHT_BUFFERS = {1, 3, 5, 8, 11}           -- tileRes >> 0 .. >> 4
TER.ITEM = {1, 8, 8, 16, 24, 24, 0, 0, 0, 0}    -- bytes per entry of the CR2W tables
TER.OPS = {"raise", "lower", "smooth", "flatten", "set", "ramp", "noise", "terrace"}
TER.SHAPES = {"circle", "square"}
TER.FALLOFFS = {"smooth", "linear", "hard"}
TER.FILE = "terrain.yml"
local unpack, pack = string.unpack, string.pack

local function has(list, x) for _, y in ipairs(list) do if y == x then return true end end return false end
local function num(v, default)
  if v == nil or v == require("conjunction.yaml").null then return default end
  return tonumber(v) + 0.0
end
local function given(v) return v ~= nil and v ~= require("conjunction.yaml").null end

-- a few bytes of a string changed: {{0-based offset, bytes}} in any order -> the new string
local function splice(s, edits)
  table.sort(edits, function(a, b) return a[1] < b[1] end)
  local out, at = {}, 1
  for _, e in ipairs(edits) do
    out[#out + 1] = s:sub(at, e[1])
    out[#out + 1] = e[2]
    at = e[1] + #e[2] + 1
  end
  out[#out + 1] = s:sub(at)
  return table.concat(out)
end
TER.splice = splice

local function props(f, data, start)
  local out = {}
  for _, p in ipairs(f:props(data, start or 1)) do
    local name, tp, off = p[1], p[2], p[3]
    if tp == "Float" then out[name] = unpack("<f", data, off + 1)
    elseif tp == "Uint32" then out[name] = unpack("<I4", data, off + 1)
    elseif tp == "Int32" then out[name] = unpack("<i4", data, off + 1)
    elseif tp == "Vector" then
      local v = {}
      for _, q in ipairs(f:props(data, off + 1)) do v[q[1]] = unpack("<f", data, q[3] + 1) end
      out[name] = v
    end
  end
  return out
end

-- the brush's weight at distance r: 1 at the centre, 0 from the edge on (smooth: soft at both ends)
function TER.falloff(r, radius, kind)
  if r >= radius then return 0.0 end
  if kind == "hard" then return 1.0 end
  if kind == "linear" then return 1.0 - r / radius end
  return 0.5 * (1 + math.cos(math.pi * r / radius))
end

-- a fixed random value -1..1 for a lattice point (the same on every build)
local function lattice(ix, iy, seed)
  local h = (ix * 374761393 + iy * 668265263 + seed * 2147483647) & 0xFFFFFFFF
  h = ((h ~ (h >> 13)) * 1274126177) & 0xFFFFFFFF
  return ((h ~ (h >> 16)) & 0xFFFF) / 32767.5 - 1.0
end

-- smooth noise -1..1 with bumps of scale metres (value noise, two octaves)
function TER.value_noise(x, y, scale, seed)
  seed = seed or 0
  local out, amp, total = 0.0, 1.0, 0.0
  for octave = 0, 1 do
    local fx, fy = x / scale, y / scale
    local ix, iy = math.floor(fx), math.floor(fy)
    local tx, ty = fx - ix, fy - iy
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    local s = seed + octave * 101
    local a = lattice(ix, iy, s) + (lattice(ix + 1, iy, s) - lattice(ix, iy, s)) * tx
    local b = lattice(ix, iy + 1, s) + (lattice(ix + 1, iy + 1, s) - lattice(ix, iy + 1, s)) * tx
    out = out + (a + (b - a) * ty) * amp
    total = total + amp
    amp, scale = amp * 0.5, scale * 0.5
  end
  return out / total
end

local T = {}
T.__index = T
function TER.Terrain(world, depot)
  local self = setmetatable({}, T)
  self.depot = depot or require("conjunction.depot").open(require("conjunction.config").load().game)
  local paths = require("conjunction.project").world_paths()
  self.w2w = paths[world] or world
  local f = CR.parse(self.depot:read(self.w2w))
  local cm
  for _, e in ipairs(f.exports) do if e[1] == "CClipMap" then cm = e break end end
  if not cm then error("StopIteration: no CClipMap in " .. self.w2w, 0) end
  local p = props(f, cm[5])
  self.corner = {p.terrainCorner.X, p.terrainCorner.Y}
  self.size = p.terrainSize / p.numTilesPerEdge            -- metres per tile
  self.tiles_per_edge = p.numTilesPerEdge
  self.res = p.tileRes
  self.low, self.high = p.lowestElevation, p.highestElevation
  self.spacing = self.size / self.res
  self.dir = (self.w2w:match("^(.*)\\[^\\]*$") or "") .. "\\terrain_tiles"
  self.grids, self.originals, self.touched = {}, {}, {}
  return self
end

local function key(row, col) return row * 65536 + col end

function T:tile_path(row, col) return string.format("%s\\tile_%d_x_%d_res%d.w2ter", self.dir, row, col, self.res) end

-- the global sample (column from x, row from y) nearest to a world point
function T:sample_of(x, y)
  return NUM.round0((x - self.corner[1]) / self.spacing), NUM.round0((y - self.corner[2]) / self.spacing)
end

function T:grid(row, col)
  local k = key(row, col)
  local g = self.grids[k]
  if g == nil then
    local raw = self.depot:read(self:tile_path(row, col) .. "." .. TER.HEIGHT_BUFFERS[1] .. ".buffer")
    g = {}
    local n = self.res * self.res
    for i = 1, n, 2048 do
      local vals = {unpack("<" .. string.rep("H", math.min(2048, n - i + 1)), raw, (i - 1) * 2 + 1)}
      for j = 1, #vals - 1 do g[i + j - 1] = vals[j] end
    end
    self.grids[k] = g
  end
  return g
end

function T:_get(gx, gy)
  local g = self:grid(gy // self.res, gx // self.res)
  return g[(gy % self.res) * self.res + gx % self.res + 1]
end

function T:_set(gx, gy, v)
  local row, col = gy // self.res, gx // self.res
  local g = self:grid(row, col)
  local k = key(row, col)
  if self.originals[k] == nil then
    local copy = {}
    for i = 1, #g do copy[i] = g[i] end
    self.originals[k] = copy
  end
  g[(gy % self.res) * self.res + gx % self.res + 1] = math.max(0, math.min(65535, NUM.round0(v)))
  self.touched[k] = {row, col}
end

function T:_inside(gx, gy)
  local n = self.tiles_per_edge * self.res
  return gx >= 0 and gx < n and gy >= 0 and gy < n
end

-- metres the strokes moved the ground at a world point (0 where nothing changed)
function T:change(x, y)
  local gx, gy = self:sample_of(x, y)
  if not self:_inside(gx, gy) then return 0.0 end
  local k = key(gy // self.res, gx // self.res)
  if self.originals[k] == nil then return 0.0 end
  local i = (gy % self.res) * self.res + gx % self.res + 1
  return (self.grids[k][i] - self.originals[k][i]) * (self.high - self.low) / 65535.0
end

function T:to_metres(v) return self.low + v / 65535.0 * (self.high - self.low) end
function T:to_value(m) return (m - self.low) / (self.high - self.low) * 65535.0 end
function T:height(x, y) return self:to_metres(self:_get(self:sample_of(x, y))) end

-- where a ray (origin, unit direction d) first meets the ground -> {x, y, z} or nil (sky, out of the world)
function T:ground(origin, d, reach, step)
  reach, step = reach or 400.0, step or 0.5
  local prev_t, t = 0.0, 0.0
  while t < reach do
    local p = {origin[1] + d[1] * t, origin[2] + d[2] * t, origin[3] + d[3] * t}
    local gx, gy = self:sample_of(p[1], p[2])
    if self:_inside(gx, gy) and p[3] <= self:to_metres(self:_get(gx, gy)) then
      local lo, hi = prev_t, t
      for _ = 1, 8 do
        local mid = (lo + hi) / 2
        local q = {origin[1] + d[1] * mid, origin[2] + d[2] * mid, origin[3] + d[3] * mid}
        if q[3] <= self:height(q[1], q[2]) then hi = mid else lo = mid end
      end
      local q = {origin[1] + d[1] * hi, origin[2] + d[2] * hi, origin[3] + d[3] * hi}
      return {q[1], q[2], self:height(q[1], q[2])}
    end
    prev_t, t = t, t + step
  end
  return nil
end

-- the samples a stroke reaches, in order: {{gx, gy, weight, t}} (its circle / square, or the band of a ramp)
function T:_weights(s)
  local radius, kind = num(s.radius), given(s.falloff) and s.falloff or "smooth"
  local shape = given(s.shape) and s.shape or "circle"
  if not has(TER.FALLOFFS, kind) or not has(TER.SHAPES, shape) then
    error("terrain stroke: falloff one of " .. table.concat(TER.FALLOFFS, ", ") .. ", shape one of " ..
          table.concat(TER.SHAPES, ", "), 0)
  end
  local x1, y1 = num(s.x), num(s.y)
  local x2, y2 = x1, y1
  if s.op == "ramp" then x2, y2 = num(s.x2), num(s.y2) end
  local lo_x, lo_y = self:sample_of(math.min(x1, x2) - radius, math.min(y1, y2) - radius)
  local hi_x, hi_y = self:sample_of(math.max(x1, x2) + radius, math.max(y1, y2) + radius)
  local dx, dy = x2 - x1, y2 - y1
  local length2 = dx * dx + dy * dy
  local out = {}
  for gy = lo_y, hi_y do
    for gx = lo_x, hi_x do
      if self:_inside(gx, gy) then
        local px, py = self.corner[1] + gx * self.spacing, self.corner[2] + gy * self.spacing
        local r, t
        local skip = false
        if s.op == "ramp" then
          t = length2 ~= 0 and ((px - x1) * dx + (py - y1) * dy) / length2 or 0.0
          if not (t >= 0.0 and t <= 1.0) then skip = true
          else r = NUM.hypot(px - (x1 + dx * t), py - (y1 + dy * t)) end
        elseif shape == "square" then
          r, t = math.max(math.abs(px - x1), math.abs(py - y1)), 0.0
        else
          r, t = NUM.hypot(px - x1, py - y1), 0.0
        end
        if not skip then
          local w = TER.falloff(r, radius, kind)
          if w ~= 0 then out[#out + 1] = {gx, gy, w, t} end
        end
      end
    end
  end
  return out
end

-- brush strokes, in order -> the tiles they touched (sorted {row, col})
function T:apply(strokes)
  for _, s in ipairs(strokes) do
    local op = s.op
    if not has(TER.OPS, op) then
      error("terrain stroke: op '" .. tostring(op) .. "' - one of " .. table.concat(TER.OPS, ", "), 0)
    end
    local strength = num(s.strength, 1.0)
    local cx, cy = self:sample_of(num(s.x), num(s.y))
    local found = self:_weights(s)
    if op == "raise" or op == "lower" then
      local d = self:to_value(strength) - self:to_value(0.0)
      if op == "lower" then d = -d end
      for _, e in ipairs(found) do self:_set(e[1], e[2], self:_get(e[1], e[2]) + d * e[3]) end
    elseif op == "flatten" or op == "set" then
      local target = given(s.height) and self:to_value(num(s.height)) or self:_get(cx, cy)
      for _, e in ipairs(found) do
        local v = self:_get(e[1], e[2])
        self:_set(e[1], e[2], v + (target - v) * e[3] * (op == "flatten" and strength or 1.0))
      end
    elseif op == "ramp" then
      local ex, ey = self:sample_of(num(s.x2), num(s.y2))
      local h1 = given(s.height) and self:to_value(num(s.height)) or self:_get(cx, cy)
      local h2 = given(s.height2) and self:to_value(num(s.height2)) or self:_get(ex, ey)
      for _, e in ipairs(found) do
        local v = self:_get(e[1], e[2])
        self:_set(e[1], e[2], v + (h1 + (h2 - h1) * e[4] - v) * e[3] * strength)
      end
    elseif op == "noise" then
      local scale, seed = num(s.scale, 4.0), math.tointeger(given(s.seed) and tonumber(s.seed) or 0)
      local d = self:to_value(strength) - self:to_value(0.0)
      for _, e in ipairs(found) do
        local n = TER.value_noise(e[1] * self.spacing, e[2] * self.spacing, scale, seed)
        self:_set(e[1], e[2], self:_get(e[1], e[2]) + d * n * e[3])
      end
    elseif op == "terrace" then
      local step = num(s.step, 1.0)
      for _, e in ipairs(found) do
        local v = self:_get(e[1], e[2])
        local m = self:to_metres(v)
        local target = self:to_value(math.floor(m / step + 0.5) * step)
        self:_set(e[1], e[2], v + (target - v) * e[3] * strength)
      end
    else                                 -- smooth: towards the mean of the 3x3 around, read before any change
      local old = {}
      for i, e in ipairs(found) do
        local sum, n = 0, 0
        for ay = e[2] - 1, e[2] + 1 do
          for ax = e[1] - 1, e[1] + 1 do
            if self:_inside(ax, ay) then sum, n = sum + self:_get(ax, ay), n + 1 end
          end
        end
        old[i] = {self:_get(e[1], e[2]), sum / n}
      end
      for i, e in ipairs(found) do
        local v, mean = old[i][1], old[i][2]
        self:_set(e[1], e[2], v + (mean - v) * e[3] * strength)
      end
    end
  end
  return self:touched_list()
end

function T:touched_list()
  local out = {}
  for _, rc in pairs(self.touched) do out[#out + 1] = rc end
  table.sort(out, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
  return out
end

-- the tile's minHeightValue / maxHeightValue (the export's u16 props) and the export's crc -> the new bytes
local function set_tile_range(raw, lo, hi)
  local f = CR.parse(raw)
  local e_off = unpack("<I4", raw, 0x28 + 4 * 12 + 1)
  local _cls, _fl, _par, size, data_off = unpack("<I2I2I4I4I4", raw, e_off + 1)
  local edits = {}
  for _, p in ipairs(f:props(f.exports[1][5])) do
    if p[1] == "maxHeightValue" then edits[#edits + 1] = {data_off + p[3], pack("<I2", hi)}
    elseif p[1] == "minHeightValue" then edits[#edits + 1] = {data_off + p[3], pack("<I2", lo)} end
  end
  raw = splice(raw, edits)
  return splice(raw, {{e_off + 20, pack("<I4", P.crc32(raw:sub(data_off + 1, data_off + size)))}})
end

-- each table's crc (crc32 of its bytes), then the header's (crc32 of 0xA0 bytes, its own field 0xDEADBEEF)
local function fix_crcs(raw)
  local edits = {}
  for i = 0, 9 do
    local off, cnt = unpack("<I4I4", raw, 0x28 + i * 12 + 1)
    if cnt ~= 0 and TER.ITEM[i + 1] ~= 0 then
      edits[#edits + 1] = {0x28 + i * 12 + 8, pack("<I4", P.crc32(raw:sub(off + 1, off + cnt * TER.ITEM[i + 1])))}
    end
  end
  raw = splice(raw, edits)
  raw = splice(raw, {{0x20, pack("<I4", 0xDEADBEEF)}})
  return splice(raw, {{0x20, pack("<I4", P.crc32(raw:sub(1, 0xA0)))}})
end

local function pack_u16(vals)
  local out = {}
  for i = 1, #vals, 2048 do
    out[#out + 1] = pack("<" .. string.rep("H", math.min(2048, #vals - i + 1)),
                         table.unpack(vals, i, math.min(#vals, i + 2047)))
  end
  return table.concat(out)
end

-- the touched tiles as cooked files under out_dir (their depot paths) -> the paths written
function T:write(out_dir)
  local written = {}
  for _, rc in ipairs(self:touched_list()) do
    local row, col = rc[1], rc[2]
    local name = self:tile_path(row, col)
    local raw = self.depot:read(name)
    local full = self.grids[key(row, col)]
    local levels = {}
    for k, idx in ipairs(TER.HEIGHT_BUFFERS) do
      local res, step = self.res >> (k - 1), 1 << (k - 1)
      local vals = {}
      for r = 0, res - 1 do
        for c = 0, res - 1 do vals[#vals + 1] = full[(r * step) * self.res + c * step + 1] end
      end
      levels[idx] = pack_u16(vals)
    end
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(full) do
      if v < lo then lo = v end
      if v > hi then hi = v end
    end
    raw = set_tile_range(raw, lo, hi)
    local b_off, b_cnt = unpack("<I4I4", raw, 0x28 + 5 * 12 + 1)
    local edits = {}
    for i = 0, b_cnt - 1 do
      local idx = unpack("<I4", raw, b_off + i * 24 + 4 + 1)
      if levels[idx] then edits[#edits + 1] = {b_off + i * 24 + 20, pack("<I4", P.crc32(levels[idx]))} end
    end
    raw = fix_crcs(splice(raw, edits))
    local path = out_dir .. "\\" .. name
    w3.fs.mkdir(path:match("^(.*)\\[^\\]+$"))
    assert(w3.fs.write(path, raw))
    for i = 0, b_cnt - 1 do
      local idx = unpack("<I4", raw, b_off + i * 24 + 4 + 1)
      assert(w3.fs.write(path .. "." .. idx .. ".buffer",
                         levels[idx] or self.depot:read(name .. "." .. idx .. ".buffer")))
    end
    written[#written + 1] = path
  end
  return written
end

-- the collision.cache entries of the tiles whose collision changes - the touched ones and the neighbours below / to
-- the left, whose pieces end on a touched tile's first row / column - remade from the heights. A tile's entry: 64
-- PhysX heightfields ("NXS\1" "HFHF"), piece k the block k // 8 (rows), k % 8 (columns) of 64 x 64 cells, 65 x 65
-- samples - past the tile's edge the neighbour's. A sample: i16 height (tile value - 32767), two material bytes kept.
-- The piece's lowest / highest sample as floats in its header: at +50 / +62, again at +94 / +98; the samples from +102.
function T:collision(game)
  local CC = require("conjunction.collision_cache")
  local PS = require("conjunction.pysort")
  local tiles = {}
  for _, rc in pairs(self.touched) do
    for _, d in ipairs({{0, 0}, {-1, 0}, {0, -1}, {-1, -1}}) do
      local r, c = rc[1] + d[1], rc[2] + d[2]
      if r >= 0 and r < self.tiles_per_edge and c >= 0 and c < self.tiles_per_edge then tiles[key(r, c)] = {r, c} end
    end
  end
  local names, wanted = {}, {}
  for _, rc in pairs(tiles) do
    local n = PYS.lower(self:tile_path(rc[1], rc[2]))
    names[n] = rc
    wanted[#wanted + 1] = n
  end
  local caches = {}
  local content = game .. "\\content"
  local cs = {}
  for _, e in ipairs(w3.fs.isdir(content) and w3.fs.list(content) or {}) do
    local p = content .. "\\" .. e.name .. "\\collision.cache"
    if e.dir and PYS.lower(e.name):sub(1, 7) == "content" and w3.fs.exists(p) then cs[#cs + 1] = p end
  end
  for _, p in ipairs(PS.sorted(cs)) do caches[#caches + 1] = p end
  cs = {}
  for _, e in ipairs(w3.fs.isdir(game .. "\\dlc") and w3.fs.list(game .. "\\dlc") or {}) do
    local p = game .. "\\dlc\\" .. e.name .. "\\content\\collision.cache"
    if e.dir and w3.fs.exists(p) then cs[#cs + 1] = p end
  end
  for _, p in ipairs(PS.sorted(cs)) do caches[#caches + 1] = p end
  local found = {}
  for _, cache in ipairs(caches) do
    for k, v in pairs(CC.find(cache, wanted)) do found[k] = v end
  end
  local out = {}
  local last = self.tiles_per_edge * self.res - 1
  for _, name in ipairs(PS.sorted(wanted)) do
    local row, col = names[name][1], names[name][2]
    local entry = found[name]
    if entry ~= nil then                                -- (a tile without collision: none to change)
      local data = entry:data()
      local starts, i = {}, 1
      while true do
        local at = data:find("NXS\1HFHF", i, true)
        if not at then break end
        starts[#starts + 1] = at - 1
        i = at + 8
      end
      if #starts ~= 64 then
        error(string.format("%s: %d heightfields in its collision, 64 expected", name, #starts), 0)
      end
      local edits = {}
      for k, s in ipairs(starts) do
        local br, bc = (k - 1) // 8, (k - 1) % 8
        local gy0, gx0 = row * self.res + br * 64, col * self.res + bc * 64
        local lo, hi
        local cells = {}
        for r = 0, 64 do
          for c = 0, 64 do
            local v = math.min(32767, self:_get(math.min(gx0 + c, last), math.min(gy0 + r, last)) - 32767)
            local o = s + 102 + (r * 65 + c) * 4
            cells[#cells + 1] = pack("<i2", v) .. data:sub(o + 3, o + 4)
            if lo == nil or v < lo then lo = v end
            if hi == nil or v > hi then hi = v end
          end
        end
        edits[#edits + 1] = {s + 102, table.concat(cells)}
        for _, ov in ipairs({{50, lo}, {62, hi}, {94, lo}, {98, hi}}) do
          edits[#edits + 1] = {s + ov[1], pack("<f", ov[2] + 0.0)}
        end
      end
      entry:replace(splice(data, edits))
      out[#out + 1] = entry
    end
  end
  return out
end

-- a project's painted terrain: {{world, strokes = {...}}, ...}, one entry per drag of the brush, in the order painted
function TER.load(project_dir)
  local Y = require("conjunction.yaml")
  local path = project_dir .. "\\" .. TER.FILE
  if not w3.fs.exists(path) then return {} end
  local data = Y.read(path)
  local out = {}
  local groups = Y.is_map(data) and data.groups
  for _, g in ipairs(type(groups) == "table" and groups or {}) do
    if P.T(P.get(g, "world")) and P.T(P.get(g, "strokes")) then out[#out + 1] = g end
  end
  return out
end

function TER.save(project_dir, groups)
  local Y = require("conjunction.yaml")
  local path = project_dir .. "\\" .. TER.FILE
  if #groups == 0 then
    if w3.fs.exists(path) then w3.fs.remove(path) end
    return
  end
  local text = "# terrain painted in the editor, in the order painted: one entry per drag of the brush\n" ..
               Y.dump(Y.map({"groups", Y.list(groups)}), {sort_keys = false, default_flow_style = nil, width = 120})
  local tmp = path .. ".tmp"
  require("conjunction.fsutil").write_text(tmp, text)
  w3.fs.remove(path)
  w3.fs.rename(tmp, path)
end

function TER.strokes_of(groups, world)
  local out = {}
  for _, g in ipairs(groups) do
    if g.world == world then for _, s in ipairs(g.strokes) do out[#out + 1] = s end end
  end
  return out
end

-- a project's painted terrain into a build: the changed tiles under their game paths in files_dir (the mod bundle's
-- files), their collision as cache_dir\collision.cache -> the number of tiles (0: nothing painted)
function TER.build_into(project_dir, files_dir, cache_dir, log, depot)
  log = log or print
  local CC = require("conjunction.collision_cache")
  local groups = TER.load(project_dir)
  if #groups == 0 then return 0 end
  depot = depot or require("conjunction.depot").open(require("conjunction.config").load().game)
  local entries, tiles, seen = {}, 0, {}
  for _, g in ipairs(groups) do
    local world = g.world
    if not seen[world] then
      seen[world] = true
      local t = TER.Terrain(world, depot)
      local touched = t:apply(TER.strokes_of(groups, world))
      t:write(files_dir)
      for _, e in ipairs(t:collision(require("conjunction.config").load().game)) do entries[#entries + 1] = e end
      tiles = tiles + #touched
      log(string.format("[build] terrain of %s: %d tiles changed", world, #touched))
    end
  end
  if #entries > 0 then
    w3.fs.mkdir(cache_dir)
    assert(w3.fs.write(cache_dir .. "\\collision.cache", CC.write(entries)))
  end
  return tiles
end

return TER
