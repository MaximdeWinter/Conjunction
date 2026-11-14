-- The same GUIDs on every build (stable_ids.py): each GUID a file defines (an object's own `guid`) becomes one
-- derived from the quest id, the file and what defines it (its class, its name - `name` or `baseName` - and how many
-- came before with the same), and every place that holds the old value gets the new one. With the project's mark
-- seed each GUID is an HMAC of that seed instead of a plain hash.
--   SI.stabilize(dlc_dir, qid, log, seed) -> how many replaced      SI.translation(root, old_qid, qid, seed)
--   SI.expected_guids({path below the DLC folder = bytes}, qid, seed) -> {where = {expected, found}}
local CR = require("conjunction.cr2w")
local CE = require("conjunction.cr2w_edit")
local PYS = require("conjunction.pystr")
local SI = {}

SI.EXTS = {".journal", ".w2quest", ".w2phase", ".w2comm", ".w2l", ".reddlc"}
local NAME_PROPS = {name = true, baseName = true}
local H = "[0-9a-f]"
local UUID = H:rep(8) .. "%-" .. H:rep(4) .. "%-" .. H:rep(4) .. "%-" .. H:rep(4) .. "%-" .. H:rep(12)

local function ends_ext(n)
  for _, x in ipairs(SI.EXTS) do if n:sub(-#x) == x then return true end end
  return false
end

local function name_string(f, typ, raw)
  if typ == "CName" then
    local k = #raw >= 2 and string.unpack("<I2", raw) or 0
    return f.names[k + 1] or ""
  end
  if typ == "String" or typ == "StringAnsi" then
    local ok, s = pcall(CE.dstring, raw)
    return ok and s or ""
  end
  return ""
end

local function unhex(h) return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)) end

-- the GUID of a key: md5 of it, or the HMAC-SHA256 with the seed (hex, as MK.project_seed gives it: its
-- first 16 bytes); never all zero
function SI.guid(key, seed)
  local g
  if seed and seed ~= "" then g = unhex(w3.plugin.cj_hmac_sha256(seed, key)):sub(1, 16)
  else g = unhex(w3.plugin.cj_hash("md5", key)) end
  if g:find("[^\0]") then return g end
  return "\1" .. g:sub(2)
end

