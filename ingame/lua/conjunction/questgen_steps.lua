-- The step types of the quest generator (quest.py's classes): each `generate(self, ctx, i, s)` -> a StepOut - the
-- radish blocks that run the step, its objective, its meta entities, its scenes, where its outputs lead.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local N = require("conjunction.pynum")
local PYS = require("conjunction.pystr")
local QN = require("conjunction.quest_nodes")
local Q = require("conjunction.quest")
local GEN = require("conjunction.questgen")
local M, L, F, I, S, R = GEN.map, GEN.list, GEN.float, GEN.int, GEN.str, GEN.round
local fail, need, with, merged, setdefault, partition = GEN.fail, GEN.need, GEN.with, GEN.merged, GEN.setdefault,
                                                         GEN.partition
local StepOut, step_type, item_call = GEN.StepOut, GEN.step_type, GEN.item_call
local T, get = P.T, P.get

local function sfx(i) return "s" .. S(i) end
local function pts3(path)                        -- [p for p in path if p and len(p) >= 3]
  local out = {}
  for _, p in ipairs(P.list(path)) do if T(p) and #p >= 3 then out[#out + 1] = p end end
  return out
end
local function path_text(path)                   -- ";".join(",".join(f"{float(v):.2f}" for v in p[:3]) for p in path)
  local parts = {}
  for _, p in ipairs(path) do
    parts[#parts + 1] = string.format("%.2f,%.2f,%.2f", F(p[1]), F(p[2]), F(p[3]))
  end
  return table.concat(parts, ";")
end
local function round3(p)                         -- [round(float(v), 3) for v in p[:3]]
  return L(R(F(p[1]), 3), R(F(p[2]), 3), R(F(p[3]), 3))
end
local function floats3(p) return L(F(p[1]), F(p[2]), F(p[3])) end
local function add_all(dst, src) for k, v in pairs(src) do dst[k] = v end end
local function meta_update(meta, m)              -- meta.setdefault(w, {}).setdefault(key, {}).update(v)
  for w, mm in pairs(m) do
    for key, v in pairs(mm) do add_all(setdefault(setdefault(meta, w, Y.map()), key, Y.map()), v) end
  end
end
local function extend(list, more) for _, x in ipairs(more) do list[#list + 1] = x end return list end
local function scene_path(ctx, name) return "dlc/dlc" .. ctx.qid .. "/data/scenes/" .. name .. ".w2scene" end

-- ===================================================================================================================
local Goto = {name = "goto"}
function Goto:generate(ctx, i, s)
  local mode = T(get(s, "mode")) and s.mode or "arrive"
  local si = sfx(i)
  if mode == "near" then                         -- near a person, wherever they are now
    if not T(get(s, "who")) then fail("step " .. S(i) .. ": go to - near whom? (the card: who)") end
    local fact, run, wait = ctx.qid .. "_" .. si .. "_near", "script." .. si .. "_near", "waituntil." .. si
    local blocks = M(run, M("function", "CjNearTo", "parameter", L(
      M("tag", "cname_" .. ctx:object_tag(s.who)), M("radius", F(get(s, "radius", 5))), M("fact", fact)),
      "next", L(wait)), wait, M("factdb", L(fact, "=", 1)))
    return StepOut(blocks, run, wait, M("caption", get(s, "text", "Go to them")))
  end
  if mode == "look" then                         -- look at someone / something for some seconds
    if not T(get(s, "who")) then fail("step " .. S(i) .. ": look at - whom or what? (the card: who)") end
    local fact, run, wait = ctx.qid .. "_" .. si .. "_look", "script." .. si .. "_look", "waituntil." .. si
    local blocks = M(run, M("function", "CjLookAt", "parameter", L(
      M("tag", "cname_" .. ctx:object_tag(s.who)), M("seconds", F(get(s, "seconds", 3))),
      M("radius", F(get(s, "radius", 20))), M("fact", fact)), "next", L(wait)), wait, M("factdb", L(fact, "=", 1)))
    return StepOut(blocks, run, wait, M("caption", get(s, "text", "Watch them")))
  end
  if T(get(s, "at")) then                        -- the spot marker: where it stands now
    local place, _, oid = partition(s.at, "/")
    local o
    for _, x in ipairs(P.list(get(get(ctx.project.places, place) or Y.map(), "objects"))) do
      if get(x, "id") == oid then o = x break end
    end
    if o == nil then fail("step " .. S(i) .. ": its spot (" .. S(s.at) .. ") is gone - set it again") end
    s = with(s, "place", place, "pos", o.pos)
  end
  local world, center
  if P.has(s, "place") then
    world = ctx:place_world(s.place)
    center = get(s, "pos")
    if not T(center) then center = ctx:place_center(s.place) end
  else
    world, center = need(s, "world"), need(s, "pos")
  end
  local area, pin = ctx.qid .. "_" .. si .. "_area", ctx.qid .. "_" .. si .. "_pin"
  local radius = F(get(s, "radius", 10))
  local meta = M(world, M("areas", M(area, GEN.area(center, radius)), "mappins",
                          M(pin, L(R(center[1], 3), R(center[2], 3), R(center[3], 3)))))
  local wait = "waituntil." .. si
  local shown = get(s, "map") == "pin" and 0.0 or F(P.or_(get(s, "map_radius"), radius))
  local objective = M("caption", get(s, "text", "Go there"), "mappins", L(L(pin, shown)), "world", world)
  if mode == "leave" then                        -- away from the spot: farther than the radius
    local fact, run = ctx.qid .. "_" .. si .. "_away", "script." .. si .. "_away"
    local blocks = M(run, M("function", "CjAwayFrom", "parameter", L(
      M("x", F(center[1])), M("y", F(center[2])), M("z", F(center[3])), M("radius", radius), M("fact", fact)),
      "next", L(wait)), wait, M("factdb", L(fact, "=", 1)))
    Y.remove(meta[world], "areas")
    objective.caption = get(s, "text", "Get away from there")
    if objective.caption == nil then objective.caption = Y.null end
    return StepOut(blocks, run, wait, objective, meta)
  end
  if T(get(s, "when")) or T(get(s, "stay")) then
    local fr, to = GEN.hours(get(s, "when"))
    local fact, go = ctx.qid .. "_" .. si .. "_go", "script." .. si .. "_go"
    Y.remove(meta[world], "areas")
    local blocks = M(go, M("function", "CjGoAt", "parameter", L(
      M("x", F(center[1])), M("y", F(center[2])), M("z", F(center[3])), M("radius", radius), M("fromHour", fr),
      M("toHour", to), M("stay", T(get(s, "stay"))), M("fact", fact))))
    if not T(get(s, "stay")) then return StepOut(blocks, go, go, objective, meta) end
    local decide = "waituntil." .. si .. "_go"
    blocks[go].next = L(decide)
    blocks[decide] = M("conditions", M("arrived", M("factdb", L(fact, "=", 1)), "left", M("factdb", L(fact, "=", 2))))
    return StepOut(blocks, go, decide, objective, meta, nil, M("arrived", "continue", "left", "fail"))
  end
  -- in the area, also when the player is there already as the step comes (the game's "Wait: player in area")
  return StepOut(M(wait, M("inside", world .. "/" .. area)), wait, wait, objective, meta)
end
GEN.add_block(Goto)

-- ===================================================================================================================
-- loot / examine / use an object of a place (containers are looted, clues examined, levers used)
local function Interact(name, condition, default_text)
  local self = {name = name, condition = condition, default_text = default_text}
  function self:generate(ctx, i, s)
    local si = sfx(i)
    local tag = ctx:object_tag(need(s, "object"))
    local meta, where = GEN.pin(ctx, i, {s.object})
    if self.name == "use" and (get(s, "state") == "on" or get(s, "state") == "off") then
      local b = "script." .. si .. "_switch"
      return StepOut(M(b, M("function", "CjWaitSwitch", "parameter", L(M("tag", "cname_" .. tag),
                                                                       M("on", s.state == "on")))),
                     b, b, merged(M("caption", GEN.caption(ctx, "use", s)), where), meta)
    end
    if self.name == "use" and T(get(s, "item")) then
      local count = I(get(s, "count", 1))
      local fact = ctx.qid .. "_" .. si .. "_have"
      local check, decide, pause = "script." .. si .. "_check", "waituntil." .. si .. "_have", "waituntil." .. si .. "_later"
      local used, take = "waituntil." .. si, "script." .. si .. "_take"
      local blocks = M(
        check, with(item_call(ctx, "CjHasItems", s.item, {"count", count, "fact", fact}), "next", L(decide)),
        decide, M("conditions", M("have", M("factdb", L(fact, "=", 1)), "notyet", M("factdb", L(fact, "=", 0))),
                  "next.notyet", L(pause), "next.have", L(used)),
        pause, M("elapsed", "00:02:00", "next", L(check)),
        used, M("used", "~" .. tag, "next", L(take)),
        take, item_call(ctx, "CjPlayerItem", s.item, {"count", -count}))
      return StepOut(blocks, check, take, merged(M("caption", GEN.caption(ctx, "use", s)), where), meta)
    end
    local template = get(ctx:object(s.object), "template") or ""
    -- (a thing of the world was picked as one that fits: the game's own interaction, never a clue of ours)
    local plain = not require("conjunction.world_pick").is_ref(s.object) and (
                  (self.name == "examine" and not GEN.is_clue_template(template)) or
                  (self.name == "use" and not T(get(s, "item")) and get(s, "state") ~= "on" and get(s, "state") ~= "off"
                   and not GEN.usable(template)) or
                  (self.name == "loot" and not T(get(s, "item")) and not Q.lootable(template)))
    if plain then
      local out = GEN.BLOCKS.clues:generate(ctx, i, M("clues", L(M("object", s.object, "how", get(s, "how")))))
      out.objective = merged(M("caption", GEN.caption(ctx, self.name, s)), where)
      out.meta = meta
      return out
    end
    if self.name == "loot" and T(get(s, "item")) then
      local out = GEN.BLOCKS.collect:generate(ctx, i, M("item", s.item, "count", get(s, "count", 1),
                                                         "more_items", P.or_(get(s, "more_items"), Y.list({})),
                                                         "keep_in", s.object))
      out.objective = merged(M("caption", GEN.caption(ctx, "loot", s)), where)
      out.meta = meta
      return out
    end
    local wait = "waituntil." .. si
    local cond = M(self.condition, "~" .. tag)
    -- (a thing of the world: the game's own interaction of it by name - 11.11., "used" of a picked door had none and
    -- the build stopped: the encoder did not know it)
    if require("conjunction.world_pick").is_ref(s.object) then
      local act = get(s, "action") or require("conjunction.world_pick").interaction_for(ctx:object(s.object), self.name)
      if act then cond = M(self.condition, "~" .. tag, "action", act) end
    end
    return StepOut(M(wait, cond), wait, wait,
                   merged(M("caption", get(s, "text", self.default_text)), where), meta)
  end
  return self
end
GEN.add_block(Interact("loot", "looted", "Search it"))
GEN.add_block(Interact("examine", "examined", "Examine it"))
GEN.add_block(Interact("use", "used", "Use it"))

-- ===================================================================================================================
-- talk to an NPC of a place: a dialogue tree, then onward
local Talk = {name = "talk"}
GEN.Talk = Talk
GEN.AUTO_POSE = false

-- the radish scene of a dialogue -> scene, ways out (a set); its lines' audio goes to ctx.speech
function Talk.scene(ctx, i, name, lines, npc, tag, fact, o)
  o = o or {}
  local DS = require("conjunction.dialogue_scene")
  local own = #DS.custom_voiced(lines)
  local first_own = own > 0 and ctx:strings(own) or 0
  local k = -1
  local own_ids = function()
    k = k + 1
    if k >= own then return nil end
    return 2110000000 + ctx.idspace * 1000 + first_own + k
  end
  local new_speech = Y.list({})
  -- radish takes a scene's id from 0 to 999 only, one each: a step's number names it where it can (a project's
  -- quest 2 numbers its steps from 2001), else the highest one still free
  ctx.scene_ids = ctx.scene_ids or {}
  local used = ctx.scene_ids
  local sid = I(i)
  if not (sid >= 0 and sid <= 999) or used[sid] then
    sid = 999
    while used[sid] do sid = sid - 1 end
  end
  used[sid] = true
  local idstart = ctx:strings(DS.string_count(lines))
  local scene, ends = DS.to_scene(lines, npc and npc.template or nil, tag, sid, ctx.idspace, idstart, fact, own_ids,
                                  new_speech, {extras = o.extras or {}, own_item = function(item) return GEN.own_item(ctx, item) end,
                                               character = o.character or ctx.start_as, qid = ctx.qid, poses = o.poses,
                                               gameplay = o.gameplay or false, cams = o.cams, stands = o.stands,
                                               placement = o.placement or "PLAYER", cam_defaults = o.cam_defaults,
                                               marks = o.marks, props = o.props})
  -- lines without a voice: as long as radish times their phonemes (the mouth moves to the text)
  local want = {}
  for _, e in ipairs(new_speech) do if not T(get(e, "source")) then want[#want + 1] = e end end
  local timing = GEN.text_timing(want)
  for _, e in ipairs(new_speech) do
    if timing[e.id] ~= nil then e.dur = timing[e.id] end
  end
  GEN.put_durations(scene, timing)
  DS.fit_gestures(scene)                          -- a gesture longer than its line ends with it, blended out
  for _, e in ipairs(new_speech) do ctx.speech[#ctx.speech + 1] = e end
  if o.gameplay then                              -- lines as subtitles, no cameras: the player keeps control
    scene.production.gameplay = true
    Y.remove(scene.production.assets, "cameras")
    Y.remove(scene.storyboard, "defaults")
  end
  return scene, ends
end

function Talk:generate(ctx, i, s)
  local D = require("conjunction.dialogue")
  local DS = require("conjunction.dialogue_scene")
  local si = sfx(i)
  local ref = T(get(s, "npc")) and s.npc or nil
  if not ref then fail("step " .. S(i) .. ": talk - to whom? (Pick, Search or Create on the card)") end
  local npc = ctx:object(ref)
  if ctx.moved[ref] then
    local pos, yaw = ctx.moved[ref][1], ctx.moved[ref][2]
    npc = with(npc, "pos", floats3(pos), "rot", L(0.0, 0.0, F(yaw)))
  end
  local place = partition(ref, "/")
  local world, tag = ctx:place_world(place), ctx:object_tag(ref)
  local name = ctx.qid .. "_" .. si
  local fact = ctx.qid .. "_" .. si .. "_choice"
  local lines = D.from_step(s)
  if not T(lines) then lines = L(M("who", "npc", "text", "...")) end
  local extras = {}
  for _, w in ipairs(P.list(get(s, "with"))) do
    extras[#extras + 1] = {w.who, ctx:object(w.who).template, ctx:object_tag(w.who), get(w, "joins", "start")}
  end
  local start = get(s, "start", "interact")
  if start == "overhear" then
    for _, x in ipairs(lines) do
      if P.has(x, "choice") then fail("step " .. S(i) .. ": an overheard talk has no choices - only lines") end
    end
  end
  local poses = Y.map()
  for k, v in pairs(P.map(get(s, "poses"))) do poses[k] = v end
  local yaw0 = F(npc.rot[3])
  local function space(c) return DS.scene_space(c, npc.pos, yaw0) end
  local function spaced(key)
    local out = Y.map()
    for k, c in pairs(P.map(get(s, key))) do out[k] = space(c) end
    return out
  end
  local cams, stands, marks = spaced("cams"), spaced("spots"), spaced("marks")
  local sp = name .. "_sp"
  local placement = start == "overhear" and "PLAYER" or (ctx.qid .. "_" .. world .. "_" .. sp .. "_sp")
  local scene, ends = Talk.scene(ctx, i, name, lines, npc, tag, fact, {
    extras = extras, character = ctx:character(s), poses = poses, cams = cams, stands = stands, placement = placement,
    cam_defaults = get(s, "cam_defaults"), marks = marks, props = get(s, "props"), gameplay = start == "overhear"})
  local scenes = M(name, scene)
  local x, y, z = npc.pos[1], npc.pos[2], npc.pos[3]
  local pin = name .. "_pin"
  local meta = M(world, M("scenepoints", M(sp, L(x, y, z, F(npc.rot[3]))), "mappins", M(pin, L(x, y, z))))
  local path = scene_path(ctx, name)
  local blocks = Y.map()
  local first, block
  if start == "now" then
    block = "scene." .. si
    first = block
    blocks[block] = M("scene", path, "placement", world .. "/" .. sp)
  elseif start == "near" or start == "overhear" then
    first, block = "script." .. si .. "_near", "scene." .. si
    blocks[first] = M("function", "CjWaitNear", "parameter", L(
      M("tag", "cname_" .. tag), M("radius", F(get(s, "radius", 6))), M("x", F(x)), M("y", F(y)), M("z", F(z))),
      "next", L(block))
    blocks[block] = M("scene", path, "placement", world .. "/" .. sp)
  else
    block = "interaction." .. si
    blocks[block] = M("scene", path, "placement", world .. "/" .. sp, "actor", L(tag))
    first = block
    if start == "calls" then
      local call_lines = get(s, "call")
      if not T(call_lines) then call_lines = L(M("who", "npc", "text", "Witcher! Over here!")) end
      local call = Talk.scene(ctx, 900 + I(i), name .. "_call", call_lines, npc, tag, fact .. "_call",
                              {character = ctx:character(s), gameplay = true})
      scenes[name .. "_call"] = call
      local area = name .. "_call"
      meta[world].areas = M(area, GEN.area(L(x, y, z), F(get(s, "radius", 10))))
      first = "addfact." .. si .. "_calls"
      blocks[first] = M("value", L(ctx.qid .. "_" .. si .. "_calls", 1), "next", L("waituntil." .. si .. "_call", block))
      blocks["waituntil." .. si .. "_call"] = M("entered", world .. "/" .. area, "next", L("scene." .. si .. "_call"))
      blocks["scene." .. si .. "_call"] = M("scene", scene_path(ctx, name .. "_call"), "placement", world .. "/" .. sp)
    end
  end
  local again_path
  local again = (QN.repeat_of(s) ~= nil and start ~= "now") and DS.again_lines(s) or nil
  if T(again) then                               -- talked to again: what one may ask again (again_lines)
    local scene_again = Talk.scene(ctx, 700 + I(i), name .. "_again", again, npc, tag, fact, {
      extras = extras, character = ctx:character(s), poses = poses, cams = cams, stands = stands, placement = placement,
      cam_defaults = get(s, "cam_defaults"), marks = marks, props = get(s, "props"), gameplay = start == "overhear"})
    scenes[name .. "_again"] = scene_again
    again_path = scene_path(ctx, name .. "_again")
  end
  local last, branches = block, Y.map()
  local sorted_ends = {}
  for e in pairs(ends) do sorted_ends[#sorted_ends + 1] = e end
  table.sort(sorted_ends)
  if #sorted_ends > 1 then
    last = "waituntil." .. si .. "_choice"
    blocks[block].next = L(last)
    local code = DS.codes(ends)
    local conds = Y.map()
    for _, e in ipairs(sorted_ends) do conds[D.socket(e)] = M("factdb", L(fact, "=", code[e])) end
    blocks[last] = M("conditions", conds)
    for _, e in ipairs(sorted_ends) do branches[D.socket(e)] = e end
  elseif not (#sorted_ends == 1 and sorted_ends[1] == "continue") then
    branches[""] = sorted_ends[1]                -- only one way out that is not "goes on": the quest follows it
  end
  if start == "now" then
    Y.remove(meta[world], "mappins")
    return StepOut(blocks, first, last, nil, meta, scenes, branches)
  end
  local caption = get(s, "text", start == "overhear" and "Listen in" or "Talk to them")
  local out = StepOut(blocks, first, last, M("caption", caption, "mappins", L(L(pin, 3.0)), "world", world), meta, scenes,
                      branches)
  out.again_scene = again_path and {path, again_path} or nil
  return out
end
GEN.add_block(Talk)

-- a placed person's action (npc_actions: group/job) -> the pose a talk with them starts in, or nil (standing)
function GEN.pose_of_action(action)
  local job = S(action or ""):match("([^/]*)$")
  if job == "" then return nil end
  local function has(w) return job:find(w, 1, true) ~= nil end
  if P.startswith(job, "sit") and (has("ground") or has("bath") or has("floor")) then return "sit_ground" end
  if P.startswith(job, "sit") then return "sit" end
  if P.startswith(job, "kneel") then return "kneel" end
  if P.startswith(job, "lie") or P.startswith(job, "lying") or P.startswith(job, "sleep") then return "lie" end
  if has("lean") then return "lean" end
  return nil
end

-- ===================================================================================================================
-- an either of the graph's newer form: ways wired to goals (the first goal done wins), not options in it
function GEN.first_wins(s) return Y.is_map(s) and P.has(s, "ways") and not T(get(s, "options")) end

-- a goal inside an either / all of these: its whole chain, its last block leading to `then` -> its first
local function embed(blocks, out, then_)
  for name, b in pairs(out.blocks) do blocks[name] = with(b) end
  blocks[out.last] = with(blocks[out.last], "next", L(then_))
  return out.first
end

local EITHER_KINDS = {"goto", "loot", "examine", "use", "kill"}
local function allowed(kind) for _, k in ipairs(EITHER_KINDS) do if k == kind then return true end end return false end
local function no_when(args)
  local out = Y.map()
  for k, v in pairs(args or Y.map()) do if k ~= "when" and k ~= "stay" then out[k] = v end end
  return out
end

local Either = {name = "either"}
function Either:generate(ctx, i, s)
  local si = sfx(i)
  if GEN.first_wins(s) then
    local fork = "addfact." .. si .. "_either"
    return StepOut(M(fork, M("value", L(ctx.qid .. "_" .. si .. "_either", 1))), fork, fork, nil)
  end
  local opts = P.list(get(s, "options"))
  if #opts < 2 then fail("step " .. S(i) .. ": an either needs two options or more") end
  local blocks, meta, pins, conditions, branches, scenes = Y.map(), Y.map(), Y.list({}), Y.map(), Y.map(), Y.map()
  local fork = "addfact." .. si .. "_either"
  local waiters = {}
  for k, o in ipairs(opts) do
    local kind, args = step_type(need(o, "goal"))
    if kind == "goto" then args = no_when(args) end
    if not allowed(kind) then
      fail("step " .. S(i) .. ": an either option can be " .. table.concat(EITHER_KINDS, ", ") .. " - not " .. kind)
    end
    local out = GEN.BLOCKS[kind]:generate(ctx, S(i) .. "_" .. k, args or Y.map())
    local fact = ctx.qid .. "_" .. si .. "_o" .. k
    local done = "addfact." .. si .. "_o" .. k
    waiters[#waiters + 1] = embed(blocks, out, done)
    blocks[done] = M("value", L(fact, 1))
    add_all(scenes, out.scenes)
    meta_update(meta, out.meta)
    if out.objective then extend(pins, P.list(get(out.objective, "mappins"))) end
    conditions["o" .. k] = M("factdb", L(fact, ">=", 1))
    branches["o" .. k] = T(get(o, "path")) and ("path:" .. S(o.path)) or "continue"
  end
  local decide = "waituntil." .. si .. "_decide"
  blocks[decide] = M("conditions", conditions)
  local nxt = Y.list({})
  extend(nxt, waiters)
  nxt[#nxt + 1] = decide
  blocks[fork] = M("value", L(ctx.qid .. "_" .. si .. "_either", 1), "next", nxt)
  return StepOut(blocks, fork, decide, M("caption", get(s, "text", "Decide"), "mappins", pins), meta, scenes, branches)
end
GEN.add_block(Either)
GEN.Either = Either

local AllOf = {name = "all"}
function AllOf:generate(ctx, i, s)
  local si = sfx(i)
  local opts = P.list(get(s, "options"))
  if #opts < 2 then fail("step " .. S(i) .. ": all of these - two goals or more") end
  local count = ctx.qid .. "_" .. si .. "_all"
  local blocks, meta, pins, waiters, scenes = Y.map(), Y.map(), Y.list({}), {}, Y.map()
  for k, o in ipairs(opts) do
    local kind, args = step_type(need(o, "goal"))
    if kind == "goto" then args = no_when(args) end
    if not allowed(kind) then
      fail("step " .. S(i) .. ": all of these can wait for " .. table.concat(EITHER_KINDS, ", ") .. " - not " .. kind)
    end
    local out = GEN.BLOCKS[kind]:generate(ctx, S(i) .. "_" .. k, args or Y.map())
    local done = "addfact." .. si .. "_a" .. k
    waiters[#waiters + 1] = embed(blocks, out, done)
    blocks[done] = M("value", L(count, 1))
    add_all(scenes, out.scenes)
    meta_update(meta, out.meta)
    if out.objective then extend(pins, P.list(get(out.objective, "mappins"))) end
  end
  local fork, last = "addfact." .. si .. "_all_on", "waituntil." .. si .. "_all"
  blocks[last] = M("factdb", L(count, ">=", #opts))
  local nxt = extend(Y.list({}), waiters)
  nxt[#nxt + 1] = last
  blocks[fork] = M("value", L(ctx.qid .. "_" .. si .. "_all_on", 1), "next", nxt)
  return StepOut(blocks, fork, last, M("caption", get(s, "text", "Do all of these"), "mappins", pins), meta, scenes,
                 nil, {count, #opts})
end
GEN.add_block(AllOf)

-- ===================================================================================================================
-- find clues with the witcher senses - each switched on when its turn comes, waited for, commented
local Clues = {name = "clues", HOW = {ground = 1, eye = 2, body = 3, high = 4}}
function Clues:generate(ctx, i, s)
  local si = sfx(i)
  local items = {}
  for _, c in ipairs(P.list(get(s, "clues"))) do
    if T(get(c, "object")) or T(get(c, "trail")) then items[#items + 1] = c end
  end
  if #items == 0 then fail("step " .. S(i) .. ": find clues - which? (add clues on the card)") end
  local found = ctx.qid .. "_" .. si .. "_found"
  local fork = "addfact." .. si .. "_clues"
  local blocks, scenes, firsts, points = Y.map(), Y.map(), {}, {}
  local world
  local in_order, tail = T(get(s, "in_order")), nil
  for k, c in ipairs(items) do
    local ref = P.or_(get(c, "object"), get(c, "trail"))
    local o = ctx:object(ref)
    local place = partition(ref, "/")
    world = ctx:place_world(place)
    local tag = ctx:object_tag(ref)
    local layer = ctx.qid .. "_" .. si .. "_c" .. k
    local count = "addfact." .. si .. "_c" .. k
    blocks[count] = M("value", L(found, 1))
    local entry, spot
    if T(get(c, "trail")) and not T(get(c, "object")) then
      local pcs = P.list(get(o, "pieces"))
      if #pcs == 0 then fail("step " .. S(i) .. ": trail " .. S(ref) .. " has no pieces (draw it again)") end
      local statics = Y.map()
      for n, p in ipairs(pcs) do
        statics[string.format("p%02d", n - 1)] = M("template", p[5], "pos", floats3(p), "rot", L(0.0, 0.0, F(p[4])),
                                                   "tags", L(tag))
      end
      ctx.layers[layer] = M("world", world, "statics", statics)
      ctx.trails_in_steps[ref] = true
      for _, p in ipairs(pcs) do points[#points + 1] = {p[1], p[2], p[3]} end
      local on, seen = "script." .. si .. "_c" .. k .. "_on", "script." .. si .. "_c" .. k .. "_seen"
      blocks[on] = M("function", "CjClueGroupOn", "parameter", L(M("tag", "cname_" .. tag)), "next", L(seen))
      blocks[seen] = M("function", "CjClueGroupSeen", "parameter", L(M("tag", "cname_" .. tag)), "next", L(count))
      entry = on
      spot = {pcs[1][1], pcs[1][2], pcs[1][3]}
    else
      local wait_tag = tag
      if not GEN.is_clue_template(o.template) then
        wait_tag = tag .. "_examine"
        ctx.own_entities.cj_examine_point = GEN.examine_point()
        local x, y, z = F(o.pos[1]), F(o.pos[2]), F(o.pos[3])
        ctx.layers[layer] = M("world", world, "statics", M("examine", M(
          "template", "dlc\\dlc" .. ctx.qid .. "\\data\\entities\\cj_examine_point.w2ent",
          "pos", L(x, y, z + 0.2), "rot", L(0.0, 0.0, 0.0), "tags", L(wait_tag))))
      end
      points[#points + 1] = o.pos
      local wait = "script." .. si .. "_c" .. k
      local said = get(c, "says") or Y.map()
      local says_early = (T(get(said, "text")) or T(get(said, "voice")) or T(get(said, "voice_pack"))) and
                         not T(get(c, "dialogue"))
      blocks[wait] = M("function", says_early and "CjClueSays" or "CjClueAs", "parameter", L(
        M("tag", "cname_" .. wait_tag), M("how", Clues.HOW[S(P.or_(get(c, "how"), ""))] or 0)), "next", L(count))
      entry = wait
      local trail = {}
      for _, t in ipairs(P.list(get(c, "trail"))) do if T(t) then trail[#trail + 1] = t end end
      for j = #trail, 1, -1 do
        local t = trail[j]
        local piece = "script." .. si .. "_c" .. k .. "_t" .. j
        blocks[piece] = M("function", "CjClueOn", "parameter", L(M("tag", "cname_" .. ctx:object_tag(t))),
                          "next", L(entry))
        points[#points + 1] = ctx:object(t).pos
        entry = piece
      end
      spot = o.pos
    end
    if ctx.layers[layer] ~= nil then             -- its layer shown first (hidden from the quest's start)
      local show = "changelayers." .. si .. "_c" .. k
      blocks[show] = M("world", world, "show", L(layer), "next", L(entry))
      entry = show
    end
    if in_order and tail then
      blocks[tail].next = L(entry)
    else
      firsts[#firsts + 1] = entry
    end
    tail = count
    local says = get(c, "says") or Y.map()
    local talk = T(get(c, "object")) and get(c, "dialogue") or nil
    if T(talk) or T(get(says, "text")) or T(get(says, "voice")) or T(get(says, "voice_pack")) then
      local name = ctx.qid .. "_" .. si .. "_c" .. k
      local sp = name .. "_sp"
      local x, y, z = spot[1], spot[2], spot[3]
      local lines = T(talk) and talk or L(with(says, "who", "player"))
      local sc = Talk.scene(ctx, 700 + 10 * I(i) + k, name, lines, nil, nil, name .. "_f",
                            {gameplay = not T(talk), character = ctx:character(s)})
      scenes[name] = sc
      setdefault(setdefault(ctx.extra_meta, world, Y.map()), "scenepoints", Y.map())[sp] = L(x, y, z, 0.0)
      blocks[count].next = L("scene." .. si .. "_c" .. k)
      blocks["scene." .. si .. "_c" .. k] = M("scene", scene_path(ctx, name), "placement", world .. "/" .. sp)
      tail = "scene." .. si .. "_c" .. k
    end
  end
  local done = "waituntil." .. si
  blocks[done] = M("factdb", L(found, ">=", #items))
  local nxt = extend(Y.list({}), firsts)
  nxt[#nxt + 1] = done
  blocks[fork] = M("value", L(ctx.qid .. "_" .. si .. "_clues", 1), "next", nxt)
  local sum = {0, 0, 0}
  for _, p in ipairs(points) do for n = 1, 3 do sum[n] = sum[n] + p[n] end end
  local cx, cy, cz = sum[1] / #points, sum[2] / #points, sum[3] / #points
  local far = -math.huge
  for _, p in ipairs(points) do far = math.max(far, ((p[1] - cx) ^ 2 + (p[2] - cy) ^ 2) ^ 0.5) end
  local radius = math.max(8.0, far + 5.0)
  local pin = ctx.qid .. "_" .. si .. "_pin"
  local meta = M(world, M("mappins", M(pin, L(R(cx, 3), R(cy, 3), R(cz, 3)))))
  return StepOut(blocks, fork, done, M("caption", get(s, "text", "Search for clues with your witcher senses"),
                                       "mappins", L(L(pin, R(radius, 1))), "world", world), meta, scenes, nil,
                 #items > 1 and {found, #items} or nil)
end
GEN.add_block(Clues)

-- ===================================================================================================================
local Follow = {name = "follow"}
function Follow:generate(ctx, i, s)
  local si = sfx(i)
  if not T(get(s, "who")) then fail("step " .. S(i) .. ": follow - who? (Pick on the card)") end
  local path = pts3(get(s, "path"))
  if #path == 0 then fail("step " .. S(i) .. ": follow - the path has no points (+ point on the card)") end
  local place = partition(s.who, "/")
  local world = ctx:place_world(place)
  local block = "script." .. si .. "_escort"
  if not T(get(s, "lead")) then
    ctx.moved[s.who] = {path[#path], GEN.heading(#path > 1 and path[#path - 1] or ctx:object(s.who).pos, path[#path])}
  end
  local text = path_text(path)
  local pin = ctx.qid .. "_" .. si .. "_pin"
  local meta = M(world, M("mappins", M(pin, round3(path[#path]))))
  local progress = ctx.qid .. "_" .. si .. "_at"
  local phases = ctx.walk_phases[s]
  local stuck = phases ~= nil and phases[3] == true
  local blocks, last
  if phases and not T(get(s, "lead")) and not stuck and P.T(get(s, "smooth", true)) then
    meta[world].mappins[pin] = round3(ctx:object(s.who).pos)
    blocks, block, last = Follow.along_path(ctx, i, s, phases, path, world, progress, pin, text)
  elseif phases and not T(get(s, "lead")) then
    meta[world].mappins[pin] = round3(ctx:object(s.who).pos)
    blocks, block, last = GEN.walk_chain(ctx, i, s.who, phases, F(get(s, "wait", 10)), progress, pin)
  else
    blocks = M(block, M("function", "CjEscort", "parameter", L(
      M("tag", "cname_" .. ctx:object_tag(s.who)), M("path", text), M("lead", T(get(s, "lead"))),
      M("run", T(get(s, "run"))), M("waitDist", F(get(s, "wait", 10))), M("progress", progress))))
    last = block
    if T(get(s, "lead")) then
      -- the person follows the player as in the game's quests (a scripted action: script moves are refused while
      -- their community leads them); CjEscort waits for both at the end, then a cut control block ends the action
      local fork, lead, cut = "addfact." .. si .. "_lead", "addfact.lead_" .. si, "addfact.cut_lead_" .. si
      ctx.minigames["lead_" .. si] = M("game", "lead", "npc", ctx:object_tag(s.who), "run", T(get(s, "run")))
      ctx.minigames["cut_lead_" .. si] = M("game", "cut", "blocks", L(lead))
      blocks[block].next = L(cut)
      blocks[fork] = M("value", L(ctx.qid .. "_" .. si .. "_lead", 1), "next", L(lead, block))
      blocks[lead] = M("value", L(ctx.qid .. "_lead_" .. si, 1), "next", L("waituntil.forever"))
      blocks[cut] = M("value", L(ctx.qid .. "_cut_lead_" .. si, 1))
      block, last = fork, cut
      if phases then
        -- then their phase at the way's end: they stay there
        local e = "spawn." .. si .. "_end"
        blocks[cut].next = L(e)
        blocks[e] = M("spawnsets", L(phases[1]), "phase", phases[2][#phases[2]][1])
        last = e
      end
    end
  end
  local first, scenes = block, Y.map()
  local talks = {}
  for _, t in ipairs(P.list(get(s, "talks"))) do
    local tt = get(t, "talk") or Y.map()
    if T(get(tt, "dialogue")) then talks[#talks + 1] = tt end
  end
  if #talks > 0 and not T(get(s, "lead")) then
    first = "addfact." .. si .. "_walk"
    local starts = Y.list({block})
    local npc, tag = ctx:object(s.who), ctx:object_tag(s.who)
    for j0, t in ipairs(talks) do
      local j = j0 - 1
      local at = math.max(1, math.min(#path, I(get(t, "at", 1))))
      local name = ctx.qid .. "_" .. si .. "_t" .. j
      local scene = Talk.scene(ctx, 400 + (10 * I(i) + j) % 100, name, t.dialogue, npc, tag, name .. "_x",
                               {character = ctx:character(s), gameplay = true})
      scenes[name] = scene
      local sp = name .. "_sp"
      local pt = path[at]
      setdefault(meta[world], "scenepoints", Y.map())[sp] = L(F(pt[1]), F(pt[2]), F(pt[3]), 0.0)
      local wait, play = "waituntil." .. si .. "_t" .. j, "scene." .. si .. "_t" .. j
      blocks[wait] = M("factdb", L(progress, ">=", at), "next", L(play))
      blocks[play] = M("scene", scene_path(ctx, name), "placement", world .. "/" .. sp)
      starts[#starts + 1] = wait
    end
    blocks[first] = M("value", L(ctx.qid .. "_" .. si .. "_walking", 1), "next", starts)
  end
  return StepOut(blocks, first, last, M("caption", GEN.caption(ctx, "follow", s), "mappins", L(L(pin, 0.0)),
                                        "world", world), meta, scenes)
end

-- the blocks of a follow the game's way -> blocks, first, last. alone: a walk - no companion, and without s.wait
-- the quest goes on at once (last: a block beside the walk)
function Follow.along_path(ctx, i, s, phases, path, world, progress, pin, text, alone)
  local si = sfx(i)
  local comm, names = phases[1], phases[2]
  local tag = ctx:object_tag(s.who)
  local ent, path_tag, layer = "cj_path_" .. si, ctx.qid .. "_" .. si .. "_path", ctx.qid .. "_" .. si .. "_path"
  local origin = floats3(path[1])
  ctx.own_entities[ent] = M("entityObject", M(".type", "CEntity", "components", M("path", M(".type", "CPathComponent"))))
  ctx.layers[layer] = M("world", world, "statics", M("path", M(
    "template", table.concat({"dlc", "dlc" .. ctx.qid, "data", "entities", ent .. ".w2ent"}, "\\"), "pos", origin,
    "rot", L(0.0, 0.0, 0.0), "tags", L(path_tag))))
  local pts = Y.list({})
  for _, p in ipairs(path) do
    pts[#pts + 1] = L(R(F(p[1]) - origin[1], 3), R(F(p[2]) - origin[2], 3), R(F(p[3]) - origin[3], 3))
  end
  ctx.minigames["path_" .. si] = M("game", "path", "entity", ent, "points", pts)
  if alone then
    ctx.minigames["follow_" .. si] = M("game", "walkpath", "npc", tag, "path", path_tag, "run", T(get(s, "run")),
                                       "pace", get(s, "pace"))
  else
    local wait = F(get(s, "wait", 10))
    ctx.minigames["follow_" .. si] = M("game", "follow", "npc", tag, "path", path_tag, "max", wait,
                                       "min", math.min(4.0, wait * 0.4), "run", T(get(s, "run")),
                                       "pace", get(s, "pace"))
  end
  local show, phase, fork = "changelayers." .. si .. "_path", "spawn." .. si .. "_end", "addfact." .. si .. "_go"
  local action, track = "addfact.follow_" .. si, "script." .. si .. "_track"
  local blocks = M(
    show, M("world", world, "show", L(layer), "next", L(fork)),
    fork, M("value", L(ctx.qid .. "_" .. si .. "_go", 1), "next", L(action, track)),
    action, M("value", L(ctx.qid .. "_follow_" .. si, 1), "next", L("waituntil.forever")),
    track, M("function", "CjFollowTrack", "parameter", L(
      M("tag", "cname_" .. tag), M("path", text), M("progress", progress), M("pin", "cname_" .. pin)), "next", L(phase)),
    phase, M("spawnsets", L(comm), "phase", names[#names][1]))
  if alone and not T(get(s, "wait")) then
    local on = "addfact." .. si .. "_on"
    local nx = blocks[fork].next
    nx[#nx + 1] = on
    blocks[on] = M("value", L(ctx.qid .. "_" .. si .. "_on", 1))
    blocks[phase].next = L("waituntil.forever")
    return blocks, show, on
  end
  return blocks, show, phase
end
GEN.add_block(Follow)

-- ===================================================================================================================
local Race = {name = "race", PACE = {easy = "MT_FastRun", normal = "MT_Sprint", hard = "MT_Sprint"}}  -- (q201's Becca sprints)
function Race:generate(ctx, i, s)
  local si = sfx(i)
  local path = pts3(get(s, "path"))
  if #path < 2 then fail("step " .. S(i) .. ": race - the course needs a start and a goal (+ point on the card)") end
  local racers = {}
  for _, r in ipairs(P.list(get(s, "racers"))) do if T(r) then racers[#racers + 1] = r end end
  if #racers == 0 then fail("step " .. S(i) .. ": race - against whom? (+ who on the card)") end
  local world = ctx:place_world((partition(racers[1], "/")))
  local radius = F(get(s, "radius", 6))
  local meta = M(world, M("areas", Y.map(), "mappins", Y.map()))
  local areas = {}
  for k0, p in ipairs(path) do
    local area = ctx.qid .. "_" .. si .. "_cp" .. (k0 - 1)
    meta[world].areas[area] = GEN.area(floats3(p), radius)
    areas[#areas + 1] = world .. "/" .. area
  end
  -- on the map: the goal (as q201 pins the top of the mountain; the course itself is drawn when it starts)
  local goal_pin = ctx.qid .. "_" .. si .. "_goal"
  meta[world].mappins[goal_pin] = round3(path[#path])
  -- checkpoints: the points between start and goal, to be passed in order (as the game's horse races) - each on the
  -- map too (k: Python's index, 1 .. #path - 2)
  local gates = {}
  if T(get(s, "checkpoints")) then for k = 1, #path - 2 do gates[#gates + 1] = k end end
  local gate_pins = Y.list({})
  for _, k in ipairs(gates) do
    local gp = ctx.qid .. "_" .. si .. "_gate" .. k
    meta[world].mappins[gp] = round3(path[k + 1])
    gate_pins[#gate_pins + 1] = L(gp, radius)
  end
  -- the course: a path entity of the quest (as Follow's, pathfollow.patch_paths puts the curve in)
  local ent, path_tag, layer = "cj_race_" .. si, ctx.qid .. "_" .. si .. "_race", ctx.qid .. "_" .. si .. "_race"
  local origin = floats3(path[1])
  ctx.own_entities[ent] = M("entityObject", M(".type", "CEntity", "components", M("path", M(".type", "CPathComponent"))))
  ctx.layers[layer] = M("world", world, "statics", M("path", M(
    "template", table.concat({"dlc", "dlc" .. ctx.qid, "data", "entities", ent .. ".w2ent"}, "\\"), "pos", origin,
    "rot", L(0.0, 0.0, 0.0), "tags", L(path_tag))))
  local pts = Y.list({})
  for _, p in ipairs(path) do
    pts[#pts + 1] = L(R(F(p[1]) - origin[1], 3), R(F(p[2]) - origin[2], 3), R(F(p[3]) - origin[3], 3))
  end
  ctx.minigames["path_" .. si] = M("game", "path", "entity", ent, "points", pts)
  local show, count, go = "changelayers." .. si .. "_course", "script." .. si .. "_count", "addfact." .. si .. "_go"
  local dark, light, settle = "script." .. si .. "_dark", "script." .. si .. "_light", "waituntil." .. si .. "_dark"
  local decide, over = "waituntil." .. si .. "_finish", "waituntil." .. si .. "_over"
  -- the course (its path, its flags) shown, then everyone to the line behind a short fade (q201: a fade, the start
  -- scene puts Geralt at the line)
  local objective_ref = ctx.qid .. "/main/" .. si
  local pin_of = {}
  for _, g in ipairs(gate_pins) do pin_of[#pin_of + 1] = g[1] end
  pin_of[#pin_of + 1] = goal_pin
  local blocks = Y.map()
  -- the switches that put pin k of the objective on the map and the one before it off (the next checkpoint, last
  -- the goal - as q304's horse race: two switches, the new pin's, then the passed one's); k counts from 0
  local function pin_on(k)
    local b_ = "addfact." .. si .. "_pin" .. k
    blocks[b_] = M("value", L(ctx.qid .. "_" .. si .. "_pin" .. k, 1), "mappin", pin_of[k + 1], "objective", objective_ref)
    if k > 0 then
      local off_ = "addfact." .. si .. "_pin" .. k .. "_off"
      blocks[b_].next = L(M(off_, "Disable"))
      blocks[off_] = M("value", L(ctx.qid .. "_" .. si .. "_pin" .. k .. "_off", 1), "mappin", pin_of[k],
                       "objective", objective_ref)
      return b_, off_
    end
    return b_, b_
  end
  local first_pin = nil
  if #gate_pins > 0 then
    first_pin = (pin_on(0))
    -- (off when the objective starts: the switches show them)
    local all = Y.list({})
    for _, x in ipairs(pin_of) do all[#all + 1] = x end
    ctx.minigames["pins_" .. si] = M("game", "pins_off", "pins", all)
  end
  blocks[show] = M("world", world, "show", L(layer), "next", L(first_pin or dark))
  blocks[dark] = M("function", "CjFadeColor", "parameter", L(M("fadeOut", true), M("seconds", 0.4), M("white", false)),
                   "next", L(settle))
  blocks[settle] = M("elapsed", "00:00:01")
  if first_pin then blocks[first_pin].next = L(dark) end
  -- the racers at the start, beside each other (across the course's first stretch)
  local dx, dy = path[2][1] - path[1][1], path[2][2] - path[1][2]
  local n = N.hypot(dx, dy)
  if n == 0 then n = 1.0 end
  local side = {-dy / n * 1.5, dx / n * 1.5}
  local yaw = GEN.heading(path[1], path[2])
  -- the player to the line first: a racer comes into the world only once the player is near
  local me = "script." .. si .. "_player"
  blocks[me] = M("function", "CjTeleport", "parameter", L(
    M("x", F(path[1][1])), M("y", F(path[1][2])), M("z", F(path[1][3])), M("yaw", F(yaw))))
  blocks[settle].next = L(me)
  local before = me
  local tags = {}
  for k, r in ipairs(racers) do
    local tag = ctx:object_tag(r)
    tags[#tags + 1] = tag
    local put = "script." .. si .. "_put" .. k
    blocks[put] = M("function", "CjPutAt", "parameter", L(
      M("tag", "cname_" .. tag), M("x", F(path[1][1] + side[1] * k)), M("y", F(path[1][2] + side[2] * k)),
      M("z", F(path[1][3])), M("yaw", F(yaw))))
    blocks[before].next = L(put)
    before = put
  end
  -- the player at the start too and held there while the game counts down (as q201's race against Becca)
  local hold, free = "script." .. si .. "_hold", "script." .. si .. "_free"
  for _, hl in ipairs({{hold, true}, {free, false}}) do
    local out = GEN.BLOCKS.game:generate(ctx, i, M("function", "BlockGameplayFunctionality", "args", M(
      "lock", hl[2], "sourceName", ctx.qid .. "_race_" .. si, "movement", true, "jump", true, "runAndSprint", true,
      "sprint", true, "drawWeapon", true, "signs", true)))
    blocks[hl[1]] = with(out.blocks[out.first])
  end
  blocks[before].next = L(light)
  blocks[light] = M("function", "CjFadeColor", "parameter", L(M("fadeOut", false), M("seconds", 0.6), M("white", false)),
                    "next", L(hold))
  blocks[hold].next = L(count)
  blocks[count] = M("function", "DisplayRaceStart", "parameter", L(M("countDownSecondsNumber", 3)), "next", L(free))
  blocks[free].next = L(go)
  local runs = {}
  for k, tag in ipairs(tags) do                 -- (stand-ins: minigames.apply makes them the race AI)
    local name = "race_" .. si .. "_" .. k
    ctx.minigames[name] = M("game", "race", "npc", tag, "path", path_tag,
                            "pace", Race.PACE[S(P.or_(get(s, "pace"), "normal"))] or "MT_FastRun")
    blocks["addfact." .. name] = M("value", L(ctx.qid .. "_" .. name, 1), "next", L("waituntil.forever"))
    runs[#runs + 1] = "addfact." .. name
  end
  -- the course on the map while it runs (q201: EnableMapPath of the race's path, off when it is decided)
  local draw, undraw = "script." .. si .. "_map_on", "script." .. si .. "_map_off"
  blocks[draw] = M("function", "CjMapPath", "parameter", L(M("tag", "cname_" .. path_tag), M("on", true)))
  blocks[undraw] = M("function", "CjMapPath", "parameter", L(M("tag", "cname_" .. path_tag), M("on", false)))
  -- first inside the goal: the player wins, a racer before him and he has lost
  local lost = Y.list({})
  for _, t in ipairs(tags) do lost[#lost + 1] = M("inside", areas[#areas], "who", t) end
  local first = extend(Y.list({}), runs)
  first[#first + 1] = decide
  first[#first + 1] = draw
  first[#first + 1] = over
  local won_if = M("inside", areas[#areas])
  if #gates > 0 then
    -- the checkpoints in order; the goal counts once the last one is passed
    local won_fact, prev = ctx.qid .. "_" .. si .. "_gates", nil
    for n_, k in ipairs(gates) do
      local w = "waituntil." .. si .. "_gate" .. k
      local say, said = pin_on(n_)               -- passed: the next checkpoint's pin (the last: the goal's)
      blocks[w] = M("entered", areas[k + 1], "next", L(say))
      if prev == nil then first[#first + 1] = w else blocks[prev].next = L(w) end
      prev = said
    end
    local done_ = "addfact." .. si .. "_gates"
    blocks[prev].next = L(done_)
    blocks[done_] = M("value", L(won_fact, 1))
    won_if = M("all", L(M("inside", areas[#areas]), M("factdb", L(won_fact, ">=", 1))))
  end
  blocks[decide] = M("conditions", M("won", won_if, "lost", #lost == 1 and lost[1] or M("any", lost)))
  local any = Y.list({won_if})
  for _, x in ipairs(lost) do any[#any + 1] = x end
  blocks[over] = M("any", any, "next", L(undraw))
  blocks[go] = M("value", L(ctx.qid .. "_" .. si .. "_go", 1), "next", first)
  local pins = Y.list({})
  for _, g in ipairs(gate_pins) do pins[#pins + 1] = g end
  pins[#pins + 1] = L(goal_pin, radius)
  return StepOut(blocks, show, decide, M("caption", get(s, "text", "Win the race"), "mappins", pins, "world", world),
                 meta, nil, M("won", "continue", "lost", "fail"))
end
GEN.add_block(Race)

-- ===================================================================================================================
local Patrol = {name = "patrol"}
function Patrol:generate(ctx, i, s)
  local si = sfx(i)
  local path = pts3(get(s, "path"))
  if #path == 0 then fail("step " .. S(i) .. ": patrol - the way has no points (+ point on the card)") end
  local fork, walk, on = "addfact." .. si .. "_patrol", "script." .. si .. "_patrol", "addfact." .. si .. "_patrol_on"
  local phases = ctx.walk_phases[s]
  local blocks
  if phases then
    local loop, last
    loop, walk, last = GEN.walk_chain(ctx, i, s.who, phases, 0.0, "")
    loop[last].next = L("spawn." .. si .. "_p1")
    blocks = with(loop)
  else
    blocks = M(walk, M("function", "CjPatrol", "parameter", L(M("tag", GEN.tag(ctx, s, "who")), M("path", path_text(path)),
                                                               M("run", T(get(s, "run"))))))
  end
  blocks[fork] = M("value", L(ctx.qid .. "_" .. si .. "_patrol", 1), "next", L(walk, on))
  blocks[on] = M("value", L(ctx.qid .. "_" .. si .. "_patrol_on", 1))
  return StepOut(blocks, fork, on, nil)
end
GEN.add_block(Patrol)

-- ===================================================================================================================
local Defeat = {name = "defeat"}
function Defeat:generate(ctx, i, s)
  local si = sfx(i)
  if not T(get(s, "target")) then fail("step " .. S(i) .. ": defeat - who? (Pick, Search or Create on the card)") end
  local tag = "cname_" .. ctx:object_tag(s.target)
  local b = {"script." .. si .. "_immortal", "script." .. si .. "_fight", "script." .. si .. "_yield",
             "script." .. si .. "_peace"}
  local blocks = M(
    b[1], M("function", "CjImmortal", "parameter", L(M("tag", tag), M("mode", "immortal")), "next", L(b[2])),
    b[2], M("function", "CjHostileQ", "parameter", L(M("qid", ctx.qid), M("tag", tag), M("hostile", true)), "next", L(b[3])),
    b[3], M("function", "CjWaitDefeated", "parameter", L(M("tag", tag), M("percent", I(get(s, "below", 20)))),
            "next", L(b[4])),
    b[4], M("function", "CjHostileQ", "parameter", L(M("qid", ctx.qid), M("tag", tag), M("hostile", false))))
  local meta, where = GEN.pin(ctx, i, {s.target}, 8.0)
  return StepOut(blocks, b[1], b[4], merged(M("caption", get(s, "text", "Defeat him")), where), meta)
end
GEN.add_block(Defeat)

local Read = {name = "read"}
function Read:generate(ctx, i, s)
  if not T(get(s, "item")) then fail("step " .. S(i) .. ": read - which letter or book?") end
  local b = "script." .. sfx(i) .. "_read"
  return StepOut(M(b, item_call(ctx, "CjWaitRead", s.item)), b, b, M("caption", get(s, "text", "Read " .. S(s.item))))
end
GEN.add_block(Read)

local WaitFor = {name = "waitfor", WHAT = {combat = 1, peace = 2, senses = 3, health = 4},
                 CAPTION = {combat = "Fight", peace = "Win the fight", senses = "Use your witcher senses",
                            health = "Survive"}}
function WaitFor:generate(ctx, i, s)
  local what = P.or_(get(s, "what"), "senses")
  if not WaitFor.WHAT[what] then fail("step " .. S(i) .. ": wait for - what? (combat, peace, senses, health)") end
  local b = "script." .. sfx(i) .. "_waitfor"
  return StepOut(M(b, M("function", "CjWaitGame", "parameter", L(M("what", WaitFor.WHAT[what]),
                                                                 M("percent", I(get(s, "percent", 30)))))),
                 b, b, M("caption", P.or_(get(s, "text"), WaitFor.CAPTION[what])))
end
GEN.add_block(WaitFor)

-- ===================================================================================================================
local Kill = {name = "kill"}
function Kill:generate(ctx, i, s)
  local refs = {}
  for _, r in ipairs(P.list(get(s, "targets"))) do if T(r) then refs[#refs + 1] = r end end
  if #refs == 0 and T(get(s, "target")) then refs = {s.target} end
  if #refs == 0 then fail("step " .. S(i) .. ": kill - who? (Pick, Search or Create on the card)") end
  local out = Kill.kill(ctx, i, s, refs)
  local sets, seen = {}, {}
  for _, r in ipairs(refs) do
    local c = ctx.foes[r]
    if c and not seen[c] then seen[c] = true sets[#sets + 1] = c end
  end
  table.sort(sets)
  if #sets > 0 then                              -- they come now (not with the quest's start)
    local sp = "spawn." .. sfx(i) .. "_foes"
    out.blocks[sp] = M("phase", "main", "spawnsets", Y.list(sets), "next", L(out.first))
    out.fork, out.first = out.first, sp
  end
  return out
end
function Kill.kill(ctx, i, s, refs)
  local si = sfx(i)
  local wait = "waituntil." .. si
  local meta, where = GEN.pin(ctx, i, refs, 8.0)
  if #refs == 1 then
    return StepOut(M(wait, M("factdb", L("actor_" .. ctx:object_tag(refs[1]) .. "_was_killed", ">=", 1))), wait, wait,
                   merged(M("caption", get(s, "text", "Kill them")), where), meta)
  end
  local dead, fork = ctx.qid .. "_" .. si .. "_dead", "addfact." .. si .. "_kill"
  local blocks, waits = Y.map(), Y.list({})
  for k, r in ipairs(refs) do
    local w, a = "waituntil." .. si .. "_k" .. k, "addfact." .. si .. "_k" .. k
    blocks[w] = M("factdb", L("actor_" .. ctx:object_tag(r) .. "_was_killed", ">=", 1), "next", L(a))
    blocks[a] = M("value", L(dead, 1))
    waits[#waits + 1] = w
  end
  blocks[wait] = M("factdb", L(dead, ">=", #refs))
  waits[#waits + 1] = wait
  blocks[fork] = M("value", L(ctx.qid .. "_" .. si .. "_kill", 1), "next", waits)
  return StepOut(blocks, fork, wait, merged(M("caption", get(s, "text", "Kill them")), where), meta, nil, nil,
                 {dead, #refs})
end
GEN.add_block(Kill)

-- ===================================================================================================================
local function Collector(name, fn)
  local self = {name = name, ["function"] = fn}
  function self:generate(ctx, i, s)
    local si = sfx(i)
    local items = GEN.step_items(s)
    if #items == 0 then fail("step " .. S(i) .. ": " .. self.name .. " - which item? (pick one on the step's card)") end
    local blocks = Y.map()
    for k0, it in ipairs(items) do
      local k = k0 - 1
      local x = k == 0 and "" or ("_" .. (k + 1))
      local fact = ctx.qid .. "_" .. si .. "_have" .. x
      local check, wait, pause = "script." .. si .. "_check" .. x, "waituntil." .. si .. x, "waituntil." .. si .. "_later" .. x
      local call
      if T(get(s, "keep_in")) then
        call = item_call(ctx, "CjHasItemsFrom", it.item, {"count", it.count, "fact", fact,
                                                           "tag", "cname_" .. ctx:object_tag(s.keep_in)})
      else
        call = item_call(ctx, self["function"], it.item, {"count", it.count, "fact", fact})
      end
      blocks[check] = with(call, "next", L(wait))
      blocks[wait] = M("conditions", M("have", M("factdb", L(fact, "=", 1)), "notyet", M("factdb", L(fact, "=", 0))),
                       "next.notyet", L(pause))
      blocks[pause] = M("elapsed", "00:02:00", "next", L(check))
      if k + 1 < #items then blocks[wait]["next.have"] = L("script." .. si .. "_check_" .. (k + 2)) end
    end
    local first = "script." .. si .. "_check"
    local last = #items > 1 and ("waituntil." .. si .. "_" .. #items) or ("waituntil." .. si)
    local caption
    if self.name ~= "collect" then caption = GEN.caption(ctx, self.name, s)
    elseif #items == 1 then caption = "Get " .. S(get(s, "count", 1)) .. " " .. S(need(s, "item"))
    else caption = "Get " .. #items .. " items" end
    local objective, meta = M("caption", get(s, "text", caption)), nil
    if T(get(s, "in")) and (get(s, "from") == "container" or get(s, "from") == "person") then
      local where
      meta, where = GEN.pin(ctx, i, {s["in"]})
      add_all(objective, where)
    end
    return StepOut(blocks, first, last, objective, meta, nil, M("have", "continue"))
  end
  return self
end
GEN.add_block(Collector("collect", "CjHasItems"))
GEN.add_block(Collector("equip", "CjEquipped"))

local Note = {name = "note"}
function Note:generate(ctx, i, s)
  local did = sfx(i)
  ctx.descriptions[#ctx.descriptions + 1] = M(did, need(s, "text"))
  local block = "journal." .. did
  return StepOut(M(block, M("entry", "quests/" .. GEN.journal_of(ctx, i) .. "/" .. did)), block, block, nil)
end
GEN.add_block(Note)

-- the journal entry of the quest step i belongs to (a project's quest k: its own)
function GEN.journal_of(ctx, i)
  local QS = require("conjunction.quests")
  return QS.journal_key(ctx.qid, QS.part_of(I(i)))
end

-- the paragraphs of the project's quest k (by their steps' numbers)
function GEN.descriptions_of(ctx, k)
  local QS = require("conjunction.quests")
  local out = Y.list({})
  for _, d in ipairs(ctx.descriptions) do
    if QS.part_of(I(Y.keys(d)[1]:sub(2))) == k then out[#out + 1] = d end
  end
  return out
end

local Wait = {name = "wait"}
function Wait:generate(ctx, i, s)
  local si = sfx(i)
  local objective = T(get(s, "text")) and M("caption", s.text) or nil
  if T(get(s, "until")) then
    local parts = {}
    for v in (S(s["until"]) .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = v end
    local h, m = I(parts[1]), I(parts[2])
    local b = "script." .. si .. "_until"
    return StepOut(M(b, M("function", "CjWaitHour", "parameter", L(M("hour", h), M("minute", m)))), b, b, objective)
  end
  local wait = "waituntil." .. si
  return StepOut(M(wait, M("elapsed", S(get(s, "time", "00:00:10")))), wait, wait, objective)
end
GEN.add_block(Wait)

local Travel = {name = "travel"}
function Travel:generate(ctx, i, s)
  local si = sfx(i)
  if not T(get(s, "pos")) then fail("step " .. S(i) .. ": travel - where to? (a point clicked in the world)") end
  local world = get(s, "world")
  if not T(world) then world = T(get(s, "place")) and ctx:place_world(s.place) or nil end
  if not T(world) then fail("step " .. S(i) .. ": travel - the point's world is unknown; pick it again") end
  local wp = si .. "_travel"
  local b = "changeworld." .. si
  return StepOut(M(b, M("destination", world .. "/" .. wp)), b, b, nil,
                 M(world, M("waypoints", M(wp, M("pos", floats3(s.pos), "rot", L(0.0, 0.0, F(get(s, "yaw", 0.0))))))))
end
GEN.add_block(Travel)

local Chapter = {name = "chapter"}
function Chapter:generate(ctx, i, s)
  local j = Y.is_map(get(s, "journal")) and s.journal or Y.map()
  local text = PYS.strip(S(P.or_(get(j, "text"), "")))
  if text == "" then return StepOut(Y.map(), nil, nil) end
  local did = sfx(i)
  ctx.descriptions[#ctx.descriptions + 1] = M(did, text)
  local block = "journal." .. did
  local blocks = M(block, M("entry", "quests/" .. GEN.journal_of(ctx, i) .. "/" .. did))
  if get(j, "mode") ~= "replace" then return StepOut(blocks, block, block, nil) end
  -- in place of the paragraphs before it: kept so beside the story while it has the say (CjJournalOnly - the game
  -- turned hidden paragraphs on again)
  local only = "script." .. did .. "_only"
  blocks[only] = M("function", "CjJournalOnly", "parameter", L(M("journalQuest", ctx.qid .. "_" .. GEN.journal_of(ctx, i)),
                                                               M("keep", did), M("step", I(i))))
  return StepOut(blocks, block, block, nil, nil, nil, M("__side", only))
end
GEN.add_block(Chapter)

local Random = {name = "random"}
function Random:generate(ctx, i, s)
  local ways = P.list(get(s, "ways"))
  if #ways < 2 then fail("step " .. S(i) .. ": at random - two ways at least") end
  if not ctx.graph then
    local any = false
    for _, w in ipairs(ways) do if T(get(w, "path")) then any = true end end
    if not any then fail("step " .. S(i) .. ": at random - every way goes on; give one a path") end
  end
  local b = "randomize." .. sfx(i)
  local branches = Y.map()
  for k, w in ipairs(ways) do branches["way" .. k] = T(get(w, "path")) and ("path:" .. S(w.path)) or "continue" end
  return StepOut(M(b, Y.map()), b, b, nil, nil, nil, branches)
end
GEN.add_block(Random)

GEN.DECKS = {"Baron", "BoatBuilder", "CardProdigy", "CircusGwentAddict", "Crach", "CrossroadsInnkeeper", "Dijkstra",
             "Gambler", "Gremista", "Halflings", "Hermit", "Lambert", "LugosTheMad", "MarkizaSerenity", "Mousesack",
             "NKEasy", "NKNormal", "NKHard", "NKTournament", "NMLEasy", "NMLNormal", "NMLHard", "NMLTournament",
             "NMLTournament2", "NilfEasy", "NilfNormal", "NilfHard", "NilfPrologue", "NilfTournament", "NilfTournament2",
             "Olgierd", "Olivier", "Roche", "ScoiaEasy", "ScoiaNormal", "ScoiaHard", "ScoiaTournament",
             "ScoiaTournament2", "ScoiaTrader", "Shani", "Sjusta", "SkelEasy", "SkelNormal", "SkelHard", "SkelTournament2",
             "Stjepan", "Thaler", "VimmeVivaldi", "Zoltan"}
local Gwent = {name = "gwent"}
function Gwent:generate(ctx, i, s)
  local known = false
  for _, d in ipairs(GEN.DECKS) do if d == get(s, "deck") then known = true end end
  if not known then fail("step " .. S(i) .. ": gwent - against which deck?") end
  local b = "randomize.gwent_" .. sfx(i)
  ctx.minigames["gwent_" .. sfx(i)] = M("deck", s.deck, "difficulty", get(s, "difficulty", "medium"))
  local lost = P.or_(get(s, "lost"), "continue")
  return StepOut(M(b, Y.map()), b, b, M("caption", P.or_(get(s, "text"), "Win a game of gwent")), nil, nil,
                 M("Success", "continue", "Failure", lost))
end
GEN.add_block(Gwent)

local Fistfight = {name = "fistfight"}
function Fistfight:generate(ctx, i, s)
  local si = sfx(i)
  local refs = {}
  for _, t in ipairs(P.list(get(s, "targets"))) do if T(t) then refs[#refs + 1] = t end end
  if #refs == 0 then fail("step " .. S(i) .. ": fist fight - with whom?") end
  local objs = {}
  for _, r in ipairs(refs) do objs[#objs + 1] = ctx:object(r) end
  for _, o in ipairs(objs) do
    if not Q.is_actor(o) then fail("step " .. S(i) .. ": fist fight - only people can fight with fists") end
  end
  local world = ctx:place_world((partition(refs[1], "/")))
  local spots = {}
  for k, r in ipairs(refs) do spots[k] = ctx.moved[r] and ctx.moved[r][1] or objs[k].pos end
  local center = Y.list({})
  for k = 1, 3 do
    local sum = 0.0
    for _, p in ipairs(spots) do sum = sum + F(p[k]) end
    center[k] = sum / #spots
  end
  local area = ctx.qid .. "_" .. si .. "_ring"
  local b = "randomize.fistfight_" .. si
  local enemies = Y.list({})
  for _, r in ipairs(refs) do enemies[#enemies + 1] = ctx:object_tag(r) end
  ctx.minigames["fistfight_" .. si] = M("game", "fistfight", "area", ctx.qid .. "_" .. world .. "_" .. area .. "_ar",
                                        "enemies", enemies)
  return StepOut(M(b, Y.map()), b, b, M("caption", P.or_(get(s, "text"), "Win the fist fight")),
                 M(world, M("areas", M(area, GEN.area(center, F(get(s, "radius", 10)))))), nil,
                 M("Success", "continue", "Failure", P.or_(get(s, "lost"), "continue")))
end
GEN.add_block(Fistfight)

local StopLane = {name = "stop"}
function StopLane:generate(ctx, i, s)
  if not T(get(s, "path")) then fail("step " .. S(i) .. ": stop lane - which lane?") end
  local b = "addfact.cut_" .. sfx(i)
  ctx.minigames["cut_" .. sfx(i)] = M("game", "cut", "lane", s.path)
  return StepOut(M(b, M("value", L(ctx.qid .. "_cut_" .. sfx(i), 1))), b, b, nil)
end
GEN.add_block(StopLane)

local Meanwhile = {name = "meanwhile"}
function Meanwhile:generate(ctx, i, s)
  if not T(get(s, "path")) then fail("step " .. S(i) .. ": meanwhile - which lane? (a path)") end
  local b = "addfact." .. sfx(i) .. "_meanwhile"
  return StepOut(M(b, M("value", L(ctx.qid .. "_" .. sfx(i) .. "_lane", 1))), b, b, nil, nil, nil, M("__lane", s.path))
end
GEN.add_block(Meanwhile)

local Stands = {name = "stands"}
function Stands:generate(ctx, i, s)
  local cp = ctx.stand_phases[s]
  if not cp then fail("step " .. S(i) .. ": stands - who, and where? (a person, a point in the world)") end
  if T(get(s, "pos")) then ctx.moved[s.who] = {s.pos, F(get(s, "yaw", 0.0))} end
  local b = "spawn." .. sfx(i) .. "_stands"
  return StepOut(M(b, M("spawnsets", L(cp[1]), "phase", cp[2])), b, b, nil)
end
GEN.add_block(Stands)

GEN.DEFAULT_TEXT_NOTICE = "Check the notice board"
local Notice = {name = "notice"}
function Notice:generate(ctx, i, s)
  local si = sfx(i)
  local board = S(P.or_(get(s, "board"), ""))
  if board == "" then fail("step " .. S(i) .. ": notice - on which notice board?") end
  local tag = P.startswith(board, "tag:") and board:sub(5) or ctx:object_tag(board)
  local key = S(P.or_(get(s, "key"), ""))
  if key == "" then
    key = PYS.lower(ctx.qid .. "_notice_" .. si)
    ctx:keyed_string(key, P.or_(get(s, "title"), "Notice"))
    ctx:keyed_string(key .. "_text", P.or_(get(s, "body"), ""))
  end
  local fact = ctx.qid .. "_" .. si .. "_taken"
  local put, wait = "script." .. si .. "_notice", "waituntil." .. si .. "_taken"
  local params = L(M("board", "cname_" .. tag), M("key", key), M("fact", fact))
  local call = M("function", "CjNotice", "parameter", params)
  if T(get(s, "item")) then
    local item = GEN.own_item(ctx, s.item) or S(s.item)
    local more = Y.list({})
    extend(more, params)
    more[#more + 1] = M("item", "cname_" .. item)
    call = M("function", "CjNoticeN", "parameter", more)
  end
  local blocks = M(put, with(call, "next", L(wait)), wait, M("factdb", L(fact, ">=", 1)))
  local meta, objective = Y.map(), Y.map()
  if not P.startswith(board, "tag:") then meta, objective = GEN.pin(ctx, i, {board}) end
  objective.caption = P.or_(get(s, "text"), GEN.DEFAULT_TEXT_NOTICE)
  return StepOut(blocks, put, wait, objective, meta)
end
GEN.add_block(Notice)

local WaitFact = {name = "waitfact"}
function WaitFact:generate(ctx, i, s)
  local wait = "waituntil." .. sfx(i) .. "_fact"
  local objective = T(get(s, "text")) and M("caption", s.text) or nil
  if T(get(s, "conditions")) then
    local meta = Y.map()
    local yes = GEN.conditions(ctx, i, s, meta, {}, true)
    return StepOut(M(wait, with(yes)), wait, wait, objective, meta)
  end
  if not T(get(s, "fact")) then fail("step " .. S(i) .. ": wait until - which fact?") end
  return StepOut(M(wait, M("factdb", L(S(s.fact), ">=", I(get(s, "value", 1))))), wait, wait, objective)
end
GEN.add_block(WaitFact)

-- show / hide a place (a place that is not visible from the start comes with a step)
local function Layers(name)
  local self = {name = name}
  function self:generate(ctx, i, s)
    local place = need(s, "place")
    local block = "changelayers." .. sfx(i)
    return StepOut(M(block, M("world", ctx:place_world(place), self.name, L(place))), block, block, nil)
  end
  return self
end
GEN.add_block(Layers("show"))
GEN.add_block(Layers("hide"))

local Reward = {name = "reward"}
function Reward:generate(ctx, i, s)
  local si = sfx(i)
  local blocks, chain = Y.map(), {}
  local money, xp = I(get(s, "money", 0)), I(get(s, "xp", 0))
  if money ~= 0 or xp ~= 0 then
    local b = "script." .. si .. "_give"
    blocks[b] = M("function", "CjGive", "parameter", L(M("money", money), M("xp", xp)))
    chain[#chain + 1] = b
  end
  local items, game, own = {}, Y.list({}), {}
  for _, it in ipairs(P.list(get(s, "items"))) do if T(it) then items[#items + 1] = it end end
  for _, it in ipairs(items) do
    if P.startswith(S(it), "own:") then own[#own + 1] = it else game[#game + 1] = "~" .. S(it) end
  end
  if #game > 0 then
    local b = "reward." .. si .. "_items"
    blocks[b] = M("reward", ctx.qid .. "_" .. si)
    ctx.rewards[ctx.qid .. "_" .. si] = game
    chain[#chain + 1] = b
  end
  for k0, it in ipairs(own) do
    local b = "script." .. si .. "_own" .. (k0 - 1)
    blocks[b] = item_call(ctx, "CjPlayerItem", it, {"count", 1})
    chain[#chain + 1] = b
  end
  if #chain == 0 then fail("step " .. S(i) .. ": a reward needs money, xp or items") end
  for k = 1, #chain - 1 do blocks[chain[k]].next = L(chain[k + 1]) end
  return StepOut(blocks, chain[1], chain[#chain])
end
GEN.add_block(Reward)

local Lock = {name = "lock"}
function Lock:generate(ctx, i, s)
  local block = "script." .. sfx(i) .. "_lock"
  local lock = get(s, "state", "lock") == "lock"
  local key = lock and S(P.or_(get(s, "key"), "")) or ""
  local call
  local own = GEN.own_item(ctx, key)
  if own then
    call = M("function", "CjLockNQ", "parameter", L(M("qid", ctx.qid), M("tag", GEN.tag(ctx, s)), M("lock", lock),
                                                    M("keyName", "cname_" .. own), M("keyGoes", T(get(s, "key_goes")))))
  else
    call = M("function", "CjLockQ", "parameter", L(M("qid", ctx.qid), M("tag", GEN.tag(ctx, s)), M("lock", lock),
                                                   M("key", key), M("keyGoes", T(get(s, "key_goes")))))
  end
  -- beside the story: the call waits until the thing is in the world (CjWaitFor) - a chest far away is not until the
  -- player comes near, and the goal that sends him there came after it
  local fork = "addfact." .. sfx(i) .. "_lock"
  return StepOut(M(fork, M("value", L(ctx.qid .. "_" .. sfx(i) .. "_lock", 1)), block, call), fork, fork, nil, nil, nil,
                 M("__side", block))
end
GEN.add_block(Lock)

local Hostile = {name = "hostile"}
function Hostile:generate(ctx, i, s)
  local block = "script." .. sfx(i) .. "_hostile"
  return StepOut(M(block, M("function", "CjHostileQ", "parameter", L(M("qid", ctx.qid),
    M("tag", "cname_" .. ctx:object_tag(need(s, "target"))), M("hostile", not T(get(s, "friendly", false)))))),
    block, block, nil)
end
GEN.add_block(Hostile)

-- an action that calls one of the mod's quest functions: params(ctx, s) -> its parameter list
local function Call(name, fn, params)
  local self = {name = name, ["function"] = fn, params = params}
  function self:generate(ctx, i, s)
    local block = "script." .. sfx(i) .. "_" .. self.name
    local more = {}
    if T(get(s, "target")) then
      for _, t in ipairs(P.list(get(s, "more_targets"))) do if T(t) then more[#more + 1] = t end end
    end
    if #more == 0 then
      return StepOut(M(block, M("function", self["function"], "parameter", self.params(ctx, s))), block, block, nil)
    end
    local names = {block}
    for k = 1, #more do names[#names + 1] = block .. "_" .. k end
    local targets = {s.target}
    extend(targets, more)
    local blocks = Y.map()
    for k, name_ in ipairs(names) do
      blocks[name_] = M("function", self["function"], "parameter", self.params(ctx, with(s, "target", targets[k])))
      if k < #names then blocks[name_].next = L(names[k + 1]) end
    end
    return StepOut(blocks, names[1], names[#names], nil)
  end
  return self
end
local function at_parts(s)
  local at = S(get(s, "at", "12:00"))
  local parts = {}
  for v in (at .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = v end
  return parts
end
local CALLS = {
  Call("effect", "CjFx", function(ctx, s) return L(M("tag", GEN.tag(ctx, s)), M("effect", "cname_" .. S(get(s, "effect", ""))),
                                                    M("on", not T(get(s, "off", false)))) end),
  Call("sound", "CjSound", function(_ctx, s) return L(M("soundEvent", S(get(s, "event", "")))) end),
  Call("fade", "CjFadeColor", function(_ctx, s) return L(M("fadeOut", get(s, "to", "black") == "black"),
                                                         M("seconds", F(get(s, "seconds", 1.0))),
                                                         M("white", get(s, "color") == "white")) end),
  Call("lights", "CjLights", function(ctx, s) return L(M("tag", GEN.tag(ctx, s)), M("on", get(s, "state", "on") == "on"),
                                                       M("fade", T(get(s, "slow")))) end),
  Call("presence", "CjPresenceQ", function(ctx, s) return L(M("qid", ctx.qid), M("tag", GEN.tag(ctx, s)),
                                                            M("show", get(s, "state") == "show")) end),
  Call("shake", "CjShake", function(_ctx, s) return L(M("strength", F(get(s, "strength", 0.5)))) end),
  Call("weather", "CjWeather", function(_ctx, s) return L(M("weather", "cname_" .. PYS.lower(S(get(s, "weather", "WT_Clear")))),
                                                          M("blend", F(get(s, "seconds", 10.0)))) end),
  Call("time", "CjSetTime", function(_ctx, s) local p = at_parts(s) return L(M("hour", I(p[1])), M("minute", I(need(p, 2)))) end),
  Call("teleport", "CjTeleport", function(_ctx, s) local pos = need(s, "pos")
    return L(M("x", F(pos[1])), M("y", F(pos[2])), M("z", F(pos[3])), M("yaw", F(get(s, "yaw", 0.0)))) end),
  Call("message", "CjMessage", function(_ctx, s) return L(M("text", S(get(s, "text", "")))) end),
  Call("autosave", "CjAutosave", function() return Y.list({}) end),
  Call("door", "CjDoor", function(ctx, s) return L(M("tag", GEN.tag(ctx, s)), M("doorState", get(s, "state", "open")),
                                                   M("key", S(get(s, "key", "")))) end),
  Call("switch", "CjSwitch", function(ctx, s) return L(M("tag", GEN.tag(ctx, s)), M("how", get(s, "state", "on"))) end),
  Call("tutorial", "CjTutorial", function(_ctx, s) return L(M("title", S(get(s, "title", ""))), M("text", S(get(s, "text", ""))),
                                                            M("seconds", F(get(s, "seconds", 8)))) end),
  Call("immortal", "CjImmortal", function(ctx, s) return L(M("tag", GEN.tag(ctx, s)), M("mode", get(s, "mode", "immortal"))) end),
  -- (things of the world, as the game's quests switch them: FocusClueManager, EntityComponentQuest, ApplyAppearance)
  Call("clue", "CjFocusClue", function(ctx, s) return L(M("tag", GEN.tag(ctx, s)), M("on", get(s, "state", "on") == "on")) end),
  Call("part", "CjPart", function(ctx, s)
    if not T(get(s, "part")) then fail("part on/off - which part? (the card: which part)") end
    return L(M("tag", GEN.tag(ctx, s)), M("part", "cname_" .. S(s.part)), M("on", get(s, "state", "on") == "on"))
  end),
  Call("thinglook", "CjThingLook", function(ctx, s)
    if not T(get(s, "look")) then fail("look of a thing - which look? (the card: which look)") end
    return L(M("tag", GEN.tag(ctx, s)), M("look", "cname_" .. S(s.look)))
  end),
  Call("thinganim", "CjThingAnim", function(ctx, s)
    if not T(get(s, "anim")) then fail("move a thing - which move? (the card: which move)") end
    local how = ({once = 0, back = 1, loop = 2, stop = 3})[S(get(s, "how", "once"))] or 0
    return L(M("tag", GEN.tag(ctx, s)), M("anim", "cname_" .. S(s.anim)), M("how", how))
  end),
}

-- ===================================================================================================================
local Walk = {name = "walk"}
function Walk:generate(ctx, i, s)
  local si = sfx(i)
  local phases = ctx.walk_phases[s]
  if not phases then
    local block = "script." .. si .. "_walk"
    local params = L(M("tag", GEN.tag(ctx, s, "who")))
    extend(params, GEN.point(s))
    params[#params + 1] = M("run", T(get(s, "run")))
    params[#params + 1] = M("waitThere", T(get(s, "wait")))
    local call = M("function", "CjWalkTo", "parameter", params)
    if T(get(s, "wait")) then return StepOut(M(block, call), block, block, nil) end
    -- not waited for: beside the story (CjWalkTo waits until the person is in the world)
    local fork = "addfact." .. si .. "_walk"
    return StepOut(M(fork, M("value", L(ctx.qid .. "_" .. si .. "_walk", 1)), block, call), fork, fork, nil, nil, nil,
                   M("__side", block))
  end
  local start = (ctx.moved[s.who] or {ctx:object(s.who).pos})[1]
  if T(get(s, "pos")) then ctx.moved[s.who] = {s.pos, GEN.heading(ctx:object(s.who).pos, s.pos)} end
  local comm, names, stuck = phases[1], phases[2], phases[3]
  if not stuck and T(get(s, "pos")) then
    -- the game's way (pathfollow.walk_block): from where he stands along the way, alone; his phase at the end
    local path = {start}
    for _, p in ipairs(pts3(get(s, "path"))) do path[#path + 1] = p end
    path[#path + 1] = s.pos
    local world = ctx:place_world((partition(s.who, "/")))
    local blocks, first, last = Follow.along_path(ctx, i, s, phases, path, world, ctx.qid .. "_" .. si .. "_at",
                                                  "cj_nopin", path_text(path), true)
    return StepOut(blocks, first, last, nil)
  end
  if not T(get(s, "wait")) and not stuck then
    local b = "spawn." .. si .. "_p1"
    return StepOut(M(b, M("spawnsets", L(comm), "phase", names[1][1])), b, b, nil)
  end
  local blocks, first, last = GEN.walk_chain(ctx, i, s.who, phases, 0.0, "")
  return StepOut(blocks, first, last, nil)
end
GEN.add_block(Walk)

-- any of the game's quest functions (game_functions.py)
local GameAction = {name = "game"}
function GameAction:generate(ctx, i, s)
  local G = require("conjunction.game_functions")
  local fn = get(s, "function")
  if not T(fn) then fail("step " .. S(i) .. ": game action - which one?") end
  local info = G.functions()[fn]
  if not info or not G.usable(fn) then fail("step " .. S(i) .. ": the game has no quest function " .. S(fn) .. " conjunction can call") end
  local args, params = P.or_(get(s, "args"), Y.map()), Y.list({})
  for _, p in ipairs(info.params) do
    local n, t, optional = p[1], p[2], p[3]
    local v = get(args, n)
    local skip = false
    if v == nil or v == "" then
      if T(optional) then skip = true
      else
        if G.kind(t) == "name" or G.kind(t) == "string" then fail("step " .. S(i) .. ": " .. G.label(fn) .. " needs " .. n) end
        v = G.default(t)
      end
    end
    if not skip then
      local k = G.kind(t)
      if k == "name" and S(v):find("/", 1, true) then
        params[#params + 1] = M(n, "cname_" .. ctx:object_tag(v))
      elseif k == "enum" then
        local values = G.enums()[t] or {}
        local ok = false
        for _, e in ipairs(values) do if e == v then ok = true end end
        if not ok then
          local some = {}
          for x = 1, math.min(6, #values) do some[x] = values[x] end
          fail("step " .. S(i) .. ": " .. G.label(fn) .. ": " .. n .. " cannot be " .. S(v) .. " (one of " ..
               table.concat(some, ", ") .. " ...)")
        end
        params[#params + 1] = M(n, "cname_" .. S(v))
      else
        params[#params + 1] = M(n, G.radish_value(t, v))
      end
    end
  end
  local block = "script." .. sfx(i) .. "_game"
  return StepOut(M(block, M("function", G.called(fn), "parameter", params)), block, block, nil)
end
GEN.add_block(GameAction)

local Item = {name = "item"}
function Item:generate(ctx, i, s)
  if not T(get(s, "item")) then fail("step " .. S(i) .. ": item - which?") end
  local block = "script." .. sfx(i) .. "_item"
  return StepOut(M(block, item_call(ctx, "CjPlayerItem", s.item, {"count", I(get(s, "count", 1)) * (T(get(s, "take")) and -1 or 1)})),
                 block, block, nil)
end
GEN.add_block(Item)

local Say = {name = "say"}
function Say:generate(ctx, i, s)
  local si = sfx(i)
  if T(get(s, "who")) then return Say.person(ctx, i, s) end
  if not (T(get(s, "text")) or T(get(s, "voice")) or T(get(s, "voice_pack"))) then
    fail("step " .. S(i) .. ": the player says - what?")
  end
  local place
  for _, n in ipairs(Y.keys(ctx.project.places)) do
    local p = ctx.project.places[n]
    if T(get(p, "world")) and T(get(p, "objects")) then place = n break end
  end
  if place == nil then fail("step " .. S(i) .. ": the player says - place something first (the line needs a world)") end
  local world = ctx:place_world(place)
  local c = ctx:place_center(place)
  local name = ctx.qid .. "_" .. si .. "_say"
  local sp = name .. "_sp"
  local sc = Talk.scene(ctx, 800 + I(i), name, L(with(s, "who", "player")), nil, nil, name .. "_f",
                        {gameplay = true, character = ctx:character(s)})
  setdefault(setdefault(ctx.extra_meta, world, Y.map()), "scenepoints", Y.map())[sp] = L(c[1], c[2], c[3], 0.0)
  local block = "scene." .. si .. "_say"
  return StepOut(M(block, M("scene", scene_path(ctx, name), "placement", world .. "/" .. sp)), block, block, nil, nil,
                 M(name, sc))
end
-- a placed person says it (or only moves: a gesture without text) where they stand
function Say.person(ctx, i, s)
  local si = sfx(i)
  if not (T(get(s, "text")) or T(get(s, "voice")) or T(get(s, "voice_pack")) or T(get(s, "gesture"))) then
    fail("step " .. S(i) .. ": says - what? (a line or a gesture)")
  end
  local o = ctx:object(s.who)
  local world = ctx:place_world((partition(s.who, "/")))
  local x, y, z = o.pos[1], o.pos[2], o.pos[3]
  local name = ctx.qid .. "_" .. si .. "_says"
  local sp = name .. "_sp"
  local line = Y.map()
  for k, v in pairs(s) do if k ~= "who" then line[k] = v end end
  line.who = "npc"
  setdefault(line, "text", "...")
  local sc = Talk.scene(ctx, 850 + I(i), name, L(line), o, ctx:object_tag(s.who), name .. "_f",
                        {gameplay = true, character = ctx:character(s)})
  setdefault(setdefault(ctx.extra_meta, world, Y.map()), "scenepoints", Y.map())[sp] = L(x, y, z, 0.0)
  local block = "scene." .. si .. "_says"
  return StepOut(M(block, M("scene", scene_path(ctx, name), "placement", world .. "/" .. sp)), block, block, nil, nil,
                 M(name, sc))
end
GEN.add_block(Say)

local Person = {name = "person"}
function Person:generate(ctx, i, s)
  if not T(get(s, "who")) then fail("step " .. S(i) .. ": journal person - who?") end
  local raw = PYS.lower(ctx.qid .. "_" .. S(s.who))
  local cid = {}
  for _, c in ipairs(PYS.cps(raw)) do
    local ch = utf8.char(c)
    cid[#cid + 1] = PYS.isalnum(ch) and ch or "_"
  end
  cid = table.concat(cid)
  local nm = get(s, "name")
  if not T(nm) then
    local last = P.replace(S(s.who):match("([^/]*)$"), "_", " ")
    local cps = PYS.cps(last)
    nm = #cps > 0 and (PYS.upper(PYS.from_cps(cps, 1, 1)) .. PYS.lower(PYS.from_cps(cps, 2))) or ""
  end
  local page = setdefault(ctx.characters, cid, M(
    "name", nm, "group", T(get(s, "main")) and "main" or "secondary",
    "image", P.or_(get(s, "image"), "journal_grandma.png"), "description", Y.list({})))
  local entry = "e" .. S(i)
  page.description[#page.description + 1] = M(entry, P.or_(get(s, "text"), "..."))
  local block = "journal." .. sfx(i) .. "_person"
  return StepOut(M(block, M("entry", "characters/" .. cid .. "/" .. entry, "activate_root", true)), block, block, nil)
end
GEN.add_block(Person)

local Portal = {name = "portal"}
function Portal:generate(ctx, i, s)
  local si = sfx(i)
  if not T(get(s, "a")) or not T(get(s, "b_exit")) then
    fail("step " .. S(i) .. ": portal - which object, and where it leads? (the card: From, To)")
  end
  for _, side in ipairs({"a", "b"}) do
    -- a spot marker is only in the editor: the game has nothing there to step into
    if T(get(s, side)) and T(get(ctx:object(s[side]), "marker")) then
      fail("step " .. S(i) .. ": portal - " .. S(s[side]) .. " is a spot marker, which is only in the editor. " ..
           "Pick an object of the world (a door, an arch, a flag placed as an object)")
    end
  end
  local two = T(get(s, "two_way")) and T(get(s, "b")) and T(get(s, "a_exit"))
  local a_exit = T(get(s, "a_exit")) and s.a_exit or L(0.0, 0.0, 0.0)
  local fork, run, on = "addfact." .. si .. "_portal", "script." .. si .. "_portal", "addfact." .. si .. "_portal_on"
  local effect = PYS.lower(S(P.or_(get(s, "effect"), "none")))
  local white = get(s, "white", true)
  local blocks = M(
    fork, M("value", L(ctx.qid .. "_" .. si .. "_portal", 1), "next", L(run, on)),
    run, M("function", "CjPortal", "parameter", L(
      M("tagA", "cname_" .. ctx:object_tag(s.a)),
      M("tagB", T(get(s, "b")) and ("cname_" .. ctx:object_tag(s.b)) or "cname_none"),
      M("ax", F(a_exit[1])), M("ay", F(a_exit[2])), M("az", F(a_exit[3])), M("ayaw", F(get(s, "a_yaw", 0.0))),
      M("bx", F(s.b_exit[1])), M("by", F(s.b_exit[2])), M("bz", F(s.b_exit[3])), M("byaw", F(get(s, "b_yaw", 0.0))),
      M("radius", F(get(s, "radius", 1.3))), M("twoWay", two), M("white", white ~= false),
      M("effect", "cname_" .. effect))),
    on, M("value", L(ctx.qid .. "_" .. si .. "_portal_on", 1)))
  return StepOut(blocks, fork, on)
end
GEN.add_block(Portal)

-- the world a step with a point is in: picked with it, else its place's, else the project's first
function GEN.step_world(ctx, s)
  if T(get(s, "world")) then return s.world end
  if T(get(s, "place")) and P.has(ctx.project.places, s.place) then return ctx:place_world(s.place) end
  for _, n in ipairs(Y.keys(ctx.project.places)) do
    local w = get(ctx.project.places[n], "world")
    if T(w) then return w end
  end
  return "velen"
end

local Encounters = {name = "encounters"}
function Encounters:generate(ctx, i, s)
  local E = require("conjunction.encounters")
  local si = sfx(i)
  if not T(get(s, "pos")) then fail("step " .. S(i) .. ": creatures nearby - where? (the card: around, pick a point)") end
  local world = GEN.step_world(ctx, s)
  local tags = {}
  for _, t in ipairs(E.near(world, s.pos, F(get(s, "radius", 60)))) do tags[#tags + 1] = t[1] end
  if #tags == 0 then
    fail("step " .. S(i) .. ": creatures nearby - the game has none within " .. S(get(s, "radius", 60)) .. " m there")
  end
  local on = get(s, "state") == "on"
  local names = {}
  for k0 = 1, #tags do names[k0] = "script." .. si .. "_encounters" .. (k0 > 1 and ("_" .. (k0 - 1)) or "") end
  local blocks = Y.map()
  for k, name in ipairs(names) do
    blocks[name] = M("function", "CjEncounterQ", "parameter", L(M("qid", ctx.qid), M("tag", "cname_" .. S(tags[k])),
                                                                M("enable", on)))
    if k < #names then blocks[name].next = L(names[k + 1]) end
  end
  return StepOut(blocks, names[1], names[#names], nil)
end
GEN.add_block(Encounters)

local Fact = {name = "fact"}
function Fact:generate(ctx, i, s)
  local block = "addfact." .. sfx(i)
  return StepOut(M(block, M("value", L(need(s, "name"), I(get(s, "value", 1))))), block, block, nil)
end
GEN.add_block(Fact)

local WorldChange = {name = "worldchange"}
function WorldChange:generate(ctx, i, s)
  local WC = require("conjunction.worldchanges")
  if not T(get(s, "change")) then fail("step " .. S(i) .. ": change the world - which change? (make one on an object in the editor)") end
  local on, off = WC.facts(ctx.qid, I(s.change))
  local block = "addfact." .. sfx(i) .. "_world"
  return StepOut(M(block, M("value", L(get(s, "state", "on") == "on" and on or off, 1))), block, block, nil)
end
GEN.add_block(WorldChange)

local PlayAs = {name = "playas"}
function PlayAs:generate(ctx, i, s)
  local D = require("conjunction.dialogue")
  local who = get(s, "as")
  if not P.has(D.PLAYERS, who) then fail("step " .. S(i) .. ": play as - whom?") end
  local pos = T(get(s, "pos")) and s.pos or L(0.0, 0.0, 0.0)
  local b = "script." .. sfx(i) .. "_playas"
  return StepOut(M(b, M("function", "CjPlayAs", "parameter", L(
    M("who", who), M("look", S(P.or_(get(s, "look"), ""))), M("x", F(pos[1])), M("y", F(pos[2])), M("z", F(pos[3])),
    M("yaw", F(get(s, "yaw", 0.0))), M("move", T(get(s, "pos")))))), b, b, nil)
end
GEN.add_block(PlayAs)

local End = {name = "end"}
function End:generate(ctx, i, s)
  local b = "addfact." .. sfx(i) .. "_end"
  local how = get(s, "how") == "fail" and "fail" or "success"
  return StepOut(M(b, M("value", L(ctx.qid .. "_end_" .. sfx(i), 1))), b, b, nil, nil, nil, M("", how))
end
GEN.add_block(End)

local If = {name = "if"}
function If:generate(ctx, i, s)
  if #Q.conditions_of(s) == 0 then
    fail("step " .. S(i) .. ": if - what? (a path taken before, a fact, an area, an item ...)")
  end
  local meta, pre = Y.map(), {}
  local yes, no = GEN.conditions(ctx, i, s, meta, pre)
  local b = "waituntil." .. sfx(i) .. "_if"
  local blocks = M(b, M("conditions", M("yes", yes, "no", no)))
  local first = b
  for k = #pre, 1, -1 do
    local name, block = pre[k][1], pre[k][2]
    blocks[name] = with(block, "next", L(first))
    first = name
  end
  return StepOut(blocks, first, b, nil, meta, nil, M("yes", P.or_(get(s, "yes"), "continue"),
                                                    "no", P.or_(get(s, "no"), "continue")))
end
GEN.add_block(If)

-- --- the game's common actions as nodes of their own (each the game's quest function with readable fields)
GEN.CONTROLS = {{"all", "everything"}, {"fastTravel", "fast travel"}, {"meditation", "meditation"},
                {"callHorse", "calling the horse"}, {"mount", "riding"}, {"runAndSprint", "running"},
                {"drawWeapon", "drawing weapons"}, {"signs", "signs"}, {"openMap", "the map"},
                {"openInventory", "the inventory"}, {"interactions", "interacting"}}
GEN.WEAPONS = {{"steel", "steel sword", "EDWQT_Steel"}, {"silver", "silver sword", "EDWQT_Silver"},
               {"fists", "fists", "EDWQT_Fists"}, {"none", "sheathed", "EDWQT_NoWeapon"}}
GEN.LAPSES = {{"cinematic_text_some_time_later", "Some time later"}, {"cinematic_text_few_hours_later", "A few hours later"},
              {"cinematic_text_while_later", "A while later"}, {"cinematic_text_day_later", "A day later"}}
GEN.HIGHLIGHTS = {{"clue", "as a clue (red)", "FMV_Clue"}, {"interactive", "as something to use (yellow)", "FMV_Interactive"},
                  {"none", "not", "FMV_None"}}

local function Preset(name, fn, args, needs)
  local self = {name = name, ["function"] = fn, args = args, needs = needs or {}}
  function self:generate(ctx, i, s)
    for _, key in ipairs(self.needs) do
      if not T(get(s, key)) then fail("step " .. S(i) .. ": " .. self.name .. " - " .. key .. "?") end
    end
    local out = GameAction:generate(ctx, i, M("function", self["function"], "args", self.args(ctx, i, s)))
    local b = out.first
    local name_ = "script." .. sfx(i) .. "_" .. self.name
    out.blocks = M(name_, out.blocks[b])
    out.first, out.last = name_, name_
    return out
  end
  return self
end
local function controls(ctx, _i, s)
  local what = {}
  for _, w in ipairs(T(get(s, "what")) and s.what or {"all"}) do what[w] = true end
  local out = Y.map()
  for _, c in ipairs(GEN.CONTROLS) do out[c[1]] = what[c[1]] == true end
  out.lock = not T(get(s, "unlock"))
  out.sourceName = ctx.qid .. "_controls"
  return out
end
local function weapon_of(s)
  local w = P.or_(get(s, "weapon"), "steel")
  for _, e in ipairs(GEN.WEAPONS) do if e[1] == w then return e[3] end end
  return Y.null
end
local PRESETS = {
  Preset("controls", "BlockGameplayFunctionality", controls),
  Preset("health", "SetHealthQuest", function(ctx, _i, s) return M("targetTag", GEN.who(ctx, s), "healthPerc",
    I(get(s, "percent", 100)), "relative", false) end),
  Preset("target", "ForceTargetQuest", function(ctx, _i, s) return M("npcTag", need(s, "who"), "targetTag",
    GEN.who(ctx, s, "at"), "unforce", T(get(s, "stop"))) end, {"who"}),
  Preset("notalk", "DisableNPCInteractivness", function(_ctx, _i, s) return M(
    "npcTag", need(s, "who"), "disableTalking", not T(get(s, "again")), "disableOnliners", not T(get(s, "again")),
    "disableLookats", false) end, {"who"}),
  Preset("weapon", "DrawWeaponQuest", function(_ctx, _i, s) return M("weapon", weapon_of(s),
    "dontIgnoreDrawActionLock", false) end),
  Preset("look", "AppearanceChange", function(ctx, _i, s) return M("npcsTag", GEN.who(ctx, s), "appearanceName",
    S(P.or_(get(s, "appearance"), ""))) end, {"appearance"}),
  Preset("timelapse", "ShowTimeLapse", function(_ctx, _i, s) return M("showTime", F(get(s, "seconds", 5)),
    "timeLapseMessageKey", P.or_(get(s, "text"), GEN.LAPSES[1][1])) end),
  Preset("bossbar", "ShowBossFightIndicator", function(_ctx, _i, s) return M("enable", not T(get(s, "off")),
    "bossTag", need(s, "who")) end, {"who"}),
  Preset("shop", "EnableShopkeeper", function(_ctx, _i, s) return M("tag", need(s, "who"), "enable",
    not T(get(s, "off"))) end, {"who"}),
  -- (the game's blocks the board had no step for, by how often its quests use them)
  Preset("forget", "RemoveFactQuest", function(_ctx, _i, s) return M("factId", S(need(s, "name"))) end, {"name"}),
  Preset("state", "ChangeNPCStateQuest", function(_ctx, _i, s) return M(
    "npcTag", need(s, "who"), "npcState", Q.pick(Q.NPC_STATES, P.or_(get(s, "state"), "unconscious"), 3),
    "ignoreImmortalityMode", false) end, {"who"}),
  Preset("containers", "EnableOrDisableContainers", function(_ctx, _i, s) return M(
    "containersTag", need(s, "target"), "containerEnabled", not T(get(s, "off"))) end, {"target"}),
  Preset("mappin", "SetMapPinStatus", function(_ctx, _i, s) return M(
    "type", Q.pick(Q.PIN_STATES, P.or_(get(s, "state"), "discovered"), 3), "tag", need(s, "target"),
    "value", true, "dontChangeIfKnown", false, "dontChangeIfDiscovered", false) end, {"target"}),
}

local Highlight = {name = "highlight"}
function Highlight:generate(ctx, i, s)
  if not T(get(s, "target")) then fail("step " .. S(i) .. ": highlight - what?") end
  local how = "FMV_Clue"
  local want = P.or_(get(s, "how"), "clue")
  for _, h in ipairs(GEN.HIGHLIGHTS) do if h[1] == want then how = h[3] end end
  local b = "script." .. sfx(i) .. "_highlight"
  return StepOut(M(b, M("function", "FocusSetHighlight", "parameter", L(
    M("tag", "cname_" .. ctx:object_tag(s.target)), M("highlightType", "enum:EFocusModeVisibility:" .. how),
    M("overrideCustomLogic", false)))), b, b, nil)
end
GEN.add_block(Highlight)

local GoAway = {name = "goaway"}
function GoAway:generate(ctx, i, s)
  if not T(get(s, "who")) then fail("step " .. S(i) .. ": goes away - who?") end
  local comm = ctx.person_comm[s.who] or ctx.foes[s.who]
  if not comm then fail("step " .. S(i) .. ": goes away - " .. S(s.who) .. " is no person placed in a place") end
  local b = "despawn." .. sfx(i) .. "_goaway"
  -- out of the picture first (at most 20 s): nobody vanishes in front of the player
  local w, fork, keep = "script." .. sfx(i) .. "_unseen", "addfact." .. sfx(i) .. "_goaway", "script." .. sfx(i) .. "_keep"
  local tag = ctx:object_tag(s.who)
  -- gone for good: kept out after it (the community sets its people anew when the place loads - CjKeepGone)
  return StepOut(M(fork, M("value", L(tag .. "_gone", 1)),
                   w, M("function", "CjWaitUnseen", "parameter", L(M("tag", "cname_" .. tag), M("seconds", 20.0)),
                        "next", L(b)),
                   b, M("spawnsets", L(comm), "next", L(keep)),
                   keep, M("function", "CjKeepGone", "parameter", L(M("tag", "cname_" .. tag), M("fact", tag .. "_gone")))),
                 fork, fork, nil, nil, nil, M("__side", w))   -- (beside the story)
end
GEN.add_block(GoAway)

-- the player's (and his horse's) items of that name are no quest items any more: they can be sold and dropped
-- (QuestItemDisable, as the game ends its quests); again: quest items once more
local QuestItemOff = {name = "questitem"}
function QuestItemOff:generate(ctx, i, s)
  if not T(get(s, "item")) then fail("step " .. S(i) .. ": quest item off - which item?") end
  local b = "script." .. sfx(i) .. "_questitem"
  return StepOut(M(b, M("function", "QuestItemDisable", "parameter", L(
    M("itemName", "cname_" .. GEN.item_cname(ctx, s.item)), M("addQuestTag", T(get(s, "again")))))), b, b, nil)
end
GEN.add_block(QuestItemOff)

for _, c in ipairs(CALLS) do GEN.add_block(c) end
for _, p in ipairs(PRESETS) do GEN.add_block(p) end

return GEN
