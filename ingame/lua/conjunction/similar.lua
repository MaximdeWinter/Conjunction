-- How much of a quest is the same as one of this PC's projects - by its content, not its marks (similar.py): the
-- texts, the order of the steps and where the objects stand stay when the history is cut out, the GUIDs rolled anew
-- and the marks rounded away. Check origin shows: "Bandit camp: 92 % of the texts, 11 of 11 objects (within 5 cm),
-- the steps 100 %".
--   SIM.content_of_meta(meta) -> texts, step kinds
--   SIM.compare(texts, kinds, objects, skip) -> {Match}     this PC's projects, most alike first
local Y = require("conjunction.yaml")
local PYS = require("conjunction.pystr")
local NUM = require("conjunction.pynum")
local PATHS = require("conjunction.paths")
local SIM = {}

SIM.NEAR = 0.05                    -- m: objects this close count as the same spot (survives a few mm of jitter)
SIM.LEAST_OBJECTS = 3

local Match = {}
Match.__index = Match
SIM.Match = Match
function Match.new(name, path, texts, objects, steps)
  return setmetatable({name = name, path = path, texts = texts, objects = objects, steps = steps}, Match)
end
function Match:strong()
  return (self.texts or 0) >= 0.5 or (self.objects ~= nil and self.objects[1] >= SIM.LEAST_OBJECTS and
                                       self.objects[1] >= 0.5 * self.objects[2]) or (self.steps or 0) >= 0.9
