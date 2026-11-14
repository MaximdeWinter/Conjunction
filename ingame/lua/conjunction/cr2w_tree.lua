-- A CR2W file as a tree of typed values, lossless (cr2w_tree.py): every object with every property as a Lua value,
-- changed and written back - an unchanged file comes out byte for byte as it went in.
-- Values, by type (as the app has them):
--   Bool, Int8 ... Double     boolean / integer / float
--   CName, an enum            string (the name)
--   String, StringAnsi        string (UTF-8; a packed length: negative = 8-bit letters, else UTF-16: then TR.Wide)
--   LocalizedString           TR.Loc(id)          handle:X, ptr:X, #X   integer (+n object n, -n import n, 0 none)
--   soft:X                    TR.Soft(index)      CGUID                 TR.Guid(16 bytes)
--   TagList                   TR.Tags({names})    array:a,b,X           TR.Array({values})
--   CVariant                  TR.Variant(type, value)                   EngineTransform  TR.Transform(pos, rot, scale)
--   a struct                  TR.Struct({props})  anything else         TR.Raw(bytes), kept as it was
-- A property is {name, type, value}. Objects are numbered from 1 as the file's handles count them.
--   local t = TR.Tree(data); t:obj(n):get("factID"); t:obj(n):set("value", 2); t:to_bytes()
local CR = require("conjunction.cr2w")
local TR = {}

local function kind(mt) return setmetatable({}, {__index = mt}) end
local RAW, WIDE, LOC, SOFT, GUID, TAGS, ARRAY, STRUCT, VARIANT, TRANSFORM = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
for _, pair in ipairs({{RAW, "Raw"}, {WIDE, "Wide"}, {LOC, "Loc"}, {SOFT, "Soft"}, {GUID, "Guid"}, {TAGS, "Tags"},
                       {ARRAY, "Array"}, {STRUCT, "Struct"}, {VARIANT, "Variant"}, {TRANSFORM, "Transform"}}) do
  pair[1].__name = pair[2]
end
TR.RAW, TR.WIDE, TR.LOC, TR.SOFT, TR.GUID, TR.TAGS, TR.ARRAY, TR.STRUCT = RAW, WIDE, LOC, SOFT, GUID, TAGS, ARRAY, STRUCT
TR.VARIANT, TR.TRANSFORM = VARIANT, TRANSFORM
function TR.Raw(b) return setmetatable({b = b}, RAW) end
function TR.Wide(s) return setmetatable({s = s}, WIDE) end
function TR.Loc(n) return setmetatable({n = n}, LOC) end
function TR.Soft(n) return setmetatable({n = n}, SOFT) end
function TR.Guid(b) return setmetatable({b = b}, GUID) end
function TR.Tags(list) return setmetatable(list or {}, TAGS) end
function TR.Array(list) return setmetatable(list or {}, ARRAY) end
function TR.Struct(props) return setmetatable(props or {}, STRUCT) end
function TR.Variant(t, v) return setmetatable({type = t, value = v}, VARIANT) end
function TR.Transform(p, r, s) return setmetatable({position = p, rotation = r, scale = s}, TRANSFORM) end
function TR.Prop(name, typ, value) return {name = name, type = typ, value = value} end
local function is(v, mt) return type(v) == "table" and getmetatable(v) == mt end
TR.is = is
-- a struct's property value by name
function TR.sget(st, name, default)
  for _, p in ipairs(st) do if p.name == name then return p.value end end
  return default
end

