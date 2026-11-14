-- What changed in a project between two history steps (changes.py): each step keeps a small picture of the project
-- (its project.yml, its places, a fingerprint of every other file) in <project>\.cj_history\state.json; the next step
-- compares against it and names the changes in plain words ("camp: 2 objects placed, 1 moved").
--   CH.state(path) -> picture   CH.describe(old, new) -> {line}   CH.load(path) / CH.save(path, picture)
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local NUM = require("conjunction.pynum")
local PYS = require("conjunction.pystr")
local DL = require("conjunction.difflib")
local CH = {}

CH.DIR = ".cj_history"
CH.FILE = "state.json"
CH.BUILT = "built.json"                 -- the picture at the last Build & Play (CH.unchanged_since_build)
CH.SKIP_DIRS = {build = true, parked = true, versions = true, [".git"] = true, __pycache__ = true, [".cj_history"] = true}
CH.QUIET = {run = true, uid = true, mark = true}
CH.MAX_LINES = 40

-- Python's == over what YAML and JSON give (1 == 1.0, True == 1, dicts without their order)
local function is_list(t) return Y.is_list(t) or (type(t) == "table" and not Y.is_map(t) and (t[1] ~= nil or next(t) == nil)) end
local function eq(a, b)
  if a == nil then a = Y.null end
  if b == nil then b = Y.null end
  local ta, tb = type(a), type(b)
  if ta == "boolean" then a, ta = a and 1 or 0, "number" end
  if tb == "boolean" then b, tb = b and 1 or 0, "number" end
  if ta ~= tb then return false end
  if ta ~= "table" then return a == b end
  if a == Y.null or b == Y.null then return a == b end
  local la, lb = is_list(a), is_list(b)
  if la ~= lb then return false end
  if la then
    if #a ~= #b then return false end
    for i = 1, #a do if not eq(a[i], b[i]) then return false end end
    return true
  end
  for k, v in pairs(a) do if b[k] == nil or not eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
CH.eq = eq
local function get(t, k) if type(t) == "table" and t ~= Y.null then return t[k] end end
local function pystr(v)                        -- str(v)
  if v == nil or v == Y.null then return "None" end
  if v == true then return "True" elseif v == false then return "False" end
  if type(v) == "number" then return NUM.str(v) end
  return tostring(v)
end
local function truthy(v)
  if v == nil or v == Y.null or v == false or v == 0 or v == "" then return false end
  if type(v) == "table" then return next(v) ~= nil end
  return true
