-- A remaster bundle written by Conjunction (packer.py) - the layout wcc_lite writes:
--   header 0x20: 'POTATO70', u32 the bundle's size rounded up to 16, u32 0, u32 the table's size, u16 5, u16 where
--                the data begins (0x20 + the table), 8 zero bytes
--   table: 0x130 per file - the depot path (0x100, zero padded), a hash (16 zero bytes), u64 offset, u32 size,
--          u32 stored size, u32 crc32 of the file, u32 compression (5 = lz4 hc)
--   data: the files in the reverse order of the table, each at a 16-byte boundary, nothing after the last
--   PK.pack(folder, out_dir, name, skip) -> the bundle's path       PK.entries(bundle) -> {{path, size, zsize, offset, comp}}
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local PK = {}

PK.ENTRY, PK.ENTRY_OLD, PK.LZ4HC = 0x130, 0x140, 5

local function scratch()
  local dir = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_pack"
  if not w3.fs.isdir(dir) then w3.fs.mkdir(dir) end
  return dir
end

-- raw as lz4.block.compress(raw, mode="high_compression", store_size=False) gives it (cj_core: LZ4 1.9.4, level 9)
function PK.compress(path)
  local out = scratch() .. "\\" .. require("conjunction.marks").uuid4_hex():sub(1, 12) .. ".lz4"
  local r = w3.plugin.cj_lz4hc_file(path, out)
  if not r or not r:match("^%d+ %d+$") then error("lz4: " .. tostring(r), 0) end
  local data = assert(w3.fs.read(out))
  w3.fs.remove(out)
  return data
end

-- the files under folder (cooked: dlc\<dlc>\...) into one bundle -> its path
function PK.pack(folder, out_dir, name, skip)
  name = name or "blob0.bundle"
  skip = skip or {["cook.db"] = true}
  local files = {}
  local function walk(dir, rel)
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local full, r = dir .. "\\" .. e.name, rel == "" and e.name or (rel .. "\\" .. e.name)
      if e.dir then walk(full, r) elseif not skip[e.name] then files[#files + 1] = {r, full, PYS.lower(r)} end
    end
  end
  walk(folder, "")
  table.sort(files, function(a, b) return a[3] < b[3] end)
  local toc = PK.ENTRY * #files
  local start = 0x20 + toc
  local offsets, blocks, pos = {}, {}, start
  for i = #files, 1, -1 do                       -- (the data in the reverse order of the table)
    pos = (pos + 15) & ~15
    local raw = assert(w3.fs.read(files[i][2]))
    local stored, comp = PK.compress(files[i][2]), PK.LZ4HC
    if #stored >= #raw then stored, comp = raw, 0 end   -- (nothing gained: stored as it is)
    offsets[i] = {pos, #raw, #stored, P.crc32(raw) & 0xFFFFFFFF, comp}
    blocks[#blocks + 1] = {pos, stored}
    pos = pos + #stored
  end
  local size = pos
  local out = {string.pack("<c8I4I4I4I2I2", "POTATO70", (size + 15) & ~15, 0, toc, 5, start), string.rep("\0", 8)}
  for i, f in ipairs(files) do
    local path = f[1]
    if path:find("[\128-\255]") then error("UnicodeEncodeError: 'ascii' codec can't encode " .. path, 0) end
    if #path >= 0x100 then error(require("conjunction.questgen").ValueError("path too long for a bundle: " .. path), 0) end
    local o = offsets[i]
    out[#out + 1] = path .. string.rep("\0", 0x110 - #path) .. string.pack("<I8I4I4I4I4", o[1], o[2], o[3], o[4], o[5]) ..
                    string.rep("\0", 8)
  end
  local at = start
  for _, b in ipairs(blocks) do
    if b[1] > at then out[#out + 1] = string.rep("\0", b[1] - at) end
    out[#out + 1] = b[2]
    at = b[1] + #b[2]
  end
  if not w3.fs.isdir(out_dir) then w3.fs.mkdir(out_dir) end
  local target = out_dir .. "\\" .. name
  assert(w3.fs.write(target .. ".tmp", table.concat(out)))
  if w3.fs.exists(target) then w3.fs.remove(target) end
  assert(w3.fs.rename(target .. ".tmp", target))
  return target
end

-- 0x140 (up to 4.04) or 0x130 (the remaster): the second entry's name starts right after the first one
local function entry_size(toc)
  if #toc % PK.ENTRY_OLD ~= 0 and #toc % PK.ENTRY == 0 then return PK.ENTRY end
  if #toc >= 2 * PK.ENTRY and #toc % PK.ENTRY == 0 then
    local function starts(at)
      local c = toc:sub(at + 1, at + 1)
      return c:match("^%w$") ~= nil and toc:byte(at) == 0
    end
    if starts(PK.ENTRY) and (#toc % PK.ENTRY_OLD ~= 0 or not starts(PK.ENTRY_OLD)) then return PK.ENTRY end
  end
  return PK.ENTRY_OLD
end

-- {depot path, size, compressed size, offset, compression} of every file in a bundle
function PK.entries(bundle)
  local data = assert(w3.fs.read(bundle))
  local n = string.unpack("<I4", data, 17)
  local toc = data:sub(0x21, 0x20 + n)
  local step = entry_size(toc)
  local out = {}
  for i = 0, n // step - 1 do
    local o = i * step
    local nm = toc:sub(o + 1, o + 0x100)
    nm = require("conjunction.w3strings").decode_replace(nm:match("^[^%z]*"))
    local offset, size, zsize, comp
    if step == PK.ENTRY then
      offset, size, zsize, _, comp = string.unpack("<I8I4I4I4I4", toc, o + 0x111)
    else
      size, zsize, offset = string.unpack("<I4I4I4", toc, o + 0x115)
      comp = string.unpack("<I4", toc, o + 0x13D)
    end
    out[#out + 1] = {nm, size, zsize, offset, comp}
  end
  return out
end

return PK
