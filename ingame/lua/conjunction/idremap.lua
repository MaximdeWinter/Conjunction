-- Text ids of their own for every quest (idremap.py): after radish has encoded everything the quest's ids (its id
-- space, 2110000000 + space * 1000 + n) move to a block of their own between 100 000 000 and 2 000 000 000, at a place
-- derived from the quest's id (and a salt). In the encoded files every LocalizedString property and a scene's `sceneId`
-- (a Uint32) is patched in place - in every CR2W of a file; nothing changes length.
--   IR.wide_base(qid, count, salt)   IR.remap_bytes(data, lo, hi, base) -> bytes, moved   IR.remap_file(path, ...)
--   IR.remap_tree(root, lo, hi, base) -> moved    IR.remap_ids({id = x}, lo, hi, base)
local CR = require("conjunction.cr2w")
local IR = {}

IR.LOW, IR.HIGH, IR.STEP = 100000000, 2000000000, 100
IR.EXTS = {".w2scene", ".journal", ".w2quest", ".w2phase", ".w2l", ".w2ent", ".w2comm", ".reddlc", ".w2behtree"}

local function crc(s) return require("conjunction.py").crc32(s) end

-- the first id of the quest's block: a multiple of 100 from a hash of its id (+ salt), room for count
function IR.wide_base(qid, count, salt)
  count, salt = count or 1000, salt or ""
  local slots = (IR.HIGH - IR.LOW - count) // IR.STEP
  local h = crc(qid .. "|" .. salt)
  h = (h * 2654435761 + crc(salt .. "|" .. qid .. "|w3s")) & 0xFFFFFFFFFFFF
  return IR.LOW + (h % slots) * IR.STEP
end

-- values lo..hi become base + (value - lo) -> the new bytes, how many moved
function IR.remap_bytes(data, lo, hi, base)
  local buf = data
  local starts, i = {}, 1
  while true do
    local a = buf:find("CR2W", i, true)
    if not a then break end
    starts[#starts + 1] = a - 1
    i = a + 4
  end
  local moved = 0
  for _, s in ipairs(starts) do
    local ok, f = pcall(CR.parse, buf:sub(s + 1))
    local names = ok and f.names or nil
    if names and #names > 0 then
      local types, u32, scene_id, list = {}, {}, {}, {}
      local any_types, any_u32, any_scene = false, false, false
      for k, n in ipairs(names) do
        if n == "LocalizedString" then types[k - 1] = true any_types = true end
        if n == "Uint32" then u32[k - 1] = true any_u32 = true end
        if n == "sceneId" then scene_id[k - 1] = true any_scene = true end
      end
      if any_types or (any_u32 and any_scene) then
        for t in pairs(types) do list[#list + 1] = t end
        if any_scene then for t in pairs(u32) do if not types[t] then list[#list + 1] = t end end end
        table.sort(list)
        for _, t in ipairs(list) do
          local pat = string.pack("<I2I4", t, 8)     -- type, size 8 - the name before it, the value after
          local j = buf:find(pat, s + 7, true)
          while j and j - 1 + 10 <= #buf do
            local at = j - 3                          -- (0-based: the name's offset)
            if types[t] or scene_id[string.unpack("<I2", buf, at + 1)] then
              local v = string.unpack("<I4", buf, at + 9)
              if lo <= v and v <= hi then
                buf = buf:sub(1, at + 8) .. string.pack("<I4", base + (v - lo)) .. buf:sub(at + 13)
                moved = moved + 1
              end
            end
            j = buf:find(pat, j + 1, true)
          end
        end
      end
    end
  end
  return buf, moved
end

function IR.remap_file(path, lo, hi, base)
  local data = assert(w3.fs.read(path))
  local new, moved = IR.remap_bytes(data, lo, hi, base)
  if moved > 0 then
    assert(w3.fs.write(path .. ".tmp", new))
    if w3.fs.exists(path) then w3.fs.remove(path) end
    assert(w3.fs.rename(path .. ".tmp", path))
  end
  return moved
end

-- every encoded file under root -> how many values moved
function IR.remap_tree(root, lo, hi, base)
  local moved = 0
  local function walk(dir)
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local p = dir .. "\\" .. e.name
      if e.dir then walk(p)
      else
        local low = e.name:lower()
        for _, x in ipairs(IR.EXTS) do
          if low:sub(-#x) == x then moved = moved + IR.remap_file(p, lo, hi, base) break end
        end
      end
    end
  end
  walk(root)
  return moved
end

-- {id = x} with the quest's ids moved (others kept)
function IR.remap_ids(ids, lo, hi, base)
  local out = {}
  for i, v in pairs(ids) do
    if lo <= i and i <= hi then out[base + (i - lo)] = v else out[i] = v end
  end
  return out
end

return IR