-- a new GUID (uuid4's bytes); the checks put a sequence of their own in
function TR.new_guid()
  local hex = require("conjunction.marks").uuid4_hex()
  return TR.Guid((hex:gsub("..", function(h) return string.char(tonumber(h, 16)) end)))
end

local SIMPLE = {Bool = "B", Int8 = "<i1", Uint8 = "<I1", Int16 = "<i2", Uint16 = "<I2", Int32 = "<i4", Uint32 = "<I4",
                Int64 = "<i8", Uint64 = "<I8", Float = "<f", Double = "<d"}
local SIZE = {Bool = 1, Int8 = 1, Uint8 = 1, Int16 = 2, Uint16 = 2, Int32 = 4, Uint32 = 4, Int64 = 8, Uint64 = 8,
              Float = 4, Double = 8}
local NOT_ENUMS = {EngineTransform = true, EulerAngles = true}

function TR.is_enum(typ)
  local a, b = typ:sub(1, 1), typ:sub(2, 2)
  return (a == "E" or a == "e") and b:match("^%u$") ~= nil and not NOT_ENUMS[typ]
end

local function prefixed(typ, list)
  for _, p in ipairs(list) do if typ:sub(1, #p) == p then return true end end
  return false
end
local HANDLES = {"handle:", "ptr:", "#"}
local function inner_of(typ)
  local _, rest = typ:match("^array:([^,]*,[^,]*),(.*)$")
  if rest then return rest end
  return typ:match("^%[%d+%](.+)$")             -- (a fixed array, [15]Bezier2dHandle: kept as an array is)
end
local function is_list(typ) return typ:sub(1, 6) == "array:" or typ:match("^%[%d+%].") ~= nil end

-- --- packed ints (string lengths, tag counts): the first byte sign (0x80), more (0x40), 6 bits; then 7 bits each
-- (i 0-based) -> value, the offset after it
local function read_packed(b, i)
  local c = b:byte(i + 1)
  if not c then error("IndexError", 0) end
  local neg, v, more, shift = c & 0x80, c & 0x3F, c & 0x40, 6
  i = i + 1
  while more ~= 0 do
    c = b:byte(i + 1)
    if not c then error("IndexError", 0) end
    v = v | ((c & 0x7F) << shift)
    more, shift, i = c & 0x80, shift + 7, i + 1
  end
  return (neg ~= 0 and -v or v), i
end
local function packed(n)
  local neg, v = n < 0, math.abs(n)
  local first = (neg and 0x80 or 0) | (v & 0x3F)
  v = v >> 6
  if v == 0 then return string.char(first) end
  local out = {string.char(first | 0x40)}
  while v ~= 0 do
    out[#out + 1] = string.char((v & 0x7F) | ((v >> 7) ~= 0 and 0x80 or 0))
    v = v >> 7
  end
  return table.concat(out)
end
TR.read_packed, TR.packed = read_packed, packed

-- --- text: 8-bit letters (latin-1) and UTF-16 as UTF-8 strings
local function latin1_to_utf8(s)
  if not s:find("[\128-\255]") then return s end
  return (s:gsub("[\128-\255]", function(c) return utf8.char(c:byte()) end))
end
-- a UTF-8 string as latin-1 bytes, or nil when a letter is past 255
local function utf8_to_latin1(s)
  if not s:find("[\128-\255]") then return s end
  local out = {}
  for _, c in utf8.codes(s) do
    if c > 255 then return nil end
    out[#out + 1] = string.char(c)
  end
  return table.concat(out)
end
local function utf16_decode(b)
  local out, i, n = {}, 1, #b
  while i + 1 <= n do
    local u = string.unpack("<I2", b, i)
    i = i + 2
    if u >= 0xD800 and u <= 0xDBFF then
      if i + 1 > n then error("UnicodeDecodeError", 0) end
      local l = string.unpack("<I2", b, i)
      if l < 0xDC00 or l > 0xDFFF then error("UnicodeDecodeError", 0) end
      i = i + 2
      out[#out + 1] = utf8.char(0x10000 + ((u - 0xD800) << 10) + (l - 0xDC00))
    elseif u >= 0xDC00 and u <= 0xDFFF then
      error("UnicodeDecodeError", 0)
    else
      out[#out + 1] = utf8.char(u)
    end
  end
  if i <= n then error("UnicodeDecodeError", 0) end
  return table.concat(out)
end
local function utf16_encode(s)
  local out = {}
  for _, c in utf8.codes(s) do
    if c >= 0x10000 then
      c = c - 0x10000
      out[#out + 1] = string.pack("<I2I2", 0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF))
    else
      out[#out + 1] = string.pack("<I2", c)
    end
  end
  return table.concat(out)
end

-- --- reading and writing values of one file (its names and imports)
local Codec = {}
Codec.__index = Codec
function TR.Codec(f) return setmetatable({f = f}, Codec) end

function Codec:name(k)
  local n = self.f.names[k + 1]
  if n == nil then error("ValueError: name index out of range", 0) end
  return n
end

-- (i, e 0-based) -> value, the offset after it
function Codec:read(typ, b, i, e)
  local fmt = SIMPLE[typ]
  if fmt then
    if i + SIZE[typ] > #b then error("struct.error", 0) end
    if typ == "Bool" then return b:byte(i + 1) ~= 0, i + 1 end
    return (string.unpack(fmt, b, i + 1)), i + SIZE[typ]
  end
  if typ == "CName" then
    if i + 2 > #b then error("struct.error", 0) end
    return self:name(string.unpack("<I2", b, i + 1)), i + 2
  end
  if typ == "String" or typ == "StringAnsi" then
    local n
    n, i = read_packed(b, i)
    if n < 0 or b:byte(i) == 0x80 then
      if i - n > #b then error("IndexError", 0) end
      return latin1_to_utf8(b:sub(i + 1, i - n)), i - n
    end
    if i + 2 * n > #b then error("IndexError", 0) end
    return TR.Wide(utf16_decode(b:sub(i + 1, i + 2 * n))), i + 2 * n
  end
  if typ == "LocalizedString" then
    if i + 4 > #b then error("struct.error", 0) end
    return TR.Loc((string.unpack("<I4", b, i + 1))), i + 4
  end
  if prefixed(typ, HANDLES) then
    if i + 4 > #b then error("struct.error", 0) end
    return (string.unpack("<i4", b, i + 1)), i + 4
  end
  if typ:sub(1, 5) == "soft:" then
    if i + 2 > #b then error("struct.error", 0) end
    return TR.Soft((string.unpack("<I2", b, i + 1))), i + 2
  end
  if typ == "EngineTransform" then
    local flags = b:byte(i + 1)
    if not flags then error("IndexError", 0) end
    i = i + 1
    local parts = {}
    for k, bit in ipairs({1, 2, 4}) do
      if flags & bit ~= 0 then
        if i + 12 > #b then error("struct.error", 0) end
        parts[k] = {string.unpack("<fff", b, i + 1)}
        parts[k][4] = nil
        i = i + 12
      end
    end
    if flags & ~7 ~= 0 then error("ValueError: transform flags", 0) end
    return TR.Transform(parts[1], parts[2], parts[3]), i
  end
  if typ == "CGUID" then
    if i + 16 > #b then error("IndexError", 0) end
    return TR.Guid(b:sub(i + 1, i + 16)), i + 16
  end
  if typ == "TagList" then
    local n
    n, i = read_packed(b, i)
    local out = TR.Tags({})
    for k = 0, n - 1 do
      if i + 2 * k + 2 > #b then error("struct.error", 0) end
      out[k + 1] = self:name(string.unpack("<I2", b, i + 2 * k + 1))
    end
    return out, i + 2 * n
  end
  if is_list(typ) then
    local inner = inner_of(typ)
    if not inner then error("IndexError", 0) end
    if i + 4 > #b then error("struct.error", 0) end
    local n = string.unpack("<I4", b, i + 1)
    i = i + 4
    local out = TR.Array({})
    for k = 1, n do
      local v
      v, i = self:read(inner, b, i, e)
      out[k] = v
    end
    return out, i
  end
  if typ == "CVariant" then
    if i + 6 > #b then error("struct.error", 0) end
    local t, size = string.unpack("<I2I4", b, i + 1)
    local vt = self:name(t)
    local v, j = self:read(vt, b, i + 6, i + 2 + size)
    if j ~= i + 2 + size then error("ValueError: variant size", 0) end
    return TR.Variant(vt, v), j
  end
  if TR.is_enum(typ) then
    if i + 2 > #b then error("struct.error", 0) end
    return self:name(string.unpack("<I2", b, i + 1)), i + 2
  end
  if b:byte(i + 1) == 0 and e - i > 2 then
    local props
    props, i = self:read_props(b, i + 1, e)
    return TR.Struct(props), i
  end
  if e - i == 2 then
    if i + 2 > #b then error("struct.error", 0) end
    return self:name(string.unpack("<I2", b, i + 1)), i + 2
  end
  error("ValueError: unknown type " .. typ, 0)
end

-- properties up to a 0 name -> {prop}, the offset after the 0 name; a value read back differently stays Raw
function Codec:read_props(b, i, e)
  local out = {}
  while true do
    if i + 2 > #b then error("struct.error", 0) end
    local nm = string.unpack("<I2", b, i + 1)
    if nm == 0 then return out, i + 2 end
    if i + 8 > #b then error("struct.error", 0) end
    local tp, size = string.unpack("<I2I4", b, i + 3)
    local name, typ = self:name(nm), self:name(tp)
    local vs, ve = i + 8, i + 4 + size
    if ve > e or size < 4 then error("ValueError: property size", 0) end
    local raw = b:sub(vs + 1, ve)
    local ok, v, j = pcall(self.read, self, typ, b, vs, ve)
    if ok then
      local okw, back = pcall(self.write, self, typ, v)
      if j ~= ve or not okw or back ~= raw then v = TR.Raw(raw) end
    else
      v = TR.Raw(raw)
    end
    out[#out + 1] = TR.Prop(name, typ, v)
    i = ve
  end
end

function Codec:write(typ, v)
  if is(v, RAW) then return v.b end
  local f = self.f
  local fmt = SIMPLE[typ]
  if fmt then
    if typ == "Bool" then return string.char(v and v ~= 0 and 1 or 0) end
    if typ == "Float" or typ == "Double" then          -- (-0.0 + 0.0 would be 0.0: a float stays as it is)
      return string.pack(fmt, math.type(v) == "float" and v or v + 0.0)
    end
    return string.pack(fmt, math.tointeger(v) or error("struct.error: required argument is not an integer", 0))
  end
  if typ == "String" or typ == "StringAnsi" then
    local s = is(v, WIDE) and v.s or v
    if not is(v, WIDE) then
      local l1 = utf8_to_latin1(s)
      if l1 then return (#l1 > 0 and packed(-#l1) or "\128") .. l1 end
    end
    local data = utf16_encode(s)
    return packed(#data // 2) .. data
  end
  if typ == "CName" or type(v) == "string" then
    if is(v, WIDE) then v = v.s end
    return string.pack("<I2", f:add_name(v))
  end
  if typ == "LocalizedString" then return string.pack("<I4", is(v, LOC) and v.n or v) end
  if prefixed(typ, HANDLES) then return string.pack("<i4", v) end
  if typ == "EngineTransform" then
    local parts = {v.position, v.rotation, v.scale}
    local flags, out = 0, {}
    for k, bit in ipairs({1, 2, 4}) do
      if parts[k] ~= nil then
        flags = flags + bit
        out[#out + 1] = string.pack("<fff", parts[k][1], parts[k][2], parts[k][3])
      end
    end
    return string.char(flags) .. table.concat(out)
  end
  if typ:sub(1, 5) == "soft:" then return string.pack("<I2", is(v, SOFT) and v.n or v) end
  if typ == "CGUID" then return v.b end
  if typ == "TagList" then
    local out = {packed(#v)}
    for _, n in ipairs(v) do out[#out + 1] = string.pack("<I2", f:add_name(n)) end
    return table.concat(out)
  end
  if is_list(typ) then
    local inner = inner_of(typ)
    local out = {string.pack("<I4", #v)}
    for _, x in ipairs(v) do out[#out + 1] = self:write(inner, x) end
    return table.concat(out)
  end
  if typ == "CVariant" then
    local data = self:write(v.type, v.value)
    return string.pack("<I2I4", f:add_name(v.type), #data + 4) .. data
  end
  if is(v, STRUCT) then return "\0" .. self:write_props(v) end
  error("ValueError: cannot write " .. typ, 0)
end

function Codec:write_props(props)
  local out = {}
  for _, p in ipairs(props) do
    local data = self:write(p.type, p.value)
    out[#out + 1] = string.pack("<I2I2I4", self.f:add_name(p.name), self.f:add_name(p.type), #data + 4) .. data
  end
  out[#out + 1] = "\0\0"
  return table.concat(out)
end

-- --- one object of the file: its class, export fields, properties (and a script block's arguments)
local Obj = {}
Obj.__index = Obj
function TR.Obj(cls, flags, parent, template, props, args, rest)
  return setmetatable({cls = cls, flags = flags, parent = parent, template = template, props = props, args = args,
                       rest = rest or ""}, Obj)
end
function Obj:prop(name)
  for _, p in ipairs(self.props or {}) do if p.name == name then return p end end
  return nil
end
function Obj:get(name, default)
  local p = self:prop(name)
  if p ~= nil then return p.value end
  return default
end
function Obj:set(name, value, typ)
  local p = self:prop(name)
  if p == nil then
    if typ == nil then error("KeyError: " .. self.cls .. " has no " .. name .. ": give its type", 0) end
    self.props[#self.props + 1] = TR.Prop(name, typ, value)
  else
    p.value = value
  end
end

local Tree = {}
Tree.__index = Tree
TR.KEEP_GUID = {CJournalPath = true}

-- A scene section keeps its events after its properties: a count (u32), then per event its size (u32, counting
-- itself), its class (a name index, u16), a 0 byte and its properties. With opts.events they are read into
-- o.events = {{cls = , props = }} (handles inside them follow edits as the properties' do) and written back from there;
-- every section of the game's 6225 scenes comes back byte for byte (scene_file.lua).
TR.EVENT_OWNERS = {CStorySceneSection = true, CStorySceneCutsceneSection = true, CStorySceneVideoSection = true}

function TR.Tree(data, opts)
  local self = setmetatable({}, Tree)
  self.f = CR.parse(data)
  self.codec = TR.Codec(self.f)
  self.objects = {}
  for k, e in ipairs(self.f.exports) do self.objects[k] = self:_read(e) end
  if opts and opts.events then
    for _, o in ipairs(self.objects) do
      if TR.EVENT_OWNERS[o.cls] and o.props and #o.rest >= 4 then self:_read_events(o) end
    end
  end
  return self
end

function Tree:_read_events(o)
  local r = o.rest
  local ok, evs, i = pcall(function()
    local n, i = string.unpack("<I4", r), 4
    local out = {}
    for k = 1, n do
      local size, cls = string.unpack("<I4I2", r, i + 1)
      if r:byte(i + 7) ~= 0 then error("event start", 0) end
      local props, j = self.codec:read_props(r, i + 7, i + size)
      if j ~= i + size then error("event size", 0) end
      out[k] = {cls = self.codec:name(cls), props = props}
      i = j
    end
    return out, i
  end)
  if ok then
    o.events, o.rest = evs, r:sub(i + 1)
  end
end

function Tree:events_bytes(o)
  local out = {string.pack("<I4", #o.events)}
  for _, ev in ipairs(o.events) do
    local body = string.pack("<I2", self.f:add_name(ev.cls)) .. "\0" .. self.codec:write_props(ev.props)
    out[#out + 1] = string.pack("<I4", #body + 4) .. body
  end
  return table.concat(out)
end

function Tree:_read(export)
  local cls, flags, parent, template, b = export[1], export[2], export[3], export[4], export[5]
  if b == "" or b:byte(1) ~= 0 then return TR.Obj(cls, flags, parent, template, nil, nil, b) end
  local ok, props, i = pcall(self.codec.read_props, self.codec, b, 1, #b)
  if not ok then return TR.Obj(cls, flags, parent, template, nil, nil, b) end
  local args
  if i < #b then
    local ok2, a, j = pcall(self.codec.read_props, self.codec, b, i, #b)
    if ok2 and j == #b then
      args = a
      i = j
    end
  end
  return TR.Obj(cls, flags, parent, template, props, args, b:sub(i + 1))
end

function Tree:chunk(o)
  if o.props == nil then return o.rest end
  local out = "\0" .. self.codec:write_props(o.props)
  if o.args ~= nil then out = out .. self.codec:write_props(o.args) end
  if o.events then out = out .. self:events_bytes(o) end
  return out .. o.rest
end

function Tree:to_bytes()
  local chunks = {}
  for k, o in ipairs(self.objects) do chunks[k] = self:chunk(o) end
  for _, o in ipairs(self.objects) do self.f:add_name(o.cls) end
  for _, im in ipairs(self.f.imports) do self.f:add_name(im[2]) end
  local ex = {}
  for k, o in ipairs(self.objects) do ex[k] = {o.cls, o.flags, o.parent, o.template, chunks[k]} end
  self.f.exports = ex
  return self.f:save()
end

-- every value kept as Raw: {{object index (0-based), class, property path, type}}
function Tree:raw_values()
  local out = {}
  local function walk(i, cls, props, path)
    for _, p in ipairs(props or {}) do
      local here = path .. p.name
      if is(p.value, RAW) then
        out[#out + 1] = {i, cls, here, p.type}
      elseif is(p.value, STRUCT) then
        walk(i, cls, p.value, here .. ".")
      elseif is(p.value, ARRAY) then
        for k, x in ipairs(p.value) do
          if is(x, STRUCT) then walk(i, cls, x, here .. "[" .. (k - 1) .. "].") end
        end
      end
    end
  end
  for k, o in ipairs(self.objects) do
    local i = k - 1
    if o.props == nil then out[#out + 1] = {i, o.cls, "(whole object)", ""} end
    walk(i, o.cls, o.props, "")
    walk(i, o.cls, o.args, "(args).")
    if o.rest ~= "" then out[#out + 1] = {i, o.cls, "(rest)", ""} end
  end
  return out
end

-- --- editing
function Tree:obj(n) return self.objects[n] end
function Tree:add(o)
  self.objects[#self.objects + 1] = o
  return #self.objects
end

-- everything under object n (its children, theirs ...), by number, sorted
function Tree:under(n)
  local kids = {}
  for k, o in ipairs(self.objects) do
    kids[o.parent] = kids[o.parent] or {}
    table.insert(kids[o.parent], k)
  end
  local out, seen, todo = {}, {}, {}
  for _, k in ipairs(kids[n] or {}) do todo[#todo + 1] = k end
  while #todo > 0 do
    local k = table.remove(todo, 1)
    if not seen[k] and k ~= n then
      seen[k] = true
      out[#out + 1] = k
      for _, c in ipairs(kids[k] or {}) do todo[#todo + 1] = c end
    end
  end
  table.sort(out)
  return out
end

-- every handle to an object (+n) and every parent through fn(n); with imp, every import named through imp(k)
function Tree:renumber(fn, imp)
  local function conv(typ, v)
    if is(v, RAW) then return v end
    if typ:sub(1, 5) == "soft:" then
      if imp and is(v, SOFT) and v.n > 0 then return TR.Soft(imp(v.n)) end
      return v
    end
    if prefixed(typ, HANDLES) then
      if math.type(v) == "integer" and v > 0 then return fn(v) end
      if imp and math.type(v) == "integer" and v < 0 then return -imp(-v) end
      return v
    end
    if is_list(typ) and is(v, ARRAY) then
      local inner = inner_of(typ)
      for k, x in ipairs(v) do v[k] = conv(inner, x) end
      return v
    end
    if is(v, VARIANT) then
      v.value = conv(v.type, v.value)
      return v
    end
    if is(v, STRUCT) then
      for _, p in ipairs(v) do p.value = conv(p.type, p.value) end
    end
    return v
  end
  for _, o in ipairs(self.objects) do
    for _, props in ipairs({o.props or {}, o.args or {}}) do
      for _, p in ipairs(props) do p.value = conv(p.type, p.value) end
    end
    for _, ev in ipairs(o.events or {}) do
      for _, p in ipairs(ev.props) do p.value = conv(p.type, p.value) end
    end
    if o.parent and o.parent ~= 0 then o.parent = fn(o.parent) end
  end
end

function Tree:remove(n)
  local gone = {[n] = true}
  for _, k in ipairs(self:under(n)) do gone[k] = true end
  local new, k, keep = {}, 0, {}
  for i, o in ipairs(self.objects) do
    if not gone[i] then
      k = k + 1
      new[i] = k
      keep[#keep + 1] = o
    end
  end
  self.objects = keep
  self:renumber(function(i) return new[i] or 0 end)
end

local function deepcopy(x, memo)
  if type(x) ~= "table" then return x end
  memo = memo or {}
  if memo[x] then return memo[x] end
  local out = {}
  memo[x] = out
  for k, v in pairs(x) do out[k] = deepcopy(v, memo) end
  return setmetatable(out, getmetatable(x))
end
TR.deepcopy = deepcopy

local function fresh_guids(objs)
  local function fresh(props)
    for _, p in ipairs(props or {}) do
      if p.type == "CGUID" and (p.name == "guid" or p.name == "GUID") then
        p.value = TR.new_guid()
      elseif is(p.value, STRUCT) then
        fresh(p.value)
      end
    end
  end
  for _, o in ipairs(objs) do
    if not TR.KEEP_GUID[o.cls] then fresh(o.props) end
  end
end

-- the objects object n's values point at (+n handles)
function Tree:refs(n)
  local out = {}
  local function walk(typ, v)
    if prefixed(typ, HANDLES) and math.type(v) == "integer" and v > 0 then
      out[#out + 1] = v
    elseif is_list(typ) and is(v, ARRAY) then
      local inner = inner_of(typ)
      for _, x in ipairs(v) do walk(inner, x) end
    elseif is(v, VARIANT) then
      walk(v.type, v.value)
    elseif is(v, STRUCT) then
      for _, q in ipairs(v) do walk(q.type, q.value) end
    end
  end
  local o = self:obj(n)
  for _, props in ipairs({o.props or {}, o.args or {}}) do
    for _, q in ipairs(props) do walk(q.type, q.value) end
  end
  return out
end

-- objects ns, everything under them, and the journal paths they name
function Tree:with_parts(ns)
  local olds, have = {}, {}
  local todo = {}
  for _, n in ipairs(ns) do todo[#todo + 1] = n end
  while #todo > 0 do
    local n = table.remove(todo, 1)
    local list = {n}
    for _, k in ipairs(self:under(n)) do list[#list + 1] = k end
    for _, k in ipairs(list) do
      if not have[k] then
        have[k] = true
        olds[#olds + 1] = k
        for _, r in ipairs(self:refs(k)) do
          if not have[r] and TR.KEEP_GUID[self:obj(r).cls] then todo[#todo + 1] = r end
        end
      end
    end
  end
  return olds
end

-- a copy of object n and everything under it, appended: new GUIDs, its parent `parent` (default: n's)
function Tree:copy(n, parent)
  local olds = self:with_parts({n})
  local base = #self.objects
  local new = {}
  for k, old in ipairs(olds) do new[old] = base + k end
  local copies = {}
  for k, old in ipairs(olds) do copies[k] = deepcopy(self:obj(old)) end
  local keep = self.objects
  self.objects = copies
  self:renumber(function(i) return new[i] or i end)
  self.objects = keep
  for _, c in ipairs(copies) do self.objects[#self.objects + 1] = c end
  copies[1].parent = parent == nil and self:obj(n).parent or parent
  fresh_guids(copies)
  return new[n]
end

-- an import of another file as one of this file's (the same one if it has it) -> its number here
local function importer(self, other)
  return function(k)
    if not (k > 0 and k <= #other.f.imports) then return 0 end
    local im = other.f.imports[k]
    for i, mine in ipairs(self.f.imports) do
      if mine[1] == im[1] and mine[2] == im[2] then return i end
    end
    self.f.imports[#self.f.imports + 1] = {im[1], im[2], im[3]}
    return #self.f.imports
  end
end

-- objects olds of another file, exactly those, appended in that order: handles between them kept, a handle to another
-- object of that file through outside[n] (a number here; none: 0), parents the same way -> {old number = new}
function Tree:adopt_set(other, olds, outside)
  local base = #self.objects
  local new = {}
  for k, old in ipairs(olds) do new[old] = base + k end
  local copies = {}
  for k, old in ipairs(olds) do copies[k] = deepcopy(other:obj(old)) end
  local keep = self.objects
  self.objects = copies
  self:renumber(function(i) return new[i] or (outside and outside[i]) or 0 end, importer(self, other))
  self.objects = keep
  for _, c in ipairs(copies) do self.objects[#self.objects + 1] = c end
  fresh_guids(copies)
  return new
end

-- adopt for several objects of another file at once: handles between them kept -> their new numbers, in order
function Tree:adopt_many(other, ns, parent)
  parent = parent or 0
  local olds = other:with_parts(ns)
  local base = #self.objects
  local new = {}
  for k, old in ipairs(olds) do new[old] = base + k end
  local copies = {}
  for k, old in ipairs(olds) do copies[k] = deepcopy(other:obj(old)) end
  local imp = importer(self, other)
  local keep = self.objects
  self.objects = copies
  self:renumber(function(i) return new[i] or 0 end, imp)
  self.objects = keep
  for _, c in ipairs(copies) do self.objects[#self.objects + 1] = c end
  for _, n in ipairs(ns) do self.objects[new[n]].parent = parent end
  fresh_guids(copies)
  local out = {}
  for k, n in ipairs(ns) do out[k] = new[n] end
  return out
end
function Tree:adopt(other, n, parent) return self:adopt_many(other, {n}, parent)[1] end

return TR
