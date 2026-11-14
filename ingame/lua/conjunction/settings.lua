-- Settings (settings.py): one menu for everything - General, Game, Tools, Plug-ins. Kept in Conjunction's config
-- (config.json): Conjunction's own under "settings" (the game's paths where they always were: "game", "redkit",
-- "radish"), the plug-ins' on / off under "plugins".
--   S.value(key, default)   "game.folder", "game.redkit", "tools.blender", "general.sound_off" ...
--   S.set_value(key, v)     S.plugins_enabled()   S.set_enabled(id, on)
--   (the page: ui/settings_window.lua)
local CFG = require("conjunction.config")
local Y = require("conjunction.yaml")
local S = {}

-- Conjunction's own fields: {section, key, label, type, default}; the game's paths live at the top of the config
S.TOP = {["game.folder"] = "game", ["game.redkit"] = "redkit", ["game.radish"] = "radish", ["general.mode"] = "mode"}
S.FIELDS = {
  {"General", "general.sound_off", "Game sound off while editing", "bool", false},
  {"General", "general.experimental", "Experimental features", "bool", false},
  {"Game", "game.folder", "The Witcher 3", "path", ""},
  {"Game", "game.redkit", "REDkit", "path", ""},
  {"Game", "game.radish", "radish", "path", ""},
  {"Tools", "tools.blender", "Blender", "file", nil},
}
S.SECTIONS = {"General", "Game", "Tools"}     -- (Performance went to Motion's own settings, 06.10.)

local function isnull(v) return v == nil or v == Y.null end

-- the newest Blender in Program Files, or ""
function S.blender()
  local base = [[C:\Program Files\Blender Foundation]]
  local found = {}
  for _, e in ipairs(w3.fs.list(base) or {}) do
    local exe = base .. "\\" .. e.name .. "\\blender.exe"
    if e.dir and e.name:sub(1, 8) == "Blender " and w3.fs.exists(exe) then found[#found + 1] = exe end
  end
  table.sort(found)
  return found[#found] or ""
end

local function default(key)
  if key == "tools.blender" then return S.blender() end
  for _, f in ipairs(S.FIELDS) do if f[2] == key then return f[5] end end
  return nil
end

function S.value(key, dflt, cfg)
  cfg = cfg or CFG.load()
  local v
  if S.TOP[key] then
    v = cfg[S.TOP[key]]
  elseif key == "general.sound_off" then
    v = cfg.sound_off
  else
    local sec, name = key:match("^([^.]*)%.?(.*)$")
    local all = type(cfg.settings) == "table" and cfg.settings or {}
    local s = type(all[sec]) == "table" and all[sec] or {}
    v = s[name]
  end
  if isnull(v) or v == "" then
    local d = default(key)
    if not isnull(d) and d ~= "" then return d end
    return dflt
  end
  return v
end

function S.set_value(key, v)
  local cfg = CFG.load()
  if S.TOP[key] then
    cfg[S.TOP[key]] = v
    if key == "game.redkit" and v ~= nil and v ~= "" and v ~= false then
      cfg.wcc = v .. "\\bin\\x64_RedKit\\wcc_lite.exe"
    end
  elseif key == "general.sound_off" then
    cfg.sound_off = not not v
  else
    local sec, name = key:match("^([^.]*)%.?(.*)$")
    if type(cfg.settings) ~= "table" then cfg.settings = Y.map() end
    if type(cfg.settings[sec]) ~= "table" then cfg.settings[sec] = Y.map() end
    cfg.settings[sec][name] = v
  end
  CFG.save(cfg)
end

-- --- plug-ins: on / off
function S.plugins_enabled(cfg)
  cfg = cfg or CFG.load()
  local p = type(cfg.plugins) == "table" and cfg.plugins or {}
  local out = {}
  for k, v in pairs(type(p.enabled) == "table" and p.enabled or {}) do out[k] = v end
  return out
end

function S.set_enabled(pid, on)
  local cfg = CFG.load()
  if type(cfg.plugins) ~= "table" then cfg.plugins = Y.map() end
  if type(cfg.plugins.enabled) ~= "table" then cfg.plugins.enabled = Y.map() end
  cfg.plugins.enabled[pid] = not not on
  CFG.save(cfg)
end

return S
