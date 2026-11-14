-- Check origin: who made something and whether a profile's mark is in it (origin.py; provenance.lua, marks.lua).
--   local r = OR.check(path)    a .w3q, a project folder, a built or installed quest (its DLC folder or a .bundle)
--   r.steps, r.history          the signed history found with it, and its check (PV.check)
--   r.marks                     {{profile name, what, matches, looked at, verdict}} for each own profile
--   r.same_as                   {{own project, objects at its spots to 2 mm, objects}} - holds when marks were rounded
--   r.similar                   {SIM.Match}: own projects alike in content (texts, steps, layout to 5 cm) - holds when
--                               everything else was removed
--   r.maker                     the project's mark: {public key, seed is that key's signature}
-- A history can be cut out of a copy; the marks stay in its GUIDs and placed objects. Only the owner of a key can look
-- for that key's marks (the seed needs the key) - so Check origin looks with the profiles on this PC.
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local PYS = require("conjunction.pystr")
local NUM = require("conjunction.pynum")
local PS = require("conjunction.pysort")
local PV = require("conjunction.provenance")
local MK = require("conjunction.marks")
local SIM = require("conjunction.similar")
local FS = require("conjunction.fsutil")
local OR = {}

OR.TS_MAGIC = "\0OpenTimestamps\0\0Proof\0\xbf\x89\xe2\xe8\x84\xe8\x92\x94"

local function lower(s) return PYS.lower(s) end
local function ends(s, tail) return #s >= #tail and s:sub(-#tail) == tail end
local function count(s, ch) local _, n = s:gsub(ch, "") return n end

local function tmp_dir()
  local d = w3.fs.folder("temp") .. "\\cj_origin_" .. MK.uuid4_hex():sub(1, 10)
  w3.fs.mkdir(d)
  return d
end

-- provenance.from_blob
local function from_blob(data)
  local ok, d = pcall(J.decode, data)
  if ok and type(d) == "table" and not Y.is_list(d) and type(d.steps) == "table" and #d.steps > 0 then return d.steps end
  return {}
end

