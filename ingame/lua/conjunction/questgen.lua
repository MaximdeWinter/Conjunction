-- The quest generator (quest.py): a project's quest - its graph of steps - made radish's quest definition: the
-- structure's blocks, the journal, the meta entities of each world (trigger areas, map pins, action points, scene
-- points), the communities of its people, the dialogues' scenes, the rewards, the own recordings and items.
--   local out = GEN.generate(project)   -> structure, journals, meta, tags, communities, scenes, rewards, speech, items
-- A step type is a table with `name` and `generate(self, ctx, i, s)` -> a StepOut (questgen_steps.lua has them all).
-- Python's dicts are yaml.lua's maps (their order is the order radish's files get), its None Y.null.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local N = require("conjunction.pynum")
local PYS = require("conjunction.pystr")
local QN = require("conjunction.quest_nodes")
local Q = require("conjunction.quest")
local GEN = {}

-- --- Python's errors: a ValueError says what is wrong with the quest (the build shows it); a KeyError a field not set
local VE_MT = {__tostring = function(e) return e.value_error end}
local KE_MT = {__tostring = function(e) return "KeyError: '" .. tostring(e.key_error) .. "'" end}
function GEN.ValueError(msg) return setmetatable({value_error = msg}, VE_MT) end
function GEN.fail(msg) error(GEN.ValueError(msg), 0) end
function GEN.is_value_error(e) return type(e) == "table" and getmetatable(e) == VE_MT end
function GEN.is_key_error(e) return type(e) == "table" and getmetatable(e) == KE_MT end
local fail = GEN.fail

-- d[k]: Python's subscript - a missing key is a KeyError (a stored None is None)
function GEN.need(d, k)
  if type(d) ~= "table" or d == Y.null or rawget(d, k) == nil then error(setmetatable({key_error = k}, KE_MT), 0) end
  local v = d[k]
  if v == Y.null then return nil end
  return v
end
local need = GEN.need

-- --- Python's values
function GEN.map(...)                            -- {k1: v1, ...} in that order (a None as Y.null)
  local kv = table.pack(...)
  local m = Y.map()
  for i = 1, kv.n, 2 do
    local v = kv[i + 1]
    if v == nil then v = Y.null end
    m[kv[i]] = v
  end
  return m
end
function GEN.list(...)
  local t = table.pack(...)
  local out = Y.list({})
  for i = 1, t.n do out[i] = t[i] == nil and Y.null or t[i] end
  return out
end
local M, L = GEN.map, GEN.list
function GEN.float(v)                            -- float(v)
  if v == true then return 1.0 end
  if v == false then return 0.0 end
  local n = tonumber(type(v) == "string" and PYS.strip(v) or v)
  if n == nil then fail("could not convert to a number: " .. P.repr(v)) end
  if math.type(n) == "float" then return n end   -- (-0.0 + 0.0 would be 0.0)
  return n + 0.0
end
function GEN.int(v)                              -- int(v): a float truncated, a string of digits read
  if v == true then return 1 end
  if v == false then return 0 end
  if type(v) == "string" then
    local s = PYS.strip(v)
    if not s:match("^[+-]?%d+$") then fail("invalid literal for int(): " .. P.repr(v)) end
    return math.tointeger(tonumber(s))
  end
  if type(v) ~= "number" then fail("int() of " .. P.repr(v)) end
  if math.type(v) == "integer" then return v end
  return math.tointeger(v >= 0 and math.floor(v) or math.ceil(v))
end
local F, I = GEN.float, GEN.int
function GEN.bool(v) return P.T(v) end
local function S(v) return P.str(v) end
GEN.str = S
function GEN.round(v, n) return N.round(v, n) end
local R = GEN.round
-- dict(m, k=v, ...): a copy with these keys set (one already there keeps its place)
function GEN.with(m, ...)
  local out = Y.map()
  if m ~= nil and m ~= Y.null then for k, v in pairs(m) do out[k] = v end end
  local kv = table.pack(...)
  for i = 1, kv.n, 2 do
    local v = kv[i + 1]
    if v == nil then v = Y.null end
    out[kv[i]] = v
  end
  return out
end
local with = GEN.with
-- {**a, **b}
function GEN.merged(a, b)
  local out = Y.map()
  for _, t in ipairs({a, b}) do
    if t ~= nil and t ~= Y.null then for k, v in pairs(t) do out[k] = v end end
  end
  return out
end
-- d.setdefault(k, default)
function GEN.setdefault(d, k, default)
  local v = rawget(d, k)
  if v == nil then
    d[k] = default
    return default
  end
  return v
end
local setdefault = GEN.setdefault
-- the parts of a reference "place/object"
function GEN.partition(s, sep)
  s = S(s)
  local a, b = s:find(sep, 1, true)
  if not a then return s, "", "" end
  return s:sub(1, a - 1), sep, s:sub(b + 1)
end
local partition = GEN.partition

-- --- a step's blocks (StepOut)
-- blocks: {"<type>.<name>" = {...}} without the final `next` of `last`; first is linked from the step before, last
-- links onward; objective {caption, mappins, world} for the journal or nil; meta {world = {areas, mappins ...}};
-- scenes {name = scene}; branches {socket = "continue" | "retry" | "fail" | "path:<id>"}; counter {fact, n}
function GEN.StepOut(blocks, first, last, objective, meta, scenes, branches, counter)
  return {blocks = blocks or Y.map(), first = first, last = last, objective = objective, meta = meta or Y.map(),
          scenes = scenes or Y.map(), branches = branches or Y.map(), counter = counter}
end
local StepOut = GEN.StepOut

-- --- small parts of quest.py
GEN.QUEST_TYPES = {main = "MainQuest", secondary = "SideQuest", side = "SideQuest", monsterhunt = "MonsterHunt",
                   treasurehunt = "TreasureHunt"}
GEN.QUEST_TYPE_NAMES = {"main", "secondary", "side", "monsterhunt", "treasurehunt"}

function GEN.idle_action(template)
  local t = PYS.lower(template)
  for _, w in ipairs({"woman", "female", "girl", "_f_"}) do
    if t:find(w, 1, true) then return "idle_woman/stand_mwdc_idle_jt" end
  end
  return "idle_man/stand_mwdc_idle_jt"
end

-- the quest's own range of string ids (radish: 1000 per space; Conjunction's DLCs use 9998 / 9999)
function GEN.idspace(qid) return 1000 + P.crc32(qid) % 8000 end

