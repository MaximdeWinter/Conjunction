-- The history of what is made with Conjunction (provenance.py): every step - made, edited, built, exported - with who
-- did it (the profile's name), the tools and when, signed by that profile's key and chained to the step before; each
-- names what changed since (changes.lua). Kept in the project (history.json).
--   PV.note(path, step, {force, tools, extra, profile}) -> step|nil   PV.note_safely(...)
--   PV.read(path) -> {step}   PV.write(path, steps)   PV.check(steps, content) -> {ok, problem, steps, changed_after}
--   PV.content_hash(path) -> hex   PV.blob(path) -> text
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local PYS = require("conjunction.pystr")
local CH = require("conjunction.changes")
local PV = {}

PV.FILE = "history.json"
PV.SKIP_DIRS = {build = true, parked = true, versions = true, [".git"] = true, __pycache__ = true, [".cj_history"] = true}
PV.LABELS = {create = "Made", edit = "Edited", build = "Built", export = "Exported", import = "Taken in",
             finish = "Finished"}
PV.VERSION = "0.1.0"                             -- (the release's version: make_ingame_release.py checks it)

local function sha_text(text) return w3.plugin.cj_sha256_parts("t:" .. text) end

-- sha256 over the project's own files (paths and bytes, sorted by their names in lower case) - not its build, not
-- the history itself; project.yml without what is no change of the quest (changes.QUIET)
function PV.content_hash(path)
  local files = {}
  local function walk(dir, rel)
    for _, e in ipairs(w3.fs.list(dir) or {}) do
      local p, r = dir .. "\\" .. e.name, rel == "" and e.name or (rel .. "/" .. e.name)
      if e.dir then
        if not PV.SKIP_DIRS[e.name] then walk(p, r) end
      elseif e.name ~= PV.FILE and e.name:sub(-4) ~= ".tmp" then
        files[#files + 1] = {r, p, PYS.lower(r), #files}
      end
    end
  end
  walk(path, "")
  table.sort(files, function(a, b) if a[3] ~= b[3] then return a[3] < b[3] end return a[4] < b[4] end)
  local parts = {}
  for _, f in ipairs(files) do
    parts[#parts + 1] = "t:" .. f[3]
    parts[#parts + 1] = "z"
    local done = false
    if f[3] == "project.yml" then
      local ok, meta = pcall(Y.read, f[2])
      if ok then
        if meta == nil or meta == Y.null or meta == false then meta = Y.map() end
        if type(meta) == "table" then
          local m = Y.map()
          for _, k in ipairs(Y.keys(meta)) do if not CH.QUIET[k] then m[k] = meta[k] end end
          parts[#parts + 1] = "x:" .. sha_text(J.encode(m, {sort_keys = true}))
          done = true
        end
      end
    end
    if not done then parts[#parts + 1] = "f:" .. f[2] end
  end
  return w3.plugin.cj_sha256_parts(table.unpack(parts))
end

local function canonical(body) return J.encode(body, {sort_keys = true, separators = {",", ":"}, ensure_ascii = false}) end
PV.canonical = canonical

function PV.tools() return Y.list({"Conjunction " .. PV.VERSION}) end

-- datetime.now().astimezone().isoformat(timespec="seconds"): the local time and its offset
local function now_iso()
  local t = os.time()
  local off = os.difftime(t, os.time(os.date("!*t", t)))
  if os.date("*t", t).isdst then off = off + 3600 end
  local sign = off < 0 and "-" or "+"
  off = math.abs(math.floor(off))
  return os.date("%Y-%m-%dT%H:%M:%S", t) .. string.format("%s%02d:%02d", sign, off // 3600, (off % 3600) // 60)
end

function PV.make_step(profile, step, content, prev, tools_used, extra)
  local body = Y.map({"v", 1, "step", step, "label", PV.LABELS[step] or step, "name", profile.name,
                      "key", profile.public, "at", now_iso(), "tools", tools_used or PV.tools(), "content", content,
                      "prev", prev})
  for _, k in ipairs(extra and Y.keys(extra) or {}) do body[k] = extra[k] end
  local out = Y.map()
  for _, k in ipairs(Y.keys(body)) do out[k] = body[k] end
  out.sig = profile:sign(canonical(body))
  return out
end

function PV.read(path)
  local p = path .. "\\" .. PV.FILE
  if not w3.fs.exists(p) then return Y.list() end
  local ok, d = pcall(J.read, p)
  if ok and type(d) == "table" and type(d.steps) == "table" then return d.steps end
  return Y.list()
end
function PV.write(path, steps)
  local p = path .. "\\" .. PV.FILE
  local text = J.encode(Y.map({"history", "conjunction/1", "steps", steps}), {indent = 1, ensure_ascii = false})
  assert(w3.fs.write(p .. ".tmp", (text:gsub("\n", "\r\n"))))       -- (Python's text mode: CRLF)
  w3.fs.remove(p)
  assert(w3.fs.rename(p .. ".tmp", p))
end

-- a step by the active profile; an "edit" only when the project changed since the last step -> the step or nil
function PV.note(path, step, o)
  o = o or {}
  local ID = require("conjunction.identity")
  local profile = o.profile or ID.active()
  if profile == nil or not w3.fs.isdir(path) then return nil end
  local steps = PV.read(path)
  local content = PV.content_hash(path)
  if not o.force and #steps > 0 and steps[#steps].content == content then return nil end
  if #steps == 0 and step == "edit" then step = "create" end
  local extra = o.extra
  if #steps == 0 then                            -- (the first step names the project: its uid, marks.lua)
    local ok, meta = pcall(Y.read, path .. "\\project.yml")
    local uid = ok and type(meta) == "table" and meta.uid
    if uid and uid ~= Y.null and uid ~= "" then
      local e = Y.map()
      for _, k in ipairs(extra and Y.keys(extra) or {}) do e[k] = extra[k] end
      e.uid = uid
      extra = e
    end
  end
  local now = CH.state(path)
  local said = CH.describe(#steps > 0 and CH.load(path) or nil, now)
  if #said > 0 then
    local e = Y.map()
    for _, k in ipairs(extra and Y.keys(extra) or {}) do e[k] = extra[k] end
    e.changes = Y.list(said)
    extra = e
  end
  local s = PV.make_step(profile, step, content, #steps > 0 and steps[#steps].sig or "", o.tools, extra)
  steps[#steps + 1] = s
  PV.write(path, steps)
  CH.save(path, now)
  return s
end
function PV.note_safely(path, step, o)
  local ok, s = pcall(PV.note, path, step, o)
  if not ok then print("[history] " .. tostring(step) .. ": " .. tostring(s)) return nil end
  return s
end

-- every signature and the chain; with content, whether the thing still is what the last step signed
function PV.check(steps, content)
  local ID = require("conjunction.identity")
  local prev = ""
  for i, st in ipairs(steps) do
    local body = Y.map()
    for _, k in ipairs(Y.keys(st)) do if k ~= "sig" then body[k] = st[k] end end
    local label = st.label or "?"
    if (body.prev or "") ~= prev then
      return {ok = false, problem = string.format("step %d (%s) does not follow the one before: a step was cut out, " ..
                                                   "put in or moved", i, label), steps = steps}
    end
    local ok = st.key ~= nil and st.sig ~= nil and ID.verify(tostring(st.key), canonical(body), tostring(st.sig))
    if not ok then
      return {ok = false, problem = string.format("step %d (%s) was changed after it was signed", i, label),
              steps = steps}
    end
    prev = st.sig
  end
  local changed = content ~= nil and content ~= "" and #steps > 0 and steps[#steps].content ~= content
  return {ok = true, problem = nil, steps = steps, changed_after = changed}
end

function PV.blob(path)
  return J.encode(Y.map({"history", "conjunction/1", "steps", PV.read(path)}), {indent = 1, ensure_ascii = false})
end

return PV
