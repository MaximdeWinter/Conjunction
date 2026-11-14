-- journal_index.py: the journal entries a quest block can name (an objective to show or tick off, a quest to track,
-- a map pin) - every journal path the game's quest files hold, each with a readable name read from the journal files
-- it leads into. A path is a chain of objects: the journal file of the act, the quest's file, the quest's entries down
-- to the one meant.
--   JI.load() -> index | nil         data\journal_index.json     JI.build(depot, log) -> index (a minute)
--   JI.chain(tree, n) -> {{file or "", guid hex}}     JI.key_of(chain) -> "file|guid>file|guid>..."
--   JI.of_tree(tree, path) -> entries                 the paths of one file
--   JI.Names(depot [, own]):label(chain) -> "quest / phase / objective", kind
local TR = require("conjunction.cr2w_tree")
local J = require("conjunction.json")
local PATHS = require("conjunction.paths")
local JI = {}

JI.CACHE = PATHS.DATA .. "\\journal_index.json"
JI.KINDS = {CJournalQuest = "quest", CJournalQuestPhase = "phase", CJournalQuestObjective = "objective",
            CJournalQuestMapPin = "map pin", CJournalQuestDescriptionGroup = "description",
            CJournalCharacter = "person", CJournalCreature = "monster", CJournalQuestGroup = "act",
            CJournalStoryBookPage = "story book", CJournalTutorial = "tutorial", CJournalGlossary = "glossary",
            CJournalQuestDescriptionEntry = "quest text", CJournalCharacterDescription = "person's text",
            CJournalCreatureDescriptionEntry = "monster's text",
            CJournalStoryBookPageDescription = "story book text", CJournalCreatureGroup = "monster group"}

local function hex(b) return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
JI.hex = hex
local function handle(v) return math.type(v) == "integer" and v > 0 end