end
local function keys_sorted(...)
  local set, out = {}, {}
  for _, t in ipairs({...}) do
    if type(t) == "table" and t ~= Y.null then for k in pairs(t) do if not set[k] then set[k] = true out[#out + 1] = k end end end
  end
  table.sort(out)
  return out
end

-- --- the picture
local function files(root)
  local out = Y.map()
  local function walk(dir, rel)
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local path, r = dir .. "\\" .. e.name, rel == "" and e.name or (rel .. "/" .. e.name)
      if e.dir then
        if not CH.SKIP_DIRS[e.name] then walk(path, r) end
      elseif e.name:sub(-4) ~= ".tmp" and e.name ~= "history.json" then
        out[r] = w3.plugin.cj_sha256_parts("F:" .. path):sub(1, 16)
      end
    end
  end
  walk(root, "")
  return out
end
function CH.state(path)
  local meta, places = Y.map(), Y.map()
  local ok, m = pcall(Y.read, path .. "\\project.yml")
  if ok and type(m) == "table" then meta = m end
  local pdir = path .. "\\places"
  local names = {}
  for _, e in ipairs(w3.fs.isdir(pdir) and w3.fs.list(pdir) or {}) do
    if e.name:sub(-4) == ".yml" then names[#names + 1] = e.name end
  end
  table.sort(names)
  for _, n in ipairs(names) do
    local ok2, d = pcall(Y.read, pdir .. "\\" .. n)
    places[n:sub(1, -5)] = (ok2 and truthy(d)) and d or Y.map()
  end
  local m2 = Y.map()
  for _, k in ipairs(Y.keys(meta)) do if not CH.QUIET[k] then m2[k] = meta[k] end end
  return Y.map({"meta", m2, "places", places, "files", files(path)})
end
function CH.load(path, file)
  local ok, d = pcall(J.read, path .. "\\" .. CH.DIR .. "\\" .. (file or CH.FILE))
  if ok and type(d) == "table" then return d end
  return nil
end
function CH.save(path, st, file)
  local d = path .. "\\" .. CH.DIR
  if not w3.fs.isdir(d) then w3.fs.mkdir(d) end
  local p = d .. "\\" .. (file or CH.FILE)
  assert(w3.fs.write(p .. ".tmp", J.encode(st, {ensure_ascii = false})))
  w3.fs.remove(p)
  assert(w3.fs.rename(p .. ".tmp", p))
end

-- a Build & Play went in: the project's picture now (a test that starts at a step: none - the next build is a whole
-- one again)
function CH.built(path, test)
  local p = path .. "\\" .. CH.DIR .. "\\" .. CH.BUILT
  if test then
    if w3.fs.exists(p) then w3.fs.remove(p) end
    return
  end
  CH.save(path, CH.state(path), CH.BUILT)
end
-- nothing changed since the last Build & Play (MaximdeWinter 23.10.: a second click by mistake built it all again)
function CH.unchanged_since_build(path)
  local old = CH.load(path, CH.BUILT)
  if not old then return false end
  return #CH.describe(old, J.decode(J.encode(CH.state(path), {ensure_ascii = false}))) == 0
end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end
-- " ".join(str(text).split()), at most n letters
local function short(text, n)
  n = n or 40
  local words = {}
  for w in pystr(text):gmatch("%S+") do words[#words + 1] = w end
  local t = table.concat(words, " ")
  local len = utf8.len(t) or #t
  if len <= n then return t end
  local cut = utf8.offset(t, n - 3 + 1) or (#t + 1)
  return t:sub(1, cut - 1) .. "..."
end

-- --- places
local function obj_key(o)
  local pos = {}
  local p = get(o, "pos")
  for i = 1, math.min(3, type(p) == "table" and #p or 0) do pos[i] = string.format("%.17g", NUM.round(p[i] + 0.0, 3)) end
  local t = get(o, "template")
  return PYS.lower(pystr(t == nil and "" or t)), table.concat(pos, ",")
end
local function place(name, old, new)
  local oo, no = get(old, "objects"), get(new, "objects")
  oo = truthy(oo) and oo or {}
  no = truthy(no) and no or {}
  local ko, kn = {}, {}
  for i, o in ipairs(oo) do local a, b = obj_key(o) ko[i] = {a, b} end
  for j, o in ipairs(no) do local a, b = obj_key(o) kn[j] = {a, b} end
  local left_o, left_n = {}, {}
  for i = 1, #oo do left_o[#left_o + 1] = i end
  for j = 1, #no do left_n[#left_n + 1] = j end
  local function remove(l, v) for k, x in ipairs(l) do if x == v then table.remove(l, k) return end end end
  local changed = 0
  local snap = {table.unpack(left_o)}
  for _, i in ipairs(snap) do                    -- the same object at the same spot
    for _, j in ipairs(left_n) do
      if ko[i][1] == kn[j][1] and ko[i][2] == kn[j][2] then
        if not eq(oo[i], no[j]) then changed = changed + 1 end
        remove(left_o, i)
        remove(left_n, j)
        break
      end
    end
  end
  local moved = 0
  snap = {table.unpack(left_o)}
  for _, i in ipairs(snap) do                    -- the same object somewhere else
    for _, j in ipairs(left_n) do
      if ko[i][1] == kn[j][1] then
        moved = moved + 1
        remove(left_o, i)
        remove(left_n, j)
        break
      end
    end
  end
  local parts = {}
  if #left_n > 0 then parts[#parts + 1] = plural(#left_n, "object") .. " placed" end
  if moved > 0 then parts[#parts + 1] = moved .. " moved" end
  if changed > 0 then parts[#parts + 1] = changed .. " changed" end
  if #left_o > 0 then parts[#parts + 1] = #left_o .. " removed" end
  for _, k in ipairs(keys_sorted(old, new)) do
    if k ~= "objects" and not eq(get(old, k), get(new, k)) then parts[#parts + 1] = k .. " changed" end
  end
  return #parts > 0 and (name .. ": " .. table.concat(parts, ", ")) or nil
end

-- --- quests
local function quests(meta)
  local list = {}
  local q = get(meta, "quest")
  if Y.is_map(q) then list[#list + 1] = q end
  local qs = get(meta, "quests")
  for _, x in ipairs(truthy(qs) and qs or {}) do if Y.is_map(x) then list[#list + 1] = x end end
  local out = {keys = {}, v = {}}
  for k, x in ipairs(list) do
    local t = get(x, "title")
    t = truthy(t) and pystr(t) or ("quest " .. k)
    if out.v[t] == nil then out.keys[#out.keys + 1] = t end
    out.v[t] = x
  end
  return out
end
local function step_sig(s)
  if not Y.is_map(s) or next(s) == nil then return "?", "" end
  local kind = Y.keys(s)[1]
  local body = Y.is_map(s[kind]) and s[kind] or {}
  local text = get(body, "text")
  if not truthy(text) then text = get(body, "title") end
  if not truthy(text) then text = "" end
  return kind, pystr(text)
end
local function step_label(n, s)
  local kind, text = step_sig(s)
  return "step " .. n .. " (" .. kind .. (text ~= "" and (": " .. short(text)) or "") .. ")"
end
local function step_change(a, b)
  local ka, ta = step_sig(a)
  local kb, tb = step_sig(b)
  if ka ~= kb then return "now " .. kb end
  local ba = Y.is_map(get(a, ka)) and a[ka] or {}
  local bb = Y.is_map(get(b, kb)) and b[kb] or {}
  local what = {}
  if not eq(get(ba, "dialogue"), get(bb, "dialogue")) then what[#what + 1] = "dialogue" end
  if ta ~= tb then what[#what + 1] = "text" end
  local rest = {}
  for _, k in ipairs(keys_sorted(ba, bb)) do
    if k ~= "dialogue" and k ~= "text" and not eq(get(ba, k), get(bb, k)) then rest[#rest + 1] = k end
  end
  if #rest > 0 then what[#what + 1] = table.concat(rest, ", ") end
  return #what > 0 and (table.concat(what, " and ") .. " changed") or "changed"
end
local function quest(title, old, new)
  local out = {}
  for _, k in ipairs({"title", "type", "description", "items"}) do
    if not eq(get(old, k), get(new, k)) then out[#out + 1] = title .. ": " .. k .. " changed" end
  end
  local so, sn = get(old, "steps"), get(new, "steps")
  so = truthy(so) and so or {}
  sn = truthy(sn) and sn or {}
  local function key(s) local k, t = step_sig(s) return k .. "\0" .. t end
  for _, op in ipairs(DL.opcodes(so, sn, key)) do
    local tag, i1, i2, j1, j2 = op[1], op[2], op[3], op[4], op[5]
    if tag == "equal" then
      for d = 0, i2 - i1 - 1 do
        local i, j = i1 + d, j1 + d
        if not eq(so[i + 1], sn[j + 1]) then
          out[#out + 1] = title .. ": " .. step_label(j + 1, sn[j + 1]) .. " " .. step_change(so[i + 1], sn[j + 1])
        end
      end
    elseif tag == "replace" and i2 - i1 == j2 - j1 then
      for d = 0, i2 - i1 - 1 do
        local i, j = i1 + d, j1 + d
        out[#out + 1] = title .. ": " .. step_label(j + 1, sn[j + 1]) .. " " .. step_change(so[i + 1], sn[j + 1])
      end
    else
      for i = i1, i2 - 1 do out[#out + 1] = title .. ": " .. step_label(i + 1, so[i + 1]) .. " removed" end
      for j = j1, j2 - 1 do out[#out + 1] = title .. ": " .. step_label(j + 1, sn[j + 1]) .. " added" end
    end
  end
  -- the graph's nodes (by id; where one stands is no change) and its wires
  local no, nn = get(old, "nodes"), get(new, "nodes")
  no = truthy(no) and no or {}
  nn = truthy(nn) and nn or {}
  for _, id in ipairs(keys_sorted(no, nn)) do
    local a, b = get(no[id] or {}, "step"), get(nn[id] or {}, "step")
    if no[id] == nil then out[#out + 1] = title .. ": " .. step_label(id, b) .. " added"
    elseif nn[id] == nil then out[#out + 1] = title .. ": " .. step_label(id, a) .. " removed"
    elseif not eq(a, b) then out[#out + 1] = title .. ": " .. step_label(id, b) .. " " .. step_change(a, b) end
  end
  if not eq(get(old, "links"), get(new, "links")) then out[#out + 1] = title .. ": links changed" end
  return out
end

function CH.describe(old, new)
  if not truthy(old) then return {} end
  local out = {}
  local om, nm = get(old, "meta"), get(new, "meta")
  om = truthy(om) and om or {}
  nm = truthy(nm) and nm or {}
  local oq, nq = quests(om), quests(nm)
  for _, t in ipairs(nq.keys) do if oq.v[t] == nil then out[#out + 1] = "quest " .. t .. " added" end end
  for _, t in ipairs(oq.keys) do
    if nq.v[t] == nil then out[#out + 1] = "quest " .. t .. " removed"
    else for _, l in ipairs(quest(t, oq.v[t], nq.v[t])) do out[#out + 1] = l end end
  end
  for _, k in ipairs(keys_sorted(om, nm)) do
    if k ~= "quest" and k ~= "quests" and not eq(get(om, k), get(nm, k)) then out[#out + 1] = "project " .. k .. " changed" end
  end
  local op, np = get(old, "places"), get(new, "places")
  op = truthy(op) and op or {}
  np = truthy(np) and np or {}
  for _, name in ipairs(keys_sorted(op, np)) do
    if op[name] == nil then
      local objs = get(np[name], "objects")
      local n = truthy(objs) and #objs or 0
      out[#out + 1] = "place " .. name .. " added" .. (n > 0 and (" (" .. plural(n, "object") .. ")") or "")
    elseif np[name] == nil then
      out[#out + 1] = "place " .. name .. " removed"
    elseif not eq(op[name], np[name]) then
      local line = place(name, op[name], np[name])
      if line then out[#out + 1] = line end
    end
  end
  local of, nf = get(old, "files"), get(new, "files")
  of = truthy(of) and of or {}
  nf = truthy(nf) and nf or {}
  for _, rel in ipairs(keys_sorted(of, nf)) do
    if rel ~= "project.yml" and rel:sub(1, 7) ~= "places/" then
      if of[rel] == nil then out[#out + 1] = "file " .. rel .. " added"
      elseif nf[rel] == nil then out[#out + 1] = "file " .. rel .. " removed"
      elseif of[rel] ~= nf[rel] then out[#out + 1] = "file " .. rel .. " changed" end
    end
  end
  if #out > CH.MAX_LINES then
    local more = #out - CH.MAX_LINES
    local cut = {}
    for i = 1, CH.MAX_LINES do cut[i] = out[i] end
    cut[#cut + 1] = "and " .. more .. " more"
    out = cut
  end
  return out
end

return CH