local function files_under(root)
  local out = {}
  local function walk(dir)
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local p = dir .. "\\" .. e.name
      if e.dir then walk(p) elseif ends_ext(e.name) then out[#out + 1] = p end
    end
  end
  walk(root)
  -- the journal first: it defines what the quest's journal paths point at
  local key = {}
  for _, p in ipairs(out) do key[p] = PYS.lower(p) end
  table.sort(out, function(a, b)
    local ja, jb = a:sub(-8) == ".journal", b:sub(-8) == ".journal"
    if ja ~= jb then return ja end
    return key[a] < key[b]
  end)
  return out
end

local function rel_of(root, p) return PYS.lower((p:sub(#root + 2):gsub("\\", "/"))) end

-- objects whose GUID names another one (a journal path's link: the game's group of characters, a game quest's
-- objective) - not a GUID of their own; rewritten, the link pointed nowhere
SI.REFERENCES = {CJournalPath = true}

-- {class, name, {guid offsets}} of an export: its name (the GUIDs taken out) and the 16-byte guid values (none for a
-- reference, as stabilize and expected_guids skip them; translation: all)
local function defines(f, e, all)
  if not all and SI.REFERENCES[e[1]] then return "", {} end
  local chunk = e[5]
  local props = f:props(chunk)
  local name = ""
  for _, p in ipairs(props) do
    if NAME_PROPS[p[1]] and (p[2] == "CName" or p[2] == "String" or p[2] == "StringAnsi") then
      name = name_string(f, p[2], chunk:sub(p[3] + 1, p[3] + p[4])):gsub(UUID, "")
      break
    end
  end
  local guids = {}
  for _, p in ipairs(props) do
    if p[1] == "guid" and p[2] == "CGUID" and p[4] == 16 then guids[#guids + 1] = chunk:sub(p[3] + 1, p[3] + 16) end
  end
  return name, guids
end

local function replace_plain(s, old, new)
  local out, i = {}, 1
  while true do
    local a = s:find(old, i, true)
    if not a then break end
    out[#out + 1] = s:sub(i, a - 1)
    out[#out + 1] = new
    i = a + #old
  end
  if i == 1 then return s, false end
  out[#out + 1] = s:sub(i)
  return table.concat(out), true
end

-- rewrite the GUIDs under root (the encoded DLC folder) -> how many were replaced
function SI.stabilize(root, qid, log, seed)
  log = log or print
  local files = {}
  for _, p in ipairs(files_under(root)) do
    local data = assert(w3.fs.read(p))
    local ok, f = pcall(CR.parse, data)
    if ok and f:writable() then files[#files + 1] = {p, f} end
  end
  local new_of, order = {}, {}
  for _, pf in ipairs(files) do
    local p, f = pf[1], pf[2]
    local rel = rel_of(root, p)
    local seen = {}
    for _, e in ipairs(f.exports) do
      local name, guids = defines(f, e)
      for _, old in ipairs(guids) do
        if new_of[old] == nil and old:find("[^\0]") then
          local key = rel .. "|" .. e[1] .. "|" .. name
          seen[key] = (seen[key] or 0) + 1
          new_of[old] = SI.guid(qid .. "|" .. key .. "|" .. seen[key], seed)
          order[#order + 1] = old
        end
      end
    end
  end
  if #order == 0 then return 0 end
  local count = 0
  for _, pf in ipairs(files) do
    local p, f = pf[1], pf[2]
    local changed = false
    for _, e in ipairs(f.exports) do
      local chunk = e[5]
      for _, old in ipairs(order) do
        local c
        chunk, c = replace_plain(chunk, old, new_of[old])
        changed = changed or c
      end
      e[5] = chunk
    end
    for _, b in ipairs(f.buffers) do
      local blob = b[3]
      for _, old in ipairs(order) do
        local c
        blob, c = replace_plain(blob, old, new_of[old])
        changed = changed or c
      end
      b[3] = blob
    end
    if changed then
      f.timestamp = 0                           -- (the encode time: the same file for the same quest)
      local out = f:save()
      assert(w3.fs.write(p .. ".tmp", out))
      if w3.fs.exists(p) then w3.fs.remove(p) end
      assert(w3.fs.rename(p .. ".tmp", p))
      count = count + 1
    end
  end
  log(string.format("[build] %s: %d GUIDs made stable in %d files", qid, #order, count))
  return #order
end

-- {GUID a build for old_qid gave = the one qid's gives} for what the files under root (stabilized for qid) define
function SI.translation(root, old_qid, qid, seed)
  local out = {}
  for _, p in ipairs(files_under(root)) do
    local ok, f = pcall(CR.parse, assert(w3.fs.read(p)))
    if ok then
      local rel = rel_of(root, p)
      local old_rel = replace_plain(rel, qid, old_qid)
      local seen = {}
      for _, e in ipairs(f.exports) do
        local name, guids = defines(f, e, true)
        for _, now in ipairs(guids) do
          if now:find("[^\0]") then
            local key = rel .. "|" .. e[1] .. "|" .. name
            seen[key] = (seen[key] or 0) + 1
            if SI.guid(qid .. "|" .. key .. "|" .. seen[key], seed) == now then
              local was = SI.guid(old_qid .. "|" .. old_rel .. "|" .. e[1] .. "|" .. replace_plain(name, qid, old_qid) ..
                                  "|" .. seen[key], seed)
              if was ~= now then out[was] = now end
            end
          end
        end
      end
    end
  end
  return out
end

-- for a built quest's files: {"<path>|<class>|<name>|<n>" = {the GUID the seed gives, the one in the file}}
function SI.expected_guids(files, qid, seed)
  local out, seen_guid = {}, {}
  local rels = {}
  for rel in pairs(files) do rels[#rels + 1] = rel end
  local low = {}
  for _, r in ipairs(rels) do low[r] = PYS.lower(r) end
  table.sort(rels, function(a, b)
    local ja, jb = low[a]:sub(-8) == ".journal", low[b]:sub(-8) == ".journal"
    if ja ~= jb then return ja end
    return low[a] < low[b]
  end)
  for _, rel in ipairs(rels) do
    if ends_ext(low[rel]) then
      local ok, f = pcall(CR.parse, files[rel])
      if ok then
        local r = PYS.lower((rel:gsub("\\", "/")))
        local seen = {}
        for _, e in ipairs(f.exports) do
          local name, guids = defines(f, e)
          for _, g in ipairs(guids) do
            if g:find("[^\0]") and not seen_guid[g] then
              seen_guid[g] = true
              local key = r .. "|" .. e[1] .. "|" .. name
              seen[key] = (seen[key] or 0) + 1
              out[key .. "|" .. seen[key]] = {SI.guid(qid .. "|" .. key .. "|" .. seen[key], seed), g}
            end
          end
        end
      end
    end
  end
  return out
end

return SI
