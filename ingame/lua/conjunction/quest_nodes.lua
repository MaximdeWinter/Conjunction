-- quest_nodes.py: a quest as a graph of its own - nodes where they were put, wires where they were drawn.
--
--   quest:
--     nodes:
--       start: {step: {start: {}}, x: 0, y: 0}
--       n1:    {step: {talk: {...}}, x: 0, y: 120}
--     links:
--       - [start, next, n1]                 # [from node, its output, to node]
--
-- The older form (steps: a list; paths: lists a way leads into) becomes this once (migrate).
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PS = require("conjunction.pysort")
local D = require("conjunction.dialogue")
local QN = {}

QN.START = "start"

-- a name as the game takes it in facts and block names: [a-zA-Z0-9_] (per character, as Python's re counts them)
function QN.safe(name)
  local out = {}
  for _, c in utf8.codes(P.str(name)) do
    local ch = utf8.char(c)
    out[#out + 1] = ch:match("^[a-zA-Z0-9_]$") and ch or "_"
  end
  return table.concat(out)
end

function QN.path_fact(qid, pid) return qid .. "_path_" .. QN.safe(pid) end

function QN.is_graph(q) return Y.is_map(P.get(q or {}, "nodes")) end

-- (kind, args) of a step {kind: args}, ("", {}) for anything else
function QN.step_kind(step)
  if Y.is_map(step) and Y.len(step) == 1 then
    local k = Y.keys(step)[1]
    return k, step[k]
  end
  return "", Y.map()
end

-- a new quest: its start and an end, not wired
function QN.new_quest(title)
  return Y.map({"title", title or "", "type", "secondary", "description", "",
                "nodes", Y.map({QN.START, Y.map({"step", Y.map({"start", Y.map()}), "x", 0, "y", 0}),
                                "done", Y.map({"step", Y.map({"end", Y.map({"how", "success"})}), "x", 0, "y", 360})}),
                "links", Y.list({})})
end

-- the words of a named way (an older path's label, an output named after an answer)
function QN.label_of(quest, pid)
  quest = quest or Y.map()
  local o = P.get(P.or_(P.get(quest, "outcomes"), Y.map()), pid)
  if P.T(o) then return o end
  local p = P.get(P.or_(P.get(quest, "paths"), Y.map()), pid)
  local l = P.get(P.or_(p, Y.map()), "label")
  if P.T(l) then return l end
  return P.replace(P.str(pid), "_", " ")
end

local function end_label(e, quest)
  e = P.str(P.or_(e, "continue"))
  if P.startswith(e, "path:") then return QN.label_of(quest, e:sub(6)) end
  if P.startswith(e, "out:") then return P.replace(e:sub(5), "_", " ") end
  local named = {continue = "continue", retry = "repeatable", fail = "fail"}
  return named[e] or e
end

QN.REPEATABLE = {["goto"] = true, waitfact = true, wait = true, talk = true}

-- a goal's 'every time': {} or {until: ...} when it repeats, nil when not
function QN.repeat_of(a)
  local r = P.get(a or Y.map(), "repeat")
  if Y.is_map(r) then return r end
  if P.T(r) then return Y.map() end
  return nil
end

local function ports_of(kind, a, quest)
  if kind == "end" then return {} end
  if kind == "talk" then
    local ends = D.sorted(D.outcomes(D.from_step(a)))
    if #ends > 1 then
      local out = {}
      for _, e in ipairs(ends) do out[#out + 1] = {D.socket(e), end_label(e, quest)} end
      return out
    end
    return {{"next", ""}}
  end
  if kind == "either" and P.has(a, "ways") and not P.T(P.get(a, "options")) then
    local out = {}
    for k = 1, #P.list(P.get(a, "ways")) do out[#out + 1] = {"way" .. k, "way " .. k} end
    return #out > 0 and out or {{"next", ""}}
  end
  if kind == "either" then
    local out = {}
    for k, o in ipairs(P.list(P.get(a, "options"))) do
      local gk = QN.step_kind(P.or_(P.get(o, "goal"), Y.map({"goto", Y.map()})))
      out[#out + 1] = {"o" .. k, P.replace(gk, "_", " ")}
    end
    return #out > 0 and out or {{"next", ""}}
  end
  if kind == "random" then
    local out = {}
    for k = 1, #P.list(P.get(a, "ways")) do out[#out + 1] = {"way" .. k, "outcome " .. k} end
    return #out > 0 and out or {{"next", ""}}
  end
  if kind == "if" then return {{"yes", "yes"}, {"no", "no"}} end
  if kind == "fistfight" or kind == "gwent" then return {{"Success", "won"}, {"Failure", "lost"}} end
  if kind == "race" then return {{"won", "won"}, {"lost", "lost"}} end
  if kind == "goto" and P.T(P.get(a, "stay")) and (P.T(P.get(a, "pos")) or P.T(P.get(a, "at"))) then
    return {{"arrived", "arrived"}, {"left", "left"}}
  end
  if kind == "meanwhile" then return {{"next", ""}, {"__lane", "meanwhile"}} end
  return {{"next", ""}}
end

-- {{output, label}} of a node's step; a goal 'every time' has one more: "__every"
function QN.ports(step, quest)
  local kind, a = QN.step_kind(step)
  a = P.or_(a, Y.map())
  local out = ports_of(kind, a, quest)
  if QN.repeat_of(a) ~= nil and QN.REPEATABLE[kind] then out[#out + 1] = {"__every", "every time"} end
  return out
end

function QN.links_from(q, nid, port)
  local out = {}
  for _, ln in ipairs(P.list(P.get(q, "links"))) do
    if ln[1] == nid and (port == nil or ln[2] == port) then out[#out + 1] = ln end
  end
  return out
end

function QN.links_to(q, nid)
  local out = {}
  for _, ln in ipairs(P.list(P.get(q, "links"))) do if ln[3] == nid then out[#out + 1] = ln end end
  return out
end

-- the node ids in story order: from the start along each node's first wired output, what the other outputs lead to
-- after it, then those nothing leads to
function QN.order(q)
  local seen, out, queue = {}, {}, {QN.START}
  local links = P.list(P.get(q, "links"))
  while #queue > 0 do
    local nid = table.remove(queue, 1)
    if not seen[nid] and q.nodes[nid] ~= nil then
      seen[nid] = true
      out[#out + 1] = nid
      local main
      for _, pt in ipairs(QN.ports(q.nodes[nid].step, q)) do
        for _, ln in ipairs(links) do
          if ln[1] == nid and ln[2] == pt[1] then main = pt[1] break end
        end
        if main then break end
      end
      local firsts, rest = {}, {}
      for _, ln in ipairs(links) do
        if ln[1] == nid then
          if ln[2] == main then firsts[#firsts + 1] = ln[3] else rest[#rest + 1] = ln[3] end
        end
      end
      for k = #firsts, 1, -1 do table.insert(queue, 1, firsts[k]) end   -- (the story goes on first)
      for _, r in ipairs(rest) do queue[#queue + 1] = r end
    end
  end
  for nid in pairs(q.nodes) do if not seen[nid] then out[#out + 1] = nid end end
  return out
end

function QN.new_id(q, base)
  base = base or "n"
  local k = Y.len(q.nodes) + 1
  while q.nodes[base .. k] ~= nil do k = k + 1 end
  return base .. k
end

local function same_link(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end

local function unique(links)
  local out = Y.list({})
  for _, ln in ipairs(links) do
    local dup = false
    for _, o in ipairs(out) do if same_link(o, ln) then dup = true break end end
    if not dup then out[#out + 1] = ln end
  end
  return out
end
QN._unique = unique

-- where a way led is the wires' now: the step's own fields for it go
local function drop_routing(step)
  local kind, a = QN.step_kind(step)
  if not Y.is_map(a) then return end
  if kind == "either" then
    for _, o in ipairs(P.list(P.get(a, "options"))) do Y.remove(o, "path") end
  elseif kind == "random" then
    for _, w in ipairs(P.list(P.get(a, "ways"))) do Y.remove(w, "path") end
  elseif kind == "if" then
    Y.remove(a, "yes")
    Y.remove(a, "no")
  elseif kind == "fistfight" or kind == "gwent" then
    Y.remove(a, "lost")
  end
end

-- {step table / "start" / "end:success" / "end:fail" / "path:<id>": {x, y}} where the old graph drew them
local function old_positions(q)
  local out = {}
  local ok = pcall(function()
    local QG = require("conjunction.quest_graph")
    local L = require("conjunction.graph_layout")
    local g = QG.build(q)
    L.place(g)
    for _, n in pairs(g.nodes) do
      if n.kind == "start" then
        out.start = {n.x, n.y}
      elseif n.kind == "done" or n.kind == "success" then
        out["end:success"] = out["end:success"] or {n.x, n.y}
      elseif n.kind == "fail" then
        out["end:fail"] = out["end:fail"] or {n.x, n.y}
      elseif n.kind == "path" and P.T(n.path) then
        out["path:" .. n.path] = {n.x, n.y}
      elseif n.card ~= nil and n.card.i ~= nil then
        out[n.card.steps[n.card.i]] = {n.x, n.y}
      end
    end
  end)
  if not ok then return {} end
  return out
end

-- a quest of step lists (steps, paths) as a graph, in place; returns it (layout: nodes where the old graph drew them)
function QN.migrate(q, layout)
  if layout == nil then layout = true end
  if QN.is_graph(q) then return q end
  local positions = layout and old_positions(q) or {}
  local paths = P.or_(P.get(q, "paths"), Y.map())
  local nodes, links = Y.map({QN.START, Y.map({"step", Y.map({"start", Y.map()}), "x", 0, "y", 0})}), {}
  local firsts, firsts_set, ends = {}, {}, {}
  local ends_order = {}
  if positions.start then nodes[QN.START].x, nodes[QN.START].y = positions.start[1], positions.start[2] end
  local right = 0
  for _, p in pairs(positions) do if p[1] > right then right = p[1] end end
  right = right + 340
  local counter = 0

  local function node(step, where, nid)
    if nid == nil then
      counter = counter + 1
      nid = "n" .. counter
    end
    local at = positions[step] or where or {right, 60 * counter}
    nodes[nid] = Y.map({"step", step, "x", at[1], "y", at[2]})
    return nid
  end

  local function end_node(how)
    if ends[how] == nil then
      local where = positions["end:" .. how] or {right, 40 + 90 * #ends_order}
      ends[how] = node(Y.map({"end", Y.map({"how", how})}), where, how == "success" and "done" or "failed")
      ends_order[#ends_order + 1] = how
    end
    return ends[how]
  end

  local column, path_first
  local function target(then_, after, me)
    then_ = P.str(P.or_(then_, "continue"))
    if then_ == "continue" then return after() end
    if then_ == "retry" then return me end
    if then_ == "fail" or then_ == "success" then return end_node(then_) end
    if P.startswith(then_, "path:") then return path_first(then_:sub(6), after) end
    return after()
  end

  local NONE = {}
  local function is_first_or_end(nid)
    for _, v in pairs(firsts) do if v == nid then return true end end
    for _, v in pairs(ends) do if v == nid then return true end end
    return false
  end

  path_first = function(pid, after, remember)
    if remember == nil then remember = true end
    if firsts[pid] ~= nil then
      if firsts[pid] == NONE then return nil end
      return firsts[pid]
    end
    local p = paths[pid]
    if p == nil or p == Y.null then return nil end
    firsts[pid] = NONE                              -- (being made: a path that leads to itself)
    local then_ = P.or_(P.get(p, "then"), "join")
    local steps = P.list(P.get(p, "steps"))
    local tail
    if then_ == "lane" then
      tail = function() return nil end
    elseif then_ == "success" or then_ == "fail" then
      tail = function() return end_node(then_) end
    else
      tail = after
    end
    local first = column(steps, tail)
    if first == nil or is_first_or_end(first) then
      local head = node(Y.map({"remember", Y.map()}), positions["path:" .. pid], "way_" .. pid)
      if first ~= nil then links[#links + 1] = Y.list({head, "next", first}) end
      first = head
    end
    if remember then nodes[first].remember = pid end
    firsts[pid] = first
    return first
  end

  local function wire(st, nid, nxt)
    local kind, a = QN.step_kind(st)
    a = P.or_(a, Y.map())
    local outs = {}
    if kind == "end" then return end
    if kind == "talk" then
      local ends_ = D.sorted(D.outcomes(D.from_step(a)))
      for _, e in ipairs(ends_) do outs[#outs + 1] = {#ends_ > 1 and D.socket(e) or "next", e} end
    elseif kind == "either" then
      for k, o in ipairs(P.list(P.get(a, "options"))) do
        outs[#outs + 1] = {"o" .. k, P.T(P.get(o, "path")) and ("path:" .. P.str(o.path)) or "continue"}
      end
    elseif kind == "random" then
      for k, w in ipairs(P.list(P.get(a, "ways"))) do
        outs[#outs + 1] = {"way" .. k, P.T(P.get(w, "path")) and ("path:" .. P.str(w.path)) or "continue"}
      end
    elseif kind == "if" then
      outs = {{"yes", P.or_(P.get(a, "yes"), "continue")}, {"no", P.or_(P.get(a, "no"), "continue")}}
    elseif kind == "fistfight" or kind == "gwent" then
      outs = {{"Success", "continue"}, {"Failure", P.or_(P.get(a, "lost"), "continue")}}
    elseif kind == "goto" and P.T(P.get(a, "stay")) and (P.T(P.get(a, "pos")) or P.T(P.get(a, "at"))) then
      outs = {{"arrived", "continue"}, {"left", "fail"}}
    elseif kind == "meanwhile" then
      outs = {{"next", "continue"}}
      if P.T(P.get(a, "path")) then
        local lane = path_first(a.path, function() return nil end, false)
        if lane ~= nil then links[#links + 1] = Y.list({nid, "__lane", lane}) end
      end
    else
      outs = {{"next", "continue"}}
    end
    if #outs == 0 then outs = {{"next", "continue"}} end
    for _, o in ipairs(outs) do
      local to = target(o[2], nxt, nid)
      if to ~= nil then links[#links + 1] = Y.list({nid, o[1], to}) end
    end
  end

  column = function(steps, tail)
    local ids = {}
    for _, st in ipairs(steps) do ids[#ids + 1] = node(st) end
    for k, st in ipairs(steps) do
      local nxt
      if k < #ids then nxt = function() return ids[k + 1] end else nxt = tail end
      wire(st, ids[k], nxt)
    end
    if #ids > 0 then return ids[1] end
    return tail()
  end

  local first = column(P.copy_list(P.list(P.get(q, "steps"))), function() return end_node("success") end)
  links[#links + 1] = Y.list({QN.START, "next", first})
  for pid in pairs(paths) do path_first(pid, function() return nil end) end   -- (paths nothing led to: still there)
  Y.remove(q, "steps")
  if P.T(paths) then                                 -- (their names stay: the outputs they were are named so)
    local named = Y.map()
    for pid, p in pairs(paths) do named[pid] = P.or_(P.get(p, "label"), pid) end
    for k, v in pairs(P.or_(P.get(q, "outcomes"), Y.map())) do named[k] = v end
    q.outcomes = named
  end
  Y.remove(q, "paths")
  q.nodes = nodes                                    -- (in this order: the keys' order in project.yml)
  q.links = unique(links)
  for _, n in pairs(nodes) do drop_routing(n.step) end
  return q
end

return QN
