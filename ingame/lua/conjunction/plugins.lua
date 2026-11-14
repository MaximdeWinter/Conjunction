-- Plug-ins (plugins.py) as Settings > Plug-ins lists them: a folder with plugin.py and plugin.json, found in the
-- plug-ins folders; on / off per plug-in (one marked adult is off until switched on); the order and the status as
-- plugins.Plugins works them out. The game runs no plug-in's Python: "loaded" is what the app loads.
--   local PL = PG.new(dirs, enabled)   PL:listing() -> {{manifest, status}}   PL.found   PL.status
local J = require("conjunction.json")
local PATHS = require("conjunction.paths")
local Y = require("conjunction.yaml")
local PG = {}
PG.__index = PG
PG.API = 1
PG.DIRS = {}                 -- the ones Conjunction brings (the repo's plugins\; the mod brings none)

local function base(p) return (p:gsub("[\\/]+$", "")):match("([^\\/]+)$") or p end
local function isfile(p) return w3.fs.exists(p) and not w3.fs.isdir(p) end

-- a plug-in's plugin.json (or what its folder says)
function PG.manifest(folder)
  local m
  local path = folder .. "\\plugin.json"
  if w3.fs.exists(path) then
    local ok, got = pcall(J.read, path)
    m = ok and type(got) == "table" and got or nil
  end
  m = m or {}
  local name = base(folder)
  if m.id == nil then m.id = (name:gsub("^_+", "")):lower():gsub(" ", "_") end
  if m.name == nil then
    m.name = (m.id:gsub("_", " ")):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b:lower() end)
  end
  if m.version == nil then m.version = "" end
  if m.api == nil then m.api = PG.API end
  if m.requires == nil then m.requires = {} end
  m.adult = m.adult ~= nil and m.adult ~= false and m.adult ~= Y.null and m.adult ~= 0 and m.adult ~= ""
  return m
end

function PG.new(dirs, enabled)
  local self = setmetatable({found = {}, status = {}}, PG)
  if dirs == nil then
    dirs = {}
    for _, d in ipairs(PG.DIRS) do dirs[#dirs + 1] = d end
    dirs[#dirs + 1] = PATHS.PLUGINS
  end
  enabled = enabled or require("conjunction.settings").plugins_enabled()
  local cands, order_found = {}, {}
  for _, d in ipairs(dirs) do
    if w3.fs.isdir(d) then
      local itself = isfile(d .. "\\plugin.py")
      local subs = {}
      if itself then subs = {d}
      else for _, e in ipairs(w3.fs.list(d) or {}) do subs[#subs + 1] = d .. "\\" .. e.name end end
      for _, folder in ipairs(subs) do
        local name = base(folder)
        if isfile(folder .. "\\plugin.py") and name:sub(1, 1) ~= "." and (itself or name:sub(1, 1) ~= "_") then
          local m = PG.manifest(folder)
          if not cands[m.id] then              -- (the first found wins)
            cands[m.id] = {folder, m}
            order_found[#order_found + 1] = m.id
            self.found[#self.found + 1] = {folder, m}
          end
        end
      end
    end
  end
  local on = {}
  for _, pid in ipairs(order_found) do
    local want = enabled[pid]
    if want ~= nil and want ~= Y.null then on[pid] = not not want else on[pid] = not cands[pid][2].adult end
    if not on[pid] then self.status[pid] = "off" end
  end
  -- the order: every plug-in after those it requires
  local done, order = {}, {}
  local function visit(pid, path)
    if done[pid] or path[pid] then return end
    local p2 = setmetatable({[pid] = true}, {__index = path})
    for _, r in ipairs(cands[pid][2].requires) do if cands[r] then visit(r, p2) end end
    done[pid] = true
    order[#order + 1] = pid
  end
  local sorted = {}
  for _, pid in ipairs(order_found) do sorted[#sorted + 1] = pid end
  table.sort(sorted)
  for _, pid in ipairs(sorted) do visit(pid, {}) end
  for _, pid in ipairs(order) do
    if on[pid] then
      local m = cands[pid][2]
      local lacking = {}
      for _, r in ipairs(m.requires) do if self.status[r] ~= "loaded" then lacking[#lacking + 1] = r end end
      if #lacking > 0 then
        local names = {}
        for i, r in ipairs(lacking) do names[i] = cands[r] and cands[r][2].name or r end
        self.status[pid] = "needs " .. table.concat(names, ", ")
      elseif (tonumber(m.api) or PG.API) > PG.API then
        self.status[pid] = string.format("needs a newer Conjunction (plug-in API %s)", tostring(m.api))
      else
        self.status[pid] = "loaded"
      end
    end
  end
  return self
end

-- {{manifest, status}} of every plug-in found - an adult one off: only its name
function PG:listing()
  local out = {}
  for _, fm in ipairs(self.found) do
    local folder, m = fm[1], fm[2]
    local st = self.status[m.id] or "off"
    if m.adult and st == "off" then
      m = {id = m.id, name = m.name, adult = m.adult}
    else
      local readme
      for _, n in ipairs({"README.md", "readme.md", "README.txt"}) do
        if not readme and isfile(folder .. "\\" .. n) then readme = folder .. "\\" .. n end
      end
      if readme then
        local copy = {}
        for k, v in pairs(m) do copy[k] = v end
        copy.readme = readme
        m = copy
      end
    end
    out[#out + 1] = {m, st}
  end
  return out
end

return PG
