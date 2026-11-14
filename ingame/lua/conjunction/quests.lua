-- quests.py, the part the Quest tab needs: several quests in one project. The project keeps the quest being edited
-- in meta.quest and the others in meta.quests; each has a key of its own (1, 2, ...) that never changes.
--   QS.all_quests(meta) -> {quest}         by key
--   QS.add(meta, title) -> key / QS.switch(meta, key) / QS.remove(meta, key)
--   QS.journal_key(qid, key) / QS.part_of(step number) -> key
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local PS = require("conjunction.pysort")
local QS = {}
QS.SPAN = 1000

function QS.key_of(q)
  local k = P.get(q or Y.map(), "key")
  if not P.T(k) then return 1 end
  return math.tointeger(tonumber(k)) or math.floor(tonumber(k))
end

-- every quest of the project, by key (the one being edited among them)
function QS.all_quests(meta)
  local out = {}
  if P.T(P.get(meta, "quest")) then out[1] = meta.quest end
  for _, q in ipairs(P.list(P.get(meta, "quests"))) do out[#out + 1] = q end
  return PS.sorted(out, QS.key_of)
end

function QS.journal_key(qid, key) return key == 1 and qid or (qid .. "q" .. key) end

-- which quest a step number belongs to (1: below 2000 - the first quest's own and its test steps)
function QS.part_of(number) return number < 2 * QS.SPAN and 1 or number // QS.SPAN end

-- the quest with this key the one being edited (nil: put the edited one back among the others)
function QS.switch(meta, key)
  local cur = P.get(meta, "quest")
  local rest = {}
  for _, q in ipairs(P.list(P.get(meta, "quests"))) do rest[#rest + 1] = q end
  if P.T(cur) then
    if P.get(cur, "key") == nil then cur.key = 1 end
    rest[#rest + 1] = cur
  end
  local chosen
  if key ~= nil then
    for _, q in ipairs(rest) do if QS.key_of(q) == key then chosen = q break end end
    if chosen == nil then error("the project has no quest " .. tostring(key)) end
  end
  if chosen ~= nil then
    local keep = {}
    for _, q in ipairs(rest) do if q ~= chosen then keep[#keep + 1] = q end end
    rest = keep
    meta.quest = chosen
  else
    Y.remove(meta, "quest")
  end
  meta.quests = Y.list(PS.sorted(rest, QS.key_of))
  if #meta.quests == 0 then Y.remove(meta, "quests") end
end

-- a new quest of the project, edited from now on -> its key
function QS.add(meta, title)
  local QN = require("conjunction.quest_nodes")
  local key = 1
  for _, q in ipairs(QS.all_quests(meta)) do key = math.max(key, QS.key_of(q)) end
  key = key + 1
  local q = QN.new_quest(title)
  q.key = key
  if P.T(P.get(meta, "quest")) and P.get(meta.quest, "key") == nil then meta.quest.key = 1 end
  QS.switch(meta, nil)
  if P.get(meta, "quests") == nil then meta.quests = Y.list({}) end
  meta.quests[#meta.quests + 1] = q
  QS.switch(meta, key)
  return key
end

-- the step number in a block's name (waituntil.s2003_choice -> 2003), nil for the quest's own blocks
function QS.step_number(block_name)
  local n = block_name:match("%.s(%d+)_") or block_name:match("%.s(%d+)$") or
            block_name:match("^[a-z]+%.[a-z]+_s(%d+)_") or block_name:match("^[a-z]+%.[a-z]+_s(%d+)$")
  return n and tonumber(n) or nil
end

-- the fact a quest waits for before it starts: another quest of the project done (after_quest: its key) or a quest
-- of another project (after: its id). nil: it starts at once. (The first quest waits for no quest of its own project:
-- the others start from its start.)
function QS.after_fact(qid, q)
  local PYS = require("conjunction.pystr")
  if P.T(P.get(q, "after_quest")) and QS.key_of(q) ~= 1 then
    return PYS.lower(QS.journal_key(qid, math.tointeger(tonumber(q.after_quest)))) .. "_done"
  end
  if P.T(P.get(q, "after")) then return PYS.lower(P.str(q.after)) .. "_done" end
  return nil
end

-- the project's quests as one graph to build: the first quest's (key 1) with the others' nodes renamed into their own
-- numbers, their starts wired from the quest's start, their items. q: the quest being edited as the caller has it. A
-- quest that starts after another one (after_fact; qid: the quest's id in the game) waits for it first, without an
-- objective - its journal entry shows with its first one. -> graph, {key = quest}
function QS.merge(meta, q, qid)
  local QN = require("conjunction.quest_nodes")
  local qs = QS.all_quests(meta)
  if #qs < 2 then
    local parts = {}
    if P.T(q) then parts[QS.key_of(q)] = q else parts[1] = q end
    return q, parts
  end
  local function ready(x)
    if rawequal(x, P.get(meta, "quest")) then x = q end
    if QN.is_graph(x) then return x end
    return QN.migrate(P.deepcopy(x), false)
  end
  local first
  for _, x in ipairs(qs) do if QS.key_of(x) == 1 then first = x break end end
  local base
  if first ~= nil and (P.T(P.get(first, "nodes")) or P.T(P.get(first, "steps"))) then
    base = P.deepcopy(ready(first))
  else
    base = QN.new_quest(P.get(first or Y.map(), "title", ""))
  end
  if P.get(base, "nodes") == nil then base.nodes = Y.map() end
  if P.get(base, "links") == nil then base.links = Y.list({}) end
  local parts = {[1] = first ~= nil and first or base}
  local items = Y.map()
  for k, v in pairs(P.map(P.get(base, "items"))) do items[k] = v end
  for _, x0 in ipairs(qs) do
    if QS.key_of(x0) ~= 1 then
      local other = ready(x0)
      local k = QS.key_of(other)
      parts[k] = other
      local names = {}
      local loose = {}
      for _, n in ipairs(Y.keys(P.map(P.get(other, "nodes")))) do
        if n ~= QN.START and not n:match("^n%d+$") then loose[#loose + 1] = n end
      end
      table.sort(loose)
      local loose_at = {}
      for i, n in ipairs(loose) do loose_at[n] = i - 1 end
      for _, nid in ipairs(Y.keys(P.map(P.get(other, "nodes")))) do
        if nid ~= QN.START then
          local m = nid:match("^n(%d+)$")
          if m and tonumber(m) < 900 then
            names[nid] = "n" .. (k * QS.SPAN + tonumber(m))
          elseif loose_at[nid] and loose_at[nid] < 99 then   -- (done, failed ...: from 900 on; 999 waits)
            names[nid] = "n" .. (k * QS.SPAN + 900 + loose_at[nid])
          else
            error(require("conjunction.questgen").ValueError(string.format(
              "quest %d: a step numbered %s - more than 899 steps in one quest", k, nid)), 0)
          end
        end
      end
      for _, nid in ipairs(Y.keys(P.map(P.get(other, "nodes")))) do
        if nid ~= QN.START then base.nodes[names[nid]] = P.deepcopy(other.nodes[nid]) end
      end
      local fact = qid and QS.after_fact(qid, other) or nil
      local gq = P.map(P.get(other, "game_quest"))
      local wait = "n" .. (k * QS.SPAN + 999)
      if P.T(P.get(gq, "file")) and not P.null(P.get(gq, "obj")) then
        -- with or after a quest of the game, as the first quest has it (quest.py: waituntil.game_quest)
        local states = P.get(gq, "when") == "with" and {"active", "done", "failed"} or {"done", "failed"}
        local conds = Y.list({})
        for _, st in ipairs(states) do
          conds[#conds + 1] = Y.map({"kind", "quest", "quest", Y.map({"file", gq.file, "obj",
                                                                     math.tointeger(tonumber(gq.obj))}), "state", st})
        end
        base.nodes[wait] = Y.map({"step", Y.map({"waitfact", Y.map({"any", true, "conditions", conds})})})
        fact = true
      elseif fact then
        base.nodes[wait] = Y.map({"step", Y.map({"waitfact", Y.map({"fact", fact})})})
      end
      if fact then base.links[#base.links + 1] = Y.list({QN.START, "next", wait}) end
      for _, l in ipairs(P.list(P.get(other, "links"))) do
        local a, port, b = l[1], l[2], l[3]
        if names[b] then
          if a == QN.START then a = fact and wait or QN.START else a = names[a] or a end
          base.links[#base.links + 1] = Y.list({a, a == wait and "next" or port, names[b]})
        end
      end
      for kk, v in pairs(P.map(P.get(other, "items"))) do items[kk] = v end
    end
  end
  if next(Y.keys(items)) ~= nil then base.items = items end
  return base, parts
end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- each quest's ends its own: the blocks of quest k (k > 1) that lead to the quest's outcome lead to quest k's
-- -> the guards to add {outcome = {guard block, the other outcome's fact, socket}}
function QS.split_outcomes(struct, parts, qid)
  local guards = Y.map()
  for _, k in ipairs(sorted_keys(parts)) do
    if k ~= 1 then
      local jk = QS.journal_key(qid, k)
      local mine = Y.map()
      for _, name in ipairs(Y.keys(struct)) do
        local b = struct[name]
        local n = QS.step_number(name)
        if n ~= nil and QS.part_of(n) == k and Y.is_map(b) then
          for _, key in ipairs(Y.keys(b)) do
            local targets = b[key]
            if P.startswith(key, "next") and Y.is_list(targets) then
              for i, t in ipairs(targets) do
                if Y.is_map(t) and Y.len(t) == 1 then
                  local target = Y.keys(t)[1]
                  local sock = t[target]
                  if target == "questoutcome.done" or target == "questoutcome.failed" then
                    local new = target .. "_q" .. k
                    targets[i] = Y.map({new, sock})
                    mine[new] = target:match("%.(.*)$")
                  end
                end
              end
            end
          end
        end
      end
      for _, outcome in ipairs(Y.keys(mine)) do
        local how = mine[outcome]
        local fact = jk .. "_" .. how
        struct[outcome] = Y.map({"quest", jk, "next", Y.list({"addfact." .. how .. "_q" .. k})})
        struct["addfact." .. how .. "_q" .. k] = Y.map({"value", Y.list({fact, 1}), "next", Y.list({"waituntil.forever"})})
      end
      for _, h in ipairs({{"done", "failed", "Success"}, {"failed", "done", "Failure"}}) do
        local outcome = "questoutcome." .. h[1] .. "_q" .. k
        if struct[outcome] ~= nil then
          guards[outcome] = {"waituntil.end_" .. h[1] .. "_q" .. k, jk .. "_" .. h[2], h[3]}
        end
      end
    end
  end
  return guards
end

-- the journal's objectives ({id = ...}, ids s<step>...) by the quest they belong to -> {key = {objective}}
function QS.objectives_by_part(objectives, parts)
  local mine = {}
  for k in pairs(parts) do mine[k] = {} end
  for _, ob in ipairs(objectives) do
    local id = Y.keys(ob)[1]
    local m = id:match("^s(%d+)")
    local k = m and QS.part_of(tonumber(m)) or 1
    if parts[k] == nil then k = 1 end
    mine[k] = mine[k] or {}
    mine[k][#mine[k] + 1] = ob
  end
  return mine
end

-- objective blocks of quest k name its own journal entry (<id>q<k>/main/s...)
function QS.retarget_objectives(struct, parts, qid)
  for _, name in ipairs(Y.keys(struct)) do
    local b = struct[name]
    if Y.is_map(b) then
      local ref = P.get(b, "objective")
      if type(ref) == "string" and P.startswith(ref, qid .. "/main/") then
        local last = ref:match("([^/]*)$")
        local m = last:match("^s(%d+)")
        local k = m and QS.part_of(tonumber(m)) or 1
        if k ~= 1 and parts[k] ~= nil then b.objective = QS.journal_key(qid, k) .. "/main/" .. last end
      end
    end
  end
end

-- a quest out of the project (not the last one)
function QS.remove(meta, key)
  local qs = QS.all_quests(meta)
  if #qs < 2 then error("A project needs at least one quest") end
  local editing = QS.key_of(P.get(meta, "quest")) == key
  local keep = {}
  for _, q in ipairs(P.list(P.get(meta, "quests"))) do if QS.key_of(q) ~= key then keep[#keep + 1] = q end end
  meta.quests = Y.list(keep)
  for _, q in ipairs(QS.all_quests(meta)) do         -- (a quest that started after it starts at once now)
    if P.get(q, "after_quest") == key then Y.remove(q, "after_quest") end
  end
  if editing then
    Y.remove(meta, "quest")
    QS.switch(meta, QS.key_of(meta.quests[1]))
  end
end

return QS