-- {path below the DLC folder: bytes} of a .bundle on the disk; the DLC folders its paths name into seen
local function bundle_files(bundle, files, seen)
  local PK, PM = require("conjunction.packer"), require("conjunction.packmaker")
  for _, e in ipairs(PK.entries(bundle)) do
    local rel = e[1]:gsub("\\", "/")
    if lower(rel):sub(1, 4) == "dlc/" and count(rel, "/") >= 2 then
      local folder, rest = rel:match("^[^/]*/([^/]*)/(.*)$")
      seen[#seen + 1] = lower(folder)
      rel = rest
    end
    files[rel] = PM.read(bundle, e)
  end
end

-- placed objects as the built layers keep them: {pos, rot} of every entity with a transform in the .w2l files
local function objects_of_layers(files)
  local TR = require("conjunction.cr2w_tree")
  local out = {}
  local rels = {}
  for rel in pairs(files) do rels[#rels + 1] = rel end
  table.sort(rels)
  for _, rel in ipairs(rels) do
    if ends(lower(rel), ".w2l") then
      local ok, t = pcall(TR.Tree, files[rel])
      if ok then
        for _, o in ipairs(t.objects) do
          local tr = o:get("transform")
          if getmetatable(tr) == TR.TRANSFORM and tr.position then
            local r = tr.rotation or {0.0, 0.0, 0.0}
            out[#out + 1] = {pos = {tr.position[1], tr.position[2], tr.position[3]}, rot = {r[1], r[2], r[3]}}
          end
        end
      end
    end
  end
  return out
end

local function objects_of_places(places)
  local out = {}
  for _, place in ipairs(places) do
    if Y.is_map(place) and Y.is_list(place.objects) then
      for _, o in ipairs(place.objects) do if Y.is_map(o) then out[#out + 1] = o end end
    end
  end
  return out
end

local function uid_from_steps(steps)
  for _, s in ipairs(steps or {}) do
    if type(s) == "table" and s.uid ~= nil and s.uid ~= Y.null and s.uid ~= "" and s.uid ~= false then return s.uid end
  end
  return nil
end

-- the uids of this PC's projects (a stolen copy of one of them carries their GUIDs)
local function own_uids()
  local out = {}
  for _, root in ipairs(SIM.projects()) do
    local ok, m = pcall(Y.read, root .. "\\project.yml")
    local u = ok and Y.is_map(m) and m.uid or nil
    if u ~= nil and u ~= Y.null and u ~= "" and u ~= false then out[#out + 1] = u end
  end
  return out
end

local function truthy(v) return v ~= nil and v ~= Y.null and v ~= false and v ~= "" and v ~= 0 end

-- this PC's projects with objects at the same spots (to 2 mm): placed by hand, no two makers hit the same millimetres
-- - it holds when the marks were rounded away -> {{project name, matches, objects looked at}}
function OR.same_spots(objects, skip, tol, least)
  tol, least = tol or 0.002, least or 3
  local pts = {}
  for _, o in ipairs(objects) do
    local pos = o.pos
    if type(pos) == "table" and #pos >= 3 then pts[#pts + 1] = {pos[1], pos[2], pos[3]} end
  end
  if #pts < least then return {} end
  local function r1(v) return NUM.round(v + 0.0, 1) end
  local function key(a, b, c) return string.format("%.17g,%.17g,%.17g", a, b, c) end
  local out = {}
  for _, root in ipairs(SIM.projects()) do
    if SIM.normcase(root) ~= SIM.normcase(skip or "") then
      local own = {}
      for _, f in ipairs(SIM.places_of(root)) do
        for _, p in ipairs(SIM.yaml_objects(f)) do own[#own + 1] = p end
      end
      if #own > 0 then
        local cells = {}
        for _, q in ipairs(own) do
          local k = key(r1(q[1]), r1(q[2]), r1(q[3]))
          cells[k] = cells[k] or {}
          table.insert(cells[k], q)
        end
        local function near(p)
          local k = {r1(p[1]), r1(p[2]), r1(p[3])}
          for _, dx in ipairs({-0.1, 0, 0.1}) do
            for _, dy in ipairs({-0.1, 0, 0.1}) do
              for _, dz in ipairs({-0.1, 0, 0.1}) do
                for _, q in ipairs(cells[key(r1(k[1] + dx), r1(k[2] + dy), r1(k[3] + dz))] or {}) do
                  if math.abs(p[1] - q[1]) <= tol and math.abs(p[2] - q[2]) <= tol and math.abs(p[3] - q[3]) <= tol then
                    return true
                  end
                end
              end
            end
          end
          return false
        end
        local m = 0
        for _, p in ipairs(pts) do if near(p) then m = m + 1 end end
        if m >= least then
          local ok, meta = pcall(Y.read, root .. "\\project.yml")
          local name = ok and Y.is_map(meta) and meta.name or nil
          if not truthy(name) then name = root:match("([^\\]+)$") end
          out[#out + 1] = {tostring(name), m, #pts}
        end
      end
    end
  end
  return PS.sorted(out, function(x) return -x[2] end)
end

function OR.check(path)
  local r = {path = path, kind = "", steps = {}, history = nil, marks = {}, maker = nil, qid = "", notes = {},
             same_as = {}, similar = {}, timestamp = nil}
  local seen = {}
  local files, objects, meta, strings = {}, {}, nil, {}
  local low = lower(path)
  local tmp
  local ok_all, err = pcall(function()
    if ends(low, ".w3q") then
      r.kind = "quest file (.w3q)"
      local LIB = require("conjunction.library")
      local names = LIB.zip_names(path)
      local have = {}
      for _, n in ipairs(names) do have[n] = true end
      for _, n in ipairs(names) do
        if n:sub(1, 4) == "dlc/" and count(n, "/") >= 2 then
          r.qid = n:match("^[^/]*/([^/]*)"):sub(4)
          break
        end
      end
      -- the entries this needs, each into a file of its own
      tmp = tmp_dir()
      local plan, file_of = {}, {}
      local function want(n)
        if not file_of[n] then
          file_of[n] = tmp .. "\\" .. (#plan + 1)
          plan[#plan + 1] = {n, file_of[n]}
        end
      end
      for _, n in ipairs(names) do
        local nl = lower(n)
        local src = n:find("conjunction_source/", 1, true) ~= nil
        if ends(n, "/" .. PV.FILE) and not src then
          want(n)
          local ots = n:sub(1, #n - #PV.FILE) .. "history.ots"
          if have[ots] then want(ots) end
        end
        if ends(nl, ".bundle") then want(n) end
        if ends(nl, ".w3strings") and not src then want(n) end
        if src then
          local rel = n:match("conjunction_source/(.*)$")
          if rel == "project.yml" or (rel:sub(1, 7) == "places/" and ends(rel, ".yml")) then want(n) end
        end
      end
      LIB.zip_extract(path, plan)
      for _, n in ipairs(names) do
        local nl = lower(n)
        local src = n:find("conjunction_source/", 1, true) ~= nil
        if ends(n, "/" .. PV.FILE) and not src then
          r.steps = from_blob(w3.fs.read(file_of[n]) or "")
          local ots = n:sub(1, #n - #PV.FILE) .. "history.ots"
          if have[ots] then                     -- a public timestamp of exactly this history (timestamp.py)
            local o = w3.fs.read(file_of[ots]) or ""
            local M = OR.TS_MAGIC
            local digest = nil
            if o:sub(1, #M) == M and o:sub(#M + 2, #M + 2) == "\x08" then digest = o:sub(#M + 3, #M + 34) end
            local hex = digest and (digest:gsub(".", function(c) return string.format("%02x", c:byte()) end))
            local sha = w3.plugin.cj_sha256_parts("F:" .. file_of[n])
            r.timestamp = (hex ~= nil and hex == sha) and "matches" or "does not match the history"
          end
        end
        if ends(nl, ".bundle") then bundle_files(file_of[n], files, seen) end
        if ends(nl, ".w3strings") and not src then strings[#strings + 1] = w3.fs.read(file_of[n]) end
        if src then
          local rel = n:match("conjunction_source/(.*)$")
          if rel == "project.yml" then
            meta = Y.load(w3.fs.read(file_of[n]) or "")
          elseif rel:sub(1, 7) == "places/" and ends(rel, ".yml") then
            for _, o in ipairs(objects_of_places({Y.load(w3.fs.read(file_of[n]) or "")})) do objects[#objects + 1] = o end
          end
        end
      end
    elseif w3.fs.exists(path .. "\\project.yml") and not w3.fs.isdir(path .. "\\project.yml") then
      r.kind = "project"
      meta = Y.read(path .. "\\project.yml")
      r.steps = PV.read(path)
      r.history = PV.check(r.steps, PV.content_hash(path))
      local places = {}
      for _, f in ipairs(SIM.places_of(path)) do places[#places + 1] = Y.read(f) end
      objects = objects_of_places(places)
      local built = path .. "\\build\\packed"
      if w3.fs.isdir(built) then
        for _, f in ipairs(FS.walk(built)) do
          if ends(f.name, ".bundle") then bundle_files(f.path, files, seen) end
        end
      end
    else
      r.kind = "built quest"
      local found = {}
      if not w3.fs.isdir(path) and ends(low, ".bundle") then
        found = {path}
      elseif w3.fs.isdir(path) then
        local by_dir, dirs = {}, {}
        for _, f in ipairs(FS.walk(path)) do
          local d = f.path:match("^(.*)\\[^\\]*$") or ""
          if not by_dir[d] then by_dir[d] = {} dirs[#dirs + 1] = d end
          table.insert(by_dir[d], f)
          if ends(f.name, ".bundle") then found[#found + 1] = f.path end
        end
        for _, d in ipairs(dirs) do                -- (the first .w3strings of each folder)
          for _, f in ipairs(by_dir[d]) do
            if ends(f.name, ".w3strings") then strings[#strings + 1] = w3.fs.read(f.path) break end
          end
        end
      end
      for _, b in ipairs(found) do
        bundle_files(b, files, seen)
        if r.qid == "" then
          local parts = {}
          for x in b:gsub("/", "\\"):gmatch("[^\\]+") do parts[#parts + 1] = x end
          for k = #parts, 1, -1 do
            local x = parts[k]
            if lower(x):sub(1, 3) == "dlc" and #x > 3 then r.qid = x:sub(4) break end
          end
        end
      end
    end
  end)
  if tmp then FS.rmtree(tmp) end
  if not ok_all then error(err, 0) end
  -- the history that came with its files
  if #r.steps == 0 then
    local rels = {}
    for rel in pairs(files) do rels[#rels + 1] = rel end
    table.sort(rels)
    for _, rel in ipairs(rels) do
      if ends(lower(rel), "conjunction/" .. PV.FILE) then r.steps = from_blob(files[rel]) break end
    end
  end
  local any_file = next(files) ~= nil
  if #objects == 0 and any_file then objects = objects_of_layers(files) end   -- no project with it: its built layers
  if r.qid == "" and #seen > 0 then                 -- the quest's id from its bundle's paths (dlc/dlc<id>/...)
    local d = seen[#seen]
    r.qid = d:sub(1, 3) == "dlc" and d:sub(4) or d
  end
  if r.history == nil and #r.steps > 0 then r.history = PV.check(r.steps) end
  if Y.is_map(meta) and truthy(meta.mark) then
    r.maker = {type(meta.mark) == "table" and meta.mark.key or "", MK.seed_is_theirs(meta)}
  end
  local SI = require("conjunction.stable_ids")
  local uids = own_uids()
  local step_uid = uid_from_steps(r.steps)
  for _, p in ipairs(require("conjunction.identity").profiles()) do
    local seeds, have = {}, {}
    local function add(s) if not have[s] then have[s] = true seeds[#seeds + 1] = s end end
    local muid = Y.is_map(meta) and meta.uid or nil
    if truthy(muid) then add(p:project_seed(muid)) end
    if step_uid and (not Y.is_map(meta) or step_uid ~= meta.uid) then add(p:project_seed(step_uid)) end
    for _, u in ipairs(uids) do add(p:project_seed(u)) end
    local best = nil
    for _, sd in ipairs(seeds) do
      local gm, gt, om, ot = 0, 0, 0, 0
      if any_file and r.qid ~= "" then
        for _, pair in pairs(SI.expected_guids(files, r.qid, sd)) do
          gt = gt + 1
          if pair[1] == pair[2] then gm = gm + 1 end
        end
      end
      if #objects > 0 then om, ot = MK.objects_marked(objects, sd) end
      if best == nil or gm > best[1] or (gm == best[1] and om > best[3]) then best = {gm, gt, om, ot} end
    end
    if best then
      local gm, gt, om, ot = table.unpack(best)
      if gt > 0 then
        r.marks[#r.marks + 1] = {p.name, "GUIDs", gm, gt, gm >= 3 and "yes" or (gm > 0 and "likely" or "no")}
      end
      if ot > 0 then r.marks[#r.marks + 1] = {p.name, "placed objects", om, ot, MK.objects_verdict(om, ot)} end
    end
  end
  r.same_as = OR.same_spots(objects, path)
  local ok, e = pcall(function()                  -- the content itself: texts, steps, layout
    local texts, kinds = {}, {}
    if Y.is_map(meta) and next(meta) ~= nil then texts, kinds = SIM.content_of_meta(meta) end
    if #texts == 0 and #strings > 0 then
      local _, _, t = require("conjunction.w3strings").read(strings[1])
      for _, v in pairs(t) do texts[#texts + 1] = v end
    end
    r.similar = SIM.compare(texts, kinds, objects, path)
  end)
  if not ok then r.notes[#r.notes + 1] = "Content not compared (" .. tostring(e) .. ")" end
  if not any_file and #objects == 0 then r.notes[#r.notes + 1] = "Nothing built found to look for marks in" end
  return r
end

-- the lines under the history (profile_view.CheckOriginDialog.run)
function OR.lines(r)
  local lines = {}
  local WORD = {yes = "Mark of", likely = "Probably the mark of", no = "No mark of"}
  for _, m in ipairs(r.marks) do
    lines[#lines + 1] = string.format("%s %s in the %s (%d of %d)", WORD[m[5]], m[1], m[2], m[3], m[4])
  end
  for _, s in ipairs(r.same_as) do
    lines[#lines + 1] = string.format("%d of %d objects at the same spots as the project %s (to 2 mm)", s[2], s[3], s[1])
  end
  for _, m in ipairs(r.similar) do lines[#lines + 1] = "The same content as your project " .. m:line() end
  if r.timestamp == "matches" then
    lines[#lines + 1] = "Public timestamp: proves when this history existed (check history.json and history.ots " ..
                        "at opentimestamps.org)"
  elseif r.timestamp then
    lines[#lines + 1] = "Public timestamp: does not match the history (the history was changed after it)"
  end
  if #lines == 0 then
    lines[#lines + 1] = #require("conjunction.identity").profiles() == 0 and
                        "No profile of this PC to look for marks with" or "No marks of this PC's profiles found"
  end
  for _, n in ipairs(r.notes) do lines[#lines + 1] = n end
  return lines
end

return OR
