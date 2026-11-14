-- Content packs as folders (contentpacks.py): <pack>\pack.yml (id, name, author, version, description) in one of the
-- pack folders - Conjunction's own packs\, Documents\conjunction\packs, the config's pack_dirs. What the library asks
-- of them (a quest's needs), and their voice lines for the dialogue editor:
--   <pack>\voices\voices.yml   lines: [{id, file, text, speaker, tags: [...], lang}]   <pack>\voices\*.wav ...
-- A voice line is known as "<pack id>/<line id>".
--   CP.pack_dirs()   CP.packs() -> {{path, id, name, author, version, description, voices, problems}}
--   CP.voice_lines()   CP.voice(key)   CP.voice_tags() -> {{tag, n}}   CP.search_voices(text, tags, limit)
local Y = require("conjunction.yaml")
local CFG = require("conjunction.config")
local PATHS = require("conjunction.paths")
local CP = {}

local function norm(p)                          -- os.path.normpath for these folders
  p = p:gsub("/", "\\")
  local drive, rest = p:match("^(%a:)(.*)$")
  local lead = ""
  if not drive then drive, rest = "", p end
  if rest:sub(1, 1) == "\\" then lead = "\\" end
  local parts = {}
  for part in rest:gmatch("[^\\]+") do
    if part == ".." and #parts > 0 and parts[#parts] ~= ".." then parts[#parts] = nil
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return drive .. lead .. table.concat(parts, "\\")
end

-- (the app's packs\ beside conjunction\: the repository's; the mod's own beside its Lua)
function CP.own_dir() return (PATHS.REPO or PATHS.MOD_ROOT) .. "\\packs" end

function CP.pack_dirs()
  local cfg = CFG.load()
  local dirs = {}
  dirs[#dirs + 1] = CP.own_dir()
  dirs[#dirs + 1] = PATHS.HOME .. "\\packs"
  for _, d in ipairs(type(cfg.pack_dirs) == "table" and cfg.pack_dirs or {}) do dirs[#dirs + 1] = tostring(d) end
  local out = {}
  for _, d in ipairs(dirs) do
    d = norm(d)
    if w3.fs.isdir(d) then out[#out + 1] = d end
  end
  return out
end

local function str(v, dflt)
  if v == nil or v == Y.null or v == false or v == "" then return dflt end
  return v
end

local PYS = require("conjunction.pystr")
local P = require("conjunction.py")
CP.AUDIO = {".wav", ".ogg", ".mp3", ".flac"}

-- the length of a recording (wav header; other formats: 0 until converted)
function CP.audio_seconds(path)
  local ok, v = pcall(function()
    local f = io.open(path, "rb")
    if not f then return 0.0 end
    local data = f:read(1 << 16) or ""
    f:close()
    if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return 0.0 end
    local i, rate, block, size = 12, 0, 0, 0
    while i + 8 <= #data do
      local cid, n = data:sub(i + 1, i + 4), string.unpack("<I4", data, i + 5)
      if cid == "fmt " then
        rate, block = string.unpack("<I4", data, i + 13), string.unpack("<I2", data, i + 21)
      elseif cid == "data" then
        size = n
        break
      end
      i = i + 8 + n + (n & 1)
    end
    if size == 0 then size = (w3.fs.size(path) or 0) - i - 8 end   -- (the data chunk lies beyond the part read)
    if rate ~= 0 and block ~= 0 then return require("conjunction.pynum").round(size / (rate * block), 3) end
    return 0.0
  end)
  return ok and v or 0.0
end

local function audio_file(p)
  local low = PYS.lower(p)
  for _, ext in ipairs(CP.AUDIO) do if low:sub(-#ext) == ext then return true end end
  return false
end

local function read_voices(pack)
  local f = pack.path .. "\\voices\\voices.yml"
  local out = {}
  if not w3.fs.exists(f) then return out end
  local doc = Y.read(f)
  for _, e in ipairs(P.list(P.get(type(doc) == "table" and doc or {}, "lines"))) do
    local src = pack.path .. "\\voices\\" .. P.str(P.get(e, "file", ""))
    if not P.T(P.get(e, "id")) or not w3.fs.exists(src) or w3.fs.isdir(src) or not audio_file(src) then
      pack.problems[#pack.problems + 1] = string.format("%s: voice line %s - no such recording", pack.id,
                                                        P.str(P.or_(P.get(e, "id"), P.get(e, "file"))))
    else
      local tags = {}
      for _, t in ipairs(P.list(P.get(e, "tags"))) do tags[#tags + 1] = PYS.lower(P.str(t)) end
      out[#out + 1] = {key = pack.id .. "/" .. P.str(e.id), pack = pack.id, pack_name = pack.name, id = P.str(e.id),
                       file = src, text = PYS.strip(P.str(P.get(e, "text", ""))),
                       speaker = P.str(P.get(e, "speaker", "")), tags = tags, lang = P.get(e, "lang", "en"),
                       dur = CP.audio_seconds(src)}
    end
  end
  return out
end

local CACHE = {}

-- every pack found (re-read when a pack file changed)
function CP.packs()
  local out = {}
  for _, d in ipairs(CP.pack_dirs()) do
    local names = {}
    for _, e in ipairs(w3.fs.list(d) or {}) do names[#names + 1] = e.name end
    table.sort(names)
    for _, name in ipairs(names) do
      local path = d .. "\\" .. name
      local meta = path .. "\\pack.yml"
      if w3.fs.exists(meta) and not w3.fs.isdir(meta) then
        local vf = path .. "\\voices\\voices.yml"
        local stamp = tostring(w3.fs.mtime(meta)) .. "|" .. (w3.fs.exists(vf) and tostring(w3.fs.mtime(vf)) or "")
        if not CACHE[path] or CACHE[path][1] ~= stamp then
          local ok, m = pcall(function()
            local m = Y.read(meta)
            m = type(m) == "table" and m or {}
            local id = PYS.lower(tostring(str(m.id, name)))
            local pack = {path = path, id = id, name = str(m.name, id), author = str(m.author, ""),
                          version = m.version ~= nil and m.version ~= Y.null and m.version or 1,
                          description = str(m.description, ""), problems = {}}
            pack.voices = read_voices(pack)
            return pack
          end)
          if ok then CACHE[path] = {stamp, m} else print("[packs] " .. path .. ": " .. tostring(m)) end
        end
        if CACHE[path] then out[#out + 1] = CACHE[path][2] end
      end
    end
  end
  return out
end

function CP.voice_lines()
  local out = {}
  for _, p in ipairs(CP.packs()) do for _, v in ipairs(p.voices) do out[#out + 1] = v end end
  return out
end

function CP.voice(key)
  for _, v in ipairs(CP.voice_lines()) do if v.key == key then return v end end
  return nil
end

-- every tag with how many lines have it, most used first
function CP.voice_tags()
  local count, order = {}, {}
  for _, v in ipairs(CP.voice_lines()) do
    for _, t in ipairs(v.tags) do
      if not count[t] then order[#order + 1] = t end
      count[t] = (count[t] or 0) + 1
    end
  end
  local out = {}
  for _, t in ipairs(order) do out[#out + 1] = {t, count[t]} end
  table.sort(out, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
  return out
end

function CP.search_voices(text, tags, limit)
  limit = limit or 200
  local words = PYS.split(PYS.lower(text or ""))
  local out = {}
  for _, v in ipairs(CP.voice_lines()) do
    local parts = {v.text, v.speaker, v.id, v.pack_name}
    for _, t in ipairs(v.tags) do parts[#parts + 1] = t end
    local hay = PYS.lower(table.concat(parts, " "))
    local ok = true
    for _, w in ipairs(words) do if not hay:find(w, 1, true) then ok = false break end end
    if ok then
      for _, t in ipairs(tags or {}) do
        local has = false
        for _, vt in ipairs(v.tags) do if vt == t then has = true end end
        if not has then ok = false break end
      end
    end
    if ok then out[#out + 1] = v end
    if #out >= limit then break end
  end
  return out
end

return CP
