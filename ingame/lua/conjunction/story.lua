-- story.py, the part the story map needs: the game's quests as story.json holds them (the app builds it from the
-- game's quest graphs), where each lies on the story's way and in which lane.
--   ST.load() -> {version = 2, quests = {...}} or nil (not built yet)
--   ST.placed(data) -> the quests with x (in levels), lane, kind, act and unlocks
--   ST.acts(quests) -> {{name, x}}: where each act begins
--   ST.done_facts(q), ST.game_key(q), ST.chain(by_id, qid, key)
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local PS = require("conjunction.pysort")
local PYS = require("conjunction.pystr")
local NUM = require("conjunction.pynum")
local ST = {}

ST.LANES = {{"story", "Main story"}, {4, "White Orchard"}, {9, "Velen"}, {1, "Novigrad"}, {2, "Skellige"},
            {3, "Kaer Morhen"}, {11, "Toussaint"}, {"other", "Elsewhere"}}
ST.KINDS = {Chapter = "main", Side = "side", MonsterHunt = "contract", TreasureHunt = "treasure"}
ST.ACT_DIRS = {{"quests\\prologue\\", "Prologue"}, {"quests\\part_1\\", "Act I"}, {"quests\\part_2\\", "Act II"},
               {"quests\\part_3\\", "Act III"}, {"quests\\epilogues\\", "Epilogue"}}
