-- radish modding tools (by rmemr, nexusmods.com/witcher3/mods/3620) for building (radish_tools.py): the Nexus zip found
-- in Downloads (or Vortex's downloads) or picked, unpacked into Documents\Conjunction\tools\radish-tools and every exe
-- and dll checked against radish's own crc.radish-modding-tools.current.txt. A radish folder the user already has is
-- only checked, never changed.
--   RT.install(current, log) -> the folder (the one set, or unpacked), or error(RT.Bad)
--   RT.install_from(zip, log) -> the folder     RT.find_zip() -> path|nil     RT.check(folder) -> {problem}
--   RT.at_start(ed)          the config's radish checked once per folder; missing: the radish window
local PATHS = require("conjunction.paths")
local PYS = require("conjunction.pystr")
local RT = {}

RT.ZIP_NAME = "radish.modding.tools-v2020-11-21-3620-v2020-11-21-1606002572.zip"
RT.ZIP_SHA256 = "f7417b7fb65160a7e11b8d9b32f597ae7a8f229ddd1e22797edb983526813b1c"
RT.ZIP_SIZE = 25611051
RT.CRC = "crc.radish-modding-tools.current.txt"
RT.NEXUS = "https://www.nexusmods.com/witcher3/mods/3620"

-- what a failure says (radish_tools.Bad): error({bad = text}) - RT.message(err) gives the text of any error
local function bad(text) error({bad = text}, 0) end
function RT.message(err) return type(err) == "table" and err.bad or tostring(err) end

local function isfile(p) return p ~= nil and p ~= "" and w3.fs.exists(p) and not w3.fs.isdir(p) end
function RT.sha256(path) return w3.plugin.cj_sha256_parts("F:" .. path) end

local function size_of(path)
  local dir, name = path:match("^(.*)\\([^\\]+)$")
  for _, e in ipairs(dir and w3.fs.list(dir) or {}) do
    if e.name == name then return e.size end
  end
  return nil
end

-- the Nexus zip in the mod (or in the repository's third_party for a build from the source) -> path|nil
function RT.bundled_zip()
  for _, r in ipairs({PATHS.MOD_ROOT, PATHS.REPO}) do
    local p = r and (r .. "\\third_party\\radish\\" .. RT.ZIP_NAME)
    if p and isfile(p) then return p end
  end
  return nil
end

-- where a downloaded radish zip lands: the user's Downloads, Vortex's downloads for The Witcher 3
function RT.download_dirs()
  local out = {(os.getenv("USERPROFILE") or "") .. "\\Downloads"}
  if os.getenv("APPDATA") then out[#out + 1] = os.getenv("APPDATA") .. "\\Vortex\\downloads\\witcher3" end
  return out
end

-- is it radish's Nexus zip, as downloaded (its size, then its sha256)?
function RT.is_radish_zip(path, size)
  size = size or size_of(path)
  return size == RT.ZIP_SIZE and RT.sha256(path) == RT.ZIP_SHA256
end

-- radish's Nexus zip: the mod's own, else a download of it (any name: a browser may add "(1)") -> path|nil
function RT.find_zip()
  local z = RT.bundled_zip()
  if z then return z end
  for _, d in ipairs(RT.download_dirs()) do
    local entries = w3.fs.isdir(d) and w3.fs.list(d) or {}
    table.sort(entries, function(a, b) return a.name < b.name end)
    for _, e in ipairs(entries) do
      local n = PYS.lower(e.name)
      if not e.dir and n:sub(1, 6) == "radish" and n:sub(-4) == ".zip" and RT.is_radish_zip(d .. "\\" .. e.name, e.size) then
        return d .. "\\" .. e.name
      end
    end
  end
  return nil
end

function RT.target() return PATHS.HOME .. "\\tools\\radish-tools" end

-- {file = sha256} from radish's crc list in the folder: a file's line, then its indented lines up to "sha256: "
function RT.expected(folder)
  local p = folder .. "\\" .. RT.CRC
  if not isfile(p) then bad(RT.CRC .. " is missing in " .. folder) end
  local out, cur = {}, nil
  for line in ((w3.fs.read(p) or ""):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
    local name = line:match("^(%S+%.exe)%s*$") or line:match("^(%S+%.dll)%s*$")
    if name then
      cur = name
    elseif cur and line:match("^[ \t]") then
      local sha = line:match("^[ \t]+sha256: (%w+)")
      if sha then out[cur], cur = sha, nil end
    else
      cur = nil
    end
  end
  return out
end

-- {problem} for every exe / dll of radish's list that is missing or differs (empty: as radish shipped it)
function RT.check(folder)
  local ok, want = pcall(RT.expected, folder)
  if not ok then return {RT.message(want)} end
  local names = {}
  for n in pairs(want) do names[#names + 1] = n end
  if #names == 0 then return {RT.CRC .. " lists no files"} end
  table.sort(names)
  local out = {}
  for _, n in ipairs(names) do
    local p = folder .. "\\" .. n
    if not isfile(p) then out[#out + 1] = n .. ": missing"
    elseif RT.sha256(p) ~= want[n] then out[#out + 1] = n .. ": changed (not as radish shipped it)" end
  end
  return out
end

-- the Nexus zip into dest (its top folder radish-tools\ becomes dest) -> dest
function RT.unpack(zip, dest, log)
  log = log or print
  local FS = require("conjunction.fsutil")
  local LIB = require("conjunction.library")
  if RT.sha256(zip) ~= RT.ZIP_SHA256 then
    bad(zip:match("([^\\]+)$") .. " is not the zip from Nexus (its sha256 differs)")
  end
  local tmp = dest .. ".unpacking"
  if w3.fs.isdir(tmp) then FS.rmtree(tmp) end
  local plan = {}
  for _, n in ipairs(LIB.zip_names(zip)) do
    local rest = n:gsub("\\", "/"):match("^[^/]*/(.+)$")
    local safe = rest and rest:sub(-1) ~= "/"
    for part in (rest or ""):gmatch("[^/]+") do if part == ".." then safe = false end end
    if safe then plan[#plan + 1] = {n, tmp .. "\\" .. rest:gsub("/", "\\")} end
  end
  w3.fs.mkdir(tmp)
  LIB.zip_extract(zip, plan)
  local problems = RT.check(tmp)
  if #problems > 0 then
    bad("radish unpacked, but: " .. table.concat(problems, "; ", 1, math.min(3, #problems)))
  end
  if w3.fs.isdir(dest) then FS.rmtree(dest) end
  w3.fs.mkdir(dest:match("^(.*)\\[^\\]+$"))
  assert(w3.fs.rename(tmp, dest))
  log("radish modding tools unpacked into " .. dest .. " and checked against " .. RT.CRC)
  return dest
end

-- the radish folder to use: current (the config's) when it is there and unmodified, else the zip unpacked (once)
function RT.install(current, log)
  log = log or print
  if current and current ~= "" and isfile(current .. "\\w2quest.exe") then
    local problems = RT.check(current)
    if #problems == 0 then return current end
    log("radish in " .. current .. " is not as radish shipped it: " ..
        table.concat(problems, "; ", 1, math.min(3, #problems)))
  end
  local dest = RT.target()
  if isfile(dest .. "\\w2quest.exe") and #RT.check(dest) == 0 then return dest end
  local z = RT.find_zip()
  if not z then bad("No radish modding tools. Please download them from " .. RT.NEXUS) end
  return RT.unpack(z, dest, log)
end

-- a radish zip the user picked -> the folder it is unpacked into
function RT.install_from(zip, log)
  if not RT.is_radish_zip(zip) then bad("This is not the radish zip from " .. RT.NEXUS .. " (" .. RT.ZIP_NAME .. ")") end
  return RT.unpack(zip, RT.target(), log)
end

-- at the start (__main__: radish checked once per folder; missing: radish_view.ask)
function RT.at_start(ed)
  local CFG = require("conjunction.config")
  local cfg = CFG.load()
  local cur = type(cfg.radish) == "string" and cfg.radish or ""
  if isfile(cur .. "\\w2quest.exe") and cfg.radish_checked == cur then return end
  local ok, got = pcall(RT.install, cur, print)
  if ok then
    cfg.radish = got                     -- (one after the other: the config keeps its keys in order)
    cfg.radish_checked = got
    CFG.save(cfg)
    return
  end
  print("radish: " .. RT.message(got))
  require("conjunction.ui.radish_window").open(ed, function(folder)
    local c = CFG.load()
    c.radish = folder
    c.radish_checked = folder
    CFG.save(c)
  end)
end

return RT
