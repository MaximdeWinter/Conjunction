-- quest_graph.py: a quest as nodes and wires (the look of PathView), pure data - graph_layout sizes and places it,
-- graph_route draws its wires, ui/graph_view.lua shows it.
--
--   build_nodes(quest, names) -> Graph      the quest's graph as it was drawn (the Quest tab)
--   build(quest, names) -> Graph            the older form's graph (columns; only migrate uses it, for where the
--                                           nodes stood - its wires are not made here)
-- A Graph: {nodes = ordered map id -> Node, wires = {Wire}, chapters = {id}, free = true}. A Node: id, kind, title,
-- block, subject, text, missing, exits ({Exit}), colour, lane, path, number, card ({steps, i} - i 1-based, nil for a
-- column's head), goes_on, next_wired, hidden, x, y, w, h. An Exit: label, to, style, set, can_fail, wired. A Wire:
-- src, dst, port ("next" or the exit's index, 0-based as the app's), enter, style, colour, link, points.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local QB = require("conjunction.questboard")
local QG = {}

QG.FAMILY = {people = "#5aa9e6", place = "#8fd07a", things = "#e3c65f", fight = "#e57a7a", choice = "#b99be6",
             time = "#9aa0b0", story = "#c8c8d0", action = "#5fcbb9", lane = "#e07fae", open = "#808090",
             scene = "#f0a050"}
QG.SUCCESS, QG.FAIL, QG.MUTED = "#22c55e", "#ef4444", "#808090"
QG.FAIL_MARK = 48

QG.GOAL_KINDS, QG.ACTION_KINDS = {}, {}
for _, g in ipairs(QB.GOALS) do if g[1] ~= "either" then QG.GOAL_KINDS[#QG.GOAL_KINDS + 1] = g[1] end end
for _, g in ipairs(QB.ACTIONS) do
  if g[1] ~= "meanwhile" and g[1] ~= "stop" and g[1] ~= "random" then QG.ACTION_KINDS[#QG.ACTION_KINDS + 1] = g[1] end
end
-- (a scene: a talk that plays at once, marked scene - its kinds none, it is one thing)
QG.BLOCKS = {{"goal", "Goal", QG.GOAL_KINDS}, {"action", "Action", QG.ACTION_KINDS}, {"scene", "Scene", {}},
             {"choice", "Choice", {"either", "random", "if"}}, {"parallel", "Meanwhile", {"meanwhile", "stop"}},
             {"chapter", "Chapter", {"chapter"}}, {"end", "End", {"end"}}}
QG.KINDS_OF = {}
for _, b in ipairs(QG.BLOCKS) do QG.KINDS_OF[b[1]] = b[3] end
QG.PLACEHOLDERS = {goal = true, action = true, choice = true, parallel = true}
QG.LABEL = {}
for k, v in pairs(QB.LABEL) do QG.LABEL[k] = v end
for k, v in pairs({["if"] = "If", ["end"] = "End", goal = "Goal", action = "Action", choice = "Choice",
                   parallel = "Meanwhile", chapter = "Chapter", scene = "Scene"}) do QG.LABEL[k] = v end

-- a step of the Scene block: a talk marked scene
function QG.is_scene(step)
  local k, a = QB.step_kind(step)
  return k == "talk" and a ~= nil and P.T(P.get(a, "scene")) or false
end

-- which block of the sidebar a step kind belongs to
function QG.block_of(kind)
  if QG.KINDS_OF[kind] then return kind end
  for _, b in ipairs(QG.BLOCKS) do
    for _, k in ipairs(b[3]) do if k == kind then return b[1] end end
  end
  return QB.GOAL_KINDS[kind] and "goal" or "action"
end

local function Exit(label, to, style, set, can_fail)
  return {label = label, to = to, style = style or "branch", set = set, can_fail = can_fail or false, wired = false}
end
QG.Exit = Exit

local function Node(id, kind, title, o)
  o = o or {}
  return {id = id, kind = kind, title = title, block = o.block or "", subject = o.subject or "", text = o.text or "",
          missing = o.missing or {}, exits = o.exits or {}, colour = o.colour or "", lane = o.lane or "",
          path = o.path or "", number = o.number or 0, card = o.card, insert = o.insert,
          goes_on = o.goes_on == nil and true or o.goes_on, hidden = false, x = 0, y = 0, w = 0, h = 0}
end
QG.Node = Node

local function Graph()
  return {nodes = Y.map(), wires = {}, main = nil, chapters = {}, loose = {}, columns = {}}
end
local function add(g, node)
  g.nodes[node.id] = node
  return node.id
end

-- an exit that fails the quest right at the node (a mark beside it, no wire)
function QG.fails_here(e) return e.to == "fail" and e.style ~= "port" end

-- names: quest.display_names (the name shown above a person, as the card and the journal call them)
local function name_of(ref, quest, names)
  ref = P.str(P.or_(ref, ""))
  if P.startswith(ref, "own:") then
    return require("conjunction.quest")._item_name(ref, P.get(quest or Y.map(), "items"))
  end
  if names and P.T(names[ref]) then return P.str(names[ref]) end
  return P.replace(ref:match("([^/]*)$"), "_", " ")
end
QG._name = name_of

local function first_of(...)
  local keys = {...}
  return function(a, quest, names)
    for _, k in ipairs(keys) do
      local v = P.get(a, k)
      if Y.is_list(v) or (type(v) == "table" and v ~= Y.null and not Y.is_map(v)) then
        local parts = {}
        for _, x in ipairs(v) do if P.T(x) then parts[#parts + 1] = name_of(x, quest, names) end end
        v = table.concat(parts, ", ")
      elseif P.T(v) then
        v = name_of(v, quest, names)
      end
      if P.T(v) then return v end
    end
    return ""
  end
end
QG._first = first_of

local function count(items, word)
  local n = #P.list(items)
  return n .. " " .. word .. (n ~= 1 and "s" or "")
end

-- leads an exit elsewhere by setting d[key]: fmt "end" (continue / fail / path:x), "path" (a bare path id, gone for
-- on down), "way" (path:x / fail, gone for on down)
local function setter(d, key, fmt)
  return function(to)
    if fmt == "end" then
      d[key] = to == "next" and "continue" or to
    elseif fmt == "path" then
      if P.startswith(to, "path:") then d[key] = to:sub(6) else Y.remove(d, key) end
    elseif to == "next" then
      Y.remove(d, key)
    else
      d[key] = to
    end
  end
end

-- where a stored value leads, in exit words
local function to_words(value, fmt)
  if fmt == "path" then return P.T(value) and ("path:" .. P.str(value)) or "next" end
  local v = P.str(P.or_(value, "continue"))
  if v == "continue" then return "next" end
  return v
end

local function hands_over(a)
  local D = require("conjunction.dialogue")
  for _, x in ipairs(D.walk(D.from_step(a))) do if P.has(x, "give") then return true end end
  return false
end

local function talk_exits(a, quest)
  local D = require("conjunction.dialogue")
  local lines = D.from_step(a)
  local out = {}
  for _, x in ipairs(D.walk(lines)) do
    if not (P.has(x, "who") or not P.has(x, "text")) then
      local to = to_words(P.get(x, "end"), "end")
      if to ~= "back" and to ~= "up" and to ~= "on" then
        out[#out + 1] = Exit(P.or_(P.get(x, "text"), "..."), to, nil, setter(x, "end", "end"), true)
      end
    end
  end
  if #out > 0 and D.outcomes(lines).continue then
    local any_next = false
    for _, e in ipairs(out) do if e.to == "next" then any_next = true end end
    if not any_next then table.insert(out, 1, Exit("dialogue ends", "next")) end
  end
  return out
end

local function either_exits(a, quest)
  local out = {}
  if P.has(a, "ways") and not P.T(P.get(a, "options")) then
    for k, w in ipairs(a.ways) do
      out[#out + 1] = Exit("way " .. k, to_words(P.get(w, "path"), "path"), nil, setter(w, "path", "path"))
    end
    return out
  end
  for _, o in ipairs(P.list(P.get(a, "options"))) do
    local gk, ga = QB.step_kind(P.or_(P.get(o, "goal"), Y.map({"goto", Y.map()})))
    local what = first_of("object", "target")(ga, quest)
    out[#out + 1] = Exit((QB.LABEL[gk] or gk) .. (P.T(what) and (" " .. what) or ""), to_words(P.get(o, "path"), "path"),
                         nil, setter(o, "path", "path"))
  end
  return out
end

local function random_exits(a, quest)
  local out = {}
  for k, w in ipairs(P.list(P.get(a, "ways"))) do
    out[#out + 1] = Exit("outcome " .. k, to_words(P.get(w, "path"), "path"), nil, setter(w, "path", "path"))
  end
  return out
end

local function lost_exits(a, quest)
  return {Exit("won", "next"), Exit("lost", to_words(P.get(a, "lost"), "way"), nil, setter(a, "lost", "way"), true)}
end

local function if_exits(a, quest)
  local out = {}
  for _, side in ipairs({"yes", "no"}) do
    out[#out + 1] = Exit(side, to_words(P.get(a, side), "way"), nil, setter(a, side, "way"), true)
  end
  return out
end

local function path_label(pid, quest)
  local p = P.get(P.or_(P.get(quest, "paths"), Y.map()), pid)
  return P.or_(P.get(P.or_(p, Y.map()), "label"), pid, "")
end

local function if_subject(a, quest)
  if P.T(P.get(a, "conditions")) then return require("conjunction.quest").conditions_text(a) end
  if P.T(P.get(a, "path")) then return "'" .. P.str(path_label(a.path, quest)) .. "' was taken" end
  if P.T(P.get(a, "fact")) then
    return P.str(a.fact) .. " " .. P.str(P.or_(P.get(a, "op"), ">=")) .. " " .. P.str(P.get(a, "value", 1))
  end
  return ""
end

local function meanwhile_exits(a, quest)
  return {Exit("meanwhile", to_words(P.get(a, "path"), "path"), "lane", setter(a, "path", "path"))}
end

local function Kind(family, subject, exits, text)
  return {family = family or "story", subject = subject, exits = exits, text = text}
end

local WAITFOR = {combat = "a fight", peace = "the fight over", senses = "witcher senses"}
QG.KINDS = {
  talk = Kind("people", first_of("npc"), talk_exits),
  deliver = Kind("people", first_of("npc")),
  follow = Kind("people", first_of("who")),
  ["goto"] = Kind("place", function(a, q, names)
    local m = P.get(a, "mode")
    if m == "near" or m == "look" then return first_of("who")(a, q, names) end
    if P.T(P.get(a, "pos")) or P.T(P.get(a, "at")) then return "a spot" end
    return ""
  end),
  wait = Kind("time", function(a, q) return P.str(P.or_(P.get(a, "time"), "")) end),
  waitfact = Kind("time", function(a, q)
    if P.T(P.get(a, "conditions")) then return if_subject(a, q) end
    return first_of("fact")(a, q)
  end),
  waitfor = Kind("time", function(a, q)
    local what = P.or_(P.get(a, "what"), "senses")
    if what == "health" then return "health " .. P.str(P.get(a, "percent", 30)) .. " %" end
    return WAITFOR[what] or ""
  end),
  loot = Kind("things", first_of("object")),
  examine = Kind("things", first_of("object")),
  use = Kind("things", first_of("object")),
  collect = Kind("things", first_of("item")),
  equip = Kind("things", first_of("item")),
  read = Kind("things", first_of("item")),
  notice = Kind("things", function(a, q) return P.str(P.or_(P.get(a, "title"), "")) end),
  clues = Kind("things", function(a, q) return count(P.get(a, "clues"), "clue") end),
  kill = Kind("fight", first_of("targets", "target")),
  defeat = Kind("fight", first_of("target")),
  fistfight = Kind("fight", first_of("targets"), lost_exits),
  race = Kind("fight", first_of("racers")),
  gwent = Kind("fight", first_of("deck"), lost_exits),
  all = Kind("choice", function(a, q) return count(P.get(a, "options"), "goal") end),
  either = Kind("choice", function(a, q) return count(P.or_(P.get(a, "options"), P.get(a, "ways")), "way") end,
                either_exits),
  random = Kind("choice", function(a, q) return count(P.get(a, "ways"), "way") end, random_exits,
                function() return "" end),
  ["if"] = Kind("choice", nil, if_exits, if_subject),
  meanwhile = Kind("lane", nil, meanwhile_exits, function(a, q) return path_label(P.get(a, "path"), q) end),
  stop = Kind("lane", nil, nil, function(a, q) return path_label(P.get(a, "path"), q) end),
  chapter = Kind("story"),
  portal = Kind("action", first_of("a")),
}

function QG.kind(k)
  return QG.KINDS[k] or Kind(QG.block_of(k) == "action" and "action" or "story")
end

-- what an action does, in a few words (the node's line under its title)
function QG.action_text(k, a, quest)
  if k == "say" then return P.or_(P.get(a, "text"), "...") end
  if k == "reward" then
    local parts = {}
    if P.T(P.get(a, "money")) then parts[#parts + 1] = P.str(a.money) .. " crowns" end
    if P.T(P.get(a, "xp")) then parts[#parts + 1] = P.str(a.xp) .. " XP" end
    if P.T(P.get(a, "items")) then parts[#parts + 1] = count(a.items, "item") end
    return table.concat(parts, ", ")
  end
  if k == "note" or k == "message" or k == "tutorial" then return P.or_(P.get(a, "text"), "") end
  if k == "playas" then
    if not P.T(P.get(a, "as")) then return "" end
    local D = require("conjunction.dialogue")
    local who = P.or_(P.get(P.or_(P.get(D.PLAYERS, a.as), Y.map()), "label"), a.as)
    local look = ""
    if a.as == "ciri" then look = QB.label_in(QB.CIRI_LOOKS, P.or_(P.get(a, "look"), ""), "") end
    return P.str(who) .. (look ~= "" and (", " .. look) or "")
  end
  if k == "fact" then return P.str(P.or_(P.get(a, "name"), "?")) .. " = " .. P.str(P.get(a, "value", 1)) end
  return first_of("who", "target", "object", "item", "place", "function", "weather", "at")(a, quest)
end

-- --- the older form's graph (columns), for where migrate puts its nodes
local function Column(nodes, then_, colour, steps)
  return {nodes = nodes, ["then"] = then_ or "join", colour = colour or "", steps = steps, forks = {}, parent = nil}
end

function QG.build(quest, names)
  local default_text = require("conjunction.quest").default_text
  local g = Graph()
  local paths = P.or_(P.get(quest, "paths"), Y.map())
  local columns = g.columns
  local BUILDING = {}
  local column, reach

  local function step_node(steps, i, colour, prefix, number)
    local k, a = QB.step_kind(steps[i])
    local spec = QG.kind(k)
    local b = QG.block_of(k)
    local nid = prefix .. tostring(steps[i])
    local common = function(o)
      o.block, o.lane, o.path, o.card, o.insert = b, colour, prefix:sub(1, -2), {steps = steps, i = i},
          {steps = steps, i = i + 1}
      return o
    end
    if QG.PLACEHOLDERS[k] then
      return Node(nid, k, QG.LABEL[k]:upper(), common({missing = {"what it does"}, colour = QG.FAMILY.open}))
    end
    if k == "chapter" then
      return Node(nid, "chapter", "CHAPTER", common({text = P.or_(P.get(a, "title"), "Chapter"),
                                                     colour = QG.FAMILY.story}))
    end
    if k == "end" then
      local fail = P.get(a, "how") == "fail"
      return Node(nid, "end", fail and "QUEST ENDS: FAILED" or "QUEST ENDS: SUCCESS",
                  common({colour = fail and QG.FAIL or QG.SUCCESS, goes_on = false}))
    end
    local exits = spec.exits and spec.exits(a, quest) or {}
    local text
    if spec.text then
      text = P.or_else(P.get(a, "text"), function() return spec.text(a, quest) end)
    elseif b == "goal" or k == "either" then
      text = P.or_else(P.get(a, "text"), function() return default_text(k, a, P.get(quest, "items"), names) end)
    else
      text = QG.action_text(k, a, quest)
    end
    local goes_on = #exits == 0
    local all_lane = true
    for _, e in ipairs(exits) do
      if e.to == "next" then goes_on = true end
      if e.style ~= "lane" then all_lane = false end
    end
    goes_on = goes_on or all_lane
    local title = (QG.LABEL[k] or QB.LABEL[k] or k):upper()
    if k == "talk" and hands_over(a) then title = "DELIVER" end
    return Node(nid, k, title, common({subject = spec.subject and spec.subject(a, quest, names) or "", text = P.str(text),
                                       missing = QB.missing(k, a), exits = exits, colour = QG.FAMILY[spec.family],
                                       number = number, goes_on = goes_on}))
  end

  column = function(steps, colour, then_, head, prefix)
    prefix = prefix or ""
    local col = Column({}, then_, colour, steps)
    col.nodes[#col.nodes + 1] = add(g, head)
    local number = 0
    for i, st in ipairs(steps) do
      local k = QB.step_kind(st)
      local counted = (QG.block_of(k) == "goal" or k == "either") and not QG.PLACEHOLDERS[k]
      if counted then number = number + 1 end
      local n = step_node(steps, i, colour, prefix, counted and number or 0)
      col.nodes[#col.nodes + 1] = add(g, n)
      if k == "chapter" then g.chapters[#g.chapters + 1] = n.id end
    end
    local last = g.nodes[col.nodes[#col.nodes]]
    local ends = {lane = {"runs_out", "RUNS OUT", QG.MUTED}, done = {"done", "QUEST DONE", QG.SUCCESS},
                  success = {"success", "QUEST ENDS: SUCCESS", QG.SUCCESS},
                  fail = {"fail", "QUEST ENDS: FAILED", QG.FAIL}}
    local e = ends[then_]
    if e and last.kind ~= "end" then
      col.nodes[#col.nodes + 1] = add(g, Node(prefix .. tostring(steps) .. ".end", e[1], e[2],
                                              {colour = e[3], lane = colour, path = prefix:sub(1, -2),
                                               insert = {steps = steps, i = #steps + 1}}))
    end
    for i, nid in ipairs(col.nodes) do
      for k, ex in ipairs(g.nodes[nid].exits) do
        local sub = reach(ex, nid)
        if sub ~= nil then
          col.forks[nid] = col.forks[nid] or {}
          table.insert(col.forks[nid], {k - 1, sub})
          if sub.parent == nil then sub.parent = {col, i} end
        end
      end
    end
    return col
  end

  reach = function(ex, _src)
    if not P.startswith(ex.to, "path:") then return nil end
    local pid = ex.to:sub(6)
    if P.get(paths, pid) == nil then return nil end
    if columns[pid] ~= nil then
      if columns[pid] == BUILDING then return nil end
      return columns[pid]
    end
    columns[pid] = BUILDING
    local p = paths[pid]
    local lane = ex.style == "lane"
    local colour = lane and QG.FAMILY.lane or QB.path_color(pid)
    if P.get(p, "steps") == nil then p.steps = Y.list({}) end
    local steps = p.steps
    local head = Node("path." .. pid, "path", lane and "LANE" or "PATH",
                      {text = P.str(P.or_(P.get(p, "label"), pid)), colour = colour, lane = colour, path = pid,
                       card = {steps = steps, i = nil}, insert = {steps = steps, i = 1}})
    columns[pid] = column(steps, colour, lane and "lane" or P.or_(P.get(p, "then"), "join"), head, pid .. ":")
    return columns[pid]
  end

  local steps = P.get(quest, "steps")
  if steps == nil then steps = Y.list({}) end
  local start = Node("start", "start", "QUEST STARTS", {text = P.str(P.or_(P.get(quest, "title"), "")),
                                                         colour = QG.MUTED, card = {steps = steps, i = nil},
                                                         insert = {steps = steps, i = 1}})
  g.main = column(steps, "", "done", start)
  for pid in pairs(paths) do
    if columns[pid] == nil then
      local sub = reach(Exit("", "path:" .. pid), "loose")
      if sub ~= nil then
        g.nodes[sub.nodes[1]].missing = {"nothing leads here yet"}
        g.loose[#g.loose + 1] = sub
      end
    end
  end
  return g
end

-- --- the quest as a graph of its own (quest_nodes): nodes where they stand, wires where they were drawn

-- a node's step as a list of one: the cards edit a step at (list, 1) - putting another step there puts it into the
-- node
function QG.Slot(quest, nid)
  local slot = {}
  rawset(slot, "nid", nid)                      -- (Slot.nid: the node it is)
  rawset(slot, "quest", quest)
  return setmetatable(slot, {
    __index = function(_, i) if i == 1 then return quest.nodes[nid].step end end,
    __newindex = function(_, i, v) if i == 1 then quest.nodes[nid].step = v end end,
    __len = function() return 1 end,
  })
end

QG.PORT_COLOUR = {fail = QG.FAIL, Failure = QG.FAIL, left = QG.FAIL, retry = "#e3c65f"}

-- how a step's node looks: kind, block, title, subject, text, missing, colour
function QG.look(step, quest, names)
  local default_text = require("conjunction.quest").default_text
  local k, a = QB.step_kind(step)
  a = P.or_(a, Y.map())
  local b = QG.block_of(k)
  if QG.PLACEHOLDERS[k] then return k, b, QG.LABEL[k]:upper(), "", "", {"what it does"}, QG.FAMILY.open end
  if k == "talk" and P.T(P.get(a, "scene")) then
    local spec = QG.kind(k)
    return k, "scene", "SCENE", spec.subject and spec.subject(a, quest, names) or "", P.str(P.or_(P.get(a, "text"), "Scene")),
           QB.missing(k, a), QG.FAMILY.scene
  end
  if k == "chapter" then return k, "chapter", "CHAPTER", "", P.str(P.or_(P.get(a, "title"), "Chapter")), {}, QG.FAMILY.story end
  if k == "end" then
    local fail = P.get(a, "how") == "fail"
    return k, "end", fail and "QUEST ENDS: FAILED" or "QUEST ENDS: SUCCESS", "", "", {}, fail and QG.FAIL or QG.SUCCESS
  end
  local spec = QG.kind(k)
  local text
  if spec.text then
    text = P.or_else(P.get(a, "text"), function() return spec.text(a, quest) end)
  elseif b == "goal" or k == "either" then
    text = P.or_else(P.get(a, "text"), function() return default_text(k, a, P.get(quest, "items"), names) end)
  else
    text = QG.action_text(k, a, quest)
  end
  local title = (QG.LABEL[k] or QB.LABEL[k] or k):upper()
  if k == "talk" and hands_over(a) then title = "DELIVER" end
  return k, b, title, spec.subject and spec.subject(a, quest, names) or "", P.str(text), QB.missing(k, a),
         QG.FAMILY[spec.family]
end

-- the quest's graph as it was drawn: a node per node, a wire per link (g.free: nodes moved, wires drawn by hand)
-- existing: {place/id = true} of the objects there are (nil: not checked) - a step naming one that is not there
-- gets it among what is missing (MaximdeWinter 24.10.: a container deleted in the world, the step still named it)
-- (a voice recording is "pack/line" too: "conjunction_samples/thank_you" was "gone: thank you", 13.11.)
local NOT_REFS = {voice_pack = true}
local function gone_refs(step, existing)
  local out, seen = {}, {}
  local function walk(x)
    if type(x) == "string" then
      if x:match("^[a-z0-9_]+/[a-z0-9_]+$") and not existing[x] and not seen[x] then
        seen[x] = true
        out[#out + 1] = "gone: " .. x:match("/(.*)$"):gsub("_", " ")
      end
    elseif type(x) == "table" and x ~= Y.null then
      if Y.is_map(x) then for _, k in ipairs(Y.keys(x)) do if not NOT_REFS[k] then walk(x[k]) end end
      else for _, v in ipairs(x) do walk(v) end end
    end
  end
  walk(step)
  return out
end
QG.gone_refs = gone_refs

function QG.build_nodes(quest, names, existing)
  local QN = require("conjunction.quest_nodes")
  local g = Graph()
  g.free = true
  local nodes, links = quest.nodes, P.list(P.get(quest, "links"))
  local wired = {}
  for _, ln in ipairs(links) do wired[ln[1] .. "\0" .. ln[2]] = true end
  local number = 0
  for _, nid in ipairs(QN.order(quest)) do
    local n = nodes[nid]
    local step = n.step
    local k0 = QN.step_kind(step)
    local node
    if k0 == "start" then
      node = Node(nid, "start", "QUEST STARTS", {text = P.str(P.or_(P.get(quest, "title"), "")), colour = QG.MUTED,
                                                  card = {steps = QG.Slot(quest, nid), i = nil}})
    elseif k0 == "remember" then
      node = Node(nid, "remember", "BRANCH TAKEN", {text = P.str(QN.label_of(quest, P.or_(P.get(n, "remember"), ""))),
                                                    block = "", colour = QG.FAMILY.story,
                                                    card = {steps = QG.Slot(quest, nid), i = 1}})
    else
      local k, b, title, subject, text, missing, colour = QG.look(step, quest, names)
      local counted = (b == "goal" or k == "either") and not QG.PLACEHOLDERS[k]
      if counted then number = number + 1 end
      node = Node(nid, k, title, {block = b, subject = subject, text = text, missing = P.copy_list(missing),
                                  colour = colour, number = counted and number or 0,
                                  card = {steps = QG.Slot(quest, nid), i = 1}})
      if existing then
        for _, m in ipairs(gone_refs(step, existing)) do node.missing[#node.missing + 1] = m end
      end
    end
    local ps = QN.ports(step, quest)
    node.goes_on = false
    node.exits = {}
    for _, pt in ipairs(ps) do
      if pt[1] == "next" then
        node.goes_on = true
      else
        local e = Exit(P.T(pt[2]) and pt[2] or pt[1], pt[1], "port")
        e.wired = wired[nid .. "\0" .. pt[1]] == true
        node.exits[#node.exits + 1] = e
      end
    end
    node.next_wired = wired[nid .. "\0next"] == true
    if P.T(P.get(n, "remember")) and k0 ~= "remember" then
      node.subject = (node.subject ~= "" and (node.subject .. "  ") or "") .. "(remembered)"
    end
    -- ('later' and 'fails' need no wire: talk again, the quest fails)
    local open = {}
    for _, e in ipairs(node.exits) do
      if not e.wired and e.to ~= "retry" and e.to ~= "fail" then open[#open + 1] = e.label end
    end
    if node.goes_on and not node.next_wired and node.kind ~= "start" then open[#open + 1] = "output" end
    if #open > 0 and node.kind ~= "start" then node.missing[#node.missing + 1] = table.concat(open, ", ") .. " not wired" end
    node.x, node.y = P.get(n, "x", 0), P.get(n, "y", 0)
    node.hidden = P.T(P.get(n, "hidden"))
    add(g, node)
    if k0 == "chapter" then g.chapters[#g.chapters + 1] = nid end
  end
  for _, ln in ipairs(links) do
    local a, p, b = ln[1], ln[2], ln[3]
    if g.nodes[a] ~= nil and g.nodes[b] ~= nil then
      local src = g.nodes[a]
      local port
      if p == "next" then
        port = "next"
      else
        for i, e in ipairs(src.exits) do if e.to == p then port = i - 1 break end end
      end
      if port ~= nil then
        local w = {src = a, dst = b, port = port, enter = "top", style = port == "next" and "next" or "branch",
                   colour = QG.PORT_COLOUR[p] or "", insert = nil, points = {}, link = {a, p, b}}
        g.wires[#g.wires + 1] = w
      end
    end
  end
  return g
end

return QG
