-- Build a quest project into an installable DLC (build.py): encode -> link into the modkit depot -> cook -> pack ->
-- metadatastore -> strings -> install. Runs in a coroutine (the game goes on while radish and wcc_lite work): every
-- program call yields until it is done.
--   B.build(project, install, log, test_from, opts) -> the packed folder (opts.live: into the running game)      B.build_dlc(defdir, out, install, log, project, ...)
--   B.run({program, args ...}, cwd, log, harmless) -> its lines (an error when it failed)   B.call(args, cwd) -> exit code
-- What the app's build runs and the game's does not: Python plug-ins (their uncooked steps, CSV rows and build steps),
-- terrain painted in the editor (terrain.lua), the own quest as the quest graph changed it (step 8).
local Y = require("conjunction.yaml")
local J = require("conjunction.json")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local CFG = require("conjunction.config")
local FS = require("conjunction.fsutil")
local CR = require("conjunction.cr2w")
local B = {}

B.MISSING = "Hardlinked resource '([^']+)' for parent resource"
B.OURS_ONLY = {"left", "outside", "inside", "journal", "period", "present", "combat", "actor", "scripted", "all",
               "any", "nor", "action"}   -- (action: the interaction a wait on a thing of the world names)
B.RADISH_ZIP = "radish.modding.tools-v2020-11-21-3620-v2020-11-21-1606002572.zip"
B.RTTI_FILE = "rtti-conjunction.repo.yml"
B.RTTI = [[# Conjunction (conjunction): engine classes radish does not list
rtti:
  classes:
    CTriggerAreaEnvironmentVisibilityComponent:
      .extends: CTriggerAreaComponent
      .adds:
        hideTerrain: bool
        hideFoliage: bool
        hideWater: bool
]]

-- RuntimeError(msg): what build() tries again after (a resource REDkit does not find); the rest goes through
local RT = {__tostring = function(e) return e.runtime_error end}
function B.RuntimeError(msg) return setmetatable({runtime_error = msg}, RT) end
function B.fail(msg) error(B.RuntimeError(msg), 0) end
function B.is_runtime_error(e) return type(e) == "table" and getmetatable(e) == RT end
function B.message(e)
  if type(e) ~= "table" then return tostring(e) end
  return tostring(e.runtime_error or e.value_error or (e.key_error and ("KeyError: '" .. tostring(e.key_error) .. "'")) or e)
end

local function exists(p) return w3.fs.exists(p) end
local function GEN_need(d, k) return require("conjunction.questgen").need(d, k) end
local function isdir(p) return w3.fs.isdir(p) end
local function basename(p) return p:match("([^\\/]*)$") end
local function dirname(p) return p:match("^(.*)[\\/][^\\/]*$") or "" end
function B.makedirs(p)
  if p == "" or isdir(p) then return end
  B.makedirs(dirname(p))
  w3.fs.mkdir(p)
end
local function replace_file(path, data)
  assert(w3.fs.write(path .. ".tmp", data))
  if exists(path) then w3.fs.remove(path) end
  assert(w3.fs.rename(path .. ".tmp", path))
end
local function scratch(prefix)
  local d = (w3.fs.folder and w3.fs.folder("temp") or os.getenv("TEMP") or "C:\\tmp"):gsub("\\$", "") .. "\\" .. prefix ..
            require("conjunction.marks").uuid4_hex():sub(1, 8)
  B.makedirs(d)
  return d
end
local function walk(root, fn)                     -- os.walk's files: fn(dir, name)
  for _, e in ipairs(isdir(root) and w3.fs.list(root) or {}) do
    if e.dir then walk(root .. "\\" .. e.name, fn) else fn(root, e.name) end
  end
