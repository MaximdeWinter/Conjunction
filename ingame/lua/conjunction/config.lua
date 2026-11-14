-- Conjunction's settings (config.py): Documents\Conjunction\data\config.json, the same file the app reads.
--
--   local cfg = CFG.load()        -- a fresh table each time (as config.load reads the file each time)
--   cfg.fly_speed = 6.0
--   CFG.save(cfg)
local J = require("conjunction.json")
local Y = require("conjunction.yaml")
local PATHS = require("conjunction.paths")
local C = {}
C.PATH = PATHS.DATA .. "\\config.json"
C.GUESSES = {
  {"game", {[[C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3]],
            [[C:\Program Files (x86)\GOG Galaxy\Games\The Witcher 3 Wild Hunt GOTY]],
            [[C:\GOG Games\The Witcher 3 Wild Hunt GOTY]]}},
  {"redkit", {[[C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3 REDkit]]}},
  {"radish", {[[C:\Apps\radish-tools]], [[C:\radish-tools]], [[C:\Modding\radish-tools]]}},
}

local function fs() return w3.fs end
local function isdir(p) return fs().isdir(p) end

-- the game's folder: the one this mod runs in (TW3SE's folder is <game>\bin\x64_dx12\tw3se)
local function own_game()
  local d = w3.dir and w3.dir()
  if not d then return nil end
  return (d:gsub("[\\/]bin[\\/][^\\/]+[\\/]tw3se[\\/]?$", ""))
end

-- REDkit where Steam or GOG puts it: beside the game (the same library), then in each of Steam's libraries
-- (steamapps\libraryfolders.vdf: a library on another drive is common)
local function redkit_places()
  local out = {}
  local game = own_game()
  if game then
    out[#out + 1] = (game:gsub("[\\/][^\\/]+$", "")) .. "\\The Witcher 3 REDkit"
    local lib = game:match("^(.-)[\\/]steamapps[\\/]common[\\/]")
    if lib then out[#out + 1] = lib .. "\\steamapps\\common\\The Witcher 3 REDkit" end
  end
  for _, steam in ipairs({[[C:\Program Files (x86)\Steam]], [[C:\Program Files\Steam]]}) do
    local vdf = fs().read(steam .. "\\steamapps\\libraryfolders.vdf")
    for lib in tostring(vdf or ""):gmatch('"path"%s*"([^"]+)"') do
      out[#out + 1] = (lib:gsub("\\\\", "\\")) .. "\\steamapps\\common\\The Witcher 3 REDkit"
    end
  end
  out[#out + 1] = [[C:\GOG Games\The Witcher 3 REDkit]]
  return out
end

function C.load()
  local cfg
  if fs().exists(C.PATH) then
    cfg = J.read(C.PATH)
  else
    -- first start: guesses (the app looks in Steam's libraries and GOG's registry too; in the game the game is here)
    cfg = Y.map()
    for _, g in ipairs(C.GUESSES) do
      local key, list = g[1], g[2]
      local found = key == "game" and own_game() or nil
      if key == "redkit" then
        for _, p in ipairs(redkit_places()) do if not found and isdir(p .. "\\bin") then found = p end end
      end
      for _, p in ipairs(list) do if not found and isdir(p) then found = p end end
      cfg[key] = found or list[1]
    end
    cfg.wcc = cfg.redkit .. "\\bin\\x64_RedKit\\wcc_lite.exe"
    fs().mkdir(PATHS.DATA)
    J.write(C.PATH, cfg, {indent = 1})
  end
  local layer = os.getenv("CJ_CONFIG_LAYER")       -- the background Conjunction's own settings (bg.py)
  if layer and fs().exists(layer) then
    for k, v in pairs(J.read(layer)) do cfg[k] = v end
  end
  local gd = os.getenv("CJ_GAME_DIR")
  if gd and gd ~= "" then cfg.game = gd end
  return cfg
end

-- written whole beside it, then put in its place (w3.fs.write)
function C.save(cfg)
  -- (the lab without a Documents\Conjunction of its own - CJ_HOME - never writes MaximdeWinter's settings: a check's
  -- stand-in settings went over his config.json once, 19.10.)
  local home = os.getenv("CJ_HOME")
  if rawget(_G, "lab") ~= nil and (home == nil or home == "") then return end
  fs().mkdir(PATHS.DATA)
  local layer = os.getenv("CJ_CONFIG_LAYER")
  if layer and layer ~= "" then        -- the background suite: only what differs from MaximdeWinter's, in its layer
    local base = fs().exists(C.PATH) and J.read(C.PATH) or Y.map()
    local diff = Y.map()
    for k, v in pairs(cfg) do
      if k ~= "game" and J.encode(base[k]) ~= J.encode(v) then diff[k] = v end
    end
    J.write(layer, diff, {indent = 1})
    return
  end
  local gd = os.getenv("CJ_GAME_DIR")
  if gd and gd ~= "" and cfg.game == gd and fs().exists(C.PATH) then    -- never kept: MaximdeWinter's game stays
    local copy = Y.map()
    for k, v in pairs(cfg) do copy[k] = v end
    copy.game = J.read(C.PATH).game
    cfg = copy
  end
  J.write(C.PATH, cfg, {indent = 1})
end

-- one value set and kept (the editor's "cfg = config.load(); cfg[k] = v; config.save(cfg)")
function C.set(key, value)
  local cfg = C.load()
  cfg[key] = value
  C.save(cfg)
end
return C
