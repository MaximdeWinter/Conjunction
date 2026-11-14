-- Editor sessions (sessions.py): the game played from files, never from a save - a fresh session from one of the
-- game's definitions (.redgame) or from one of ours (a world, a story entry, facts set by our main quest).
--   SE.definitions(depot, story, rebuild) -> the game's starts (data\sessions.json)   SE.for_quest / SE.story_starts
--   SE.plan(q, quests) -> world, entry or nil, facts     SE.world_name(path)     SE.jump(ed, world, entry, facts)
--   SE.build_mod(depot, game_dir) / SE.ensure_mod(game_dir)   our starts as Mods\modConjunctionSessions
local P = require("conjunction.py")
local Y = require("conjunction.yaml")
local PS = require("conjunction.pysort")
local PYS = require("conjunction.pystr")
local SE = {}

SE.WORLD_OF = {[1] = "novigrad", [9] = "novigrad", [4] = "prolog_village", [2] = "skellige", [3] = "kaer_morhen",
               [11] = "bob"}
SE.ENTRY_ORDER = {"Prologue", "Act I", "Act II", "Act III", "Epilogue"}
SE.ENTRY_OF_ACT = {Prologue = "prologue", ["Act I"] = "part 1", ["Act II"] = "part 2", ["Act III"] = "part 3 after novi",
                   Epilogue = "epilogues"}