function GEN.step_type(step)
  if not Y.is_map(step) or Y.len(step) ~= 1 then
    fail("a step is one entry like '- goto: {...}', found: " .. P.repr(step))
  end
  local k = Y.keys(step)[1]
  local v = step[k]
  if v == Y.null then v = nil end
  return k, v
end
local step_type = GEN.step_type

-- when a place comes: "start" or "step" (a Show place step brings it). Set to come with a step and no step
-- shows it any more: from the start - it came never, its people neither (13.11.: Bayor of "ambush" was not
-- there, the step that showed the place was gone)
function GEN.place_visible(project, name, q)
  local v = P.get(project.places[name] or Y.map(), "visible", "start")
  if v ~= "step" then return v end
  q = q or P.get(project.meta, "quest") or Y.map()
  if not GEN.has_quest(q) then return "start" end
  for _, st in ipairs(GEN.all_steps(q)) do
    local kind, a = step_type(st)
    if kind == "show" and Y.is_map(a) and P.get(a, "place") == name then return "step" end
  end
  return "start"
end

-- every step of the quest (its graph's nodes; the older form: the story and its paths)
function GEN.all_steps(q)
  local out = {}
  if QN.is_graph(q) then
    for _, nid in ipairs(Y.keys(q.nodes)) do
      local st = q.nodes[nid].step
      local k = step_type(st)
      if k ~= "start" and k ~= "remember" then out[#out + 1] = st end
    end
    return out
  end
  for _, st in ipairs(P.list(P.get(q, "steps"))) do out[#out + 1] = st end
  for _, pid in ipairs(Y.keys(P.map(P.get(q, "paths")))) do
    for _, st in ipairs(P.list(P.get(q.paths[pid], "steps"))) do out[#out + 1] = st end
  end
  return out
end

-- the node ids reachable from these along the wires (them too) - a set
function GEN.reach(q, starts)
  local seen, todo = {}, {}
  for _, s in ipairs(starts) do todo[#todo + 1] = s end
  while #todo > 0 do
    local nid = table.remove(todo)
    if not seen[nid] then
      seen[nid] = true
      for _, l in ipairs(QN.links_from(q, nid)) do todo[#todo + 1] = l[3] end
    end
  end
  return seen
end

-- the node ids from which the wires lead to nid - a set
function GEN.ancestors(q, nid)
  local back = {}
  for _, l in ipairs(P.list(P.get(q, "links"))) do
    back[l[3]] = back[l[3]] or {}
    table.insert(back[l[3]], l[1])
  end
  local seen, todo = {}, {}
  for _, x in ipairs(back[nid] or {}) do todo[#todo + 1] = x end
  while #todo > 0 do
    local x = table.remove(todo)
    if not seen[x] then
      seen[x] = true
      for _, y in ipairs(back[x] or {}) do todo[#todo + 1] = y end
    end
  end
  return seen
end

function GEN.meta_layer(qid, world) return qid .. "_meta_" .. world end
function GEN.inside_facts(qid) return qid .. "_inside", qid .. "_over" end

-- is there a quest to build: a step besides its start and its ends?
function GEN.has_quest(q)
  if QN.is_graph(q) then
    for _, nid in ipairs(Y.keys(q.nodes)) do
      local k = step_type(q.nodes[nid].step)
      if k ~= "start" and k ~= "end" then return true end
    end
    return false
  end
  return P.T(P.get(q, "steps")) or P.T(P.get(q, "paths"))
end

-- a place gets a layer only for its things (its NPCs come as a community; spot markers only in the editor)
function GEN.has_statics(place)
  for _, o in ipairs(P.list(P.get(place, "objects"))) do
    if not Q.is_actor(o) and not P.T(P.get(o, "marker")) and not P.T(P.get(o, "trail")) then return true end
  end
  return false
end

-- {place/id} of everyone a Kill step targets (anywhere in the quest) - a set
function GEN.kill_targets(q)
  local out = {}
  local function walk(x)
    if Y.is_map(x) then
      local k = P.get(x, "kill")
      if Y.is_map(k) then
        for _, r in ipairs(P.list(P.get(k, "targets"))) do if P.T(r) then out[r] = true end end
        if P.T(P.get(k, "target")) then out[k.target] = true end
      end
      for _, v in pairs(x) do walk(v) end
    elseif Y.is_list(x) or (type(x) == "table" and x ~= Y.null) then
      for _, v in ipairs(x) do walk(v) end
    end
  end
  walk(q or Y.map())
  return out
end

-- the object references of everyone who speaks: talk partners, people who join a talk or speak in it, says - a set
function GEN.speaking_people(q)
  local D = require("conjunction.dialogue")
  local out = {}
  for _, st in ipairs(GEN.all_steps(q)) do
    local kind, a = step_type(st)
    a = a or Y.map()
    if kind == "talk" then
      local n = P.get(a, "npc")
      if P.T(n) then out[n] = true end
      for _, w in ipairs(P.list(P.get(a, "with"))) do
        local who = P.get(w, "who")
        if P.T(who) then out[who] = true end
      end
      for _, x in ipairs(D.walk(D.from_step(a))) do
        local who = S(P.get(x, "who", ""))
        if who:find("/", 1, true) then out[x.who] = true end
      end
    elseif kind == "say" and P.T(P.get(a, "who")) then
      out[a.who] = true
    end
  end
  return out
end

-- {place/id = the name shown above a person} - what journal lines made from a step call them
function GEN.display_names(project)
  local out = {}
  for _, place in ipairs(Y.keys(project.places)) do
    for _, o in ipairs(P.list(P.get(project.places[place], "objects"))) do
      if P.T(P.get(o, "id")) and P.T(P.get(o, "display")) then out[place .. "/" .. S(o.id)] = o.display end
    end
  end
  return out
end

-- --- the generation's context (quest.Ctx)
local Ctx = {}
Ctx.__index = Ctx
GEN.Ctx = Ctx

function Ctx.new(project, q)
  local self = setmetatable({}, Ctx)
  self.project = project
  self.qid = project.id
  self.names = GEN.display_names(project)
  self.idspace = GEN.idspace(self.qid)
  self.next_string = 200                         -- 0..199: the journal; scenes take theirs from here on
  self.speech = Y.list({})                       -- own recordings of the dialogues: {id, text, source, lang}
  self.extra_meta = Y.map()                      -- meta entities steps add besides their own
  self.moved = {}                                -- {place/id = {pos, yaw}} where a person stands after a step moved them
  self.characters = Y.map()                      -- people's journal pages
  self.rewards = Y.map()                         -- radish reward definitions {id = [items]}
  self.minigames = Y.map()                       -- stand-ins {block name = {...}} (minigames.py)
  self.keyed = {}                                -- texts the game asks for by key: {{id, key, text}}
  self.layers = Y.map()                          -- layers of the steps' own: hidden first
  self.own_entities = Y.map()                    -- entity templates built into the DLC
  self.trails_in_steps = {}                      -- trails a step shows (a set)
  self.descriptions = Y.list({})                 -- journal paragraphs added by note steps
  self.foes = {}                                 -- kill targets {reference = their own community}
  self.walk_phases, self.stand_phases, self.person_comm = {}, {}, {}
  if q == nil then q = P.get(project.meta, "quest") or Y.map() end
  self._items = P.get(q, "items") or Y.map()
  self.graph = QN.is_graph(q)
  self.start_as = P.get(q, "player") or "geralt"
  self.played = Q.characters(q)
  return self
end

-- the quest's own items {id = {name ...}} (their names in journal lines made from a step) - all the project's quests'
function Ctx:own_items()
  if P.T(self._items) then return self._items end
  return P.get(P.get(self.project.meta, "quest") or Y.map(), "items") or Y.map()
end
-- who is played at the step with these arguments
function Ctx:character(s) return self.played[s] or self.start_as end
-- the first of n string ids for a scene (all scenes of a quest share its id space)
function Ctx:strings(n)
  local start = self.next_string
  self.next_string = self.next_string + n
  if self.next_string > 1000 then
    fail("The quest's dialogues have more than 800 lines. Please split it into two quests")
  end
  return start
end
-- a text the game finds by its key (a notice board's notices) - into the quest's strings
function Ctx:keyed_string(key, text)
  self.keyed[#self.keyed + 1] = {2110000000 + self.idspace * 1000 + self:strings(1), key, text}
end
function Ctx:place_world(place)
  local p = P.get(self.project.places, place)
  if not P.T(p) or not P.T(P.get(p, "world")) then
    fail("Location '" .. S(place) .. "' is still empty (its world is unknown)")
  end
  return p.world
end
function Ctx:place_center(place)
  local objs = P.list(P.get(P.get(self.project.places, place) or Y.map(), "objects"))
  if #objs == 0 then fail("Location '" .. S(place) .. "' has no objects. A Go to step needs a position") end
  local out = Y.list({})
  for i = 1, 3 do
    local xs = {}
    for _, o in ipairs(objs) do xs[#xs + 1] = o.pos[i] end
    out[i] = N.sum(xs) / #objs                   -- (Python's sum: compensated)
  end
  return out
end
function Ctx:object(ref)
  local WP = require("conjunction.world_pick")
  if WP.is_ref(S(ref)) then                     -- (an object the game placed: world_pick.lua)
    local o = WP.get(self.project, S(ref))
    if o then return o end
    fail("The object of the world '" .. S(ref) .. "' is not in the project any more. Pick it again")
  end
  local place, _, oid = partition(ref, "/")
  for _, o in ipairs(P.list(P.get(P.get(self.project.places, place) or Y.map(), "objects"))) do
    if P.get(o, "id") == oid then return o end
  end
  fail("Object '" .. S(ref) .. "' not found. Select it in the editor and give it a name")
end
-- camp/strongbox -> the tag its static (or NPC) gets (checked: the object exists)
function Ctx:object_tag(ref)
  self:object(ref)
  local WP = require("conjunction.world_pick")
  if WP.is_ref(S(ref)) then return WP.tag(self.project, S(ref)) end
  local place, _, oid = partition(ref, "/")
  return self.qid .. "_" .. place .. "_" .. oid
end

-- --- map pins and areas
-- a map pin on objects of the step (the middle of several; the circle takes in all of them) -> meta, objective fields
function GEN.pin(ctx, i, refs, radius)
  radius = radius or 3.0
  local objs = {}
  for _, r in ipairs(refs) do objs[#objs + 1] = ctx:object(r) end
  local first = refs[1]
  local world = require("conjunction.world_pick").is_ref(S(first)) and S(ctx:object(first).world)
                or ctx:place_world((partition(first, "/")))
  local center = Y.list({})
  for k = 1, 3 do
    local sum = 0.0
    for _, o in ipairs(objs) do sum = sum + F(o.pos[k]) end
    center[k] = R(sum / #objs, 3)
  end
  local spread = -math.huge
  for _, o in ipairs(objs) do
    spread = math.max(spread, N.hypot(center[1] - F(o.pos[1]), center[2] - F(o.pos[2])))
  end
  local pin = ctx.qid .. "_s" .. S(i) .. "_pin"
  local r = #objs > 1 and R(math.max(radius, spread + 5.0), 1) or radius
  return M(world, M("mappins", M(pin, center))), M("mappins", L(L(pin, r)), "world", world)
end

function GEN.area(center, radius, height, corners)
  height, corners = height or 6.0, corners or 8
  local x, y, z = center[1], center[2], center[3]
  local pts = Y.list({})
  for k = 0, corners - 1 do
    pts[#pts + 1] = L(R(x + radius * math.cos(2 * math.pi * k / corners), 3),
                      R(y + radius * math.sin(2 * math.pi * k / corners), 3), R(z - 2.0, 3))
  end
  return M("borderpoints", pts, "height", height)
end

-- go to only at a time of day: the hours [from, to)
GEN.WHEN = {morning = {5, 10}, day = {7, 19}, evening = {18, 22}, night = {22, 5}}
function GEN.hours(when)
  if not P.T(when) then return 0, 0 end
  if GEN.WHEN[when] then return GEN.WHEN[when][1], GEN.WHEN[when][2] end
  local a, _, b = partition(S(when), "-")
  if b == "" then b = a end
  return I(a) % 24, I(b) % 24
end

-- the game's yaw of looking from a to b (0: +y, as an object's rot[2])
function GEN.heading(a, b)
  return R(math.deg(math.atan(-(F(b[1]) - F(a[1])), F(b[2]) - F(a[2]))), 1)
end

-- --- items
-- the game's name of the quest's own item ("own:<id>"), or nil for the game's items
function GEN.own_item(ctx, item)
  item = S(P.or_(item, ""))
  if not P.startswith(item, "own:") then return nil end
  local iid = item:sub(5)
  local items = ctx:own_items()                  -- (every quest of the project's)
  if not P.has(items, iid) then fail("The quest has no own item '" .. iid .. "'") end
  return ctx.qid .. "_own_" .. iid
end

-- a loot / collect step's items: the first (item, count) and the ones added to it (more_items)
function GEN.step_items(a)
  local out = {}
  if P.T(P.get(a, "item")) then out[1] = M("item", a.item, "count", I(P.get(a, "count", 1))) end
  for _, x in ipairs(P.list(P.get(a, "more_items"))) do
    if P.T(P.get(x, "item")) then out[#out + 1] = M("item", x.item, "count", I(P.get(x, "count", 1))) end
  end
  return out
end

-- does the item come from a mod (not the game)? (content.Origins, as the app's cache has it)
local function pack_item(ctx, item)
  if ctx._origins == nil then
    local ok, o = pcall(function() return require("conjunction.content").Origins() end)
    ctx._origins = ok and o or false
  end
  local o = ctx._origins
  if not o then return false end
  local from = o:item(item) or "game"
  return from ~= "game" and from ~= "suite"
end

-- an item's name as the game's scripts take it (a CName): an own item's, a content pack's, a game item's by its name
-- or by the text it shows (the catalog's items: name, label)
function GEN.item_cname(ctx, item)
  local own = GEN.own_item(ctx, item)
  if own then return own end
  if S(item):match("^[a-z0-9_]+$") and pack_item(ctx, item) then return S(item) end
  local r
  pcall(function()
    local db = require("conjunction.db").open(require("conjunction.assets").DB, false)
    r = db:one("select name from items where name = ? union all select name from items where label = ? limit 1",
               S(item), S(item))
    db:close()
  end)
  return r and r.name or S(item)
end

-- a script call with an item: the game's items by text (looked up in the mod), own items by name; rest: {k, v, ...}
function GEN.item_call(ctx, fn, item, rest)
  local params = Y.list({})
  local own = GEN.own_item(ctx, item)
  local function more()
    for k = 1, #(rest or {}), 2 do params[#params + 1] = M(rest[k], rest[k + 1]) end
  end
  if own then
    params[1] = M("itemName", "cname_" .. own)
    more()
    return M("function", fn .. "N", "parameter", params)
  end
  if S(item):match("^[a-z0-9_]+$") and pack_item(ctx, item) then
    params[1] = M("itemName", "cname_" .. S(item))
    more()
    return M("function", fn .. "N", "parameter", params)
  end
  params[1] = M("item", S(item))
  more()
  return M("function", fn, "parameter", params)
end

function GEN.point(s)
  if not P.T(P.get(s, "pos")) then fail("Walk to: where? (Pick a point on the card, then click in the world)") end
  return {M("x", F(s.pos[1])), M("y", F(s.pos[2])), M("z", F(s.pos[3]))}
end

function GEN.tag(ctx, s, key)
  key = key or "target"
  if not P.T(P.get(s, key)) then fail(key .. ": which one? (Pick, Search or Create on the card)") end
  return "cname_" .. ctx:object_tag(s[key])
end

-- a person of a place (its quest tag), or the player
function GEN.who(_ctx, s, key)
  key = key or "who"
  if P.T(P.get(s, key)) then return s[key] end
  return "PLAYER"
end

-- the blocks of a walk by phases: for each point the phase that sends him there, then CjArrive -> blocks, first, last
function GEN.walk_chain(ctx, i, who, phases, wait, progress, pin)
  pin = pin or ""
  local comm, names, stuck = phases[1], phases[2], phases[3]
  local tag = "cname_" .. ctx:object_tag(who)
  local blocks, prev = Y.map(), nil
  local si = "s" .. S(i)
  if stuck then
    local out, away = "script." .. si .. "_fadeout", "despawn." .. si .. "_free"
    blocks[out] = M("function", "CjFadeColor", "parameter", L(M("fadeOut", true), M("seconds", 1.0), M("white", false)),
                    "next", L(away))
    blocks[away] = M("spawnsets", L(comm), "next", L("spawn." .. si .. "_p1"))
    prev = nil
  end
  for j, np in ipairs(names) do
    local phase, pos = np[1], np[2]
    local sp, ar = "spawn." .. si .. "_p" .. j, "script." .. si .. "_at" .. j
    blocks[sp] = M("spawnsets", L(comm), "phase", phase, "next", L(ar))
    blocks[ar] = M("function", "CjArrive", "parameter", L(
      M("tag", tag), M("x", pos[1]), M("y", pos[2]), M("z", pos[3]), M("point", j), M("progress", progress),
      M("waitDist", F(wait)), M("pin", "cname_" .. (pin ~= "" and pin or "cj_nopin"))))
    if prev then blocks[prev].next = L(sp) end
    prev = ar
  end
  if stuck then
    local back = "script." .. si .. "_fadein"
    blocks[back] = M("function", "CjFadeColor", "parameter", L(M("fadeOut", false), M("seconds", 1.0), M("white", false)),
                     "next", L("script." .. si .. "_at1"))
    blocks["spawn." .. si .. "_p1"].next = L(back)
    return blocks, "script." .. si .. "_fadeout", prev
  end
  return blocks, "spawn." .. si .. "_p1", prev
end

-- """[@<id>]" in the scene's lines -> "[<seconds>]" ("[@<id>><hold>]": at least <hold> seconds)
function GEN.put_durations(x, timing)
  if Y.is_map(x) then
    for _, k in ipairs(Y.keys(x)) do x[k] = GEN.put_durations(x[k], timing) end
  elseif Y.is_list(x) then
    local out = Y.list({})
    for i, v in ipairs(x) do out[i] = GEN.put_durations(v, timing) end
    return out
  elseif type(x) == "string" and P.startswith(x, "[@") then
    local inner, rest = x:sub(3):match("^([^%]]*)%](.*)$")
    local sid, _, hold = partition(inner, ">")
    local t = timing[I(sid)] or 2.0
    return string.format("[%.3f]", math.max(t, F(hold ~= "" and hold or 0))) .. rest
  elseif type(x) == "string" and P.startswith(x, "@rest ") then
    local parts = PYS.split(x)
    return R(math.max(0.05, F(parts[3]) - (timing[I(parts[2])] or 2.0)), 3)
  end
  return x
end

-- --- conditions of If and Wait until (quest.py: the game's own condition classes)
GEN.IF_OPS = {["="] = "!=", ["!="] = "=", [">="] = "<", ["<"] = ">=", [">"] = "<=", ["<="] = ">"}
GEN.QUEST_STATES = {{"active", "is running", "JS_Active"}, {"done", "is done", "JS_Success"},
                    {"failed", "has failed", "JS_Failed"}}

local function seconds_of(text)
  local h, m = S(text):match("^%s*([+-]?%d+)%s*:%s*([+-]?%d+)")
  if not h then error(GEN.ValueError("not hh:mm"), 0) end
  return (I(h) % 24) * 3600 + I(m) * 60
end

-- one condition -> holds, holds not (an item is counted by a script first: pre gets its block; an area is a trigger
-- area of the quest: meta)
function GEN.condition(ctx, i, k, c, meta, pre, waiting)
  local kind = Q.cond_kind(c)
  local where = "step " .. S(i) .. ", condition " .. (k + 1)
  local yes, no
  if kind == "fact" then
    if not P.T(P.get(c, "fact")) then fail(where .. ": which fact?") end
    local op = S(P.or_(P.get(c, "op"), ">="))
    if not GEN.IF_OPS[op] then fail(where .. ": unknown comparison '" .. op .. "'") end
    local value = I(P.get(c, "value", 1))
    yes, no = M("factdb", L(S(c.fact), op, value)), M("factdb", L(S(c.fact), GEN.IF_OPS[op], value))
  elseif kind == "path" then
    if not P.T(P.get(c, "path")) then fail(where .. ": which branch?") end
    local fact = QN.path_fact(ctx.qid, c.path)
    yes, no = M("factdb", L(fact, ">=", 1)), M("factdb", L(fact, "<", 1))
  elseif kind == "area" then
    local world, center
    if P.T(P.get(c, "at")) then
      local place, _, oid = partition(c.at, "/")
      local o
      for _, x in ipairs(P.list(P.get(P.get(ctx.project.places, place) or Y.map(), "objects"))) do
        if P.get(x, "id") == oid then o = x break end
      end
      if o == nil then fail(where .. ": its spot (" .. S(c.at) .. ") is gone. Please set it again") end
      world, center = ctx:place_world(place), o.pos
    elseif P.T(P.get(c, "place")) then
      world, center = ctx:place_world(c.place), P.get(c, "pos") or ctx:place_center(c.place)
      if not P.T(center) then center = ctx:place_center(c.place) end
    elseif P.T(P.get(c, "world")) and P.T(P.get(c, "pos")) then
      world, center = c.world, c.pos
    else
      fail(where .. ": in which area? (a spot)")
    end
    local area = ctx.qid .. "_s" .. S(i) .. "_c" .. (k + 1) .. "_area"
    setdefault(setdefault(meta, world, Y.map()), "areas", Y.map())[area] = GEN.area(center, F(P.get(c, "radius", 10)))
    yes, no = M("inside", world .. "/" .. area), M("outside", world .. "/" .. area)
  elseif kind == "item" then
    if waiting then fail(where .. ": for waiting until the player has an item, use Collect") end
    if not P.T(P.get(c, "item")) then fail(where .. ": which item?") end
    local fact = ctx.qid .. "_s" .. S(i) .. "_c" .. (k + 1) .. "_has"
    pre[#pre + 1] = {"script.s" .. S(i) .. "_c" .. (k + 1) .. "_has",
                     GEN.item_call(ctx, "CjHasItemsNow", c.item, {"count", I(P.get(c, "count", 1)), "fact", fact})}
    yes, no = M("factdb", L(fact, "=", 1)), M("factdb", L(fact, "=", 2))
  elseif kind == "quest" then
    local q = P.get(c, "quest") or Y.map()
    if not (P.T(P.get(q, "file")) and P.T(P.get(q, "obj"))) then fail(where .. ": which quest (or objective)?") end
    local state = P.or_(P.get(c, "state"), "done")
    local status
    for _, st in ipairs(GEN.QUEST_STATES) do if st[1] == state then status = st[3] end end
    if not status then fail(where .. ": unknown quest state '" .. S(P.get(c, "state")) .. "'") end
    local entry = M("file", q.file, "obj", I(q.obj))
    yes = M("journal", entry, "status", status)
    no = M("journal", entry, "status", status, "inverted", true)
  elseif kind == "time" then
    local ok, fr, to = pcall(function()
      return seconds_of(P.or_(P.get(c, "from"), "20:00")), seconds_of(P.or_(P.get(c, "to"), "06:00"))
    end)
    if not ok then fail(where .. ": time of day from and to as hh:mm") end
    yes, no = M("period", L(fr, to)), M("period", L(to, fr))
  elseif kind == "present" then
    local tag = P.T(P.get(c, "who")) and ctx:object_tag(c.who) or P.get(c, "tag")
    if not P.T(tag) then fail(where .. ": who?") end
    yes = M("present", L(S(tag)))
    no = M("nor", L(M("present", L(S(tag)))))
  elseif kind == "combat" then
    yes, no = M("combat", true), M("combat", false)
  elseif kind == "near" or kind == "health" or kind == "alive" or kind == "state" or kind == "gone" or
         kind == "riding" or kind == "doing" then
    yes = GEN.person_check(ctx, kind, c, where)
    no = M("nor", L(yes))
  else
    fail(where .. ": unknown condition '" .. S(kind) .. "'")
  end
  if P.T(P.get(c, "not")) then return no, yes end
  return yes, no
end

-- a check of a person (or of the player) as the game's quests write it: an actor condition with the check inside, or
-- a condition of the game's scripts by itself (quest_encoder: "actor" / "scripted")
function GEN.person_check(ctx, kind, c, where)
  local function tag(key) return P.T(P.get(c, key)) and ctx:object_tag(c[key]) or "PLAYER" end
  if kind == "near" then
    local far = P.T(P.get(c, "farther"))
    return M("actor", tag("who"), "check", "CQCDistanceTo", "props", L(
      L("targetNodeTag", "CName", tag("to")), L("distance", "Float", F(P.get(c, "metres", 5))),
      L("compareFunc", "ECompareFunc", far and "CF_Greater" or "CF_LessEqual")))
  end
  if kind == "health" then
    return M("actor", tag("who"), "check", "W3QuestCond_Health", "props", L(
      L("condition", "ECompareOp", "CO_LesserEq"), L("percents", "Int32", I(P.get(c, "percent", 20)))))
  end
  if kind == "alive" then
    if not P.T(P.get(c, "who")) then fail(where .. ": who?") end
    return M("actor", tag("who"), "check", "CQCIsAlive", "props", Y.list({}))
  end
  if kind == "state" then
    local state = Q.pick(Q.PERSON_STATES, P.or_(P.get(c, "state"), "combat"), 3)
    return M("actor", tag("who"), "check", "W3QuestCond_IsInState", "props",
             L(L("actorState", "EQuestNPCStates", state)))
  end
  if kind == "gone" then
    if not P.T(P.get(c, "who")) then fail(where .. ": who?") end
    return M("scripted", "W3QuestCond_ActorIsDespawned", "props", L(L("actorTag", "CName", tag("who"))))
  end
  if kind == "riding" then
    local on = P.or_(P.get(c, "on"), "horse")
    local props = on == "any" and L(L("anyVehicle", "Bool", true)) or
                  L(L("vehicleType", "EVehicleType", Q.pick(Q.RIDES, on, 3)))
    return M("actor", "PLAYER", "check", "W3QuestCond_IsInVehicle", "props", props)
  end
  local does = Q.pick(Q.PLAYER_DOES, P.or_(P.get(c, "does"), "swimming"), 3)
  return M("scripted", "W3QuestCond_PlayerState", "props", L(L("playerState", "EQuestConditionPlayerState", does)))
end

-- a step's conditions together -> holds, holds not: all of them (or one of them: any) - and the reverse
function GEN.conditions(ctx, i, s, meta, pre, waiting)
  local conds = Q.conditions_of(s)
  if #conds == 0 then fail("step " .. S(i) .. ": " .. (waiting and "wait until" or "if") .. " - what? (a condition)") end
  local yes, no = Y.list({}), Y.list({})
  for k, c in ipairs(conds) do
    local y, n = GEN.condition(ctx, i, k - 1, c, meta, pre, waiting)
    yes[k], no[k] = y, n
  end
  if #conds == 1 then return yes[1], no[1] end
  if P.T(P.get(s, "any")) then return M("any", yes), M("all", no) end
  return M("all", yes), M("any", no)
end

-- a step's journal line: its own, or the one made from it
function GEN.caption(ctx, kind, s)
  local t = P.get(s, "text")
  if P.T(t) then return t end
  return Q.default_text(kind, s, ctx:own_items(), ctx.names)
end

-- which step an error is about, in the graph's words: its journal line, or its kind
function GEN.which(kind, args, q, ctx)
  local LABEL = require("conjunction.questboard").LABEL
  local line = P.get(args or Y.map(), "text")
  if not P.T(line) then line = Q.default_text(kind, args or Y.map(), P.get(q, "items"), ctx and ctx.names) end
  return " - the " .. (LABEL[kind] or kind) .. " step" .. (P.T(line) and (" '" .. S(line) .. "'") or "")
end

-- --- what the game's files tell (read once, the app's way)
local function depot()
  if GEN._depot == nil then
    local ok, d = pcall(function() return require("conjunction.depot").open(require("conjunction.config").load().game) end)
    GEN._depot = ok and d or false
  end
  return GEN._depot or nil
end
local function first_exports(data, n)
  local CR = require("conjunction.cr2w")
  local f = CR.parse(data)
  local out = {}
  for k = 1, math.min(n, #f.exports) do out[k] = f.exports[k][1] end
  return out
end

GEN.CLUE_CLASSES = {W3MonsterClue = true, W3ClueCorpse = true, W3ClueStash = true, W3DestroyableClue = true,
                    W3MonsterClueAnimated = true, W3MonsterClueScent = true}
local clue_class = {}
-- is it one of the game's witcher-sense clues (examined by itself)? unknown (no game to look in): yes
function GEN.is_clue_template(template)
  local key = PYS.lower(template)
  if clue_class[key] == nil then
    local ok, v = pcall(function()
      local d = depot()
      if not d then return true end
      if not d:exists(key) then return true end
      for _, cls in ipairs(first_exports(d:read(key), 4)) do if GEN.CLUE_CLASSES[cls] then return true end end
      return false
    end)
    clue_class[key] = (not ok) or v
  end
  return clue_class[key]
end

GEN.USABLE = {"Door", "Switch", "Lever", "Elevator", "Gate", "Mechanism", "Lock", "Interaction", "Bed", "Boat",
              "Fireplace", "Lamp", "Torch", "Board", "Altar"}
-- does using it mean something to the game (its own interaction)? unknown: yes
function GEN.usable(template)
  local cls = Q.template_class(template)
  if cls == "" then return true end
  local low = PYS.lower(cls)
  for _, w in ipairs(GEN.USABLE) do if low:find(PYS.lower(w), 1, true) then return true end end
  return false
end

local own_talk = {}
-- does the template bring a talk of its own (a CStorySceneComponent: a merchant's shop)? no game: no
function GEN.has_own_talk(template)
  local key = PYS.lower(template)
  if own_talk[key] == nil then
    local ok, v = pcall(function()
      local d = depot()
      if not d or not d:exists(key) then return false end
      for _, cls in ipairs(first_exports(d:read(key), 12)) do if cls == "CStorySceneComponent" then return true end end
      return false
    end)
    own_talk[key] = ok and v or false
  end
  return own_talk[key]
end

-- an examine point: a clue of the game's own kind without a mesh, beside an object that is no clue itself
function GEN.examine_point()
  return M("entityObject", M(
    ".type", "W3MonsterClue", "isInteractive", true, "isVisible", true, "isAvailable", true, "isReusable", false,
    "interactionAnim", "PEA_ExamineGround", "maxDetectionDistance", 4.0, "components", M(
      "InteractiveClue", M(".type", "CInteractionComponent", "actionName", "Examine", "rangeMax", 1.5,
                           "reportToScript", true),
      "focus", M(".type", "CFocusActionComponent", "actionName", "Examine"))))
end

-- the graph's blocks dropped but not yet told what they do
GEN.PLACEHOLDERS = {goal = "what the player does", action = "what happens", choice = "which choice",
                    parallel = "Meanwhile or Stop lane"}
-- steps that change the world (a test that starts later still gets them)
GEN.WORLD_ACTIONS = {}
for _, k in ipairs({"show", "hide", "fact", "hostile", "immortal", "door", "switch", "lock", "item", "weather", "time",
                    "stands", "walk", "patrol", "portal", "lights", "presence", "encounters", "worldchange"}) do
  GEN.WORLD_ACTIONS[k] = true
end

-- what the player would carry after a step a test skips: the items a loot / collect step has him take, a reward's
function GEN.carried(step)
  local kind, a = step_type(step)
  a = a or Y.map()
  local got = {}
  if kind == "loot" or kind == "collect" then
    if P.T(P.get(a, "item")) then got[1] = M("item", a.item, "count", P.get(a, "count", 1)) end
    for _, x in ipairs(P.list(P.get(a, "more_items"))) do if P.T(P.get(x, "item")) then got[#got + 1] = x end end
  elseif kind == "reward" then
    for _, x in ipairs(P.list(P.get(a, "items"))) do got[#got + 1] = Y.is_map(x) and x or M("item", x) end
  end
  local out = {}
  for _, x in ipairs(got) do
    if P.T(P.get(x, "item")) then out[#out + 1] = M("item", M("item", x.item, "count", I(P.get(x, "count", 1)))) end
  end
  return out
end

-- {id = seconds} radish gives lines without a recording (speech.text_timing; the checks put their own in)
function GEN.text_timing(lines) return require("conjunction.speech").text_timing(lines) end

GEN.BLOCKS = {}                                  -- name -> step type (questgen_steps.lua)
GEN.BLOCK_NAMES = {}                             -- (their order)
function GEN.add_block(b)
  if GEN.BLOCKS[b.name] == nil then GEN.BLOCK_NAMES[#GEN.BLOCK_NAMES + 1] = b.name end
  GEN.BLOCKS[b.name] = b
end

return GEN
