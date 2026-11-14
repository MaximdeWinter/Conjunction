-- Wwise Opus .wem (codec 0x3041) without Wwise (wwise_opus.py) - what the remaster's voices are. RIFF/WAVE with
--   fmt  (0x24): codec 0x3041, channels, 48000, bytes a second, 0, 0, extra size 0x12, samples a frame (960),
--                channel layout (mono 0x00004101), total samples, frame count, pre-skip, version 1, mapping 0
--   hash (0x10): md5 of the data      seek: u16 size of every Opus packet      data: the raw Opus packets
-- The packets come from ffmpeg's libopus (Ogg) - its header packets dropped, its pre-skip kept.
--   WO.encode_file(src, bitrate) -> wem bytes, seconds  (in a coroutine: ffmpeg runs meanwhile)   WO.wem(frames, samples, preskip)
local WO = {}
WO.RATE, WO.FRAME = 48000, 960

-- the packets of an Ogg stream (segments joined across pages)
function WO.ogg_packets(data)
  local packets, cur, i = {}, {}, 0
  while i + 27 <= #data and data:sub(i + 1, i + 4) == "OggS" do
    local nseg = data:byte(i + 27)
    local lacing = data:sub(i + 28, i + 27 + nseg)
    local body = i + 27 + nseg
    for k = 1, #lacing do
      local lace = lacing:byte(k)
      cur[#cur + 1] = data:sub(body + 1, body + lace)
      body = body + lace
      if lace < 255 then
        packets[#packets + 1] = table.concat(cur)
        cur = {}
      end
    end
    i = body
  end
  return packets
end

-- Wwise Opus RIFF around raw Opus packets
function WO.wem(frames, samples, preskip)
  local data = table.concat(frames)
  local seconds = math.max(samples / WO.RATE, 1e-3)
  local fmt = string.pack("<I2I2I4I4I2I2I2I2I4I4I4I2BB", 0x3041, 1, WO.RATE, math.floor(#data / seconds), 0, 0, 0x12,
                          WO.FRAME, 0x00004101, samples, #frames, preskip, 1, 0)
  local sizes = {}
  for k, f in ipairs(frames) do sizes[k] = string.pack("<I2", #f) end
  local md5 = require("conjunction.hashlib").md5_bytes(data)
  local chunks = {}
  for _, c in ipairs({{"fmt ", fmt}, {"hash", md5}, {"seek", table.concat(sizes)}, {"data", data}}) do
    chunks[#chunks + 1] = c[1] .. string.pack("<I4", #c[2]) .. c[2] .. ((#c[2] & 1) == 1 and "\0" or "")
  end
  local body = table.concat(chunks)
  return "RIFF" .. string.pack("<I4", 4 + #body) .. "WAVE" .. body
end

-- an audio file (wav, ogg, mp3 ... anything ffmpeg reads) -> wem bytes, seconds
function WO.encode_file(src, bitrate)
  bitrate = bitrate or "64k"
  local B = require("conjunction.build")
  local tmp = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_opus_" .. require("conjunction.marks").uuid4_hex():sub(1, 8)
  w3.fs.mkdir(tmp)
  local out = tmp .. "\\line.opus"
  local ok, ogg = pcall(function()
    local code = B.call({B.which("ffmpeg") or "ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar",
                         tostring(WO.RATE), "-c:a", "libopus", "-b:a", bitrate, "-frame_duration", "20", "-vbr", "on", out})
    if code ~= 0 then error("CalledProcessError: ffmpeg returned " .. tostring(code), 0) end
    return assert(w3.fs.read(out))
  end)
  require("conjunction.fsutil").rmtree(tmp)
  if not ok then error(ogg, 0) end
  local packets = WO.ogg_packets(ogg)
  local head = packets[1] or ""
  if head:sub(1, 8) ~= "OpusHead" then error(require("conjunction.questgen").ValueError("ffmpeg gave no Opus stream"), 0) end
  local frames = {}
  for k = 3, #packets do frames[#frames + 1] = packets[k] end
  local preskip = string.unpack("<I2", head, 11)
  -- the last page's granule position: every sample including the pre-skip
  local last
  local i = 1
  while true do
    local a = ogg:find("OggS", i, true)
    if not a then break end
    last, i = a, a + 1
  end
  local granule = string.unpack("<i8", ogg, last + 6)
  local samples = math.max(0, granule - preskip)
  return WO.wem(frames, samples, preskip), samples / WO.RATE
end

return WO
