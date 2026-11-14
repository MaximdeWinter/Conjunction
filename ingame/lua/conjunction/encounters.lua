-- The game's encounters (encounters.py): the creatures of an area (wolves, drowners - CEncounter in the world's
-- layers) with their tags and where they stand. A quest step "creatures around here off" is built with the tags of
-- those within its radius. An index per world, made once from the game's files and kept where the app keeps it.
--   E.near(world, pos, radius) -> {{tag, distance}, ...} nearest first   E.index(world) -> {{tags, pos, layer}}
local J = require("conjunction.json")
local CFG = require("conjunction.config")
local PYS = require("conjunction.pystr")
local N = require("conjunction.pynum")
local E = {}

local function dirname(p) return (p:gsub("[\\/][^\\/]*$", "")) end

-- the depot folder of a world's layers, by the radish world id (velen: levels\novigrad\)
function E.prefix(world)
  local worlds = require("conjunction.project").worlds()
  local paths = {}
  for path in pairs(worlds) do paths[#paths + 1] = path end
  table.sort(paths)                              -- (the app's dict: the repo's order; one world has one folder)
  for _, path in ipairs(paths) do
    if worlds[path] == world then return path:gsub("\\[^\\]*$", "") .. "\\" end
  end
  error("unknown world " .. tostring(world))
end

function E.cache_path(world, cls)
  local kind = (cls == nil or cls == "CEncounter") and "encounters" or PYS.lower(cls)
  return dirname(CFG.PATH) .. "\\" .. kind .. "_" .. world .. ".json"
end

-- TagList: a count, then that many name indices (uint16)
local function taglist(f, raw)
  if raw == nil or raw == "" then return {} end
  local n = raw:byte(1)
  local out = {}
  for i = 0, n - 1 do
    if 3 + 2 * i <= #raw then out[#out + 1] = f.names[string.unpack("<I2", raw, 2 + 2 * i) + 1] end
  end
  return out
end

-- every CEncounter (or cls: W3NoticeBoard) of the world's layers -> {{tags, pos, layer}}
function E.scan(world, log, cls)
  cls = cls or "CEncounter"
  log = log or print
  local CR = require("conjunction.cr2w")
  local MV = require("conjunction.meshview")
  local folder = E.prefix(world)
  local depot = require("conjunction.depot").open(CFG.load().game)
  local layers = depot:glob(folder, ".w2l")
  local out = {}
  for k, path in ipairs(layers) do
    if (k - 1) % 2000 == 0 then log(string.format("[%s] %s: %d/%d layers, %d found", cls, world, k - 1, #layers, #out)) end
    local ok, data = pcall(function() return depot:read(path) end)
    if ok and type(data) == "string" and data:find(cls, 1, true) then
      for _, f in ipairs(CR.parts(data)) do
        for _, e in ipairs(f.exports) do
          if e[1] == cls then
            local okp, props = pcall(function() return f:props(e[5], 1) end)
            if okp then
              local tags, pos = {}, nil
              for _, pr in ipairs(props) do
                local raw = e[5]:sub(pr[3] + 1, pr[3] + pr[4])
                if pr[1] == "tags" then tags = taglist(f, raw)
                elseif pr[1] == "transform" then
                  local p = MV.transform(raw)[1]
                  pos = {N.round(p[1], 2), N.round(p[2], 2), N.round(p[3], 2)}
                end
              end
              if #tags > 0 and pos then out[#out + 1] = {tags = tags, pos = pos, layer = path} end
            end
          end
        end
      end
    end
    if coroutine.isyieldable() then coroutine.yield() end
  end
  return out
end

function E.index(world, log, cls)
  local path = E.cache_path(world, cls)
  if w3.fs.exists(path) then return J.read(path) end
  local found = E.scan(world, log, cls)
  if not os.getenv("CJ_REF") then
    pcall(function()
      assert(w3.fs.write(path .. ".tmp", J.encode(found)))
      if w3.fs.exists(path) then w3.fs.remove(path) end
      w3.fs.rename(path .. ".tmp", path)
    end)
  end
  return found
end

-- {{tag, distance}} of the encounters whose place lies within the radius (nearest first; their first tag)
function E.near(world, pos, radius, log)
  local seen, out = {}, {}
  for _, e in ipairs(E.index(world, log)) do
    local d = N.hypot(e.pos[1] - pos[1], e.pos[2] - pos[2])
    if d <= radius then
      local item = {e.tags[1], N.round(d, 1)}
      local key = tostring(item[1]) .. "\0" .. N.str(item[2])
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = item
      end
    end
  end
  -- sorted(set(out), key=distance): the set's order among equals is the app's hash order - here by tag
  table.sort(out, function(a, b)
    if a[2] ~= b[2] then return a[2] < b[2] end
    return tostring(a[1]) < tostring(b[1])
  end)
  return out
end

return E
