-- The game's voiced lines (voices.py): every line of every scene (.w2scene) with who speaks it, how long and its text -
-- so a dialogue line of a quest can reuse one (radish: a line "0001011351|text" plays the game's own voice and lip
-- sync).
--   voices.sqlite  lines(id, speaker, dur, scene, text)   built once from the game (VO.build), then searched
--   VO.ready()   VO.open() -> v   v:search(text, speaker, others, limit)   v:line(sid)   VO.speaker_label(s)
--   VO.length(sid, approved, text)   VO.listen(sid) -> a job: VO.listened(job) -> the wav, false, or nil while it runs
local CFG = require("conjunction.config")
local DB = require("conjunction.db")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local N = require("conjunction.pynum")
local Y = require("conjunction.yaml")
local VO = {}
VO.__index = VO

local function dirname(p) return (p:gsub("[\\/][^\\/]*$", "")) end
function VO.db_path() return VO.DB or (dirname(CFG.PATH) .. "\\voices.sqlite") end
VO.VERSION = 1
VO.GERALT = "GERALT"
-- words that say nothing about a line (a search by a whole sentence ranks by the others)
VO.COMMON = {}
for w in ([[the and you your for are was were that this with have has had not but they them their there what who how
why when where will would could should can just all out from into about his her him she he its it's i'm i'll don't
won't can't our ours we us me my mine yes]]):gmatch("%S+") do VO.COMMON[w] = true end

-- the first CR2W file in the data that reads (assets._cr2w_parts(...)[0])
local function first_part(CR, data)
  local i = 1
  while true do
    i = data:find("CR2W", i, true)
    if not i then return nil end
    local ok, f = pcall(CR.parse, data:sub(i))
    if ok then return f end
    i = i + 4
  end
end

