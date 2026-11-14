-- A dialogue made a radish scene (dialogue.py's to_scene and what it needs): its sections (lines, choices, ifs, the
-- random), the storyboard's cues (gestures, moods, poses, looks, cameras, props), the production's assets, the
-- repository of the shots and poses it takes. The quest generator (questgen_steps.lua: Talk.scene) calls it.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local N = require("conjunction.pynum")
local D = require("conjunction.dialogue")
local GEN = require("conjunction.questgen")
local M, L, F, I, S, R = GEN.map, GEN.list, GEN.float, GEN.int, GEN.str, GEN.round
local fail, with, setdefault = GEN.fail, GEN.with, GEN.setdefault
local T, get = P.T, P.get
local DS = {}

-- Python's == on data (a dict, a list, a str ...) - `x in list` asks it
local function deep_eq(a, b)
  if rawequal(a, b) then return true end
  if type(a) ~= "table" or type(b) ~= "table" or a == Y.null or b == Y.null then return false end
  if Y.is_map(a) ~= Y.is_map(b) then return false end
  if Y.is_map(a) then
    if Y.len(a) ~= Y.len(b) then return false end
    for k, v in pairs(a) do if b[k] == nil or not deep_eq(v, b[k]) then return false end end
    return true
  end
  if #a ~= #b then return false end
  for i = 1, #a do if not deep_eq(a[i], b[i]) then return false end end
  return true
end
local function contains(list, x) for _, y in ipairs(list) do if deep_eq(y, x) then return true end end return false end
local function has_key(t, k) return Y.is_map(t) and t[k] ~= nil end