end
function Match:line()
  local parts = {}
  if self.texts ~= nil then parts[#parts + 1] = string.format("%d %% of the texts", NUM.round(self.texts * 100)) end
  if self.objects ~= nil then
    parts[#parts + 1] = string.format("%d of %d objects (within %d cm)", self.objects[1], self.objects[2],
                                      NUM.round(SIM.NEAR * 100))
  end
  if self.steps ~= nil then parts[#parts + 1] = string.format("the steps %d %%", NUM.round(self.steps * 100)) end
  return self.name .. ": " .. table.concat(parts, ", ")
end

local function words(s)
  local out = {}
  for w in PYS.lower(s):gmatch("[a-z0-9']+") do out[#out + 1] = w end
  return out
end

local SKIP_KEYS = {template = true, npc = true, id = true, world = true, tags = true, appearance = true}
local function strings(x, out)
  if type(x) == "string" then
    if #words(x) >= 2 and not x:find("\\", 1, true) and not x:find("/", 1, true) then out[#out + 1] = x end
  elseif Y.is_map(x) then
    for _, k in ipairs(Y.keys(x)) do
      if not SKIP_KEYS[k] then strings(x[k], out) end
    end
  elseif Y.is_list(x) then
    for _, v in ipairs(x) do strings(v, out) end
  end
  return out
end

-- (texts, step kinds) of a project.yml: every line, title, objective; the kind of each step in order
function SIM.content_of_meta(meta)
  meta = Y.is_map(meta) and meta or Y.map()
  local top = Y.map()
  for _, k in ipairs(Y.keys(meta)) do
    if k ~= "id" and k ~= "uid" and k ~= "mark" and k ~= "run" then top[k] = meta[k] end
  end
  local texts = strings(top, {})
  local kinds = {}
  local qs = {}
  if Y.is_map(meta.quest) then qs[1] = meta.quest end
  if Y.is_list(meta.quests) then
    for _, q in ipairs(meta.quests) do if Y.is_map(q) then qs[#qs + 1] = q end end
  end
  for _, q in ipairs(qs) do
    if Y.is_list(q.steps) then
      for _, s in ipairs(q.steps) do
        if Y.is_map(s) and #Y.keys(s) > 0 then kinds[#kinds + 1] = Y.keys(s)[1] end
      end
    end
  end
  return texts, kinds
end

-- the word triples of the texts (a text of fewer words: its words), as a set
local function shingles(texts, n)
  n = n or 3
  local out = {}
  for _, t in ipairs(texts) do
    local w = words(tostring(t))
    if #w < n then
      if #w > 0 then out[table.concat(w, "\0")] = true end
    else
      for i = 1, #w - n + 1 do out[table.concat(w, "\0", i, i + n - 1)] = true end
    end
  end
  return out
end

local function yaml_objects(file)
  local ok, data = pcall(Y.read, file)
  local out = {}
  if ok and Y.is_map(data) and Y.is_list(data.objects) then
    for _, o in ipairs(data.objects) do
      local pos = Y.is_map(o) and o.pos
      if type(pos) == "table" and #pos >= 3 then out[#out + 1] = {pos[1], pos[2], pos[3]} end
    end
  end
  return out
end
SIM.yaml_objects = yaml_objects

-- a folder's *.yml files (glob's order on NTFS: by name)
function SIM.places_of(root)
  local dir, out = root .. "\\places", {}
  for _, n in ipairs(w3.fs.list(dir) or {}) do
    local name = type(n) == "table" and n.name or n
    if PYS.lower(name):sub(-4) == ".yml" then out[#out + 1] = dir .. "\\" .. name end
  end
  table.sort(out, function(a, b) return PYS.lower(a) < PYS.lower(b) end)
  return out
end

-- this PC's projects: {root, project.yml}
function SIM.projects()
  local out = {}
  for _, n in ipairs(w3.fs.list(PATHS.PROJECTS) or {}) do
    local name = type(n) == "table" and n.name or n
    local root = PATHS.PROJECTS .. "\\" .. name
    if w3.fs.exists(root .. "\\project.yml") then out[#out + 1] = root end
  end
  table.sort(out, function(a, b) return PYS.lower(a) < PYS.lower(b) end)
  return out
end

function SIM.normcase(p) return PYS.lower((tostring(p):gsub("/", "\\"):gsub("\\+$", ""))) end

local function objects_of(root)
  local out = {}
  for _, f in ipairs(SIM.places_of(root)) do
    for _, p in ipairs(yaml_objects(f)) do out[#out + 1] = p end
  end
  return out
end

-- Python's float // (floatobject.c float_floor_div)
local function floordiv(v, w)
  local mod = math.fmod(v, w)
  local div = (v - mod) / w
  if mod ~= 0 and ((w < 0) ~= (mod < 0)) then div = div - 1.0 end
  local fd
  if div ~= 0 then
    fd = math.floor(div)
    if div - fd > 0.5 then fd = fd + 1 end
  else
    fd = 0
  end
  return math.tointeger(fd) or fd
end

local function near_count(pts, own)
  local NEAR = SIM.NEAR
  local cells = {}
  local function key(a, b, c) return a .. "," .. b .. "," .. c end
  for _, q in ipairs(own) do
    local k = key(floordiv(q[1], NEAR), floordiv(q[2], NEAR), floordiv(q[3], NEAR))
    cells[k] = cells[k] or {}
    table.insert(cells[k], q)
  end
  local n, r2 = 0, NEAR ^ 2
  for _, p in ipairs(pts) do
    local c = {floordiv(p[1], NEAR), floordiv(p[2], NEAR), floordiv(p[3], NEAR)}
    local hit = false
    for dx = -1, 1 do
      for dy = -1, 1 do
        for dz = -1, 1 do
          for _, q in ipairs(cells[key(c[1] + dx, c[2] + dy, c[3] + dz)] or {}) do
            local d = (p[1] - q[1]) ^ 2
            d = d + (p[2] - q[2]) ^ 2
            d = d + (p[3] - q[3]) ^ 2
            if d <= r2 then hit = true break end
          end
          if hit then break end
        end
        if hit then break end
      end
      if hit then break end
    end
    if hit then n = n + 1 end
  end
  return n
end

-- difflib.SequenceMatcher(a=a, b=b, autojunk=False).ratio()
function SIM.ratio(a, b)
  local b2j = {}
  for j, x in ipairs(b) do
    b2j[x] = b2j[x] or {}
    table.insert(b2j[x], j - 1)
  end
  local function longest(alo, ahi, blo, bhi)
    local besti, bestj, bestsize = alo, blo, 0
    local j2len = {}
    for i = alo, ahi - 1 do
      local newj2len = {}
      for _, j in ipairs(b2j[a[i + 1]] or {}) do
        if j >= blo then
          if j >= bhi then break end
          local k = (j2len[j - 1] or 0) + 1
          newj2len[j] = k
          if k > bestsize then besti, bestj, bestsize = i - k + 1, j - k + 1, k end
        end
      end
      j2len = newj2len
    end
    while besti > alo and bestj > blo and a[besti] == b[bestj] do
      besti, bestj, bestsize = besti - 1, bestj - 1, bestsize + 1
    end
    while besti + bestsize < ahi and bestj + bestsize < bhi and a[besti + bestsize + 1] == b[bestj + bestsize + 1] do
      bestsize = bestsize + 1
    end
    return besti, bestj, bestsize
  end
  local matches, queue = 0, {{0, #a, 0, #b}}
  while #queue > 0 do
    local alo, ahi, blo, bhi = table.unpack(table.remove(queue))
    local i, j, k = longest(alo, ahi, blo, bhi)
    if k > 0 then
      matches = matches + k
      if alo < i and blo < j then queue[#queue + 1] = {alo, i, blo, j} end
      if i + k < ahi and j + k < bhi then queue[#queue + 1] = {i + k, ahi, j + k, bhi} end
    end
  end
  local total = #a + #b
  return total > 0 and 2.0 * matches / total or 1.0
end

-- this PC's projects the quest (its texts, step kinds, placed objects {{pos}}) is alike, most alike first
function SIM.compare(texts, kinds, objects, skip)
  local sh = shingles(texts)
  local sh_n = 0
  for _ in pairs(sh) do sh_n = sh_n + 1 end
  local pts = {}
  for _, o in ipairs(objects or {}) do
    local pos = o.pos
    if type(pos) == "table" and #pos >= 3 then pts[#pts + 1] = {pos[1], pos[2], pos[3]} end
  end
  local out = {}
  for _, root in ipairs(SIM.projects()) do
    if not (skip and skip ~= "" and SIM.normcase(root) == SIM.normcase(skip)) then
      local ok, meta = pcall(Y.read, root .. "\\project.yml")
      if ok then
        if not Y.is_map(meta) then meta = Y.map() end
        local own_texts, own_kinds = SIM.content_of_meta(meta)
        local t = nil
        if sh_n > 0 then
          local own, own_n, both = shingles(own_texts), 0, 0
          for k in pairs(own) do
            own_n = own_n + 1
            if sh[k] then both = both + 1 end
          end
          t = own_n > 0 and both / sh_n or 0.0
        end
        local o = nil
        if #pts >= SIM.LEAST_OBJECTS then
          local own_pts = objects_of(root)
          o = #own_pts > 0 and {near_count(pts, own_pts), #pts} or {0, #pts}
        end
        local s = (#kinds > 0 and #own_kinds > 0) and SIM.ratio(kinds, own_kinds) or nil
        local name = meta.name
        if name == nil or name == Y.null or name == "" or name == false then name = root:match("([^\\]+)$") end
        local m = Match.new(tostring(name), root, t, o, s)
        if m:strong() then out[#out + 1] = m end
      end
    end
  end
  local function key(m)
    return -math.max(m.texts or 0, m.objects and (m.objects[1] / m.objects[2]) or 0, m.steps or 0)
  end
  return require("conjunction.pysort").sorted(out, key)
end

return SIM
