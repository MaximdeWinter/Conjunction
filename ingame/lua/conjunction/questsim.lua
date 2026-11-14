-- A quest's logic run without the game (questsim.py): the blocks the generator makes (radish's structure) played
-- through - facts set and waited on, ways side by side, random picks, outcomes - with a stand-in player who does what
-- a step asks (walks into the area, waits, talks and takes the first way on, has the item).
--   local sim = QS.new(struct)   sim:start()   sim:play()   sim.outcomes      QS.playthrough(struct, q, qid, journals)
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local QS = {}
QS.__index = QS

local OPS = {["="] = function(a, b) return a == b end, ["!="] = function(a, b) return a ~= b end,
             [">="] = function(a, b) return a >= b end, [">"] = function(a, b) return a > b end,
             ["<="] = function(a, b) return a <= b end, ["<"] = function(a, b) return a < b end}
local PASS = {}
for _, k in ipairs({"start", "objective", "journal", "mappin", "phaseobjectives", "spawn", "spawnsets", "despawn",
                    "changelayers", "reward", "teleport", "changeworld", "settime", "shifttime", "pausetime",
                    "unpausetime", "script"}) do PASS[k] = true end
local FACT_PARAMS = {"fact", "factName", "factId", "factID"}
local PLAYER = {interaction = true, scene = true}
local S = P.str

