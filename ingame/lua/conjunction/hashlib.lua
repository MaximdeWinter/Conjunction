-- hashlib's hexdigest through cj_core (Windows' CNG): H.md5(text), H.sha1(text), H.sha256(text)
local H = {}
local function hex(alg, text)
  local f = w3.plugin and w3.plugin.cj_hash
  if not f then error("cj_core is not loaded: no w3.plugin.cj_hash", 3) end
  return f(alg, text)
end
function H.md5(text) return hex("md5", text) end
function H.sha1(text) return hex("sha1", text) end
function H.sha256(text) return hex("sha256", text) end

-- hashlib.md5(data).digest() of any bytes (the plugin's arguments end at a 0 byte: this one is Lua's own, RFC 1321)
local MD5_K, MD5_S = {}, {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14,
                          20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6,
                          10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21}
for i = 0, 63 do MD5_K[i + 1] = math.floor(math.abs(math.sin(i + 1)) * 2 ^ 32) & 0xFFFFFFFF end
function H.md5_bytes(data)
  local n = #data
  local msg = data .. "\128" .. string.rep("\0", (55 - n) % 64) .. string.pack("<I8", (n * 8) & 0xFFFFFFFFFFFFFFFF)
  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  local M = {}
  for off = 1, #msg, 64 do
    for j = 0, 15 do M[j] = string.unpack("<I4", msg, off + 4 * j) end
    local A, B, C, D = a0, b0, c0, d0
    for i = 0, 63 do
      local F, g
      if i < 16 then F, g = (B & C) | (~B & D), i
      elseif i < 32 then F, g = (D & B) | (~D & C), (5 * i + 1) % 16
      elseif i < 48 then F, g = B ~ C ~ D, (3 * i + 5) % 16
      else F, g = C ~ (B | ~D), (7 * i) % 16 end
      F = (F + A + MD5_K[i + 1] + M[g]) & 0xFFFFFFFF
      A, D, C = D, C, B
      local s = MD5_S[i + 1]
      B = (B + (((F << s) | (F >> (32 - s))) & 0xFFFFFFFF)) & 0xFFFFFFFF
    end
    a0, b0, c0, d0 = (a0 + A) & 0xFFFFFFFF, (b0 + B) & 0xFFFFFFFF, (c0 + C) & 0xFFFFFFFF, (d0 + D) & 0xFFFFFFFF
  end
  return string.pack("<I4I4I4I4", a0, b0, c0, d0)
end
return H