-- --- what a talk is when talked to again: its greeting, a choice of the questions one may ask again, a goodbye
function DS.again_lines(a)
  local ag = get(a, "again") or Y.map()
  local items = P.list(get(ag, "questions"))
  if #items == 0 then return nil end
  local by_id = {}
  for _, c in ipairs(D.options(D.from_step(a))) do
    if T(get(c, "id")) and by_id[c.id] == nil then by_id[c.id] = c end
  end
  for _, c in ipairs(D.options(D.from_step(a))) do if T(get(c, "id")) then by_id[c.id] = c end end
  local opts = Y.list({})
  for _, it in ipairs(items) do
    if T(get(it, "ask")) then
      local c = by_id[it.ask]
      if c == nil then fail("Asked again: the question '" .. S(it.ask) .. "' is no longer in the talk") end
      opts[#opts + 1] = M("text", P.or_(get(c, "text"), "..."), "lines", P.deepcopy(P.list(get(c, "lines"))), "end", "back")
    else
      local ls = Y.list({})
      for _, x in ipairs(P.list(get(it, "lines"))) do ls[#ls + 1] = x end
      opts[#opts + 1] = M("text", P.or_(get(it, "text"), "..."), "lines", ls, "end", "back")
    end
  end
  opts[#opts + 1] = M("text", P.or_(get(ag, "bye"), "Goodbye."), "end", "continue")
  local out = Y.list({})
  if T(get(ag, "greet")) then out[1] = M("who", "npc", "text", ag.greet) end
  out[#out + 1] = M("choice", opts)
  return out
end

-- the options of the same choice an 'after all other options' waits for
function DS.after_others(choice, c)
  local mine = false
  for _, x in ipairs(D.conditions(c)) do if x == D.AFTER_ALL then mine = true end end
  if not mine then return {} end
  local out = {}
  for _, o in ipairs(choice) do
    if not rawequal(o, c) then
      local all = false
      for _, x in ipairs(D.conditions(o)) do if x == D.AFTER_ALL then all = true end end
      local e = S(get(o, "end", ""))
      if not all and (T(get(o, "once")) or e == "back" or e == "up") then out[#out + 1] = o end
    end
  end
  return out
end

function DS.option_fact(qid, oid) return qid .. "_opt_" .. S(oid) end
function DS.chosen_fact(fact, n, k) return fact .. "_o" .. n .. "_" .. k end

-- an answer's 'only if' as {{fact, op, value}}
function DS.only_if_checks(cond)
  if not T(cond) then return {} end
  if type(cond) == "string" then return {{cond, "=", 1}} end
  if type(cond[1]) == "table" then
    local out = {}
    for _, x in ipairs(cond) do out[#out + 1] = {table.unpack(x)} end
    return out
  end
  return {{table.unpack(cond)}}
end

-- does the player say an answer's text when it is chosen?
function DS.says_choice(c)
  if get(c, "say") ~= nil then return T(c.say) end
  local first = P.list(get(c, "lines"))[1]
  return not (Y.is_map(first) and has_key(first, "who") and D.is_player(get(first, "who")))
end

-- the lines that get their audio from the quest's DLC: own recordings and, with mouth, every line without a voice
function DS.custom_voiced(lines, mouth)
  if mouth == nil then mouth = true end
  local out = {}
  local all = D.walk(lines)
  for _, x in ipairs(all) do
    -- (a game voice with a text of its own too: say copies its recording under an id of its own, 13.11.)
    if (has_key(x, "who") or DS.says_choice(x)) and
       (T(get(x, "voice_pack")) or (mouth and not T(get(x, "voice")) and not T(get(x, "thought"))) or
        (T(get(x, "voice")) and PYS.strip(S(get(x, "text", ""))) ~= "")) then
      out[#out + 1] = x
    end
  end
  if mouth then
    for _, x in ipairs(all) do
      for _, t in ipairs(P.list(get(x, "alt"))) do
        if PYS.strip(S(t)) ~= "" then out[#out + 1] = M("text", t) end
      end
    end
  end
  return out
end

-- how many strings the scene needs (a line, an answer and Geralt saying it)
function DS.string_count(lines)
  local n = 0
  for _, x in ipairs(D.walk(lines)) do n = n + (has_key(x, "who") and 1 or 2) + #P.list(get(x, "alt")) end
  return n + 2
end

-- the fact value of every way out: continue 1, retry 2, fail 3, paths 10, 11, ... (sorted by name)
function DS.codes(ends)
  local out = {}
  for e in pairs(ends) do if D.CODE[e] then out[e] = D.CODE[e] end end
  local paths = {}
  for e in pairs(ends) do if P.startswith(e, "path:") then paths[#paths + 1] = e end end
  require("conjunction.pysort").sort(paths)
  for k, e in ipairs(paths) do out[e] = 10 + k - 1 end
  return out
end

-- the scene's actor name of an extra person (radish: [a-z_0-9])
function DS.extra_key(ref)
  local out = {"p_"}
  for _, c in ipairs(PYS.cps(PYS.lower(ref))) do
    local ch = utf8.char(c)
    out[#out + 1] = PYS.isalnum(ch) and ch or "_"
  end
  return table.concat(out)
end

-- --- cameras
local SIDE = {{40.0, -15.0}, {45.0, -15.0}, {45.0, -10.0}, {45.0, -18.0}, {50.0, -15.0}, {60.0, -15.0}, {70.0, -15.0},
              {80.0, -15.0}}
DS.SIDE_CAMERAS = Y.map()
for k0, ft in ipairs(SIDE) do
  local k = k0 - 1
  DS.SIDE_CAMERAS["cj_side_" .. k0] = M(
    "fov", ft[1], "transform", M("pos", L(k ~= 1 and -3.5 or -4.5, 1.2, 1.9), "rot", L(0.0, ft[2], k ~= 1 and 260.0 or 240.0)),
    "zoom", 0.0, "dof", M("aperture", L(42.14, 2.7), "blur", L(4.0, 5.0), "focus", L(1.45, 3.0), "intensity", 1.0),
    "event_generator", M("plane", "medium", "tags", L("ext")))
end

local SHOT_DEFS
-- (repo name, its definition) of a shot on the one who speaks, or nil (dialogue.shot_camera)
function DS.shot_camera(player_speaks, plane, drop, player_at)
  drop = drop or 0.0
  if SHOT_DEFS == nil then
    local ok, t = pcall(require, "conjunction.data.camera_shots")
    SHOT_DEFS = ok and t or {}
  end
  local side = player_speaks and "1_2" or "2_1"
  for _, suffix in ipairs({"ext", "int"}) do
    local name = side .. "_" .. plane .. "_" .. suffix
    local d = SHOT_DEFS[name]
    if d then
      local pos = {d.pos[1], d.pos[2], R(d.pos[3] + drop, 3)}
      local rot = {d.rot[1], d.rot[2], d.rot[3]}
      local low = drop ~= 0 and ("_low" .. I(N.round0(-drop * 100))) or ""
      if player_at then
        local px, py = F(player_at[1]), F(player_at[2])
        local t = math.atan(-px, py)
        local x, y = pos[1], pos[2] - (player_speaks and 1.6 or 0.0)
        x, y = x * math.cos(t) - y * math.sin(t), x * math.sin(t) + y * math.cos(t)
        if player_speaks then
          x, y = x + px, y + py
          pos[3] = R(pos[3] + F(#player_at > 2 and player_at[3] or 0.0), 3)
        end
        pos[1], pos[2] = R(x, 3), R(y, 3)
        rot[3] = R((rot[3] + math.deg(t)) % 360, 2)
        low = low .. P.replace("_at" .. I(N.round0(px * 100)) .. "_" .. I(N.round0(py * 100)), "-", "m")
      end
      return "cj_" .. name .. low, M(
        "fov", d.fov, "transform", M("pos", Y.list(pos), "rot", Y.list(rot)), "zoom", d.zoom or 0.0,
        "dof", M("aperture", L(28.25, 1.27), "blur", L(3.0, 10.0), "focus", L(2.0, 4.0), "intensity", 1.0),
        "event_generator", M("plane", plane, "tags", L(suffix)))
    end
  end
  return nil
end

-- the radish camera of one of a talk's own cameras, c in the scene's space ({pos, yaw, pitch, fov})
function DS.own_camera(c)
  return M("fov", F(get(c, "fov", 35.0)),
           "transform", M("pos", L(R(F(c.pos[1]), 3), R(F(c.pos[2]), 3), R(F(c.pos[3]), 3)),
                          "rot", L(0.0, R(F(get(c, "pitch", 0.0)), 2), R(F(get(c, "yaw", 0.0)) % 360, 2))),
           "zoom", 0.0,
           "dof", M("aperture", L(28.25, 1.27), "blur", L(3.0, 10.0), "focus", L(2.0, 4.0), "intensity", 0.0),
           "event_generator", M("plane", "medium", "tags", L("ext")))
end

-- a camera or where someone stands, set in the world, in the space of a scene placed at origin turned by origin_yaw
function DS.scene_space(c, origin, origin_yaw)
  local a = math.rad(-F(origin_yaw))
  local dx, dy = c.pos[1] - origin[1], c.pos[2] - origin[2]
  return with(c, "pos", L(dx * math.cos(a) - dy * math.sin(a), dx * math.sin(a) + dy * math.cos(a), c.pos[3] - origin[3]),
              "yaw", (F(get(c, "yaw", 0.0)) - F(origin_yaw)) % 360)
end

-- {camera asset: {repo}}, {actor: camera asset}, {repo cameras} for these actors (in order), side_1 on
function DS.side_cameras(keys)
  local assets, defaults, repo = Y.map(), Y.map(), Y.map()
  for k, key in ipairs(keys) do
    if k > Y.len(DS.SIDE_CAMERAS) then break end
    local name, cam = P.replace(key, " ", "_") .. "_cam", "cj_side_" .. k
    assets[name], defaults[key], repo[cam] = M("repo", cam), name, DS.SIDE_CAMERAS[cam]
  end
  return assets, defaults, repo
end

DS.HOLD_SWORD = {steel = "steelsword", silver = "silversword"}
local BANKS
-- the game's sound bank that holds a sound event (radish's soundevents repo), or nil
function DS.sound_bank(event)
  if BANKS == nil then
    BANKS = {}
    pcall(function()
      local f = S(P.or_(get(require("conjunction.config").load(), "radish"), "")) ..
                "\\repo.scenes\\soundevents.with-exp.repo.yml"
      local doc = Y.read(f)
      local banks = get(get(doc or Y.map(), "repository") or Y.map(), "soundbanks") or Y.map()
      for bank, events in pairs(banks) do
        for _, e in ipairs(P.list(events)) do
          if BANKS[S(e)] == nil then BANKS[S(e)] = S(bank) end
        end
      end
    end)
    if BANKS[""] == nil then BANKS[""] = "" end
  end
  return BANKS[S(event)]
end

-- the sound banks the scene's sounds come from, in its production assets (radish wants them imported)
function DS.with_soundbanks(scene)
  local banks = {}
  local function walk(x)
    if Y.is_map(x) then
      for k, v in pairs(x) do
        if k == "actor.sound" and Y.is_list(v) and #v >= 3 then
          local b = DS.sound_bank(v[3])
          if not T(b) then fail("The sound " .. S(v[3]) .. " is in none of the game's sound banks") end
          banks[b] = true
        else
          walk(v)
        end
      end
    elseif Y.is_list(x) then
      for _, v in ipairs(x) do walk(v) end
    end
  end
  walk(get(scene, "storyboard") or Y.map())
  local list = {}
  for b in pairs(banks) do list[#list + 1] = b end
  if #list > 0 then
    table.sort(list)
    scene.production.assets.soundbanks = Y.list(list)
  end
  return scene
end

-- what happens with a line besides the words: sound, hold, appearance, fade, goto (a mark), show / hide (props)
function DS.line_events(x, who, marks, props)
  local out = {}
  props = props or {}
  for _, k in ipairs({"show", "hide"}) do
    for _, n in ipairs(P.list(get(x, k))) do
      if props[n] then out[#out + 1] = M("prop." .. k, L(0.0, props[n])) end
    end
  end
  local m = T(get(x, "goto")) and get(marks or Y.map(), x["goto"]) or nil
  if T(m) then
    out[#out + 1] = M("actor.placement", L(0.0, who, L(R(F(m.pos[1]), 3), R(F(m.pos[2]), 3), R(F(m.pos[3]), 3)),
                                           L(0.0, 0.0, R(F(get(m, "yaw", 0.0)) % 360, 2))))
  end
  if T(get(x, "sound")) then out[#out + 1] = M("actor.sound", L(0.0, who, S(x.sound))) end
  if DS.HOLD_SWORD[get(x, "sword")] then
    out[#out + 1] = M("actor.equip.right", L(0.2, who, DS.HOLD_SWORD[x.sword]))
  elseif has_key(x, "hold") then
    if T(get(x, "hold")) then out[#out + 1] = M("actor.equip.right", L(0.2, who, S(x.hold)))
    else out[#out + 1] = M("actor.unequip.right", L(0.2, who)) end
  end
  if T(get(x, "appearance")) then out[#out + 1] = M("actor.appearance", L(0.0, who, S(x.appearance))) end
  if get(x, "fade") == "out" then out[#out + 1] = M("fade.out", L(0.8, 1.0))
  elseif get(x, "fade") == "in" then out[#out + 1] = M("fade.in", L(0.0, 1.0)) end
  return out
end

-- --- poses and gestures of the game's own scenes
function DS.pose_drop(anim)
  local a = anim or ""
  if a:find("lying", 1, true) or a:find("laying", 1, true) then return -1.3 end
  if P.startswith(a, "low_sitting") or a:find("sitting_ground", 1, true) or a:find("tiedup", 1, true) then return -0.85 end
  if a:find("sitting", 1, true) then return -0.45 end
  if a:find("kneeling", 1, true) then return -0.55 end
  return 0.0
end

local function capitalize(w)
  local cps = PYS.cps(w)
  if #cps == 0 then return "" end
  return PYS.upper(PYS.from_cps(cps, 1, 1)) .. PYS.lower(PYS.from_cps(cps, 2))
end
function DS.pose_state(anim)
  local words = {}
  for w in (anim .. "_"):gmatch("([^_]*)_") do words[#words + 1] = w end
  local out = Y.map()
  if words[1] == "high" or words[1] == "low" then out.status = capitalize(words[1]) end
  for _, w in ipairs(words) do
    if w == "standing" or w == "sitting" or w == "kneeling" or w == "lying" or w == "laying" or w == "channeling" then
      out.name = w == "laying" and "Lying" or capitalize(w)
      break
    end
  end
  local moods = {}
  for _, m in ipairs(require("conjunction.data.dialogue_tables").MOOD_WORDS) do moods[m] = true end
  for _, w in ipairs(words) do
    if moods[w] then
      out.emotional_state = w == "agressive" and "Aggressive" or capitalize(w)
      break
    end
  end
  return out
end

local ANIM_IDS
-- the radish repository id of a game animation ('anim_4033_high_standing_...'), or nil
function DS.anim_repo_id(animation)
  if ANIM_IDS == nil then
    ANIM_IDS = {}
    pcall(function()
      local radish = require("conjunction.config").load().radish
      local f = io.open(tostring(radish) .. "\\repo.scenes\\sbui.all_animations.repo.yml", "rb")
      if not f then return end
      local text = f:read("a"):gsub("\r\n", "\n")
      f:close()
      for id, name in text:gmatch('\n        (%S+):\n            animation: "([^"]+)"') do
        if ANIM_IDS[name] == nil then ANIM_IDS[name] = id end
      end
    end)
  end
  return ANIM_IDS[animation]
end

local REPO_SECS
function DS.anim_seconds(repo)
  if REPO_SECS == nil then
    REPO_SECS = {}
    for _, a in ipairs(D.all_animations()) do
      local rid = DS.anim_repo_id(a[1])
      if rid and REPO_SECS[rid] == nil then REPO_SECS[rid] = a[2] end
    end
  end
  return REPO_SECS[repo]
end

-- the seconds of a timed line ("[<seconds>]..."), nil: no line
local function line_seconds(item)
  if not (Y.is_map(item) and Y.len(item) == 1) then return nil end
  local v = item[Y.keys(item)[1]]
  if type(v) == "string" and P.startswith(v, "[") and v:find("]", 1, true) then
    return tonumber(v:sub(2, v:find("]", 1, true) - 1))
  end
  return nil
end

-- a gesture plays whole, past the end of its line, as the game's own do (it ends in the pose it started from); only
-- where its section ends first (the scene goes on in another section, a choice, the end) it is cut there and blended
-- out (after the lines are timed). A cue's position is a share of its line.
function DS.fit_gestures(scene)
  local anims = get(get(get(scene, "production") or Y.map(), "assets") or Y.map(), "animations") or Y.map()
  local board = get(scene, "storyboard") or Y.map()
  for section, body in pairs(get(scene, "dialogScript") or Y.map()) do
    if Y.is_list(body) then
      for k, item in ipairs(body) do
        if Y.is_map(item) and has_key(item, "CUE") then
          local dur, at
          for j = k + 1, #body do
            dur = line_seconds(body[j])
            if dur then at = j break end
          end
          local after = 0.0                   -- the section's seconds after the line
          for j = (at or #body) + 1, #body do
            local nxt = body[j]
            local secs = line_seconds(nxt)
            if secs then after = after + secs
            elseif Y.is_map(nxt) and has_key(nxt, "PAUSE") and tonumber(nxt.PAUSE) then after = after + tonumber(nxt.PAUSE)
            elseif not (Y.is_map(nxt) and has_key(nxt, "CUE")) then break end
          end
          local events = get(get(board, section) or Y.map(), item.CUE)
          if dur ~= nil and Y.is_list(events) then
            for j, ev in ipairs(events) do
              local pos = Y.is_map(ev) and get(ev, "actor.anim") or nil
              if Y.is_list(pos) and #pos == 2 and anims[pos[2]] ~= nil then
                local secs = DS.anim_seconds(get(anims[pos[2]], "repo"))
                local room = dur * (1.0 - F(pos[1])) + after
                if not (secs == nil or secs <= room or room <= 0.3) then
                  events[j] = M("actor.anim", M(".@pos", L(pos[1], pos[2]), "clipend", R(room, 3),
                                                "blendout", R(math.min(0.6, room / 2), 3)))
                end
              end
            end
          end
        end
      end
    end
  end
  return scene
end

-- ===================================================================================================================
-- lines -> (radish scene definition, outcomes - a set). o: extras {{ref, template, tag, joins}}, own_item, character,
-- qid, poses, gameplay, cams, stands, placement, cam_defaults, marks, props (as dialogue.to_scene's keywords)
-- A game scene swapped (scene_swap.lua): o.cast {order = {who ...}, by = {who = {key, asset, template}}} - its actors,
-- found by voicetag - in place of the NPC and the extras; o.exits {end = section} - where each end goes (the game
-- scene's outputs, its own actors and exits: the scene is the caller's to finish)
function DS.to_scene(lines, npc_template, npc_tag, scene_id, idspace, idstart, fact, own_ids, speech, o)
  o = o or {}
  local cast, exits = o.cast, o.exits
  local mouth = o.mouth ~= false
  local extras = o.extras or {}
  local own_item = o.own_item or function() return nil end
  local character = o.character or "geralt"
  local qid = o.qid or "cj"
  local poses, gameplay, cams, stands = o.poses, o.gameplay or false, o.cams, o.stands
  local placement, cam_defaults, marks, props = o.placement or "PLAYER", o.cam_defaults, o.marks, o.props
  local prop_key, prop_order = {}, {}
  local k_prop = 0
  for _, n in ipairs(exits and {} or Y.keys(P.map(props))) do
    local p = props[n]
    if T(get(p, "template")) and T(get(P.map(marks), get(p, "mark"))) then
      k_prop = k_prop + 1
      local slug = PYS.lower(n):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
      local key = ("prop_" .. k_prop .. "_" .. slug)
      local cps = PYS.cps(key)
      if #cps > 40 then key = PYS.from_cps(cps, 1, 40) end
      prop_key[n] = key
      prop_order[#prop_order + 1] = n
    end
  end
  local who_plays = get(D.PLAYERS, character) or D.PLAYERS.geralt
  local pk = PYS.lower(who_plays.voicetag)
  local player_actor = M(pk, M("template", who_plays.template))
  local actor_of, actor_order = {}, {}
  for _, e in ipairs(extras) do
    if actor_of[e[1]] == nil then actor_order[#actor_order + 1] = e[1] end
    actor_of[e[1]] = DS.extra_key(e[1])
  end
  local first_cast
  if cast then
    actor_of = {}
    for _, who in ipairs(cast.order) do actor_of[who] = cast.by[who][1] end
    first_cast = cast.by[cast.order[1]] and cast.by[cast.order[1]][1] or nil
  end
  local late = {}
  for _, e in ipairs(extras) do if e[4] == "line" then late[#late + 1] = actor_of[e[1]] end end
  local function is_late(who) for _, x in ipairs(late) do if x == who then return true end end return false end
  local template_of = {[pk] = who_plays.template, npc = npc_template}
  for _, e in ipairs(extras) do if actor_of[e[1]] then template_of[actor_of[e[1]]] = e[2] end end
  if cast then for _, who in ipairs(cast.order) do template_of[cast.by[who][1]] = cast.by[who][3] end end
  local bodies, bodies_known = {}, {}
  local shot_repo, shot_assets = Y.map(), Y.map()
  local function anims_of(actor)
    if not bodies_known[actor] then
      bodies_known[actor] = true
      local t = template_of[actor]
      local ok, v = pcall(function() return t and require("conjunction.talking").dialogue_anims(t) or nil end)
      bodies[actor] = ok and v or nil
    end
    return bodies[actor]
  end
  local ends = D.outcomes(lines)
  local code = DS.codes(ends)
  local nends = 0
  for _ in pairs(ends) do nends = nends + 1 end
  local monologue = npc_template == nil and not cast and #extras == 0
  local sections = Y.map()
  local storyboard = M("defaults", M("camera", M(pk, "player_cam", "npc", "npc_cam")))
  local anims, mimics, face_anims = Y.map(), Y.map(), Y.map()
  local pose_repo, pose_assets = Y.map(), Y.map()
  local player_at
  for _, r in ipairs(Y.keys(P.map(stands))) do
    if D.is_player(r) then player_at = stands[r].pos break end
  end
  local drops = {}
  local count = {cue = 0, choice = 0, script = 0, join = 0, after_script = 0, rand = 0, ["if"] = 0, var = 0}

  local function actor_key(ref)
    if ref == nil then return nil end
    if D.is_player(ref) then return pk end
    if ref == "npc" then return "npc" end
    return actor_of[ref]
  end

  local function camera_of(key, who)
    if not T(key) then return nil end
    if P.startswith(key, "cam:") then
      local name = key:sub(5)
      local c = get(P.map(cams), name)
      if not T(c) then return nil end
      local asset = "own_" .. PYS.lower(name):gsub("[^a-z0-9_]", "_")
      shot_repo["cj_" .. asset] = DS.own_camera(c)
      shot_assets[asset] = M("repo", "cj_" .. asset)
      return asset
    end
    if who ~= pk and who ~= "npc" then return nil end
    local name, definition = DS.shot_camera(who == pk, key, drops[who] or 0.0, player_at)
    if not name then return nil end
    shot_repo[name] = definition
    shot_assets[name] = M("repo", name)
    return name
  end

  local function pose_event(who, key)
    if gameplay and who == pk then return nil end
    local anim = D.pose_anim(key, anims_of(who))
    if not anim then return nil end
    local repo = "pose_" .. anim
    pose_repo[repo] = with(DS.pose_state(anim), "idle_anim", anim)
    local asset = P.replace(who, " ", "_") .. "_" .. key
    pose_assets[asset] = M("actor", who, "repo", repo)
    return M("actor.pose", L(0.0, asset))
  end

  local function say(x, section, body)
    local who
    if D.is_player(get(x, "who")) then who = pk
    else who = actor_of[get(x, "who")] or (cast and first_cast or "npc") end
    local text = PYS.strip(S(get(x, "text", "")))
    if text == "" then text = "..." end
    local hold = F(P.or_(get(x, "length"), 0))
    if T(get(x, "voice")) and own_ids ~= nil and text ~= "..." then
      -- (the game's voice with the creator's text: a line of its own, the recording copied into the quest's speech
      -- file - under the game's id the subtitle was the game's text, 13.11.)
      local sid = own_ids()
      speech[#speech + 1] = M("id", sid, "text", text, "source", Y.null, "game", I(x.voice), "lang", "en")
      text = string.format("[%.3f]%010d|%s", F(P.or_(get(x, "dur"), 2.0)), sid, text)
    elseif T(get(x, "voice")) then
      text = string.format("[%.3f]%010d|%s", F(P.or_(get(x, "dur"), 2.0)), I(x.voice), text)
    elseif own_ids ~= nil and mouth and not T(get(x, "voice_pack")) and not T(get(x, "thought")) then
      local sid = own_ids()
      speech[#speech + 1] = M("id", sid, "text", text, "source", Y.null, "lang", "en")
      text = string.format("[@%d]%010d|%s", sid, sid, text)
    elseif T(get(x, "voice_pack")) and own_ids ~= nil then
      local v = require("conjunction.contentpacks").voice(x.voice_pack)
      if v == nil then fail("Voice line " .. S(x.voice_pack) .. " is in no loaded content pack") end
      local sid = own_ids()
      local dur = require("conjunction.speech").seconds(v.file)
      if dur == 0 then dur = F(P.or_(get(x, "dur"), 2.0)) end
      speech[#speech + 1] = M("id", sid, "text", text, "source", v.file, "lang", v.lang or "en")
      text = string.format("[%.3f]%010d|%s", dur, sid, text)
    end
    local events = Y.list({})
    local have = anims_of(who)
    local anim = D.GESTURE[get(x, "gesture")] and D.gesture_anim(x.gesture, have) or nil
    if T(get(x, "anim")) and (have == nil or have[x.anim]) then anim = x.anim end
    local repo = anim and DS.anim_repo_id(anim)
    if repo then
      local asset = not T(get(x, "anim")) and (P.replace(who, " ", "_") .. "_" .. S(x.gesture)) or
                    (P.replace(who, " ", "_") .. "_" .. repo)
      anims[asset] = M("actor", who, "repo", repo, "blendin", 0.4, "blendout", 0.6)
      events[#events + 1] = M("actor.anim", L(0.1, asset))
    end
    if D.MOOD[get(x, "mood")] and (have == nil or next(have) ~= nil) then
      local asset = who .. "_" .. x.mood
      mimics[asset] = M("actor", who, "repo", x.mood)
      events[#events + 1] = M("actor.mimic", L(0.0, asset))
    end
    if D.POSE[get(x, "pose")] then
      local ev = pose_event(who, x.pose)
      if ev then events[#events + 1] = ev end
    end
    local target = actor_key(get(x, "look"))
    if target and target ~= who and not (gameplay and who == pk) then
      events[#events + 1] = M("actor.lookat", L(0.0, who, target))
    end
    if is_late(who) then events[#events + 1] = M("actor.show", L(0.0, who)) end
    for _, ev in ipairs(DS.line_events(x, who, marks, prop_key)) do events[#events + 1] = ev end
    local to = camera_of(get(x, "camera"), who)
    local start = to and camera_of(get(x, "glide"), who) or nil
    if to and start and start ~= to then
      events[#events + 1] = M("cam.blend.start", L(0.0, start, "smooth"))
      events[#events + 1] = M("cam.blend.end", L(1.0, to, "smooth"))
    elseif to then
      events[#events + 1] = M("cam", L(0.0, to))
    end
    if #events > 0 then
      count.cue = count.cue + 1
      local cue = "cue_" .. count.cue
      body[#body + 1] = M("CUE", cue)
      setdefault(storyboard, section, Y.map())[cue] = events
    end
    body[#body + 1] = M(who, text)
    if hold > 0 then
      if P.startswith(text, "[@") then
        body[#body + 1] = M("PAUSE", string.format("@rest %s %.3f", text:sub(3, text:find("]", 1, true) - 1), hold))
      elseif P.startswith(text, "[") then
        local said = F(text:sub(2, text:find("]", 1, true) - 1))
        if hold - said > 0.05 then body[#body + 1] = M("PAUSE", R(hold - said, 3)) end
      end
    end
  end

  local function end_of(e)
    if exits then return exits[e] end
    if nends > 1 and code[e] then return "script_end_" .. D.socket(e) end
    return "section_exit"
  end

  local function scripts(calls, then_)
    for k = #calls, 1, -1 do
      count.script = count.script + 1
      local name = "script_do_" .. count.script
      sections[name] = L(M("SCRIPT", calls[k]), M("NEXT", then_))
      then_ = name
    end
    return then_
  end

  local function effects(c)
    local calls = {}
    for _, ks in ipairs({{"give", -1}, {"receive", 1}}) do
      local key, sign = ks[1], ks[2]
      local d = get(c, key) or Y.map()
      if T(get(d, "item")) then
        local own = own_item(d.item)
        if own then
          calls[#calls + 1] = M("function", "CjSceneItemN", "parameter", L(M("itemName", "cname_" .. own),
                                                                            M("count", sign * I(get(d, "count", 1)))))
        else
          calls[#calls + 1] = M("function", "CjSceneItem", "parameter", L(M("item", S(d.item)),
                                                                           M("count", sign * I(get(d, "count", 1)))))
        end
      end
      if key == "receive" and (T(get(d, "money")) or T(get(d, "xp"))) then
        calls[#calls + 1] = M("function", "CjSceneGive", "parameter", L(M("money", I(get(d, "money", 0))),
                                                                         M("xp", I(get(d, "xp", 0)))))
      end
    end
    if T(get(c, "shop")) and T(npc_tag) then
      calls[#calls + 1] = M("function", "ShowMeGoods", "parameter", L(M("merchantTag", "cname_" .. npc_tag)))
    end
    return calls
  end

  local function axii_cast(section, ls)
    local events = Y.list({})
    local have = anims_of(pk)
    -- the covert gesture (as q702_18_axii casts it); the open one when a body has not the covert one
    local cast_anim = (have == nil or have[D.AXII_CAST_ANIM]) and D.AXII_CAST_ANIM or D.AXII_CAST_ANIM_ALT
    local repo = DS.anim_repo_id(cast_anim)
    if repo and (have == nil or next(have) ~= nil) then
      local asset = pk .. "_axii_cast"
      anims[asset] = M("actor", pk, "repo", repo, "blendin", 0.3, "blendout", 0.5)
      events[#events + 1] = M("actor.anim", L(0.05, asset))
    end
    events[#events + 1] = M("actor.effect.start", L(0.35, pk, "axii_cast_dialog"))
    local ref = "npc"
    for _, ln in ipairs(ls) do
      if Y.is_map(ln) and T(get(ln, "who")) and not D.is_player(ln.who) then ref = ln.who break end
    end
    local target = actor_of[ref] or ((not cast and npc_template ~= nil) and actor_key(ref) or nil)
    if target and target ~= pk then
      events[#events + 1] = M("actor.effect.start", L(0.6, target, "axii_confusion"))
      local th = anims_of(target)
      if th == nil or next(th) ~= nil then          -- (a face: the dazed look the game's Axii gives)
        local face = P.replace(target, " ", "_") .. "_axii_dazed"
        face_anims[face] = M("actor", target, "repo", D.AXII_DAZED_FACE)
        events[#events + 1] = M("actor.anim.mimic", L(0.6, face))
      end
    end
    count.cue = count.cue + 1
    local cue = "cue_" .. count.cue
    local sec = setdefault(sections, section, Y.list({}))
    sec[#sec + 1] = M("CUE", cue)
    sec[#sec + 1] = M("PAUSE", D.AXII_CAST_SECONDS)
    setdefault(storyboard, section, Y.map())[cue] = events
  end

  local base_poses = {}
  local fill
  fill = function(section, ls, end_, pre, back)
    pre = pre or {}
    local body = setdefault(sections, section, Y.list({}))
    local k0 = 1
    while k0 <= #ls do
      local x = ls[k0]
      local join
      local split = false
      for _, s in ipairs(D.SPLITS) do if has_key(x, s) then split = true end end
      if split then
        join = end_
        if k0 < #ls then
          count.join = count.join + 1
          join = "section_join_" .. count.join
          local rest = {}
          for j = k0 + 1, #ls do rest[#rest + 1] = ls[j] end
          fill(join, rest, end_, nil, back)
        end
      end
      local handled = false
      if has_key(x, "script") then
        count.after_script = count.after_script + 1
        local after = "section_after_script_" .. count.after_script
        body[#body + 1] = M("NEXT", scripts({x.script}, after))
        section, body = after, setdefault(sections, after, Y.list({}))
        handled = true
      elseif has_key(x, "random") then
        count.rand = count.rand + 1
        local n = count.rand
        local names = Y.list({})
        for k, br in ipairs(P.list(get(x, "random"))) do
          local sec = "section_random_" .. n .. "_" .. k
          local be = get(br, "end")
          local target
          if (be == "back" or be == "up") and back then target = back
          elseif be ~= nil and be ~= "back" and be ~= "up" and be ~= "on" then target = end_of(be)
          else target = join end
          fill(sec, P.list(get(br, "lines")), target, nil, back)
          names[#names + 1] = sec
        end
        local pick = "section_random_" .. n
        sections[pick] = L(M("RANDOM", names))
        body[#body + 1] = M("NEXT", scripts(pre, pick))
        return
      elseif has_key(x, "if") then
        count["if"] = count["if"] + 1
        local n = count["if"]
        local c = get(x, "if") or Y.map()
        local names = {}
        for _, st in ipairs({{"then", "yes"}, {"else", "no"}}) do
          local br = get(x, st[1]) or Y.map()
          local sec = "section_if_" .. n .. "_" .. st[2]
          local be = get(br, "end")
          local target
          if (be == "back" or be == "up") and back then target = back
          elseif be ~= nil and be ~= "back" and be ~= "up" and be ~= "on" then target = end_of(be)
          else target = join end
          fill(sec, P.list(get(br, "lines")), target, nil, back)
          names[#names + 1] = sec
        end
        local cond = M("condition", L(S(get(c, "fact", "")), S(get(c, "op", ">=")), I(get(c, "value", 1))),
                       "on_true", names[1], "on_false", names[2])
        body[#body + 1] = M("NEXT", scripts(pre, cond))
        return
      end
      if not handled then
        local alts = {}
        if not has_key(x, "choice") then
          for _, t in ipairs(P.list(get(x, "alt"))) do if PYS.strip(S(t)) ~= "" then alts[#alts + 1] = t end end
        end
        if #alts > 0 then
          count.var = count.var + 1
          local n = count.var
          local after = "section_after_" .. n
          local names = Y.list({})
          local texts = {get(x, "text", "")}
          for _, t in ipairs(alts) do texts[#texts + 1] = t end
          for k, text in ipairs(texts) do
            local vs = "section_variant_" .. n .. "_" .. k
            local variant = x
            if k > 1 then
              variant = with(x, "text", text)
              for _, key in ipairs({"voice", "voice_pack", "dur", "alt"}) do Y.remove(variant, key) end
            end
            local vb = setdefault(sections, vs, Y.list({}))
            say(variant, vs, vb)
            vb[#vb + 1] = M("NEXT", after)
            names[#names + 1] = vs
          end
          body[#body + 1] = M("RANDOM", names)
          section, body = after, setdefault(sections, after, Y.list({}))
        elseif not has_key(x, "choice") then
          say(x, section, body)
        else
          count.choice = count.choice + 1
          local n = count.choice
          local cs = (#base_poses > 0) and ("section_ask_" .. n) or ("section_choice_" .. n)
          local options, checks, answers = Y.list({}), {}, {}
          local waited = {}
          for _, c in ipairs(x.choice) do
            for _, o2 in ipairs(DS.after_others(x.choice, c)) do waited[o2] = true end
          end
          for k, c in ipairs(x.choice) do
            local a = "section_answer_" .. n .. "_" .. k
            local text = PYS.strip(S(get(c, "text", "")))
            if text == "" then text = "..." end
            local act = T(get(c, "pay")) and "pay" or T(get(c, "axii")) and "axii" or T(get(c, "shop")) and "shop" or
                        get(c, "icon")
            local ch = L(text, a)
            if T(act) then
              ch[#ch + 1] = act
              if act == "pay" then ch[#ch + 1] = I(c.pay) end
            end
            local opt = M("choice", ch)
            if T(get(c, "once")) then opt.single_use = true end
            if T(get(c, "emphasize")) then opt.emphasize = true end
            local conds = {}
            for _, cond in ipairs(D.conditions(c)) do
              if cond == D.AFTER_ALL then
                local others = DS.after_others(x.choice, c)
                for j, o2 in ipairs(x.choice) do
                  if contains(others, o2) then conds[#conds + 1] = {DS.chosen_fact(fact, n, j), "=", 1} end
                end
              elseif type(cond) == "string" and P.startswith(cond, "@") then
                conds[#conds + 1] = {DS.option_fact(qid, cond:sub(2)), "=", 1}
              else
                for _, ck in ipairs(DS.only_if_checks(cond)) do conds[#conds + 1] = ck end
              end
            end
            local need = with(get(c, "needs") or Y.map())
            if T(get(get(c, "give") or Y.map(), "item")) then
              setdefault(need, "item", c.give.item)
              setdefault(need, "count", get(c.give, "count", 1))
            end
            if Y.is_list(get(need, "item")) or T(get(need, "none")) then
              local check = fact .. "_n" .. n .. "_" .. k
              local items = Y.is_list(get(need, "item")) and need.item or {P.or_(get(need, "item"), "")}
              local names = {}
              for _, it in ipairs(items) do if T(it) then names[#names + 1] = S(it) end end
              checks[#checks + 1] = M("function", "CjSceneHas", "parameter", L(
                M("fact", check), M("items", table.concat(names, ";")), M("count", I(get(need, "count", 1))),
                M("none", T(get(need, "none")))))
              conds[#conds + 1] = {check, "=", 1}
            elseif T(get(need, "item")) or T(get(need, "money")) then
              local check = fact .. "_n" .. n .. "_" .. k
              local own = own_item(get(need, "item"))
              if own then
                checks[#checks + 1] = M("function", "CjSceneCheckN", "parameter", L(
                  M("fact", check), M("itemName", "cname_" .. own), M("count", I(get(need, "count", 1)))))
              else
                checks[#checks + 1] = M("function", "CjSceneCheck", "parameter", L(
                  M("fact", check), M("item", S(get(need, "item", ""))), M("count", I(get(need, "count", 1))),
                  M("money", I(get(need, "money", 0)))))
              end
              conds[#conds + 1] = {check, "=", 1}
            end
            if #conds > 1 then
              local check = fact .. "_a" .. n .. "_" .. k
              local parts = {}
              for _, cc in ipairs(conds) do parts[#parts + 1] = S(cc[1]) .. "," .. S(cc[2]) .. "," .. S(cc[3]) end
              checks[#checks + 1] = M("function", "CjSceneAll", "parameter", L(M("fact", check),
                                                                                M("checks", table.concat(parts, ";"))))
              conds = {{check, "=", 1}}
            end
            if #conds > 0 then opt.condition = Y.list({table.unpack(conds[1])}) end
            options[#options + 1] = Y.len(opt) > 1 and opt or opt.choice
            -- the sign first, then the demand (q702_18_axii: Geralt casts, then says his lines)
            if T(get(c, "axii")) and not gameplay then axii_cast(a, P.list(get(c, "lines"))) end
            if DS.says_choice(c) and not monologue then
              say(with(c, "who", D.PLAYER, "text", text, "gesture", Y.null, "mood", Y.null), a,
                  setdefault(sections, a, Y.list({})))
            end
            answers[#answers + 1] = {a, c, get(c, "end", "continue")}
          end
          local entry = scripts(checks, cs)
          for k, ans in ipairs(answers) do
            local a, c, e = ans[1], ans[2], ans[3]
            local target
            if e == "back" then target = entry
            elseif e == "up" then target = back or end_
            elseif e == "on" then target = join
            else target = end_of(e) end
            local mark = {}
            if waited[c] then
              mark[#mark + 1] = M("function", "CjSetFact", "parameter", L(M("fact", DS.chosen_fact(fact, n, k)),
                                                                           M("value", 1)))
            end
            if T(get(c, "id")) then
              mark[#mark + 1] = M("function", "CjSetFact", "parameter", L(M("fact", DS.option_fact(qid, c.id)),
                                                                           M("value", 1)))
            end
            local calls = {}
            for _, m in ipairs(mark) do calls[#calls + 1] = m end
            for _, ef in ipairs(effects(c)) do calls[#calls + 1] = ef end
            fill(a, P.list(get(c, "lines")), target, calls, entry)
          end
          if T(get(x, "time")) then options[#options + 1] = M("time_limit", F(x.time)) end
          sections[cs] = L(M("CHOICE", options))
          body[#body + 1] = M("NEXT", scripts(pre, entry))
          return
        end
      end
      k0 = k0 + 1
    end
    body[#body + 1] = M("NEXT", scripts(pre, end_))
  end

  local first = Y.list({})
  for _, who in ipairs(late) do first[#first + 1] = M("actor.hide", L(0.0, who)) end
  local shown_later = {}
  for _, y in ipairs(D.walk(lines)) do for _, n in ipairs(P.list(get(y, "show"))) do shown_later[n] = true end end
  for _, n in ipairs(prop_order) do
    local key = prop_key[n]
    local m = marks[props[n].mark]
    first[#first + 1] = M("prop.placement", L(0.0, key, L(R(F(m.pos[1]), 3), R(F(m.pos[2]), 3), R(F(m.pos[3]), 3)),
                                                L(0.0, 0.0, R(F(get(m, "yaw", 0.0)) % 360, 2))))
    first[#first + 1] = M(shown_later[n] and "prop.hide" or "prop.show", L(0.0, key))
  end
  for _, ref in ipairs(Y.keys(P.map(poses))) do
    local who = actor_key(ref)
    local ev = who and pose_event(who, poses[ref]) or nil
    if ev then base_poses[#base_poses + 1] = ev end
  end
  if not monologue and not cast then
    if not gameplay then first[#first + 1] = M("actor.lookat", L(0.0, pk, "npc")) end
    first[#first + 1] = M("actor.lookat", L(0.0, "npc", pk))
  end
  for _, ev in ipairs(base_poses) do
    local asset = ev["actor.pose"][2]
    drops[pose_assets[asset].actor] = DS.pose_drop(pose_repo[pose_assets[asset].repo].idle_anim)
  end
  local own_default = {}
  for _, ref in ipairs(Y.keys(P.map(cam_defaults))) do
    local who, asset = actor_key(ref), camera_of(cam_defaults[ref], nil)
    if who and asset then own_default[who] = asset end
  end
  fill("section_start", lines, end_of("continue"))
  for _, name in ipairs(Y.keys(sections)) do
    local sec = sections[name]
    if not (name == "section_start" or #base_poses == 0 or #sec == 0 or not Y.is_map(sec[1])) then
      local k0 = has_key(sec[1], "CUE") and 1 or 0
      local head = sec[k0 + 1]
      if P.startswith(name, "section_ask_") and Y.is_map(head) and has_key(head, "CHOICE") then
        local cue = "cue_pose_" .. (Y.len(get(storyboard, name) or Y.map()) + 1)
        table.insert(sec, 1, M("PAUSE", 0.3))
        table.insert(sec, 1, M("CUE", cue))
        local later = Y.list({})
        for _, ev in ipairs(base_poses) do later[#later + 1] = M("actor.pose", L(0.1, ev["actor.pose"][2])) end
        local close_name, close_def
        if not own_default[pk] then close_name, close_def = DS.shot_camera(true, "closeup", 0.0, player_at) end
        if close_name then
          shot_repo[close_name] = close_def
          shot_assets[close_name] = M("repo", close_name)
        end
        later[#later + 1] = M("cam", L(0.0, close_name or "player_cam"))
        setdefault(storyboard, name, Y.map())[cue] = later
      elseif Y.is_map(head) then
        local hk = Y.keys(head)[1]
        if not (hk == "NEXT" or hk == "SCRIPT" or hk == "OUTPUT" or hk == "PAUSE" or hk == "CHOICE") then
          if k0 == 1 then
            local cue = sec[1].CUE
            local evs = Y.list({})
            for _, ev in ipairs(base_poses) do evs[#evs + 1] = ev end
            for _, ev in ipairs(P.list(get(get(storyboard, name) or Y.map(), cue))) do evs[#evs + 1] = ev end
            setdefault(storyboard, name, Y.map())[cue] = evs
          else
            local cue = "cue_pose_" .. (Y.len(get(storyboard, name) or Y.map()) + 1)
            table.insert(sec, 1, M("CUE", cue))
            setdefault(storyboard, name, Y.map())[cue] = Y.list({table.unpack(base_poses)})
          end
        end
      end
    end
  end
  local start_poses = {}
  for _, ev in ipairs(base_poses) do start_poses[#start_poses + 1] = M("actor.pose", L(0.1, ev["actor.pose"][2])) end
  if #first > 0 or #start_poses > 0 then
    local st = sections.section_start
    table.insert(st, 1, M("PAUSE", 0.4))
    table.insert(st, 1, M("CUE", "cue_start"))
    local evs = Y.list({})
    for _, ev in ipairs(first) do evs[#evs + 1] = ev end
    for _, ev in ipairs(start_poses) do evs[#evs + 1] = ev end
    setdefault(storyboard, "section_start", Y.map()).cue_start = evs
  end
  if exits then
    -- a swap: its own actors, the exits are the caller's (the game scene's outputs)
    local actors = M(pk, M("repo", pk))
    for _, who in ipairs(cast.order) do
      local c = cast.by[who]
      actors[c[1]] = c[2]
    end
    local akeys = Y.keys(actors)
    local main = cast.by.npc and cast.by.npc[1] or nil
    if main == nil then for _, k in ipairs(akeys) do if k ~= pk then main = k break end end end
    local others = {}
    for _, k in ipairs(akeys) do if k ~= pk and k ~= main then others[#others + 1] = k end end
    local is_other = {}
    for _, k in ipairs(others) do is_other[k] = true end
    local side_assets, side_defaults, side_repo = DS.side_cameras(others)
    local cams, cam_defaults2 = Y.map(), Y.map()
    for _, k in ipairs(akeys) do
      if not is_other[k] then
        cams[P.replace(k, " ", "_") .. "_cam"] = M("repo", k == pk and "1_2_medium" or "2_1_medium")
        cam_defaults2[k] = P.replace(k, " ", "_") .. "_cam"
      end
    end
    for _, k in ipairs(Y.keys(side_assets)) do cams[k] = side_assets[k] end
    for _, k in ipairs(Y.keys(side_defaults)) do cam_defaults2[k] = side_defaults[k] end
    local assets = M("actors", actors, "cameras", cams)
    storyboard.defaults = M("camera", cam_defaults2)
    if Y.len(anims) > 0 then assets.animations = anims end
    if Y.len(mimics) > 0 then assets.mimics = mimics end
    if Y.len(face_anims) > 0 then assets["animations.mimic"] = face_anims end
    local repo_actors = Y.map()
    for _, k in ipairs(Y.keys(player_actor)) do repo_actors[k] = player_actor[k] end
    for _, who in ipairs(cast.order) do
      local c = cast.by[who]
      if T(c[3]) then repo_actors[c[1]] = M("template", c[3]) end
    end
    local repository = M("actors", repo_actors)
    if Y.len(side_repo) > 0 then repository.cameras = side_repo end
    local script = M("player", pk, "actors", L(table.unpack(akeys)))
    for _, k in ipairs(Y.keys(sections)) do script[k] = sections[k] end
    local scene = M("repository", repository,
                    "production", M("settings", M("sceneid", scene_id, "strings-idspace", idspace,
                                                  "strings-idstart", idstart),
                                    "placement", "PLAYER", "assets", assets),
                    "storyboard", storyboard,
                    "dialogScript", script)
    return DS.with_soundbanks(scene), ends
  end
  if nends > 1 then
    for _, e in ipairs(D.sorted(ends)) do
      sections["script_end_" .. D.socket(e)] = L(
        M("SCRIPT", M("function", "CjSetFact", "parameter", L(M("fact", fact), M("value", code[e])))),
        M("NEXT", "section_exit"))
    end
  end
  sections.section_exit = L(M("OUTPUT", "Out"), "EXIT")
  local alone = npc_template == nil
  local actors = M(pk, M("repo", pk))
  if not alone then actors.npc = M("repo", "npc", "tags", L(npc_tag), "by_voicetag", false) end
  for _, e in ipairs(extras) do actors[actor_of[e[1]]] = M("repo", actor_of[e[1]], "tags", L(e[3]), "by_voicetag", false) end
  local assets = M("actors", actors, "cameras", M("player_cam", M("repo", "1_2_medium"), "npc_cam", M("repo", "2_1_medium")))
  local extra_keys = {}
  for _, e in ipairs(extras) do extra_keys[#extra_keys + 1] = actor_of[e[1]] end
  local side_assets, side_defaults, side_repo = DS.side_cameras(extra_keys)
  for k, v in pairs(side_assets) do assets.cameras[k] = v end
  for _, wcs in ipairs({{pk, "player_cam", true}, {"npc", "npc_cam", false}}) do
    local who, cam, side = wcs[1], wcs[2], wcs[3]
    if own_default[who] then
      assets.cameras[cam] = M("repo", "cj_" .. own_default[who])
    elseif (drops[who] and drops[who] ~= 0) or player_at then
      local ln, ld = DS.shot_camera(side, "medium", drops[who] or 0.0, player_at)
      if ln then
        shot_repo[ln] = ld
        assets.cameras[cam] = M("repo", ln)
      end
    end
  end
  for k, v in pairs(shot_assets) do assets.cameras[k] = v end
  local repo_cams = with(side_repo)
  for k, v in pairs(shot_repo) do repo_cams[k] = v end
  for k, v in pairs(side_defaults) do storyboard.defaults.camera[k] = v end
  if T(stands) and not alone then
    local turn = 0.0
    if player_at then turn = R(math.deg(math.atan(-F(player_at[1]), F(player_at[2]))) % 360, 2) end
    local spots = M("npc", L(L(0.0, 0.0, 0.0), L(0.0, 0.0, turn)))
    for _, ref in ipairs(Y.keys(stands)) do
      local c = stands[ref]
      local who = actor_key(ref)
      if who and who ~= "npc" then
        spots[who] = L(L(R(F(c.pos[1]), 3), R(F(c.pos[2]), 3), R(F(c.pos[3]), 3)), L(0.0, 0.0, R(F(get(c, "yaw", 0)) % 360, 2)))
      end
    end
    storyboard.defaults.placement = spots
  end
  if Y.len(anims) > 0 then assets.animations = anims end
  if Y.len(mimics) > 0 then assets.mimics = mimics end
  if Y.len(face_anims) > 0 then assets["animations.mimic"] = face_anims end
  if Y.len(pose_assets) > 0 then assets["actor.poses"] = pose_assets end
  if #prop_order > 0 then
    local pa = Y.map()
    for _, n in ipairs(prop_order) do pa[prop_key[n]] = M("repo", prop_key[n]) end
    assets.props = pa
  end
  local repo_actors = with(player_actor)
  if not alone then repo_actors.npc = M("template", npc_template) end
  for _, e in ipairs(extras) do repo_actors[actor_of[e[1]]] = M("template", e[2]) end
  local repository = M("actors", repo_actors)
  if Y.len(repo_cams) > 0 then repository.cameras = repo_cams end
  if Y.len(pose_repo) > 0 then repository["actor.poses"] = pose_repo end
  if #prop_order > 0 then
    local pr = Y.map()
    for _, n in ipairs(prop_order) do pr[prop_key[n]] = M("template", props[n].template) end
    repository.props = pr
  end
  local actor_list = L(pk)
  if not alone then actor_list[#actor_list + 1] = "npc" end
  for _, e in ipairs(extras) do actor_list[#actor_list + 1] = actor_of[e[1]] end
  local script = M("player", pk, "actors", actor_list)
  if #prop_order > 0 then
    local pl = Y.list({})
    for _, n in ipairs(prop_order) do pl[#pl + 1] = prop_key[n] end
    script.props = pl
  end
  for k, v in pairs(sections) do script[k] = v end
  local scene = M("repository", repository,
                  "production", M("settings", M("sceneid", scene_id, "strings-idspace", idspace, "strings-idstart", idstart),
                                  "placement", placement, "assets", assets),
                  "storyboard", storyboard,
                  "dialogScript", script)
  return DS.with_soundbanks(scene), ends
end

return DS
