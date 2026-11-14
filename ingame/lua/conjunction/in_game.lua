-- Only the open project in the game (in_game.py): when a project is built into the game, the DLCs and mod bundles of
-- Conjunction's other projects are parked - moved beside the game's folders, never deleted. A project with
-- `always_in_game: true` stays, and so do Conjunction's own libraries.
--   IG.suite_folders(game, projects, also) -> {{folder, where = dlc | Mods, project = path | nil}}
--   IG.park_others(project_dir, log, game, projects) -> names parked     IG.park(entries, log, game)
--   IG.mark(folder, project_dir, qid, base)    IG.clear_for(project_dir, log, game, projects, dry, wait)
--   IG.parked(game)   IG.restore(name, log, game)
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local PYS = require("conjunction.pystr")
local IG = {}

IG.LIBRARIES = {dlcconjunctionmeshes = true, dlcconjunctionfoliage = true}
IG.TESTS = {["dlc|dlcw3sterraintest"] = true, ["dlc|dlcsuite_test_furniture"] = true,
            ["Mods|modconjunctionterraintest"] = true}
IG.MARK = "conjunction.json"     -- in each DLC and mod bundle Build & Play installs: {"project", "base", "id"}

local function game_of(game) return game or require("conjunction.config").load().game end
local function key(p) return PYS.lower((p:gsub("/", "\\"))) end
local function say(log, s) (log or print)(s) end

function IG.parked_root(game) return game_of(game) .. "\\_conjunction_parked" end

local function meta_of(folder)
  local p = folder .. "\\project.yml"
  if not w3.fs.exists(p) then return nil end
  local ok, m = pcall(Y.read, p)
  if not ok then return nil end
  return type(m) == "table" and m ~= Y.null and m or Y.map()
end

-- a project folder's id (its base id: the id of project.yml) - nil when it is no project
local function project_id(folder)
  local m = meta_of(folder)
  if not m then return nil end
  local id = m.id
  if id == nil or id == Y.null or id == false or id == "" then return nil end
  id = PYS.lower(require("conjunction.py").str(id))
  return id ~= "" and id or nil
end

