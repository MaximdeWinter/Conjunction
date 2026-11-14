-- The game's .w3strings files (w3strings.py): read v162 / v163 / v164, write v164.
-- Layout (WolvenKit-7's reader, v164 measured against the v163 backup):
--   "RTSW", version u32, key1 u16
--   block 1: count (bit6), per string: id ^ magic u32, offset u32, length u32 - sorted by id ^ magic
--   block 2: count (bit6), per key: hash of the key text u32, id ^ magic u32 - sorted by the hash
--   block 3: count (bit6) = the text's size, then the text
--   key2 u16
-- v162 / v163: the text is utf-16, offset and length in characters, each character XORed with a key that walks on.
-- v164: the text is utf-8, offset and length in bytes, each string ended by one 0 byte; each byte XORed with the low
-- byte of the same walking key.
--   WS.read(data, lang) -> version, lang, {id = text}, {id = key text hash}, {id ...} (the keys' order in the file)
--   WS.string_files(lang, game)   WS.read_strings(lang, log, game) -> {id = text}, {hash = id}  (assets.read_strings)
--   WS.write_v164(lang, texts, keys, hashes, hash_order) -> bytes   WS.key_hash(key text)
local WS = {}
local unpack = string.unpack

WS.LANGS = {  -- language -> {key1, key2, magic} (WolvenKit-7 W3Language.cs; the remaster's newer ones: no key)
  ar = {0, 0, 0}, br = {0, 0, 0}, esmx = {0, 0, 0}, kr = {0, 0, 0}, tr = {0, 0, 0}, cn = {0, 0, 0}, ua = {0, 0, 0},
  pl = {0x8349, 0x6237, 0x73946816}, en = {0x4397, 0x5139, 0x79321793}, de = {0x7588, 0x6138, 0x42791159},
  it = {0x4593, 0x1894, 0x12375973}, fr = {0x2386, 0x3176, 0x75921975}, cz = {0x2498, 0x7354, 0x21793217},
  es = {0x1879, 0x6651, 0x42387566}, zh = {0x1863, 0x2176, 0x16875467}, ru = {0x6348, 0x1486, 0x42386347},
  hu = {0x4237, 0x8932, 0x67823218}, jp = {0x5483, 0x4893, 0x59825646},
}
-- (the order of LANGS in the app: lang_of takes the first that fits - the keyless ones all fit 0, 0: "ar")
local ORDER = {"ar", "br", "esmx", "kr", "tr", "cn", "ua", "pl", "en", "de", "it", "fr", "cz", "es", "zh", "ru", "hu",
               "jp"}

-- i 1-based -> value, the next i
local function bit6(d, i)
  local result, shift, k = 0, 0, 1
  while true do
    local b = d:byte(i)
    i = i + 1
    local s, mask = 6, 255
    if b > 127 then mask, s = 127, 7
    elseif b > 63 and k == 1 then mask = 63 end
    result = result | ((b & mask) << shift)
    shift = shift + s
    k = k + 1
    if b < 64 or (k >= 3 and b < 128) then return result, i end
  end
end

function WS.lang_of(key1, key2)
  for _, lang in ipairs(ORDER) do
    local k = WS.LANGS[lang]
    if k[1] == key1 and k[2] == key2 then return lang end
  end
  return nil
end

-- bytes.decode("utf-8", "replace"): a broken sequence becomes U+FFFD as Python's decoder makes it (the longest valid
-- start of a sequence is one error)
local function decode_replace(s)
  if utf8.len(s) then return s end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local need, lo, hi = 0, 0x80, 0xBF
    if c < 0x80 then need = 0
    elseif c >= 0xC2 and c <= 0xDF then need = 1
    elseif c == 0xE0 then need, lo = 2, 0xA0
    elseif c >= 0xE1 and c <= 0xEC or c == 0xEE or c == 0xEF then need = 2
    elseif c == 0xED then need, hi = 2, 0x9F
    elseif c == 0xF0 then need, lo = 3, 0x90
    elseif c >= 0xF1 and c <= 0xF3 then need = 3
    elseif c == 0xF4 then need, hi = 3, 0x8F
    else need = -1 end
    if need < 0 then
      out[#out + 1] = "\u{FFFD}"
      i = i + 1
    elseif need == 0 then
      out[#out + 1] = string.char(c)
      i = i + 1
    else
      local j, ok = i + 1, true
      for k = 1, need do
        local b = s:byte(j)
        local l, h = 0x80, 0xBF
        if k == 1 then l, h = lo, hi end
        if not b or b < l or b > h then ok = false break end
        j = j + 1
      end
      if ok then out[#out + 1] = s:sub(i, j - 1) else out[#out + 1] = "\u{FFFD}" end
      i = j
    end
  end
  return table.concat(out)
end

WS.decode_replace = decode_replace

local function utf16_char(cp, out)
  out[#out + 1] = utf8.char(cp)
end

function WS.read(data, lang)
  if data:sub(1, 4) ~= "RTSW" then error("not a .w3strings file") end
  local version = unpack("<I4", data, 5)
  local key1, key2 = unpack("<I2", data, 9), unpack("<I2", data, #data - 1)
  lang = lang or WS.lang_of(key1, key2)
  local magic = WS.LANGS[lang] and WS.LANGS[lang][3] or 0
  local n1, i = bit6(data, 11)
  local entries = {}
  for k = 0, n1 - 1 do entries[k + 1] = {unpack("<I4I4I4", data, i + 12 * k)} end
  i = i + 12 * n1
  local n2
  n2, i = bit6(data, i)
  local keys, order = {}, {}
  for k = 0, n2 - 1 do
    local h, sid = unpack("<I4I4", data, i + 8 * k)
    if keys[sid ~ magic] == nil then order[#order + 1] = sid ~ magic end
    keys[sid ~ magic] = h
  end
  i = i + 8 * n2
  local _, start = bit6(data, i)
  local texts = {}
  local sk0 = (magic >> 8) & 0xFFFF
  for _, e in ipairs(entries) do
    local hid, off, ln = e[1], e[2], e[3]
    local sk = sk0
    if version >= 164 then
      local p = start + off
      local out = {}
      for k = 1, math.min(ln, #data - p + 1) do       -- (a slice past the end is shorter: zip stops)
        local key = ((ln + 1) * sk) & 0xFFFF
        out[k] = data:byte(p + k - 1) ~ (key & 0xFF)
        sk = ((sk << 1) | (sk >> 15)) & 0xFFFF
      end
      local parts = {}
      for a = 1, #out, 4096 do parts[#parts + 1] = string.char(table.unpack(out, a, math.min(#out, a + 4095))) end
      texts[hid ~ magic] = decode_replace(table.concat(parts))
    else
      local p = start + off * 2
      local chars = {}
      for _ = 1, ln do
        local key = ((ln + 1) * sk) & 0xFFFF
        local cp = (data:byte(p) ~ (key & 0xFF)) | ((data:byte(p + 1) ~ (key >> 8)) << 8)
        -- (Python's chr of a lone surrogate; written as utf-8 here: a surrogate half as its three bytes)
        utf16_char(cp, chars)
        p = p + 2
        sk = ((sk << 1) | (sk >> 15)) & 0xFFFF
      end
      texts[hid ~ magic] = table.concat(chars)
    end
  end
  return version, lang, texts, keys, order
end

-- --- writing v164 (the remaster's; radish writes v162, which the remaster no longer loads)
WS.bit6 = bit6
-- the inverse of bit6: 6 bits in the first byte (0x40: more follows), then 7 bits a byte (0x80: more)
function WS.bit6_write(v)
  local first = v & 0x3F
  v = v >> 6
  if v ~= 0 then first = first | 0x40 end
  local out = {string.char(first)}
  while v ~= 0 do
    local b = v & 0x7F
    v = v >> 7
    if v ~= 0 then b = b | 0x80 end
    out[#out + 1] = string.char(b)
  end
  return table.concat(out)
end

-- a string key's hash as the game looks it up: of the key in lower case
function WS.key_hash(text)
  local h = 0
  for _, c in utf8.codes(require("conjunction.pystr").lower(text)) do h = (h * 31 + c) & 0xFFFFFFFF end
  return h
end

-- {id = text} (+ {id = key text} - the strings found by name - or {id = its hash} as read, hash_order the order the
-- hashes came in: WS.read's fifth) -> a v164 file
function WS.write_v164(lang, texts, keys, hashes, hash_order)
  lang = lang:lower()
  local L = WS.LANGS[lang]
  if not L then error("KeyError: '" .. lang .. "'", 0) end
  local key1, key2, magic = L[1], L[2], L[3]
  local order = {}
  for sid in pairs(texts) do order[#order + 1] = sid end
  table.sort(order, function(a, b) return (a ~ magic) < (b ~ magic) end)
  local blob, blen, rows = {}, 0, {}
  for _, sid in ipairs(order) do
    local raw = texts[sid]
    rows[#rows + 1] = string.pack("<I4I4I4", sid ~ magic, blen, #raw)
    local sk = (magic >> 8) & 0xFFFF
    local out = {}
    for k = 1, #raw do
      local key = ((#raw + 1) * sk) & 0xFFFF
      out[k] = raw:byte(k) ~ (key & 0xFF)
      sk = ((sk << 1) | (sk >> 15)) & 0xFFFF
    end
    for a = 1, #out, 4096 do blob[#blob + 1] = string.char(table.unpack(out, a, math.min(#out, a + 4095))) end
    blob[#blob + 1] = "\0"
    blen = blen + #raw + 1
  end
  local head = {"RTSW", string.pack("<I4I2", 164, key1), WS.bit6_write(#rows), table.concat(rows)}
  -- dict(hashes) updated by the keys' hashes: the order as Python's dict keeps it
  local hashed, horder = {}, {}
  local function put(sid, h)
    if hashed[sid] == nil then horder[#horder + 1] = sid end
    hashed[sid] = h
  end
  if hashes then
    if hash_order then
      for _, sid in ipairs(hash_order) do if hashes[sid] ~= nil then put(sid, hashes[sid]) end end
    else
      local ids = {}
      for sid in pairs(hashes) do ids[#ids + 1] = sid end
      table.sort(ids)
      for _, sid in ipairs(ids) do put(sid, hashes[sid]) end
    end
  end
  if keys then
    local ids = {}
    for sid, k in pairs(keys) do if k ~= nil and k ~= "" then ids[#ids + 1] = sid end end
    table.sort(ids)
    for _, sid in ipairs(ids) do put(sid, WS.key_hash(keys[sid])) end
  end
  local pairs_ = {}
  for i, sid in ipairs(horder) do pairs_[i] = {hashed[sid], sid ~ magic, i} end
  table.sort(pairs_, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[3] < b[3]
  end)
  local hrows = {}
  for i, p in ipairs(pairs_) do hrows[i] = string.pack("<I4I4", p[1], p[2]) end
  local text = table.concat(blob)
  return table.concat(head) .. WS.bit6_write(#hrows) .. table.concat(hrows) .. WS.bit6_write(#text) .. text ..
         string.pack("<I2", key2)
end

-- every strings file of a language: content\content*\<lang>.w3strings, then dlc\*\content\<lang>.w3strings
function WS.string_files(lang, game)
  game = game or require("conjunction.config").load().game
  local function sorted_glob(dir, sub)
    local out = {}
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local p = dir .. "\\" .. e.name .. sub
      if e.dir ~= false and w3.fs.exists(p) then out[#out + 1] = p end
    end
    table.sort(out)
    return out
  end
  local out = {}
  for _, p in ipairs(sorted_glob(game .. "\\content", "\\" .. lang .. ".w3strings")) do
    if p:match("\\content\\content[^\\]*\\[^\\]+$") then out[#out + 1] = p end
  end
  for _, p in ipairs(sorted_glob(game .. "\\dlc", "\\content\\" .. lang .. ".w3strings")) do out[#out + 1] = p end
  return out
end

function WS.read_strings(lang, log, game)
  log = log or print
  local by_id, by_key = {}, {}
  local n = 0
  for _, src in ipairs(WS.string_files(lang, game)) do
    local ok, err = pcall(function()
      local _, _, texts, keys, order = WS.read(assert(w3.fs.read(src)), lang:lower())
      for id, t in pairs(texts) do
        if by_id[id] == nil then n = n + 1 end
        by_id[id] = t
      end
      for _, sid in ipairs(order) do by_key[keys[sid]] = sid end
    end)
    if not ok then log(string.format("[assets] strings: %s unreadable (%s)", src, tostring(err))) end
  end
  log(string.format("[assets] strings %s: %d", lang, n))
  return by_id, by_key
end

return WS
