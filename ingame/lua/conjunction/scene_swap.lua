-- scene_swap.py (its outline so far): what a scene of the game is made of - its inputs (the quest graph starts it at
-- one of them, with the actors it names), its outputs, its actors (by voicetag), its sections and lines. The quest
-- graph's card shows it for a scene block.
--   SS.outline(depot, path) -> {path, inputs = {{name, voicetags}}, outputs = {names}, actors = {{voicetag, template,
--                               search_by_voicetag, spawn}}, sections = {kind: n}, lines = n, cutscenes, videos}
local TR = require("conjunction.cr2w_tree")
local V = require("conjunction.vanilla_graph")
local SS = {}

SS.DEFAULT_IN, SS.DEFAULT_OUT = "Input", "Output"

function SS.outline(depot, path)
  local t = TR.Tree(depot:read(path))
  local imps = t.f.imports
  local function import_of(h)                   -- (a handle -n or a soft handle n: the import's path)
    if math.type(h) == "integer" and h < 0 and -h <= #imps then return imps[-h][1] end
    if TR.is(h, TR.SOFT) and h.n > 0 and h.n <= #imps then return imps[h.n][1] end
    return nil
  end
  local Y = require("conjunction.yaml")
  local ins, outs, seen_out, actors, kinds, lines, cuts, videos = {}, {}, {}, {}, Y.map(), 0, {}, {}
  for _, o in ipairs(t.objects) do
    local cls = o.cls
    if cls == "CStorySceneInput" then
      local tags = {}
      for _, m in ipairs(V.or_(o:get("voicetagMappings"), {})) do
        local vt = V.sget(m, "voicetag")
        if V.truth(vt) then tags[#tags + 1] = V.str(vt) end
      end
      ins[#ins + 1] = Y.map({"name", V.str(V.or_(o:get("inputName"), SS.DEFAULT_IN)), "voicetags", Y.list(tags)})
    elseif cls == "CStorySceneOutput" then
      local name = V.str(V.or_(o:get("name"), SS.DEFAULT_OUT))
      if not seen_out[name] then
        seen_out[name] = true
        outs[#outs + 1] = name
      end
    elseif cls == "CStorySceneActor" then
      local tmpl = import_of(o:get("entityTemplate"))
      actors[#actors + 1] = Y.map({"voicetag", o:get("id") ~= nil and V.str(o:get("id")) or Y.null,
                                   "template", tmpl == nil and Y.null or tmpl,
                                   "search_by_voicetag", not V.truth(o:get("dontSearchByVoicetag")),
                                   "spawn", V.truth(o:get("forceSpawn"))})
    elseif cls:sub(-7) == "Section" then
      local k = cls:gsub("CStoryScene", "")
      kinds[k] = (kinds[k] or 0) + 1                  -- (a Counter: its names in the order they come)
    elseif cls == "CStorySceneLine" then
      lines = lines + 1
    elseif cls == "CStorySceneCutscenePlayer" then
      local c = import_of(o:get("cutscene"))
      if c then cuts[#cuts + 1] = c end
    elseif cls == "CStorySceneVideoElement" then
      local v = o:get("videoFileName")
      if V.truth(v) then videos[#videos + 1] = V.str(v) end
    end
  end
  return Y.map({"path", path, "inputs", Y.list(ins), "outputs", Y.list(outs), "actors", Y.list(actors),
                "sections", kinds, "lines", lines, "cutscenes", Y.list(cuts), "videos", Y.list(videos)})
end

-- --- the swapped scene's radish definition
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PS = require("conjunction.pysort")
local PYS = require("conjunction.pystr")
local PATHS = require("conjunction.paths")
local J = require("conjunction.json")
local M, L = Y.map, Y.list
local function MK(...) return M({...}) end

-- the actor's name in the radish scene: its voicetag in small letters (spaces kept)
function SS.key(voicetag)
  local words = {}
  for w in PYS.lower(P.str(voicetag)):gmatch("%S+") do words[#words + 1] = w end
  local s = table.concat(words, " ")
  return s ~= "" and s or "actor"
end
function SS.section(name)
  return (PYS.lower(P.str(name)):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end
function SS.exit_section(output)
  return output ~= SS.DEFAULT_OUT and ("section_exit_" .. SS.section(output)) or "section_exit"
end

-- an actor the game scene names without a template still needs one for radish (found by voicetag in the game)
SS.STAND_IN = [[gameplay\community\community_npcs\novigrad\regular\novigrad_citizen_man.w2ent]]
SS.MAX_ACTORS = 10                  -- radish: "expected 2-10 actor definitions in dialogscript"

-- {order = {who ...}, by = {who = {actor key, radish asset, template}}} of a game scene's actors (Geralt apart)
function SS.cast_of(o)
  local out = {order = {}, by = {}}
  for _, a in ipairs(o.actors) do
    if a.voicetag ~= "GERALT" then
      local k = SS.key(a.voicetag)
      if out.by[k] == nil then out.order[#out.order + 1] = k end
      local by_voicetag = true
      if P.T(a.template) then by_voicetag = P.T(a.search_by_voicetag) end
      out.by[k] = {k, MK("repo", k, "by_voicetag", by_voicetag), P.T(a.template) and a.template or SS.STAND_IN}
    end
  end
  return out
end

-- a radish scene with the game scene's sockets and actors: write the lines over, wire the sections up
function SS.skeleton(o, player)
  player = player or "geralt"
  local D = require("conjunction.dialogue")
  local actors, repo = M(), M()
  for _, a in ipairs(o.actors) do
    local k = SS.key(a.voicetag)
    if a.voicetag == "GERALT" then
      repo[k] = MK("template", D.PLAYERS.geralt.template)
      actors[k] = MK("repo", k)
    else
      repo[k] = MK("template", P.T(a.template) and a.template or SS.STAND_IN)
      actors[k] = MK("repo", k, "by_voicetag", P.T(a.search_by_voicetag))
    end
  end
  local speakers = {}
  for _, k in ipairs(Y.keys(actors)) do if k ~= "geralt" then speakers[#speakers + 1] = k end end
  if #speakers == 0 then speakers = {"geralt"} end
  local script = MK("player", player, "actors", L(Y.keys(actors)))
  for n, i in ipairs(o.inputs) do
    local name = i.name == SS.DEFAULT_IN and "section_start" or ("section_start_" .. i.name)
    local who = speakers[1]
    for _, v in ipairs(i.voicetags) do
      local k = SS.key(v)
      if actors[k] ~= nil and k ~= "geralt" and k ~= "player" then who = k break end
    end
    local first_out = #o.outputs > 0 and o.outputs[math.min(n, #o.outputs)] or nil
    script[name] = L({MK(who, "(new line - started at " .. i.name .. ")"),
                      MK("NEXT", first_out and ("section_exit_" .. SS.section(first_out)) or "section_exit")})
  end
  for _, out in ipairs(o.outputs) do
    local body = out == SS.DEFAULT_OUT and L({}) or L({MK("OUTPUT", out)})
    body[#body + 1] = "EXIT"
    script["section_exit_" .. SS.section(out)] = body
  end
  if #o.outputs == 0 then script.section_exit = L({"EXIT"}) end
  local cameras = M()
  for _, k in ipairs(Y.keys(actors)) do
    cameras[SS.section(k) .. "_cam"] = MK("repo", k == "geralt" and "1_2_medium" or "2_1_medium")
  end
  local cam_defaults = M()
  for _, k in ipairs(Y.keys(actors)) do cam_defaults[k] = SS.section(k) .. "_cam" end
  return MK("repository", Y.len(repo) > 0 and MK("actors", repo) or M(),
            "production", MK("settings", MK("sceneid", 1, "strings-idspace", 9999, "strings-idstart", 0),
                             "placement", "PLAYER", "assets", MK("actors", actors, "cameras", cameras)),
            "storyboard", MK("defaults", MK("camera", cam_defaults)),
            "dialogscript", script)
end

-- section names in a dialogscript's bodies (NEXT, CHOICE, RANDOM ...) renamed by `names`
local RENAMED = {NEXT = true, CHOICE = true, RANDOM = true, CUE = true, choice = true, on_true = true, on_false = true}
local function rename(x, names)
  if type(x) == "string" then return names[x] or x end
  if Y.is_map(x) then
    local out = M()
    for _, k in ipairs(Y.keys(x)) do out[k] = RENAMED[k] and rename(x[k], names) or x[k] end
    return out
  end
  if type(x) == "table" and x ~= Y.null then
    local out = L({})
    for i, v in ipairs(x) do out[i] = rename(v, names) end
    return out
  end
  return x
end
SS.rename = rename

-- a scene with more people than radish takes: only those who speak in it (and Geralt)
local function only_speakers(scene)
  local script = scene.dialogScript
  local actors = {}
  for i, a in ipairs(script.actors) do actors[i] = a end
  if #actors <= SS.MAX_ACTORS then return end
  local is_actor = {}
  for _, a in ipairs(actors) do is_actor[a] = true end
  local spoken = {}
  for _, key in ipairs(Y.keys(script)) do
    local body = script[key]
    if type(body) == "table" and not Y.is_map(body) and body ~= Y.null then
      for _, x in ipairs(body) do
        if Y.is_map(x) then for _, k in ipairs(Y.keys(x)) do if is_actor[k] then spoken[k] = true end end end
      end
    end
  end
  local keep = L({})
  for _, a in ipairs(actors) do
    if (a == "geralt" or spoken[a]) and #keep < SS.MAX_ACTORS then keep[#keep + 1] = a end
  end
  local kept = {}
  for _, a in ipairs(keep) do kept[a] = true end
  script.actors = keep
  local assets = scene.production.assets
  local function filter_map(m, ok)
    local out = M()
    for _, k in ipairs(Y.keys(m)) do if ok(k, m[k]) then out[k] = m[k] end end
    return out
  end
  assets.actors = filter_map(P.get(assets, "actors") or M(), function(k) return kept[k] end)
  local cams = {}
  for _, a in ipairs(keep) do cams[SS.section(a) .. "_cam"] = true end
  assets.cameras = filter_map(P.get(assets, "cameras") or M(), function(k) return cams[k] end)
  for _, kind in ipairs({"animations", "mimics"}) do
    if P.T(P.get(assets, kind)) then
      assets[kind] = filter_map(assets[kind], function(_, v) return kept[P.get(v, "actor")] end)
    end
  end
  local defaults = P.get(P.get(scene, "storyboard") or M(), "defaults") or M()
  if P.T(P.get(defaults, "camera")) then
    defaults.camera = filter_map(defaults.camera, function(k) return kept[k] end)
  end
  local repo = P.get(P.get(scene, "repository") or M(), "actors")
  if P.T(repo) then scene.repository.actors = filter_map(repo, function(k) return kept[k] end) end
end

-- the radish scene of a swap: a dialogue per input of the game scene (an input without one: its first output at
-- once), merged into one scene with exactly the game scene's inputs, outputs and actors -> scene, strings used
function SS.scene(swap, scene_id, idspace, idstart, speech, own_ids, own_item)
  local DS = require("conjunction.dialogue_scene")
  local D = require("conjunction.dialogue")
  own_item = own_item or function() return nil end
  local o = swap.outline
  local cast = SS.cast_of(o)
  local outputs = P.T(o.outputs) and o.outputs or {SS.DEFAULT_OUT}
  local exits = M()
  for _, out in ipairs(outputs) do exits["out:" .. out] = SS.exit_section(out) end
  local merged, n_strings = nil, 0
  for k, i in ipairs(o.inputs) do
    local name = i.name
    local mine = P.get(P.get(swap, "inputs") or M(), name) or M()
    mine = P.get(mine, "talk") or mine
    local lines = P.list(P.get(mine, "dialogue"))
    local then_ = outputs[math.min(k, #outputs)]
    for _, x in ipairs(outputs) do if P.get(mine, "then") == x then then_ = x end end
    local ex = M()
    for _, kk in ipairs(Y.keys(exits)) do ex[kk] = exits[kk] end
    ex.continue, ex.retry, ex.fail = SS.exit_section(then_), SS.exit_section(then_), SS.exit_section(then_)
    local start = name == SS.DEFAULT_IN and "section_start" or ("section_start_" .. SS.section(name))
    local part
    if #lines == 0 then
      part = MK("dialogScript", MK(start, L({MK("NEXT", SS.exit_section(then_))})), "storyboard", M())
    else
      local main = cast.by[P.get(mine, "npc")] and P.get(mine, "npc") or cast.order[1]
      local mcast = {order = {}, by = {}}
      if main then
        mcast.order[1] = "npc"
        mcast.by.npc = cast.by[main]
      end
      for _, who in ipairs(cast.order) do
        if mcast.by[who] == nil then mcast.order[#mcast.order + 1] = who end
        mcast.by[who] = cast.by[who]
      end
      part = DS.to_scene(lines, nil, nil, scene_id, idspace, idstart + n_strings,
                         "cj_swap" .. scene_id .. "_" .. SS.section(name), own_ids, speech,
                         {cast = mcast, exits = ex, own_item = own_item})
      n_strings = n_strings + DS.string_count(lines)
      -- its sections get the input's name (one scene holds every input's talk)
      local script = part.dialogScript
      local is_exit = {}
      for _, kk in ipairs(Y.keys(exits)) do is_exit[exits[kk]] = true end
      local names = {}
      for _, sec in ipairs(Y.keys(script)) do
        if sec ~= "player" and sec ~= "actors" and not is_exit[sec] then
          names[sec] = sec == "section_start" and start or (sec .. "_" .. SS.section(name))
        end
      end
      for _, sec in ipairs(Y.keys(part.storyboard)) do      -- (cues too: one scene, every input's)
        if sec ~= "defaults" then
          for _, c in ipairs(Y.keys(part.storyboard[sec])) do names[c] = c .. "_" .. SS.section(name) end
        end
      end
      local new_script = M()
      for _, sec in ipairs(Y.keys(script)) do new_script[names[sec] or sec] = rename(script[sec], names) end
      part.dialogScript = new_script
      local new_board = M()
      for _, sec in ipairs(Y.keys(part.storyboard)) do
        local v = part.storyboard[sec]
        if sec ~= "defaults" then
          local cues = M()
          for _, c in ipairs(Y.keys(v)) do cues[names[c] or c] = v[c] end
          v = cues
        end
        new_board[names[sec] or sec] = v
      end
      part.storyboard = new_board
    end
    if merged == nil then
      merged = #lines > 0 and part or SS.skeleton(o)
      if #lines == 0 then
        merged.dialogScript = MK("player", "geralt", "actors", merged.dialogscript.actors)
        Y.remove(merged, "dialogscript")
        merged.production.settings = MK("sceneid", scene_id, "strings-idspace", idspace, "strings-idstart", idstart)
        for _, sec in ipairs(Y.keys(part.dialogScript)) do merged.dialogScript[sec] = part.dialogScript[sec] end
      end
    else
      for _, sec in ipairs(Y.keys(part.dialogScript)) do
        if sec ~= "player" and sec ~= "actors" then merged.dialogScript[sec] = part.dialogScript[sec] end
      end
      for _, sec in ipairs(Y.keys(part.storyboard)) do
        if sec ~= "defaults" then merged.storyboard[sec] = part.storyboard[sec] end
      end
      for _, kind in ipairs({"animations", "mimics"}) do
        local have = P.get(P.get(P.get(part, "production") or M(), "assets") or M(), kind)
        if P.T(have) then
          local into = P.get(merged.production.assets, kind)
          if into == nil then
            into = M()
            merged.production.assets[kind] = into
          end
          for _, kk in ipairs(Y.keys(have)) do into[kk] = have[kk] end
        end
      end
    end
  end
  -- every output must stay; radish wants each pointed at - one nobody's talk leads to gets an input of its own
  local used = {}
  local NEXTS = {NEXT = true, CHOICE = true, RANDOM = true, choice = true, on_true = true, on_false = true}
  local function refs(x)
    if type(x) == "string" then used[x] = true
    elseif Y.is_map(x) then
      for _, kk in ipairs(Y.keys(x)) do if NEXTS[kk] then refs(x[kk]) end end
    elseif type(x) == "table" and x ~= Y.null then
      for _, v in ipairs(x) do refs(v) end
    end
  end
  for _, kk in ipairs(Y.keys(merged.dialogScript)) do
    if kk ~= "player" and kk ~= "actors" then refs(merged.dialogScript[kk]) end
  end
  -- the player is always in it (the scene's look-ats go to them even where they say nothing)
  local has_geralt = false
  for _, a in ipairs(merged.dialogScript.actors) do if a == "geralt" then has_geralt = true end end
  if not has_geralt then
    local list = L({"geralt"})
    for _, a in ipairs(merged.dialogScript.actors) do list[#list + 1] = a end
    merged.dialogScript.actors = list
  end
  local assets = merged.production.assets
  if P.get(assets, "actors") == nil then assets.actors = M() end
  if P.get(assets.actors, "geralt") == nil then assets.actors.geralt = MK("repo", "geralt") end
  if P.get(merged, "repository") == nil then merged.repository = M() end
  if P.get(merged.repository, "actors") == nil then merged.repository.actors = M() end
  if P.get(merged.repository.actors, "geralt") == nil then
    merged.repository.actors.geralt = MK("template", D.PLAYERS.geralt.template)
  end
  only_speakers(merged)
  for k, out in ipairs(outputs) do
    local body = out == SS.DEFAULT_OUT and L({}) or L({MK("OUTPUT", out)})
    body[#body + 1] = "EXIT"
    merged.dialogScript[SS.exit_section(out)] = body
    if not used[SS.exit_section(out)] then
      merged.dialogScript["section_start_cj_unused_" .. k] = L({MK("NEXT", SS.exit_section(out))})
    end
  end
  return merged, n_strings
end

-- 'mq1060 01 hook  -  mq1060 devils pit': the scene's name and the quest folder it is in
function SS.label(path)
  local parts = {}
  for x in P.replace(path, "/", "\\"):gmatch("[^\\]+") do parts[#parts + 1] = x end
  local name = P.replace(parts[#parts]:match("^(.*)%.[^.]*$") or parts[#parts], "_", " ")
  local folder
  for k = 1, #parts - 1 do if parts[k] == "quest_files" then folder = parts[k + 1] break end end
  if folder == nil then folder = #parts > 2 and parts[#parts - 2] or "" end
  return folder ~= "" and (name .. "  -  " .. P.replace(folder, "_", " ")) or name
end

-- a swap of the game scene at `path`: its outline and a talk per input (who speaks first: its actor)
function SS.new_swap(depot, path)
  local o = SS.outline(depot, path)
  if #o.inputs == 0 then error("ValueError: No quest starts this scene, so it cannot be replaced", 0) end
  local inputs = M()
  for _, i in ipairs(o.inputs) do
    local people = {}
    for _, v in ipairs(i.voicetags) do if v ~= "GERALT" then people[#people + 1] = SS.key(v) end end
    local main = people[1]
    if main == nil then
      for _, a in ipairs(o.actors) do if a.voicetag ~= "GERALT" then main = SS.key(a.voicetag) break end end
    end
    local talk = MK("swap", true, "input", i.name, "dialogue", L({}))
    if main then
      talk.npc = main
      local with = L({})
      for k = 2, #people do with[#with + 1] = MK("who", people[k]) end
      talk.with = with
    end
    inputs[i.name] = MK("talk", talk)
  end
  return MK("scene", path, "name", SS.label(path), "outline", o, "inputs", inputs)
end

-- every scene of the game (depot paths), sorted - kept in data\game_scenes.json
local INDEX
function SS.scene_index(depot)
  if INDEX == nil then
    local cache = PATHS.DATA .. "\\game_scenes.json"
    local ok, v = pcall(J.read, cache)
    if ok and type(v) == "table" then
      INDEX = v
    else
      INDEX = PS.sorted(depot:glob("", ".w2scene"))
      pcall(J.write, cache, INDEX)
    end
  end
  return INDEX
end

-- {scene path: {voicetags of its actors (Geralt apart), ways in}} - kept in data\game_scene_info.json (the app
-- builds it, a second)
-- (made in slices when called in a coroutine: the engine makes it over the frames after its start, engine.lua; a
-- call meanwhile goes on where the slices are)
local INFO, BUILD
-- the scenes' info there without reading every scene (its cache, or read before)
function SS.info_ready()
  return INFO ~= nil or w3.fs.exists(PATHS.DATA .. "\\game_scene_info.json")
end

function SS.scene_info(depot)
  if INFO == nil then
    local cache = PATHS.DATA .. "\\game_scene_info.json"
    local ok, v = pcall(J.read, cache)
    if ok and type(v) == "table" then
      INFO = v
    else
      BUILD = BUILD or {i = 0, info = {}}
      local index = SS.scene_index(depot)
      local slice = os.clock() + 0.015
      while BUILD.i < #index do
        BUILD.i = BUILD.i + 1
        local p = index[BUILD.i]
        local okp, f = pcall(function() return require("conjunction.cr2w").parse(depot:read(p)) end)
        if okp then
          local tags, ins = {}, 0
          for _, e in ipairs(f.exports) do
            if e[1] == "CStorySceneActor" then
              for _, pr in ipairs(f:props(e[5])) do
                if pr[1] == "id" and pr[2] == "CName" then
                  local t = f.names[string.unpack("<I2", e[5], pr[3] + 1) + 1]
                  if t ~= "GERALT" then tags[#tags + 1] = PYS.lower(t) end
                end
              end
            elseif e[1] == "CStorySceneInput" then
              ins = ins + 1
            end
          end
          BUILD.info[p] = {table.concat(tags, " "), ins}
        end
        if coroutine.isyieldable() and os.clock() >= slice then
          coroutine.yield()
          slice = os.clock() + 0.015
        end
      end
      if INFO == nil then
        INFO = BUILD.info
        pcall(J.write, cache, INFO)
      end
    end
  end
  return INFO
end

function SS.scene_people(depot)
  local out = {}
  for p, v in pairs(SS.scene_info(depot)) do out[p] = v[1] end
  return out
end

return SS