-- {base id = project folder} of every project in the projects folder, and of the folders in more
local function projects_by_id(root, more)
  local out, list = {}, {}
  local names = {}
  for _, e in ipairs(w3.fs.isdir(root) and w3.fs.list(root) or {}) do names[#names + 1] = e.name end
  for _, n in ipairs(names) do list[#list + 1] = root .. "\\" .. n end
  for _, p in ipairs(more or {}) do list[#list + 1] = p end
  for _, path in ipairs(list) do
    local pid = project_id(path)
    if pid and out[pid] == nil then out[pid] = path end
  end
  return out
end

-- the projects Conjunction knows outside its projects folder: opened, added, its examples
local function known_elsewhere()
  local dirs = {}
  pcall(function()
    local cfg = require("conjunction.config").load()
    for _, k in ipairs({"recent", "projects_added"}) do
      for _, p in ipairs(type(cfg[k]) == "table" and cfg[k] or {}) do dirs[#dirs + 1] = p end
    end
  end)
  pcall(function()
    for _, e in ipairs(require("conjunction.project").examples()) do dirs[#dirs + 1] = e[2] end
  end)
  return dirs
end

local function marked(path)
  local s = w3.fs.read(path .. "\\" .. IG.MARK)
  if not s then return nil end
  local ok, m = pcall(J.decode, s)
  if not ok or type(m) ~= "table" or m == Y.null or Y.is_list(m) then return nil end
  return m
end

-- <prefix>(.+?)(r\d+)? -> the id part without the run's r<n> (nil when nothing follows the prefix)
local function id_part(low, prefix)
  if low:sub(1, #prefix) ~= prefix or #low <= #prefix then return nil end
  local rest = low:sub(#prefix + 1)
  return rest:match("^(.+)r%d+$") or rest
end
local function is_run_of(low, prefix, id)
  local rest = low:sub(#prefix + 1)
  if low:sub(1, #prefix) ~= prefix then return false end
  if rest == id then return true end
  return rest:sub(1, #id) == id and rest:sub(#id + 1):match("^r%d+$") ~= nil
end

function IG.suite_folders(game, projects, also)
  game = game_of(game)
  local more = {}
  if not projects then more = known_elsewhere() end
  if also then more[#more + 1] = also end
  local ids = projects_by_id(projects or require("conjunction.paths").PROJECTS, more)
  local out = {}
  for _, wp in ipairs({{"dlc", "dlc"}, {"Mods", "moddlc"}}) do
    local where, prefix = wp[1], wp[2]
    local root = game .. "\\" .. where
    local names = {}
    for _, e in ipairs(w3.fs.isdir(root) and w3.fs.list(root) or {}) do names[#names + 1] = e.name end
    table.sort(names)
    for _, d in ipairs(names) do
      local low = PYS.lower(d)
      -- (a quest installed to be played - the Library's, a mod manager's: its manifest and no mark of Build & Play -
      -- is no project's run, whatever its name; 14.11.: an author's own export, dlc<base id>, read as the project's
      -- run and would have gone into its versions)
      local played = w3.fs.exists(root .. "\\" .. d .. "\\conjunction_quest.yml") and
                     not w3.fs.exists(root .. "\\" .. d .. "\\" .. IG.MARK)
      if not IG.LIBRARIES[low] and not played then
        if IG.TESTS[where .. "|" .. low] then
          out[#out + 1] = {folder = d, where = where}
        else
          local m = marked(root .. "\\" .. d)
          if m then
            local p = m.project
            out[#out + 1] = {folder = d, where = where, project = (p ~= nil and p ~= Y.null and p ~= "") and p or nil}
          else
            local g1, whole = id_part(low, prefix), low:sub(#prefix + 1)
            if g1 and (ids[g1] or ids[whole]) then
              out[#out + 1] = {folder = d, where = where, project = ids[g1] or ids[whole]}
            end
          end
        end
      end
    end
  end
  return out
end

local function kept(project_dir)
  local m = meta_of(project_dir)
  return m ~= nil and require("conjunction.py").T(m.always_in_game)
end

-- move these folders beside the game's (<game>\_conjunction_parked\<dlc | Mods>) -> the names moved
function IG.park(entries, log, game)
  game = game_of(game)
  local done = {}
  for _, e in ipairs(entries) do
    local src = game .. "\\" .. e.where .. "\\" .. e.folder
    local dst_root = IG.parked_root(game) .. "\\" .. e.where
    if not w3.fs.isdir(dst_root) then w3.fs.mkdir(dst_root) end
    local dst = dst_root .. "\\" .. e.folder
    local k = 2
    while w3.fs.exists(dst) do                    -- (parked before: the older one keeps its name)
      dst = dst_root .. "\\" .. e.folder .. "." .. k
      k = k + 1
    end
    local ok, err = w3.fs.rename(src, dst)
    if ok then done[#done + 1] = e.folder
    else say(log, "[in game] " .. e.folder .. " stays (the game holds it - close the game): " .. tostring(err)) end
  end
  if #done > 0 then
    say(log, "[in game] parked (out of the world, in " .. IG.parked_root(game) .. "): " .. table.concat(done, ", "))
  end
  return done
end

-- the ids a project's DLC is named by (its id, and without the run's r<n>)
local function ids_of(project_dir)
  local m = meta_of(project_dir)
  if not m then return {} end
  local pid = m.id
  pid = (pid == nil or pid == Y.null or pid == false) and "" or PYS.lower(require("conjunction.py").str(pid))
  local out, seen = {}, {}
  local two = {pid, require("conjunction.py").T(m.run) and (pid:gsub("r%d+$", "")) or pid}
  for _, i in ipairs(two) do
    if i ~= "" and not seen[i] then seen[i] = true out[#out + 1] = i end
  end
  return out
end

local function others(project_dir, game, projects)
  local me = key(project_dir)
  local mine = ids_of(project_dir)
  local function own(e)
    if e.project and key(e.project) == me then return true end
    local low = PYS.lower(e.folder)
    local prefix = e.where == "dlc" and "dlc" or "moddlc"
    for _, i in ipairs(mine) do if is_run_of(low, prefix, i) then return true end end
    return false
  end
  local out = {}
  for _, e in ipairs(IG.suite_folders(game, projects)) do
    if not own(e) and not (e.project and kept(e.project)) then out[#out + 1] = e end
  end
  return out
end

-- every other project's DLC and mod bundle in the game (what park_others would move)
function IG.others_in(project_dir, game, projects) return others(project_dir, game, projects) end

-- every other project's DLC and mod bundle out of the game (not this project's, not those always in it)
function IG.park_others(project_dir, log, game, projects)
  return IG.park(others(project_dir, game, projects), log, game)
end

-- Conjunction's mark in an installed DLC or mod bundle: the game folder knows whose it is
function IG.mark(folder, project_dir, qid, base)
  local s = '{"project": ' .. J.encode(project_dir) .. ', "base": ' .. J.encode(base) .. ', "id": ' .. J.encode(qid) .. "}"
  assert(w3.fs.write(folder .. "\\" .. IG.MARK, s))
end

-- before the game starts: in its dlc and Mods only this project's current run (and what is always in the game);
-- its older runs go into its versions, every other project's is parked -> the folders that should go and are there
function IG.clear_for(project_dir, log, game, projects, dry, wait)
  game = game_of(game)
  wait = wait or 10.0
  local PR = require("conjunction.project")
  local project = PR.open(project_dir)
  local base, current = project:base_id(), project:id()
  local left = {}
  local t = os.time()
  local function pass()
    local own, oth = {}, {}
    for _, e in ipairs(IG.suite_folders(game, projects, project_dir)) do
      local low = PYS.lower(e.folder)
      local prefix = e.where == "dlc" and "dlc" or "moddlc"
      if is_run_of(low, prefix, base) then
        if low ~= prefix .. current then own[#own + 1] = e end
      elseif not (e.project and kept(e.project)) then
        oth[#oth + 1] = e
      end
    end
    return own, oth
  end
  while true do
    local own, oth = pass()
    left = {}
    for _, e in ipairs(own) do left[#left + 1] = e.folder end
    for _, e in ipairs(oth) do left[#left + 1] = e.folder end
    if dry or #left == 0 then return left end
    for _, e in ipairs(own) do
      local stage = IG.parked_root(game) .. "\\runs\\" .. e.folder
      local ok, err = pcall(function()
        if w3.fs.exists(stage) then require("conjunction.fsutil").rmtree(stage) end
        local up = stage:match("^(.*)\\[^\\]*$")
        if not w3.fs.isdir(up) then w3.fs.mkdir(up) end
        local r, why = w3.fs.rename(game .. "\\" .. e.where .. "\\" .. e.folder, stage)
        if not r then error(why or "held", 0) end
      end)
      if not ok then
        say(log, "[in game] " .. e.folder .. " is held: " .. tostring(err))
      else
        local ok2, err2 = pcall(PR.park_run, project.path, stage:match("^(.*)\\[^\\]*$"), e.folder,
                                e.where == "dlc" and "dlc" or "mod")
        if ok2 then say(log, "[in game] older run out of the game (in the project's versions): " .. e.folder)
        else say(log, "[in game] older run out of the game (" .. stage .. "; not in the versions: " .. tostring(err2) .. ")") end
      end
    end
    IG.park(oth, log, game)
    if #own > 0 then PR.prune_versions(project.path) end
    if os.time() - t > wait then break end
    local until_ = os.time() + 1
    while os.time() < until_ do if coroutine.isyieldable() then coroutine.yield() else break end end
  end
  left = IG.clear_for(project_dir, log, game, projects, true)
  if #left > 0 then say(log, "[in game] still in the game folder (a program holds them): " .. table.concat(left, ", ")) end
  return left
end

-- {{where, folder}} parked now
function IG.parked(game)
  local root = IG.parked_root(game)
  local out = {}
  for _, w in ipairs({"dlc", "Mods"}) do
    local names = {}
    for _, e in ipairs(w3.fs.isdir(root .. "\\" .. w) and w3.fs.list(root .. "\\" .. w) or {}) do names[#names + 1] = e.name end
    table.sort(names)
    for _, d in ipairs(names) do out[#out + 1] = {w, d} end
  end
  return out
end

-- a parked folder back into the game (its name without the '.2' of a second parking)
function IG.restore(name, log, game)
  game = game_of(game)
  local GEN = require("conjunction.questgen")
  for _, wd in ipairs(IG.parked(game)) do
    if wd[2] == name then
      local target = game .. "\\" .. wd[1] .. "\\" .. (wd[2]:gsub("%.%d+$", ""))
      if w3.fs.exists(target) then GEN.fail(target .. " is there already") end
      assert(w3.fs.rename(IG.parked_root(game) .. "\\" .. wd[1] .. "\\" .. wd[2], target))
      say(log, "[in game] back: " .. wd[2])
      return target
    end
  end
  GEN.fail("nothing parked as " .. name)
end

return IG
