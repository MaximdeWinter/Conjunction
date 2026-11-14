-- The game's .w3speech files (w3speech.py): spoken lines (audio + mouth movement), read v162 / v163 / v164, write
-- v164. "CPSW", version u32, key1 u16, count (bit6); per line: id ^ magic u32, id_high u32, audio offset u64 (at the
-- audio's size field), audio size + 12 u64, lipsync offset u64, lipsync size u64; key2 u16; per line: audio size u32,
-- audio (a wem), duration f32, a u32 (v162 / v163: 4, v164: 1), lipsync.
--   WSP.read(data) -> version, lang, {{id, audio, duration, lipsync}}     WSP.write_v164(lang, lines, lipsync)
local WS = require("conjunction.w3strings")
local WSP = {}

local ORDER = {"ar", "br", "esmx", "kr", "tr", "cn", "ua", "pl", "en", "de", "it", "fr", "cz", "es", "zh", "ru", "hu",
               "jp"}

function WSP.read(data)
  if data:sub(1, 4) ~= "CPSW" then error(require("conjunction.questgen").ValueError("not a .w3speech file"), 0) end
  local version = string.unpack("<I4", data, 5)
  local key1 = string.unpack("<I2", data, 9)
  local count, i = WS.bit6(data, 11)
  local rows = {}
  for k = 0, count - 1 do rows[k + 1] = {string.unpack("<I4I4I8I8I8I8", data, i + 40 * k)} end
  local key2 = string.unpack("<I2", data, i + 40 * count)
  local lang = "en"
  for _, lg in ipairs(ORDER) do
    local L = WS.LANGS[lg]
    if L[1] == key1 and L[2] == key2 then lang = lg break end
  end
  local magic = WS.LANGS[lang][3]
  local out = {}
  for k, r in ipairs(rows) do
    local lid, woff, wsz, coff, csz = r[1], r[3], r[4], r[5], r[6]
    local audio = data:sub(woff + 5, woff + 4 + wsz - 12)
    local duration = string.unpack("<f", data, woff + 4 + wsz - 12 + 1)
    out[k] = {lid ~ magic, audio, duration, data:sub(coff + 1, coff + csz)}
  end
  return version, lang, out
end

-- {{id, audio, duration, lipsync}} -> a v164 file (lipsync false: no mouth movement - an empty lipsync); the lines
-- sorted by their stored (keyed) id, as the game looks them up by binary search
function WSP.write_v164(lang, lines, lipsync)
  local L = WS.LANGS[lang]
  local key1, key2, magic = L[1], L[2], L[3]
  local sorted = {}
  for k, ln in ipairs(lines) do sorted[k] = {ln, k} end
  table.sort(sorted, function(a, b)
    local x, y = a[1][1] ~ magic, b[1][1] ~ magic
    if x ~= y then return x < y end
    return a[2] < b[2]
  end)
  local head = "CPSW" .. string.pack("<I4I2", 164, key1) .. WS.bit6_write(#sorted)
  local pos = #head + 40 * #sorted + 2
  local rows, body = {}, {}
  for _, s in ipairs(sorted) do
    local sid, audio, duration, lips = s[1][1], s[1][2], s[1][3], s[1][4]
    if lipsync == false then lips = "" end
    local woff = pos
    local chunk = string.pack("<I4", #audio) .. audio .. string.pack("<fI4", duration, 1)
    local coff = pos + #chunk
    rows[#rows + 1] = string.pack("<I4I4I8I8I8I8", sid ~ magic, 0, woff, #audio + 12, coff, #lips)
    body[#body + 1] = chunk .. lips
    pos = pos + #chunk + #lips
  end
  return head .. table.concat(rows) .. string.pack("<I2", key2) .. table.concat(body)
end

return WSP
