-- Build & Play into the running game (editor.live_play, done in full): the new run (<id>r<n>) built and installed
-- while the game runs; the runs before and every other project's DLC switched off for the DLC manager (EnableDLC:
-- their quests stay out of the next load, as the game's DLC menu does it); the new run's folder mounted and
-- registered (TW3SE livedlc); the project's clean save loaded by its name - a save from before any run of the quest
-- was in the game, so only the new run starts - the places of the runs before hidden, the player put back where they
-- stood. Without a clean save, as before: the runs before step aside (<id>_retired), a quick save, loaded again. The folders of the runs before and of the others leave the game folder at
-- its next start, before the engine looks at it (cj_core: _conjunction_parked\pending.txt), the runs into the
-- project's versions afterwards (PL.finish_parked).
--   PL.build_and_play(ed, log, test_from)   (in a coroutine: ed:job)      PL.finish_parked(project_path, log)
-- A quest that changes the game's own files (a mod bundle) is built and installed; the game takes the bundle only at a
-- start - it starts again by itself (PL.restart), as the app restarts it.
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local CFG = require("conjunction.config")
local PL = {}

PL.RETIRE_VERSION = 3     -- editor.RETIRE_VERSION: 3 - its places first, its people kept out (CjRunGoneKeep)
PL.SAVE_WAIT, PL.MOUNT_WAIT, PL.LOAD_WAIT, PL.REGISTER_WAIT = 15, 3, 600, 60
-- the saves loaded, counted (TW3SE's on_load): the live path knows a load happened (nil: an older TW3SE)
PL.loads = nil
if w3.on_load then
  PL.loads = 0
  w3.on_load(function() PL.loads = PL.loads + 1 end)
end

local function now() return w3.time and w3.time() or os.time() end
-- the coroutine waits (the game goes on) for s seconds, or until done() says so -> done()'s answer
local function wait(s, done)
  local t = now()
  while now() - t < s do
    if done then
      local r = done()
      if r then return r end
    end
    if coroutine.isyieldable() then coroutine.yield() else break end
  end
  return done and done() or nil
end

-- the game's folder in Documents (its saves): Windows' own Documents, also when moved (OneDrive) - the game asks
-- Windows the same way
function PL.game_docs()
  return os.getenv("CJ_GAME_DOCS") or (require("conjunction.paths").DOCUMENTS .. "\\The Witcher 3")
end

-- the runs of this quest whose DLCs are in the game's dlc folder: {{folder, quest id, run}}
function PL.old_runs(project, game)
  local base, current = project:base_id(), project:id()
  local out = {}
  for _, e in ipairs(w3.fs.list(game .. "\\dlc") or {}) do
    local low = PYS.lower(e.name)
    if e.dir and low:sub(1, 3 + #base) == "dlc" .. base and low ~= "dlc" .. current then
      local rest = low:sub(4 + #base)
      local n = rest == "" and 0 or rest:match("^r(%d+)$")
      if n then out[#out + 1] = {e.name, low:sub(4), math.tointeger(tonumber(n)) or 0} end
    end
  end
  return out
end

-- a new run of the quest (project.id: <id>r<n>): to the game a new quest, started from the beginning or the step
function PL.fresh_run(project, log)
  local meta = project.meta
  meta.run = (math.tointeger(tonumber(P.get(meta, "run") or 0)) or 0) + 1
  meta.stamp = os.time()
  if meta.live_from == nil then meta.live_from = meta.run end
  if (math.tointeger(tonumber(P.get(meta, "gone_version") or 0)) or 0) < PL.RETIRE_VERSION then
    meta.gone_from, meta.gone_version = meta.run, PL.RETIRE_VERSION
  end
  project:save_meta()
  log(string.format("[play] Run %d of the quest", meta.run))
end

-- the folders to leave the game folder at its next start (before the engine mounts them): {{from, to}} relative to
-- the game's folder, added to what is there already
function PL.park_later(game, moves)
  if #moves == 0 then return end
  local dir = game .. "\\_conjunction_parked"
  local file = dir .. "\\pending.txt"
  require("conjunction.build").makedirs(dir)
  local have, lines = {}, {}
  for line in ((w3.fs.read(file) or "") .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    if line ~= "" and not have[line] then have[line] = true lines[#lines + 1] = line end
  end
  for _, m in ipairs(moves) do
    local line = m[1] .. "\t" .. m[2]
    if not have[line] then have[line] = true lines[#lines + 1] = line end
  end
  assert(w3.fs.write(file, table.concat(lines, "\n") .. "\n"))
end

-- the runs a start parked (_conjunction_parked\runs\<folder>, marked as this project's) into the project's versions
function PL.finish_parked(project_path, log)
  log = log or print
  local game = CFG.load().game or ""
  local runs = game .. "\\_conjunction_parked\\runs"
  local PR = require("conjunction.project")
  local J = require("conjunction.json")
  local key = PYS.lower((project_path:gsub("/", "\\")))
  local done = {}
  for _, e in ipairs(w3.fs.list(runs) or {}) do
    if e.dir then
      local mark = w3.fs.read(runs .. "\\" .. e.name .. "\\" .. require("conjunction.in_game").MARK)
      local ok, m = pcall(J.decode, mark or "")
      local whose = ok and type(m) == "table" and m.project
      if type(whose) == "string" and PYS.lower((whose:gsub("/", "\\"))) == key then
        local name = e.name:gsub("%.%d+$", "")
        local part = PYS.lower(name):sub(1, 6) == "moddlc" and "mod" or "dlc"
        local ok2, err = pcall(PR.park_run, project_path, runs, e.name, part)
        if ok2 then done[#done + 1] = e.name
        else log("[in game] " .. e.name .. " not into the versions: " .. tostring(err)) end
      end
    end
  end
  if #done > 0 then
    PR.prune_versions(project_path)
    log("[in game] older runs into the project's versions: " .. table.concat(done, ", "))
  end
  return done
end

-- the newest save file (its time, its name)
local function newest_save()
  local folder = PL.game_docs() .. "\\gamesaves"
  local best, name = 0, nil
  for _, e in ipairs(w3.fs.list(folder) or {}) do
    if e.name:sub(-4) == ".sav" then
      local t = w3.fs.mtime(folder .. "\\" .. e.name) or 0
      if t > best then best, name = t, e.name end
    end
  end
  return best, name
end

-- the game's answers (CjOut lines) while a step waits for one
local listen = {}
function PL.heard(line) for _, f in ipairs(listen) do f(line) end end
local function hear(f) listen[#listen + 1] = f return function() for i, g in ipairs(listen) do if g == f then table.remove(listen, i) end end end end

-- quick save and wait for it: a save file newer than the request
function PL.quicksave(ed, log)
  local before = newest_save()
  local locked = false
  local stop = hear(function(line) if line == "save|locked" then locked = true end end)
  ed:exec("cj_quicksave()")
  log("[play] quick save ...")
  local saved = wait(PL.SAVE_WAIT, function()
    if locked then return "locked" end
    local t, name = newest_save()
    if t > before and os.time() - t > 0.5 then return name end
  end)
  stop()
  if saved and saved ~= "locked" then log("[play] saved: " .. saved)
  else log("[play] No save confirmation, continuing with the last save") end
  return saved ~= "locked" and saved or nil
end

-- the session's own save (Build & Play in a session): saving unlocked for it, a manual save of its own -> its
-- name or nil; PL.forget_save takes it out of the game's saves once loaded (MaximdeWinter 14.11.: nothing of a test run
-- stays among the player's saves)
function PL.session_save(ed, log)
  local before = newest_save()
  local locked = false
  local stop = hear(function(line) if line == "save|locked" then locked = true end end)
  ed:exec("cj_session_save()")
  local saved = wait(PL.SAVE_WAIT, function()
    if locked then return "locked" end
    local t, name = newest_save()
    if t > before and os.time() - t > 0.5 then return name end
  end)
  stop()
  if saved == "locked" then log("[play] The game does not save right now") return nil end
  if not saved then log("[play] No save") end
  return saved
end
function PL.forget_save(name)
  local folder = PL.game_docs() .. "\\gamesaves\\" .. name:gsub("%.sav$", "")
  for _, ext in ipairs({".sav", ".png", ".json"}) do
    if w3.fs.exists(folder .. ext) then w3.fs.remove(folder .. ext) end
  end
end

-- --- the project's clean save (Build & Play in one run, MaximdeWinter 23.10.): a save from before any run of the quest was
-- in the game. Loaded by its name after the new run is mounted, only that run starts - the runs before are switched
-- off and their places hidden, nothing of them is in that save (measured in the background game: one Anna, the new
-- chest filled). Kept aside in data\bases\<project>\ (the game reuses its save slots) and put back before a load.
PL.BASES = require("conjunction.paths").DATA .. "\\bases"
local function bases_file() return PL.BASES .. "\\bases.json" end
local function bases_read()
  local J = require("conjunction.json")
  local ok, t = pcall(J.read, bases_file())
  return ok and type(t) == "table" and t or {}
end
-- the project's clean save (its name, without .sav), or nil
function PL.base_of(base_id)
  local name = bases_read()[base_id]
  if type(name) ~= "string" or not w3.fs.exists(PL.BASES .. "\\" .. base_id .. "\\" .. name .. ".sav") then
    return nil
  end
  return name
end
local function save_files(name)
  local out = {}
  for _, ext in ipairs({".sav", ".json", ".png"}) do out[#out + 1] = name .. ext end
  return out
end
-- a save of the game kept aside as the project's clean save
function PL.keep_base(base_id, name, log)
  local folder = PL.BASES .. "\\" .. base_id
  local saves = PL.game_docs() .. "\\gamesaves"
  w3.fs.mkdir(PL.BASES)
  w3.fs.mkdir(folder)
  for _, f in ipairs(w3.fs.list(folder) or {}) do w3.fs.remove(folder .. "\\" .. f.name) end
  for _, f in ipairs(save_files(name)) do
    if w3.fs.exists(saves .. "\\" .. f) then assert(w3.fs.copy(saves .. "\\" .. f, folder .. "\\" .. f)) end
  end
  local all = bases_read()
  all[base_id] = name
  assert(w3.fs.write(bases_file(), require("conjunction.json").encode(all)))
  log("[play] clean save of this quest kept: " .. name)
end
-- the clean save among the game's saves again (the game may have reused its slot meanwhile)
function PL.put_base_back(base_id, name)
  local folder = PL.BASES .. "\\" .. base_id
  local saves = PL.game_docs() .. "\\gamesaves"
  for _, f in ipairs(save_files(name)) do
    if w3.fs.exists(folder .. "\\" .. f) and not w3.fs.exists(saves .. "\\" .. f) then
      w3.fs.copy(folder .. "\\" .. f, saves .. "\\" .. f)
    end
  end
end
-- the newest save of the game older than t (a time stamp), or nil
function PL.save_before(t)
  local folder = PL.game_docs() .. "\\gamesaves"
  local best, name = 0, nil
  for _, e in ipairs(w3.fs.list(folder) or {}) do
    if e.name:sub(-4) == ".sav" then
      local m = w3.fs.mtime(folder .. "\\" .. e.name) or 0
      if m < t and m > best then best, name = m, e.name:sub(1, -5) end
    end
  end
  return name
end
-- when a run of the project still in the game came into it: its DLC folder's time (a run gone from the game folder
-- is gone from every save as it loads), nil when there is none
function PL.first_run_time(project, game)
  local base = PYS.lower(project:base_id())
  local first
  local function seen(t) if t and (not first or t < first) then first = t end end
  for _, e in ipairs(w3.fs.list(game .. "\\dlc") or {}) do
    if e.dir and PYS.lower(e.name):sub(1, 3 + #base) == "dlc" .. base then
      seen(w3.fs.mtime(game .. "\\dlc\\" .. e.name))
    end
  end
  return first
end
-- a run's layer groups: its places (those of the project now and of the run kept in the versions) and its meta layer
-- per world - hidden after the clean save loaded, the run's things are not in the world (its quest does not run, the
-- layers of a DLC folder are part of the world all the same)
function PL.run_groups(project, run_id)
  local Y2 = require("conjunction.yaml")
  local places, worlds = {}, {}
  local function add(name, world)
    places[name] = true
    if world and world ~= "" then worlds[world] = true end
  end
  for name, p in pairs(project.places or {}) do add(name, p.world) end
  local kept = project.path .. "\\versions\\" .. run_id .. "\\project\\places"
  for _, e in ipairs(w3.fs.list(kept) or {}) do
    if e.name:sub(-4) == ".yml" then
      local ok, p = pcall(Y2.read, kept .. "\\" .. e.name)
      add(e.name:sub(1, -5), ok and type(p) == "table" and p.world or nil)
    end
  end
  local out = {}
  for name in pairs(places) do out[#out + 1] = "DLC\\dlc" .. run_id .. "\\" .. run_id .. "\\" .. name end
  local root = "DLC\\dlc" .. run_id .. "\\" .. run_id .. "\\"
  for w in pairs(worlds) do out[#out + 1] = root .. run_id .. "_meta_" .. w end
  table.sort(out)
  return out
end

-- the game closed and started again (editor._close_game, _start_game): a hidden PowerShell the game starts ends
-- the game, waits until it is gone and starts it again (PL.restart_script: through Steam for Steam's game - a
-- witcher3.exe started on its own hung at the main menu and missed the cloud's saves). Its main menu starts the project's session by itself
-- (sessions.start_project with later, start_menu); cj_core moves out what pending.txt names before the engine mounts it.
PL.RESTART_PS = [[
$me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$game = Get-Process -Id $me.ParentProcessId
Start-Sleep -Milliseconds 1500
Stop-Process -Id $game.Id -Force
$game.WaitForExit(30000) | Out-Null
Start-Sleep -Milliseconds 1000
START
]]
-- how the game starts again: through Steam when it is Steam's (steam_api64.dll beside the exe), else its exe (GOG)
function PL.restart_script()
  local exe = w3.fs.folder("game") .. "\\bin\\x64_dx12\\witcher3.exe"
  local steam = w3.fs.exists(w3.fs.folder("game") .. "\\bin\\x64_dx12\\steam_api64.dll")
  local start = steam and "Start-Process 'steam://rungameid/292030'" or
                ("Start-Process -FilePath '" .. exe:gsub("'", "''") .. "' -WorkingDirectory '" ..
                 (exe:match("^(.*)\\[^\\]+$")):gsub("'", "''") .. "'")
  return (PL.RESTART_PS:gsub("START", function() return start end))
end
-- play: the game comes back playing, not editing (MaximdeWinter 23.10.: after Build & Play the quest is to be played) - a
-- mark the editor takes at its start (PL.play_after_start)
PL.PLAY_MARK = "play_after_start.txt"
function PL.restart(log, play)
  local PATHS = require("conjunction.paths")
  if play then
    w3.fs.mkdir(PATHS.DATA)
    w3.fs.write(PATHS.DATA .. "\\" .. PL.PLAY_MARK, tostring(os.time()))
  end
  local file = (os.getenv("TEMP") or PL.game_docs()) .. "\\conjunction_restart.ps1"
  assert(w3.fs.write(file, PL.restart_script()))
  log("[play] the game restarts")
  local p = w3.proc.run(string.format('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s"',
                                      file))
  if not p then log("[play] the build is installed. The game could not restart itself, please close and start it") end
  return p ~= nil
end

-- the editor's start: was the game started again by Build & Play (PL.restart with play, at most 15 minutes ago)?
-- The mark goes either way
function PL.play_after_start()
  local path = require("conjunction.paths").DATA .. "\\" .. PL.PLAY_MARK
  local t = tonumber(w3.fs.read(path) or "")
  if w3.fs.exists(path) then w3.fs.remove(path) end
  return t ~= nil and os.time() - t < 15 * 60
end

-- --- nothing of the quest under the ground (editor.ground_check, 02.10.: a guide and the player under the ground -
-- heights guessed by a script): every person of the project's places in the player's world, near enough to be loaded,
-- measured against the ground there (cj_ground_z); more than GROUND_BELOW under it -> its height is the ground's, the
-- place is saved. Never lowers anything; decals and trails stay as they are. -> {{place, name, old z, new z}}
PL.GROUND_NEAR = 300.0      -- m around the player: loaded, its ground can be measured
PL.GROUND_BELOW = 0.25      -- m under the ground: lifted (less: sunk in on purpose, a log in the mud)
PL.GROUND_MAX = 2.5         -- m at most (more: a bridge or a roof above it, not its ground)
function PL.ground_check(ed, log, timeout)
  timeout = timeout or 5.0
  local PR = require("conjunction.project")
  local Q = require("conjunction.quest")
  local NUM = require("conjunction.pynum")
  ed.last_where, ed.last_world = nil, nil
  ed:exec("cj_where()")
  wait(timeout, function() return ed.last_where ~= nil end)
  if ed.last_where == nil then
    log("[ground] Player position unknown, not checked")
    return {}
  end
  local paths = PR.world_paths()
  local todo = {}
  local places = ed.project.places
  for _, name in ipairs(Y.keys(places)) do
    local p = places[name]
    local pw = P.get(p, "world")
    if not (ed.last_world and P.T(pw) and (paths[pw] or "") ~= ed.last_world) then
      for _, o in ipairs(P.get(p, "objects") or {}) do
        local pos = P.get(o, "pos")
        local skip = not P.T(pos) or P.T(P.get(o, "trail")) or
                     PYS.lower(P.str(P.get(o, "template") or "")):find("decal", 1, true) ~= nil
        if not skip and Q.is_actor(o) then
          local dx, dy = pos[1] - ed.last_where[1], pos[2] - ed.last_where[2]
          if math.sqrt(dx * dx + dy * dy) <= PL.GROUND_NEAR then todo[#todo + 1] = {name, o} end
        end
      end
    end
  end
  if #todo == 0 then return {} end
  local got
  ed.groundz_pending = function(out) got = out end
  local pts = {}
  for i, t in ipairs(todo) do
    local pos = t[2].pos
    pts[i] = string.format("%.3f,%.3f,%.3f", pos[1], pos[2], pos[3])
  end
  ed:exec('cj_ground_z("' .. table.concat(pts, ";") .. '")')
  wait(timeout, function() return got ~= nil end)
  ed.groundz_pending = nil
  got = got or {}
  local fixed, saved, order = {}, {}, {}
  for i, t in ipairs(todo) do
    local name, o = t[1], t[2]
    local gz = got[i]
    if gz ~= nil and gz ~= Y.null then
      local d = gz - o.pos[3]
      if d > PL.GROUND_BELOW and d <= PL.GROUND_MAX then
        local what = P.T(P.get(o, "id")) and o.id or (P.str(o.template):match("([^\\]*)$"))
        local new = NUM.round(gz, 3)
        fixed[#fixed + 1] = {name, what, o.pos[3], new}
        o.pos[3] = new
        if not saved[name] then saved[name] = true order[#order + 1] = name end
      end
    end
  end
  for _, name in ipairs(order) do ed.project:save_place(name) end
  for _, f in ipairs(fixed) do
    log(string.format("[ground] %s/%s was %.2f m under the ground, now on it (z %s -> %s)", f[1], P.str(f[2]),
                      f[4] - f[3], P.str(f[3]), P.str(f[4])))
  end
  return fixed
end

function PL.build_and_play(ed, log, test_from)
  local B = require("conjunction.build")
  local IG = require("conjunction.in_game")
  local PR = require("conjunction.project")
  local game = CFG.load().game
  local path = ed.project.path
  PL.ground_check(ed, log)                      -- (editor._pause_editing: nothing of the quest under the ground)
  local stood = ed.last_where                   -- (where the player stands: back there after the clean save)
  local project = PR.open(path)
  PL.fresh_run(project, log)
  ed.project = project
  local old = PL.old_runs(project, game)
  local others = IG.others_in(path, game)       -- (other projects' DLCs and mod bundles in the game)
  local packed
  local ok, err = pcall(function()
    packed = B.build(path, true, log, test_from, {live = true})
  end)
  if not ok then
    log("[play] Build failed")
    error(err, 0)
  end
  project = PR.open(path)
  ed.project = project
  -- what leaves the game folder at its next start: the runs before (into the versions after it), the others
  local moves = {}
  for _, r in ipairs(old) do
    moves[#moves + 1] = {"dlc\\" .. r[1], "_conjunction_parked\\runs\\" .. r[1]}
    local mod = "moddlc" .. r[2]
    if w3.fs.isdir(game .. "\\Mods\\" .. mod) then moves[#moves + 1] = {"Mods\\" .. mod, "_conjunction_parked\\runs\\" .. mod} end
  end
  for _, e in ipairs(others) do moves[#moves + 1] = {e.where .. "\\" .. e.folder, "_conjunction_parked\\" .. e.where .. "\\" .. e.folder} end
  PL.park_later(game, moves)
  -- the editor stays while it builds (MaximdeWinter 23.10.), it goes for the save
  if ed.editing then ed:set_editing(false) end
  ed:show_built()                               -- (the save must not keep the quest's people hidden)
  local mod = packed:gsub("[\\/][^\\/]*$", "") .. "\\packed_mod\\content"
  -- in a session (MaximdeWinter 14.11.: Conjunction never loads or makes a save of the player's): the session saved, the runs
  -- before switched off, the new one mounted and registered, the session's save loaded and deleted again; saving
  -- locked again (editor.session_arrived). Not in a session, or a quest that changes game files: the game starts
  -- again, its main menu starts the session (a new game started right after the live mount froze the engine for
  -- minutes, CGame::StartGame waiting on the renderer, 14.11.)
  local SE = require("conjunction.sessions")
  local bundle = w3.fs.isdir(mod) and #(w3.fs.list(mod) or {}) > 0
  local function restart()
    SE.start_project(path, nil, {play = true, where = stood, later = true})
    PL.restart(log)
  end
  if bundle then log("[play] a restart after all: the quest changes game files") end
  if bundle or not ed.session then return restart() end
  -- the runs before step aside at once (their watchers hide their places before the save)
  local quests = {}
  for _, r in ipairs(old) do quests[#quests + 1] = r[2] ed:exec(string.format('addfact("%s_retired", 1)', r[2])) end
  if #quests > 0 then wait(1.0) end
  local save = PL.session_save(ed, log)
  if not save then return restart() end
  -- switched off for the DLC manager: the runs before, the others (each DLC's id: dlc_<its quest id>)
  local off = {}
  for _, r in ipairs(old) do off[#off + 1] = "dlc_" .. r[2] end
  for _, e in ipairs(others) do
    if e.where == "dlc" and PYS.lower(e.folder):sub(1, 3) == "dlc" then off[#off + 1] = "dlc_" .. PYS.lower(e.folder):sub(4) end
  end
  local said = {}
  local stop = hear(function(line)
    local id, en = line:match("^dlc|([^|]*)|enabled=(%d)")
    if id then said[id] = en end
  end)
  for _, id in ipairs(off) do ed:exec(string.format("cj_dlc_enable('%s', false)", id)) end
  wait(2.0, function() for _, id in ipairs(off) do if said[id] == nil then return nil end end return true end)
  for _, id in ipairs(off) do
    if said[id] ~= "0" then log("[play] live: " .. id .. " could not be switched off (" .. tostring(said[id]) .. ")") end
  end
  if #off > 0 then log("[play] live: switched off: " .. table.concat(off, ", ")) end
  -- the runs before: their changes to the game's objects step aside as well (TW3SE reads every dlc's
  -- tw3se\world.txt at each load, switched off or not - 11.11.); the folders leave the game folder at the start anyway
  for _, r in ipairs(old) do
    local f = game .. "\\dlc\\" .. r[1] .. "\\tw3se\\world.txt"
    if w3.fs.exists(f) then
      if w3.fs.exists(f .. ".off") then w3.fs.remove(f .. ".off") end
      if not w3.fs.rename(f, f .. ".off") then log("[play] live: " .. f .. " could not step aside") end
    end
  end
  -- the new run mounted and registered (TW3SE: ~2 s after the mount)
  local mounted
  local scans0 = w3.dlc_scans and w3.dlc_scans() or nil
  local stop2 = hear(function(line) local r = line:match("^livedlc|(%d)") if r then mounted = r end end)
  ed:exec(string.format('cj_live_dlc("%s")', (game .. "\\dlc\\dlc" .. project:id()):gsub("\\", "/")))
  wait(5.0, function() return mounted end)
  stop2()
  local function again(why)
    stop()
    PL.forget_save(save)
    log("[play] a restart after all: " .. why)
    restart()
  end
  if mounted ~= "1" then return again("the extender could not load it") end
  -- until the extender has registered it (it counts game ticks: at a low frame rate far more than 2 s, MaximdeWinter 23.10.);
  -- an older TW3SE: the 3 s as before
  if scans0 then
    local registered = wait(PL.REGISTER_WAIT, function()
      local n, pending = w3.dlc_scans()
      return n > scans0 and not pending
    end)
    if not registered then return again("the game did not register the new run in time") end
    wait(1.0)                                   -- (the manager takes the scan in over the next ticks)
  else
    wait(PL.MOUNT_WAIT)
  end
  -- the session's save loaded (a load counted by TW3SE's on_load)
  local loads0 = PL.loads
  local function launch()
    SE.start_project(path, nil, {play = true, where = stood, reload = true})
    ed:exec(string.format('cj_load_save("%s")', save:gsub("%.sav$", "")))
  end
  launch()
  log("[play] Loading...")
  -- until the old world answers no more, then until the new one answers
  local function answers(s)
    local heard = false
    local st = hear(function(line) if line:sub(1, 6) == "where " then heard = true end end)
    ed:exec("cj_where()")
    wait(s, function() return heard end)
    st()
    return heard
  end
  -- -> began, loaded. Began: the old world went quiet or TW3SE counted a load (14.11.: the load came, on_load did
  -- not count it - asked once more, the save loaded twice)
  local function load_done()
    local t = now()
    local began = false
    while now() - t < 20 do
      if loads0 ~= nil and PL.loads > loads0 then began = true end
      if not answers(1.0) then began = true break end
      wait(1.0)
    end
    if not began then return false, false end
    t = now()
    while now() - t < PL.LOAD_WAIT do
      if answers(2.0) then return true, true end
    end
    return true, false
  end
  local began, loaded = load_done()
  if not began then
    launch()
    began, loaded = load_done()
  end
  if loaded then
    -- (the world may come back without a frame between: the mark taken here then)
    if SE.peek_mark() then ed:session_arrived() end
    for _, q in ipairs(quests) do ed:exec(string.format('addfact("%s_retired", 1)', q)) end
    for _, id in ipairs(off) do ed:exec(string.format("cj_dlc_state('%s')", id)) end
    wait(2.0)
    for _, id in ipairs(off) do
      if said[id] == "1" then log("[play] " .. id .. " came back with the load - close the game, its start parks it") end
    end
  end
  stop()
  PL.forget_save(save)
  log(loaded and "[play] Done. F8 opens the editor" or "[play] The save did not load")
end

return PL