local function startswith(s, pre) return type(s) == "string" and s:sub(1, #pre) == pre end
local function remove_value(list, v)
  for i, x in ipairs(list) do if x == v then table.remove(list, i) return true end end
  return false
end
local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
local function params(b) return P.list(P.get(b, "parameter")) end
local function param(b, key)
  for _, p in ipairs(params(b)) do if Y.is_map(p) and p[key] ~= nil then return p[key] end end
  return nil
end

function QS.new(struct, seed, answers, has_items, cuts)
  local self = setmetatable({s = struct, rng = require("conjunction.pyrandom").new(seed or 0)}, QS)
  self.cuts = cuts or {}
  self.inside, self.journal, self.hour, self.present, self.combat = {}, {}, 12, {}, false
  self.answers = answers or {}
  self.has_items = has_items ~= false
  self.facts, self.waiting, self.log, self.outcomes, self.picks = {}, {}, {}, {}, {}
  self.arrived = {}
  return self
end

-- --- the world
function QS:fact(name) return self.facts[name] or 0 end
function QS:set_fact(name, value)
  self.facts[name] = value
  self:settle()
end
function QS:test(cond)
  local f, op, value = cond[1], cond[2], cond[3]
  return OPS[op](self:fact(S(f)), value)
end

-- a condition of the game's in this world: true / false - nil: the player does it (an area, a time ...)
function QS:holds(c)
  if c.factdb ~= nil then return self:test(c.factdb) end
  if c.inside ~= nil then
    local key = P.T(P.get(c, "who")) and (S(c.who) .. "@" .. S(c.inside)) or S(c.inside)
    return self.inside[key] == true
  end
  if c.outside ~= nil then return self.inside[S(c.outside)] ~= true end
  if c.journal ~= nil then
    local j = c.journal
    local got = (self.journal[S(j.file) .. "|" .. S(j.obj)] or "JS_Inactive") == P.get(c, "status")
    return got ~= P.T(P.get(c, "inverted"))
  end
  if c.period ~= nil then
    local fr, to = math.tointeger(c.period[1]) // 3600, math.tointeger(c.period[2]) // 3600
    if fr <= to then return fr <= self.hour and self.hour < to end
    return self.hour >= fr or self.hour < to
  end
  if c.present ~= nil then
    for _, t in ipairs(c.present) do if not self.present[t] then return false end end
    return true
  end
  if c.combat ~= nil then return self.combat == P.T(c.combat) end
  -- (got may have holes - nil: the player does it - so it is counted by its list, not by ipairs)
  if c.all ~= nil then
    local got = {}
    for i, x in ipairs(c.all) do got[i] = self:holds(x) end
    for i = 1, #c.all do if got[i] == nil then return nil end end
    for i = 1, #c.all do if not got[i] then return false end end
    return true
  end
  if c.any ~= nil then
    local got, none = {}, false
    for i, x in ipairs(c.any) do got[i] = self:holds(x) end
    for i = 1, #c.any do if got[i] == true then return true end end
    for i = 1, #c.any do if got[i] == nil then none = true end end
    if none then return nil end
    return false
  end
  if c.nor ~= nil then
    local got = {}
    for i, x in ipairs(c.nor) do got[i] = self:holds(x) end
    for i = 1, #c.nor do if got[i] == nil then return nil end end
    for i = 1, #c.nor do if got[i] then return false end end
    return true
  end
  return nil
end

-- the world changes (inside, journal, hour, present, combat): waits on it go on
function QS:world(kv)
  for k, v in pairs(kv) do self[k] = v end
  self:settle()
end

-- --- running blocks
function QS:start()
  self:go("start")
  self:settle()
end

function QS:targets(b, socket)
  local out = {}
  local nxt = b[socket and ("next." .. socket) or "next"]
  if type(nxt) == "string" then nxt = {nxt} end
  for _, t in ipairs(P.list(nxt)) do
    if Y.is_map(t) then
      for k, v in pairs(t) do out[#out + 1] = {k, v ~= Y.null and v or nil} break end
    else
      out[#out + 1] = {t, nil}
    end
  end
  return out
end

function QS:go(name, in_socket)
  local b = self.s[name]
  if b == nil then error(require("conjunction.questgen").KeyError("A way leads to '" .. S(name) .. "', which does not exist"), 0) end
  self.log[#self.log + 1] = name
  local kind = name:match("^([^.]*)")
  if kind == "end" then return end
  if kind == "addfact" then
    local f, value = b.value[1], b.value[2]
    self.facts[f] = self:fact(f) + value
    for _, x in ipairs(self.cuts[name] or {}) do                 -- a cut control block: what it cuts stops waiting
      while remove_value(self.waiting, x) do end
    end
    self:on(b)
  elseif kind == "questoutcome" then
    self.outcomes[#self.outcomes + 1] = in_socket or "?"
    self:on(b)
  elseif kind == "randomize" then
    local socks = {}
    for _, k in ipairs(Y.keys(b)) do if startswith(k, "next.") then socks[#socks + 1] = k:sub(6) end end
    local pick = #socks > 0 and self.rng:choice(socks) or nil
    if startswith(name, "randomize.gwent_") or startswith(name, "randomize.fistfight_") then   -- a minigame: won
      pick = self.answers[name] or "Success"
    end
    self.picks[name] = pick
    self:on(b, pick)
  elseif kind == "waituntil" or PLAYER[kind] then
    self.waiting[#self.waiting + 1] = name
  elseif PASS[kind] then
    local fn = kind == "script" and S(P.get(b, "function", "")) or ""
    if fn == "CjRunRetired" then                 -- a newer run never comes in a stand-in play
      self.waiting[#self.waiting + 1] = name
      return
    end
    if startswith(fn, "CjHasItemsNow") then      -- counted once: 1 has it, 2 not
      self.facts[S(param(b, "fact") or "")] = self.has_items and 1 or 2
    end
    if fn == "RemoveFactQuest" then
      self.facts[(S(param(b, "factId") or ""):gsub("^cname_", "", 1))] = 0
    end
    if fn == "CjArrive" then
      if self.arrived[name] then return end
      self.arrived[name] = true
      local prm = {}
      for _, p in ipairs(params(b)) do if Y.is_map(p) then for k, v in pairs(p) do prm[k] = v end end end
      if P.T(prm.progress) then self.facts[S(prm.progress)] = prm.point or 1 end
    end
    if (startswith(fn, "CjHasItems") or startswith(fn, "CjEquipped")) and self.has_items or fn == "CjGoAt" or
       fn == "CjAwayFrom" or fn == "CjNearTo" or fn == "CjLookAt" then
      for _, p in ipairs(params(b)) do
        if Y.is_map(p) and p.fact ~= nil then self.facts[p.fact] = 1 end
      end
    elseif startswith(fn, "CjG_") then
      local f
      for _, p in ipairs(params(b)) do
        for _, k in ipairs(FACT_PARAMS) do if f == nil and Y.is_map(p) and p[k] ~= nil then f = p[k] end end
      end
      local value = param(b, "value")
      if value == nil then value = 1 end
      if f ~= nil then self.facts[S(f)] = self:fact(S(f)) + (type(value) == "number" and value or 1) end
    end
    self:on(b)
  else
    require("conjunction.questgen").fail("The simulation does not know blocks like '" .. S(name) .. "'")
  end
end

function QS:on(b, socket)
  for _, t in ipairs(self:targets(b, socket)) do self:go(t[1], t[2]) end
end

-- ways waiting on facts go on while one of them can
function QS:settle()
  local moved = true
  while moved do
    moved = false
    local list = {table.unpack(self.waiting)}
    for _, name in ipairs(list) do
      local b = self.s[name]
      if startswith(name, "waituntil.") then
        if b.conditions == nil and self:holds(b) then
          remove_value(self.waiting, name)
          self:on(b)
          moved = true
        elseif b.conditions ~= nil then
          for _, sock in ipairs(Y.keys(b.conditions)) do
            if self:holds(b.conditions[sock]) then
              remove_value(self.waiting, name)
              self:on(b, sock)
              moved = true
              break
            end
          end
        end
      end
    end
  end
end

-- --- the player: the first thing a way waits for (an area, a time, a talk) -> false: nothing to do
function QS:step_player()
  local list = {table.unpack(self.waiting)}
  for _, name in ipairs(list) do
    local b = self.s[name]
    local kind = name:match("^([^.]*)")
    local acted = true
    local fdb = b.factdb
    if PLAYER[kind] then
      remove_value(self.waiting, name)
      self:talk(name, b)
    elseif b.conditions == nil and self:holds(b) == nil then
      remove_value(self.waiting, name)
      self:on(b)
    elseif startswith(name, "waituntil.s") and b.inside ~= nil and not P.T(P.get(b, "who")) and not self:holds(b) then
      self.inside[S(b.inside)] = true             -- a goal's area (Go to): the player walks into it
      self:settle()
    elseif startswith(name, "waituntil.s") and fdb ~= nil and S(fdb[1]):sub(-11) == "_was_killed" then
      self.facts[fdb[1]] = 1
      self:settle()
    elseif startswith(name, "waituntil.s") and fdb ~= nil and S(fdb[1]):sub(-6) == "_taken" then
      self.facts[fdb[1]] = 1
      self:settle()
    else
      acted = false
    end
    if acted then
      self:settle()
      return true
    end
  end
  return false
end

-- a talk ends: the answer that goes on (a quest's talk sets its choice fact in the scene), then on
function QS:talk(name, b)
  for _, t in ipairs(self:targets(b)) do
    local conds = P.map(P.get(self.s[t[1]] or Y.map(), "conditions"))
    local want = self.answers[name]
    if want == nil then
      if conds.continue ~= nil then want = "continue" else want = Y.keys(conds)[1] end
    end
    local c = (want ~= nil and conds[want]) or Y.map()
    if Y.is_map(c) and c.factdb ~= nil then self.facts[c.factdb[1]] = c.factdb[3] end
  end
  self:on(b)
end

-- the player does everything until the quest has an outcome (each of a project's `quests`: a series, one after the
-- other) or nothing is left to do
function QS:play(limit, quests)
  quests = quests or 1
  for _ = 1, limit or 500 do
    if #self.outcomes >= quests or not self:step_player() then break end
  end
  return self.outcomes
end

QS.QUIET = {"waituntil.forever", "waituntil.setup_rest", "waituntil.alive_", "waituntil.ends_game", "waituntil.end_",
            "waituntil.retired"}

-- the quest played through by the stand-in player: true, what happened - or false, where a way stops and why
function QS.playthrough(struct, q, qid, journals)
  local sim = QS.new(struct)
  sim:start()
  local ag = P.get(q, "after_game")
  if P.T(P.get(P.map(ag), "fact")) then sim:set_fact(S(ag.fact), 1) end
  if P.T(P.get(P.map(P.get(q, "inside_game")), "phase")) then sim:set_fact(qid .. "_inside", 1) end
  if P.T(P.get(q, "after")) then sim:set_fact(require("conjunction.pystr").lower(S(q.after)) .. "_done", 1) end
  local gq = P.map(P.get(q, "game_quest"))
  if P.T(P.get(gq, "file")) and P.get(gq, "obj") ~= nil then
    local j = {}
    for k, v in pairs(sim.journal) do j[k] = v end
    j[S(gq.file) .. "|" .. S(require("conjunction.questgen").int(gq.obj))] = "JS_Success"
    sim:world({journal = j})
  end
  local quests = Y.len(P.map(P.get(P.map(journals), "quests")))
  if quests == 0 then quests = 1 end
  sim:play(500, quests)
  local stuck = {}
  for _, w in ipairs(sim.waiting) do
    local quiet = false
    for _, pre in ipairs(QS.QUIET) do if startswith(w, pre) then quiet = true end end
    if not quiet then stuck[#stuck + 1] = w end
  end
  if #sim.outcomes >= quests then
    if quests > 1 then
      local said = {}
      for k, o in ipairs(sim.outcomes) do said[k] = o == "Success" and "success" or "it fails" end
      return true, "played through all " .. quests .. " quests to their end: " .. table.concat(said, ", ")
    end
    return true, "played through to the end: " .. (sim.outcomes[1] == "Success" and "success" or "it fails")
  end
  if #sim.outcomes > 0 and #stuck == 0 then
    return false, #sim.outcomes .. " of " .. quests .. " quests end; the next one stops where a step's output leads " ..
                  "nowhere (after " .. (#sim.log > 0 and S(sim.log[#sim.log]) or "its start") .. ")"
  end
  if #stuck == 0 then return true, "played through (the quest has no end of its own)" end
  local name = stuck[1]
  local captions = {}
  local main = P.list(P.get(P.map(P.get(P.map(P.get(P.map(P.get(P.map(journals), "quests")), qid)), "instructions")), "main"))
  for _, ob in ipairs(main) do
    for oid, o in pairs(P.map(ob)) do captions[oid] = P.get(o, "caption") end
  end
  local step = name:match("^waituntil%.(s%d+)")
  local where = (step and P.T(captions[step])) and ("'" .. S(captions[step]) .. "'") or "a step"
  local b = struct[name] or Y.map()
  if b.factdb ~= nil then
    local f = b.factdb[1]
    local set_here = false
    for k, x in pairs(struct) do
      if startswith(k, "addfact.") and Y.is_map(x) and P.list(P.get(x, "value", Y.list({Y.null})))[1] == f then set_here = true end
      if startswith(k, "script.") and Y.is_map(x) then
        for _, p in ipairs(params(x)) do
          for _, n in ipairs(FACT_PARAMS) do if Y.is_map(p) and p[n] == f then set_here = true end end
        end
      end
    end
    return false, where .. " waits for the fact '" .. S(f) .. "'" ..
                  (set_here and "" or " - nothing in this quest sets it (one of the game's?)")
  end
  return false, where .. " waits - the stand-in player could not go on (" .. name .. ")"
end

local _ = has
return QS