ST.EXPANSIONS = {"Hearts of Stone", "Blood and Wine"}
ST.ACTS = {}
for _, d in ipairs(ST.ACT_DIRS) do ST.ACTS[#ST.ACTS + 1] = d[2] end
for _, e in ipairs(ST.EXPANSIONS) do ST.ACTS[#ST.ACTS + 1] = e end
local function expansion(name) return name == "Hearts of Stone" or name == "Blood and Wine" end
ST.is_expansion = expansion

function ST.file() return require("conjunction.paths").DATA .. "\\story.json" end

-- story.json (nil: not built yet, or by an older suite)
function ST.load()
  local f = io.open(ST.file(), "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  local ok, data = pcall(require("conjunction.json").decode, text)
  if not ok or type(data) ~= "table" or data.version ~= 2 then return nil end
  return data
end

local function main_code(code) return type(code) == "string" and code:match("^q%d%d%d") ~= nil end
function ST.is_main(q) return P.get(q, "type") == "Chapter" or main_code(P.get(q, "code")) end
function ST.kind_of(q) return ST.is_main(q) and "main" or (ST.KINDS[P.get(q, "type")] or "side") end
local WORLD_LANES = {[1] = true, [2] = true, [3] = true, [4] = true, [9] = true, [11] = true}
function ST.lane_of(q)
  if ST.is_main(q) then return "story" end
  local w = P.get(q, "world")
  return (type(w) == "number" and WORLD_LANES[w]) and w or "other"
end
function ST.act_of(q)
  if expansion(P.get(q, "game")) then return q.game end
  if not ST.is_main(q) then return nil end
  local low = PYS.lower(P.str(P.or_(P.get(q, "file"), "")))
  for _, d in ipairs(ST.ACT_DIRS) do if low:sub(1, #d[1]) == d[1] then return d[2] end end
  return nil
end

local function copy(q)
  local out = {}
  for k, v in pairs(q) do out[k] = v end
  return out
end
local function truthy(v) return P.T(v) end

-- the quests to show, each with x (its place on the way, in levels: its own level, never before a quest it waits
-- for, an expansion's never before its story begins), lane, kind, act and unlocks (story.placed)
function ST.placed(data)
  local quests, order = {}, {}
  for _, q in ipairs(data.quests) do
    local c = copy(q)
    c.unlocks, c.lane, c.kind = {}, ST.lane_of(q), ST.kind_of(q)
    if quests[q.id] == nil then order[#order + 1] = q.id end
    quests[q.id] = c
  end
  for _, qid in ipairs(order) do
    local q = quests[qid]
    q.act = ST.act_of(q)
    local by = {}
    for _, b in ipairs(P.list(P.get(q, "by"))) do if quests[b] ~= nil and b ~= q.id then by[#by + 1] = b end end
    q.by = by
    for _, b in ipairs(by) do local u = quests[b].unlocks u[#u + 1] = q.id end
  end
  -- no level of its own: the lowest level met in its lane of its game
  local lowest = {}
  local function key(game, lane) return tostring(game) .. "\0" .. tostring(lane) end
  for _, qid in ipairs(order) do
    local q = quests[qid]
    if truthy(P.get(q, "level")) then
      local k = key(q.game, q.lane)
      lowest[k] = math.min(lowest[k] or 99, q.level)
    end
  end
  for _, qid in ipairs(order) do
    local q = quests[qid]
    if not truthy(P.get(q, "level")) then
      local g = lowest[key(q.game, q.lane)]
      if not truthy(g) then g = lowest[key(q.game, "story")] end
      q.level_guess = g
    end
  end
  local function place(floor)
    local memo, busy = {}, {}
    local function x_of(qid)
      if memo[qid] ~= nil then return memo[qid] end
      local q = quests[qid]
      local lv = P.get(q, "level")
      if not truthy(lv) then lv = q.level_guess end
      if not truthy(lv) then lv = 1 end
      local own = math.max(lv + 0.0, q.act ~= nil and floor[q.act] or 0.0)
      if busy[qid] then return own end
      busy[qid] = true
      local best = own
      for _, b in ipairs(q.by) do best = math.max(best, x_of(b) + 0.4) end
      memo[qid] = best
      busy[qid] = nil
      return best
    end
    for _, qid in ipairs(order) do quests[qid].x = NUM.round(x_of(qid), 2) end
  end
  place({})
  local floor = {}
  for _, name in ipairs(ST.EXPANSIONS) do
    local lo
    for _, qid in ipairs(order) do
      local q = quests[qid]
      if q.act == name and q.lane == "story" then lo = lo and math.min(lo, q.x) or q.x end
    end
    if lo then floor[name] = lo end
  end
  place(floor)
  local out = {}
  for _, qid in ipairs(order) do out[#out + 1] = quests[qid] end
  return out
end

-- where each act begins on the way: {{name, x}} - where most of its main quests begin (the first eighth left out)
function ST.acts(quests)
  local out, last = {}, 0.0
  for _, name in ipairs(ST.ACTS) do
    local xs = {}
    for _, q in ipairs(quests) do if q.act == name and q.lane == "story" then xs[#xs + 1] = q.x end end
    if #xs > 0 then
      PS.sort(xs)
      local x
      if expansion(name) then x = xs[1]
      else
        x = math.max(xs[#xs // 8 + 1], last)
        last = x
      end
      out[#out + 1] = {name, x}
    end
  end
  return out
end

-- the facts a quest sets, the ones that read as 'it is done' first (story_view.done_facts)
function ST.done_facts(q)
  local facts, seen = {}, {}
  for _, f in ipairs(P.list(P.get(q, "sets"))) do if not seen[f] then seen[f] = true facts[#facts + 1] = f end end
  local idx = {}
  for i, f in ipairs(facts) do idx[f] = i end
  local function done(f)
    local low = PYS.lower(f)
    for _, w in ipairs({"complet", "done", "finish", "_end", "success"}) do
      if low:find(w, 1, true) then return true end
    end
    return false
  end
  return PS.sorted(facts, function(f) return {done(f) and 0 or 1, idx[f]} end)
end

local GAME_COLOUR = {["Hearts of Stone"] = true, ["Blood and Wine"] = true}
function ST.game_key(q) local g = P.get(q, "game") return GAME_COLOUR[g] and g or "base" end

-- every quest reached from qid along key ("by": all it waits for, "unlocks": all that waits for it)
function ST.chain(quests, qid, key)
  local seen, todo = {}, {qid}
  while #todo > 0 do
    local cur = table.remove(todo)
    local q = quests[cur]
    for _, other in ipairs(q and q[key] or {}) do
      if not seen[other] and quests[other] ~= nil then
        seen[other] = true
        todo[#todo + 1] = other
      end
    end
  end
  seen[qid] = nil
  return seen
end

-- a quest of the game as a quest block names it (story.journal_entry): {file, obj} from the journal index
-- (journal_index.json); nil while there is none - then it is read once, as a job of the editor ed (about a minute)
local index
ST.reading = false
function ST.journal_entry(journal, ed)
  if not index then
    local f = io.open(require("conjunction.paths").DATA .. [[\journal_index.json]], "rb")
    if f then
      local ok, data = pcall(require("conjunction.json").decode, f:read("a"))
      f:close()
      index = (ok and type(data) == "table") and data or nil
    end
  end
  if not index then
    if not ST.reading and ed and ed.job then
      ST.reading = true
      ed:job(function() require("conjunction.journal_index").build(nil, function() end) end,
             function() ST.reading = false end)
    end
    return nil
  end
  local want = PYS.lower(P.str(journal))
  for _, e in ipairs(index.entries or {}) do
    local chain = e.chain
    if e.kind == "quest" and type(chain) == "table" and #chain > 0 and PYS.lower(P.str(chain[#chain][1])) == want then
      return {file = e.file, obj = e.obj}
    end
  end
  return nil
end

local _ = Y
return ST