SE.DONE = {"complet", "done", "finish", "_end", "success"}
-- (WORLD_DEFS' keys in their order)
SE.WORLDS = {"kaer_morhen", "novigrad", "prolog_village", "skellige", "bob"}

local NAMES = {kaer_morhen = "Kaer Morhen", novigrad = "Velen and Novigrad", prolog_village = "White Orchard",
               prolog_village_winter = "White Orchard (winter)", skellige = "Skellige", bob = "Toussaint",
               wyzima_castle = "Vizima", island_of_mist = "Isle of Mists", spiral = "The Spiral"}
function SE.world_name(path)
  if not path or path == "" then return "" end
  local parts = {}
  for part in (PYS.lower(path) .. "\\"):gmatch("(.-)\\") do parts[#parts + 1] = part end
  local key = #parts > 1 and parts[#parts - 1] or parts[#parts]
  return NAMES[key] or (key:gsub("_", " "))
end

function SE.entry_fact(entry)
  local s = PYS.lower(entry):gsub("[^%w]", "_")
  return "cj_entry_" .. (s:gsub("^_+", ""):gsub("_+$", ""))
end
function SE.world_def(world) return "conjunction\\sessions\\" .. world .. ".redgame" end

SE.NOT_STARTS = {"engine\\", "\\demo_files\\", "_freecam", "\\test\\", "performance"}
SE.MANY = 6                     -- a definition starting this many quests starts a part of the story
function SE.cache() return require("conjunction.paths").DATA .. "\\sessions.json" end

local function depot_of(depot)
  return depot or require("conjunction.depot").open(require("conjunction.config").load().game)
end
local function handle(v)                -- a handle's number (an import's, 1-based), or nil
  local V = require("conjunction.vanilla_graph")
  return V.isint(v) and V.ival(v) or nil
end

-- the quest graph files a main quest plays: those it names, and those the phases it names name (one deep)
local function phase_files(depot, path)
  local TR = require("conjunction.cr2w_tree")
  local seen, out, have = {}, {}, {}
  local todo = {{path, 0}}
  while #todo > 0 do
    local p, depth = table.unpack(table.remove(todo, 1))
    if not seen[p] and depot:exists(p) then
      seen[p] = true
      local ok, t = pcall(TR.Tree, depot:read(p))
      if ok then
        for _, imp in ipairs(t.f.imports) do
          local ip = imp[1]
          if (ip:sub(-8) == ".w2phase" or ip:sub(-8) == ".w2quest") and not have[ip] then
            have[ip] = true
            out[#out + 1] = ip
            if depth < 1 then todo[#todo + 1] = {ip, depth + 1} end
          end
        end
      end
    end
  end
  return out
end

-- every definition of the game that starts somewhere: path, name, world, start, main quest, the quest files it
-- starts and the story's quests among them (sessions.definitions; kept in data\sessions.json)
function SE.definitions(depot, story_data, rebuild)
  local J = require("conjunction.json")
  local Y = require("conjunction.yaml")
  if not rebuild and w3.fs.exists(SE.cache()) then
    local ok, got = pcall(J.read, SE.cache())
    if ok and type(got) == "table" then return got end
  end
  local SB = require("conjunction.story_build")
  local TR = require("conjunction.cr2w_tree")
  depot = depot_of(depot)
  local data = story_data or require("conjunction.story").load() or {quests = {}}
  local owner, by_id = {}, {}
  for _, q in ipairs(data.quests) do by_id[q.id] = q end
  for _, q in ipairs(data.quests) do
    local files = P.T(P.get(q, "files")) and q.files or {P.get(q, "file")}
    for _, f in ipairs(files) do
      if f ~= nil and f ~= Y.null then
        owner[f] = owner[f] or {}
        owner[f][q.id] = true
      end
    end
  end
  local containers = {[SB.ROOT] = true, ["quests\\witcher3_quest.w2quest"] = true}
  local paths = {}
  for _, p in ipairs(depot:glob("", ".redgame")) do if SB.game_file(p) then paths[#paths + 1] = p end end
  paths = PS.sorted(paths)
  local out = Y.list()
  for _, path in ipairs(paths) do
    local low, skip = PYS.lower(path), false
    for _, w in ipairs(SE.NOT_STARTS) do if low:find(w, 1, true) then skip = true end end
    local ok, t = false, nil
    if not skip then ok, t = pcall(TR.Tree, depot:read(path)) end
    local o = ok and t:obj(1) or nil
    if o and o.cls == "CWitcherGameResource" then
      local imps = t.f.imports
      local function imp(v)
        local k = handle(v)
        return (k and k > 0 and k <= #imps) and imps[k][1] or nil
      end
      local worlds = {}
      for _, w in ipairs(o:get("worlds") or {}) do worlds[#worlds + 1] = imp(TR.sget(w, "world")) or false end
      local sp = o:get("startingPoint")
      local main = imp(o:get("mainQuest"))
      local files = main and phase_files(depot, main) or {}
      local qs = {}
      for _, f in ipairs(files) do
        if not containers[f] then for j in pairs(owner[f] or {}) do qs[j] = true end end
      end
      local quests = {}
      for j in pairs(qs) do quests[#quests + 1] = j end
      quests = PS.sorted(quests)
      local name = path:match("([^\\]*)$"):gsub("%.[^.]*$", "")
      local code = SB.code_of(name)
      if code then
        local mine = {}
        for _, j in ipairs(quests) do if by_id[j].code == code then mine[#mine + 1] = j end end
        if #mine == 0 then
          for _, q in ipairs(data.quests) do if q.code == code then mine[#mine + 1] = q.id end end
        end
        quests = PS.sorted(mine)
      end
      local named = Y.list()
      for _, w in ipairs(worlds) do if w then named[#named + 1] = w end end
      local start = Y.null
      if sp ~= nil and sp.position then
        start = Y.list()
        for i, v in ipairs(sp.position) do start[i] = v end
      end
      out[#out + 1] = Y.map({"path", path, "name", name, "world", worlds[1] or Y.null, "worlds", named,
                             "start", start, "quest", main or Y.null, "files", Y.list(files),
                             "quests", Y.list(quests),
                             "story", low:sub(1, 5) == "game\\" or (code == nil and #quests >= SE.MANY)})
    end
  end
  local tmp = SE.cache() .. ".tmp"
  J.write(tmp, out, {indent = 1})
  w3.fs.remove(SE.cache())
  w3.fs.rename(tmp, SE.cache())
  return out
end
function SE.for_quest(q, defs)
  local out = {}
  for _, d in ipairs(defs) do
    local has = false
    for _, id in ipairs(d.quests or {}) do if id == q.id then has = true end end
    if has and not d.story then out[#out + 1] = d end
  end
  return out
end
function SE.story_starts(defs)
  local out = {}
  for _, d in ipairs(defs) do if d.story then out[#out + 1] = d end end
  return out
end

local function done(f)
  local low = PYS.lower(f)
  for _, w in ipairs(SE.DONE) do if low:find(w, 1, true) then return true end end
  return false
end
local function base_name(path) return (path:match("([^\\/]*)$")) end

-- where a jump to the map's quest q goes (sessions.plan): its region's world (an expansion's own), its act's entry
-- in the base game, the facts it and every quest before it wait for and those they set that read as 'done'
function SE.plan(q, quests)
  local world = SE.WORLD_OF[q.world] or (q.game == "Blood and Wine" and "bob" or "novigrad")
  local act = q.act
  local base = q.game == "The Witcher 3" or q.game == "Free DLC"
  if not act and base then                      -- (a side quest: its main quests' act)
    local best
    for _, b in ipairs(q.by or {}) do
      local a = quests[b] and quests[b].act
      if a and SE.ENTRY_OF_ACT[a] then
        local i
        for k, n in ipairs(SE.ENTRY_ORDER) do if n == a then i = k end end
        if best == nil or i > best[1] then best = {i, a} end
      end
    end
    act = best and best[2] or "Act I"
  end
  local entry = base and SE.ENTRY_OF_ACT[act] or nil
  local facts, seen = {}, {[q.id] = true}
  for _, g in ipairs(P.list(q.gates)) do facts[g] = true end
  local todo = {}
  for _, b in ipairs(q.by or {}) do todo[#todo + 1] = b end
  while #todo > 0 do
    local b = table.remove(todo)
    if not seen[b] and quests[b] then
      seen[b] = true
      local before = quests[b]
      for _, g in ipairs(P.list(before.gates)) do facts[g] = true end
      for _, f in ipairs(P.list(before.sets)) do if done(f) then facts[f] = true end end
      for _, x in ipairs(before.by or {}) do todo[#todo + 1] = x end
    end
  end
  local code = P.str(q.code or "")
  if code == "" then code = (base_name(P.str(q.file or "~")):match("^([^_]*)")) or "" end
  if code == "" then code = "~" end
  local own = PYS.lower(code)
  local out = {}
  for f in pairs(facts) do
    local trimmed = f:gsub("^_+", ""):gsub("_+$", "")
    if trimmed:find("_", 1, true) and f:sub(1, 1) ~= "_" and PYS.lower(f):sub(1, #own) ~= own then out[#out + 1] = f end
  end
  return world, entry, PS.sorted(out)
end

-- a fresh session in a world of ours, at the story's entry (nil: no story), with the facts set (sessions.jump)
function SE.jump(ed, world, entry, facts)
  ed:exec("cj_session_clear()")
  local all = {}
  for _, f in ipairs(facts or {}) do all[#all + 1] = f end
  if entry then all[#all + 1] = SE.entry_fact(entry) end
  for _, f in ipairs(all) do ed:exec(string.format('cj_session_fact("%s")', f)) end
  ed:exec(string.format('cj_new_session("%s")', (SE.world_def(world):gsub("\\", "/"))))
end
function SE.start(ed, path)
  ed:exec("cj_session_clear()")
  ed:exec(string.format('cj_new_session("%s")', (path:gsub("\\", "/"))))
end

-- --- a project in a session of its own (MaximdeWinter 14.11.: Conjunction never loads or makes a save of the player's - a
-- project is worked on in a session from the game's files, started from the game's main menu; the editor opens it
-- there, saving is locked). No story entry: CDPR's start asks for the choices of The Witcher 2 when the story is
-- entered (a test questionnaire of theirs) - without it the session stands free in the world.
SE.MARK = "session_start.json"                -- in data: {project, world, time} - the editor takes it (editor.session)
SE.MARK_FRESH = 600                           -- s: an older mark is a session that never came
local WORLD_ALIAS = {velen = "novigrad", no_mans_land = "novigrad", white_orchard = "prolog_village",
                     toussaint = "bob", kaermorhen = "kaer_morhen"}
-- the session world of a project: its first place's world (a project of no world: Velen)
function SE.world_of(project)
  for _, name in ipairs(Y.keys(project.places or {})) do
    local w = P.str(P.get(project.places[name], "world") or "")
    if w ~= "" then
      local key = PYS.lower(w)
      local ok, paths = pcall(function() return require("conjunction.project").world_paths() end)
      local path = ok and paths[w] or nil
      if path then
        local parts = {}
        for part in (path .. "\\"):gmatch("(.-)\\") do parts[#parts + 1] = part end
        key = parts[#parts - 1] or key
      end
      key = WORLD_ALIAS[key] or key
      if SE.WORLD_DEFS[key] then return key end
    end
  end
  return "novigrad"
end
-- o: play (Build & Play: playing, not editing, where = {x, y, z} the player stood), later (the game starts again
-- first: the main menu starts it by itself - start_menu), reload (Build & Play loads the session's own save: the
-- mark only)
function SE.start_project(path, exec, o)
  exec, o = exec or w3.exec, o or {}
  local PR = require("conjunction.project")
  local pr = PR.open(path)
  local world = SE.world_of(pr)
  PR.remember(path)
  local PATHS = require("conjunction.paths")
  w3.fs.mkdir(PATHS.DATA)
  w3.fs.write(PATHS.DATA .. "\\" .. SE.MARK, require("conjunction.json").encode({
    project = path, world = world, time = os.time(), play = o.play == true, where = o.where, later = o.later == true}))
  if not (o.later or o.reload) then SE.launch(world, exec) end
  return world
end
function SE.launch(world, exec)
  exec = exec or w3.exec
  exec("cj_session_clear()")
  exec(string.format('cj_new_session("%s")', (SE.world_def(world):gsub("\\", "/"))))
end
local function read_mark()
  local path = require("conjunction.paths").DATA .. "\\" .. SE.MARK
  local text = w3.fs.read(path)
  if not text then return nil, path end
  local ok, m = pcall(require("conjunction.json").decode, text)
  if not ok or type(m) ~= "table" or type(m.project) ~= "string" then return nil, path end
  if os.time() - (tonumber(m.time) or 0) > SE.MARK_FRESH then return nil, path end
  return m, path
end
-- the mark as it is (it stays) -> {project, world, time, play, where, later} or nil
function SE.peek_mark() return (read_mark()) end
-- the mark of a session started for a project (taken: it goes) -> the mark or nil
function SE.take_mark()
  local m, path = read_mark()
  if w3.fs.exists(path) then w3.fs.remove(path) end
  return m
end

-- --- our own starts: a definition for each world, one main quest that goes where the session's facts say
SE.JUMP = [[conjunction\sessions\jump.w2quest]]
SE.MOD = "modConjunctionSessions"
SE.MAIN = [[quests\witcher3_quest.w2quest]]
SE.IF_FACT = {[[quests\witcher3_structure.w2phase]], "part1_skellige_start"}   -- a condition block on a fact: the model
-- each world's definition: the game's definition it is made from, the one whose starting point it takes
SE.WORLD_DEFS = {
  kaer_morhen = {[[game\witcher3.redgame]], [[game\witcher3.redgame]]},
  novigrad = {[[game\witcher3.redgame]], [[game\hub_definitions\novigrad_part1.redgame]]},
  prolog_village = {[[game\witcher3.redgame]], [[quests\prologue\quest_files\q001_beggining\q001_after_nightmare.redgame]]},
  skellige = {[[game\witcher3.redgame]], [[game\game_parts_definitions\endgame_review.redgame]]},
  bob = {[[dlc\bob\data\quests\bob_toussaint_tech_def.redgame]], [[dlc\bob\data\quests\bob_toussaint_tech_def.redgame]]},
}

-- the story structure's inputs (prologue, part 1, ... endgame, epilogues): where a jump can go in
function SE.entries(depot)
  local V = require("conjunction.vanilla_graph")
  local g = V.QuestFile(depot_of(depot), require("conjunction.story_build").ROOT):graph()
  local blocks = {}
  for _, b in pairs(g.blocks) do
    if b.cls == "CQuestPhaseInputBlock" and b.name ~= nil and b.name ~= "" then blocks[#blocks + 1] = b end
  end
  table.sort(blocks, function(a, b) return a.n < b.n end)
  local out = {}
  for i, b in ipairs(blocks) do out[i] = b.name end
  return out
end

local function clear_blocks(o)        -- a block's links out taken (its cachedConnections' blocks emptied)
  for _, c in ipairs(o:get("cachedConnections") or {}) do
    for _, x in ipairs(c) do
      if x.name == "blocks" then for i = #x.value, 1, -1 do x.value[i] = nil end end
    end
  end
end

-- the main quest of our starts: at its start the session's facts set (CjSessionFacts: what Conjunction put on the
-- game object before asking for the session), then a fact test per story entry (cj_entry_<entry>) - true: into the
-- structure there; none true: no story at all (the world alone) -> the file's bytes
function SE.jump_quest(depot)
  depot = depot_of(depot)
  local TR = require("conjunction.cr2w_tree")
  local VE = require("conjunction.vanilla_edit")
  local e = VE.Editor(depot, SE.MAIN)
  local src = TR.Tree(depot:read(SE.IF_FACT[1]))
  local model
  for k, o in ipairs(src.objects) do
    if o.cls == "CQuestConditionBlock" and src:obj(handle(o:get("questCondition"))):get("factId") == SE.IF_FACT[2] then
      model = k
      break
    end
  end
  local g = e.qf:graph()
  local start, phase
  for _, n in ipairs(g.order) do
    local b = g.blocks[n]
    if not start and b.cls == "CQuestStartBlock" then start = n end
    if not phase and b.cls == "CQuestPhaseBlock" then phase = n end
  end
  local graph = e.qf.root
  local links = {}
  for i, l in ipairs(g.links) do links[i] = l end
  for _, l in ipairs(links) do e:disconnect(l[1], l[2], l[3], l[4]) end
  local names = SE.entries(depot)
  local tests = e:change(function(t)
    local made = {}
    for _, name in ipairs(names) do
      local n = t:adopt(src, model, graph)
      local o = t:obj(n)
      o:set("name", "If " .. SE.entry_fact(name))
      clear_blocks(o)
      t:obj(handle(o:get("questCondition"))):set("factId", SE.entry_fact(name))
      local gb = t:obj(graph):get("graphBlocks")
      gb[#gb + 1] = n
      made[#made + 1] = n
    end
    return made
  end)
  local script = e:change(function(t)               -- (a script block of the structure's: its function ours)
    local model_script
    for k, o in ipairs(src.objects) do if o.cls == "CQuestScriptBlock" then model_script = k break end end
    local n = t:adopt(src, model_script, graph)
    local o = t:obj(n)
    o:set("functionName", "CjSessionFacts")
    o:set("parameters", TR.Array({}))
    o.args = {}
    for _, p in ipairs(o.props) do
      if p.name == "comment" or p.name == "caption" then p.value = "session facts" end
    end
    clear_blocks(o)
    local gb = t:obj(graph):get("graphBlocks")
    gb[#gb + 1] = n
    return n
  end)
  e:connect(start, "", script, "In")
  e:connect(script, "Out", tests[1], "In")
  for k, n in ipairs(tests) do
    e:connect(n, "True", phase, names[k])
    if k < #tests then e:connect(n, "False", tests[k + 1], "In") end
  end
  return e.data
end

-- our definition for a world: the game's (its worlds, the chosen one first), the starting point of a game definition
-- that starts there, our main quest, no intro film -> the file's bytes
function SE.world_definition(depot, world)
  depot = depot_of(depot)
  local TR = require("conjunction.cr2w_tree")
  local base, starting = SE.WORLD_DEFS[world][1], SE.WORLD_DEFS[world][2]
  local t = TR.Tree(depot:read(base))
  local o = t:obj(1)
  local worlds = o:get("worlds") or {}
  local imps = t.f.imports
  for i, w in ipairs(worlds) do
    local k = handle(TR.sget(w, "world"))
    local hit = false
    if k and k > 0 then
      for part in (PYS.lower(imps[k][1]) .. "\\"):gmatch("(.-)\\") do if part == world then hit = true end end
    end
    if hit then
      table.remove(worlds, i)
      table.insert(worlds, 1, w)
      break
    end
  end
  local sp = TR.Tree(depot:read(starting)):obj(1):get("startingPoint")
  if sp ~= nil then o:set("startingPoint", sp, "EngineTransform") end
  local keep = {}
  for _, p in ipairs(o.props) do if p.name ~= "newGameLoadingVideo" then keep[#keep + 1] = p end end
  o.props = keep
  imps[handle(o:get("mainQuest"))][1] = SE.JUMP
  return t:to_bytes()
end

-- the mod's files: {path = bytes}
function SE.mod_files(depot)
  depot = depot_of(depot)
  local files = {[SE.JUMP] = SE.jump_quest(depot)}
  for _, world in ipairs(SE.WORLDS) do files[SE.world_def(world)] = SE.world_definition(depot, world) end
  return files
end

-- our starts into the game: <game>\Mods\modConjunctionSessions (a bundle of the jump quest and a definition per
-- world). The game reads it at its start -> the files' paths
function SE.build_mod(depot, game_dir, log)
  log = log or print
  local FS = require("conjunction.fsutil")
  local PK = require("conjunction.packer")
  local MS = require("conjunction.metastore")
  local files = SE.mod_files(depot)
  local tmp = w3.fs.folder("temp") .. "\\cj_sessions_" .. require("conjunction.marks").uuid4_hex():sub(1, 10)
  local ok, err = pcall(function()
    local paths = {}
    for path, data in pairs(files) do
      local dest = tmp .. "\\" .. path
      w3.fs.mkdir(dest:match("^(.*)\\[^\\]+$"))
      assert(w3.fs.write(dest, data))
      paths[#paths + 1] = path
    end
    local content = game_dir .. "\\Mods\\" .. SE.MOD .. "\\content"
    w3.fs.mkdir(content)
    local bundle = PK.pack(tmp, content)
    assert(w3.fs.write(content .. "\\metadata.store", MS.build({{bundle:match("([^\\]+)$"), bundle}})))
    log(string.format("[sessions] %d files -> %s", #paths, content))
    files = PS.sorted(paths)
  end)
  FS.rmtree(tmp)
  if not ok then error(err, 0) end
  return files
end

-- the sessions mod in the game when it is not there yet (setup.install_scripts) -> true when it was made
function SE.ensure_mod(game_dir)
  if game_dir == nil or game_dir == "" then return false end
  if w3.fs.exists(game_dir .. "\\Mods\\" .. SE.MOD .. "\\content\\metadata.store") then return false end
  SE.build_mod(nil, game_dir, function() end)
  return true
end

return SE