-- read every scene of the game: its lines (voice tag, approved duration, string id) joined with the texts.
-- step(n, total): called after each scene (a coroutine yields there, so the game goes on meanwhile)
function VO.build(log, step)
  log = log or print
  local CR = require("conjunction.cr2w")
  local WS = require("conjunction.w3strings")
  local depot = require("conjunction.depot").open(CFG.load().game)
  local texts = WS.read_strings("en", log)
  local files = depot:glob("", ".w2scene")
  local rows, order = {}, {}
  local unpack = string.unpack
  for n, p in ipairs(files) do
    if (n - 1) % 1000 == 0 then log(string.format("[voices] scenes %d / %d", n - 1, #files)) end
    local ok, f = pcall(function() return first_part(CR, depot:read(p)) end)
    if ok and f then
      for _, e in ipairs(f.exports) do
        if e[1] == "CStorySceneLine" then
          local chunk, line = e[5], {}
          for _, pr in ipairs(f:props(chunk)) do
            local name, tp, off = pr[1], pr[2], pr[3]
            if name == "voicetag" and tp == "CName" then
              line.speaker = f.names[unpack("<I2", chunk, off + 1) + 1]
            elseif name == "dialogLine" and tp == "LocalizedString" then
              line.id = unpack("<I4", chunk, off + 1)
            elseif name == "approvedDuration" and tp == "Float" then
              line.dur = unpack("<f", chunk, off + 1)
            end
          end
          local sid = line.id
          local text = PYS.strip(texts[sid] or "")
          if sid and sid ~= 0 and text ~= "" and line.speaker and line.speaker ~= "" and not rows[sid] then
            rows[sid] = {sid, PYS.upper(line.speaker), N.round(line.dur or 0.0, 3), p, text}
            order[#order + 1] = sid
          end
        end
      end
    end
    if step then step(n, #files) end
  end
  local path = VO.db_path()
  local tmp = path .. ".new"
  if w3.fs.exists(tmp) then w3.fs.remove(tmp) end
  local db = DB.open(tmp, "write")
  db:exec("create table lines (id integer primary key, speaker text, dur real, scene text, text text)")
  db:exec("create table meta (key text primary key, value text)")
  db:exec("begin")
  for _, sid in ipairs(order) do
    local r = rows[sid]
    db:exec("insert into lines values (?, ?, ?, ?, ?)", r[1], r[2], r[3], r[4], r[5])
  end
  db:exec("create index lines_speaker on lines (speaker)")
  db:exec("insert into meta values ('version', ?)", tostring(VO.VERSION))
  db:exec("commit")
  db:close()
  if w3.fs.exists(path) then w3.fs.remove(path) end
  w3.fs.rename(tmp, path)
  log(string.format("[voices] %d voiced lines", #order))
  return #order
end

function VO.ready()
  if not w3.fs.exists(VO.db_path()) then return false end
  local ok, v = pcall(function()
    local db = DB.open(VO.db_path())
    local r = db:one("select value from meta where key='version'")
    db:close()
    return r
  end)
  return ok and v ~= nil and tonumber(v[1]) == VO.VERSION
end

-- searching the voiced lines (read into memory: a rebuild can replace the file meanwhile)
function VO.open()
  return setmetatable({db = DB.open(VO.db_path(), true)}, VO)
end

local function row(r) return {id = r.id, speaker = r.speaker, dur = r.dur, scene = r.scene, text = r.text} end

-- lines with all the words first (short lines first: "hm" finds "Hm." before a speech that contains it), then lines
-- with most of them (a whole sentence of one's own still finds lines close to it). speaker: only that voicetag's
-- lines (the player: GERALT, CIRILLA); others: everybody but the playable characters; neither: all
function VO:search(text, speaker, others, limit)
  limit = limit or 40
  local cleaned = {}
  for _, c in ipairs(PYS.cps(PYS.lower(text or ""))) do
    local ch = utf8.char(c)
    cleaned[#cleaned + 1] = (PYS.isalnum(ch) or ch == "'") and ch or " "
  end
  local words = PYS.split(table.concat(cleaned))
  local who, who_args = "", {}
  if P.T(speaker) then
    who, who_args = " and speaker = ?", {speaker}
  elseif others then
    local D = require("conjunction.dialogue")
    local tags = {}
    for _, k in ipairs(Y.keys(D.PLAYERS)) do tags[#tags + 1] = D.PLAYERS[k].voicetag end
    who, who_args = " and speaker not in (" .. string.rep("?", #tags, ",") .. ")", tags
  end
  local conds = {}
  for _ = 1, #words do conds[#conds + 1] = "lower(text) like ?" end
  if #conds == 0 then conds = {"1"} end
  local sql = "select * from lines where " .. table.concat(conds, " and ") .. who .. " order by length(text), id limit ?"
  local args = {}
  for _, w in ipairs(words) do args[#args + 1] = "%" .. w .. "%" end
  for _, a in ipairs(who_args) do args[#args + 1] = a end
  args[#args + 1] = limit
  local out = {}
  for _, r in ipairs((self.db:rows(sql, table.unpack(args)))) do out[#out + 1] = row(r) end
  -- the words that say something, longest first (at most 8)
  local seen_w, keys = {}, {}
  for _, w in ipairs(words) do
    if PYS.len(w) > 2 and not VO.COMMON[w] and not seen_w[w] then
      seen_w[w] = true
      keys[#keys + 1] = w
    end
  end
  table.sort(keys, function(a, b)
    if PYS.len(a) ~= PYS.len(b) then return PYS.len(a) > PYS.len(b) end
    return a < b                                -- (the app's ties come in a set's order)
  end)
  while #keys > 8 do table.remove(keys) end
  if #out < limit and #keys > 1 then
    local seen = {}
    for _, r in ipairs(out) do seen[r.id] = true end
    local ors = {}
    for _ = 1, #keys do ors[#ors + 1] = "lower(text) like ?" end
    local sql2 = "select * from lines where (" .. table.concat(ors, " or ") .. ")" .. who
    local args2 = {}
    for _, w in ipairs(keys) do args2[#args2 + 1] = "%" .. w .. "%" end
    for _, a in ipairs(who_args) do args2[#args2 + 1] = a end
    local scored = {}
    for _, r in ipairs((self.db:rows(sql2, table.unpack(args2)))) do
      if not seen[r.id] then
        local low = PYS.lower(r.text)
        local hits = 0
        for _, w in ipairs(keys) do if low:find(w, 1, true) then hits = hits + 1 end end
        if hits > 1 or #keys <= 2 then scored[#scored + 1] = {-hits, PYS.len(low), row(r), #scored} end
      end
    end
    table.sort(scored, function(a, b)            -- (stable: the database's order among equals)
      if a[1] ~= b[1] then return a[1] < b[1] end
      if a[2] ~= b[2] then return a[2] < b[2] end
      return a[4] < b[4]
    end)
    for k = 1, math.min(#scored, limit - #out) do out[#out + 1] = scored[k][3] end
  end
  return out
end

-- the voices that fit a person first: `like` is its template and name ("novigrad_old_woman_poor" - NOVIGRAD OLD WOMAN 01
-- before VILLAGER WOMAN 03 before the others); a man's voice for a woman and the other way round last
VO.WOMAN, VO.MAN = {}, {}
for w in ([[woman women female girl lady wife mother witch sorceress maid prostitute bride bridesmaids countess
priestess townswoman noblewoman waitress aunt grandma hag succubus siren diva marquise prophetess daughter sister
queen princess crone granny]]):gmatch("%S+") do VO.WOMAN[w] = true end
for w in ([[man men male boy lord husband father son brother king prince nobleman townsman fisherman dockworker
sailor knight squire groom grandpa uncle eunuch butler chamberlain count pimp lumberjack blacksmith armourer armorer]]):gmatch("%S+") do
  VO.MAN[w] = true
end
local function words_of(s)
  local out = {}
  for w in PYS.lower(s or ""):gmatch("%a+") do if #w > 2 then out[w] = true end end
  return out
end
local function sex_of(words)
  for w in pairs(words) do if VO.WOMAN[w] then return "w" end end
  for w in pairs(words) do if VO.MAN[w] then return "m" end end
  return nil
end
function VO.fit(rows, like)
  local want = words_of(like)
  local sex = sex_of(want)
  if not sex and next(want) == nil then return rows end
  local scored = {}
  for k, r in ipairs(rows) do
    local has = words_of(r.speaker)
    local s = 0
    for w in pairs(has) do if want[w] then s = s + 1 end end
    local their = sex_of(has)
    if sex and their == sex then s = s + 2 elseif sex and their then s = -1 end
    scored[k] = {s, k, r}
  end
  table.sort(scored, function(a, b) if a[1] ~= b[1] then return a[1] > b[1] end return a[2] < b[2] end)
  local out = {}
  for k, x in ipairs(scored) do out[k] = x[3] end
  return out
end

function VO:line(sid)
  local r = self.db:one("select * from lines where id = ?", math.tointeger(tonumber(sid)))
  return r and row(r) or nil
end

-- 'REDANIAN TOWNSMAN 02' -> 'Redanian townsman 02'
function VO.speaker_label(speaker)
  if not P.T(speaker) then return "" end
  local cps = PYS.cps(speaker)
  return PYS.upper(PYS.from_cps(cps, 1, 1)) .. PYS.lower(PYS.from_cps(cps, 2))
end

-- --- listening: the game's speech file (<lang>pc.w3speech) holds every line's audio (Wwise; remaster 5.0: Opus)
-- Layout: "CPSW", version u32, key u16, count (bit6 varint), then per line 40 bytes: id ^ ID_KEY u32, 0 u32, audio
-- offset u64, audio size u64, lip sync offset u64, lip sync size u64. An audio blob is its wem's length (u32) and the
-- wem.
VO.ID_KEY = 0x79321793
local INDEX = {}

local function bit6(f)
  local b = f:read(1):byte()
  local r = b & 0x3F
  if b & 0x40 ~= 0 then
    local s = 6
    while true do
      b = f:read(1):byte()
      r = r | ((b & 0x7F) << s)
      s = s + 7
      if b & 0x80 == 0 then break end
    end
  end
  return r
end

function VO.speech_file(lang)
  return CFG.load().game .. "\\content\\content0\\" .. (lang or "en") .. "pc.w3speech"
end

-- {string id = {audio offset, audio size}} of a speech file (read once)
function VO.speech_index(path)
  path = path or VO.speech_file()
  if not INDEX[path] then
    local f = io.open(path, "rb")
    if not f then error(path .. ": cannot be read") end
    if f:read(4) ~= "CPSW" then f:close() error(path .. ": not a speech file") end
    f:read(6)
    local n = bit6(f)
    local raw = f:read(40 * n)
    f:close()
    local out = {}
    for k = 0, n - 1 do
      local sid, _z, off, size, loff, lsize = string.unpack("<I4I4I8I8I8I8", raw, 40 * k + 1)
      out[sid ~ VO.ID_KEY] = {off, size, loff, lsize}
    end
    INDEX[path] = out
  end
  return INDEX[path]
end

-- the length of a game line's recording in seconds, from its Wwise Opus header (fmt: samples at +24, 48 kHz) - the
-- scenes' approved length is 0 for a third of the lines. nil if it is not there or not Opus
function VO.duration(sid, path)
  local ok, idx = pcall(VO.speech_index, path)
  if not ok then return nil end
  local e = idx[math.tointeger(tonumber(sid)) or -1]
  if not e then return nil end
  local f = io.open(path or VO.speech_file(), "rb")
  if not f then return nil end
  f:seek("set", e[1])
  local head = f:read(math.min(e[2], 256)) or ""
  f:close()
  local k = head:find("fmt ", 1, true)
  if not k or #head < k - 1 + 8 + 32 then return nil end
  local codec, _ch, rate = string.unpack("<I2I2I4", head, k + 8)
  if codec ~= 0x3041 or rate == 0 then return nil end
  return string.unpack("<I4", head, k + 8 + 24) / rate
end

-- a game line as the quest's own speech file takes it: its audio (Wwise Opus), seconds, mouth movement (the game's
-- raw form) - a line with the game's voice and the creator's text gets an id of its own (13.11.: the subtitle was
-- the game's text, the voice and the text of a line share its id) -> audio, seconds, lipsync | nil
function VO.game_line(sid, path)
  local ok, idx = pcall(VO.speech_index, path)
  local e = ok and idx[math.tointeger(tonumber(sid)) or -1] or nil
  if not e or not e[3] then return nil end
  local f = io.open(path or VO.speech_file(), "rb")
  if not f then return nil end
  f:seek("set", e[1])
  local blob = f:read(e[2]) or ""
  f:seek("set", e[3])
  local lipsync = f:read(e[4]) or ""
  f:close()
  local n = string.unpack("<I4", blob)
  if #blob < 4 + n + 4 then return nil end
  return blob:sub(5, 4 + n), string.unpack("<f", blob, 5 + n), lipsync
end

-- how long a game line lasts: its scene's approved length, else its recording's, else from its text
function VO.length(sid, approved, text)
  if approved and (tonumber(approved) or 0) > 0 then return tonumber(approved) + 0.0 end
  return VO.duration(sid) or math.max(1.5, 0.07 * PYS.len(text or ""))
end

-- vgmstream-cli.exe: the config's, a vgmstream folder in the mod's, C:\Apps\vgmstream, the PATH (it is not in the
-- release: two of its DLLs were flagged on VirusTotal, 14.11.)
function VO.vgmstream()
  local exe = CFG.load().vgmstream
  if P.T(exe) and w3.fs.exists(exe) then return exe end
  for _, e in ipairs({require("conjunction.paths").MOD_ROOT .. "\\vgmstream\\vgmstream-cli.exe",
                      "C:\\Apps\\vgmstream\\vgmstream-cli.exe"}) do
    if w3.fs.exists(e) then return e end
  end
  for dir in (os.getenv("PATH") or ""):gmatch("[^;]+") do      -- (shutil.which)
    local p = dir:gsub("[\\/]$", "") .. "\\vgmstream-cli.exe"
    if w3.fs.exists(p) then return p end
  end
  return nil
end

function VO.cache_dir()
  local d = dirname(CFG.PATH) .. "\\voice_cache"
  if not w3.fs.isdir(d) then w3.fs.mkdir(d) end
  return d
end

-- a wav of the game's line sid to play (made once, kept in the cache): a job - the wav at once when it is there,
-- else vgmstream decodes it (Wwise audio) without a console window; nil if the game has no audio for it
function VO.listen(sid, path)
  sid = math.tointeger(tonumber(sid))
  local out = VO.cache_dir() .. "\\" .. sid .. ".wav"
  if w3.fs.exists(out) then return {out = out, done = true} end
  local ok, idx = pcall(VO.speech_index, path)
  local entry = ok and idx[sid] or nil
  local exe = VO.vgmstream()
  if not entry or not exe then return nil end
  local f = io.open(path or VO.speech_file(), "rb")
  if not f then return nil end
  f:seek("set", entry[1])
  local blob = f:read(entry[2]) or ""
  f:close()
  local n = string.unpack("<I4", blob)
  local wem = out:sub(1, -5) .. ".wem"
  w3.fs.write(wem, blob:sub(5, 4 + n))
  local proc = w3.proc.run(string.format('"%s" -o "%s" "%s"', exe, out, wem))
  if not proc then
    w3.fs.remove(wem)
    return nil
  end
  return {out = out, wem = wem, proc = proc}
end

-- -> the wav, false (it failed), nil (still decoding)
function VO.listened(job)
  if job.done then return w3.fs.exists(job.out) and job.out or false end
  if w3.proc.exit(job.proc) == nil then
    w3.proc.lines(job.proc)
    return nil
  end
  w3.proc.close(job.proc)
  if w3.fs.exists(job.wem) then w3.fs.remove(job.wem) end
  job.done = true
  return w3.fs.exists(job.out) and job.out or false
end

return VO
