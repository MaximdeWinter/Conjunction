-- Changes to objects the game itself placed (worldchanges.py): <project>\world.yml, kept by TW3SE's world edits.
-- The editing side: load, save, add, drop, transform; the build's <dlc>	w3se\world.txt: lines, write.
local Y = require("conjunction.yaml")
local PYS = require("conjunction.pystr")   -- (Python's str.lower: umlauts too)
local NUM = require("conjunction.pynum")
local W = {}
W.FILE = "world.yml"
W.DOES = {remove = true, effect = true, look = true, move = true}

function W.load(project_path)
  local p = project_path .. "\\" .. W.FILE
  if not w3.fs.exists(p) then return Y.list() end
  local d = Y.read(p)
  local ch = (Y.is_map(d) and d.changes) or nil
  if not ch or ch == Y.null or #ch == 0 then return Y.list() end
  return ch
end
function W.save(project_path, changes)
  Y.write(project_path .. "\\" .. W.FILE, Y.map({"changes", changes}),
          {sort_keys = false, allow_unicode = true, default_flow_style = nil})
end

-- a template path becomes its file name (lamp_standing_complex)
function W.short_name(name)
  local base = NUM.str(name or ""):gsub("/", "\\"):match("([^\\]*)$")
  if PYS.lower(base):sub(-6) == ".w2ent" then return base:sub(1, -7) end
  return base
end

-- four hex dwords, not all zero, not a run-time object's counter (ffffffff ffffffff n 0)
function W.guid_ok(guid)
  local parts = {}
  for p in NUM.str(guid or ""):gmatch("%S+") do parts[#parts + 1] = p end
  if #parts ~= 4 then return false end
  local vals, any = {}, false
  for i, x in ipairs(parts) do
    local v = NUM.int_base(x, 16)
    if v == nil then return false end
    vals[i] = v
    if v ~= 0 then any = true end
  end
  return any and not (vals[1] == 0xFFFFFFFF and vals[2] == 0xFFFFFFFF)
end

local function round3(pos)
  local out = Y.list()
  for i, v in ipairs(pos) do out[i] = NUM.round(NUM.float(v), 3) end
  return out
end

-- record a change -> its id; the same object with the same kind of change is updated, not doubled
function W.add(project_path, guid, what, value, label, world, pos, otherwise)
  value, label, otherwise = value or "", label or "", otherwise or ""
  if not W.DOES[what] then error("a world change is one of remove, effect, look, move, not '" .. tostring(what) .. "'") end
  if not W.guid_ok(guid) then
    error("This object was made by the game at run time and cannot be changed permanently (only objects the game " ..
          "placed can)")
  end
  local changes = W.load(project_path)
  for _, c in ipairs(changes) do
    if c.guid == guid and c["do"] == what then
      -- (a move keeps where the object first stood)
      local back
      if what == "move" then back = c.otherwise or "" else back = (otherwise ~= "" and otherwise) or c.otherwise or "" end
      c.value = value
      c.otherwise = (back ~= "" and back) or otherwise
      c.label = (label ~= "" and label) or c.label or ""
      if what == "move" and pos and #pos > 0 then c.pos = round3(pos) end
      W.save(project_path, changes)
      return c.id
    end
  end
  local cid = 0
  for _, c in ipairs(changes) do if c.id > cid then cid = c.id end end
  cid = cid + 1
  changes[#changes + 1] = Y.map({"id", cid, "guid", guid, "do", what, "value", value, "otherwise", otherwise,
                                 "label", label, "world", world == nil and Y.null or world,
                                 "pos", (pos and #pos > 0) and round3(pos) or Y.null})
  W.save(project_path, changes)
  return cid
end

function W.drop(project_path, cid)
  local keep = Y.list()
  for _, c in ipairs(W.load(project_path)) do if c.id ~= cid then keep[#keep + 1] = c end end
  W.save(project_path, keep)
end

-- a move's value: "x y z roll pitch yaw"
function W.transform(pos, rot)
  local a, b = {}, {}
  for _, v in ipairs(pos) do a[#a + 1] = string.format("%.3f", NUM.float(v)) end
  for _, v in ipairs(rot) do b[#b + 1] = string.format("%.2f", NUM.float(v)) end
  return table.concat(a, " ") .. " " .. table.concat(b, " ")
end
function W.facts(qid, cid) return qid .. "_wc" .. cid .. "_on", qid .. "_wc" .. cid .. "_off" end

-- {change id = {on = true, off = true}} - which changes the quest's steps switch on or off
function W.switched(quest)
  local GEN = require("conjunction.questgen")
  local P = require("conjunction.py")
  local out = {}
  for _, step in ipairs(GEN.all_steps(P.T(quest) and quest or Y.map())) do
    local kind, a = GEN.step_type(step)
    if kind == "worldchange" and P.T(P.get(a, "change")) then
      local id = GEN.int(P.get(a, "change"))
      out[id] = out[id] or {}
      out[id][P.str(P.get(a, "state", "on"))] = true
    end
  end
  return out
end

-- the world.txt lines for the extender
function W.lines(project_path, qid, quest)
  local P = require("conjunction.py")
  local sw = W.switched(quest)
  local out = {}
  for _, c in ipairs(W.load(project_path)) do
    if W.guid_ok(P.get(c, "guid")) then
      local on, off = W.facts(qid, P.str(c.id))
      local s = sw[c.id] or {}
      local cond = (s.on and (" if " .. on) or "") .. (s.off and (" unless " .. off) or "")
      local label = "# " .. P.str(P.or_(P.get(c, "label"), c["do"])) .. " (change " .. P.str(c.id) .. ")"
      local guid, value, otherwise = P.str(c.guid), P.get(c, "value"), P.get(c, "otherwise")
      if c["do"] == "remove" then
        out[#out + 1] = label
        out[#out + 1] = "remove " .. guid .. cond
      elseif c["do"] == "effect" and P.T(value) then
        out[#out + 1] = label
        out[#out + 1] = "effect " .. guid .. " " .. P.str(value) .. cond
      elseif c["do"] == "look" and P.T(value) then
        local back = P.T(otherwise) and (" else " .. P.str(otherwise)) or ""
        out[#out + 1] = label
        out[#out + 1] = "appearance " .. guid .. " " .. P.str(value) .. back .. cond
      elseif c["do"] == "move" then
        local parts = {}
        for w in P.str(P.get(c, "value", "")):gmatch("%S+") do parts[#parts + 1] = w end
        if #parts == 6 then                     -- (the extender takes pitch yaw roll)
          out[#out + 1] = label
          out[#out + 1] = string.format("move %s %s %s %s %s %s %s%s", guid, parts[1], parts[2], parts[3], parts[5],
                                        parts[6], parts[4], cond)
        end
      end
    end
  end
  return out
end

-- <dlc>\tw3se\world.txt from the project's changes (none: no file) -> how many changes
-- what the project's scenes switch in the world (the cutscene editor's World tab: scene_timeline S:add_world_action):
-- a light and hiding follow the facts the scene sets - each from its fact until the next one for the same thing
-- (`light <guid> on if f1 unless f2`, `remove <guid> if f2 unless f3`); doors and effects need the tag alone
function W.scene_lines(project_path, project_meta, qid)
  local P = require("conjunction.py")
  local J = require("conjunction.json")
  local TL = require("conjunction.scene_timeline")
  local m = project_meta and P.get(project_meta, "world_objects")
  local out = {}
  if not (m and Y.is_map(m)) then return out end
  local dir = project_path .. "\\scene_layers"
  if not w3.fs.isdir(dir) then return out end
  local names = {}
  for _, e in ipairs(w3.fs.list(dir) or {}) do
    local n = type(e) == "table" and e.name or e
    if type(n) == "string" and n:sub(-5) == ".json" then names[#names + 1] = n end
  end
  table.sort(names)
  local acts = {}                               -- wid -> {{what, state, fact, order}}
  local order = 0
  for _, n in ipairs(names) do
    local ok, layer = pcall(function() return J.decode(w3.fs.read(dir .. "\\" .. n)) end)
    if ok and type(layer) == "table" then
      local secs = {}
      for name in pairs(layer.sections or {}) do secs[#secs + 1] = name end
      table.sort(secs)
      for _, sname in ipairs(secs) do
        local list = layer.sections[sname]
        table.sort(list, function(a, b) return (a.at or 0) < (b.at or 0) end)
        for _, rec in ipairs(list) do
          local props = {}
          for _, p in ipairs(rec.props or {}) do props[p[1]] = p[3] end
          local nm = tostring(props.eventName or "")
          if rec.cls == "CStorySceneAddFactEvent" and nm:sub(1, #TL.WORLD_ACT) == TL.WORLD_ACT then
            local what, wid, state = nm:sub(#TL.WORLD_ACT + 1):match("^(%S+) (%S+) (%S+)")
            if what and props.factId then
              order = order + 1
              acts[wid] = acts[wid] or {}
              local fact = tostring(props.factId)
              if fact:sub(1, 4) == "@wa_" then fact = tostring(qid) .. "_" .. fact:sub(2) end
              table.insert(acts[wid], {what = what, state = state, fact = fact, order = order})
            end
          end
        end
      end
    end
  end
  local wids = {}
  for wid in pairs(acts) do wids[#wids + 1] = wid end
  table.sort(wids)
  for _, wid in ipairs(wids) do
    local o = m[wid]
    if o and W.guid_ok(P.get(o, "guid")) then
      local guid = P.str(o.guid)
      local list = acts[wid]
      table.sort(list, function(a, b) return a.order < b.order end)
      for k, a in ipairs(list) do
        local function group_of(w) return (w == "light" or w == "anim") and w or "presence" end
        local group = group_of(a.what)
        local nxt
        for j = k + 1, #list do
          if group_of(list[j].what) == group then nxt = list[j] break end
        end
        local cond = " if " .. a.fact .. (nxt and (" unless " .. nxt.fact) or "")
        if a.what == "light" then
          out[#out + 1] = "# " .. P.str(P.or_(P.get(o, "name"), wid)) .. ": light " .. a.state .. " (a scene)"
          out[#out + 1] = "light " .. guid .. " " .. a.state .. cond
        elseif a.what == "anim" then             -- (its own move from the moment on: TW3SE 1.3.3 `anim`)
          out[#out + 1] = "# " .. P.str(P.or_(P.get(o, "name"), wid)) .. ": moves " .. a.state .. " (a scene)"
          out[#out + 1] = "anim " .. guid .. " " .. a.state .. " if " .. a.fact
        elseif a.what == "hide" then
          out[#out + 1] = "# " .. P.str(P.or_(P.get(o, "name"), wid)) .. ": hidden (a scene)"
          out[#out + 1] = "remove " .. guid .. cond
        end
      end
    end
  end
  return out
end

-- the objects of the world the project uses (world_pick.lua): each gets the tag its blocks name
function W.world_tags(project_path, qid)
  local P = require("conjunction.py")
  local WP = require("conjunction.world_pick")
  local ok, pr = pcall(function() return require("conjunction.project").open(project_path) end)
  local m = ok and pr and pr.meta and P.get(pr.meta, "world_objects")
  local out, ids = {}, {}
  if not (m and Y.is_map(m)) then return out end
  for id in pairs(m) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local o = m[id]
    if W.guid_ok(P.get(o, "guid")) then
      out[#out + 1] = "# " .. P.str(P.or_(P.get(o, "name"), id)) .. " (an object of the world)"
      out[#out + 1] = "tag " .. P.str(o.guid) .. " " .. WP.guid_tag(o.guid)
    end
  end
  return out
end

function W.write(project_path, qid, quest, dlc_folder, log)
  local text = W.lines(project_path, qid, quest)
  for _, ln in ipairs(W.world_tags(project_path, qid)) do text[#text + 1] = ln end
  local okm, pr = pcall(function() return require("conjunction.project").open(project_path) end)
  for _, ln in ipairs(W.scene_lines(project_path, okm and pr and pr.meta, qid)) do text[#text + 1] = ln end
  local target = dlc_folder .. "\\tw3se\\world.txt"
  if #text == 0 then
    if w3.fs.exists(target) then w3.fs.remove(target) end
    return 0
  end
  if not w3.fs.isdir(dlc_folder .. "\\tw3se") then w3.fs.mkdir(dlc_folder .. "\\tw3se") end
  assert(w3.fs.write(target, "# " .. qid .. ": changes to the game's own objects (Conjunction, kept by the script " ..
                             "extender TW3SE)\n" .. table.concat(text, "\n") .. "\n"))
  local n = 0
  for _, ln in ipairs(text) do if ln:sub(1, 1) ~= "#" then n = n + 1 end end
  ;(log or print)(string.format("[build] %s: %d change(s) to the game's objects -> tw3se\\world.txt", qid, n))
  return n
end

return W
