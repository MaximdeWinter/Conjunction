-- metadata.store, the index beside a DLC's bundles (metastore.py; the format after w3edit, version 7 of the remaster):
--   header: '\x03VTM', u32 version 7, u32 the largest stored size, u32 the largest size
--   the string table (vlq length + bytes; offset 0 = the empty string), then seven arrays (vlq count + records):
--   file_infos (32 bytes), entry_infos (24), bundle_infos (24), buffers (u32 each), dir_init_infos (8),
--   file_init_infos (12), hashes (16: i64 hash, i64 file)
--   MS.read(data) -> table     MS.write(store) -> bytes     MS.build({{file name, path}}) -> bytes (wcc_lite's order)
local MS = {}

-- CR2W's variable length int: first byte 6 bits (0x40 more, 0x80 negative), then 7 bits each (0x80 more); i 1-based
function MS.vlq_read(buf, i)
  local b = buf:byte(i)
  local neg, more, val = b & 0x80, b & 0x40, b & 0x3F
  i = i + 1
  local shift = 6
  while more ~= 0 do
    b = buf:byte(i)
    i = i + 1
    val = val | ((b & 0x7F) << shift)
    shift = shift + 7
    more = b & 0x80
  end
  return (neg ~= 0 and -val or val), i
end

function MS.vlq_write(value)
  local neg = value < 0
  local v = neg and -value or value
  local first = v & 0x3F
  v = v >> 6
  local out = {string.char(first | (neg and 0x80 or 0) | (v ~= 0 and 0x40 or 0))}
  while v ~= 0 do
    local b = v & 0x7F
    v = v >> 7
    out[#out + 1] = string.char(b | (v ~= 0 and 0x80 or 0))
  end
  return table.concat(out)
end

local FORMATS = {{"files", "<I4I4I4I4I4I4I4I4", 32}, {"entries", "<I8I4I4I4I4", 24}, {"bundles", "<I8I4I4I4I4", 24},
                 {"buffers", "<I4", 4}, {"dirs", "<i4i4", 8}, {"inits", "<i4i4i4", 12}, {"hashes", "<i8i8", 16}}

function MS.read(data)
  assert(data:sub(1, 4) == "\3VTM", data:sub(1, 4))
  local version, max_z, max_size = string.unpack("<I4I4I4", data, 5)
  local n, i = MS.vlq_read(data, 17)
  local s = {version = version, max_z = max_z, max_size = max_size, strings = data:sub(i, i + n - 1)}
  i = i + n
  for _, f in ipairs(FORMATS) do
    local count
    count, i = MS.vlq_read(data, i)
    local recs = {}
    for k = 0, count - 1 do
      local r = {string.unpack(f[2], data, i + k * f[3])}
      r[#r] = nil                               -- (unpack's next position)
      recs[k + 1] = f[1] == "buffers" and r[1] or r
    end
    s[f[1]] = recs
    i = i + count * f[3]
  end
  s["end"] = i - 1
  return s
end

function MS.write(s)
  local out = {"\3VTM", string.pack("<I4I4I4", s.version, s.max_z, s.max_size), MS.vlq_write(#s.strings), s.strings}
  for _, f in ipairs(FORMATS) do
    local recs = s[f[1]]
    -- (wcc_lite writes an empty buffer list's count as a negative zero, 0x80)
    out[#out + 1] = (f[1] == "buffers" and #recs == 0) and "\128" or MS.vlq_write(#recs)
    for _, r in ipairs(recs) do
      out[#out + 1] = type(r) == "table" and string.pack(f[2], table.unpack(r)) or string.pack(f[2], r)
    end
  end
  return table.concat(out)
end

function MS.string_at(strings, off)
  local z = strings:find("\0", off + 1, true)
  return strings:sub(off + 1, z - 1)
end

function MS.fnv64(data)
  local h = 0xcbf29ce484222325
  for i = 1, #data do h = (h ~ data:byte(i)) * 0x100000001b3 end
  return h
end

-- the store wcc_lite writes for bundles {{file name, path}} - in its order -> bytes
function MS.build(bundles)
  local PK = require("conjunction.packer")
  local strings, slen = {"\0"}, 1
  local function intern(text)
    if text:find("[\128-\255]") then error("UnicodeEncodeError: 'ascii' codec can't encode " .. text, 0) end
    local off = slen
    strings[#strings + 1] = text .. "\0"
    slen = slen + #text + 1
    return off
  end
  local files, binfo = {}, {}
  for k, b in ipairs(bundles) do
    local name_off = intern(b[1])
    local head = assert(w3.fs.read(b[2])):sub(1, 32)
    local size, toc = string.unpack("<I4", head, 9), string.unpack("<I4", head, 17)
    local start = 0x20 + toc
    local rows = PK.entries(b[2])                 -- (path, size, zsize, offset, compression)
    for i, r in ipairs(rows) do r.at = i end
    table.sort(rows, function(x, y)
      if x[4] ~= y[4] then return x[4] < y[4] end
      return x.at < y.at
    end)
    binfo[#binfo + 1] = {name_off, start, size - start, rows, k}
    for _, r in ipairs(rows) do files[#files + 1] = {r, k} end
  end
  local path_off = {}
  for i, f in ipairs(files) do path_off[i] = intern(f[1][1]) end
  local root = intern("")
  local dirs, children, inits = {{root, 0}}, {}, {}
  for i, f in ipairs(files) do
    local path = f[1][1]
    local parts = {}
    for part in (path .. "\\"):gmatch("(.-)\\") do parts[#parts + 1] = part end
    local cur = 0
    for c = 1, #parts - 1 do
      local key = cur .. "\0" .. parts[c]
      if children[key] == nil then
        children[key] = #dirs
        dirs[#dirs + 1] = {intern(parts[c]), cur}
      end
      cur = children[key]
    end
    inits[#inits + 1] = {i, cur, path_off[i] + #path - #parts[#parts]}
  end
  local recs, ents = {{0, 0, 0, 0, 0, 0, 0, 0}}, {{0, 0, 0, 0, 0}}
  for i, f in ipairs(files) do
    local r = f[1]
    recs[#recs + 1] = {path_off[i], 0, r[3], r[2], i, 0, 0, r[5]}
    ents[#ents + 1] = {r[4], r[3], 0, i, f[2]}
  end
  local first = 1
  local bund = {{0, 0, 0, 0, 0}}
  for _, b in ipairs(binfo) do
    bund[#bund + 1] = {b[3], b[2], b[1], #b[4] > 0 and first or 0, #b[4]}
    first = first + #b[4]
  end
  local hashes = {}
  for i, f in ipairs(files) do
    local hi = i == 1 and 0 or 0xFFFFFFFF
    hashes[#hashes + 1] = {MS.fnv64(f[1][1]), (hi << 32) | i, i}
  end
  table.sort(hashes, function(x, y)
    if x[1] ~= y[1] then return math.ult(x[1], y[1]) end
    return x[3] < y[3]
  end)
  for _, h in ipairs(hashes) do h[3] = nil end
  local max_z, max_size = 0, 0
  for _, f in ipairs(files) do
    if f[1][3] > max_z then max_z = f[1][3] end
    if f[1][2] > max_size then max_size = f[1][2] end
  end
  return MS.write({version = 7, max_z = max_z, max_size = max_size, strings = table.concat(strings), files = recs,
                   entries = ents, bundles = bund, buffers = {}, dirs = dirs, inits = inits, hashes = hashes})
end

return MS
