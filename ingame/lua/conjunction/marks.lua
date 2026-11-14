-- The maker's mark inside a quest (marks.py): nothing added that one could find and cut out - the project's seed (the
-- maker's signature of its uid) derives the built quest's GUIDs, and a placed object's position carries a digit below
-- the millimetre, its rotation one below the hundredth of a degree, worked out from the seed of who placed it.
--   MK.ensure(project) -> changed     a uid, and for a project without one the active profile's mark (meta "mark")
--   MK.project_seed(meta) -> hex|nil  MK.seed_is_theirs(meta) -> bool
--   MK.stamp(project, pos, rot) -> pos, rot     MK.stamp_values(seed_hex, pos, rot)
--   MK.object_score / objects_marked / objects_verdict / verdict as marks.py
local NUM = require("conjunction.pynum")
local Y = require("conjunction.yaml")
local MK = {}

MK.POS_STEP = 0.001
MK.ROT_STEP = 0.01
MK.KEPT = 1024.0

-- uuid.uuid4().hex: 16 random bytes, the version (4) and the variant (10xx) set
function MK.uuid4_hex()
  local h = w3.plugin.cj_random("16")
  local b = {}
  for x in h:gmatch("%x%x") do b[#b + 1] = tonumber(x, 16) end
  b[7] = (b[7] & 0x0F) | 0x40
  b[9] = (b[9] & 0x3F) | 0x80
  local out = {}
  for i, v in ipairs(b) do out[i] = string.format("%02x", v) end
  return table.concat(out)
end

local function present(v) return v ~= nil and v ~= Y.null and v ~= false and v ~= "" end

function MK.ensure(project)
  local ID = require("conjunction.identity")
  local changed = false
  if not present(project.meta.uid) then
    project.meta.uid = MK.uuid4_hex()
    changed = true
  end
  if not present(project.meta.mark) then
    local p = ID.active()
    if p then
      project.meta.mark = Y.map({"key", p.public, "seed", p:project_seed(project.meta.uid)})
      changed = true
    end
  end
  if changed then project:save_meta() end
  return changed
end

function MK.project_seed(meta)
  meta = meta and (meta.meta or meta) or {}
  local m = meta.mark
  if type(m) ~= "table" or not present(m.seed) then return nil end
  local s = tostring(m.seed)
  if #s % 2 ~= 0 or s:find("[^%x]") then return nil end
  return s
end

function MK.seed_is_theirs(meta)
  local ID = require("conjunction.identity")
  local m = type(meta) == "table" and meta.mark
  if type(m) ~= "table" or m.key == nil or m.seed == nil or meta.uid == nil then return false end
  return ID.verify(tostring(m.key), "cj-mark/1|" .. tostring(meta.uid), tostring(m.seed))
end

local function deg(v) return (v + 0.0) % 360.0 end          -- (an angle as the game keeps it: 0 .. 360)
-- the grid point each value sits next to and the digit the seed gives it
local function digits(seed_hex, pos, rot)
  local cell = {}
  for i = 1, 3 do cell[i] = NUM.round(pos[i] / MK.POS_STEP) end
  for i = 1, 3 do cell[3 + i] = math.floor(NUM.round(deg(rot[i]) / MK.ROT_STEP, 6)) end
  local parts = {}
  for i, c in ipairs(cell) do parts[i] = string.format("%d", c) end
  local h = w3.plugin.cj_hmac_sha256(seed_hex, "obj|" .. table.concat(parts, ","))
  local d = {}
  for i = 1, 6 do d[i] = tonumber(h:sub(2 * i - 1, 2 * i), 16) % 10 end
  return cell, d
end
MK.digits = digits

function MK.stamp_values(seed_hex, pos, rot)
  local cell, d = digits(seed_hex, pos, rot)
  local p, r = {}, {}
  for i = 1, 3 do p[i] = NUM.round((cell[i] + (d[i] - 4.5) / 10) * MK.POS_STEP, 7) end
  for i = 1, math.min(3, #rot) do r[i] = NUM.round((cell[3 + i] + (d[3 + i] + 0.5) / 10) * MK.ROT_STEP, 7) end
  return p, r
end

-- pos, rot with the active profile's digits (unchanged without a profile)
function MK.stamp(project, pos, rot)
  local ID = require("conjunction.identity")
  local p = ID.active()
  if p == nil or #pos < 3 or #rot < 3 then return pos, rot end
  if not present(project.meta.uid) then MK.ensure(project) end
  return MK.stamp_values(p:project_seed(project.meta.uid), pos, rot)
end

function MK.object_score(objects, seed_hex)
  local match, total = 0, 0
  for _, o in ipairs(objects) do
    local pos, rot = o.pos or {}, o.rot or {}
    if #pos >= 3 and #rot >= 3 then
      local cell, d = digits(seed_hex, pos, rot)
      for i = 1, 6 do
        local v = i <= 3 and pos[i] or rot[i - 3]
        if not (i <= 3 and math.abs(v) >= MK.KEPT) then
          local got
          if i <= 3 then got = NUM.round((v / MK.POS_STEP - cell[i]) * 10 + 4.5)
          else got = math.floor(NUM.round((deg(v) / MK.ROT_STEP - cell[i]) * 10, 4)) end
          total = total + 1
          if got == d[i] then match = match + 1 end
        end
      end
    end
  end
  return match, total
end
function MK.objects_marked(objects, seed_hex)
  local k, n = 0, 0
  for _, o in ipairs(objects) do
    local m, t = MK.object_score({o}, seed_hex)
    if t >= 4 then
      n = n + 1
      if m == t then k = k + 1 end
    end
  end
  return k, n
end
function MK.objects_verdict(k, n)
  if n == 0 then return "nothing to look at" end
  return k >= 2 and "yes" or (k == 1 and "likely" or "no")
end
function MK.verdict(match, total, chance)
  chance = chance or 0.1
  if total == 0 then return 0.0, "nothing to look at" end
  local z = (match - total * chance) / math.sqrt(total * chance * (1 - chance))
  if (match == total and total >= 6) or z >= 6 then return z, "yes" end
  if z >= 3 then return z, "likely" end
  return z, "no"
end

return MK
