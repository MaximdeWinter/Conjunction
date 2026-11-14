-- Quest packages (packaging.py): a quest made with Conjunction as one file anyone with Conjunction can play.
--   PK.export(project_path, include_source, version, log, packs, rebuild) -> the .w3q's path (in a coroutine: it may
--   build first)       PK.manifest(project, include_source, version, packs)       PK.read_manifest(path)
-- A .w3q is a zip laid out as the game's folders:
--   dlc/dlc<id>/...                       the built DLC
--   dlc/dlc<id>/conjunction_quest.yml     the manifest: what it is and what it needs
--   dlc/dlc<id>/conjunction_source/...    the project - only if its author shares it
--   Mods/moddlc<id>/...                   the game's files it changes, if any
local Y = require("conjunction.yaml")
local P = require("conjunction.py")
local PYS = require("conjunction.pystr")
local FS = require("conjunction.fsutil")
local PATHS = require("conjunction.paths")
local PK = {}

PK.EXPORTS = PATHS.EXPORTS
PK.RUNTIME_VERSION = 2                   -- (2: CjFocusClue, CjPart, CjThingLook, CjThingAnim)
PK.EXPANSIONS = {{"dlc\\ep1\\", "Hearts of Stone"}, {"dlc\\bob\\", "Blood and Wine"}}
PK.ID_FILE = ".conjunction_id"
PK.QUEST_MANIFEST = "conjunction_quest.yml"
PK.SUITE_PAGE = "https://www.nexusmods.com/witcher3/mods/15718"
PK.RUNTIME_PAGE = ""
PK.TW3SE_PAGE = "https://www.nexusmods.com/witcher3/mods/13837"
PK.GAME = "The Witcher 3 Remastered 5.0 or 5.01 (with Hearts of Stone and Blood and Wine)"
PK.APP_NAME = "Conjunction"
PK.WORLD_NAMES = {novigrad = "Velen and Novigrad", velen = "Velen and Novigrad", skellige = "Skellige",
                  kaer_morhen = "Kaer Morhen", prologue = "White Orchard", prologue_winter = "White Orchard",
                  bob = "Toussaint", toussaint = "Toussaint"}

local S, get = P.str, P.get
local function exists(p) return w3.fs.exists(p) end
local function isdir(p) return w3.fs.isdir(p) end

