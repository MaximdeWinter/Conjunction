-- The game's files straight out of its bundles (bundles.Depot) - through cj_core (ingame/plugin/depot.cpp): its index
-- of every bundle's files (later bundles and DLCs win, as in the game), a file unpacked on request.
--   local d = DP.open(game)        game: the game's folder (config "game"); the index is kept while no bundle changes
--   d:exists(path)   d:read(path) -> its bytes   d:glob(prefix, suffix) -> paths (lower case, the index's order)
--   DP.open_async(game) -> d, or nil while cj_core makes the index on its own thread (ask again)
-- The last few files read are kept (the 3D view reads a template three times: its looks, colours, meshes).
local DP = {}
DP.__index = DP

local function plugin(name)
  local p = w3.plugin and w3.plugin[name]
  if not p then error("cj_core is not loaded (tw3se\\plugins\\cj_core.dll): no w3.plugin." .. name, 3) end
  return p
end
-- the files a call hands over: a folder of this Lua state's own (20.10.: two labs at once read through one
-- depot_read.bin - one's reads got the other's files, then the file stayed locked)
local own = string.format("%x_%x", os.time(), math.floor((os.clock() * 1e6) % 0x7fffffff))
local function scratch(name)
  local base = w3.fs.folder("temp") .. "\\cj_core"
  if not w3.fs.isdir(base) then w3.fs.mkdir(base) end
  local dir = base .. "\\depot_" .. own
  if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  return dir .. "\\" .. name
end

local function made(game, got)
  local files, bundles = tostring(got):match("^(%d+)\t(%d+)$")
  return setmetatable({game = game, files = tonumber(files), bundles = tonumber(bundles), kept = {}}, DP)
end
function DP.open(game)
  local ok, got = pcall(plugin("cj_depot_open"), game)
  if ok then return made(game, got) end
  if not tostring(got):find("being made", 1, true) then error(got, 2) end
  -- (made on cj_core's thread since the start: waited for, not made twice)
  repeat got = plugin("cj_depot_open_async")(game) until got ~= "busy"
  return made(game, got)
end
function DP.open_async(game)
  local got = plugin("cj_depot_open_async")(game)
  if got == "busy" then return nil end
  return made(game, got)
end
DP.KEEP = 4

function DP:exists(path) return plugin("cj_depot_exists")(path) == "1" end

function DP:read(path)
  local kept = self.kept or {}
  self.kept = kept
  for i, k in ipairs(kept) do
    if k[1] == path then
      table.insert(kept, 1, table.remove(kept, i))
      return k[2]
    end
  end
  local data, err
  if DP.direct == nil then DP.direct = w3.plugin and w3.plugin.cj_depot_data ~= nil end
  if DP.direct then                              -- (its bytes straight to Lua: TW3SE 20's LuaReplyBytes)
    local ok, got = pcall(w3.plugin.cj_depot_data, path)
    if ok then data = got
    elseif tostring(got):find("LuaReplyBytes", 1, true) then DP.direct = false   -- (an older TW3SE: by a file)
    else error("depot: " .. path .. ": " .. tostring(got), 2) end
  end
  if data == nil then
    -- (through a file: written, read, removed - 25.10.: 8.7 ms a file, most of the asset build's 25 minutes)
    local out = scratch("depot_read.bin")
    plugin("cj_depot_read")(path, out)
    data, err = w3.fs.read(out)
    w3.fs.remove(out)
  end
  if not data then error("depot: " .. path .. ": " .. tostring(err), 2) end
  table.insert(kept, 1, {path, data})
  kept[DP.KEEP + 1] = nil
  return data
end

function DP:glob(prefix, suffix)
  local out = scratch("depot_glob.txt")
  plugin("cj_depot_glob")(prefix, suffix or "", out)
  local text = w3.fs.read(out) or ""
  w3.fs.remove(out)
  local paths = {}
  for line in text:gmatch("[^\n]+") do paths[#paths + 1] = line end
  return paths
end

-- as glob, each path with the bundle it comes from (bundles.Depot.where[p][0]) -> {{path, bundle}}
function DP:glob_where(prefix, suffix)
  local out = scratch("depot_glob_where.txt")
  plugin("cj_depot_glob_where")(prefix, suffix or "", out)
  local text = w3.fs.read(out) or ""
  w3.fs.remove(out)
  local rows = {}
  for line in text:gmatch("[^\n]+") do
    local p, b = line:match("^([^\t]*)\t(.*)$")
    rows[#rows + 1] = {p or line, b or ""}
  end
  return rows
end

return DP
