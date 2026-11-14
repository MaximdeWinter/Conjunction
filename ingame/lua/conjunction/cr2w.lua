-- CR2W, The Witcher 3's resource files, read and written (cr2w.py).
-- Header 0x28 bytes (magic, version, flags, timestamp u64, build, fileSize, bufferSize, crc, table count), 10 table
-- headers (offset, count, crc32), tables: 0 strings, 1 names (string offset, hash), 2 imports (path offset, class name,
-- flags), 3 properties (16 bytes), 4 exports (class name, flags, parent, size, offset, template, crc32), 5 buffers
-- (flags, index, offset, disk size, mem size, crc32). A property: name index u16, type index u16, size u32 (counting
-- itself), the value; a handle an i32: -n = import n, +n = export n.
--   local f = CR.parse(data)    f.names[k + 1] (k as the file has it), f.imports[n] = {path, class, flags},
--                               f.exports[n] = {class, flags, parent, template, chunk}, f.buffers[n] = {flags, index,
--                               data, mem size}
--   f:props(chunk, start) -> {{name, type, off, size}, ...}   off 0-based in the chunk
--   CR.parts(data) -> the CR2W files in it (a cooked template and the ones embedded in it; broken pieces left out)
local CR = {}
CR.__index = CR

local unpack = string.unpack

local find, sub = string.find, string.sub
-- bytes off .. off + size - 1 of the file that starts after b bytes of d (0-based off; as rest:sub(off + 1, off + size)
-- of the copy from there gave them: cut at the end of the data, empty for a negative size)
local function piece(d, b, off, size)
  local hi = off + size
  if hi > #d - b then hi = #d - b end
  if hi < off + 1 then return "" end
  return sub(d, b + off + 1, b + hi)
end
-- a 0-ended text at 0-based offset o of s (strings.index(b"\0", o): an error without one)
local function text(s, o)
  local z = s:find("\0", o + 1, true)
  if not z then error("cr2w: a text without its end") end
  return s:sub(o + 1, z - 1)
end
local function at_(list, k, what)           -- list[k] as Python's list[k - 1] would raise past the end
  local v = list[k]
  if v == nil then error("cr2w: no " .. what .. " " .. tostring(k - 1)) end
  return v
end