function JI.chain(tree, n)
  local out = {}
  local o = handle(n) and tree:obj(n) or nil
  while o ~= nil and o.cls == "CJournalPath" do
    local res = o:get("resource")
    local k = TR.is(res, TR.SOFT) and res.n or 0
    local imps = tree.f.imports
    local path = (k > 0 and k <= #imps) and imps[k][1] or ""
    local g = o:get("guid")
    out[#out + 1] = {path, TR.is(g, TR.GUID) and hex(g.b) or ""}
    local ch = o:get("child")
    o = handle(ch) and tree:obj(ch) or nil
  end
  return out
end

function JI.key_of(ch)
  local parts = {}
  for i, c in ipairs(ch) do parts[i] = c[1] .. "|" .. c[2] end
  return table.concat(parts, ">")
end

-- the path objects a block points at (not a child of another path)
function JI.roots(tree)
  local kids = {}
  for _, o in ipairs(tree.objects) do
    if o.cls == "CJournalPath" then
      local c = o:get("child")
      if c ~= nil then kids[c] = true end
    end
  end
  local out = {}
  for k, o in ipairs(tree.objects) do
    if o.cls == "CJournalPath" and not kids[k] then out[#out + 1] = k end
  end
  return out
end

function JI.of_tree(tree, path)
  local out, order = {}, {}
  for _, k in ipairs(JI.roots(tree)) do
    local ch = JI.chain(tree, k)
    if #ch > 0 then
      local key = JI.key_of(ch)
      local e = out[key]
      if e == nil then
        e = {key = key, chain = ch, count = 0, file = path, obj = k}
        out[key] = e
        order[#order + 1] = e
      end
      e.count = e.count + 1
    end
  end
  return order
end

local function basename(p) return (p:gsub("^.*[\\/]", "")) end

local Names = {}
Names.__index = Names
function JI.Names(depot, own)
  return setmetatable({depot = depot, own = own or {}, files = {}}, Names)
end

function Names:of(path)
  if self.files[path] == nil then
    local names = {}
    pcall(function()                            -- (a file not found: no names from it)
      local data = self.own[path] or self.depot:read(path)
      local t = TR.Tree(data)
      for _, o in ipairs(t.objects) do
        local g = o.props and o:get("guid") or nil
        if TR.is(g, TR.GUID) then
          local name = o:get("baseName")
          if not (name ~= nil and name ~= "") then name = o:get("name") end
          if TR.is(name, TR.WIDE) then name = name.s end
          names[hex(g.b)] = {o.cls, (name ~= nil and name ~= "") and tostring(name) or ""}
        end
      end
    end)
    self.files[path] = names
  end
  return self.files[path]
end

-- "quest / phase / objective" and the kind of the last
function Names:label(ch)
  local parts, kind, res = {}, "", ""
  for _, c in ipairs(ch) do
    local path, g = c[1], c[2]
    if path ~= "" then res = path end
    if res ~= "" then
      local got = self:of(res)[g] or {"", ""}
      local cls, name = got[1], got[2]
      if not (cls == "CJournalQuestGroup" or cls == "CJournalResource" or cls == "") then
        if name ~= "" then parts[#parts + 1] = name end
        kind = JI.KINDS[cls] or cls:gsub("CJournal", ""):lower()
      end
    end
  end
  local label = table.concat(parts, " / ")
  if label == "" then label = res ~= "" and (basename(res):gsub("%.journal", "")) or "?" end
  return label, kind
end

-- the objectives of a project's own quest as its last build wrote them: {{id, guid, caption, file}} - the quest
-- board's and those made in the quest graph (graph_journal.yml)
function JI.own_objectives(project_dir)
  local VE = require("conjunction.vanilla_edit")
  local P = require("conjunction.py")
  local Y = require("conjunction.yaml")
  local rel = VE.own_quest(project_dir)
  if not rel then return {} end
  local root = project_dir .. "\\build\\uncooked"
  local dlc_dir = root .. "\\" .. (rel:match("^(.*)[\\/][^\\/]*[\\/][^\\/]*$") or "")
  local captions = {}
  pcall(function()
    local jy = Y.read(project_dir .. "\\build\\definition.quest\\journals.yml") or Y.map()
    for _, q in pairs(P.get(P.get(jy, "journals") or {}, "quests") or {}) do
      for _, items in pairs(P.get(q, "instructions") or {}) do
        for _, it in ipairs(P.list(items)) do
          if Y.is_map(it) then
            for k, body in pairs(it) do captions[P.str(k)] = P.get(P.map(body), "caption", "") end
          end
        end
      end
    end
  end)
  local files = {}
  if w3.fs.isdir(dlc_dir) then
    for _, e in ipairs(require("conjunction.fsutil").walk(dlc_dir)) do
      if e.name:sub(-8) == ".journal" then files[#files + 1] = e.path end
    end
  end
  local out = {}
  for _, f in ipairs(require("conjunction.pysort").sorted(files)) do
    local ok, t = pcall(function() return TR.Tree(assert(w3.fs.read(f))) end)
    if ok then
      for _, o in ipairs(t.objects) do
        local g = o.props and o:get("guid") or nil
        if o.cls == "CJournalQuestObjective" and TR.is(g, TR.GUID) then
          local oid = tostring(o:get("baseName") or "")
          if TR.is(o:get("baseName"), TR.WIDE) then oid = o:get("baseName").s end
          out[#out + 1] = {id = oid, guid = hex(g.b), caption = captions[oid] or oid, file = f:sub(#root + 2)}
        end
      end
    end
  end
  return out
end

-- every journal path the game's quest files hold, named (journal_index.build): about a minute - in a job it gives the
-- game a frame now and then -> the index, kept in data\journal_index.json
function JI.build(depot, log)
  log = log or print
  local Y = require("conjunction.yaml")
  local PS = require("conjunction.pysort")
  local PYS = require("conjunction.pystr")
  local SB = require("conjunction.story_build")
  local function yield() if coroutine.isyieldable() then coroutine.yield() end end
  depot = depot or require("conjunction.depot").open(require("conjunction.config").load().game)
  local files = {}
  for _, suffix in ipairs({".w2phase", ".w2quest"}) do
    for _, p in ipairs(depot:glob("", suffix)) do if SB.game_file(p) then files[#files + 1] = p end end
  end
  files = PS.sorted(files)
  local entries, order = {}, {}
  for i, path in ipairs(files) do
    local ok, t = pcall(TR.Tree, depot:read(path))
    if ok then
      for _, e in ipairs(JI.of_tree(t, path)) do
        local have = entries[e.key]
        if have then
          have.count = have.count + e.count
        else
          entries[e.key] = e
          order[#order + 1] = e
        end
      end
    end
    if i % 20 == 0 then yield() end
  end
  local names = JI.Names(depot)
  local out = {}
  for i, e in ipairs(order) do
    local chain = Y.list()
    for k, c in ipairs(e.chain) do chain[k] = Y.list({c[1], c[2]}) end
    local label, kind = names:label(e.chain)
    out[i] = Y.map({"key", e.key, "chain", chain, "count", e.count, "file", e.file, "obj", e.obj, "label", label,
                    "kind", kind})
    if i % 200 == 0 then yield() end
  end
  out = PS.sorted(out, function(e) return {PYS.lower(e.label), -e.count} end)
  local index = Y.map({"entries", Y.list(out)})
  local tmp = JI.CACHE .. ".tmp"
  J.write(tmp, index, {})
  w3.fs.remove(JI.CACHE)
  w3.fs.rename(tmp, JI.CACHE)
  log(string.format("[journal] %d journal entries the game's quests name", #out))
  return index
end

-- the journal index (nil when it is not there yet)
function JI.get() return JI.load() end

function JI.load()
  local ok, fs = pcall(function() return w3.fs end)
  if ok and fs and fs.exists and not fs.exists(JI.CACHE) then return nil end
  local okr, v = pcall(J.read, JI.CACHE)
  return okr and v or nil
end

function JI.by_key(index)
  local out = {}
  for _, e in ipairs(index and index.entries or {}) do out[e.key] = e end
  return out
end

return JI
