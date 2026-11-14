-- speech.py: how long a recording is, the length radish gives a line without one (its phonemes timed from the text
-- alone), and the speech of a DLC (the build).
--   SP.seconds(path) -> seconds (0.0: not readable)   SP.text_timing(lines) -> {id = seconds}   SP.wordy(line)
--   SP.build(lines, work, content_dir, lang, log) -> the strings csv     SP.remaster(packed, wav_dir, lang)
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local N = require("conjunction.pynum")
local SP = {}
SP.RATE = 48000
SP.LEAD = 0.25            -- silence before the first sound (radish: prevents a jerked mouth opening)

-- the length of a recording (the lead-in silence included): a wav's frames by its rate; other formats 0.0 here
-- (the app decodes them with ffmpeg)
function SP.seconds(path)
  local ok, v = pcall(function()
    if not PYS.lower(path):match("%.wav$") then return 0.0 end
    local f = io.open(path, "rb")
    if not f then return 0.0 end
    local data = f:read("a")
    f:close()
    if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then return 0.0 end
    local i, fmt, pcm_n = 12, nil, nil
    while i + 8 <= #data do
      local cid, n = data:sub(i + 1, i + 4), string.unpack("<I4", data, i + 5)
      if cid == "fmt " then
        local tag, channels, rate = string.unpack("<I2I2I4", data, i + 9)
        local bits = string.unpack("<I2", data, i + 23)
        if tag == 0xFFFE and n >= 40 then tag = string.unpack("<I2", data, i + 33) end
        fmt = {tag, channels, rate, bits}
      elseif cid == "data" then
        pcm_n = math.max(0, math.min(n, #data - (i + 8)))
      end
      i = i + 8 + n + (n & 1)
    end
    if not fmt or pcm_n == nil then return 0.0 end
    local tag, channels, rate, bits = fmt[1], fmt[2], fmt[3], fmt[4]
    local samples
    if tag == 3 and bits == 32 then samples = pcm_n // 4
    elseif tag == 1 and bits == 16 then samples = pcm_n // 2
    elseif tag == 1 and bits == 8 then samples = pcm_n
    elseif tag == 1 and (bits == 24 or bits == 32) then samples = pcm_n // (bits // 8)
    else return 0.0 end
    local frames = samples
    if channels > 1 then frames = samples >= channels and ((samples - channels) // channels + 1) or 0 end
    return N.round(SP.LEAD + frames / rate, 3)
  end)
  return ok and v or 0.0
end

-- a line with words (a gesture alone is '...': silence, the mouth stays shut)
function SP.wordy(line)
  for _, c in ipairs(PYS.cps(P.str(P.get(line, "text", "")))) do
    if PYS.isalnum(utf8.char(c)) then return true end
  end
  return false
end

function SP.strings_csv(path, lines, lang)
  local out = {";meta[language=" .. (lang or "en") .. "]\n; id      |key(hex)|key(str)| text\n"}
  for _, ln in ipairs(lines) do out[#out + 1] = string.format("%d|00000000||%s\n", ln.id, P.str(ln.text)) end
  assert(w3.fs.write(path, table.concat(out)))
end

-- a program run to its end (in a coroutine: the game goes on meanwhile) -> its exit code, its lines
function SP.run(cmd, cwd)
  local p = assert(w3.proc.run(cmd, {cwd = cwd}))
  local lines = {}
  while true do
    for _, ln in ipairs(w3.proc.lines(p) or {}) do lines[#lines + 1] = ln end
    local code = w3.proc.exit(p)
    if code ~= nil then
      for _, ln in ipairs(w3.proc.lines(p) or {}) do lines[#lines + 1] = ln end
      w3.proc.close(p)
      return code, lines
    end
    if coroutine.isyieldable() then coroutine.yield() end
  end
end

-- --- the speech of a DLC (the build): audio read, at 48 kHz with the lead-in, radish's tools for phonemes, lip sync
-- and the speech file, then Wwise Opus audio and the file as v164

-- -> rate, mono samples as floats -1..1. wav (PCM 8/16/24/32 bit, float 32); other formats through ffmpeg
function SP.read_audio(path)
  local B = require("conjunction.build")
  local name = path:match("[^\\/]*$")
  if not PYS.lower(path):match("%.wav$") then
    local exe = B.which("ffmpeg")
    if not exe then error("RuntimeError: " .. name .. ": only wav files can be read without ffmpeg", 0) end
    local tmp = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_pcm_" .. require("conjunction.marks").uuid4_hex():sub(1, 8) .. ".raw"
    local code = B.call({exe, "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", tostring(SP.RATE), tmp})
    local raw = w3.fs.read(tmp) or ""
    if w3.fs.exists(tmp) then w3.fs.remove(tmp) end
    if code ~= 0 then error("CalledProcessError: ffmpeg returned " .. tostring(code), 0) end
    local out = {}
    for k = 1, #raw // 2 do out[k] = string.unpack("<i2", raw, 2 * k - 1) / 32768.0 end
    return SP.RATE, out
  end
  local data = w3.fs.read(path)
  if not data then error("OSError: " .. path, 0) end
  if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then error("RuntimeError: " .. name .. ": not a wav file", 0) end
  local i, fmt, pcm = 12, nil, nil
  while i + 8 <= #data do
    local cid, n = data:sub(i + 1, i + 4), string.unpack("<I4", data, i + 5)
    if cid == "fmt " then
      local tag, channels, rate = string.unpack("<I2I2I4", data, i + 9)
      local bits = string.unpack("<I2", data, i + 23)
      if tag == 0xFFFE and n >= 40 then tag = string.unpack("<I2", data, i + 33) end
      fmt = {tag, channels, rate, bits}
    elseif cid == "data" then
      pcm = data:sub(i + 9, i + 8 + n)
    end
    i = i + 8 + n + (n & 1)
  end
  if not fmt or pcm == nil then error("RuntimeError: " .. name .. ": no audio in the file", 0) end
  local tag, channels, rate, bits = fmt[1], fmt[2], fmt[3], fmt[4]
  local values = {}
  if tag == 3 and bits == 32 then
    for k = 1, #pcm // 4 do values[k] = string.unpack("<f", pcm, 4 * k - 3) end
  elseif tag == 1 and bits == 16 then
    for k = 1, #pcm // 2 do values[k] = string.unpack("<i2", pcm, 2 * k - 1) / 32768.0 end
  elseif tag == 1 and bits == 8 then
    for k = 1, #pcm do values[k] = (pcm:byte(k) - 128) / 128.0 end
  elseif tag == 1 and (bits == 24 or bits == 32) then
    local w = bits // 8
    local fmt_s = "<i" .. w
    local scale = (1 << (bits - 1)) + 0.0
    for k = 0, #pcm - w, w do values[#values + 1] = string.unpack(fmt_s, pcm, k + 1) / scale end
  else
    error(string.format("RuntimeError: %s: wav format %d / %d bit is not supported", name, tag, bits), 0)
  end
  if channels > 1 then                            -- mono: the mean of the channels
    local mono = {}
    for k = 1, #values - channels + 1, channels do
      local s = 0
      for j = k, k + channels - 1 do s = s + values[j] end
      mono[#mono + 1] = s / channels
    end
    values = mono
  end
  return rate, values
end

function SP.resample(values, rate, to)
  to = to or SP.RATE
  if rate == to or #values == 0 then return values end
  local n = math.floor(#values * to / rate)
  local step = rate / to
  local out, last = {}, #values
  for k = 0, n - 1 do
    local x = k * step
    local j = math.floor(x)
    local f = x - j
    out[k + 1] = values[j + 1] * (1 - f) + values[math.min(j + 2, last)] * f
  end
  return out
end

function SP.pcm16(values)
  local out, part = {}, {}
  local since = os.clock()
  for k, v in ipairs(values) do
    part[#part + 1] = string.pack("<i2", math.max(-32768, math.min(32767, N.round(v * 32767))))
    if #part == 4096 or k == #values then
      out[#out + 1] = table.concat(part)
      part = {}
      if os.clock() - since > 0.015 and coroutine.isyieldable() then   -- (in a build's job: the game's frame)
        coroutine.yield()
        since = os.clock()
      end
    end
  end
  return table.concat(out)
end

function SP.write_wav(path, values, rate)
  rate = rate or SP.RATE
  local data = SP.pcm16(values)
  assert(w3.fs.write(path, "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVE" .. "fmt " ..
                           string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, rate, rate * 2, 2, 16) .. "data" ..
                           string.pack("<I4", #data) .. data))
end

-- the game's PCM wem (the layout of radish's silence template)
function SP.write_wem(path, values, rate)
  rate = rate or SP.RATE
  local data = SP.pcm16(values)
  local fmt = string.pack("<I2I2I4I4I2I2I2I2I4", 0xFFFE, 1, rate, rate * 2, 2, 16, 6, 0, 4)   -- mono, centre
  local body = "WAVE" .. "fmt " .. string.pack("<I4", #fmt) .. fmt .. "JUNK" .. string.pack("<I4", 4) .. "\0\0\0\0" ..
               "data" .. string.pack("<I4", #data) .. data
  assert(w3.fs.write(path, "RIFF" .. string.pack("<I4", #body) .. body))
end

local function silence(n)
  local out = {}
  for k = 1, n do out[k] = 0.0 end
  return out
end

-- -> 48 kHz mono samples with the lead-in silence, seconds
function SP.prepare(source)
  local rate, values = SP.read_audio(source)
  local out = silence(math.floor(SP.LEAD * SP.RATE))
  for _, v in ipairs(SP.resample(values, rate)) do out[#out + 1] = v end
  return out, N.round(#out / SP.RATE, 3)
end

-- the game's lines a quest line speaks with its own text (ln.game: the game line's id) -> {{id, audio, seconds,
-- lipsync}} as the speech file takes them; one the game has no recording for stays out (its line is silent)
function SP.game_copies(lines, log)
  local VO = require("conjunction.voices")
  local out = {}
  for _, ln in ipairs(lines) do
    local audio, dur, lipsync = VO.game_line(ln.game)
    if audio then
      out[#out + 1] = {math.tointeger(tonumber(P.str(ln.id))), audio, dur, lipsync}
    elseif log then
      log(string.format("[speech] game line %s: no recording in the game's speech file", P.str(ln.game)))
    end
  end
  if #out > 0 and log then log(string.format("[speech] %d lines with the game's voice and their own text", #out)) end
  return out
end

-- recordings -> <content_dir>\<lang>pc.w3speech; -> the strings csv of the lines (for the DLC's texts)
function SP.build(lines, work, content_dir, lang, log)
  lang, log = lang or "en", log or print
  local B = require("conjunction.build")
  local FS = require("conjunction.fsutil")
  local radish = require("conjunction.config").load().radish
  if w3.fs.isdir(work) then FS.rmtree(work) end
  local wav_dir, wem_dir = work .. "\\speech." .. lang .. ".wav", work .. "\\speech." .. lang .. ".wem"
  B.makedirs(wav_dir)
  B.makedirs(wem_dir)
  local csv = work .. "\\speech." .. lang .. ".csv"
  SP.strings_csv(csv, lines, lang)
  local recorded, silent, copied = {}, {}, {}
  for _, ln in ipairs(lines) do
    if P.T(P.get(ln, "game")) then copied[#copied + 1] = ln
    elseif P.T(P.get(ln, "source")) then recorded[#recorded + 1] = ln else silent[#silent + 1] = ln end
  end
  local target = content_dir .. "\\" .. lang .. "pc.w3speech"
  local extra = SP.game_copies(copied, log)
  if #recorded == 0 and #silent == 0 then          -- (only the game's voices: no radish at all)
    B.makedirs(content_dir)
    assert(w3.fs.write(target, require("conjunction.w3speech").write_v164(lang, extra)))
    return csv
  end
  for _, ln in ipairs(recorded) do
    local values, dur = SP.prepare(ln.source)
    SP.write_wav(wav_dir .. "\\" .. P.str(ln.id) .. ".wav", values)
    SP.write_wem(string.format("%s\\%s[%.2f]line.wem", wem_dir, P.str(ln.id), dur), values)
  end
  local extractor = radish .. "\\w3speech-phoneme-extractor.exe"
  if #recorded > 0 then
    log(string.format("[speech] %d recordings: phonemes", #recorded))
    local rec_csv = work .. "\\recorded.csv"
    SP.strings_csv(rec_csv, recorded, lang)
    B.run({extractor, "--extract", wav_dir, "--strings-file", rec_csv}, radish, log)
  end
  if #silent > 0 then
    -- lines without a recording: silence as long as the line, the mouth moves to the text
    log(string.format("[speech] %d lines without a recording", #silent))
    local silent_csv = work .. "\\silent.csv"
    local spoken = {}
    for _, ln in ipairs(silent) do if SP.wordy(ln) then spoken[#spoken + 1] = ln end end
    if #spoken > 0 then
      SP.strings_csv(silent_csv, spoken, lang)
      B.run({extractor, "--strings-file", silent_csv, "--generate-from-text-only", "--output-dir", wav_dir}, radish, log)
    end
    for _, ln in ipairs(silent) do
      local dur = P.T(P.get(ln, "dur")) and require("conjunction.questgen").float(ln.dur) or 2.0
      SP.write_wem(string.format("%s\\%s[%.2f]line.wem", wem_dir, P.str(ln.id), dur), silence(math.floor(dur * SP.RATE)))
    end
  end
  local missing = {}
  for _, ln in ipairs(recorded) do
    if not w3.fs.exists(wav_dir .. "\\" .. P.str(ln.id) .. ".phonemes") then missing[#missing + 1] = ln end
  end
  if #missing > 0 then
    log(string.format("[speech] No phonemes found in %d recordings", #missing))
    local only = work .. "\\text_only.csv"
    SP.strings_csv(only, missing, lang)
    B.run({extractor, "--extract", wav_dir, "--strings-file", only, "--generate-from-text-only"}, radish, log)
  end
  log("[speech] lip sync")
  B.run({radish .. "\\w3speech-lipsync-creator.exe", "--create-lipsync", wav_dir .. "\\*.phonemes", "--output-dir",
         wem_dir, "--repo-dir", radish .. "\\repo.lipsync"}, radish, log, {"no match"})
  B.run({radish .. "\\w3speech.exe", "--encode-cr2w", wem_dir, "--output-dir", wem_dir}, radish, log)
  log("[speech] pack")
  local out = work .. "\\packed"
  B.makedirs(out)
  B.run({radish .. "\\w3speech.exe", "--pack-w3speech", wem_dir, "--language", lang, "--output-dir", out}, radish, log)
  local made
  for _, e in ipairs(w3.fs.list(out) or {}) do
    if not e.dir and e.name:find(".w3speech", 1, true) and not made then made = out .. "\\" .. e.name end
  end
  if not made then error("RuntimeError: radish made no speech file", 0) end
  B.makedirs(content_dir)
  if not B.which("ffmpeg") then
    log("[speech] No ffmpeg: the game cannot play these lines. Please install ffmpeg")
    assert(w3.fs.copy(made, target))
    return csv
  end
  log("[speech] audio as Wwise Opus, file as v164")
  assert(w3.fs.write(target, SP.remaster(assert(w3.fs.read(made)), wav_dir, lang, extra)))
  return csv
end

-- radish's v162 .w3speech (PCM, CR2W lip sync) -> v164 with Wwise Opus audio (the recording of a line, else its
-- silence) and the lip sync in the game's raw form
function SP.remaster(packed, wav_dir, lang, extra)
  local WSP = require("conjunction.w3speech")
  local LS = require("conjunction.lipsync")
  local WO = require("conjunction.wwise_opus")
  local _v, _l, lines = WSP.read(packed)
  local names = {}
  for _, e in ipairs(w3.fs.list(wav_dir) or {}) do names[#names + 1] = e.name end
  local out = {}
  for _, ln in ipairs(lines) do
    local sid, dur, lipsync = ln[1], ln[3], ln[4]
    -- radish's phoneme extractor renames a recording to <id>[<seconds>].wav
    local src
    if w3.fs.exists(wav_dir .. "\\" .. sid .. ".wav") then src = wav_dir .. "\\" .. sid .. ".wav" end
    if not src then
      local pre = sid .. "["
      for _, n in ipairs(names) do
        if n:sub(1, #pre) == pre and n:sub(-5) == "].wav" then src = wav_dir .. "\\" .. n break end
      end
    end
    if not src then
      src = wav_dir .. "\\" .. sid .. ".silence.wav"
      SP.write_wav(src, silence(math.floor(dur * SP.RATE)))
    end
    local audio = WO.encode_file(src)
    out[#out + 1] = {sid, audio, dur, LS.to_game(lipsync)}
  end
  for _, e in ipairs(extra or {}) do out[#out + 1] = e end
  return WSP.write_v164(lang, out)
end

-- the seconds of the last phoneme of a .phonemes file (its lines: phoneme|start ms|end ms|...)
local function phonemes_end(path)
  local stop = 0
  for line in io.lines(path) do
    local parts = {}
    for p in (line .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = PYS.strip(p) end
    if #parts > 2 and parts[2]:match("^%d+$") and parts[3]:match("^%d+$") then stop = math.max(stop, tonumber(parts[3])) end
  end
  return stop / 1000.0
end

-- {id = seconds} for lines without a recording: radish times their phonemes from the text alone; the line lasts
-- until the last phoneme and a little more
function SP.text_timing(lines, lang)
  lang = lang or "en"
  local want = {}
  for _, ln in ipairs(lines) do if SP.wordy(ln) then want[#want + 1] = ln end end
  if #want == 0 then return {} end
  local radish = require("conjunction.config").load().radish
  local tmp = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_mouth_" .. require("conjunction.marks").uuid4_hex():sub(1, 8)
  w3.fs.mkdir(tmp)
  local out = {}
  local ok, err = pcall(function()
    local csv = tmp .. "\\lines.csv"
    SP.strings_csv(csv, want, lang)
    local code, got = SP.run(string.format('"%s\\w3speech-phoneme-extractor.exe" --strings-file "%s" ' ..
                                           '--generate-from-text-only --output-dir "%s"', radish, csv, tmp), radish)
    local failed = code ~= 0
    for _, ln in ipairs(got) do
      if PYS.strip(ln) ~= "" and (ln:sub(1, 5) == "ERROR" or ln:find("Failed to add seed file", 1, true)) then
        failed = true                              -- (build.run: an ERROR line, or wcc_lite's fatal one)
      end
    end
    if failed then error("w3speech-phoneme-extractor.exe failed (exit " .. tostring(code) .. ")") end
    for _, ln in ipairs(want) do
      local f = tmp .. "\\" .. ln.id .. ".phonemes"
      if w3.fs.exists(f) then out[ln.id] = N.round(math.max(1.2, phonemes_end(f) + 0.45), 3) else out[ln.id] = 2.0 end
    end
  end)
  for _, e in ipairs(w3.fs.list(tmp) or {}) do w3.fs.remove(tmp .. "\\" .. e.name) end
  w3.fs.rmdir(tmp)
  if not ok then error(err, 0) end
  return out
end

return SP
