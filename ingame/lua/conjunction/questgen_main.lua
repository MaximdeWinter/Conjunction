-- quest.generate: the whole quest - its people (communities, their phases), every node's blocks wired as the graph's
-- wires lead, the journal, the layers shown at the start, what is set up on objects - as the app makes it.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local QN = require("conjunction.quest_nodes")
local Q = require("conjunction.quest")
local GEN = require("conjunction.questgen_steps")
local QS = require("conjunction.quests")
local M, L, F, I, S, R = GEN.map, GEN.list, GEN.float, GEN.int, GEN.str, GEN.round
local fail, need, with, setdefault, partition = GEN.fail, GEN.need, GEN.with, GEN.setdefault, GEN.partition
local step_type = GEN.step_type
local T, get = P.T, P.get

local function sorted_set(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end
local function startswith_any(s, prefixes)
  for _, p in ipairs(prefixes) do if P.startswith(s, p) then return true end end
  return false
end
local function in_list(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

-- blocks nothing leads to from the start taken out (a block counts as reached once its name stands anywhere in a
-- reached block)
local function drop_unreached(structure)
  local function names(v, out)
    if type(v) == "string" then
      if structure[v] ~= nil then out[#out + 1] = v end
    elseif Y.is_map(v) then
      for k, x in pairs(v) do names(k, out) names(x, out) end
    elseif type(v) == "table" and v ~= Y.null then
      for _, x in ipairs(v) do names(x, out) end
    end
    return out
  end
  local seen, todo = {start = true}, {"start"}
  while #todo > 0 do
    for _, n in ipairs(names(structure[table.remove(todo)], {})) do
      if not seen[n] then
        seen[n] = true
        todo[#todo + 1] = n
      end
    end
  end
  for _, k in ipairs(Y.keys(structure)) do if not seen[k] then Y.remove(structure, k) end end
end

-- the names of a step's blocks reached from entry along their links (only the step's own)
local function chain(blocks, entry)
  local seen, seen_set, todo = {}, {}, {entry}
  while #todo > 0 do
    local n = table.remove(todo, 1)
    if not seen_set[n] and blocks[n] ~= nil then
      seen[#seen + 1] = n
      seen_set[n] = true
      for key, targets in pairs(blocks[n]) do
        if P.startswith(key, "next") and Y.is_list(targets) then
          for _, t in ipairs(targets) do todo[#todo + 1] = Y.is_map(t) and Y.keys(t)[1] or t end
        end
      end
    end
  end
  return seen
end

-- a copy's links: those to the step's own blocks to their copies, the others left out
local function renamed(targets, names)
  local out = Y.list({})
  for _, t in ipairs(targets) do
    if Y.is_map(t) then
      local k = Y.keys(t)[1]
      if names[k] then out[#out + 1] = M(names[k], t[k]) end
    elseif names[t] then
      out[#out + 1] = names[t]
    end
  end
  return out
end

-- a goal that repeats: the block it comes in by again, and the blocks that make it ready first -> entry, {{name, block}}
local function again(ctx, i, kind, s, out)
  local si = "s" .. S(i)
  local function clear(fact, name)
    return {"script." .. si .. "_" .. name, M("function", "RemoveFactQuest", "parameter", L(M("factId", "cname_" .. S(fact))))}
  end
  if kind == "goto" then
    local b = out.blocks[out.first] or Y.map()
    if P.has(b, "entered") or P.has(b, "inside") then          -- in the area again: first out of it
      return out.first, {{"waituntil." .. si .. "_left", M("left", P.or_(get(b, "entered"), b.inside))}}
    end
    local last = out.blocks[out.last] or Y.map()
    if P.has(last, "factdb") and not T(get(s, "stay")) then return out.first, {clear(last.factdb[1], "again")} end
    fail("step " .. S(i) .. ": go to - 'every time' works for arriving in an area, near someone, looking, getting away " ..
         "(not with a time of day or 'stay')")
  end
  if kind == "waitfact" then
    if T(get(s, "conditions")) then
      local conds = Q.conditions_of(s)
      for _, c in ipairs(conds) do
        if Q.cond_kind(c) ~= "fact" or T(get(c, "not")) then
          fail("step " .. S(i) .. ": wait until - 'every time' works with facts (they are removed and waited for " ..
               "again), not with an area, a quest, the time ...")
        end
      end
      local made = {}
      for k, c in ipairs(conds) do made[k] = clear(c.fact, "again" .. (k - 1)) end
      return out.first, made
    end
    local fb = out.blocks[out.first] or Y.map()
    local fact = P.has(fb, "factdb") and fb.factdb[1] or get(s, "fact")
    return out.first, {clear(fact, "again")}
  end
  if kind == "wait" then
    if T(get(s, "until")) then fail("step " .. S(i) .. ": wait - 'every time' works with a time that passes, not with 'until'") end
    return out.first, {}
  end
  if kind == "talk" then
    local start = get(s, "start", "interact")
    if start == "now" then
      fail("step " .. S(i) .. ": talk - a cutscene ('immediately') plays once; 'every time' needs E or near")
    end
    local entry = (start == "interact" or start == "calls") and ("interaction." .. si) or out.first
    local made = {}
    local choice = out.blocks["waituntil." .. si .. "_choice"]
    if choice then
      local c1 = choice.conditions[Y.keys(choice.conditions)[1]]
      made[#made + 1] = clear(c1.factdb[1], "again")
    end
    made[#made + 1] = {"waituntil." .. si .. "_again", M("elapsed", "00:00:02")}
    local near = out.blocks["script." .. si .. "_near"]
    if start == "near" and near then
      -- first away again: else it starts anew while the player still stands by
      made[#made + 1] = {"script." .. si .. "_away", GEN.with(near, "function", "CjWaitAway")}
    end
    return entry, made
  end
  fail("step " .. S(i) .. ": '" .. kind .. "' cannot repeat - 'every time' is for Go to, Wait until, Wait, Talk")
end

function GEN.generate(project, blocks_extra)
  local blocks = {}
  for k, v in pairs(GEN.BLOCKS) do blocks[k] = v end
  for k, v in pairs(blocks_extra or {}) do blocks[k] = v end
  local q = get(project.meta, "quest") or Y.map()
  local copied = {}
  if not GEN.has_quest(q) then
    q = Y.map()
  elseif not QN.is_graph(q) then
    q = QN.migrate(P.deepcopy(q, copied), false)
  end
  local parts
  q, parts = QS.merge(project.meta, q, project.id)
  local ctx = GEN.Ctx.new(project, q)
  local qid = ctx.qid
  local struct, meta, objectives, scenes = Y.map(), Y.map(), {}, Y.map()
  local communities, spawn_of = Y.map(), {}
  local spawn_order = {}
  local speakers = GEN.speaking_people(q)
  project.notes = project.notes or {}
  project.minigames = ctx.minigames
  project.keyed_strings = ctx.keyed
  project.step_layers, project.step_entities = ctx.layers, ctx.own_entities
  project.step_trails = ctx.trails_in_steps
  local foes = GEN.kill_targets(q)
  local movers = {}
  for _, st in ipairs(GEN.all_steps(q)) do
    local kind, a = step_type(st)
    if (kind == "follow" or kind == "patrol" or kind == "walk" or kind == "stands" or kind == "goaway") and
       Y.is_map(a) and T(get(a, "who")) then movers[a.who] = true end
    if kind == "race" and Y.is_map(a) then
      for _, r in ipairs(P.list(get(a, "racers"))) do if T(r) then movers[r] = true end end
    end
  end
  local function spawn_add(name, c, front)
    if spawn_of[name] == nil then
      spawn_of[name] = {}
      spawn_order[#spawn_order + 1] = name
    end
    if front then table.insert(spawn_of[name], 1, c) else table.insert(spawn_of[name], c) end
  end
  ctx.communities = communities
  for _, name in ipairs(Y.keys(project.places)) do
    local p = project.places[name]
    local ents, phase = Y.map(), Y.map()
    for k0, o in ipairs(P.list(get(p, "objects"))) do
      if Q.is_actor(o) then
        local oid = setdefault(o, "id", "npc" .. (k0 - 1))
        if foes[name .. "/" .. S(oid)] then
          local ap = qid .. "_" .. name .. "_" .. S(oid) .. "_ap"
          local c = qid .. "_" .. name .. "_" .. S(oid) .. "_foe"
          local ent = M("template", o.template, "tags", L(qid .. "_" .. name .. "_" .. S(oid)))
          if T(get(o, "appearance")) then ent.appearances = L(o.appearance) end
          communities[c] = M("entities", M(oid, ent), "phases", M("main", M(oid, p.world .. "/" .. ap)))
          setdefault(setdefault(meta, p.world, Y.map()), "actionpoints", Y.map())[ap] = M(
            "pos", o.pos, "rot", L(0.0, 0.0, F(o.rot[3])), "action", P.or_(get(o, "action"), GEN.idle_action(o.template)))
          ctx.foes[name .. "/" .. S(oid)] = c
        else
          local ap = qid .. "_" .. name .. "_" .. S(oid) .. "_ap"
          ents[oid] = M("template", o.template, "tags", L(qid .. "_" .. name .. "_" .. S(oid)))
          local look = get(o, "appearance")
          if speakers[name .. "/" .. S(oid)] then
            local note
            look, note = require("conjunction.talking").look_for_speaker(o.template, look)
            if note then project.notes[#project.notes + 1] = name .. "/" .. S(oid) .. ": " .. note end
          end
          if T(look) then ents[oid].appearances = L(look) end
          phase[oid] = p.world .. "/" .. ap
          setdefault(setdefault(meta, p.world, Y.map()), "actionpoints", Y.map())[ap] = M(
            "pos", o.pos, "rot", L(0.0, 0.0, F(o.rot[3])), "action", P.or_(get(o, "action"), GEN.idle_action(o.template)))
        end
      end
    end
    for _, oid in ipairs(Y.keys(ents)) do
      if movers[name .. "/" .. S(oid)] then
        local c = qid .. "_" .. name .. "_" .. S(oid) .. "_c"
        communities[c] = M("entities", M(oid, Y.remove(ents, oid)), "phases", M("main", M(oid, Y.remove(phase, oid))))
        spawn_add(name, c)
        ctx.person_comm[name .. "/" .. S(oid)] = c
      end
    end
    if next(Y.keys(ents)) ~= nil then
      communities[qid .. "_" .. name] = M("entities", ents, "phases", M("main", phase))
      spawn_add(name, qid .. "_" .. name, true)
    end
  end
  -- schedules: each 'stands' makes a new phase of its place's community - the one before it with this person at
  -- the new spot (in story order); the step switches to it
  local latest, doing = {}, {}
  local function action_of(who)
    if doing[who] == nil then
      local place, _, oid = partition(who, "/")
      local o = Y.map()
      for _, x in ipairs(P.list(get(get(project.places, place) or Y.map(), "objects"))) do
        if get(x, "id") == oid then o = x break end
      end
      doing[who] = P.or_(get(o, "action"), "")
    end
    return doing[who]
  end
  local function new_phase(comm, place, oid, world, ap, pos, yaw, action, name_)
    local o
    for _, x in ipairs(project.places[place].objects) do if get(x, "id") == oid then o = x break end end
    setdefault(setdefault(meta, world, Y.map()), "actionpoints", Y.map())[ap] = M(
      "pos", L(R(F(pos[1]), 3), R(F(pos[2]), 3), R(F(pos[3]), 3)), "rot", L(0.0, 0.0, R(F(yaw), 2)),
      "action", P.T(action) and action or GEN.idle_action(o.template))
    communities[comm].phases[name_] = with(communities[comm].phases[latest[comm] or "main"], oid, world .. "/" .. ap)
    latest[comm] = name_
  end
  for k, st in ipairs(GEN.all_steps(q)) do
    local kind, a = step_type(st)
    local skip = false
    if (kind == "follow" or kind == "patrol" or kind == "walk") and T(get(a or Y.map(), "who")) and
       (not T(get(a, "lead")) or kind == "follow") then
      local place, _, oid = partition(a.who, "/")
      local comm = ctx.person_comm[a.who]
      local pts
      if kind ~= "walk" then
        pts = {}
        for _, p_ in ipairs(P.list(get(a, "path"))) do if T(p_) and #p_ >= 3 then pts[#pts + 1] = p_ end end
      else
        pts = T(get(a, "pos")) and {a.pos} or {}
      end
      if T(get(a, "lead")) then pts = #pts > 0 and {pts[#pts]} or {} end   -- led: only where the way ends
      if comm and communities[comm].entities[oid] ~= nil and #pts > 0 then
        local world = project.places[place].world
        local names, yaw = {}, F(get(a, "yaw", 0.0))
        for j, pt in ipairs(pts) do
          if j < #pts then
            local nx, ny = F(pts[j + 1][1]) - F(pt[1]), F(pts[j + 1][2]) - F(pt[2])
            yaw = math.deg(math.atan(-nx, ny)) % 360
          end
          local name_ = "s" .. k .. "_p" .. j
          new_phase(comm, place, oid, world, qid .. "_" .. place .. "_" .. oid .. "_ap" .. k .. "_" .. j, pt, yaw,
                    get(a, "action"), name_)
          names[#names + 1] = {name_, {F(pt[1]), F(pt[2]), F(pt[3])}}
        end
        local act = action_of(a.who)
        local stuck = false
        for _, w in ipairs({"tied", "lying", "_lie_", "sleep", "bound", "chained", "kneel_tied"}) do
          if S(act):find(w, 1, true) then stuck = true end
        end
        doing[a.who] = P.or_(get(a, "action"), "")
        ctx.walk_phases[a] = {comm, names, stuck}
      end
      skip = true
    end
    if not skip and kind == "stands" and T(get(a or Y.map(), "who")) and T(get(a, "pos")) then
      local place, _, oid = partition(a.who, "/")
      local comm = ctx.person_comm[a.who]
      if not comm or communities[comm].entities[oid] == nil then
        fail("Stands: " .. S(a.who) .. " is not an NPC of a location")
      end
      doing[a.who] = P.or_(get(a, "action"), "")
      local world = project.places[place].world
      local ap = qid .. "_" .. place .. "_" .. oid .. "_ap" .. k
      local o
      for _, x in ipairs(project.places[place].objects) do if get(x, "id") == oid then o = x break end end
      setdefault(setdefault(meta, world, Y.map()), "actionpoints", Y.map())[ap] = M(
        "pos", a.pos, "rot", L(0.0, 0.0, F(get(a, "yaw", 0.0))), "action", P.or_(get(a, "action"), GEN.idle_action(o.template)))
      local phase = with(communities[comm].phases[latest[comm] or "main"], oid, world .. "/" .. ap)
      local name_ = "s" .. k
      communities[comm].phases[name_] = phase
      latest[comm] = name_
      ctx.stand_phases[a] = {comm, name_}
    end
  end
  local start_worlds, start_order = {}, {}
  local function sw_add(w, name)
    if start_worlds[w] == nil then
      start_worlds[w] = {}
      start_order[#start_order + 1] = w
    end
    table.insert(start_worlds[w], name)
  end
  for _, name in ipairs(Y.keys(project.places)) do
    local p = project.places[name]
    if GEN.has_statics(p) and GEN.place_visible(project, name, q) == "start" then sw_add(p.world, name) end
  end
  local paths = get(q, "paths") or Y.map()
  local count = 0
  local used_fail = false
  local graph_node = {nil, {}, ""}
  local numbers, numbers_n = {}, 0
  local function node_number(nid)
    local d = nid:match("^n(%d+)$")
    if d then return tonumber(d) end
    if numbers[nid] == nil then
      numbers[nid] = 500 + numbers_n
      numbers_n = numbers_n + 1
    end
    return numbers[nid]
  end
  if QN.is_graph(q) then count = 900 end
  local path_first, lane_first, lane_blocks = {}, {}, {}
  local repeats, repeat_order = {}, {}

  -- the communities of a place's kill targets (each its own)
  local function place_foes(name)
    local out = {}
    for ref, c in pairs(ctx.foes) do if partition(ref, "/") == name then out[#out + 1] = c end end
    table.sort(out)
    return out
  end

  local build                                     -- (resolve and build call each other)
  local function pieces(step, objective)
    if objective == nil then objective = true end
    local i
    if graph_node[1] ~= nil then
      i = node_number(graph_node[1])
    else
      count = count + 1
      i = count
    end
    local kind, args = step_type(step)
    if GEN.PLACEHOLDERS[kind] then
      fail("step " .. i .. ": a block that does not know yet what it does - choose " .. GEN.PLACEHOLDERS[kind])
    end
    if blocks[kind] == nil then
      local known = {}
      for k in pairs(blocks) do known[#known + 1] = k end
      table.sort(known)
      fail("step " .. i .. ": unknown step type '" .. kind .. "' (known: " .. table.concat(known, ", ") .. ")")
    end
    local place = get(args or Y.map(), "place")
    local out
    if (kind == "show" or kind == "hide") and not GEN.has_statics(get(project.places, place) or Y.map()) then
      out = GEN.StepOut(Y.map(), nil, nil)
    else
      local ok, res = pcall(function() return blocks[kind]:generate(ctx, i, args or Y.map()) end)
      if not ok then
        if GEN.is_key_error(res) then
          fail("step " .. i .. " (" .. kind .. "): '" .. S(res.key_error) .. "' is not set yet (or no longer there)" ..
               GEN.which(kind, args, q, ctx))
        elseif GEN.is_value_error(res) then
          fail(res.value_error .. GEN.which(kind, args, q, ctx))
        end
        error(res, 0)
      end
      out = res
    end
    for k, v in pairs(out.blocks) do struct[k] = v end
    for k, v in pairs(out.scenes) do scenes[k] = v end
    if graph_node[1] ~= nil and QN.repeat_of(args) ~= nil then
      if repeats[graph_node[1]] == nil then repeat_order[#repeat_order + 1] = graph_node[1] end
      repeats[graph_node[1]] = {out, i, kind, args}
    end
    for w, m in pairs(out.meta) do
      for k, v in pairs(m) do
        local dst = setdefault(setdefault(meta, w, Y.map()), k, Y.map())
        for kk, vv in pairs(v) do dst[kk] = vv end
      end
    end
    local made = {}
    -- the place's people: its community's and the kill targets standing there
    local sets = {}
    if kind == "show" or kind == "hide" then
      for _, c in ipairs(spawn_of[place] or {}) do sets[#sets + 1] = c end
      for _, c in ipairs(place_foes(place)) do sets[#sets + 1] = c end
    end
    if kind == "show" and #sets > 0 then
      -- its people come out of sight: is the place in the picture, a short fade hides their coming
      local c3 = ctx:place_center(place)
      local cover = "script.s" .. i .. "_cover"
      struct[cover] = M("function", "CjCoverIfSeen", "parameter", L(M("x", F(c3[1])), M("y", F(c3[2])), M("z", F(c3[3])),
                                                                     M("fact", qid .. "_s" .. i .. "_covered")))
      made[#made + 1] = {cover, cover, nil, cover, nil}
    end
    local made_text = Q.default_text(kind, args or Y.map(), get(q, "items"), ctx.names)
    if out.objective and not T(get(args or Y.map(), "text")) and T(made_text) then out.objective.caption = made_text end
    if out.objective and objective and out.counter then
      local fact, n = out.counter[1], out.counter[2]
      local caption = out.objective.caption
      local ons, dones = {}, {}
      for k = 0, n - 1 do
        local oid = "s" .. i .. "_" .. k
        local ob = Y.map()
        for kk, v in pairs(with(out.objective, "caption", S(caption) .. " (" .. k .. "/" .. n .. ")")) do
          if T(v) then ob[kk] = v end
        end
        objectives[#objectives + 1] = M(oid, ob)
        ons[#ons + 1] = "objective." .. oid .. "_on"
        dones[#dones + 1] = "objective." .. oid .. "_done"
        struct[ons[k + 1]] = M("objective", qid .. "/main/" .. oid, "track", true)
        struct[dones[k + 1]] = M("objective", qid .. "/main/" .. oid)
      end
      for k = 1, n - 1 do
        local wait = "waituntil.s" .. i .. "_count" .. k
        struct[ons[k]].next = L(wait)
        struct[wait] = M("factdb", L(fact, ">=", k), "next", L(M(dones[k], "Success")))
        struct[dones[k]].next = L(ons[k + 1])
      end
      struct[ons[#ons]].next = L(out.last)
      local fork = out.fork or out.first
      local keep = Y.list({})
      for _, x in ipairs(struct[fork].next) do if x ~= out.last then keep[#keep + 1] = x end end
      keep[#keep + 1] = ons[1]
      struct[fork].next = keep
      made[#made + 1] = {out.first, out.last, out.branches, out.first, "s" .. i .. "_" .. (n - 1)}
      made[#made + 1] = {M(dones[#dones], "Success"), dones[#dones], nil, nil, nil}
      return made
    end
    if out.objective and objective then
      local oid = "s" .. i
      local ob = Y.map()
      for k, v in pairs(out.objective) do if T(v) then ob[k] = v end end
      objectives[#objectives + 1] = M(oid, ob)
      local on, done = "objective." .. oid .. "_on", "objective." .. oid .. "_done"
      struct[on] = M("objective", qid .. "/main/" .. oid, "track", true)
      struct[done] = M("objective", qid .. "/main/" .. oid)
      made[#made + 1] = {on, on, nil, nil, nil}
      made[#made + 1] = {out.first, out.last, out.branches, on, oid}
      made[#made + 1] = {M(done, "Success"), done, nil, nil, nil}
    elseif out.first then
      made[#made + 1] = {out.first, out.last, out.branches, out.first, nil}
    end
    if (kind == "show" or kind == "hide") and #sets > 0 then
      local b = (kind == "show" and "spawn" or "despawn") .. ".s" .. i .. "_npcs"
      struct[b] = M("spawnsets", Y.list({table.unpack(sets)}))
      -- the place's people kept out after a Hide (the community sets them anew when the place loads - CjKeepGone,
      -- beside the story), back with a Show: their facts to 0 first
      local tags = {}
      for _, o in ipairs(P.list(get(project.places[place], "objects"))) do
        if Q.is_actor(o) and T(get(o, "id")) then tags[#tags + 1] = ctx:object_tag(place .. "/" .. S(o.id)) end
      end
      for k0, tg in ipairs(tags) do
        local mark = "addfact.s" .. i .. "_gone" .. (k0 - 1)
        struct[mark] = M("value", L(tg .. "_gone", kind == "hide" and 1 or 0))
        local side = nil
        if kind == "hide" then
          local keep = "script.s" .. i .. "_keep" .. (k0 - 1)
          struct[keep] = M("function", "CjKeepGone", "parameter", L(M("tag", "cname_" .. tg), M("fact", tg .. "_gone")))
          side = M("__side", keep)
        end
        made[#made + 1] = {mark, mark, side, mark, nil}
      end
      if kind == "show" then struct[b].phase = "main" end
      made[#made + 1] = {b, b, nil, b, nil}
      if kind == "show" then
        local uncover = "script.s" .. i .. "_uncover"
        struct[uncover] = M("function", "CjUncover", "parameter", L(M("fact", qid .. "_s" .. i .. "_covered")))
        made[#made + 1] = {uncover, uncover, nil, uncover, nil}
      end
    end
    return made
  end

  -- where a way out of a step leads: on (join), again (retry), a path, the quest's end
  local function resolve(then_, join, retry, objective)
    if then_ == "continue" then return join end
    if then_ == "retry" then return retry end
    if then_ == "fail" then
      used_fail = true
      return M("questoutcome.failed", "Failure")
    end
    if then_ == "success" then return M("questoutcome.done", "Success") end
    if P.startswith(then_, "@") then
      local _e, src, port = then_:match("^([^@]*)@([^@]*)@(.*)$")
      local ends = {}
      for _, l in ipairs(P.list(get(q, "links"))) do
        if l[1] == src and l[2] == port and q.nodes[l[3]] ~= nil then
          local k, x = step_type(q.nodes[l[3]].step)
          ends[#ends + 1] = {k, x}
        end
      end
      local all_fail = #ends > 0
      for _, e in ipairs(ends) do
        if not (e[1] == "end" and get(e[2] or Y.map(), "how") == "fail") then all_fail = false end
      end
      if all_fail then return then_ end
      if objective then
        local d = "objective." .. objective .. "_done_" .. P.replace(then_:sub(2), "@", "_")
        struct[d] = M("objective", qid .. "/main/" .. objective, "next", L(then_))
        return M(d, "Success")
      end
      return then_
    end
    if P.startswith(then_, "path:") then
      local pid = then_:sub(6)
      if not P.has(paths, pid) then fail("A step leads to the branch '" .. pid .. "', which does not exist") end
      if lane_first[pid] ~= nil then
        fail("The branch '" .. pid .. "' is a parallel track (Meanwhile). A choice needs a branch of its own")
      end
      if path_first[pid] == nil then
        local p = paths[pid]
        local endw = get(p, "then", "join")
        local after = resolve(endw == "join" and "continue" or endw, join, retry, nil)
        local b = "addfact.path_" .. QN.safe(pid)
        path_first[pid] = b
        struct[b] = M("value", L(QN.path_fact(qid, pid), 1))
        struct[b].next = L(build(P.list(get(p, "steps")), after))
      end
      local target = path_first[pid]
      if objective then
        local d = "objective." .. objective .. "_done_" .. pid
        struct[d] = M("objective", qid .. "/main/" .. objective, "next", L(target))
        return M(d, "Success")
      end
      return target
    end
    fail("unknown way on: " .. S(then_))
  end

  -- the blocks of a list of steps, linked in order; the last leads to `after`. -> the first
  build = function(steps, after, hidden_first)
    local made = {}
    if hidden_first and #steps > 0 then
      local k = 1
      for j, st in ipairs(steps) do if step_type(st) ~= "chapter" then k = j break end end
      for j = 1, k do for _, p in ipairs(pieces(steps[j], false)) do made[#made + 1] = p end end
      made[#made + 1] = {"journal.begin", "journal.begin", nil, nil, nil}
      for j = k + 1, #steps do for _, p in ipairs(pieces(steps[j])) do made[#made + 1] = p end end
    else
      for _, step in ipairs(steps) do for _, p in ipairs(pieces(step)) do made[#made + 1] = p end end
    end
    local ref, beyond = after, after
    for idx = #made, 1, -1 do
      local first, last, branches, retry, objective = made[idx][1], made[idx][2], made[idx][3], made[idx][4], made[idx][5]
      local nb = branches and Y.len(branches) > 0
      if nb and P.has(branches, "__side") then
        -- an action beside the story (Lock): the story goes on at once, the action's block on its own
        struct[last].next = L(ref, branches.__side)
        ref, beyond = first, ref
      elseif nb and P.has(branches, "__lane") and graph_node[1] ~= nil then
        struct[last].next = L(ref, "@" .. graph_node[1] .. "@__lane")
        ref, beyond = first, ref
      elseif nb and P.has(branches, "__lane") then
        local pid = branches.__lane
        if not P.has(paths, pid) then fail("Meanwhile: there is no branch '" .. S(pid) .. "'") end
        if path_first[pid] ~= nil or lane_first[pid] == "" then
          fail("Meanwhile: the branch '" .. S(pid) .. "' belongs to a choice or starts on its own. A parallel track " ..
               "needs a branch of its own")
        end
        if lane_first[pid] == nil then
          lane_first[pid] = ""
          local before = {}
          for k in pairs(struct) do before[k] = true end
          lane_first[pid] = build(P.list(get(paths[pid], "steps")), "waituntil.forever")
          local made_now = {}
          for k in pairs(struct) do if not before[k] then made_now[#made_now + 1] = k end end
          table.sort(made_now)
          lane_blocks[pid] = made_now
        end
        struct[last].next = L(ref, lane_first[pid])
        ref, beyond = first, ref
      elseif nb and graph_node[1] ~= nil and graph_node[3] ~= "end" then
        for _, sock in ipairs(Y.keys(branches)) do
          local port = graph_node[2][sock] and sock or "next"
          local then_ = branches[sock]
          local target
          if port == "next" then
            target = ref
          elseif (port == "retry" or port == "fail" or then_ == "fail") and not (function()
              for _, l in ipairs(P.list(get(q, "links"))) do
                if l[1] == graph_node[1] and l[2] == port then return true end
              end
              return false
            end)() then
            -- not wired: 'later' talks again, 'fails' fails the quest - what the words say; so does an output the
            -- step says fails (Go to 'stay', left too early, and a lost race)
            target = resolve((port == "retry" or port == "fail") and port or then_, ref, retry, nil)
          else
            target = resolve("@" .. graph_node[1] .. "@" .. port, ref, retry, objective)
          end
          struct[last][sock ~= "" and ("next." .. sock) or "next"] = L(target)
        end
        ref, beyond = first, ref
      elseif nb then
        for _, sock in ipairs(Y.keys(branches)) do
          local then_ = branches[sock]
          local target
          if P.startswith(then_, "path:") then
            target = resolve(then_, objective and beyond or ref, retry, objective)
          else
            target = resolve(then_, ref, retry, nil)
          end
          struct[last][sock ~= "" and ("next." .. sock) or "next"] = L(target)
        end
        ref, beyond = first, ref
      else
        struct[last].next = L(ref)
        ref, beyond = first, ref
      end
    end
    return ref
  end

  -- an either whose ways are wired to goals: its block starts them all side by side; when one is done a cut stops
  -- the others and their journal lines are taken away (Deactivate), then on where the winner leads
  local function first_wins_ways(nodes, out_of, first_of, blocks_of)
    for _, e in ipairs(Y.keys(nodes)) do
      local node = nodes[e]
      local kind, a = step_type(node.step)
      if kind == "either" and GEN.first_wins(a) and first_of[e] ~= nil then
        local ways = #P.list(get(a, "ways"))
        local groups = {}
        for k = 1, ways do
          local g = {}
          for _, t in ipairs(out_of[e .. "\0way" .. k] or {}) do if nodes[t] ~= nil then g[#g + 1] = t end end
          groups[k] = g
        end
        local fork = "addfact.s" .. node_number(e) .. "_either"
        local nxt = Y.list({})
        for k, g in ipairs(groups) do if #g > 0 then nxt[#nxt + 1] = "@" .. e .. "@way" .. k end end
        if #nxt == 0 then nxt[1] = "waituntil.forever" end
        struct[fork].next = nxt
        for k, group in ipairs(groups) do
          local lose = {}
          for j, g in ipairs(groups) do
            if j ~= k then for _, t in ipairs(g) do for b in pairs(blocks_of[t]) do lose[b] = true end end end
          end
          local losers = sorted_set(lose)
          if #losers > 0 then
            local cut_these = {}
            for _, b in ipairs(losers) do
              if not startswith_any(b, {"objective.", "journal."}) then cut_these[#cut_these + 1] = b end
            end
            local lines_set = {}
            for _, b in ipairs(losers) do
              if P.startswith(b, "objective.") and P.endswith(b, "_on") then lines_set[struct[b].objective] = true end
            end
            local lines_ = sorted_set(lines_set)
            local exits = 0
            for _, t in ipairs(group) do
              for _, b in ipairs(sorted_set(blocks_of[t])) do
                for _, key in ipairs(Y.keys(struct[b])) do
                  local targets = struct[b][key]
                  if P.startswith(key, "next") and Y.is_list(targets) then
                    for n_, tgt in ipairs(targets) do
                      if type(tgt) == "string" and P.startswith(tgt, "@" .. t .. "@") then
                        exits = exits + 1
                        local name = "cut_e" .. node_number(e) .. "_" .. k .. "_" .. exits
                        local lane = "__either_" .. name
                        lane_blocks[lane] = cut_these
                        ctx.minigames[name] = M("game", "cut", "lane", lane)
                        local then_ = tgt
                        for m = #lines_, 1, -1 do
                          local off = "objective." .. name .. "_off" .. (m - 1)
                          struct[off] = M("objective", lines_[m], "next", L(then_))
                          then_ = M(off, "Deactivate")
                        end
                        struct["addfact." .. name] = M("value", L(qid .. "_" .. name, 1), "next", L(then_))
                        targets[n_] = "addfact." .. name
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  -- each goal 'every time': its blocks once more (a copy, without the journal), entered after what makes it ready
  -- again; its output every time - and the copy, each time it is done - leads to what is wired to it
  local function repeat_loops(nodes, out_of, first_of, blocks_of)
    for _, nid in ipairs(repeat_order) do
      local out, i, kind, a = table.unpack(repeats[nid])
      local entry, ready = again(ctx, i, kind, a, out)
      local own_blocks = Y.map()
      for k in pairs(out.blocks) do own_blocks[k] = struct[k] end
      local own = chain(own_blocks, entry)
      local swap = out.again_scene
      if swap then
        local cut_at
        for _, k in ipairs(own) do if get(struct[k], "scene") == swap[1] then cut_at = k break end end
        local keep = {}
        for _, k in ipairs(own) do
          keep[#keep + 1] = k
          if k == cut_at then break end
        end
        own = keep
      end
      local names = {}
      for _, k in ipairs(own) do names[k] = k .. "_again" end
      for _, k in ipairs(own) do
        local b = P.deepcopy(struct[k])
        for _, key in ipairs(Y.keys(b)) do
          if P.startswith(key, "next") then b[key] = renamed(b[key], names) end
        end
        if swap and k == own[#own] then
          b.scene = swap[2]
          for _, key in ipairs(Y.keys(b)) do if P.startswith(key, "next") then Y.remove(b, key) end end
        end
        struct[names[k]] = b
      end
      local every = "@" .. nid .. "@__every"
      local last, copy_last = out.last, names[out.last]
      if swap then copy_last = names[own[#own]] end
      local keys = {}
      for _, x in ipairs(Y.keys(struct[last])) do if P.startswith(x, "next") then keys[#keys + 1] = x end end
      if #keys == 0 then keys = {"next"} end
      for _, key in ipairs(keys) do
        local lst = setdefault(struct[last], key, Y.list({}))
        lst[#lst + 1] = every
        if copy_last and not swap then struct[copy_last][key] = L(every) end
      end
      if swap then struct[copy_last].next = L(every) end
      local back = "__again_" .. nid
      local first = names[entry] or entry
      for k = #ready, 1, -1 do
        local name, b = ready[k][1], ready[k][2]
        struct[name] = with(b, "next", L(first))
        first = name
      end
      first_of[back] = first
      local lane = GEN.reach(q, out_of[nid .. "\0__every"] or {})
      local main_starts = {}
      for key, bs in pairs(out_of) do
        local x, p = key:match("^(.-)%z(.*)$")
        if x == nid and p ~= "__every" then for _, b in ipairs(bs) do main_starts[#main_starts + 1] = b end end
      end
      local main = GEN.reach(q, main_starts)
      for x in pairs(main) do lane[x] = nil end
      if not out_of[nid .. "\0__every"] or #out_of[nid .. "\0__every"] == 0 then out_of[nid .. "\0__every"] = {back} end
      for x in pairs(lane) do
        for _, pt in ipairs(QN.ports(nodes[x].step, q)) do
          local key = x .. "\0" .. pt[1]
          if not out_of[key] or #out_of[key] == 0 then out_of[key] = {back} end
        end
      end
      local until_ = QN.repeat_of(a)
      local how = P.or_(get(until_, "until"), "quest")
      if how ~= "quest" then
        local cut = "cut_r" .. S(i)
        local loop = "__every_" .. nid
        local set = {}
        for _, v in pairs(names) do set[v] = true end
        for _, r in ipairs(ready) do set[r[1]] = true end
        for x in pairs(lane) do for b in pairs(blocks_of[x] or {}) do set[b] = true end end
        lane_blocks[loop] = sorted_set(set)
        ctx.minigames[cut] = M("game", "cut", "lane", loop)
        local stand_in = "addfact." .. cut
        if how == "fact" then
          if not T(get(until_, "fact")) then fail("step " .. S(i) .. ": every time, until a fact - which fact?") end
          local w = "waituntil.s" .. S(i) .. "_until"
          struct[w] = M("factdb", L(S(until_.fact), ">=", I(get(until_, "value", 1))), "next", L(stand_in))
          struct[stand_in] = M("value", L(qid .. "_" .. cut, 1))
          for _, key in ipairs(keys) do struct[last][key][#struct[last][key] + 1] = w end
        elseif how == "node" then
          local target = get(until_, "node")
          if first_of[target] == nil then fail("step " .. S(i) .. ": every time, until a step is reached - which step?") end
          struct[stand_in] = M("value", L(qid .. "_" .. cut, 1), "next", L(first_of[target]))
          first_of[target] = stand_in
        else
          fail("step " .. S(i) .. ": every time, until '" .. S(how) .. "'?")
        end
      end
    end
  end

  -- the step a test build of the older form starts at
  local function old_test_node(test_from)
    local orig = get(project.meta, "quest") or Y.map()
    local where, k = test_from[1], I(test_from[#test_from])
    local steps
    if where == "main" then steps = get(orig, "steps")
    else steps = get(get(get(orig, "paths") or Y.map(), test_from[2]) or Y.map(), "steps") end
    if not T(steps) or k >= #steps then return nil end
    local step = copied[steps[k + 1]] or steps[k + 1]
    for _, nid in ipairs(Y.keys(q.nodes)) do if rawequal(q.nodes[nid].step, step) then return nid end end
    return nil
  end

  -- every node on its own, then its outputs wired: to the first block of each node its links lead to
  local function build_graph(hidden, test_from)
    local nodes = q.nodes
    local out_of = {}
    for _, l in ipairs(P.list(get(q, "links"))) do
      local key = l[1] .. "\0" .. l[2]
      out_of[key] = out_of[key] or {}
      table.insert(out_of[key], l[3])
    end
    local first_of, blocks_of = {}, {}
    local starts = {}
    for _, b in ipairs(out_of[QN.START .. "\0next"] or {}) do if nodes[b] ~= nil then starts[#starts + 1] = b end end
    for _, nid in ipairs(QN.order(q)) do
      local node = nodes[nid]
      local kind = step_type(node.step)
      if kind ~= "start" then
        local before = {}
        for k in pairs(struct) do before[k] = true end
        local after = "@" .. nid .. "@next"
        local first
        if kind == "remember" then
          first = after
        else
          local outs = {}
          for _, pt in ipairs(QN.ports(node.step, q)) do outs[pt[1]] = true end
          graph_node[1], graph_node[2], graph_node[3] = nid, outs, kind
          local ok, res = pcall(build, {node.step}, after, hidden and nid == starts[1])
          graph_node[1] = nil
          if not ok then error(res, 0) end
          first = res
        end
        if T(get(node, "remember")) then
          local b = "addfact.path_" .. QN.safe(node.remember)
          struct[b] = M("value", L(QN.path_fact(qid, node.remember), 1), "next", L(first))
          first = b
        end
        first_of[nid] = first
        local mine = {}
        for k in pairs(struct) do if not before[k] then mine[k] = true end end
        blocks_of[nid] = mine
      end
    end
    first_wins_ways(nodes, out_of, first_of, blocks_of)
    repeat_loops(nodes, out_of, first_of, blocks_of)
    -- a project's quest k: its journal entry (its description) comes when it begins - after the quest it waits for,
    -- if any
    local part_keys = {}
    for k in pairs(parts) do part_keys[#part_keys + 1] = k end
    table.sort(part_keys)
    for _, k in ipairs(part_keys) do
      if k ~= 1 then
        local wait = "n" .. (k * QS.SPAN + 999)
        local begins = {}
        for _, b_ in ipairs(out_of[QN.START .. "\0next"] or {}) do
          if nodes[b_] ~= nil and QS.part_of(node_number(b_)) == k then
            if b_ == wait then
              for _, x in ipairs(out_of[b_ .. "\0next"] or {}) do begins[#begins + 1] = x end
            else
              begins[#begins + 1] = b_
            end
          end
        end
        for _, b_ in ipairs(begins) do
          if first_of[b_] ~= nil then
            local jb = "journal.begin_q" .. k .. "_" .. b_
            struct[jb] = M("entry", "quests/" .. QS.journal_key(qid, k) .. "/start", "activate_root", true,
                           "next", L(first_of[b_]))
            first_of[b_] = jb
          end
        end
      end
    end
    local function settle(targets, seen)
      seen = seen or {}
      local out = Y.list({})
      for _, t in ipairs(targets) do
        if type(t) == "string" and P.startswith(t, "@") then
          if not seen[t] then
            local _e, nid, port = t:match("^([^@]*)@([^@]*)@(.*)$")
            local nxt = {}
            for _, b in ipairs(out_of[nid .. "\0" .. port] or {}) do
              if first_of[b] ~= nil then nxt[#nxt + 1] = first_of[b] end
            end
            local seen2 = {}
            for k in pairs(seen) do seen2[k] = true end
            seen2[t] = true
            local got = settle(nxt, seen2)
            if #got == 0 then out[#out + 1] = "waituntil.forever" else for _, g in ipairs(got) do out[#out + 1] = g end end
          end
        else
          out[#out + 1] = t
        end
      end
      return out
    end
    for _, name in ipairs(Y.keys(struct)) do
      local b = struct[name]
      if Y.is_map(b) then
        for _, key in ipairs(Y.keys(b)) do
          if P.startswith(key, "next") and Y.is_list(b[key]) then b[key] = settle(b[key]) end
        end
      end
    end
    local start_at
    if test_from then start_at = test_from[1] == "node" and test_from[2] or old_test_node(test_from) end
    local runs = start_at and GEN.reach(q, {start_at}) or nil
    for _, nid in ipairs(Y.keys(nodes)) do
      local kind, a = step_type(nodes[nid].step)
      if kind == "meanwhile" and T(get(a or Y.map(), "path")) and (runs == nil or runs[nid]) then
        local lane = GEN.reach(q, out_of[nid .. "\0__lane"] or {})
        local main = GEN.reach(q, out_of[nid .. "\0next"] or {})
        local set = {}
        for x in pairs(lane) do
          if not main[x] then for b in pairs(blocks_of[x] or {}) do set[b] = true end end
        end
        lane_blocks[a.path] = sorted_set(set)
      end
    end
    local first = settle({"@" .. QN.START .. "@next"})
    if test_from then
      local nid = test_from[1] == "node" and test_from[2] or old_test_node(test_from)
      if first_of[nid] ~= nil then
        local anc = GEN.ancestors(q, nid)
        local before = {}
        for _, x in ipairs(QN.order(q)) do if anc[x] then before[#before + 1] = nodes[x].step end end
        local world = {}
        for _, st in ipairs(before) do if GEN.WORLD_ACTIONS[(step_type(st))] then world[#world + 1] = st end end
        for _, st in ipairs(before) do for _, g in ipairs(GEN.carried(st)) do world[#world + 1] = g end end
        local start = build(world, first_of[nid])
        for k0, st in ipairs(before) do
          local k = k0 - 1
          local kind, a = step_type(st)
          local phases = kind == "follow" and ctx.walk_phases[a] or nil
          if phases and not T(get(a or Y.map(), "lead")) then
            local path = {}
            for _, p_ in ipairs(P.list(get(a, "path"))) do if T(p_) and #p_ >= 3 then path[#path + 1] = p_ end end
            local b, put = "spawn.test_moved_" .. k, "script.test_put_" .. k
            local nx = L(start)
            if #path > 0 then
              -- beside the story: CjPutAt waits until the person is in the world, which he is not while the player
              -- starts far from him
              local e = path[#path]
              local yaw = GEN.heading(#path > 1 and path[#path - 1] or ctx:object(a.who).pos, e)
              struct[put] = M("function", "CjPutAt", "parameter", L(
                M("tag", "cname_" .. ctx:object_tag(a.who)), M("x", F(e[1])), M("y", F(e[2])), M("z", F(e[3])),
                M("yaw", F(yaw))))
              nx[#nx + 1] = put
            end
            struct[b] = M("spawnsets", L(phases[1]), "phase", phases[2][#phases[2]][1], "next", nx)
            start = b
          end
        end
        -- the project's other quests start as they would
        local function part(n_)
          local d = n_:match("^n(%d+)$")
          return d and QS.part_of(tonumber(d)) or 1
        end
        local others = Y.list({})
        for _, x in ipairs(out_of[QN.START .. "\0next"] or {}) do
          if first_of[x] ~= nil and part(x) ~= part(nid) then others[#others + 1] = first_of[x] end
        end
        if #others > 0 then
          local nx = L(start)
          for _, o in ipairs(others) do nx[#nx + 1] = o end
          struct["addfact.started"] = M("value", L(qid .. "_started", 1), "next", nx)
          return "addfact.started"
        end
        return start
      end
    end
    if #first == 1 then return first[1] end
    struct["addfact.started"] = M("value", L(qid .. "_started", 1), "next", first)
    return "addfact.started"
  end

  struct["waituntil.forever"] = M("factdb", L(qid .. "_never", "=", 1), "next", L("end"))
  local has_q = Y.len(q) > 0
  if has_q then
    struct["questoutcome.done"] = M("quest", qid, "next", L("addfact.done"))
    struct["addfact.done"] = M("value", L(qid .. "_done", 1), "next", L("waituntil.forever"))
  end
  local story = {}
  local test_from = project.test_from
  if not require("conjunction.features").experimental() then
    q = with(q)
    for _, k in ipairs({"start", "after_game", "inside_game", "ends_game"}) do Y.remove(q, k) end
  end
  local hidden = get(q, "start") == "after_first" and has_q and not test_from
  if hidden then struct["journal.begin"] = M("entry", "quests/" .. qid .. "/start", "activate_root", true) end
  local first_story
  if has_q then first_story = build_graph(hidden, test_from)
  else first_story = build(story, "waituntil.forever") end
  local watchers = {}
  for k, ref in ipairs(P.list(get(q, "keep_alive"))) do
    local w = "waituntil.alive_" .. k
    struct[w] = M("factdb", L("actor_" .. ctx:object_tag(ref) .. "_was_killed", ">=", 1),
                  "next", L(M("questoutcome.failed", "Failure")))
    watchers[#watchers + 1] = w
    used_fail = true
  end
  local eg = get(q, "ends_game") or Y.map()
  if T(get(eg, "fact")) then
    local failing = get(eg, "how", "fail") == "fail"
    struct["waituntil.ends_game"] = M("factdb", L(S(eg.fact), ">=", 1),
                                      "next", L(failing and M("questoutcome.failed", "Failure") or M("questoutcome.done", "Success")))
    watchers[#watchers + 1] = "waituntil.ends_game"
    used_fail = used_fail or failing
  end
  if used_fail then
    struct["questoutcome.failed"] = M("quest", qid, "next", L("addfact.failed"))
    struct["addfact.failed"] = M("value", L(qid .. "_failed", 1), "next", L("waituntil.forever"))
  end
  if has_q then
    local guards = Y.map()
    guards["questoutcome.done"] = {"waituntil.end_done", qid .. "_failed", "Success"}
    guards["questoutcome.failed"] = {"waituntil.end_failed", qid .. "_done", "Failure"}
    QS.retarget_objectives(struct, parts, qid)
    for k, v in pairs(QS.split_outcomes(struct, parts, qid)) do guards[k] = v end
    for _, name in ipairs(Y.keys(struct)) do
      local b = struct[name]
      if Y.is_map(b) then
        for _, key in ipairs(Y.keys(b)) do
          local targets = b[key]
          if P.startswith(key, "next") and Y.is_list(targets) then
            local out = Y.list({})
            for _, t in ipairs(targets) do
              if Y.is_map(t) and Y.len(t) == 1 then
                local k1 = Y.keys(t)[1]
                if guards[k1] and struct[k1] ~= nil then t = guards[k1][1] end
              end
              out[#out + 1] = t
            end
            b[key] = out
          end
        end
      end
    end
    for _, outcome in ipairs(Y.keys(guards)) do
      local g, other, sock = guards[outcome][1], guards[outcome][2], guards[outcome][3]
      if struct[outcome] ~= nil then
        struct[g] = M("conditions", M("on", M("factdb", L(other, "=", 0)), "over", M("factdb", L(other, ">=", 1))),
                      "next.on", L(M(outcome, sock)), "next.over", L("waituntil.forever"))
      end
    end
  end
  -- after a game of gwent / a fist fight the picture stays black until the quest fades in
  for _, name in ipairs(Y.keys(ctx.minigames)) do
    local m = ctx.minigames[name]
    local b = "randomize." .. name
    local game = get(m, "game", "gwent")
    if (game == "gwent" or game == "fistfight") and struct[b] ~= nil then
      for _, sock in ipairs({"Success", "Failure"}) do
        local fade = "script." .. name .. "_fadein_" .. PYS.lower(sock)
        local nxt = get(struct[b], "next." .. sock)
        struct[fade] = M("function", "FadeInQuest", "parameter", L(M("fadeTime", 1.0)),
                         "next", T(nxt) and nxt or L("waituntil.forever"))
        struct[b]["next." .. sock] = L(fade)
      end
    end
  end
  for _, name in ipairs(Y.keys(ctx.minigames)) do
    local m = ctx.minigames[name]
    if get(m, "game") == "cut" and not P.has(m, "blocks") then   -- (a lead's cut names its block itself)
      if lane_blocks[m.lane] == nil then
        if test_from then
          Y.remove(ctx.minigames, name)
        else
          fail("Stop lane: '" .. S(m.lane) .. "' never runs (no Meanwhile starts it)")
        end
      else
        m.blocks = Y.list({table.unpack(lane_blocks[m.lane])})
      end
    end
  end
  for w, m in pairs(ctx.extra_meta) do
    for k, v in pairs(m) do
      local dst = setdefault(setdefault(meta, w, Y.map()), k, Y.map())
      for kk, vv in pairs(v) do dst[kk] = vv end
    end
  end
  for w in pairs(meta) do sw_add(w, GEN.meta_layer(qid, w)) end
  local later, later_order = {}, {}
  local function later_add(w, name)
    if later[w] == nil then
      later[w] = {}
      later_order[#later_order + 1] = w
    end
    table.insert(later[w], name)
  end
  for _, name in ipairs(Y.keys(project.places)) do
    local p = project.places[name]
    if GEN.has_statics(p) and GEN.place_visible(project, name, q) ~= "start" then later_add(p.world, name) end
  end
  for name, lay in pairs(ctx.layers) do later_add(lay.world, name) end
  local worlds = {}
  for _, w in ipairs(start_order) do worlds[#worlds + 1] = w end
  for _, w in ipairs(later_order) do if start_worlds[w] == nil then worlds[#worlds + 1] = w end end
  local head = {}
  for _, w in ipairs(worlds) do
    local b = "changelayers.show_" .. w
    struct[b] = M("world", w)
    if start_worlds[w] and #start_worlds[w] > 0 then struct[b].show = Y.list({table.unpack(start_worlds[w])}) end
    if later[w] and #later[w] > 0 then struct[b].hide = Y.list({table.unpack(later[w])}) end
    head[#head + 1] = b
  end
  local spawn_names = {table.unpack(spawn_order)}
  for _, name in ipairs(Y.keys(project.places)) do
    if spawn_of[name] == nil and #place_foes(name) > 0 then spawn_names[#spawn_names + 1] = name end
  end
  for _, name in ipairs(spawn_names) do
    if GEN.place_visible(project, name, q) == "start" then
      local b = "spawn." .. name .. "_npcs"
      local sets = Y.list({table.unpack(spawn_of[name] or {})})
      for _, c in ipairs(place_foes(name)) do sets[#sets + 1] = c end
      struct[b] = M("phase", "main", "spawnsets", sets)
      head[#head + 1] = b
    end
  end
  if has_q and not hidden then
    local j = "journal.begin"
    struct[j] = M("entry", "quests/" .. qid .. "/start", "activate_root", true)
    head[#head + 1] = j
  end
  for k, a_ in ipairs(head) do struct[a_].next = L(head[k + 1] or first_story) end
  local story_start = head[1] or first_story
  if T(get(get(q, "after_game") or Y.map(), "fact")) then
    struct["waituntil.after_game"] = M("factdb", L(S(q.after_game.fact), ">=", 1), "next", L(story_start))
    story_start = "waituntil.after_game"
  end
  local gq = get(q, "game_quest") or Y.map()
  if T(get(gq, "file")) and get(gq, "obj") ~= nil then
    local entry = M("file", gq.file, "obj", I(gq.obj))
    local states = get(gq, "when") == "with" and {"JS_Active", "JS_Success", "JS_Failed"} or {"JS_Success", "JS_Failed"}
    local any = Y.list({})
    for _, st in ipairs(states) do any[#any + 1] = M("journal", entry, "status", st) end
    struct["waituntil.game_quest"] = M("any", any, "next", L(story_start))
    story_start = "waituntil.game_quest"
  end
  if T(get(get(q, "inside_game") or Y.map(), "phase")) then
    local start_fact, over_fact = GEN.inside_facts(qid)
    struct["waituntil.inside_game"] = M("factdb", L(start_fact, ">=", 1), "next", L(story_start))
    story_start = "waituntil.inside_game"
    struct["addfact.over"] = M("value", L(over_fact, 1), "next", L("waituntil.forever"))
    for _, e in ipairs({"addfact.done", "addfact.failed"}) do
      if struct[e] ~= nil then struct[e].next = L("addfact.over") end
    end
  end
  if QS.after_fact(qid, q) then
    -- starts when another conjunction quest was done (its fact <quest id>_done; a quest of the project: its own)
    struct["waituntil.after"] = M("factdb", L(QS.after_fact(qid, q), ">=", 1), "next", L(story_start))
    story_start = "waituntil.after"
  end
  -- a run left behind by Build & Play's live loading: its places hidden first (the chests, the things placed: 23.10.
  -- the old run's emptied chest stood over the new one's), then its people's communities let go (a community lets its
  -- people go only when nobody looks), then it ends
  local retire = {}
  for _, w in ipairs(worlds) do
    local names, seen_n = Y.list({}), {}
    for _, n in ipairs(start_worlds[w] or {}) do if not seen_n[n] then seen_n[n] = true names[#names + 1] = n end end
    for _, n in ipairs(later[w] or {}) do if not seen_n[n] then seen_n[n] = true names[#names + 1] = n end end
    if #names > 0 then
      retire[#retire + 1] = "changelayers.retire_" .. w
      struct[retire[#retire]] = M("world", w, "hide", names)
    end
  end
  local sets, seen_sets = Y.list({}), {}
  for _, k in ipairs(Y.keys(struct)) do
    local b = struct[k]
    if startswith_any(k, {"spawn.", "despawn."}) and Y.is_map(b) then
      for _, n in ipairs(P.list(get(b, "spawnsets"))) do
        if not seen_sets[n] then seen_sets[n] = true sets[#sets + 1] = n end
      end
    end
  end
  if #sets > 0 then
    retire[#retire + 1] = "despawn.retired"
    struct["despawn.retired"] = M("spawnsets", sets)
  end
  for k, a_ in ipairs(retire) do struct[a_].next = L(retire[k + 1] or "end") end
  -- ... and its people out at once and kept out until it ends, beside that (23.10.: the community spawned them again
  -- after the load - two citizens, both gave the quest)
  local gone = {}
  for _, pname in ipairs(Y.keys(project.places)) do
    for _, o in ipairs(P.list(get(project.places[pname], "objects"))) do
      if T(get(o, "id")) and Q.is_actor(o) then
        gone[#gone + 1] = "script.retire_" .. pname .. "_" .. S(o.id)
        struct[gone[#gone]] = M("function", "CjRunGoneKeep", "parameter",
                                L(M("tag", "cname_" .. qid .. "_" .. pname .. "_" .. S(o.id))))
      end
    end
  end
  local base, run = project.base_id, I(P.or_(get(project.meta, "stamp"), 0))
  struct["script.retired"] = M("function", "CjRunRetired", "parameter", L(M("base", base), M("run", run),
                                                                         M("retired", qid .. "_retired")),
                               "next", L(retire[1] or "end"))
  for _, g in ipairs(gone) do struct["script.retired"].next[#struct["script.retired"].next + 1] = g end
  watchers[#watchers + 1] = "script.retired"
  struct["script.run_start"] = M("function", "CjRunStart", "parameter", L(M("base", base), M("run", run)),
                                 "next", L(story_start))
  story_start = "script.run_start"
  local start_next = L(story_start)
  for _, w in ipairs(watchers) do start_next[#start_next + 1] = w end
  local structure = M("start", M("next", start_next))
  struct["end"] = M("next", ".done")
  local setups = {}
  for _, st in ipairs(GEN.all_steps(q)) do
    local kind, args = step_type(st)
    local a = args or Y.map()
    if kind == "loot" and T(get(a, "object")) and #GEN.step_items(a) == 0 then
      local ok, o = pcall(function() return ctx:object(a.object) end)
      if ok then
        if not Q.is_actor(o) and not T(get(o, "inventory")) and not T(get(o, "loot")) then
          o.inventory = L(M("item", "Crowns", "count", 25))
        end
      elseif not GEN.is_value_error(o) then
        error(o, 0)
      end
    end
  end
  for _, name in ipairs(Y.keys(project.places)) do
    local p = project.places[name]
    local taken = {}
    for _, o in ipairs(P.list(get(p, "objects"))) do if get(o, "id") ~= nil then taken[o.id] = true end end
    for _, o in ipairs(P.list(get(p, "objects"))) do
      local actor = Q.is_actor(o)
      if T(get(o, "inventory")) or T(get(o, "appearance")) or T(get(o, "loot")) or (P.has(o, "loot") and not actor) then
        if not T(get(o, "id")) then
          local b0 = PYS.lower((P.replace(o.template, "\\", "/"):match("([^/]*)$"):gsub("%.[^.]*$", "")))
          if b0 == "" then b0 = PYS.lower(P.replace(o.template, "\\", "/"):match("([^/]*)$")) end
          local oid, n = b0, 2
          while taken[oid] do oid, n = b0 .. "_" .. n, n + 1 end
          o.id = oid
          taken[oid] = true
        end
        local tag = "cname_" .. qid .. "_" .. name .. "_" .. S(o.id)
        if T(get(o, "appearance")) then
          setups[#setups + 1] = M("function", "CjSetupLook", "parameter", L(M("tag", tag), M("appearance", o.appearance)))
        end
        if P.has(o, "loot") and not actor then
          setups[#setups + 1] = M("function", "CjSetupLoot", "parameter", L(M("tag", tag), M("loot", P.or_(get(o, "loot"), ""))))
        elseif actor and T(get(o, "loot")) then
          setups[#setups + 1] = M("function", "CjSetupDrops", "parameter", L(M("tag", tag), M("loot", o.loot)))
        end
        for _, e in ipairs(P.list(get(o, "inventory"))) do
          local call = GEN.item_call(ctx, "CjSetupItem", need(e, "item"), {"count", I(get(e, "count", 1))})
          table.insert(call.parameter, 1, M("tag", tag))
          setups[#setups + 1] = call
        end
      end
    end
  end
  for _, st in ipairs(GEN.all_steps(q)) do
    local kind, args = step_type(st)
    local a = args or Y.map()
    local holder
    if kind == "collect" and (get(a, "from") == "container" or get(a, "from") == "person") then holder = get(a, "in")
    elseif kind == "loot" then holder = get(a, "object") end
    if T(holder) then
      for _, it in ipairs(GEN.step_items(a)) do
        local call = GEN.item_call(ctx, "CjSetupItem", it.item, {"count", it.count})
        table.insert(call.parameter, 1, M("tag", "cname_" .. ctx:object_tag(holder)))
        setups[#setups + 1] = call
      end
    end
    if kind == "clues" then
      for _, c in ipairs(P.list(get(args or Y.map(), "clues"))) do
        if T(get(c, "object")) then
          local refs = {}
          if GEN.is_clue_template(ctx:object(c.object).template) then refs[#refs + 1] = c.object end
          for _, t in ipairs(P.list(get(c, "trail"))) do if T(t) then refs[#refs + 1] = t end end
          for _, ref in ipairs(refs) do
            setups[#setups + 1] = M("function", "CjClueOff", "parameter", L(M("tag", "cname_" .. ctx:object_tag(ref))))
          end
        end
      end
    end
  end
  local k = 0
  for _, name in ipairs(Y.keys(project.places)) do
    for _, o in ipairs(P.list(get(project.places[name], "objects"))) do
      if Q.is_actor(o) and T(get(o, "id")) and GEN.has_own_talk(o.template) then
        k = k + 1
        struct["script.owntalk_" .. k] = M("function", "CjOwnTalkOff", "parameter",
                                           L(M("tag", "cname_" .. qid .. "_" .. name .. "_" .. S(o.id))))
        structure.start.next[#structure.start.next + 1] = "script.owntalk_" .. k
      end
    end
  end
  -- each from the start, side by side: one waits for its entity until it is there
  for n, s in ipairs(setups) do
    struct["script.setup_" .. n] = with(s, "next", L("waituntil.setup_rest"))
    structure.start.next[#structure.start.next + 1] = "script.setup_" .. n
  end
  if #setups > 0 then
    struct["waituntil.setup_rest"] = M("factdb", L(qid .. "_never", "=", 1), "next", L("end"))
  end
  for kk, v in pairs(struct) do structure[kk] = v end
  drop_unreached(structure)
  local journals = nil
  if has_q then
    local first_world = start_order[1]
    if first_world == nil then
      for _, n in ipairs(Y.keys(project.places)) do
        local w = get(project.places[n], "world")
        if T(w) then first_world = w break end
      end
    end
    if first_world == nil then                  -- (a quest with objects of the world only: their world)
      local wo = get(project.meta or Y.map(), "world_objects")
      if Y.is_map(wo) then
        for _, id in ipairs(Y.keys(wo)) do
          local w = get(wo[id], "world")
          if T(w) then first_world = w break end
        end
      end
    end
    local function entry(qq, objs, kq)
      local qtype = PYS.lower(S(get(qq, "type", "secondary")))
      if not GEN.QUEST_TYPES[qtype] then
        fail("quest type '" .. qtype .. "' - one of " .. table.concat(GEN.QUEST_TYPE_NAMES, ", "))
      end
      local jq = M("title", get(qq, "title", get(project.meta, "name", qid)), "type", GEN.QUEST_TYPES[qtype])
      if T(get(qq, "level")) then jq.level = I(qq.level) end
      local desc = L(M("start", get(qq, "description", "")))
      for _, d in ipairs(GEN.descriptions_of(ctx, kq)) do desc[#desc + 1] = d end
      jq.description = desc
      local wset = {}
      for _, ob in ipairs(objs) do
        for _, o in pairs(ob) do
          local w = P.or_(get(o, "world"), first_world)
          if w ~= nil then wset[w] = true end
        end
      end
      if first_world ~= nil then wset[first_world] = true end
      local nworlds = 0
      for _ in pairs(wset) do nworlds = nworlds + 1 end
      for _, ob in ipairs(objs) do
        for _, o in pairs(ob) do
          local w = P.or_(Y.remove(o, "world"), first_world)
          if w == Y.null then w = first_world end
          if nworlds > 1 then o.world = w end
        end
      end
      if nworlds == 1 then jq.world = first_world end
      if first_world == nil then
        fail("The quest is in no world yet. Please place something for it (an NPC, an object, a spot)")
      end
      if #objs == 0 then
        -- (a quest of a scene alone, a SCENE block right after the start: the journal's one objective is its title,
        -- never shown as a goal - 11.11., a player building a first scene was stopped here and asked for a goal)
        objs = {M("s0_quest", M("caption", S(P.or_(get(qq, "title"), get(project.meta, "name", qid)))))}
      end
      jq.instructions = M("main", Y.list(objs))
      return jq
    end
    local mine = QS.objectives_by_part(objectives, parts)
    local quests = Y.map()
    local keys = {}
    for kq in pairs(parts) do keys[#keys + 1] = kq end
    table.sort(keys)
    for _, kq in ipairs(keys) do
      quests[QS.journal_key(qid, kq)] = entry(kq == 1 and q or parts[kq], mine[kq] or {}, kq)
    end
    journals = M("quests", quests)
    if Y.len(ctx.characters) > 0 then journals.characters = ctx.characters end
  end
  local tags = Y.map()
  for _, name in ipairs(Y.keys(project.places)) do
    for _, o in ipairs(P.list(get(project.places[name], "objects"))) do
      if T(get(o, "id")) then tags[name .. "/" .. S(o.id)] = qid .. "_" .. name .. "_" .. S(o.id) end
    end
  end
  ctx.items = Y.map()
  for _, iid in ipairs(Y.keys(P.map(get(q, "items")))) do
    local it = q.items[iid]
    local d = Y.map()
    for _, kv in ipairs({{"name", P.or_(get(it, "name"), iid)}, {"description", get(it, "description", "")},
                         {"text", get(it, "text", "")}}) do
      if T(kv[2]) then d[kv[1]] = kv[2] end
    end
    ctx.items[iid] = d
  end
  local swaps = P.map(get(project.meta, "swaps"))
  local swap_ids = Y.keys(swaps)
  table.sort(swap_ids)
  for n, sid in ipairs(swap_ids) do scenes[qid .. "_swap_" .. sid] = GEN.swap_scene(ctx, n, swaps[sid]) end
  return structure, journals, meta, tags, communities, scenes, ctx.rewards, ctx.speech, ctx.items
end

-- a game scene swapped (scene_swap.lua): its radish scene, the lines' strings and speech as a talk's; `_target`: the
-- game's path it is built to
function GEN.swap_scene(ctx, k, sw)
  if not (T(get(sw, "scene")) and T(get(sw, "outline"))) then
    fail("a scene swap without its game scene: " .. S(P.or_(get(sw, "name"), sw)))
  end
  local DS = require("conjunction.dialogue_scene")
  local SS = require("conjunction.scene_swap")
  local talks = {}
  local ins = P.map(get(sw, "inputs"))
  for _, name in ipairs(Y.keys(ins)) do
    local i = ins[name]
    talks[#talks + 1] = P.list(get(P.or_(get(i, "talk"), i), "dialogue"))
  end
  local own = 0
  for _, t in ipairs(talks) do own = own + #DS.custom_voiced(t) end
  local first_own = own > 0 and ctx:strings(own) or 0
  local n = -1
  local own_ids = function()
    n = n + 1
    if n >= own then return nil end
    return 2110000000 + ctx.idspace * 1000 + first_own + n
  end
  local new_speech = Y.list({})
  local count = 0
  for _, t in ipairs(talks) do count = count + DS.string_count(t) end
  local idstart = ctx:strings(count)
  local scene = SS.scene(sw, 800 + k, ctx.idspace, idstart, new_speech, own_ids,
                         function(item) return GEN.own_item(ctx, item) end)
  local want = {}
  for _, e in ipairs(new_speech) do if not T(get(e, "source")) then want[#want + 1] = e end end
  local timing = GEN.text_timing(want)
  for _, e in ipairs(new_speech) do
    if timing[e.id] ~= nil then e.dur = timing[e.id] end
  end
  GEN.put_durations(scene, timing)
  for _, e in ipairs(new_speech) do ctx.speech[#ctx.speech + 1] = e end
  scene._target = sw.scene
  return scene
end

return GEN