-- (at: where in d the file starts, 1-based - CR.parts reads the files embedded in a template where they are, no copy
-- of the rest of the data for each: 25.10., the asset build)
function CR.parse(d, at)
  at = at or 1
  local b = at - 1                              -- (the file's offsets count from its start)
  if d:sub(at, at + 3) ~= "CR2W" then error("not a CR2W file") end
  local self = setmetatable({data = d, at = at}, CR)
  local _, version, flags, timestamp, build, _fs, _bs, _crc, tcount = unpack("<c4IIi8IIIII", d, at)
  self.version, self.flags, self.timestamp, self.build, self.table_count = version, flags, timestamp, build, tcount
  self.tables = {}
  for i = 0, 9 do self.tables[i + 1] = {unpack("<III", d, b + 0x28 + i * 12 + 1)} end
  local s_off, s_len = self.tables[1][1], self.tables[1][2]
  local strings = sub(d, at + s_off, math.min(at + s_off + s_len - 1, #d))
  self.strings = strings
  local n_off, n_cnt = self.tables[2][1], self.tables[2][2]
  local names, hashes = {}, {}
  self.names, self.hashes = names, hashes
  for i = 0, n_cnt - 1 do                       -- (text() written out: a call a name was most of a build's parsing)
    local o, h = unpack("<II", d, b + n_off + i * 8 + 1)
    local z = find(strings, "\0", o + 1, true)
    if not z then error("cr2w: a text without its end") end
    names[i + 1] = sub(strings, o + 1, z - 1)
    hashes[i + 1] = h
  end
  local i_off, i_cnt = self.tables[3][1], self.tables[3][2]
  self.imports = {}
  for i = 0, i_cnt - 1 do
    local o, cls, fl = unpack("<IHH", d, b + i_off + i * 8 + 1)
    self.imports[i + 1] = {text(strings, o), at_(names, cls + 1, "name"), fl}
  end
  local p_off, p_cnt = self.tables[4][1], self.tables[4][2]
  self.properties = {}
  for i = 0, p_cnt - 1 do self.properties[i + 1] = piece(d, b, p_off + i * 16, 16) end
  local e_off, e_cnt = self.tables[5][1], self.tables[5][2]
  self.exports = {}
  for i = 0, e_cnt - 1 do
    local cls, fl, parent, size, off, tmpl = unpack("<HHIIIII", d, b + e_off + i * 24 + 1)   -- (and its crc)
    self.exports[i + 1] = {at_(names, cls + 1, "name"), fl, parent, tmpl, piece(d, b, off, size)}
  end
  local b_off, b_cnt = self.tables[6][1], self.tables[6][2]
  self.buffers = {}
  for i = 0, b_cnt - 1 do
    local fl, idx, off, disk, mem = unpack("<IIIIII", d, b + b_off + i * 24 + 1)   -- (and its crc)
    self.buffers[i + 1] = {fl, idx, piece(d, b, off, disk), mem}
  end
  return self
end

-- (name, type, value offset, value size) of the properties of an object's data (it starts with a 0 byte)
function CR:props(chunk, start)
  local out, i = {}, start or 1
  while i + 2 <= #chunk do
    local nm = unpack("<H", chunk, i + 1)
    if nm == 0 then break end
    local tp, sz = unpack("<HI", chunk, i + 3)
    out[#out + 1] = {at_(self.names, nm + 1, "name"), at_(self.names, tp + 1, "name"), i + 8, sz - 4}
    i = i + 4 + sz
  end
  return out
end
-- {name = {type, off, size}} (meshview._props)
function CR:prop_map(chunk, start)
  local out = {}
  for _, p in ipairs(self:props(chunk, start)) do out[p[1]] = {p[2], p[3], p[4]} end
  return out
end

-- --- writing (cr2w.py's: enough for Conjunction's own resources and its changes to the game's)
local P = require("conjunction.py")
local pack = string.pack

-- a name's hash in the name table: FNV-1a (32 bit) of its UTF-8 bytes with the closing 0 byte; the empty name 0
function CR.known_hash(name)
  if name == nil or name == "" then return 0 end
  local h = 0x811C9DC5
  for i = 1, #name + 1 do
    local c = i <= #name and name:byte(i) or 0
    h = ((h ~ c) * 0x01000193) & 0xFFFFFFFF
  end
  return h
end

-- the index (0-based, as the file has it) of a name; an error when there is none
function CR:name_index(name)
  for i, n in ipairs(self.names) do if n == name then return i - 1 end end
  error("ValueError: '" .. tostring(name) .. "' is not in list")
end
function CR:add_name(name)
  for i, n in ipairs(self.names) do if n == name then return i - 1 end end
  self.names[#self.names + 1] = name
  self.hashes[#self.hashes + 1] = CR.known_hash(name)
  return #self.names - 1
end
-- tables 6.. (embedded files and more) are not read; such a file can be read but not written back
function CR:writable()
  for t = 7, 10 do if self.tables[t][2] ~= 0 then return false end end
  return true
end

-- a Color value: the struct's fields Red / Green / Blue / Alpha (Uint8), ended by name 0
function CR:color_struct(rgba)
  local u8 = self:add_name("Uint8")
  local out = {"\0"}
  for k, nm in ipairs({"Red", "Green", "Blue", "Alpha"}) do out[#out + 1] = pack("<I2I2I4B", self:add_name(nm), u8, 5, rgba[k]) end
  out[#out + 1] = "\0\0"
  return table.concat(out)
end

function CR:save()
  if not self:writable() then error("ValueError: this file uses tables the writer does not know (embedded files)") end
  -- strings: the file's own table as it was (its order), new names and import paths after it
  local strings, offsets = {self.strings}, {}
  local len = #self.strings
  local o = 0
  while o < #self.strings do
    local e = self.strings:find("\0", o + 1, true)
    local s = self.strings:sub(o + 1, e - 1)
    if offsets[s] == nil then offsets[s] = o end
    o = e
  end
  local function put(s)
    if offsets[s] == nil then
      offsets[s] = len
      strings[#strings + 1] = s .. "\0"
      len = len + #s + 1
    end
    return offsets[s]
  end
  for _, n in ipairs(self.names) do put(n) end
  for _, im in ipairs(self.imports) do put(im[1]) end
  local names = {}
  for i, n in ipairs(self.names) do names[i] = pack("<I4I4", offsets[n], self.hashes[i]) end
  local imports = {}
  for i, im in ipairs(self.imports) do imports[i] = pack("<I4I2I2", offsets[im[1]], self:add_name(im[2]), im[3]) end
  local strings_s = table.concat(strings)
  local names_s, imports_s, props_s = table.concat(names), table.concat(imports), table.concat(self.properties)
  local pos = 0xA0
  local layout = {}
  for _, bc in ipairs({{strings_s, #strings_s}, {names_s, #self.names}, {imports_s, #self.imports},
                       {props_s, #self.properties}}) do
    layout[#layout + 1] = {pos, bc[2], P.crc32(bc[1]), bc[1]}
    pos = pos + #bc[1]
  end
  local exports_off = pos
  pos = pos + 24 * #self.exports
  local buffers_off = pos
  pos = pos + 24 * #self.buffers
  local data_off = pos
  local exports, datas, dlen = {}, {}, 0
  for i, e in ipairs(self.exports) do
    exports[i] = pack("<I2I2I4I4I4I4I4", self:add_name(e[1]), e[2], e[3], #e[5], data_off + dlen, e[4], P.crc32(e[5]))
    datas[i] = e[5]
    dlen = dlen + #e[5]
  end
  local file_size = data_off + dlen
  local buffers, bufdata, blen = {}, {}, 0
  for i, b in ipairs(self.buffers) do
    buffers[i] = pack("<I4I4I4I4I4I4", b[1], b[2], file_size + blen, #b[3], b[4], P.crc32(b[3]))
    bufdata[i] = b[3]
    blen = blen + #b[3]
  end
  if #names_s ~= 8 * #self.names then error("RuntimeError: a class name was added while saving - add names before save()") end
  local exports_s, buffers_s = table.concat(exports), table.concat(buffers)
  layout[#layout + 1] = {exports_off, #self.exports, P.crc32(exports_s), exports_s}
  layout[#layout + 1] = {buffers_off, #self.buffers, P.crc32(buffers_s), buffers_s}
  local head = {pack("<c4I4I4I8I4I4I4I4I4", "CR2W", self.version, self.flags, self.timestamp, self.build, file_size,
                     file_size + blen, 0xDEADBEEF, self.table_count)}
  for i = 1, 10 do
    local l = layout[i]
    if l then head[#head + 1] = pack("<I4I4I4", l[2] ~= 0 and l[1] or 0, l[2], l[3])
    else head[#head + 1] = pack("<I4I4I4", 0, 0, 0) end
  end
  local h = table.concat(head)
  h = h .. string.rep("\0", 0xA0 - #h)
  local crc = P.crc32(h)
  h = h:sub(1, 32) .. pack("<I4", crc) .. h:sub(37)
  local out = {h}
  for _, l in ipairs(layout) do out[#out + 1] = l[4] end
  out[#out + 1] = table.concat(datas)
  out[#out + 1] = table.concat(bufdata)
  return table.concat(out)
end

-- assets._cr2w_parts: every "CR2W" in the data read as a file from there (one that fails is left out)
function CR.parts(data)
  local out, i = {}, 1
  while true do
    i = data:find("CR2W", i, true)
    if not i then return out end
    local ok, f = pcall(CR.parse, data, i)
    if ok then out[#out + 1] = f end
    i = i + 4
  end
end

return CR
