-- Lip sync in the game's own form (lipsync.py). radish makes a CR2W (CSkeletalAnimation +
-- CAnimationBufferBitwiseCompressed); the game's .w3speech files hold the same animation raw:
--   f32 frames per second, f32 duration
--   bit6 bone count, per bone: position, orientation              (the scale is not stored)
--   bit6 track count, per track: one record
--   bit6 data size, the data (the bytes of the CR2W's data array)
--   u32 frame count, f32 dt
-- a record (16 bytes): f32 dt, i8 compression, u8 0, u16 frames, u32 data address, u32 fallback address.
--   LS.read_cr2w(data) -> {fps, duration, bones, tracks, data, frames, dt}   LS.write_raw(a)   LS.read_raw(data)
--   LS.to_game(lipsync) -> the raw form (a CR2W converted, raw bytes and empty kept)
local CR = require("conjunction.cr2w")
local WS = require("conjunction.w3strings")
local LS = {}

LS.RECORD = {"dt", "compression", "numFrames", "dataAddr", "dataAddrFallback"}

local struct_at
local function value(c, typ, v)
  if typ == "Float" then return (string.unpack("<f", v)) end
  if typ == "Int8" then return (string.unpack("<i1", v)) end
  if typ == "Uint16" then return (string.unpack("<I2", v)) end
  if typ == "Uint32" then return (string.unpack("<I4", v)) end
  if typ:sub(1, 6) == "array:" and typ:sub(-5) == ",Int8" then
    return v:sub(5, 4 + string.unpack("<I4", v))
  end
  if typ:sub(1, 6) == "array:" then
    local n, i, out = string.unpack("<I4", v), 4, {}
    for _ = 1, n do
      local item
      item, i = struct_at(c, v, i)
      out[#out + 1] = item
    end
    return out
  end
  if typ:sub(1, #"SAnimationBufferBitwiseCompressed") == "SAnimationBufferBitwiseCompressed" then
    return (struct_at(c, v, 0))                 -- (the records; enums and settings stay bytes)
  end
  return {bytes = v}
end

-- a serialized struct at i (0-based: a 0 byte, properties, a 0 name) -> {name = value}, the offset after it
struct_at = function(c, data, i)
  local out = {}
  i = i + 1
  while true do
    local nm = string.unpack("<I2", data, i + 1)
    if nm == 0 then return out, i + 2 end
    local tp, sz = string.unpack("<I2I4", data, i + 3)
    out[c.names[nm + 1]] = value(c, c.names[tp + 1], data:sub(i + 9, i + 4 + sz))
    i = i + 4 + sz
  end
end

-- radish's lip sync CR2W -> {fps, duration, bones, tracks, data, frames, dt}
function LS.read_cr2w(data)
  local c = CR.parse(data)
  local anim, buf
  for _, e in ipairs(c.exports) do
    local props = struct_at(c, e[5], 0)
    if e[1] == "CSkeletalAnimation" then anim = props
    elseif e[1] == "CAnimationBufferBitwiseCompressed" then buf = props end
  end
  if buf == nil then
    error(require("conjunction.questgen").ValueError("no CAnimationBufferBitwiseCompressed in the lip sync"), 0)
  end
  local dt = buf.dt
  if dt == nil then dt = 1 / 30 end
  local fps = (anim or {}).framesPerSecond
  if fps == nil then fps = 1 / dt end
  local d = buf.data
  return {fps = fps, duration = buf.duration or 0.0, bones = buf.bones or {}, tracks = buf.tracks or {},
          data = type(d) == "string" and d or (type(d) == "table" and d.bytes) or "", frames = buf.numFrames or 0, dt = dt}
end

local function record(r)
  r = r or {}
  return string.pack("<fi1I1I2I4I4", r.dt or 0.0, r.compression or 0, 0, r.numFrames or 0, r.dataAddr or 0,
                     r.dataAddrFallback or 0)
end

function LS.write_raw(a)
  local out = {string.pack("<ff", a.fps, a.duration), WS.bit6_write(#a.bones)}
  for _, b in ipairs(a.bones) do out[#out + 1] = record(b.position) .. record(b.orientation) end
  out[#out + 1] = WS.bit6_write(#a.tracks)
  for _, t in ipairs(a.tracks) do out[#out + 1] = record(t) end
  out[#out + 1] = WS.bit6_write(#a.data) .. a.data
  out[#out + 1] = string.pack("<I4f", a.frames, a.dt)
  return table.concat(out)
end

-- the game's raw lip sync -> the same table as read_cr2w
function LS.read_raw(data)
  local fps, duration = string.unpack("<ff", data)
  local function rec(i)
    local dt, comp, _z, frames, addr, fb = string.unpack("<fi1I1I2I4I4", data, i)
    return {dt = dt, compression = comp, numFrames = frames, dataAddr = addr, dataAddrFallback = fb}
  end
  local nb, i = WS.bit6(data, 9)
  local bones = {}
  for k = 0, nb - 1 do bones[k + 1] = {position = rec(i + 32 * k), orientation = rec(i + 32 * k + 16)} end
  local nt
  nt, i = WS.bit6(data, i + 32 * nb)
  local tracks = {}
  for k = 0, nt - 1 do tracks[k + 1] = rec(i + 16 * k) end
  local size
  size, i = WS.bit6(data, i + 16 * nt)
  local frames, dt = string.unpack("<I4f", data, i + size)
  return {fps = fps, duration = duration, bones = bones, tracks = tracks, data = data:sub(i, i + size - 1),
          frames = frames, dt = dt}
end

function LS.to_game(lipsync)
  if lipsync:sub(1, 4) == "CR2W" then return LS.write_raw(LS.read_cr2w(lipsync)) end
  return lipsync
end

return LS