function PK.expansions_used(project)
  local used, list = {}, {}
  for _, name in ipairs(Y.keys(project.places)) do
    for _, o in ipairs(P.list(get(project.places[name], "objects"))) do
      local t = PYS.lower(S(get(o, "template", "")))
      for _, e in ipairs(PK.EXPANSIONS) do
        if t:sub(1, #e[1]) == e[1] and not used[e[2]] then used[e[2]] = true list[#list + 1] = e[2] end
      end
    end
  end
  table.sort(list)
  return Y.list(list)
end

-- content packs whose lines the quest carries itself ({pack id = lines used})
function PK.baked_packs(project)
  local out = Y.map()
  local stack = {P.map(get(project.meta, "quest"))}
  while #stack > 0 do
    local x = table.remove(stack)
    if Y.is_map(x) then
      if P.T(get(x, "voice_pack")) then
        local pack = S(x.voice_pack):match("^([^/]*)")
        out[pack] = (out[pack] or 0) + 1
      end
      for _, v in pairs(x) do stack[#stack + 1] = v end
    elseif type(x) == "table" and x ~= Y.null then
      for _, v in ipairs(x) do stack[#stack + 1] = v end
    end
  end
  return out
end

-- str.title()
local function title(s)
  local out, prev = {}, false
  for _, c in utf8.codes(s) do
    local ch = utf8.char(c)
    local cased = PYS.isalpha(ch)
    out[#out + 1] = cased and (prev and PYS.lower(ch) or PYS.upper(ch)) or ch
    prev = cased
  end
  return table.concat(out)
end

-- how the quest begins, for players: {text, world} (nil: unknown)
function PK.starts_with(project)
  local GEN = require("conjunction.questgen")
  local QN = require("conjunction.quest_nodes")
  local Q = require("conjunction.quest")
  local q = P.map(get(project.meta, "quest"))
  local ok, steps = pcall(function()
    if QN.is_graph(q) then
      local nodes = P.map(get(q, "nodes"))
      local first
      for _, l in ipairs(P.list(get(q, "links"))) do
        if l[1] == "start" and nodes[l[3]] ~= nil and first == nil then first = l[3] end
      end
      return first and {nodes[first].step} or {}
    end
    local out = {}
    for _, st in ipairs(GEN.all_steps(q)) do if GEN.step_type(st) ~= "chapter" then out[#out + 1] = st end end
    return out
  end)
  if not ok then steps = {} end
  if #steps == 0 then return nil end
  local kind, a = GEN.step_type(steps[1])
  local text = P.get(a or Y.map(), "text")
  if not P.T(text) then text = Q.default_text(kind, a or Y.map(), get(q, "items")) end
  local world = ""
  for _, name in ipairs(Y.keys(project.places)) do
    local w = get(project.places[name], "world")
    if P.T(w) then world = w break end
  end
  return Y.map({"text", S(P.T(text) and text or kind), "world", PK.WORLD_NAMES[PYS.lower(S(world))] or title(S(world))})
end

-- the game's files the quest changes (its mod part) - two quests changing the same one cannot both work
function PK.replaced_files(project)
  local root = project.path .. "\\build\\overrides"
  local out = {}
  for _, f in ipairs(isdir(root) and FS.walk(root) or {}) do out[#out + 1] = PYS.lower((f.rel:gsub("/", "\\"))) end
  table.sort(out)
  return Y.list(out)
end

-- [first, last] of the quest's text ids
function PK.strings_range(project)
  local wide = require("conjunction.build").wide_strings(project, project:id())
  local lo = wide or (2110000000 + require("conjunction.questgen").idspace(project:id()) * 1000)
  return Y.list({lo, lo + 999})
end

local function packs_of(project)
  local C = require("conjunction.content")
  local ok, packs = pcall(function() return (C.manifest_packs(project, nil, C.labeler())) end)
  return ok and packs or Y.list({})
end

function PK.manifest(project, include_source, version, packs)
  local GEN = require("conjunction.questgen")
  local meta = project.meta
  local q = P.map(get(meta, "quest"))
  local langs = {"en"}
  local packed = project.path .. "\\build\\packed\\content"
  if isdir(packed) then
    langs = {}
    for _, e in ipairs(w3.fs.list(packed) or {}) do
      if e.name:sub(-10) == ".w3strings" then langs[#langs + 1] = e.name:sub(1, -11) end
    end
    table.sort(langs)
  end
  local place = get(meta, "kind") == "place"
  local fp = require("conjunction.bugreport").fingerprint
  local after = PYS.lower(S(P.or_(get(q, "after"), "")))
  local starts = Y.null
  if not place then
    local s = get(P.map(get(meta, "page")), "starts")
    if not P.T(s) then s = PK.starts_with(project) end
    starts = s or Y.null
  end
  return Y.map({"id", project:id(), "kind", place and "place" or "quest",
                "title", P.or_(place and get(meta, "name") or get(q, "title"), get(meta, "name", project:id())),
                "author", get(meta, "author", ""), "version", S(version or get(meta, "version", "1.0")),
                "description", P.or_(get(q, "description"), get(meta, "description", "")),
                "made", os.date("%Y-%m-%d"), "suite", fp and (fp()) or "",
                "suite_version", require("conjunction.provenance").VERSION, "runtime", 0, "game", "remaster",
                "expansions", PK.expansions_used(project), "packs", packs ~= nil and packs or packs_of(project),
                "baked", PK.baked_packs(project), "languages", Y.list(langs),
                "strings_idspace", GEN.idspace(project:id()), "strings", PK.strings_range(project),
                "after", after ~= "" and after or Y.null, "replaces", PK.replaced_files(project),
                "starts", starts, "source", not not include_source})
end

function PK.export_id(folder)
  local s = w3.fs.read(folder .. "\\" .. PK.ID_FILE)
  if not s then return nil end
  s = PYS.strip(s)
  return s ~= "" and s or nil
end

-- the export's folder, named as the quest: a name another quest already has gets a number
function PK.export_folder(m)
  local name = S(P.or_(get(m, "title"), "")):gsub('[<>:"/\\|?*%z\1-\31]', "")
  name = PYS.strip(name):gsub("%.+$", "")
  if name == "" then name = S(m.id) end
  local folder, n = PK.EXPORTS .. "\\" .. name, 2
  while isdir(folder) and PK.export_id(folder) ~= nil and PK.export_id(folder) ~= m.id do
    folder, n = PK.EXPORTS .. "\\" .. name .. " (" .. n .. ")", n + 1
  end
  return folder
end

-- the folder of a quest's export (by its id), or nil - also one of the old names (<id>-<version>)
function PK.find_export(qid)
  if not isdir(PK.EXPORTS) then return nil end
  local best, t = nil, nil
  for _, e in ipairs(w3.fs.list(PK.EXPORTS) or {}) do
    local d = PK.EXPORTS .. "\\" .. e.name
    if e.dir and (PK.export_id(d) == qid or PYS.lower(e.name):sub(1, #qid + 1) == PYS.lower(qid .. "-")) then
      local m = w3.fs.mtime(d) or 0
      if t == nil or m > t then best, t = d, m end
    end
  end
  return best
end

local function link(url, text) return url ~= "" and ("[url=" .. url .. "]" .. text .. "[/url]") or text end
function PK.what(m) return get(m, "kind") == "place" and "place mod" or "quest" end
function PK.runtime_page() return PK.RUNTIME_PAGE ~= "" and PK.RUNTIME_PAGE or (PK.SUITE_PAGE .. "?tab=files") end

-- what a player needs for the quest, in order -> {{text, url}}
function PK.needs(m)
  local out = {{PK.GAME, ""}}
  if P.T(get(m, "tw3se")) then
    local v = P.T(get(m, "tw3se_min")) and (" " .. P.str(m.tw3se_min) .. " or newer") or ""
    out[#out + 1] = {"TW3SE" .. v, PK.TW3SE_PAGE}
  end
  local runtime = get(m, "runtime", 1)
  if require("conjunction.questgen").int(runtime) ~= 0 then
    out[#out + 1] = {"Conjunction Runtime " .. S(runtime) .. " or newer", PK.runtime_page()}
  end
  for _, p in ipairs(P.list(get(m, "packs"))) do
    local used = {}
    for _, u in ipairs(P.list(get(p, "used"))) do used[#used + 1] = S(P.or_(get(u, "name"), get(u, "ref"))) end
    local text = PYS.strip(S(get(p, "name")) .. " " .. S(get(p, "version", "")))
    if #used > 0 then
      text = text .. " (for: " .. table.concat({table.unpack(used, 1, math.min(6, #used))}, ", ") ..
             (#used > 6 and ", ..." or "") .. ")"
    end
    out[#out + 1] = {text, S(P.or_(get(p, "url"), ""))}
  end
  if P.T(get(m, "after")) then out[#out + 1] = {"the quest " .. S(m.after) .. " (this one starts after it)", ""} end
  return out
end

-- dlc<id>\README.txt: what a player who installs the quest by hand needs to know
function PK.player_readme(m)
  local lines = {PYS.strip(S(get(m, "title")) .. " " .. S(get(m, "version", ""))), "",
                 "Install: unpack into the game folder (the one with bin, content, dlc), or use a mod manager.",
                 "Remove: delete the folders dlc\\dlc" .. S(get(m, "id")) .. " and Mods\\moddlc" .. S(get(m, "id")) .. ".",
                 "", "Needs:"}
  for _, n in ipairs(PK.needs(m)) do lines[#lines + 1] = "- " .. n[1] .. (n[2] ~= "" and (" (" .. n[2] .. ")") or "") end
  local rp = PK.runtime_page()
  for _, l in ipairs({"", "Recommended: the Conjunction Runtime" .. (rp ~= "" and (" (" .. rp .. ")") or "") ..
                     ". It removes quests cleanly.", "", "Made with " .. PK.APP_NAME .. (PK.SUITE_PAGE ~= "" and (" (" .. PK.SUITE_PAGE .. ")") or "") .. ".", ""}) do
    lines[#lines + 1] = l
  end
  return table.concat(lines, "\r\n")
end

-- what a quest's download page should say (Nexus BBCode)
function PK.nexus_text(m)
  local st = P.map(get(m, "starts"))
  local lines = {"[size=4][b]" .. S(get(m, "title")) .. "[/b][/size]"}
  if P.T(get(m, "version")) then lines[#lines + 1] = "Version " .. S(m.version) end
  lines[#lines + 1] = ""
  if P.T(get(m, "description")) then lines[#lines + 1] = S(m.description) lines[#lines + 1] = "" end
  if get(m, "kind") == "place" then
    lines[#lines + 1] = "A place mod: its places are in the world from the first load."
    lines[#lines + 1] = ""
  end
  if P.T(get(st, "text")) then
    lines[#lines + 1] = "[b]Starts:[/b] " .. S(st.text) .. (P.T(get(st, "world")) and (" (" .. S(st.world) .. ")") or "")
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "[b]Requirements[/b]"
  lines[#lines + 1] = "[list]"
  for _, n in ipairs(PK.needs(m)) do lines[#lines + 1] = "[*]" .. link(n[2], n[1]) end
  lines[#lines + 1] = "[/list]"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[b]Recommended[/b]: " .. link(PK.runtime_page(), "Conjunction Runtime") .. ". It removes the " ..
                      PK.what(m) .. " cleanly."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[b]Install[/b]: unpack the .zip into the game folder (the one with bin, content, dlc), or use a " ..
                      "mod manager."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Made with " .. link(PK.SUITE_PAGE, PK.APP_NAME) .. " " .. S(get(m, "suite_version", "")) .. "."
  return table.concat(lines, "\n") .. "\n"
end

-- os.walk's order: a folder's files, then its folders (skip_dir(name): a folder left out at every level)
local function walk_files(root, fn, skip_dir)
  local files, dirs = {}, {}
  for _, e in ipairs(w3.fs.list(root) or {}) do
    if e.dir then
      if not (skip_dir and skip_dir(e.name)) then dirs[#dirs + 1] = e.name end
    else files[#files + 1] = e.name end
  end
  for _, f in ipairs(files) do fn(root .. "\\" .. f) end
  for _, d in ipairs(dirs) do walk_files(root .. "\\" .. d, fn, skip_dir) end
end

-- the built quest as a .w3q (built first when it is not, or under its own id when the last build was a test run)
function PK.export(project_path, include_source, version, log, packs, rebuild)
  log = log or print
  local PR = require("conjunction.project")
  local B = require("conjunction.build")
  local project = PR.open(project_path)
  log("[export] checking the quest")
  if project:id() ~= project:base_id() or rebuild then
    local run = project.meta.run
    Y.remove(project.meta, "run")
    project:save_meta()
    log("[export] Built again as " .. project:base_id() .. "")
    local ok, err = pcall(B.build, project_path, false, log)
    if run ~= nil then
      local kept = PR.open(project_path)
      kept.meta.run = run
      kept:save_meta()
    end
    if not ok then error(err, 0) end
    project = PR.open(project_path)
    Y.remove(project.meta, "run")
  end
  local out = project_path .. "\\build"
  local dlc = out .. "\\packed"
  local function built() return isdir(dlc .. "\\content") and #(w3.fs.list(dlc .. "\\content") or {}) > 0 end
  if not built() then
    log("[export] Built first")
    B.build(project_path, false, log)
    project = PR.open(project_path)
  end
  if not built() then require("conjunction.questgen").fail("The quest could not be built. Please Build & Play it once") end
  local m = PK.manifest(project, include_source, version, packs)
  m.tw3se = exists(dlc .. "\\tw3se\\world.txt")
  -- (things of the world named by tag, lights switched or moves played: world edits TW3SE knows from 1.3.3 on)
  if m.tw3se then
    local wt = "\n" .. (w3.fs.read(dlc .. "\\tw3se\\world.txt") or "")
    if wt:find("\ntag ", 1, true) or wt:find("\nlight ", 1, true) or wt:find("\nanim ", 1, true) then
      m.tw3se_min = "1.3.3"
    end
  end
  local folder = PK.export_folder(m)
  B.makedirs(folder)
  local mark = folder .. "\\" .. PK.ID_FILE
  if PK.export_id(folder) ~= m.id then
    local attr = w3.plugin and w3.plugin.cj_file_attributes
    if attr and exists(mark) then attr(mark, "128") end      -- (Windows refuses to write over a hidden file)
    assert(w3.fs.write(mark, S(m.id)))
    if attr then attr(mark, "2") end                           -- (hidden: the folder shows only what to upload)
  end
  local name = folder:match("([^\\]*)$")
  local path = folder .. "\\" .. name .. ".w3q"
  local top = "dlc/dlc" .. S(m.id) .. "/"
  log("[export] the quest file")
  local tmp = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_export_" .. require("conjunction.marks").uuid4_hex():sub(1, 8)
  B.makedirs(tmp)
  local plan, k = {}, 0
  local function text_entry(entry, data)
    k = k + 1
    local f = tmp .. "\\" .. k
    assert(w3.fs.write(f, data))
    plan[#plan + 1] = entry .. "\t" .. f
  end
  text_entry(top .. PK.QUEST_MANIFEST, Y.dump(m, {sort_keys = false, allow_unicode = true, default_flow_style = false}))
  text_entry(top .. "README.txt", PK.player_readme(m))
  local PV = require("conjunction.provenance")
  PV.note_safely(project_path, "export", {force = true})
  local hist = PV.blob(project_path)
  text_entry(top .. "conjunction/" .. PV.FILE, hist)
  walk_files(dlc, function(p) plan[#plan + 1] = top .. p:sub(#dlc + 2):gsub("\\", "/") .. "\t" .. p end)
  local mod = out .. "\\packed_mod"
  if isdir(mod) then
    walk_files(mod, function(p) plan[#plan + 1] = "Mods/moddlc" .. S(m.id) .. "/" .. p:sub(#mod + 2):gsub("\\", "/") .. "\t" .. p end)
  end
  if include_source then
    walk_files(project_path, function(p)
      plan[#plan + 1] = top .. "conjunction_source/" .. p:sub(#project_path + 2):gsub("\\", "/") .. "\t" .. p
    end, function(d) return d == "build" or d == "versions" end)
  end
  local plan_file = tmp .. "\\plan.txt"
  assert(w3.fs.write(plan_file, table.concat(plan, "\n")))
  if exists(path) then w3.fs.remove(path) end
  local r = w3.plugin.cj_zip_write(path, plan_file)
  FS.rmtree(tmp)
  if not r or not tostring(r):match("^%d+$") then error("zip: " .. tostring(r), 0) end
  -- the same file as a plain .zip: what Nexus takes and a mod manager installs
  log("[export] the zip for mod managers")
  local zip = path:gsub("%.w3q$", "") .. ".zip"
  if exists(zip) then w3.fs.remove(zip) end
  assert(w3.fs.copy(path, zip))
  log("[export] the page text")
  local page = path:gsub("%.w3q$", "") .. ".nexus.txt"
  assert(FS.write_text(page, PK.nexus_text(m)))
  log("[export] " .. path)
  log("[export] text for its download page: " .. page)
  return path
end

-- where a .w3q keeps its manifest (in its DLC folder; older files: the root)
function PK.manifest_name(names)
  for _, n in ipairs(names) do if n == "manifest.yml" then return n end end
  for _, n in ipairs(names) do
    local _, slashes = n:gsub("/", "")
    if slashes == 2 and n:sub(1, 4) == "dlc/" and n:sub(-(#PK.QUEST_MANIFEST + 1)) == "/" .. PK.QUEST_MANIFEST then
      return n
    end
  end
  error("KeyError: 'no manifest'", 0)
end

function PK.read_manifest(path)
  local tmp = (os.getenv("TEMP") or "C:\\tmp") .. "\\conjunction_w3q_" .. require("conjunction.marks").uuid4_hex():sub(1, 8)
  require("conjunction.build").makedirs(tmp)
  local ok, res = pcall(function()
    local list = tmp .. "\\list.txt"
    assert(w3.plugin.cj_zip_list(path, list))
    local names = {}
    for line in (assert(w3.fs.read(list)) .. "\n"):gmatch("([^\n]*)\n") do
      local n = line:match("^([^\t]*)\t")
      if n then names[#names + 1] = n end
    end
    local name = PK.manifest_name(names)
    local plan = tmp .. "\\plan.txt"
    assert(w3.fs.write(plan, name .. "\t" .. tmp .. "\\manifest.yml"))
    assert(w3.plugin.cj_zip_extract(path, plan))
    return Y.load(assert(w3.fs.read(tmp .. "\\manifest.yml"))) or Y.map()
  end)
  FS.rmtree(tmp)
  if not ok then error(res, 0) end
  return res
end

function PK.game_dir() return require("conjunction.config").load().game or "" end

return PK