end
local function read_lines(path)                   -- open(path, encoding="utf-8") line by line, newlines kept out
  local s = FS.read_text(path) or ""
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  if out[#out] == "" and s:sub(-1) == "\n" then out[#out] = nil end
  return out
end

-- --- programs
-- subprocess.list2cmdline: the command line Windows programs read back as these arguments
function B.list2cmdline(args)
  local out = {}
  for _, arg in ipairs(args) do
    if #out > 0 then out[#out + 1] = " " end
    local bs = 0
    local need = arg == "" or arg:find("[ \t]") ~= nil
    if need then out[#out + 1] = '"' end
    for c in arg:gmatch(".") do
      if c == "\\" then bs = bs + 1
      elseif c == '"' then
        out[#out + 1] = string.rep("\\", bs * 2) .. '\\"'
        bs = 0
      else
        if bs > 0 then out[#out + 1] = string.rep("\\", bs) bs = 0 end
        out[#out + 1] = c
      end
    end
    if bs > 0 then out[#out + 1] = string.rep("\\", bs) end
    if need then out[#out + 1] = string.rep("\\", bs) .. '"' end
  end
  return table.concat(out)
end

-- shutil.which: the program on PATH (with PATHEXT's endings)
function B.which(name)
  local exts = {}
  for e in ((os.getenv("PATHEXT") or ".COM;.EXE;.BAT;.CMD") .. ";"):gmatch("([^;]*);") do
    if e ~= "" then exts[#exts + 1] = e:lower() end
  end
  local has_ext = false
  for _, e in ipairs(exts) do if PYS.lower(name):sub(-#e) == e then has_ext = true end end
  for dir in ((os.getenv("PATH") or "") .. ";"):gmatch("([^;]*);") do
    if dir ~= "" then
      dir = dir:gsub('"', ""):gsub("\\$", "")
      if has_ext and exists(dir .. "\\" .. name) and not isdir(dir .. "\\" .. name) then return dir .. "\\" .. name end
      for _, e in ipairs(exts) do
        local p = dir .. "\\" .. name .. e
        if exists(p) and not isdir(p) then return p end
      end
    end
  end
  return nil
end

local function now() return os.time() end
local function wait_tick() if coroutine.isyieldable() then coroutine.yield() end end

-- a program run to its end without its lines -> its exit code
function B.call(args, cwd)
  local p, err = w3.proc.run(B.list2cmdline(args), {cwd = cwd})
  if not p then error("OSError: " .. tostring(err) .. ": " .. args[1], 0) end
  while true do
    w3.proc.lines(p)
    local code = w3.proc.exit(p)
    if code ~= nil then
      w3.proc.lines(p)
      w3.proc.close(p)
      return code
    end
    wait_tick()
  end
end

local function keep_eula()
  local f = w3.plugin and w3.plugin.cj_redkit_eula_keep
  return f and f() == "1"
end

-- run a tool: its last lines logged; an exit code other than 0, an ERROR line or wcc_lite's fatal one fail it
function B.run(cmd, cwd, log, harmless)
  log = log or print
  local shown = {}
  for i, c in ipairs(cmd) do shown[i] = c:find(" ", 1, true) and ('"' .. c .. '"') or c end
  log("  $ " .. table.concat(shown, " "))
  local wcc = PYS.lower(basename(cmd[1])) == "wcc_lite.exe"
  if wcc then keep_eula() end                    -- (accepted before: a DWORD wcc_lite itself cannot read back)
  local p, err = w3.proc.run(B.list2cmdline(cmd), {cwd = cwd})
  if not p then error("OSError: " .. tostring(err) .. ": " .. cmd[1], 0) end
  local lines = {}
  local t, asked = now(), nil
  local code
  while true do
    for _, ln in ipairs(w3.proc.lines(p) or {}) do lines[#lines + 1] = ln end
    code = w3.proc.exit(p)
    if code ~= nil then
      for _, ln in ipairs(w3.proc.lines(p) or {}) do lines[#lines + 1] = ln end
      w3.proc.close(p)
      break
    end
    -- wcc_lite silent from its start: its EULA window waits (the first build on a PC). The user accepts it (once) -
    -- it is their licence, never clicked for them. (No look at other programs' windows: a DLL that lists processes
    -- and reads their window titles is malware to virus scanners, 06.11.)
    if wcc and asked == nil and #lines == 0 and now() - t > 8 then
      asked = now()
      log("  If REDkit's EULA window is open, accept it there. The build goes on after that")
    end
    if asked and #lines == 0 and now() - asked > 600 then
      w3.proc.kill(p)
      w3.proc.close(p)
      B.fail("REDkit's wcc_lite waits for its EULA to be accepted. Please start the REDkit once, accept the EULA and " ..
             "build again")
    end
    wait_tick()
  end
  if wcc and keep_eula() then log("  REDkit's EULA accepted") end
  local out = {}
  for _, ln in ipairs(lines) do if PYS.strip(ln) ~= "" then out[#out + 1] = ln end end
  for k = math.max(1, #out - 7), #out do log("    " .. out[k]) end
  -- harmless: ERROR lines a tool prints that are only hints (radish's lip sync: "no match" = tune it later)
  if harmless then
    local kept = {}
    for _, ln in ipairs(out) do
      local skip = false
      for _, h in ipairs(harmless) do if ln:find(h, 1, true) then skip = true end end
      if not skip then kept[#kept + 1] = ln end
    end
    out = kept
  end
  local fatal = "Failed to add seed file"        -- (wcc_lite says so and still exits 0, having cooked almost nothing)
  local errors, seen, bad = {}, {}, code ~= 0
  for _, ln in ipairs(out) do
    local s = PYS.strip(ln)
    if s:sub(1, 5) == "ERROR" or ln:find("[Error]", 1, true) then errors[#errors + 1] = s seen[s] = true end
    if ln:sub(1, 5) == "ERROR" then bad = true end
  end
  for _, ln in ipairs(out) do
    if ln:find(fatal, 1, true) then
      bad = true
      local s = PYS.strip(ln)
      if not seen[s] then errors[#errors + 1] = s seen[s] = true end
    end
  end
  if bad then
    local first = {}
    for k = 1, math.min(5, #errors) do first[k] = errors[k] end
    B.fail(string.format("%s failed (exit %s)", basename(cmd[1]), tostring(code)) ..
           (#first > 0 and (":\n  " .. table.concat(first, "\n  ")) or ""))
  end
  return out
end

-- --- the definition's production settings
local function prod_files(defdir)
  local out = {}
  for _, e in ipairs(w3.fs.list(defdir) or {}) do
    if not e.dir and e.name:sub(1, 5) == "prod." and e.name:sub(-4) == ".yml" then out[#out + 1] = e.name end
  end
  return out
end
-- `strings-idspace:` of the production (Conjunction's own DLCs use their own, quests the configured one)
function B.production_idspace(defdir, default)
  for _, f in ipairs(prod_files(defdir)) do
    for _, line in ipairs(read_lines(defdir .. "\\" .. f)) do
      local s = PYS.strip(line)
      if s:sub(1, 16) == "strings-idspace:" then
        local v = PYS.strip(PYS.strip(s:sub(17)), '"')
        return require("conjunction.questgen").int(v)
      end
    end
  end
  return default
end
-- the quest id from prod.quest-*.yml (`production: settings: id:`) - the DLC is named dlc<id>
function B.production_id(defdir)
  for _, f in ipairs(prod_files(defdir)) do
    for _, line in ipairs(read_lines(defdir .. "\\" .. f)) do
      local s = PYS.strip(line)
      if s:sub(1, 3) == "id:" then return PYS.lower(PYS.strip(PYS.strip(s:sub(4)), '"')) end
    end
  end
  B.fail("no production id in " .. defdir)
end

-- radish strings csv files (`;` comment lines, `id|key|key|text`) into one - the header of the first only
function B.merge_strings(csvs, target)
  local out, header_done = {}, false
  for _, c in ipairs(csvs) do
    if exists(c) then
      for _, line in ipairs(PYS.splitlines(FS.read_text(c) or "")) do
        if line:sub(1, 1) == ";" then
          if not header_done then out[#out + 1] = line end
        elseif PYS.strip(line) ~= "" then
          out[#out + 1] = line
        end
      end
      header_done = true
    end
  end
  assert(w3.fs.write(target, table.concat(out, "\n") .. "\n"))
  return target
end

-- the lines of one's own words in the project's game scenes (game_files) -> speech's lines: a silent voice as long as
-- the line is in the timeline (the game gives a line without a voice 1.5 to 1.8 s whatever its text), the mouth
-- moving to the text
function B.scene_text_lines(project, base)
  if not project then return {} end
  local TR, N = require("conjunction.cr2w_tree"), require("conjunction.pynum")
  local ST = require("conjunction.scene_texts")
  local texts = ST.load(project).texts
  local own = project .. "\\game_files"
  if next(texts) == nil or not isdir(own) then return {} end
  local lines = {}
  walk(own, function(dir, n)
    if PYS.lower(n):sub(-8) == ".w2scene" then
      local ok, tree = pcall(function() return TR.Tree(assert(w3.fs.read(dir .. "\\" .. n))) end)
      if ok then
        for _, o in ipairs(tree.objects) do
          if o.cls == "CStorySceneLine" and o.props then
            local sid = o:get("dialogLine")
            if TR.is(sid, TR.LOC) then sid = sid.n end
            if math.type(sid) == "integer" and texts[sid] then
              local dur = tonumber(o:get("approvedDuration") or 0) or 0
              if dur == 0 then dur = 2.0 end
              lines[sid] = Y.map({"id", base + (sid - ST.POOL_BASE), "text", texts[sid], "dur", N.round(dur, 3),
                                  "source", Y.null})
            end
          end
        end
      end
    end
  end)
  local ids = {}
  for sid in pairs(lines) do ids[#ids + 1] = sid end
  table.sort(ids)
  local out = Y.list({})
  for _, sid in ipairs(ids) do out[#out + 1] = lines[sid] end
  return out
end

-- the definition as radish can parse it: a copy whose waits name Conjunction's own conditions as a stand-in fact
-- -> the folder radish encodes, the blocks changed
function B.for_radish(defdir)
  local stand_in = Y.map({"factdb", Y.list({"cj_radish_stand_in", "=", 1})})
  local function plain(spec)
    for _, k in ipairs(B.OURS_ONLY) do if spec[k] ~= nil then return stand_in end end
    return spec
  end
  local changed, out = {}, nil
  local names = {}
  for _, e in ipairs(w3.fs.list(defdir) or {}) do
    if not e.dir and e.name:sub(1, 9) == "structure" and e.name:sub(-4) == ".yml" then names[#names + 1] = e.name end
  end
  table.sort(names)
  for _, f in ipairs(names) do
    local d = Y.read(defdir .. "\\" .. f)
    if not P.T(d) then d = Y.map() end
    local mine = {}
    for _, seg in pairs(P.map(P.get(d, "structure"))) do
      for name, body in pairs(P.map(P.get(P.map(seg), "blocks"))) do
        if type(name) == "string" and name:sub(1, 8) == "addfact." and Y.is_map(body) and P.has(body, "mappin") then
          Y.remove(body, "mappin")                 -- (a map pin's switch: Conjunction's encoder writes it)
          Y.remove(body, "objective")
          mine[#mine + 1] = name
        elseif type(name) == "string" and name:sub(1, 10) == "waituntil." and Y.is_map(body) then
          local conds = body.conditions
          if Y.is_map(conds) then
            for _, k in ipairs(Y.keys(conds)) do
              local c = conds[k]
              if Y.is_map(c) and plain(c) ~= c then
                conds[k] = plain(c)
                mine[#mine + 1] = name
              end
            end
          elseif plain(body) ~= body then
            local nxt = {}
            for _, k in ipairs(Y.keys(body)) do
              if type(k) == "string" and k:sub(1, 4) == "next" then nxt[#nxt + 1] = {k, body[k]} end
            end
            for _, k in ipairs(Y.keys(body)) do Y.remove(body, k) end
            body.factdb = stand_in.factdb
            for _, kv in ipairs(nxt) do body[kv[1]] = kv[2] end
            mine[#mine + 1] = name
          end
        end
      end
    end
    if #mine > 0 then
      if out == nil then
        local tmp = scratch("conjunction_radish_")
        out = tmp .. "\\" .. basename(defdir)
        FS.copytree(defdir, out)
      end
      Y.write(out .. "\\" .. f, d, {sort_keys = false, allow_unicode = true, default_flow_style = false})
      for _, n in ipairs(mine) do changed[#changed + 1] = n end
    end
  end
  local set, list = {}, {}
  for _, n in ipairs(changed) do if not set[n] then set[n] = true list[#list + 1] = n end end
  table.sort(list)
  return out or defdir, list
end

-- the names people are shown by (definition.names.yml {tag = name}) into the DLC's strings -> how many
function B.people_names(out, texts, keys, idspace)
  local f = out .. "\\definition.names.yml"
  if not exists(f) then return 0 end
  local names = Y.read(f)
  if not P.T(names) then return 0 end
  local tags = Y.keys(names)
  table.sort(tags, function(a, b) return P.str(a) < P.str(b) end)
  local top = 2110000000 + idspace * 1000 + 999
  local WS = require("conjunction.w3strings")
  for k, tag in ipairs(tags) do
    texts[top - (k - 1)] = P.str(names[tag])
    keys[top - (k - 1)] = WS.key_hash(PYS.lower("cj_name_" .. P.str(tag)))
  end
  return #tags
end

-- the game's own files a build changes (the mod bundle's) -> their paths; an error while the experimental features
-- are off
function B.game_files_changed(overrides)
  local changed = {}
  if isdir(overrides) then
    walk(overrides, function(dir, n) changed[#changed + 1] = (dir .. "\\" .. n):sub(#overrides + 2) end)
    table.sort(changed)
  end
  if #changed > 0 and not require("conjunction.features").experimental() then
    local more = #changed > 3 and string.format(" and %d more", #changed - 3) or ""
    B.fail("This project changes game files (" .. table.concat({table.unpack(changed, 1, math.min(3, #changed))}, ", ") ..
           more .. "). That is an experimental feature (turn it on in Settings > General > Experimental)")
  end
  return changed
end

-- radish's repository folder plus Conjunction's RTTI file, kept beside Conjunction's config (refreshed when
-- radish's own files are newer) -> its path, for w2quest --repo-dir. B.REPO (a check's copy) wins.
function B.radish_repo(cfg)
  if B.REPO then return B.REPO end
  cfg = cfg or CFG.load()
  local src = cfg.radish .. "\\repo.quests"
  local dst = require("conjunction.paths").DATA .. "\\radish_repo"
  local newest = 0
  for _, e in ipairs(w3.fs.list(src) or {}) do newest = math.max(newest, w3.fs.mtime(src .. "\\" .. e.name) or 0) end
  local mine = dst .. "\\" .. B.RTTI_FILE
  if not exists(mine) or (w3.fs.mtime(mine) or 0) < newest or FS.read_text(mine) ~= B.RTTI then
    if isdir(dst) then FS.rmtree(dst) end
    FS.copytree(src, dst)
    assert(w3.fs.write(mine, B.RTTI))
  end
  return dst
end

-- --- the own encoders
local function settings_of(defdir)
  local settings = Y.map()
  for _, f in ipairs(prod_files(defdir)) do
    local d = Y.read(defdir .. "\\" .. f)
    settings = P.map(P.get(P.map(P.get(P.map(d), "production")), "settings"))
  end
  return settings
end

-- our own quest, journal and layer encoders write the files in place of radish's -> true when it wrote the quest
function B.own_quest(defdir, uncooked, dlc, qid, cfg, log, scripts)
  if P.get(cfg, "quest_encoder", "ours") ~= "ours" then return false end
  local QE = require("conjunction.quest_encoder")
  local dlcdir = uncooked .. "\\dlc\\" .. dlc
  local target = dlcdir .. "\\data\\" .. qid .. ".w2quest"
  if not exists(target) then return false end
  local depot = require("conjunction.depot").open(cfg.game)
  local template = depot:read(QE.TEMPLATE)
  local jy = defdir .. "\\journals.yml"
  if exists(jy) then
    local JE = require("conjunction.journal_encoder")
    local s = settings_of(defdir)
    -- map pins a switch turns on (a race's checkpoints): off when their objective starts
    local mg = dirname(defdir) .. "\\definition.minigames.yml"
    local off = {}
    for _, m in pairs(exists(mg) and P.map(Y.read(mg)) or {}) do
      if Y.is_map(m) and P.get(m, "game") == "pins_off" then
        for _, p in ipairs(P.list(P.get(m, "pins"))) do off[#off + 1] = P.str(p) end
      end
    end
    local files = JE.encode(Y.read(jy) or Y.map(), JE.Ctx(qid, dlc, P.get(s, "strings-idspace", P.get(cfg, "idspace", 0)),
                                                         P.get(s, "strings-idstart", 0), template, off))
    local n = 0
    for path, data in pairs(files) do
      local dest = uncooked .. "\\" .. path:gsub("/", "\\")
      B.makedirs(dirname(dest))
      replace_file(dest, data)
      n = n + 1
    end
    log(string.format("[build] %s: journal encoded by Conjunction (%d files)", qid, n))
  end
  local ly = defdir .. "\\layers.yml"
  if exists(ly) then
    local LE = require("conjunction.layer_encoder")
    local files = LE.encode(Y.read(ly) or Y.map(), LE.Ctx(qid, dlc, template, B.radish_repo(cfg)))
    local n = 0
    for path, data in pairs(files) do
      local dest = uncooked .. "\\" .. path
      B.makedirs(dirname(dest))
      replace_file(dest, data)
      n = n + 1
    end
    log(string.format("[build] %s: layers encoded by Conjunction (%d files)", qid, n))
  end
  local journals = {}
  walk(dlcdir .. "\\journal", function(dir, n)
    if n:sub(-8) == ".journal" then
      local full = dir .. "\\" .. n
      journals["dlc/" .. dlc .. "/" .. full:sub(#dlcdir + 2):gsub("\\", "/")] = assert(w3.fs.read(full))
    end
  end)
  local PATHS = require("conjunction.paths")
  local base = PATHS.REPO and (PATHS.REPO .. "\\mod") or PATHS.MOD_ROOT
  local roots = {cfg.game .. "\\content\\content0\\scripts", PATHS.RUNTIME_SCRIPTS, base .. "\\scripts"}
  if scripts then roots[#roots + 1] = scripts end
  local data = QE.encode(defdir, journals, QE.Ctx(qid, dlc, QE.script_functions(roots), template))
  replace_file(target, data)
  log(string.format("[build] %s: quest encoded by Conjunction (%d bytes)", qid, #data))
  return true
end

-- the own quest changed in the quest graph (vanilla_edit.own_quest_data) in place of what was encoded; what the
-- quest board made kept beside (build\own_quest.encoded.w2quest: the graph's Revert) -> true when it replaced
function B.apply_own_quest(project, uncooked, out, qid, log)
  local VE = require("conjunction.vanilla_edit")
  local rel, data = VE.own_quest_data(project)
  local keep = out .. "\\" .. VE.ENCODED
  if data ~= nil and rel then
    local target = uncooked .. "\\" .. rel
    assert(w3.fs.copy(target, keep))
    replace_file(target, data)
    log(string.format("[build] %s: the quest as the quest graph left it (%d bytes)", qid, #data))
    return true
  end
  if exists(keep) then w3.fs.remove(keep) end
  return false
end

-- gwent, fist fights, stopped lanes: the stand-ins made the game's own blocks; script blocks get their parameters
function B.minigames(out, uncooked, log, own)
  local SPm = require("conjunction.script_params")
  local CE = require("conjunction.cr2w_edit")
  local params = SPm.apply(uncooked)
  local spec_file = out .. "\\definition.minigames.yml"
  local done = {}
  if exists(spec_file) then
    local spec = P.map(Y.read(spec_file))
    local paths, games = {}, Y.map()
    local any_path = false
    for k, v in pairs(spec) do
      if P.get(v, "game") == "path" then paths[v.entity] = v any_path = true
      elseif P.get(v, "game") ~= "pins_off" then games[k] = v end
    end
    if any_path then
      log(string.format("[build] ways into %d path entities", #CE.patch_paths(uncooked, paths)))
    end
    if not own then done = CE.apply(uncooked, games) end    -- (our encoder wrote the game's blocks at once)
  end
  if params > 0 or #done > 0 then
    walk(uncooked, function(dir, n)
      if n:sub(-8) == ".w2quest" or n:sub(-8) == ".w2phase" then
        local data = assert(w3.fs.read(dir .. "\\" .. n))
        if CR.parse(data):save() ~= data then B.fail(n .. " does not read back after its blocks were written") end
      end
    end)
  end
  if params > 0 then log(string.format("[build] script blocks with their parameters: %d", params)) end
  if #done > 0 then log("[build] the game's own blocks: " .. table.concat(done, ", ")) end
end

-- the cook's list of files: every file of the uncooked DLC in one bundle, the .reddlc with its chunk
function B.write_seed(dlc_dir, seed)
  local root = dirname(dirname(dlc_dir))          -- (paths start at dlc\)
  local files = {}
  walk(dlc_dir, function(dir, f)
    local rel = (dir .. "\\" .. f):sub(#root + 2)
    local e = Y.map({"path", rel, "bundle", "blob"})
    if PYS.lower(f):sub(-7) == ".reddlc" then e.chunks = Y.list({"dlc"}) end
    files[#files + 1] = {e, PYS.lower(rel), #files + 1}
  end)
  table.sort(files, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[3] < b[3] end)
  local list = Y.list({})
  for k, x in ipairs(files) do list[k] = x[1] end
  assert(w3.fs.write(seed, J.encode(Y.map({"files", list}), {indent = 4})))
end

-- the cooked files into a bundle and its metadata.store, by Conjunction; wcc_lite when CJ_WCC_PACK is set, the
-- folder has mesh buffers, or Conjunction's way fails
function B.pack_and_index(src, content, wcc, bindir, log)
  local buffers = false
  walk(src, function(_d, f) if f:sub(-7) == ".buffer" then buffers = true end end)
  if not os.getenv("CJ_WCC_PACK") and not buffers then
    local ok, err = pcall(function()
      B.makedirs(content)
      local bundle = require("conjunction.packer").pack(src, content)
      assert(w3.fs.write(content .. "\\metadata.store", require("conjunction.metastore").build({{basename(bundle), bundle}})))
      log(string.format("[build] packed and indexed by Conjunction (%d bytes)", w3.fs.size(bundle)))
    end)
    if ok then return end
    log("[build] Conjunction's packer failed (" .. B.message(err) .. "), wcc_lite packs instead")
  end
  B.run({wcc, "pack", "-dir=" .. src, "-outdir=" .. content}, bindir, log)
  B.run({wcc, "metadatastore", "-path=" .. content}, bindir, log)
end

-- the project's mark seed (hex) or nil
function B.mark_seed(project)
  if not project or not exists(project .. "\\project.yml") then return nil end
  return require("conjunction.marks").project_seed(Y.read(project .. "\\project.yml") or Y.map())
end

-- the tools a build used, for its history step
function B.build_tools(cfg)
  local out = require("conjunction.provenance").tools()
  if P.T(P.get(cfg, "radish")) then
    out[#out + 1] = "radish modding tools " .. (B.RADISH_ZIP:match("v%d%d%d%d%-%d%d%-%d%d") or "")
  end
  if P.T(P.get(cfg, "wcc")) then out[#out + 1] = "REDkit wcc_lite" end
  return out
end

function B.need_redkit(cfg)
  cfg = cfg or CFG.load()
  local w = P.get(cfg, "wcc") or ""
  if w == "" or not exists(w) or isdir(w) then
    B.fail("REDkit is missing. Please install The Witcher 3 REDkit (free on Steam or GOG) and set its folder in " ..
           "Settings > Game")
  end
end

-- radish writes the quest's own items as misc things: those with a text are letters and books, those without are
-- plain quest items
local function utf16_decode(raw)                  -- raw.decode("utf-16"): the BOM's order, then the text as UTF-8
  local le, i = true, 1
  if raw:sub(1, 2) == "\255\254" then i = 3 elseif raw:sub(1, 2) == "\254\255" then le, i = false, 3 end
  local out = {}
  local fmt = le and "<I2" or ">I2"
  while i + 1 <= #raw do
    local u = string.unpack(fmt, raw, i)
    i = i + 2
    if u >= 0xD800 and u <= 0xDBFF and i + 1 <= #raw then
      local l = string.unpack(fmt, raw, i)
      i = i + 2
      out[#out + 1] = utf8.char(0x10000 + ((u - 0xD800) << 10) + (l - 0xDC00))
    else
      out[#out + 1] = utf8.char(u)
    end
  end
  return table.concat(out)
end
local function utf16_encode(text)                 -- open(..., "w", encoding="utf-16"): a BOM, little endian
  local out = {"\255\254"}
  for _, c in utf8.codes(text) do
    if c >= 0x10000 then
      local v = c - 0x10000
      out[#out + 1] = string.pack("<I2I2", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
    else
      out[#out + 1] = string.pack("<I2", c)
    end
  end
  return table.concat(out)
end
B.utf16_decode = utf16_decode
local function universal_newlines(s) return (s:gsub("\r\n", "\n"):gsub("\r", "\n")) end

function B.readable_items(uncooked, dlc, project)
  local path = uncooked .. "\\dlc\\" .. dlc .. "\\data\\gameplay\\items\\def_item_quest.xml"
  if not exists(path) then return end
  local plain, icons = {}, {}
  if type(project) == "string" then project = require("conjunction.project").open(project) end
  if project ~= nil then
    local qid = PYS.lower(P.str(project:id()))
    local own = Y.map()                          -- (every quest of the project's)
    for _, q in ipairs(require("conjunction.quests").all_quests(project.meta)) do
      for iid, d in pairs(P.map(P.get(q, "items"))) do own[iid] = d end
    end
    local based = {}
    for iid, d in pairs(own) do
      local name = PYS.lower(qid .. "_own_" .. P.str(iid))
      if not P.T(P.get(P.map(d), "text")) then plain[name] = true end
      if P.T(P.get(P.map(d), "base")) then based[name] = d.base end
    end
    if next(based) then
      local ok = pcall(function()
        local A = require("conjunction.assets").new()
        for k, b in pairs(based) do icons[k] = P.get(A:item(b) or {}, "icon") end
      end)
      if not ok then icons = {} end
    end
  end
  local text = universal_newlines(utf16_decode(assert(w3.fs.read(path))))
  local out, i = {}, 1
  while true do
    local a = text:find("<item name=", i, true)
    if not a then break end
    local z = text:find("</item>", a, true)
    if not z then break end
    out[#out + 1] = text:sub(i, a - 1)
    local block = text:sub(a, z + 6)
    local name = PYS.lower(block:match('<item name="([^"]+)"'))
    if icons[name] and icons[name] ~= "" then
      local icon = icons[name]
      block = block:gsub('icon_path="[^"]*"', function() return 'icon_path="' .. icon .. '"' end)
    end
    if plain[name] then
      block = P.replace(block, "<!--<tags></tags>-->", "<tags>Quest</tags>")
    else
      block = P.replace(P.replace(block, 'category="misc"', 'category="book"'), "<!--<tags></tags>-->",
                        "<tags>ReadableItem, Quest</tags>")
    end
    out[#out + 1] = block
    i = z + 7
  end
  out[#out + 1] = text:sub(i)
  assert(w3.fs.write(path, utf16_encode((table.concat(out):gsub("\n", "\r\n")))))
end

-- radish writes the DLC's definitions as UTF-16; the remaster reads them only as UTF-8 with a BOM -> the files changed
-- radish names the rewards file's property of the DLC's mounter `rewordsXmlFilePath`; the game's own DLCs (bob, ep1)
-- have `rewardsXmlFilePath` - under radish's name the game loaded no reward of the quest. -> true when changed
function B.reddlc_rewards(uncooked, dlc)
  local p = uncooked .. "\\dlc\\" .. dlc .. "\\" .. dlc .. ".reddlc"
  if not exists(p) then return false end
  local CR = require("conjunction.cr2w")
  local f = CR.parse(assert(w3.fs.read(p)))
  local i
  for k, n in ipairs(f.names) do if n == "rewordsXmlFilePath" then i = k break end end
  if not i then return false end
  f.names[i], f.hashes[i] = "rewardsXmlFilePath", CR.known_hash("rewardsXmlFilePath")
  assert(w3.fs.write(p .. ".tmp", f:save()))
  if exists(p) then w3.fs.remove(p) end
  assert(w3.fs.rename(p .. ".tmp", p))
  return true
end

-- radish gives each reward of the rewards file 50 experience; a reward step's crowns and experience come from the
-- script (CjGive), its items from the file - with both the player got the experience twice. -> the file's experience
-- and gold set to 0
function B.rewards_items_only(uncooked, dlc)
  local p = uncooked .. "\\dlc\\" .. dlc .. "\\data\\gameplay\\rewards\\def_reward_quest.xml"
  if not exists(p) then return false end
  local raw = assert(w3.fs.read(p))
  local bom = raw:sub(1, 3) == "\239\187\191" and raw:sub(1, 3) or ""
  local text = raw:sub(#bom + 1)
  -- (<reward\b[^>]*?\b)experience="[^"]*"  and the same for gold: in each <reward ...> tag
  local new = text:gsub("(<reward[%s>][^>]*)", function(tag)
    tag = tag:gsub('([%s])experience="[^"]*"', '%1experience="0"', 1)
    tag = tag:gsub('([%s])gold="[^"]*"', '%1gold="0"', 1)
    return tag
  end)
  if new == text then return false end
  assert(w3.fs.write(p, bom .. new))
  return true
end

function B.xml_utf8(uncooked, dlc)
  local done = {}
  walk(uncooked .. "\\dlc\\" .. dlc, function(dir, n)
    if PYS.lower(n):sub(-4) == ".xml" then
      local p = dir .. "\\" .. n
      local raw = assert(w3.fs.read(p))
      if raw:sub(1, 2) == "\255\254" or raw:sub(1, 2) == "\254\255" then
        local text = utf16_decode(raw)
        -- (<\?xml[^>]*encoding=")UTF-16(") once, case-insensitive: the first declaration that has it, its last one
        local low = text:lower()
        local at = 1
        while true do
          local a = low:find("<?xml", at, true)
          if not a then break end
          local stop = low:find(">", a + 5, true) or (#low + 1)
          local decl = low:sub(a, stop - 1)
          local last, k = nil, 1
          while true do
            local e = decl:find('encoding="utf-16"', k, true)
            if not e then break end
            last, k = e, e + 1
          end
          if last then
            local s = a + last - 1 + #'encoding="'
            text = text:sub(1, s - 1) .. "UTF-8" .. text:sub(s + 6)
            break
          end
          at = a + 1
        end
        assert(w3.fs.write(p, "\239\187\191" .. text))
        done[#done + 1] = n
      end
    end
  end)
  return done
end

-- the folder REDkit uncooked the game into (its editor's uncookPath; config "uncook_depot" wins), with a backslash
function B.uncook_depot(cfg)
  cfg = cfg or CFG.load()
  local path = P.get(cfg, "uncook_depot")
  if not P.T(path) then
    path = nil
    local ini = P.str(P.get(cfg, "redkit", "")) .. "\\bin\\r4LavaEditor2.ini"
    local s = w3.fs.read(ini)
    if not s then return nil end
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
      line = line:gsub("\r$", "")
      if PYS.lower(line):sub(1, 11) == "uncookpath=" then
        path = PYS.strip(line:match("^[^=]*=(.*)$"))
        break
      end
    end
  end
  if not path or path == "" or not isdir(path) then return nil end
  return (path:gsub("[\\/]+$", "")) .. "\\"
end

-- the game's files wcc_lite misses: hard links from REDkit's uncooked depot into r4data -> {rel = true} linked
function B.link_from_depot(resources, log)
  local cfg = CFG.load()
  local depot = B.uncook_depot(cfg)
  local done, list = {}, {}
  if not depot then return done end
  local r4data = cfg.redkit .. "\\r4data"
  for rel in pairs(resources) do
    local src, dst = depot .. rel, r4data .. "\\" .. rel
    if exists(src) and not isdir(src) then
      if not exists(dst) then
        B.makedirs(dirname(dst))
        local ok = w3.plugin.cj_hardlink and w3.plugin.cj_hardlink(src, dst) == "1"
        if not ok then assert(w3.fs.copy(src, dst)) end           -- another drive: a copy
      end
      done[rel] = true
      list[#list + 1] = rel
    end
  end
  if #list > 0 then
    table.sort(list)
    log(string.format("[build] %d of the game's files from REDkit's depot into r4data: %s", #list,
                      table.concat({table.unpack(list, 1, math.min(4, #list))}, ", ")) .. (#list > 4 and " ..." or ""))
  end
  return done
end

-- every import path (lower case) of the CR2W files in data
local function imports_of(data)
  local out = {}
  local ok = pcall(function()
    for _, part in ipairs(CR.parts(data)) do
      for _, im in ipairs(part.imports) do if im[1] ~= "" then out[PYS.lower(im[1])] = true end end
    end
  end)
  return ok and out or {}
end

-- before cooking: every game file the layers, templates and communities point at (and what the game's templates
-- among them point at) linked from REDkit's depot at once
function B.prelink(uncooked, cfg, log)
  local r4data = cfg.redkit .. "\\r4data"
  local depot = B.uncook_depot(cfg)
  local todo = {}
  walk(uncooked, function(dir, f)
    if f:sub(-4) == ".w2l" or f:sub(-6) == ".w2ent" or f:sub(-7) == ".w2comm" then
      for k in pairs(imports_of(assert(w3.fs.read(dir .. "\\" .. f)))) do todo[k] = true end
    end
  end)
  local wanted, seen, any = {}, {}, false
  for _ = 1, 3 do                                 -- a layer -> a template -> its includes and meshes
    local nxt = {}
    for rel in pairs(todo) do
      if not seen[rel] then
        seen[rel] = true
        if rel:sub(1, 4) ~= "dlc\\" then
          if not exists(r4data .. "\\" .. rel) then wanted[rel] = true any = true end
          if rel:sub(-6) == ".w2ent" then
            for _, base in ipairs({r4data .. "\\", depot or false}) do
              if base and exists(base .. rel) and not isdir(base .. rel) then
                for k in pairs(imports_of(assert(w3.fs.read(base .. rel)))) do nxt[k] = true end
                break
              end
            end
          end
        end
      end
    end
    todo = nxt
  end
  if any then B.link_from_depot(wanted, log) end
end

-- templates of the project that are, or use, one of these resources (their meshes and includes)
local function templates_using(project, resources)
  local PG = require("conjunction.project_gen")
  local depot = require("conjunction.depot").open(CFG.load().game)
  local mesh_of = PG.mesh_reverse_index()
  local out = {}
  for _, name in ipairs(Y.keys(project.places)) do
    for _, o in ipairs(P.list(P.get(project.places[name], "objects"))) do
      local t = PYS.lower(o.template)
      local uses = {[t] = true, [mesh_of[t] or ""] = true}
      if depot:exists(t) then
        pcall(function()
          local parts = CR.parts(depot:read(t))
          for k, part in ipairs(parts) do
            for _, im in ipairs(part.imports) do
              local p = PYS.lower(im[1])
              if p:sub(-7) == ".w2mesh" or (k == 1 and p:sub(-6) == ".w2ent") then uses[p] = true end
            end
          end
        end)
      end
      for r in pairs(uses) do if resources[r] then out[t] = true break end end
    end
  end
  return out
end

-- the mod bundle with the game's files a quest changes -> <game>\Mods\mod<dlc>; none: an old one goes
function B.install_mod(packed_mod, game, dlc, log)
  local target = game .. "\\Mods\\mod" .. dlc
  if exists(target) then FS.rmtree(target) end
  local content = packed_mod .. "\\content"
  if isdir(content) and #(w3.fs.list(content) or {}) > 0 then
    FS.copytree(packed_mod, target)
    log("[build] the game's files it changes -> " .. target)
  end
  return target
end

-- the first of the quest's own 1000 text ids in the wide field (idremap) - nil when a project turns it off
function B.wide_strings(project, qid)
  if type(project) == "string" then
    if not exists(project .. "\\project.yml") then return nil end
    project = require("conjunction.project").open(project)
  end
  if project == nil or P.get(project.meta, "strings_wide") == false then return nil end
  return require("conjunction.idremap").wide_base(qid, 1000, P.str(P.get(project.meta, "strings_salt", "")))
end

local function copy_tree_into(src, dst, log, qid, what, skip)
  walk(src, function(dir, name)
    local full = dir .. "\\" .. name
    if not (skip and skip(dir, name)) then
      local rel = full:sub(#src + 2)
      B.makedirs(dirname(dst .. "\\" .. rel))
      assert(w3.fs.copy(full, dst .. "\\" .. rel))
      log(string.format("[build] %s: %s: %s", qid, what, rel))
    end
  end)
end

-- a radish definition folder -> the DLC dlc<id> (scenes from <out>\definition.scenes), optionally installed
function B.build_dlc(defdir, out, install, log, project, extra, after_encode, collision_cache, opts)
  log = log or print
  local cfg = CFG.load()
  local qid = B.production_id(defdir)
  local dlc = "dlc" .. qid
  local uncooked, cooked, packed = out .. "\\uncooked", out .. "\\cooked", out .. "\\packed"
  local overrides, packed_mod = out .. "\\overrides", out .. "\\packed_mod"
  for _, d in ipairs({cooked, packed, overrides, packed_mod}) do if exists(d) then FS.rmtree(d) end end
  for _, d in ipairs({uncooked, cooked, packed .. "\\content"}) do B.makedirs(d) end

  -- the runtime functions the quest calls: its own copies, named after it (scriptlib) - or, into the running game,
  -- the runtime's there when they are the same (no script of its own: no restart)
  local SL = require("conjunction.scriptlib")
  local scripts = packed_mod .. "\\content\\scripts\\local"
  local runtime = opts and opts.live and require("conjunction.setup").runtime_in_game(cfg) or nil
  local ok, err = pcall(SL.apply, out, qid, scripts, log, nil, runtime)
  if not ok then
    if type(err) == "table" and getmetatable(err) == SL.RUNTIME_ONLY_MT then
      B.fail("the quest calls something only the Conjunction Runtime can do: " .. tostring(err.runtime_only))
    end
    error(err, 0)
  end

  log(string.format("[build] %s: encode quest", qid))
  local plain, mine = B.for_radish(defdir)
  if #mine > 0 and P.get(cfg, "quest_encoder", "ours") ~= "ours" then
    B.fail("these waits need Conjunction's quest encoder (config quest_encoder: radish): " ..
           table.concat({table.unpack(mine, 1, math.min(6, #mine))}, ", "))
  end
  B.run({cfg.radish .. "\\w2quest.exe", "--repo-dir", B.radish_repo(cfg), "--output-dir", uncooked, "--encode", plain},
        nil, log)
  if plain ~= defdir then FS.rmtree(dirname(plain)) end      -- (radish's copy: done with)
  local own = B.own_quest(defdir, uncooked, dlc, qid, cfg, log, scripts)
  B.readable_items(uncooked, dlc, project)
  local utf8_ = B.xml_utf8(uncooked, dlc)
  if #utf8_ > 0 then
    log(string.format("[build] %s: definitions saved as UTF-8: %s", qid, table.concat(utf8_, ", ")))
  end
  if B.reddlc_rewards(uncooked, dlc) then
    log(string.format("[build] %s: rewards file mounted under the game's name", qid))
  end
  B.rewards_items_only(uncooked, dlc)
  B.minigames(out, uncooked, log, own)
  if after_encode then after_encode(uncooked, dlc) end
  -- the same GUIDs on every build: a save that is in the quest resumes it after a rebuild
  require("conjunction.stable_ids").stabilize(uncooked .. "\\dlc\\" .. dlc, qid, log, B.mark_seed(project))
  if project then B.apply_own_quest(project, uncooked, out, qid, log) end
  for rel, source in pairs(extra or {}) do
    local target = uncooked .. "\\" .. rel
    B.makedirs(dirname(target))
    assert(w3.fs.copy(source, target))
  end
  -- (plug-ins' uncooked steps and CSV rows: the app's Python runs them, the game has none)

  -- wcc_lite cooks from its depot: our uncooked DLC is linked in as r4data\dlc\<dlc>, pointing at THIS project's files
  local link = cfg.redkit .. "\\r4data\\dlc\\" .. dlc
  local src = uncooked .. "\\dlc\\" .. dlc
  if exists(link) then
    w3.fs.rmdir(link)                             -- (a junction: only it goes, not what it points at)
    if exists(link) then B.fail(link .. " is a folder of its own, not Conjunction's link: please move it away") end
  end
  B.call({"cmd", "/c", "mklink", "/J", link, src})
  if not exists(link) then B.fail("could not link " .. src .. " into REDkit's depot (" .. link .. ")") end
  local wcc = cfg.wcc
  local bindir = dirname(wcc)
  local seed = out .. "\\seed.files"
  B.prelink(uncooked, cfg, log)
  log(string.format("[build] %s: analyze, cook", qid))
  if os.getenv("CJ_WCC_ANALYZE") then
    B.run({wcc, "analyze", "r4dlc", "-dlc=dlc\\" .. dlc .. "\\" .. dlc .. ".reddlc", "-out=" .. seed}, bindir, log)
  else
    B.write_seed(uncooked .. "\\dlc\\" .. dlc, seed)
  end
  -- one seed entry missing from the depot makes wcc_lite drop the whole seed; ready-made resources must be in it
  local data = J.decode(assert(w3.fs.read(seed)))
  local kept, listed = Y.list({}), {}
  for _, e in ipairs(data.files) do
    if exists(uncooked .. "\\" .. e.path) then kept[#kept + 1] = e listed[PYS.lower(e.path)] = true end
  end
  for _, rel in ipairs(Y.keys(extra or Y.map())) do
    local r = rel:gsub("/", "\\")
    if not listed[PYS.lower(r)] then kept[#kept + 1] = Y.map({"path", r, "bundle", "blob"}) end
  end
  data.files = kept
  assert(w3.fs.write(seed, J.encode(data, {indent = 4})))
  B.run({wcc, "cook", "-platform=pc", "-trimdir=dlc\\" .. dlc, "-seed=" .. seed, "-outdir=" .. cooked}, bindir, log)
  local db = cooked .. "\\cook.db"
  if exists(db) then
    if exists(out .. "\\cook.db") then w3.fs.remove(out .. "\\cook.db") end
    assert(w3.fs.rename(db, out .. "\\cook.db"))  -- must not be packed
  end
  local back = require("conjunction.script_params").restore(uncooked, cooked)
  if back > 0 then log(string.format("[build] %s: script parameters put back after cooking: %d", qid, back)) end

  -- dialogue scenes: encoded straight into the cooked DLC (as radish does), their texts join the quest's
  local scene_csvs = {}
  local scenedefs = out .. "\\definition.scenes"
  if isdir(scenedefs) then
    local tmp = out .. "\\scenes"
    if exists(tmp) then FS.rmtree(tmp) end
    B.makedirs(tmp)
    local target_dir = cooked .. "\\dlc\\" .. dlc .. "\\data\\scenes"
    B.makedirs(target_dir)
    local tf = scenedefs .. "\\targets.yml"
    local targets = exists(tf) and P.map(Y.read(tf)) or Y.map()
    local names = {}
    for _, e in ipairs(w3.fs.list(scenedefs) or {}) do
      if not e.dir and e.name:sub(1, 6) == "scene." and e.name:sub(-4) == ".yml" then names[#names + 1] = e.name end
    end
    table.sort(names)
    for _, f in ipairs(names) do
      local name = f:sub(1, -5)
      log(string.format("[build] %s: scene %s", qid, name:sub(7)))
      B.run({cfg.radish .. "\\w2scene.exe", "--repo-dir", cfg.radish .. "\\repo.scenes", "--output-dir", tmp, "--encode",
             name}, scenedefs, log)
      local dest = target_dir .. "\\" .. name:sub(7) .. ".w2scene"
      if P.T(P.get(targets, name:sub(7))) then     -- a swapped game scene: under the game's own path, in the mod
        dest = overrides .. "\\" .. P.str(targets[name:sub(7)]):gsub("/", "\\")
        B.makedirs(dirname(dest))
      end
      assert(w3.fs.copy(tmp .. "\\" .. name .. ".w2scene", dest))
      scene_csvs[#scene_csvs + 1] = tmp .. "\\" .. name .. ".w3strings-csv"
      -- its staging from the scene workshop's timeline (the project's layer), laid over the new scene
      local key = name:sub(7)
      if key:sub(1, #qid + 1) == qid .. "_" then key = key:sub(#qid + 2) end      -- (s12: its node)
      local ldata = project and w3.fs.read(project .. "\\scene_layers\\" .. key .. ".json")
      local lok, layer = false, nil
      if ldata then lok, layer = pcall(J.decode, ldata) end
      if lok and type(layer) == "table" then
        log(string.format("[build] %s: scene %s: its timeline's staging", qid, name:sub(7)))
        require("conjunction.scene_timeline")
        local sc = require("conjunction.scene_file").open(assert(w3.fs.read(dest)))
        sc:apply_layer(layer, qid)
        assert(w3.fs.write(dest, sc:bytes()))
      end
    end
  end
  local keyed = out .. "\\definition.strings.csv"     -- texts by key (notices)
  if exists(keyed) then scene_csvs[#scene_csvs + 1] = keyed end
  -- game files changed for the quest: cooked already, under their path, in the mod bundle
  copy_tree_into(out .. "\\definition.game", overrides, log, qid, "game file changed")
  -- own recordings: audio, lip sync and the speech file (one for every game language)
  local speech_def = out .. "\\definition.speech.yml"
  local ST0 = require("conjunction.scene_texts")
  local scene_base0 = require("conjunction.idremap").wide_base(qid .. "|scene texts", ST0.POOL_SIZE, "")
  local scene_lines = B.scene_text_lines(project, scene_base0)
  if exists(speech_def) or #scene_lines > 0 then
    local SPc = require("conjunction.speech")
    local WSP = require("conjunction.w3speech")
    local lines = exists(speech_def) and GEN_need(Y.read(speech_def), "speech") or Y.list({})
    log(string.format("[build] %s: %d own voice lines", qid, #lines) .. (#scene_lines > 0 and
        string.format(", %d lines of the scene workshop (silent, as long as in the timeline)", #scene_lines) or ""))
    local all = Y.list({})
    for _, ln in ipairs(lines) do all[#all + 1] = ln end
    for _, ln in ipairs(scene_lines) do all[#all + 1] = ln end
    SPc.build(all, out .. "\\speech", packed .. "\\content", "en", log)
    if #lines > 0 then                            -- (the scene workshop's texts go into the strings below, not radish's)
      local csv = out .. "\\speech\\speech.quest.csv"
      SPc.strings_csv(csv, lines, "en")
      scene_csvs[#scene_csvs + 1] = csv
    end
    local made = assert(w3.fs.read(packed .. "\\content\\enpc.w3speech"))
    local v, _lang, spoken = WSP.read(made)
    local WS = require("conjunction.w3strings")
    for _, e in ipairs(w3.fs.list(cfg.game .. "\\content\\content0") or {}) do
      local n = e.name
      if n:sub(-11) == "pc.w3speech" then
        local lang = n:sub(1, -12)
        if lang ~= "en" then
          local d = (WS.LANGS[lang] and v == 164) and WSP.write_v164(lang, spoken) or made
          assert(w3.fs.write(packed .. "\\content\\" .. n, d))
        end
      end
    end
  end
  -- (plug-ins' build steps: the app's Python runs them)
  -- text ids of their own, far from every other quest's (idremap): the encoded files now, strings and speech below
  local IR = require("conjunction.idremap")
  local space = B.production_idspace(defdir, P.get(cfg, "idspace", 9999))
  local lo = 2110000000 + space * 1000
  local wide = B.wide_strings(project, qid)
  if wide ~= nil then
    local moved = 0
    for _, d in ipairs({cooked, overrides}) do if isdir(d) then moved = moved + IR.remap_tree(d, lo, lo + 999, wide) end end
    log(string.format("[build] %s: text ids moved to %d..%d (%d in the encoded files)", qid, wide, wide + 999, moved))
  end
  if project then                                 -- the signed history goes into the bundle (provenance)
    local PV = require("conjunction.provenance")
    PV.note_safely(project, "edit")
    PV.note_safely(project, "build", {force = true, tools = B.build_tools(cfg)})
    local hist = cooked .. "\\dlc\\" .. dlc .. "\\conjunction\\" .. PV.FILE
    B.makedirs(dirname(hist))
    assert(w3.fs.write(hist, PV.blob(project)))
  end
  log(string.format("[build] %s: pack, metadatastore", qid))
  B.pack_and_index(cooked, packed .. "\\content", wcc, bindir, log)
  if collision_cache then                         -- meshes with collision: their shapes for the physics
    log(string.format("[build] %s: collision cache", qid))
    local content = packed .. "\\content"
    B.run({wcc, "buildcache", "physics", "-platform=pc", "-db=" .. out .. "\\cook.db",
           "-out=" .. content .. "\\collision.cache"}, bindir, log)
    B.run({wcc, "metadatastore", "-path=" .. content}, bindir, log)
  end
  -- terrain painted in the editor (terrain.yml): its tiles replace the game's (the mod bundle), their collision goes
  -- into the mod's collision.cache (written before the pack: the store then lists it)
  if project and exists(project .. "\\terrain.yml") then
    require("conjunction.terrain").build_into(project, overrides, packed_mod .. "\\content", log)
  end
  -- the game's quest files edited in the quest graph: under their own paths, in the mod bundle
  if project then
    local own_dir = project .. "\\game_files"
    copy_tree_into(own_dir, overrides, log, qid, "game quest file edited", function(dir, name)
      return name:sub(-4) == ".tmp" or (dir == own_dir and name:sub(1, 10) == "own_quest.")
    end)
  end
  -- texts of its own in the game's scenes (the scene workshop: ids of Conjunction's pool, scene_texts.lua): moved to
  -- ids of the quest's own; their strings go into the DLC's below
  local ST = require("conjunction.scene_texts")
  local scene_base = require("conjunction.idremap").wide_base(qid .. "|scene texts", ST.POOL_SIZE, "")
  if project and isdir(overrides) then
    local moved = ST.remap(overrides, scene_base)
    if moved > 0 then log(string.format("[build] %s: scene texts of its own: %d ids moved", qid, moved)) end
  end
  if #B.game_files_changed(overrides) > 0 then
    log(string.format("[build] %s: the game's files it changes - a mod bundle", qid))
    B.makedirs(packed_mod .. "\\content")
    B.pack_and_index(overrides, packed_mod .. "\\content", wcc, bindir, log)
  end
  local strings = uncooked .. "\\queststrings.csv"
  if #scene_csvs > 0 then
    local all = {strings}
    for _, c in ipairs(scene_csvs) do all[#all + 1] = c end
    strings = B.merge_strings(all, uncooked .. "\\allstrings.csv")
  end
  if exists(strings) then
    log(string.format("[build] %s: strings", qid))
    B.run({cfg.radish .. "\\w3strings.exe", "--encode", strings, "--id-space", tostring(space)}, nil, log)
    local WS = require("conjunction.w3strings")
    local base = basename(strings)
    for _, e in ipairs(w3.fs.list(uncooked) or {}) do
      local f = e.name
      if f:sub(1, #base + 1) == base .. "." and f:sub(-10) == ".w3strings" then
        -- one text for every game language (a missing language file shows empty journal entries)
        local langs, any = {}, false
        for _, g in ipairs(w3.fs.list(cfg.game .. "\\content\\content0") or {}) do
          if g.name:sub(-10) == ".w3strings" then langs[g.name:sub(1, -11)] = true any = true end
        end
        if not any then langs = {en = true} end
        local _v, _h, texts, keys, order = WS.read(assert(w3.fs.read(uncooked .. "\\" .. f)))
        local named = B.people_names(out, texts, keys, space)
        if named > 0 then
          log(string.format("[build] %s: %d people with names of their own", qid, named))
          for k = 0, named - 1 do order[#order + 1] = 2110000000 + space * 1000 + 999 - k end
        end
        if wide ~= nil then
          texts = IR.remap_ids(texts, lo, lo + 999, wide)
          keys = IR.remap_ids(keys, lo, lo + 999, wide)
          for k, sid in ipairs(order) do if lo <= sid and sid <= lo + 999 then order[k] = wide + (sid - lo) end end
        end
        local list = {}
        for lang in pairs(langs) do list[#list + 1] = lang end
        table.sort(list)
        local n = 0
        for _ in pairs(texts) do n = n + 1 end
        for _, lang in ipairs(list) do
          local d = WS.write_v164(WS.LANGS[lang] and lang or "en", texts, nil, keys, order)
          assert(w3.fs.write(packed .. "\\content\\" .. lang .. ".w3strings", d))
        end
        log(string.format("[build] %s: %d strings as v164 in %d languages", qid, n, #list))
      end
    end
  end
  if project then                                 -- (the scene workshop's texts: into the DLC's strings, each language)
    local langs = ST.languages(cfg.game)
    local n = ST.add_strings(project, packed .. "\\content", scene_base, langs)
    if n > 0 then log(string.format("[build] %s: scene texts: %d, in %d languages", qid, n, #langs)) end
  end
  if wide ~= nil then
    local WSP = require("conjunction.w3speech")
    local content_dir = packed .. "\\content"
    local names = {}
    for _, e in ipairs(w3.fs.list(content_dir) or {}) do names[#names + 1] = e.name end
    table.sort(names)
    for _, n in ipairs(names) do
      if n:sub(-11) == "pc.w3speech" then
        local f = content_dir .. "\\" .. n
        local _v, lang, spoken = WSP.read(assert(w3.fs.read(f)))
        for _, s in ipairs(spoken) do if lo <= s[1] and s[1] <= lo + 999 then s[1] = wide + (s[1] - lo) end end
        assert(w3.fs.write(f, WSP.write_v164(lang, spoken)))
      end
    end
  end
  if project and exists(project .. "\\project.yml") then
    local PR = require("conjunction.project")
    require("conjunction.worldchanges").write(project, qid, P.get(PR.open(project).meta, "quest") or Y.map(), packed, log)
  end
  local target = cfg.game .. "\\dlc\\" .. dlc
  if install then
    if exists(target) then FS.rmtree(target) end
    FS.copytree(packed, target)
    log("[build] installed -> " .. target)
    local mod_target = B.install_mod(packed_mod, cfg.game, dlc, log)
    if project and exists(project .. "\\project.yml") then
      local IG = require("conjunction.in_game")
      local PR = require("conjunction.project")
      local base = PR.open(project):base_id()
      for _, folder in ipairs({target, mod_target}) do
        if isdir(folder) then IG.mark(folder, project, dlc:sub(4), base) end
      end
      PR.snapshot(project, dlc:sub(4))           -- (the project as this run was built: a version)
      if not (opts and opts.live) then           -- (only this project in the world: the others parked - into the
        IG.park_others(project, log, cfg.game)   -- running game: play.lua switches them off, parks them at the start)
      end
    end
  else
    log("[build] ready (not installed): " .. packed)
  end
  return packed
end


-- quick check without cooking (seconds): generate, encode the quest and every scene - the errors a build would stop
-- at, from radish, in plain words; then the quest played through by a stand-in player (questsim)
function B.check(project, log)
  log = log or print
  local cfg = CFG.load()
  local PR = require("conjunction.project")
  local PG = require("conjunction.project_gen")
  local tmp = scratch("conjunction_check_")
  local ok, err = pcall(function()
    local pr = PR.open(project)
    local proj = {meta = pr.meta, places = pr.places, id = pr:id(), base_id = pr:base_id(), path = project}
    local defdir = PG.generate(proj, tmp .. "\\definition.quest")
    B.makedirs(tmp .. "\\uncooked")
    B.makedirs(tmp .. "\\scenes")
    log("[check] quest")
    local plain, mine = B.for_radish(defdir)
    if #mine > 0 then
      log(string.format("[check] %d wait%s with Conjunction's own conditions: %s", #mine,
                        #mine ~= 1 and "s" or "", table.concat({table.unpack(mine, 1, math.min(6, #mine))}, ", ")))
    end
    B.run({cfg.radish .. "\\w2quest.exe", "--repo-dir", B.radish_repo(cfg), "--output-dir", tmp .. "\\uncooked",
           "--encode", plain}, nil, log)
    if plain ~= defdir then FS.rmtree(dirname(plain)) end
    B.minigames(tmp, tmp .. "\\uncooked", log)
    -- the game's files the quest changes: they read back
    local changed = {}
    walk(tmp .. "\\definition.game", function(dir, n) changed[#changed + 1] = dir .. "\\" .. n end)
    for _, fn in ipairs(changed) do
      local data = assert(w3.fs.read(fn))
      if CR.parse(data):save() ~= data then B.fail("a changed game file does not read back: " .. basename(fn)) end
    end
    if #changed > 0 then
      log(string.format("[check] %d game file%s changed - they read back", #changed, #changed ~= 1 and "s" or ""))
    end
    local scenedefs = tmp .. "\\definition.scenes"
    if isdir(scenedefs) then
      local names = {}
      for _, e in ipairs(w3.fs.list(scenedefs) or {}) do
        if not e.dir and e.name:sub(1, 6) == "scene." and e.name:sub(-4) == ".yml" then names[#names + 1] = e.name end
      end
      table.sort(names)
      for _, f in ipairs(names) do
        log("[check] scene " .. f:sub(7, -5))
        B.run({cfg.radish .. "\\w2scene.exe", "--repo-dir", cfg.radish .. "\\repo.scenes", "--output-dir",
               tmp .. "\\scenes", "--encode", f:sub(1, -5)}, scenedefs, log)
      end
    end
    -- the quest played through by a stand-in player: a way that stops is said here, not in the game
    local GEN = require("conjunction.questgen_main")
    local QSIM = require("conjunction.questsim")
    local pr2 = PR.open(project)
    local q = P.map(P.get(pr2.meta, "quest"))
    if require("conjunction.questgen").has_quest(q) then
      local p2 = {meta = pr2.meta, places = pr2.places, id = pr2:id(), base_id = pr2:base_id(), path = project}
      local struct, journals = GEN.generate(p2)
      local played, what = QSIM.playthrough(struct, q, pr2:id(), journals)
      log("[check] " .. (played and "played" or "stuck") .. ": " .. what)
    end
    log("[check] ok")
  end)
  FS.rmtree(tmp)
  if not ok then error(err, 0) end
end

-- a project: its radish definition generated from its places, then built. What REDkit cannot cook (a resource it does
-- not find) is left out with a note and the build runs again - one gap must not stop a whole quest.
function B.build(project, install, log, test_from, opts)
  log = log or print
  B.need_redkit()
  local out = project .. "\\build"
  if not exists(project .. "\\project.yml") then
    return B.build_dlc(project .. "\\definition.quest", out, install, log, project, nil, nil, nil, opts)
  end
  local PR = require("conjunction.project")
  local PG = require("conjunction.project_gen")
  local skip = {}
  local tries = 40                                -- every try may bring more of the game's files (links)
  for attempt = 0, tries - 1 do
    local pr = PR.open(project)
    local proj = {meta = pr.meta, places = pr.places, id = pr:id(), base_id = pr:base_id(), path = project,
                  test_from = test_from}
    if test_from then log("[build] a test: the quest starts at " .. P.str(test_from)) end
    local defdir = PG.generate(proj, out .. "\\definition.quest", skip)
    for _, what in ipairs(proj.skipped or {}) do log("[build] left out: " .. what) end
    for _, what in ipairs(proj.notes or {}) do log("[build] " .. what) end
    if attempt > 0 then log(string.format("[build] again (try %d)", attempt + 1)) end
    local lines = {}
    local function keep(line)
      lines[#lines + 1] = line
      log(line)
    end
    local extra = proj.extra_resources
    local has_extra, mesh = false, false
    for rel in pairs(extra or {}) do
      has_extra = true
      if rel:sub(-7) == ".w2mesh" then mesh = true end
    end
    local ok, res = pcall(B.build_dlc, defdir, out, install, keep, project, has_extra and extra or nil, nil, mesh, opts)
    if ok then return res end
    if not B.is_runtime_error(res) then error(res, 0) end
    local missing = {}
    for _, ln in ipairs(lines) do for m in ln:gmatch(B.MISSING) do missing[PYS.lower(m)] = true end end
    local linked = B.link_from_depot(missing, log)
    local unfound, any_linked = {}, next(linked) ~= nil
    for m in pairs(missing) do if not linked[m] then unfound[m] = true end end
    local new = {}
    for t in pairs(templates_using(proj, unfound)) do if not skip[t] then new[#new + 1] = t end end
    if not (any_linked or #new > 0) or attempt == tries - 1 then error(res, 0) end
    table.sort(new)
    local u = {}
    for m in pairs(unfound) do u[#u + 1] = m end
    table.sort(u)
    for _, t in ipairs(new) do
      log("[build] not in REDkit's depot either: " .. table.concat(u, ", ") .. " - left out: " .. t)
      skip[t] = true
    end
  end
end

return B
