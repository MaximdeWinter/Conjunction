-- collision.cache (CC3W, version 11): the game's cooked collision by resource path, read and written by Conjunction
-- (collision_cache.py: a terrain tile's collision follows its changed heights without wcc_lite, which cooks only what
-- it cooked itself).
-- Header 0x40: magic, version, 0, 0, table offset (u64), entry count, strings offset (u64), strings size, largest
-- packed / unpacked entry (each rounded up to 4 KB), fnv64 of everything from the strings on, 8 zero bytes. Then the
-- entries' data (zlib, one after another), the strings (paths, 0-ended), the table: 64 bytes per entry - path offset
-- in the strings, 0, 0, data offset (u64), packed size, unpacked size, fnv64 of the packed data, 8 zero bytes, 20
-- bytes kept as they are (bounds, flags).
--   CC.find(path, wanted) -> {lower path = Entry}   only those entries (the game's cache is 890 MB: read by seeking)
--   CC.parse(bytes) -> {Entry}     CC.write(entries) -> bytes
--   Entry: {path, packed, size, extra}   e:data() -> the unpacked bytes   e:replace(raw)
local MS = require("conjunction.metastore")
local CC = {}

CC.HEADER, CC.ENTRY = 0x40, 64
local unpack, pack = string.unpack, string.pack

-- zlib through cj_core (stb's inflate and deflate): a file each way
local own = string.format("%x_%x", os.time(), math.floor((os.clock() * 1e6) % 0x7fffffff))
local function scratch(name)
  local dir = w3.fs.folder("temp") .. "\\cj_core\\zlib_" .. own
  if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  return dir .. "\\" .. name
end
local function zlib(op, data)
  local src, dst = scratch("in.bin"), scratch("out.bin")
  assert(w3.fs.write(src, data))
  local ok, err = pcall(w3.plugin.cj_zlib, op, src, dst)
  w3.fs.remove(src)
  if not ok then error("zlib " .. op .. ": " .. tostring(err), 2) end
  local out = assert(w3.fs.read(dst))
  w3.fs.remove(dst)
  return out
end
CC.inflate = function(data) return zlib("inflate", data) end
CC.deflate = function(data) return zlib("deflate", data) end

local Entry = {}
Entry.__index = Entry
function CC.Entry(path, packed, size, extra)
  return setmetatable({path = path, packed = packed, size = size, extra = extra}, Entry)
end
function Entry:data() return CC.inflate(self.packed) end
function Entry:replace(raw)
  self.packed = CC.deflate(raw)
  self.size = #raw
end

function CC.fnv64(b) return MS.fnv64(b) end

function CC.parse(m)
  local magic, version = unpack("<c4I4", m, 1)
  if magic ~= "CC3W" or version ~= 11 then
    error(string.format("not a collision cache of version 11 (%q %d)", magic, version))
  end
  local tbl = unpack("<I8", m, 0x10 + 1)
  local count = unpack("<I4", m, 0x18 + 1)
  local strings = unpack("<I8", m, 0x1C + 1)
  local out = {}
  for i = 0, count - 1 do
    local e = tbl + i * CC.ENTRY + 1
    local so = unpack("<I4", m, e)
    local s0 = strings + so + 1
    local name = m:sub(s0, m:find("\0", s0, true) - 1)
    local off = unpack("<I8", m, e + 0x0C)
    local zsize, size = unpack("<I4I4", m, e + 0x14)
    out[#out + 1] = CC.Entry(name, m:sub(off + 1, off + zsize), size, m:sub(e + 0x2C, e + CC.ENTRY - 1))
  end
  return out
end
function CC.read(path) return CC.parse(assert(w3.fs.read(path))) end

-- only the entries named in wanted (depot paths, any case): the table and the strings are read, and those entries'
-- data -> {lower path = Entry}
function CC.find(path, wanted)
  local PYS = require("conjunction.pystr")
  local want = {}
  for _, w in ipairs(wanted) do want[PYS.lower(w)] = true end
  local f = assert(io.open(path, "rb"))
  local out = {}
  local ok, err = pcall(function()
    local head = f:read(0x40)
    local tbl = unpack("<I8", head, 0x10 + 1)
    local count = unpack("<I4", head, 0x18 + 1)
    local strings = unpack("<I8", head, 0x1C + 1)
    f:seek("set", strings)
    local sblock = f:read(tbl - strings)               -- (the strings run up to the table)
    f:seek("set", tbl)
    local table_ = f:read(count * CC.ENTRY)
    for i = 0, count - 1 do
      local e = i * CC.ENTRY + 1
      local so = unpack("<I4", table_, e)
      local z = sblock:find("\0", so + 1, true)
      local name = sblock:sub(so + 1, (z or (#sblock + 1)) - 1)
      local low = PYS.lower(name)
      if want[low] then
        local off = unpack("<I8", table_, e + 0x0C)
        local zsize, size = unpack("<I4I4", table_, e + 0x14)
        f:seek("set", off)
        out[low] = CC.Entry(name, f:read(zsize), size, table_:sub(e + 0x2C, e + CC.ENTRY - 1))
      end
    end
  end)
  f:close()
  if not ok then error(err, 0) end
  return out
end

local function round4k(n) return (n + 0xFFF) & ~0xFFF end

function CC.write(entries)
  local data, offsets, dlen = {}, {}, 0
  for i, e in ipairs(entries) do
    offsets[i] = CC.HEADER + dlen
    data[#data + 1] = e.packed
    dlen = dlen + #e.packed
  end
  local strings, name_off, slen = {}, {}, 0
  for i, e in ipairs(entries) do
    name_off[i] = slen
    strings[#strings + 1] = e.path .. "\0"
    slen = slen + #e.path + 1
  end
  local tbl = {}
  for i, e in ipairs(entries) do
    tbl[i] = pack("<I4I4I4I8I4I4I8I8", name_off[i], 0, 0, offsets[i], #e.packed, e.size, CC.fnv64(e.packed), 0) ..
             e.extra
  end
  local strings_s, table_s = table.concat(strings), table.concat(tbl)
  local strings_at = CC.HEADER + dlen
  local table_at = strings_at + #strings_s
  local most_p, most_u = 0, 0
  for _, e in ipairs(entries) do
    most_p = math.max(most_p, #e.packed)
    most_u = math.max(most_u, e.size)
  end
  local head = pack("<c4I4I4I4I8I4I8I4", "CC3W", 11, 0, 0, table_at, #entries, strings_at, #strings_s) ..
               pack("<I4I4", round4k(most_p), round4k(most_u)) ..
               pack("<I8I8", CC.fnv64(strings_s .. table_s), 0)
  return head .. table.concat(data) .. strings_s .. table_s
end

return CC
